## Target workflows

| #   | Workflow                      | Single node | Multi node | Multi-node + tracing |
| --- | ----------------------------- | ----------- | ---------- | -------------------- |
| 1   | 1000genome-workflow           |             |            |                      |
| 2   | biobb_wf_md_setup             |             |            |                      |
| 3   | chipseq                       |             |            |                      |
| 4   | DeepDriveMD-pipeline          |             |            |                      |
| 5   | dna-seq-gatk-variant-calling  |             |            |                      |
| 6   | dna-seq-varlociraptor         |             |            |                      |
| 7   | metaGEM                       |             |            |                      |
| 8   | Montage                       |             |            |                      |
| 9   | nf-core_airrflow              |             |            |                      |
| 10  | nf-core_ampliseq              |             |            |                      |
| 11  | nf-core_atacseq               |             |            |                      |
| 12  | nf-core_bacass                |             |            |                      |
| 13  | nf-core_circdna               |             |            |                      |
| 14  | nf-core_clipseq               |             |            |                      |
| 15  | nf-core_createtaxdb           |             |            |                      |
| 16  | nf-core_cutandrun             |             |            |                      |
| 17  | nf-core_deepvariant           |             |            |                      |
| 18  | nf-core_demultiplex           |             |            |                      |
| 19  | nf-core_detaxizer             |             |            |                      |
| 20  | nf-core_differentialabundance |             |            |                      |
| 21  | nf-core_dualrnaseq            |             |            |                      |
| 22  | nf-core_fetchngs              |             |            |                      |
| 23  | nf-core_funcscan              |             |            |                      |
| 24  | nf-core_genomeqc              |             |            |                      |
| 25  | nf-core_hic                   |             |            |                      |
| 26  | nf-core_mag                   |             |            |                      |
| 27  | nf-core_methylseq             |             |            |                      |
| 28  | nf-core_mhcquant              |             |            |                      |
| 29  | nf-core_nascent               |             |            |                      |
| 30  | nf-core_pathogensurveillance  |             |            |                      |
| 31  | nf-core_proteinfold           |             |            |                      |
| 32  | nf-core_quantms               |             |            |                      |
| 33  | nf-core_rnaseq                |             |            |                      |
| 34  | nf-core_sarek                 |             |            |                      |
| 35  | nf-core_scnanoseq             |             |            |                      |
| 36  | nf-core_scrnaseq              |             |            |                      |
| 37  | nf-core_smrnaseq              |             |            |                      |
| 38  | nf-core_spatialvi             |             |            |                      |
| 39  | nf-core_taxprofiler           |             |            |                      |
| 40  | nf-core_tumourevo             |             |            |                      |
| 41  | nf-core_viralintegration      |             |            |                      |
| 42  | nf-core_viralrecon            |             |            |                      |
| 43  | PyFLEXTRKR                    |             |            |                      |
| 44  | rna-seq-star-deseq2           |             |            |                      |
| 45  | V-pipe                        |             |            |                      |
| 46  | nf-core_eager                 |             |            |                      |
| 47  | iwc                           |             |            |                      |
| 48  | lammps                        |             |            |                      |
| 49  | nwchem                        |             |            |                      |
| 50  | parsl                         |             |            |                      |
| 51  | pegasus                       |             |            |                      |
| 52  | PtychoNN                      |             |            |                      |
| 53  | radical.pilot                 |             |            |                      |

## Repositories to clone

Most workflows are included as git submodules in the project repository. The following are **not** submodules and must be `git clone`d from the internet:

|Repo|URL|Purpose|
|---|---|---|
|lammps|https://github.com/lammps/lammps|Molecular dynamics simulator|
|nwchem|https://github.com/nwchemgit/nwchem|Computational chemistry|
|parsl|https://github.com/Parsl/parsl|Parallel scripting library|
|pegasus|https://github.com/pegasus-isi/pegasus|Workflow management system|
|PtychoNN|https://github.com/mcherukara/PtychoNN|Neural network ptychography|
|radical.pilot|https://github.com/radical-cybertools/radical.pilot|HPC pilot framework|

Everything not in this table is a submodule and should already be present in the project repository.
