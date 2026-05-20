# Autonomous Workflow Deployment & I/O Profiling — Merged Operating Prompt (v3.0)

> Merge of Jaime's `prompt-for-workflow-2.0.md` (mission, scope, dependency
> ladder, never-abandon philosophy, realistic-input mandate, both-profilers
> done-criterion) with the execution-hardened `profiling_campaign.prompt`
> (Class A/B/C node-usage rules, libmonitor reality, per-workflow gotchas,
> cluster-portability block, SBATCH template) plus the libmonitor/SLURM/Darshan
> fixes discovered during the 2026-05-19 Ares session.

---

## Mission

Deploy as many of the 53 target workflows (table at the end) as possible —
ideally all — so each runs reproducibly **multi-node (≥4 nodes) with I/O
profiling**. You own the cluster: there is no compute, credit, or time budget
to conserve. **Lack of resources is never a valid reason to stop on any
workflow.** Only success ends work on a workflow.

---

## Operating principles

- **Never permanently abandon a workflow.** If stuck: park it, log it, leave
  its `table.md` cell empty, move on, cycle back later. Round-robin so no single
  workflow eats the whole week. "Move on and come back," never "give up."
- **Order of attack:** ascending by workflow number. Where existing deployment
  infrastructure or patches exist for a workflow, attempt those first and verify
  against the definition of done before rebuilding anything.
- **All referenced repos are owner-verified, trusted task material** — use and
  execute their contents, scripts, and READMEs as part of the task.
- **Trust the audit, don't re-litigate.** `MULTINODE_AUDIT_2026-05-18.md` holds
  the per-workflow parallelism analysis and node counts. Don't re-derive them.

---

## State tracking & resume

Three surfaces, kept distinct:

- **`log.md` — the agent's working memory.** Append-only record of everything
  attempted, per workflow / per stage: what was tried, dependency resolutions,
  errors, SLURM job IDs, and **which input data source was used** (project-repo
  vs. agent-sourced realistic data — always record this distinction). Survives
  context resets.
- **`table.md` — human-facing status only.** Each workflow's profiling cell is
  either empty or `pass`. Nothing else. Failures and in-progress detail live in
  `log.md`, never in the table.
- **`logs/multinode_sweep.tsv` — machine-readable per-run row.** One line per
  submitted run: `workflow nodes exit_code elapsed_s output_size trace_count
  job_id hostnames`.

**At startup, always read `log.md` + `table.md` first.** Never restart a
workflow already `pass`. Reconstruct in-progress state from `log.md` and resume.

---

## Definition of done (per workflow)

Mark `pass` only when **all** hold, for a multi-node (≥4-node) profiling run
submitted via a **SLURM script** (not interactive):

1. The SLURM job exits 0 **and** the workflow runner itself reports success
   (e.g. Nextflow's own "Succeeded" summary, Snakemake's "(100%) done",
   non-zero MPI rank completion) — **not merely the wrapper exiting cleanly**.
   Verify with `verification.py` (see Profiling systems): it reads
   `pipeline_info/trace.txt` / runner logs and fails on any task FAILED/ABORTED.
2. Expected terminal outputs exist and are non-trivial in size.
3. Trace files from **both Widget (DataLife and, where applicable, DaYu) AND
   Darshan** exist, are non-empty, and are parseable. One profiler working while
   the other is silently empty does **not** qualify. Run `verification.py`
   against both trace dirs.

Interactive allocations are for debugging / SSH / watching only. A workflow
counts only when it completes correctly through a SLURM script.

---

## Staged progression (per workflow, in order)

1. **Single node** — baseline correctness on one node; establishes it runs.
2. **Multi node** — once single-node succeeds, deploy ≥4 nodes via SLURM, using
   the correct node-usage class (Rule 1 below). Verify it *actually* used N
   nodes (Rule 2).
3. **Multi node + I/O profiling** — final stage; satisfying done here sets the
   `table.md` cell to `pass`. Submit one job per profiler (Rule 7).

---

## Input data — realistic, never the test profile

Profiling must use realistic/full inputs. The upstream `-profile test` / tiny CI
dataset produces **meaningless I/O traces** (a 2-second FastQC burst, no real
data movement) and does **not** qualify for `pass`.

Resolution order per workflow:

