process get_number_of_records {
  label 'smallTask'

  input:
  tuple val(name), path(reads)

  output:
  tuple val(name), env(TOTALRECORDS), emit: TOTALRECORDS

  script:
  if ( params.lib_pairedness == 'paired' ) {
    """
    if [[ ${reads[0]} =~ \\.gz\$ ]]; then
      TOTALRECORDS_1=\$(zcat ${reads[0]} | echo \$((`wc -l`/4)))
      TOTALRECORDS_2=\$(zcat ${reads[1]} | echo \$((`wc -l`/4)))
    else
      TOTALRECORDS_1=\$(cat ${reads[0]} | echo \$((`wc -l`/4)))
      TOTALRECORDS_2=\$(cat ${reads[1]} | echo \$((`wc -l`/4)))
    fi
    TOTALRECORDS=\$(( TOTALRECORDS_1+TOTALRECORDS_2 ))
    """
  } else if ( params.lib_pairedness == 'single' && params.input_type != 'fasta' ) {
    """
    if [[ ${reads} =~ \\.gz\$ ]]; then
      TOTALRECORDS=\$(zcat ${reads} | echo \$((`wc -l`/4)))
    else
      TOTALRECORDS=\$(cat ${reads} | echo \$((`wc -l`/4)))
    fi
    """
  } else if ( params.input_type == 'fasta' ) {
    """
    if [[ ${reads} =~ \\.gz\$ ]]; then
      TOTALCONTIGS=\$(zgrep '^>' ${reads} | wc -l)
    else
      TOTALCONTIGS=\$(grep '^>' ${reads} | wc -l)
    fi
    """
  } else {
    error "Invalid pairedness: ${params.lib_pairedness} or input_type: ${params.input_type}"
  }
  stub:
  """
  TOTALRECORDS=42
  """
}

process get_read_names {
  label 'minimap2'

  input:
  tuple val(name), path(bam)

  output:
  tuple val(name), path("${name}_read_names.csv")

  script:
  """
  samtools view ${bam} | cut -f1 | sort | uniq > ${name}_read_names.csv
  """
  stub:
  """
  touch ${name}_read_names.csv
  """
}

process get_read_names_fastx {
  label 'seqkit'

  input:
  tuple val(name), path(fastx)

  output:
  tuple val(name), path("${name}.ids")

  script:
  """
  seqkit seq -ni ${fastx} | sort | uniq > ${name}.ids
  """
  stub:
  """
  touch ${name}.ids
  """
}

process filter_fastq_by_name {
  label 'minimap2'  // We don't need minimap2 but the container has pigz

  // When using --keep, this is where the final cleaned fastq file is
  // generated. If not, it's generated by the fastq_from_bam process or
  // bbduk mapping
  if ( params.keep ) {
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
            fn.matches('.*.mapped_merged_merged.fast[aq].gz$') ? "removed/${fn}".replaceAll(~'.mapped_merged_merged(.fast[aq].gz)$', '$1') :
            fn.matches('.*.fast[aq].clean.fast[aq].gz$') ? "clean/${fn}".replaceAll(~'.fast[aq].clean(.fast[aq].gz)$', '$1') :
            fn.matches('.*.fast[aq].contamination.fast[aq].gz$') ? "removed/${fn}".replaceAll(~'.fast[aq].contamination(.fast[aq].gz)$', '$1') :
            fn
      }
    )
  }

  input:
  tuple val(name), path(keep_read_name_list), val(mapped), path(reads_mapped), val(unmapped), path(reads_unmapped)

  output:
  tuple val(name), val(mapped), path(reads_mapped, includeInputs: true), emit: mapped_no_keep
  tuple val(name), val(unmapped), path(reads_unmapped, includeInputs: true), emit: unmapped_keep

  script:
  if ( params.lib_pairedness == 'paired' ) {
    """
    zcat ${reads_mapped[0]} | paste - - - - | grep -v -F -f ${keep_read_name_list} | tr "\t" "\n" | pigz -fc -p ${task.cpus} > ${reads_mapped[0]}
    zcat ${reads_mapped[0]} | paste - - - - | grep -F -f ${keep_read_name_list} | tr "\t" "\n" | pigz -fc -p ${task.cpus} >> ${reads_unmapped[0]}
    zcat ${reads_mapped[1]} | paste - - - - | grep -v -F -f ${keep_read_name_list} | tr "\t" "\n" | pigz -fc -p ${task.cpus} > ${reads_mapped[1]}
    zcat ${reads_mapped[1]} | paste - - - - | grep -F -f ${keep_read_name_list} | tr "\t" "\n" | pigz -fc -p ${task.cpus} >> ${reads_unmapped[1]}
    """
  } else if ( params.lib_pairedness == 'single' ) {
    """
    zcat ${reads_mapped} | paste - - - - | grep -v -F -f ${keep_read_name_list} | tr "\t" "\n" | pigz -fc -p ${task.cpus} > ${reads_mapped}
    zcat ${reads_mapped} | paste - - - - | grep -F -f ${keep_read_name_list} | tr "\t" "\n" | pigz -fc -p ${task.cpus} >> ${reads_unmapped}
    """
  } else {
    error "Invalid mode: ${params.lib_pairedness}"
  }
  stub:
  """
  touch ${reads_unmapped} ${reads_mapped}
  """
}

process bbduk_stats {
  label 'smallTask'

  publishDir (
    path: "${params.output}/intermediate",
    mode: params.publish_dir_mode,
    pattern: "*.bbduk_stats.tsv",
    overwrite: false,
    saveAs: { fn ->
          fn.startsWith("keep_") ? "map-to-keep/${fn.replaceAll(~'^keep_', '')}" : "map-to-remove/${fn}"
    }
  )

  input:
  tuple val(name), path (bbdukStats)

  output:
  tuple val(name), path ("${name}.stats.txt")
  path("${name}.bbduk_stats.tsv"), emit: tsv

  script:
  """
  TOTAL=\$(grep '#Total' ${bbdukStats} | awk -F '\\t' '{print \$2}')
  MNUM=\$(grep '#Matched' ${bbdukStats} | awk -F '\\t' '{print \$2}')
  MPER=\$(grep '#Matched' ${bbdukStats} | awk -F '\\t' '{print \$3}')

  FA=\$(awk -F '\\t' '/^[^#]/ {print "\\t\\t"\$2" ("\$3") aligned to "\$1}' ${bbdukStats})

  touch ${name}.stats.txt
  cat <<EOF >> ${name}.stats.txt
  \$TOTAL reads in total; of these:
  \t\$MNUM (\$MPER) reads were properly mapped; of these:
  \$FA
  EOF

  touch ${name}.bbduk_stats.tsv
  cat <<EOF >> ${name}.bbduk_stats.tsv
  Sample Name\tClean reads\tMapped reads
  ${name}\t\$((\$TOTAL-\$MNUM))\t\$MNUM
  EOF
  """
  stub:
  """
  touch ${name}.stats.txt ${name}.bbduk_stats.tsv
  """
}
