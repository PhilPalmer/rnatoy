/*
 * Copyright (c) 2013-2017, Centre for Genomic Regulation (CRG) and the authors.
 *
 *   This file is part of 'RNA-Toy'.
 *
 *   RNA-Toy is free software: you can redistribute it and/or modify
 *   it under the terms of the GNU General Public License as published by
 *   the Free Software Foundation, either version 3 of the License, or
 *   (at your option) any later version.
 *
 *   RNA-Toy is distributed in the hope that it will be useful,
 *   but WITHOUT ANY WARRANTY; without even the implied warranty of
 *   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *   GNU General Public License for more details.
 *
 *   You should have received a copy of the GNU General Public License
 *   along with RNA-Toy.  If not, see <http://www.gnu.org/licenses/>.
 */

/*
 * Proof of concept Nextflow based RNA-Seq pipeline
 *
 * Authors:
 * Paolo Di Tommaso <paolo.ditommaso@gmail.com>
 * Emilio Palumbo <emiliopalumbo@gmail.com>
 */


/*
 * Defines some parameters in order to specify the refence genomes
 * and read pairs by using the command line options
 */
//params.reads = "$baseDir/data/ggal/*_{1,2}.fq"
params.reads="$baseDir/data/ggal/"
params.readsExtension="fq"
allReads="${params.reads}/*_{1,2}.${params.readsExtension}"

System.out.println(allReads)

params.annot = "$baseDir/data/ggal/ggal_1_48850000_49020000.bed.gff"
params.genome = "$baseDir/data/ggal/ggal_1_48850000_49020000.Ggal71.500bpflank.fa"
params.outdir = 'results'
params.multiqc_config = "$baseDir/multiqc_config.yaml"
multiqc_config = file(params.multiqc_config)
params.skip_multiqc = false

log.info """\
         R N A T O Y   P I P E L I N E
         =============================
         genome: ${params.genome}
         annot : ${params.annot}
         reads : ${params.reads}
         outdir: ${params.outdir}
         """
         .stripIndent()

/*
 * the reference genome file
 */
genome_file = file(params.genome)
annotation_file = file(params.annot)

/*
 * Create the `read_pairs` channel that emits tuples containing three elements:
 * the pair ID, the first read-pair file and the second read-pair file
 */
Channel
    .fromFilePairs( allReads )
    .ifEmpty { error "Cannot find any reads matching: ${params.reads}" }
    .set { read_pairs }

/*
 * Step 1. Builds the genome index required by the mapping process
 */
process buildIndex {
    tag "$genome_file.baseName"

    input:
    file genome from genome_file

    output:
    file 'genome.index*' into genome_index

    """
    bowtie2-build --threads ${task.cpus} ${genome} genome.index
    """
}

/*
 * Step 2. Maps each read-pair by using Tophat2 mapper tool
 */
process mapping {
    tag "$pair_id"

    input:
    file genome from genome_file
    file annot from annotation_file
    file index from genome_index
    set pair_id, file(reads) from read_pairs

    output:
    set pair_id, "accepted_hits.bam" into bam
    file "*" into tophat_results

    """
    tophat2 -p ${task.cpus} --GTF $annot genome.index $reads
    mv tophat_out/accepted_hits.bam .
    """
}

/*
 * Step 3. Assembles the transcript by using the "cufflinks" tool
 */
process makeTranscript {
    tag "$pair_id"
    publishDir params.outdir, mode: 'copy'

    input:
    file annot from annotation_file
    set pair_id, file(bam_file) from bam

    output:
    set pair_id, file('transcript_*.gtf') into transcripts

    """
    cufflinks --no-update-check -q -p $task.cpus -G $annot $bam_file
    mv transcripts.gtf transcript_${pair_id}.gtf
    """
}

process workflow_summary_mqc {

    when:
    !params.skip_multiqc

    output:
    file 'workflow_summary_mqc.yaml' into workflow_summary_yaml

    exec:
    def yaml_file = task.workDir.resolve('workflow_summary_mqc.yaml')
    yaml_file.text  = """
    id: 'lifebit-ai/rnatoy'
    description: " - this information is collected when the pipeline is started."
    section_name: 'lifebit-ai/rnatoy Workflow Summary'
    section_href: 'https://github.com/lifebit-ai/rnatoy'
    plot_type: 'html'
    """.stripIndent()
}

/*
 * STEP 12 MultiQC
 */
process multiqc {
    publishDir "${params.outdir}/MultiQC", mode: 'copy'

    container 'maxulysse/multiqc:1.0'

    when:
    !params.skip_multiqc

    input:
    file multiqc_config
    file ('tophat/tophat*') from tophat_results.collect().ifEmpty([])
    file ('workflow_summary/*') from workflow_summary_yaml.collect()

    output:
    file "*multiqc_report.html" into multiqc_report
    file "*_data"

    script:
    rtitle = "--title \"lifebit-ai/rnatoy\""
    rfilename = "--filename " + "_multiqc_report"
    """
    multiqc . -f $rtitle $rfilename --config $multiqc_config \\
        -m custom_content -m tophat
    """
}

workflow.onComplete {
	println ( workflow.success ? "Done!" : "Oops .. something went wrong" )
}