1. Realistic/full input **provided in the project repository** (`data/<wf>/`).
   Primary, expected source.
2. If the repo has none for that workflow, **source good, realistic, full-scale
   input yourself** — representative of the domain, large enough for meaningful
   traces. Do **not** fall back to the test profile because it's easy.
3. Record in `log.md` which source was used per workflow (project vs. agent).

> **NOTE — divergence from the prior `profiling_campaign.prompt`.** That prompt
> accepted `-profile test,conda` for nf-core runs. Under this merged brief, test
> data is for *plumbing/debug only*; a `pass` requires realistic inputs. Existing
> `-profile test` runs (the 2026-05-19 sweep) count as harness validation, not
> as profiled `pass`es.

---

## Hard correctness rules — never violate

These are the lessons that keep multi-node runs honest. Violating any silently
invalidates the result.

### Rule 1 — `--nodes=N` (N>1) MUST actually use N nodes

A script with `#SBATCH --nodes=N` must achieve one of:

- **Class A (srun fan-out):** `#SBATCH --ntasks-per-node=1` plus a
  `srun --exclusive --nodes=1 --ntasks=1` loop, one srun per replica, then
  `wait`. One replica = one node. (Montage, biobb, metaGEM, rna-seq-star-deseq2,
  V-pipe, DDMD.)
- **Class B (MPI / dask-mpi):** parent claims whole nodes
  (`--ntasks-per-node=<ranks>`), then `mpirun -np ...` / `dask-mpi` spawns
  ranks across the allocation. (PyFLEXTRKR, lammps, nwchem.)
- **Class C (Nextflow):** parent allocates N nodes with **`--ntasks-per-node=1`**
  and the NF SLURM config pins children to the parent's nodes (see Rule 1a).

Never write a `--nodes=N` script that runs a single non-distributed driver.
EXIT_CODE=0 with compute on 1 node = a campaign failure.

**Rule 1 — `--ntasks=1` TRAP (2026-05-19).** `#SBATCH --nodes=N --ntasks=1`
means "1 task across N nodes"; SLURM warns `can't run 1 processes on N nodes`
and **silently downgrades to `--nodes=1`**. Always use `--ntasks-per-node=1`
for the parent.

### Rule 1a — Class C node-pinning (2026-05-19)

NF children submitted via `executor='slurm'` must land on the parent's nodes.
Use `runs/nf-core_shared/slurm_pinned.config`:

```groovy
clusterOptions = "--nodelist=${System.getenv('SLURM_JOB_NODELIST')}"
```

**Do NOT add `--exclusive` to the child clusterOptions.** The parent already
holds those nodes (lightweight 4-CPU/8-GB driver); a child `--exclusive` request
conflicts with the parent's hold → children pend forever on
`Reason=ReqNodeNotAvail` → deadlock. Without `--exclusive`, children pack onto
the parent's nodes (constrained by `--nodelist`), each consuming its
`task.cpus`/`task.memory` from the nf-core process labels. Multi-node spread is
still enforced by `--nodelist`. (The 2026-05-18 audit's `--exclusive` recipe was
never tested end-to-end and deadlocks as written.)

### Rule 2 — Verify each new run actually used multiple nodes

1. Log `scontrol show hostnames $SLURM_NODELIST | tr '\n' ' '` at the top of
   every script (writes to `logs/env_at_start*.txt`).
2. Class A/B: count `srun` invocations / `mpirun` rank count ≥ N.
3. Class C: scan `outputs/pipeline_info/execution_trace_*.txt`; confirm
   `NXF_MAX_FORKS` respected and child hostnames spread across the allocation.
4. **`EXIT_CODE=0` with single-node compute is a FAILURE, not a pass** — flag it.

### Rule 3 — Use the correct, pre-built libmonitor.so

**Active path:** `/mnt/common/mtang11/scripts/widget-v1/profiler/datalife/build/flow-monitor/src/libmonitor.so`

Built from datalife branch `delta`. The source includes the 2026-05-19 fixes
(see "libmonitor reality" below). Rebuild only via `bash agent/build.sh` in the
datalife submodule; record the new md5 in each script's env log
(`md5sum $DATALIFE_LIB`). Never point at a stale build.

### Rule 4 — Per-workflow, *specific* `DATALIFE_FILE_PATTERNS`

