process fastqc {
  label 'fastqc'

  input:
  tuple val(name), val(type), path(reads)

  output:
  tuple val(name), val(type), path("*_fastqc.zip"), emit: zip

  script:
  """
  fastqc --noextract -t ${task.cpus} ${reads}
  """
}

process nanoplot {
  label 'nanoplot'
  errorStrategy { task.exitStatus in 1 ? 'ignore' : 'terminate' }

  input:
  tuple val(name), val(type), path(reads)

  output:
  tuple val(name), path("*.html"), path("*.png"), path("*.pdf")
  tuple val(name), val(type), path("${name}_${type}_read_quality.txt"), emit: txt
  tuple val(name), val(type), path("${name}_${type}_read_quality_report.html"), emit: html
  
  script:
  """
  NanoPlot -t ${task.cpus} --fastq ${reads} --title ${name}_${type} --color darkslategrey --N50 --plots hex --loglength -f png --store
  NanoPlot -t ${task.cpus} --pickle NanoPlot-data.pickle --title ${name}_${type} --color darkslategrey --N50 --plots hex --loglength -f pdf
  mv NanoPlot-report.html ${name}_${type}_read_quality_report.html
  mv NanoStats.txt ${name}_${type}_read_quality.txt
  """
}

process format_nanoplot_report {
    label 'smallTask'
    
    input:
    tuple val(name), val(type), path(nanoplot_report)

    output:
    path("*_mqc.html")

    script:
    """
    sed -e '25,30d;34,45d' ${nanoplot_report} > ${nanoplot_report}.tmp
    echo "<!--" > tmp
    echo "id: 'nanoplot_${name}_${type}'" >> tmp
    echo "section_name: 'NanoPlot: ${name}, ${type}'" >> tmp
    echo "-->"  >> tmp
    cat tmp ${nanoplot_report}.tmp > ${nanoplot_report.baseName}_mqc.html
    rm -f *tmp
    """
}

process quast {
  label 'quast'
  errorStrategy { task.exitStatus in 4 ? 'ignore' : 'terminate' }

  input:
  tuple val(name), val(type), path(fasta)

  output:
  path("${name}_${type}_report.tsv"), emit: report_tsv
  path("quast_${name}_${type}")

  script:
  """
  quast.py -o quast_${name}_${type} -t ${task.cpus} ${fasta}
  cp quast_${name}_${type}/report.tsv ${name}_${type}_report.tsv
  """
}

process multiqc {
  label 'multiqc'
  label 'smallTask'
  
  publishDir "${params.output}/${params.multiqc_dir}", pattern: 'multiqc_report.html'
  
  input:
  path(config)
  path(fastqc)
  path(nanoplot)
  path(quast)
  path(mapping_stats)
    
  output:
  path "multiqc_report.html"
  
  script:
  """
  multiqc . -s -c ${config}
  """
}
