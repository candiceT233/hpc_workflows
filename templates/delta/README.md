# Delta run templates

Per-workflow `run_slurm.{datalife,darshan}.sh` and matching `*.nf.config`
files for running the WIDGET I/O profiling pipeline on the NCSA Delta HPC
cluster. Cloned from `/scratch/bekn/mtang9/runs/` snapshots that produced
working trace output on 2026-05-13.

## Layout assumed by the scripts

```
/scratch/bekn/mtang9/
├── widget-v1/profiler/datalife/flow-monitor/build/src/libmonitor.so
├── tools/darshan/lib/libdarshan.so
├── bin/nextflow
├── hpc_workflows/   (this repo)
├── data/<workflow>/small/...
└── runs/<workflow>/small_1n32c_<profiler>/
```

`/projects/bekn` is excluded — the project's NSF taiga quota is at the
hard cap (540 G of 550 G) with expired grace, so writes there fail.
Everything WIDGET-related lives under `/scratch/bekn/mtang9/`.

## SLURM defaults

```
--account=bekn-delta-cpu
--partition=cpu-preempt
--nodes=1 --ntasks=1 --cpus-per-task=32 --mem=64G
--time=01:30:00
```

`cpu-preempt` is half the SU rate of `cpu` (CPU=500 vs 1000 weight) at
the cost of being preemptable. For 32 cores × 1.5 h cap that's ~24 SU
worst case; jobs typically finish in 2–10 min for test profile so the
real bill is well under 1 SU each. Use `cpu` instead if preemption
during long runs would lose too much progress.

## Nextflow version

Pinned to `NXF_VER=25.10.5` because:
- Nextflow 26.04+ has a stricter config parser that breaks nf-core
  pipelines using `def varname = ...` at config top level (observed on
  methylseq 2.7.0 and 4.2.0).
- Nextflow 24.10 LTS lacks the nf-schema 2.5.1 plugin that newer
  pipelines require (`Plugin nf-schema@2.5.1 requires Nextflow
  version >=25.04.0`).
- 25.10.5 is the Goldilocks: parses everything and ships nf-schema.

## Apptainer LD_PRELOAD injection

Nextflow's task wrapper runs `env -` before invoking
`singularity exec`, wiping any `LD_PRELOAD` or `APPTAINERENV_*` set on
the host. To get libmonitor.so / libdarshan.so loaded inside the
container, we use Apptainer's `--env` flag through Nextflow's
`singularity.runOptions`. See `datalife.nf.config` and
`darshan.nf.config` for the exact incantation.

We also bind `/scratch/bekn/mtang9` so the host-built `.so` files are
accessible inside containers (default bind is only `/etc/localtime` +
`/etc/hosts` on Delta).

## Known issue: glibc ABI mismatch (exit 127)

`libmonitor.so` and `libdarshan.so` are built on the host (RHEL 9.4,
glibc 2.34). Some BioContainers built on older bases (Debian bullseye,
glibc 2.31) refuse to load the host-built `.so` and exit with `127`
(command-not-found cascade through the dynamic linker).

Observed on:
- nf-core/methylseq 4.2.0 FASTQC container — exit 127 with libmonitor

Workarounds (not yet validated):
1. Build `libmonitor.so` against an older glibc using a chroot or
   container.
2. Run with `-profile conda` instead of `-profile singularity` to skip
   containers entirely (requires Miniconda install).
3. Selectively whitelist which processes get LD_PRELOAD via Nextflow's
   `process.withName` selectors, skipping problem containers.

## Reuse pattern

To run a different workflow:
1. Copy the most-similar template, rename the workflow.
2. Update `nextflow run <workflow>` + the `-r <release>` tag.
3. Adjust `DATALIFE_FILE_PATTERNS` to match the workflow's expected
   output file extensions (the trimming/alignment/QC suffixes).
4. Update the `RUN_DIR` path + the `#SBATCH --output/--error` lines.
5. `bash -n` to syntax-check; submit with `sbatch`.

The DataLife and Darshan configs (`*.nf.config`) are reusable across
workflows without modification.