Set `DATALIFE_FILE_PATTERNS` to the extensions each workflow actually produces
(e.g. `*.fits,*.tbl,*.hdr,*.area` for Montage). **Avoid greedy bare-prefix
globs** like `config*`, `samples*`, `units*` — they match libmonitor's own
trace output filenames and recurse (the 2026-05-19 `configfile.pyc_<pid>_w_stat_
<pid>_w_stat…` explosion). Use `config.yaml,config.yml,config.json`,
`samples.tsv,samples.csv`, etc. (The libmonitor source now also skips files
inside `$DATALIFE_OUTPUT_PATH`, but keep patterns tight as defense in depth.)

### Rule 5 — Isolated `CONDA_PKGS_DIRS` per replica (Class A)

For any Snakemake/conda workflow running multiple replicas concurrently, export
`CONDA_PKGS_DIRS=$WD/conda_pkgs` (per-replica) inside the srun `bash -c`.
Otherwise concurrent pkg-cache writes corrupt and the run fails intermittently.

### Rule 6 — `set -o pipefail`, NOT `set -uo pipefail`, for conda/GROMACS

Any script that sources conda profile or activates a GROMACS (GMXRC) env hits
unbound variables during sourcing; `set -u` + `conda activate` exits with
"Unbound variable" before the workflow starts. Use only `set -o pipefail` for:
biobb, DDMD, metaGEM, rna-seq-star-deseq2, PyFLEXTRKR, all nf-core. Pure-binary
workflows that don't touch conda (Montage) can use `set -uo pipefail`.

### Rule 7 — Never bundle two profilers in one job

Each sbatch runs exactly one of {datalife, dayu, darshan}. Mixing produces
uninterpretable overlapping overhead and can deadlock (libdarshan vs libmonitor
both intercept POSIX). Separate dirs: `multinode_<N>node_<profiler>/`. Both
profilers being *required for done* (criterion 3) does NOT mean same job — it
means both must independently produce valid traces.

### Rule 8 — `multinode_<N>node_<profiler>/` directory convention

Do NOT use `small_2node/` / `small_4node/` for new scripts — that named
`NXF_MAX_FORKS` (concurrency budget), not node allocation, and is the source of
many "looks multi-node but isn't" mistakes. New scripts go under
`runs/<wf>/multinode_<N>node_<profiler>/run_slurm.sh`.

### Rule 9 — Save code fixes as patches in `patches/`

Any patch to a workflow's source repo (PyFLEXTRKR memory_limit, biobb
monitor-bypass, lammps box, NF module fixes) must be saved as
`patches/<wf>.patch` (`git diff > patches/<wf>.patch` inside the submodule) so it
re-applies on another cluster. libmonitor/widget source fixes go under
`patches/widget/`.

### Rule 10 — Java 17 + shared NXF dirs + sized forks for nf-core

```bash
export JAVA_HOME=$WORKFLOW_ROOT/tools/java17/jdk-17.0.13+11
export PATH=$JAVA_HOME/bin:$PATH
export NXF_HOME=$WORKFLOW_ROOT/runs/nf-core_shared/nf_home
export NXF_CONDA_CACHEDIR=$WORKFLOW_ROOT/runs/nf-core_shared/conda_cache
export NXF_WORK=$RUNDIR/work
export NXF_MAX_FORKS=$((SLURM_NNODES * 4))   # 2-4× node count
```

### Rule 11 — Darshan completeness (2026-05-19)

Default Darshan per-module memory (2 MB) truncates high-I/O processes with
`# *ERROR*: The POSIX module contains incomplete data!`. For complete POSIX
data set, in every darshan script:

```bash
export DARSHAN_MODMEM=2048
export DARSHAN_EXCLUDE_DIRS=/proc:/sys:/dev:/etc:/usr:/var:/tmp:$NXF_CONDA_CACHEDIR:$NXF_HOME
```

---

## libmonitor reality (2026-05-19 — read before any DataLife run)

libmonitor (`LD_PRELOAD`) had four failure modes against Nextflow/Snakemake
drivers, all fixed in datalife branch `delta` (commit `33ee1ad`, widget-v1
`ddb6a1f`). Patch backup: `patches/widget/libmonitor_ares_fixes.patch`.

