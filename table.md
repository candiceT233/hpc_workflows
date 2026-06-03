## Target workflows

| #   | Workflow                      | Single node | Multi node | Multi-node + tracing |
| --- | ----------------------------- | ----------- | ---------- | -------------------- |
| 1   | 1000genome-workflow           | pass        | pass       |                      |
| 2   | biobb_wf_md_setup             | pass        | pass       | needs rerun          |
| 3   | chipseq                       |             |            |                      |
| 4   | DeepDriveMD-pipeline          | pass        | pass       | fail                 |
| 5   | dna-seq-gatk-variant-calling  | pass        |            |                      |
| 6   | dna-seq-varlociraptor         | pass        | pass       | fail                 |
| 7   | metaGEM                       | pass        |            |                      |
| 8   | Montage                       | pass        | pass       | needs rerun          |
| 9   | nf-core_airrflow              | fail        |            |                      |
| 10  | nf-core_ampliseq              | fail        |            |                      |
| 11  | nf-core_atacseq               | fail        |            |                      |
| 12  | nf-core_bacass                | fail        |            |                      |
| 13  | nf-core_circdna               | fail        |            |                      |
| 14  | nf-core_clipseq               |             |            |                      |
| 15  | nf-core_createtaxdb           | fail        |            |                      |
| 16  | nf-core_cutandrun             | fail        |            |                      |
| 17  | nf-core_deepvariant           | fail        |            |                      |
| 18  | nf-core_demultiplex           | fail        |            |                      |
| 19  | nf-core_detaxizer             | fail        |            |                      |
| 20  | nf-core_differentialabundance |             |            |                      |
| 21  | nf-core_dualrnaseq            | fail        |            |                      |
| 22  | nf-core_fetchngs              | pass        |            |                      |
| 23  | nf-core_funcscan              | pass        |            |                      |
| 24  | nf-core_genomeqc              | fail        | fail       |                      |
| 25  | nf-core_hic                   | unknown     |            |                      |
| 26  | nf-core_mag                   | fail        |            |                      |
| 27  | nf-core_methylseq             | unknown     |            |                      |
| 28  | nf-core_mhcquant              | fail        | unknown    |                      |
| 29  | nf-core_nascent               | fail        | fail       |                      |
| 30  | nf-core_pathogensurveillance  | fail        |            |                      |
| 31  | nf-core_proteinfold           | fail        |            |                      |
| 32  | nf-core_quantms               | fail        |            |                      |
| 33  | nf-core_rnaseq                | fail        | pass       |                      |
| 34  | nf-core_sarek                 | fail        |            |                      |
| 35  | nf-core_scnanoseq             |             |            |                      |
| 36  | nf-core_scrnaseq              | fail        |            |                      |
| 37  | nf-core_smrnaseq              | fail        | fail       |                      |
| 38  | nf-core_spatialvi             | fail        |            |                      |
| 39  | nf-core_taxprofiler           | pass        |            |                      |
| 40  | nf-core_tumourevo             | fail        |            |                      |
| 41  | nf-core_viralintegration      |             |            |                      |
| 42  | nf-core_viralrecon            | fail        | fail       |                      |
| 43  | PyFLEXTRKR                    | pass        | pass       | fail                 |
| 44  | rna-seq-star-deseq2           | pass        | pass       | needs rerun          |
| 45  | V-pipe                        |             |            |                      |
| 46  | nf-core_eager                 |             |            |                      |
| 47  | iwc                           | pass        |            |                      |
| 48  | lammps                        | pass        |            |                      |
| 49  | nwchem                        | pass        | pass       | needs rerun          |
| 50  | parsl                         | pass        | pass       | needs rerun          |
| 51  | pegasus                       | pass        | pass       | needs rerun          |
| 52  | PtychoNN                      | pass        | pass       | needs rerun          |
| 53  | radical.pilot                 | pass        | pass       | needs rerun          |

## Multi-node tracing verification

Verification script: `scripts/verify_profiled_run_widget.py`

Full machine-readable outputs:

- `summaries/widget_profiled_verification.tsv`
- `summaries/widget_profiled_verification.json`

The widget `delta` branch adds stricter DataLife correctness checks. Older DataLife block traces in these completed runs generally contain only `io_blk_range`; the new verifier requires `file_name`, `pid`, and `monitor_timer.*.datalife.json`. Therefore, workflow success plus Darshan success is not enough to keep the `Multi-node + tracing` column marked as pass under the new semantics.

