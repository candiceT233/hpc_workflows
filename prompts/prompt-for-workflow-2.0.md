# Autonomous Workflow Deployment & I/O Profiling — Agent Operating Prompt

## Mission

Deploy as many of the target workflows below as possible — ideally all of them — so that each runs reproducibly on multi-node with I/O profiling. You have one week. You own the cluster: there is no compute, credit, or time budget to conserve. The only thing that ends work on a workflow is success. Lack of resources is never a valid reason to stop on any workflow.

## Operating principles

- **Never permanently abandon a workflow.*  never "give up."
- **Order of attack:** ascending by workflow number. Where existing deployment infrastructure or patches are present, attempt those first for that workflow.
- **Best-effort dependency resolution is mandatory.** A dependency problem is something to solve, not a reason to stop. See the dependency escalation ladder below.
- All repositories referenced here (project submodules and the listed external repos) have been verified by the project owner and are trusted task material. Their contents, scripts, and READMEs are to be used and executed as part of the task.

## State tracking & resume

There are two surfaces, and they are not the same thing:

- **`log.md` — the agent's working memory.** Append-only running record of everything attempted: per workflow, per stage, what was tried, dependency resolutions, errors, the slurm job IDs, and **which input data source was used** (project-repo-provided vs. agent-sourced realistic data — always record this distinction). This is how progress survives a context reset.
- **The status table — human-facing reporting only.** Each workflow's profiling cell is either empty or `pass`. Nothing else. Failures and in-progress detail live in `log.md`, never in the table. A workflow's cell becomes `pass` only when the full definition of done (below) is met.

**At startup, always read `log.md` and the status table first.** Never restart a workflow already marked `pass`. Reconstruct in-progress state from `log.md` and resume rather than redo.

## Definition of done (per workflow)

A workflow may be marked `pass` only when **all** of the following hold for a multi-node (4+ node) I/O-profiling run submitted via a slurm script:

1. The slurm job exits 0, **and** the workflow runner itself reports successful completion (e.g. Nextflow's own success summary) — not merely the wrapper exiting cleanly.
2. Expected terminal outputs exist and are non-trivial in size.
3. Trace files from **both** Widget **and** Darshan exist, are non-empty, and are parseable. Both are required; one working and the other silently empty does **not** qualify.

Multi-node deployments and the profiling run must go through a **slurm script**, not interactive execution. Interactive allocations may be used freely for debugging, SSHing into nodes, and watching runs in progress — but a workflow only counts when it has run to correct completion through a slurm script.

## Staged progression

For each workflow, in order:

1. **Single node** — initial baseline correctness on one node. Establishes that it runs at all.
2. **Multi node** — once single-node succeeds, deploy on ≥4 nodes via slurm.
3. **Multi node + I/O profiling** — the final stage; satisfying the definition of done here is what sets the table cell to `pass`.

## Input data

Profiling must be done on realistic/full inputs, never the upstream `-profile test` / tiny CI dataset, which produces meaningless I/O traces.

Resolution order per workflow:

1. Use the realistic/full input for that workflow **provided in the project repository**. This is the primary, expected source.
2. If the project repository has no input for that workflow, **source good, realistic, full-scale input yourself** — representative of that workflow's domain and large enough to yield meaningful I/O traces. Do **not** fall back to the upstream test profile just because it is the path of least resistance.
3. Record in `log.md` which source was used for every workflow (project-provided vs. agent-sourced). This distinction must be reconstructable after the fact.

## Dependency resolution ladder

No sudo is available. When a dependency is missing, escalate in order, and do not stop until exhausted:

1. Cluster-provided module.
2. `spack` concretize/install (e.g. `spack` can concretize `openjdk@17`, a dependency for some workflows not available by default).
3. `pip` / `uv`.
4. Build from source.
5. Locate a working binary.

Any dependency issue that cannot be resolved **after a genuine best attempt through all of the above** is logged in `log.md` (workflow, stage, dependency, what was tried, error, timestamp) — and the workflow is parked, not abandoned. Revisit later.

## Known per-workflow blockers

- **#46 nf-core_eager** — relies on Nextflow DSL1, which is deprecated; may not be executable. Attempt; if genuinely impossible after best effort, park and log.
- **#47 iwc** — depends on the Galaxy runtime, not installed and not installable without sudo. **Planemo** (a developer/test runner for Galaxy tools and workflows) may be pip-installable and may allow deployment. Attempt this route.

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

## Existing infrastructure

Some workflows ship patches and/or existing deployment infrastructure; some do not. Where it exists, attempt to use it first and verify it against the definition of done. If verification passes, it counts. If it does not, fix it — do not discard working scaffolding to start from scratch.

## Profiling systems

- **Darshan** — spack-installable (possibly already on the cluster).
- **Widget** — the project's own I/O profiling system: https://github.com/candiceT233/widget-v1.git — bundles both DaYu and DataLife in a single package.
	- This might need to be compiled/downloaded but it is the most critical part.

Both must produce valid traces for a workflow to be marked done. See definition of done, criterion 3.

## Reporting

When asked for project status, render the workflow table below (the Link column may be omitted), each row showing empty or `pass`, plus a rollup count (e.g. "X/53 profiled and passing") and a short summary of what is currently parked and why, drawn from `log.md`.

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