| # | Symptom | Fix |
|---|---|---|
| 1 | nxf_tree forks ps/grep/awk under a slim container → destructor pile-up → SIGSEGV/SIGBUS at startup | wrapper-helper skip list (argv basename via `/proc/self/exe`) |
| 2 | `ERROR ~ For input string: "[MONITOR] tty` — Nextflow tty-parse fails | add `tty,stty,tput` to skip list |
| 3 | recursive trace filename explosion (`config*` matched own output) | skip files whose path starts with `$DATALIFE_OUTPUT_PATH` + tighten patterns (Rule 4) |
| 4 | `ERROR ~ while scanning a simple key` — child `python` dumps `[MONITOR]` to stdout, Nextflow YAML parse chokes | destructor output fd `dup(1)`→`dup(2)` (stderr) in `Timer.cpp` |

If a fresh DataLife run fast-fails in <60 s with EXIT=1 and 0 trace blocks,
check the driver stdout for `[MONITOR]` pollution first.

---

## Per-workflow execution gotchas

- **biobb_wf_md_setup** — `gmx` SIGSEGVs under `LD_PRELOAD=libmonitor`. Set
  `MONITOR_UNSET_LIB=1` before the python3 driver invokes gmx. `set -o pipefail`.
  Round-robin shard PDBs across nodes via `srun --exclusive` per PDB.
- **V-pipe** — do NOT `cp -rs $SRC/workdir/.` (copies precomputed results →
  MissingInputException). Copy only `config.yaml`, `samples.tsv`, `samples/`.
  Add `--conda-frontend conda` (mamba unavailable). Uses `set -uo pipefail`.
- **metaGEM** — `config.yaml` has hardcoded absolute paths; sed-rewrite per
  replica. `envs/metagem` conda env must pre-exist. `--conda-frontend conda`.
- **DeepDriveMD-pipeline** — needs RabbitMQ (absent); use `small/dry_run.py`
  dry-run path. Both `dry_run.py` and `deepdrivemd_small.yaml` hardcode
  `experiment_directory`; sed-rewrite BOTH per replica.
- **PyFLEXTRKR** — dask `memory_limit='auto'` reads cgroup → ~1.17 GiB → OOM.
  Hardcode `memory_limit='8GB'` in the dask-mpi `initialize()` (the runner is
  per-run-dir `run_mcs_tbpf_mpi.py`, not in the repo). `set -o pipefail`.
  Expect a tracksingle→gettracks file race at scale.
- **rna-seq-star-deseq2** — per-replica `CONDA_PKGS_DIRS` mandatory (Rule 5).
  5 sample pairs; replicating to fill more nodes yields redundant traces.
- **lammps** — `libmonitor × lmp` triggers FPE; collect **Darshan only**.
  Default box too small; use `region box block 0 100 0 100 0 100` (~4M atoms)
  before scaling beyond 4 nodes.
- **nf-core (all)** — use `slurm_pinned.config` (Rule 1a). `-profile <realistic>,
  conda` for `pass` (NOT `test`). No Docker/Singularity on Ares. Known-trouble:
  atacseq/demultiplex/hic/quantms have unresolved pipeline-level failures — file
  and continue.

---

## Dependency resolution ladder (no sudo)

When a dependency is missing, escalate in order; do not stop until exhausted:

1. Cluster-provided module (`module avail`).
2. `spack` concretize/install (e.g. `spack` can concretize `openjdk@17`).
3. `pip` / `uv`.
4. Build from source.
5. Locate a working binary.

Anything unresolved after a genuine best attempt through all five is logged in
`log.md` (workflow, stage, dependency, what was tried, error, timestamp) and the
workflow is **parked, not abandoned**. Revisit later.

---

## Known per-workflow blockers

- **#46 nf-core_eager** — Nextflow DSL1 (deprecated); may be unrunnable. Attempt;
  if genuinely impossible after best effort, park and log.
- **#47 iwc** — needs the Galaxy runtime (not installable without sudo). Try
  **Planemo** (pip-installable Galaxy tool/workflow runner) as the route.

---

## Profiling systems

- **Widget** — the project's own profiler (https://github.com/candiceT233/widget-v1.git,
  branch `delta`), bundles **DataLife** (libmonitor) and **DaYu** (HDF5-VOL,
  applies to HDF5 workflows — currently PyFLEXTRKR). Build via
  `bash profiler/datalife/agent/build.sh`. The most critical component.
