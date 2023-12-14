process split_bam {
  label 'minimap2'

  input:
    tuple val(name), val(type), path(bam)

  output:
    tuple val(name), val('mapped'), path("${name}.mapped.bam"), emit: mapped
    tuple val(name), val('unmapped'), path("${name}.unmapped.bam"), emit: unmapped

  script:
  // includes supplementary alignments included (chimeric alignment, sometimes also not linear )
  if ( params.lib_pairedness == 'paired' ){
    """
    samtools view -h -@ ${task.cpus} -f 2 ${bam} | samtools sort -o ${name}.mapped.bam -@ ${task.cpus}
    samtools view -h -@ ${task.cpus} -F 2 ${bam} | samtools sort -o ${name}.unmapped.bam -@ ${task.cpus}
    """
  } else if ( params.lib_pairedness == 'single' ) {
    """
    samtools view -h -@ ${task.cpus} -F 4 ${bam} | samtools sort -o ${name}.mapped.bam -@ ${task.cpus}
    samtools view -h -@ ${task.cpus} -f 4 ${bam} | samtools sort -o ${name}.unmapped.bam -@ ${task.cpus}
    """
  } else { error "Invalid pairedness: ${params.lib_pairedness}" }
  stub:
  """
  touch ${name}.mapped.bam ${name}.unmapped.bam
  """
}

process merge_bam {
  label 'minimap2'

  input:
    tuple val(name), val(type), path(bam)

  output:
  tuple val(name), val(type), path("${bam[0].baseName}_merged.bam")

  script:
  """
  samtools merge -@ ${task.cpus} ${bam[0].baseName}_merged.bam ${bam} # first bam is output
  """
  stub:
  """
  touch ${bam[0].baseName}_merged.bam
  """
}

process filter_soft_clipped_alignments {
  label 'samclipy'
  label 'smallTask'

  publishDir (
    path: "${params.output}/intermediate",
    mode: params.publish_dir_mode,
    pattern: "${name}*.bam{,.bai}",
    enabled: !params.no_intermediate,
    saveAs: { fn ->
          fn.startsWith("keep_") ? "map-to-keep/soft-clipped/${fn.replaceAll(~'^keep_', '')}" : "map-to-remove/soft-clipped/${fn}"
    }
  )

  input:
  tuple val(name), path (bam)
  val (minClip)

  output:
  tuple val(name), val('unmapped'), path ('*.soft-clipped.bam'), emit: bam_clipped
  tuple val(name), val('mapped'), path ('*.passed-clipped.bam'), emit: bam_ok_clipped
  tuple val(name), path ('*.bam.bai')

  script:
  """
  git clone https://github.com/MarieLataretu/samclipy.git --branch v0.0.2 || git clone git@github.com:MarieLataretu/samclipy.git --branch v0.0.2
  samtools view -h ${bam} | python samclipy/samclipy.py --invert --minClip ${minClip} | samtools sort > ${name}.soft-clipped.bam
  samtools view -h ${bam} | python samclipy/samclipy.py --minClip ${minClip} | samtools sort > ${name}.passed-clipped.bam
  samtools index ${name}.soft-clipped.bam
  samtools index ${name}.passed-clipped.bam
  """
  stub:
  """
  touch ${name}.soft-clipped.bam ${name}.passed-clipped.bam ${name}.soft-clipped.bam.bai ${name}.passed-clipped.bam.bai
  """
}

process filter_true_dcs_alignments {
  label 'bed_samtools'

  publishDir (
    path: "${params.output}/intermediate",
    mode: params.publish_dir_mode,
    pattern: "${name}*.bam{,.bai}",
    enabled: !params.no_intermediate,
    saveAs: { fn ->
          fn.startsWith("keep_") ? "map-to-keep/strict-dcs/${fn.replaceAll(~'^keep_', '')}" : "map-to-remove/strict-dcs/${fn}"
    }
  )

  input:
  tuple val(name), path (bam)
  path (dcs_ends_bed)

  output:
  tuple val(name), val('mapped'), path ("${name}.no-dcs.bam"), emit: no_dcs
  tuple val(name), val('mapped'), path ("${name}.true-dcs.bam"), emit: true_dcs
  tuple val(name), val('unmapped'), path ("${name}.false-dcs.bam"), emit: false_dcs
  tuple val(name), path ('*.bam.bai')
  path('dcs.bam')

  script:
  """
  # true spike in: 1-65 || 1-92; 3513-3560 (len 48)
  samtools view -b -h -e 'rname=="Lambda_3.6kb"' ${bam} > dcs.bam
  samtools view -b -h -e 'rname!="Lambda_3.6kb"' ${bam} > ${name}.no-dcs.bam
  bedtools intersect -wa -ubam -a dcs.bam -b ${dcs_ends_bed} > ${name}.true-dcs.bam
  bedtools intersect -v -ubam -a dcs.bam -b ${dcs_ends_bed} > ${name}.false-dcs.bam
  samtools index dcs.bam
  samtools index ${name}.no-dcs.bam
  samtools index ${name}.true-dcs.bam
  samtools index ${name}.false-dcs.bam
  """
  stub:
  """
  touch ${name}.no-dcs.bam ${name}.true-dcs.bam ${name}.false-dcs.bam ${name}.no-dcs.bam.bai ${name}.true-dcs.bam.bai ${name}.false-dcs.bam.bai
  """
}