| Workflow | Run | Workflow | DataLife | Darshan | Result | Note |
| --- | --- | --- | --- | --- | --- | --- |
| DeepDriveMD-pipeline | 4node-profiled-19327 | pass | needs rerun | fail | fail | Darshan has 2 parse failures; DataLife old schema |
| Montage | 4node-profiled-19055 | pass | needs rerun | pass | needs rerun | DataLife old schema |
| PtychoNN | 4node-profiled-19082 | pass | needs rerun | pass | needs rerun | DataLife old schema |
| PyFLEXTRKR | 4node-profiled-19324 | fail | fail | fail | fail | Slurm log has `BAD TERMINATION`; no block traces or Darshan logs |
| biobb_wf_md_setup | 4node-profiled-19230 | pass | needs rerun | pass | needs rerun | DataLife old schema |
| dna-seq-varlociraptor | 4node-profiled-19531 | unknown | needs rerun | fail | fail | No clear workflow success marker; no non-empty Darshan logs |
| nwchem | 4node-profiled-19229 | pass | needs rerun | pass | needs rerun | DataLife old schema |
| parsl | 4node-profiled-19101 | pass | needs rerun | pass | needs rerun | DataLife old schema |
| pegasus | 4node-profiled-19053 | pass | needs rerun | pass | needs rerun | DataLife old schema |
| radical.pilot | 4node-profiled-19080 | pass | needs rerun | pass | needs rerun | DataLife old schema |
| rna-seq-star-deseq2 | 4node-profiled-19330 | pass | needs rerun | pass | needs rerun | DataLife old schema |

Current tracing verification counts: 8 `needs rerun`, 3 `fail`, 0 `pass`.

`PyFLEXTRKR` profiled rerun job `20181` completed and still failed with `BAD TERMINATION`, so this is not only an old-widget verification issue.

## Completed reruns, May 22-24

Slurm accounting is disabled on Ares, so these statuses are based on files under `runs/`. `squeue` is currently empty for `jcernudagarcia`; every job in the 20181-20206 rerun batch wrote a terminal log or run directory.

| Job | Workflow | Mode | Status | Evidence |
| --- | --- | --- | --- | --- |
| 20181 | PyFLEXTRKR | trace | fail | `BAD TERMINATION` in `runs/PyFLEXTRKR/slurm-20181-4node-profiled.out` |
| 20182 | nf-core_airrflow | single | fail | Missing expected AIRRFlow input path |
| 20183 | nf-core_ampliseq | single | fail | Nextflow process failure in QIIME2 taxonomy preparation |
| 20184 | nf-core_atacseq | single | fail | Pipeline parameter validation failed |
| 20185 | nf-core_bacass | single | fail | Nextflow process failure in KmerFinder download/summary |
| 20186 | nf-core_circdna | single | fail | Nextflow process failure in Unicycler |
| 20187 | nf-core_createtaxdb | single | fail | Pipeline parameter validation failed |
| 20188 | nf-core_cutandrun | single | fail | Missing/unavailable iGenomes Bowtie2 index URI |
| 20189 | nf-core_deepvariant | single | fail | Nextflow execution cancelled after process failures |
| 20190 | nf-core_demultiplex | single | fail | Nextflow process failure in `UNTAR_FLOWCELL` |
| 20191 | nf-core_dualrnaseq | single | fail | Failed to create Conda environment |
| 20192 | nf-core_genomeqc | multi | fail | Internal Nextflow trace has 57 `COMPLETED`, 1 `ABORTED`; `.nextflow.log` says session aborted |
| 20193 | nf-core_mag | single | fail | Nextflow process failure in `NANOPLOT_RAW` |
| 20194 | nf-core_mhcquant | multi | unknown | Internal trace has 34 `COMPLETED`, but `.nextflow.log` says session aborted |
| 20195 | nf-core_nascent | multi | fail | Internal trace has 136 `COMPLETED`, 1 `ABORTED`, 1 `RUNNING`; session aborted |
| 20196 | nf-core_pathogensurveillance | single | fail | Nextflow process failure in Flye nanopore assembly |
| 20197 | nf-core_proteinfold | single | fail | Nextflow process failure in ColabFold FASTA conversion |
| 20198 | nf-core_quantms | single | fail | Input file URI does not exist |
| 20199 | nf-core_rnaseq | multi | pass | `.nextflow.log` reports pipeline completed successfully |
| 20200 | nf-core_sarek | single | fail | Nextflow process failure in Mutect2 pileup summaries |
| 20201 | nf-core_scrnaseq | single | fail | STAR genome index version incompatible with STAR runtime |
| 20202 | nf-core_smrnaseq | multi | fail | Internal trace has 30 `COMPLETED`, 1 `FAILED` |
| 20203 | nf-core_spatialvi | single | fail | Nextflow process failure in Space Ranger input untar |
| 20204 | nf-core_taxprofiler | single | pass | Slurm log reports pipeline completed successfully; `Succeeded : 4` |
| 20205 | nf-core_tumourevo | single | fail | Forked VEP process died during cross-process communication |
| 20206 | nf-core_viralrecon | multi | fail | Internal trace has 52 `COMPLETED`, 1 `FAILED` |

What is still missing: blank cells in the target table have not been proven by a completed run on disk; `unknown` cells have output evidence but not enough to mark pass or fail confidently; `needs rerun` tracing cells require rerunning with the rebuilt widget/DataLife library to satisfy the new trace correctness schema.

## Submitted reruns, June 3

Submission manifest: `summaries/submitted_multinode_and_trace_20260603_171908.tsv`

Submitted 49 exclusive 4-node jobs:

- 35 `multi_blank` jobs to fill blank `Multi node` cells.
- 14 `trace_for_multi_pass_or_unknown` jobs for workflows whose `Multi node` status is `pass` or `unknown`.

Slurm job range: `20600-20648`.

At submission time, jobs `20600-20603` started immediately and the rest were pending for `Resources` or `Priority`.