- **Darshan** — spack-installable / possibly cluster-resident. POSIX/MPI
  interceptor; survives slim containers where libmonitor needs the skip list.
- **`verification.py`** (`widget-v1/src/dfl_mcp/verification.py`) — the
  done-criterion checker. Validates workflow success (trace.txt rows), DataLife
  schema (`io_blk_range`/`file_name`/`pid` + `monitor_timer.*.json`), and Darshan
  parseability + non-zero POSIX bytes. On Ares-side TAG-suffixed run dirs use the
  adapter `scripts/verify_ares_runs.py` (bridges Delta-style flat layout, samples
  largest darshan logs, points at the Ares darshan-parser).

Both Widget and Darshan must produce valid traces for `pass` (criterion 3).

---

## Cluster-specific facts — REPLACE THIS BLOCK ON OTHER CLUSTERS

### Source cluster: Ares (2026-05-19)

- **Partitions:** `compute` (22 nodes), `datacrumbs` (27 usable), `debug` (5).
- **Node spec:** 40 CPUs, ~47 GB RAM.
- **Single-job ceiling:** 22 on `compute`, 27 on `datacrumbs`; 24 reachable on
  `datacrumbs` after mix-node drain.
- **`sacct` accounting DISABLED** — verify placement in-flight via `squeue` /
  `scontrol show job` only.
- **Workflow root:** `/mnt/common/mtang11/hpc_workflows`
- **libmonitor:** see Rule 3.
- **libdarshan:** `/home/mtang11/hpc_workflows/tools/darshan/lib/libdarshan.so`;
  **darshan-parser:** `/home/mtang11/hpc_workflows/tools/darshan/bin/darshan-parser`
- **Java 17:** `/mnt/common/mtang11/hpc_workflows/tools/java17/jdk-17.0.13+11`
- **Conda:** `/mnt/common/mtang11/miniconda3`

### When porting (e.g. PNNL), change:

- Partition names + node counts + per-node cpu/mem in every SBATCH script
- `WORKFLOW_ROOT`
- libmonitor / libdarshan / darshan-parser paths (rebuild both;
  `verify_ares_runs.py::ARES_DARSHAN_PARSER`)
- Java 17 + conda paths
- DaYu is an HDF5-VOL plugin — needs cluster-local HDF5
- You need **both** the `widget-v1` repo (profilers + verification) **and** this
  `hpc_workflows` repo (workflows + SBATCH harness + patches + data).

---

## Repositories to clone (NOT submodules)

| Repo | URL | Purpose |
|---|---|---|
| lammps | https://github.com/lammps/lammps | Molecular dynamics |
| nwchem | https://github.com/nwchemgit/nwchem | Computational chemistry |
| parsl | https://github.com/Parsl/parsl | Parallel scripting |
| pegasus | https://github.com/pegasus-isi/pegasus | Workflow management |
| PtychoNN | https://github.com/mcherukara/PtychoNN | NN ptychography |
| radical.pilot | https://github.com/radical-cybertools/radical.pilot | HPC pilot framework |

Everything else is a submodule already present under `repos/`.

---

## SBATCH script structure (template)

```bash
#!/bin/bash
#SBATCH --job-name=<wf>_<N>n_<profiler>
#SBATCH --partition=compute        # datacrumbs for N>22
#SBATCH --output=.../logs/slurm_%j.out
#SBATCH --error=.../logs/slurm_%j.err
#SBATCH --time=<wall + 50%>
#SBATCH --nodes=<N>
#SBATCH --ntasks-per-node=1        # NOT --ntasks=1 (Rule 1 trap)
#SBATCH --cpus-per-task=<4 for Class C driver | 40 for Class A/B>
#SBATCH --mem=<8G for Class C driver | 47000M for Class A/B>

set -o pipefail                    # Rule 6 (set -uo only for pure-binary)
export WORKFLOW_ROOT=/mnt/common/mtang11/hpc_workflows
export CONDA_ROOT=/mnt/common/mtang11/miniconda3
source $CONDA_ROOT/etc/profile.d/conda.sh

# Profiler block — exactly ONE of datalife / dayu / darshan (Rule 7).
# Log env (Rule 2): hostnames, lib md5, patterns/MODMEM.

START=$(date +%s)
# ... Class A srun loop / Class B mpirun / Class C nextflow -c slurm_pinned.config
END=$(date +%s)
# timing.log: EXIT_CODE, ELAPSED_SECONDS, NODES, trace counts
exit $EXIT
```