process fastq_from_bam {
  label 'minimap2'

  publishDir (
    path: "${params.output}/intermediate",
    mode: params.publish_dir_mode,
    pattern: "*.gz",
    enabled: !params.no_intermediate,
    saveAs: { fn ->
          fn.startsWith("keep_") ? "map-to-keep/${fn.replaceAll(~'^keep_', '').replaceAll(~'_merged', '')}" : "map-to-remove/${fn.replaceAll(~'_merged', '')}"
    }
  )

  // When using --keep, cleaned fastq files are generated by the
  // filter_fastq_by_name process and not here
  if ( !params.keep ) {
    publishDir (
      path: params.output,
      mode: params.publish_dir_mode,
      pattern: "*.gz",
      saveAs: { fn ->
            fn.matches('.*.unmapped.fast[aq].gz$') ? "clean/${fn}".replaceAll(~'.unmapped(.fast[aq].gz)$', '$1') :
            fn.matches('.*.mapped.fast[aq].gz$') ? "removed/${fn}".replaceAll(~'.mapped(.fast[aq].gz)$', '$1') :
            fn.matches('.*.unmapped_merged.fast[aq].gz$') ? "clean/${fn}".replaceAll(~'.unmapped_merged(.fast[aq].gz)$', '$1') :
            fn.matches('.*.mapped_merged.fast[aq].gz$') ? "removed/${fn}".replaceAll(~'.mapped_merged(.fast[aq].gz)$', '$1') :
            fn.matches('.*.unmapped_merged_merged.fast[aq].gz$') ? "clean/${fn}".replaceAll(~'.unmapped_merged_merged(.fast[aq].gz)$', '$1') :
            fn.matches('.*.soft-clipped_merged.fast[aq].gz$') ? "clean/${fn}".replaceAll(~'.soft-clipped_merged(.fast[aq].gz)$', '$1') :
            fn.matches('.*.unmapped_(1|2|singleton).fast[aq].gz$') ? "clean/${fn}".replaceAll(~'.unmapped_(1|2|singleton)(.fast[aq].gz)$', '_$1$2') :
            fn.matches('.*.mapped_(1|2|singleton).fast[aq].gz$') ? "removed/${fn}".replaceAll(~'.mapped_(1|2|singleton)(.fast[aq].gz)$', '_$1$2') :
            fn
      }
    )
  }

  input:
  tuple val(name), val(type), path(bam)

  output:
  tuple val(name), val(type), path('*.fast*.gz')

  script:
  if ( params.lib_pairedness == 'paired' ) {
    """
    samtools fastq -@ ${task.cpus} -c 6 -1 ${bam.baseName}_1.fastq.gz -2 ${bam.baseName}_2.fastq.gz -s ${bam.baseName}_singleton.fastq.gz ${bam}
    """
  } else if ( params.lib_pairedness == 'single' ) {
    dtype = (params.input_type == 'fasta') ? 'a' : 'q'
    """
    samtools fast${dtype} -@ ${task.cpus} -c 6 -0 ${bam.baseName}.fast${dtype}.gz ${bam}
    """
  } else {
    error "Invalid pairedness: ${params.lib_pairedness}"
  }
  stub:
  dtype = (params.input_type == 'fasta') ? 'a' : 'q'
  """
  touch ${bam.baseName}_1.fast${dtype}.gz ${bam.baseName}_2.fast${dtype}.gz
  """
}

process idxstats_from_bam {
  label 'minimap2'

  publishDir (
    path: "${params.output}/intermediate",
    mode: params.publish_dir_mode,
    pattern: "*.sorted.idxstats.tsv",
    enabled: !params.no_intermediate,
    saveAs: { fn ->
          fn.startsWith("keep_") ? "map-to-keep/${fn.replaceAll(~'^keep_', '')}" : "map-to-remove/${fn}"
    }
  )

  input:
  tuple val(name), val(type), path(bam), path(bai)

  output:
  tuple val(name), val(type), path('*.idxstats.tsv')

  script:
  """
  samtools idxstats ${bam} > ${bam.baseName}.idxstats.tsv
  """
  stub:
  """
  touch ${bam.baseName}.idxstats.tsv
  """
}

process flagstats_from_bam {
  label 'minimap2'

  publishDir (
    path: "${params.output}/intermediate",
    mode: params.publish_dir_mode,
    pattern: "*.sorted.flagstats.txt",
    enabled: !params.no_intermediate,
    saveAs: { fn ->
          fn.startsWith("keep_") ? "map-to-keep/${fn.replaceAll(~'^keep_', '')}" : "map-to-remove/${fn}"
    }
  )

  input:
  tuple val(name), val(type), path(bam), path(bai)

  output:
  tuple val(name), val(type), path('*.flagstats.txt')

  script:
  """
  samtools flagstats ${bam} > ${bam.baseName}.flagstats.txt
  """
  stub:
  """
  touch ${bam.baseName}.flagstats.txt
  """
}

process sort_bam {
  label 'minimap2'

  input:
  tuple val(name), val(type), path(bam)

  output:
  tuple val(name), val(type), path("${bam.baseName}.sorted.bam")

  script:
  """
  mv ${bam} ${bam}.tmp
  samtools sort -@ ${task.cpus} ${bam}.tmp > ${bam.baseName}.sorted.bam
  """
  stub:
  """
  touch ${bam.baseName}.sorted.bam
  """
}

process index_bam {
  label 'minimap2'

  publishDir (
    path: "${params.output}/intermediate",
    mode: params.publish_dir_mode,
    pattern: "*.sorted.bam{,.bai}",
    enabled: !params.no_intermediate,
    saveAs: { fn ->
          fn.startsWith("keep_") ? "map-to-keep/${fn.replaceAll(~'^keep_', '')}" : "map-to-remove/${fn}"
    }
  )

  input:
  tuple val(name), val(type), path(bam)

  output:
  tuple val(name), val(type), path(bam), path('*.bai')

  script:
  """
  samtools index -@ ${task.cpus} ${bam}
  """
  stub:
  """
  touch ${bam}.bai
  """
}