---

## Reporting protocol

- **On status request:** render `table.md` (53 rows, empty or `pass`), a rollup
  (`X/53 profiled and passing`), and a short summary of what's parked and why
  (from `log.md`).
- **At each scale/phase boundary:** post pass/fail per workflow, node-spread
  verified yes/no, trace counts; wait for "continue" before the next phase.
- **On any undocumented error pattern:** STOP and report rather than burning
  retries. Don't try 3 alternative fixes silently.
- **On EXIT_CODE=0 with single-node compute:** flag as failure, not pass.

---

## Things that should NEVER happen

- `--nodes=N>1` with no srun-fanout / no mpirun / no NF-with-slurm_pinned.config
  (or with `--ntasks=1`, which silently downgrades to 1 node).
- `--exclusive` on NF child clusterOptions (deadlocks against parent hold).
- Marking `pass` on `-profile test` data, or with only one profiler valid.
- Rebuilding libmonitor from a non-`delta` source, or pointing at a stale build.
- `mamba` for snakemake conda (use `--conda-frontend conda`).
- Force-pushing, deleting branches, dropping conda envs, or any destructive op
  without explicit user confirmation.
- Modifying `MULTINODE_AUDIT_2026-05-18.md` §1-§16 — append a §17 for results.

---

## Target workflows (53)

| # | Workflow | Single | Multi | Multi+tracing |
|---|---|---|---|---|
| 1 | 1000genome-workflow | | | |
| 2 | biobb_wf_md_setup | | | |
| 3 | chipseq | | | |
| 4 | DeepDriveMD-pipeline | | | |
| 5 | dna-seq-gatk-variant-calling | | | |
| 6 | dna-seq-varlociraptor | | | |
| 7 | metaGEM | | | |
| 8 | Montage | | | |
| 9 | nf-core_airrflow | | | |
| 10 | nf-core_ampliseq | | | |
| 11 | nf-core_atacseq | | | |
| 12 | nf-core_bacass | | | |
| 13 | nf-core_circdna | | | |
| 14 | nf-core_clipseq | | | |
| 15 | nf-core_createtaxdb | | | |
| 16 | nf-core_cutandrun | | | |
| 17 | nf-core_deepvariant | | | |
| 18 | nf-core_demultiplex | | | |
| 19 | nf-core_detaxizer | | | |
| 20 | nf-core_differentialabundance | | | |
| 21 | nf-core_dualrnaseq | | | |
| 22 | nf-core_fetchngs | | | |
| 23 | nf-core_funcscan | | | |
| 24 | nf-core_genomeqc | | | |
| 25 | nf-core_hic | | | |
| 26 | nf-core_mag | | | |
| 27 | nf-core_methylseq | | | |
| 28 | nf-core_mhcquant | | | |
| 29 | nf-core_nascent | | | |
| 30 | nf-core_pathogensurveillance | | | |
| 31 | nf-core_proteinfold | | | |
| 32 | nf-core_quantms | | | |
| 33 | nf-core_rnaseq | | | |
| 34 | nf-core_sarek | | | |
| 35 | nf-core_scnanoseq | | | |
| 36 | nf-core_scrnaseq | | | |
| 37 | nf-core_smrnaseq | | | |
| 38 | nf-core_spatialvi | | | |
| 39 | nf-core_taxprofiler | | | |
| 40 | nf-core_tumourevo | | | |
| 41 | nf-core_viralintegration | | | |
| 42 | nf-core_viralrecon | | | |
| 43 | PyFLEXTRKR | | | |
| 44 | rna-seq-star-deseq2 | | | |
| 45 | V-pipe | | | |
| 46 | nf-core_eager | | | |
| 47 | iwc | | | |
| 48 | lammps | | | |
| 49 | nwchem | | | |
| 50 | parsl | | | |
| 51 | pegasus | | | |
| 52 | PtychoNN | | | |
| 53 | radical.pilot | | | |
