# Delta Bootstrap Guide

Handoff document for an agent (or person) bringing the WIDGET / Datalife / DaYu / Darshan trace-collection workflow up on the Delta HPC cluster, mirroring what's been validated on Ares.

> **Status as of 2026-05-06**: All workflows here have been validated on Ares at 2-node and (where indicated) 4-node scale. Delta port has not been started — this doc is the starting point.

---

## 1. What this project is

We profile HPC scientific workflows with three I/O tracers and use the resulting traces to validate / train AI agents that author WIDGET deployment documents.

Three profilers, three independent purposes:
| Profiler | What it captures | Where it lives |
|---|---|---|
| **DataLife** (`libmonitor.so`) | POSIX I/O via LD_PRELOAD; emits `*.blk_trace.json` per process | `widget-v1/profiler/datalife/flow-monitor` |
| **DaYu** | HDF5 VOL/VFD interceptor; emits HDF5 dataset / chunk traces | `widget-v1/profiler/dayu-tracker` |
| **Darshan** | Stock POSIX/MPI-IO/HDF5 stat aggregator; emits `*.darshan` log per rank | system-installed via Spack/module |

DaYu only applies to HDF5 workflows (PyFLEXTRKR is the only one in this corpus). Datalife + Darshan apply to everything.

## 2. The three repos involved

| Repo | Purpose | URL |
|---|---|---|
| **`hpc_workflows`** (this repo) | The 45 workflow submodules + run scripts + patches | https://github.com/candiceT233/hpc_workflows |
| **`widget-v1`** | Source of profiler libs (Datalife, DaYu) + shared utilities | https://github.com/candiceT233/widget-v1 |
| **`paper_widget`** | WIDGET document templates + agent prompts + notes | (private — request access if you need the templates) |

The bootstrap focuses on **`hpc_workflows` + `widget-v1`**; you can validate 4 workflows × 4 nodes without touching `paper_widget`.

## 3. Prerequisites on Delta

Before starting, confirm you have:

- [ ] **Delta SSH access** — host, username, SSH key set up
- [ ] **Allocation / project ID** for charging
- [ ] **Default partition name** (will be passed to `--partition` in SLURM scripts)
- [ ] **Project workspace path** (e.g., `/projects/<allocation>/<user>` — SCRATCH equivalent)
- [ ] **Internet egress** to GitHub from at least the login node (for `git clone`, conda/pip, nf-core data pulls)
- [ ] **Module system** — verify `module avail` works; identify GCC, OpenMPI, Python, conda, Singularity/Apptainer, Nextflow modules

Ask the user for these if unknown — don't guess.

## 4. Phase 0 — Clone the three repos

```bash
# On Delta login node, in your project workspace
cd /projects/<allocation>/<user>

git clone https://github.com/candiceT233/hpc_workflows.git
cd hpc_workflows
git submodule update --init --recursive
cd ..

git clone https://github.com/candiceT233/widget-v1.git
cd widget-v1
git submodule update --init --recursive   # pulls profiler/datalife and profiler/dayu-tracker
cd ..
```

Expected layout after Phase 0:
```
/projects/<allocation>/<user>/
├── hpc_workflows/
│   ├── repos/                      # 45 submodules (Snakemake, Nextflow, Python, Shell)
│   ├── patches/                    # 10 local patches to apply on top of submodules
│   ├── runs/                       # EMPTY — populated by SLURM scripts
│   └── data/                       # EMPTY — populated by scripts/download_inputs.sh
└── widget-v1/
    ├── profiler/datalife/          # libmonitor source
    └── profiler/dayu-tracker/      # DaYu source
```

## 5. Phase 1 — Build the profilers

### 5a. Build Datalife `libmonitor.so`

```bash
cd widget-v1/profiler/datalife/flow-monitor
mkdir -p build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
make -j8
ls -lh libmonitor.so   # should be present, ~1MB
md5sum libmonitor.so   # remember this md5 — used to verify identical builds across runs
```

Expected `libmonitor.so` MD5 from last Ares build: `a1540eb201fbabc4fc8aabd5ceb4becf` (recorded 2026-04-30 after merging upstream/main into candiceT233/main).

If the MD5 differs, verify your build flags match. Check `widget-v1/profiler/datalife/flow-monitor/CMakeLists.txt` for required compiler flags. The Datalife build is C++17 + pthread + zlib; if Delta's default `cmake` is too old (<3.18) load a newer cmake module first.

### 5b. Build DaYu (only if you'll profile PyFLEXTRKR)

```bash
cd widget-v1/profiler/dayu-tracker
# Build instructions are in profiler/dayu-tracker/README.md
# Typically: mkdir build && cd build && cmake .. && make -j8
# DaYu emits two libraries: libh5vol_tracker.so (VOL connector) and libh5vfd_tracker.so (VFD)
```

Defer this until after the 4-workflow bootstrap. DaYu had multiple `vfd_only_4node`-style debug iterations on Ares — if you don't need HDF5 traces for the first validation pass, skip.

### 5c. Verify Darshan availability

```bash
module avail darshan
module load darshan-runtime/<version>
echo $DARSHAN_RUNTIME_DIR
ls $DARSHAN_RUNTIME_DIR/lib/libdarshan.so
```

If Darshan isn't pre-installed on Delta, build via Spack:
```bash
spack install darshan-runtime+mpi
```

Record the path to `libdarshan.so` — you'll need it in the LD_PRELOAD for the run scripts.

## 6. Phase 2 — Adapt 4 SLURM scripts to Delta

The validation set:
| # | Workflow | Why this one | Expected wall time at 4n |
|---|---|---|---|
| 1 | Montage | Fastest smoke test. Shell/C/MPI binary chain. Validates libmonitor LD_PRELOAD on a non-Python tool. | ~30s |
| 2 | nf-core_methylseq | Canonical Nextflow workflow; DL+DH validated at 2n+4n on Ares. | ~30 min |
| 3 | nf-core_quantms | Tests `patches/nf-core_quantms.patch` application + DL+DH at 4n. | ~45 min |
| 4 | nf-core_atacseq | Highest Darshan yield (~50k traces at 2n on Ares); stress-tests Darshan toolchain. | ~60 min |

### What you need to change in each SLURM script

Each `runs/<workflow>/multinode_4node_<profiler>/run_slurm.<profiler>.4node.sh` (or similar) on Ares hard-codes:
- `#SBATCH --partition=ares` → change to **Delta partition name**
- `#SBATCH --account=<ares_account>` → change to **Delta allocation ID**
- `module load` lines for OpenMPI/conda/etc. → match Delta module names
- Path roots like `/mnt/common/mtang11/hpc_workflows/` → change to **Delta project workspace path**
- `LD_PRELOAD` path to `libmonitor.so` → use the Delta build path from Phase 1
- For Nextflow workflows: the `runs/nf-core_shared/slurm.config` references Ares partition → change

**Recommended approach**: rather than editing each script, do `find runs/<workflow> -name '*.sh' -o -name '*.config' | xargs sed -i 's|/mnt/common/mtang11|/projects/<alloc>/<user>|g'` and similar for partition/account, then verify by `grep` before submitting.

### Apply the patches first

Before running profiled jobs:
```bash
cd hpc_workflows
git apply patches/nf-core_quantms.patch     # for #3
# atacseq, methylseq don't need patches
# Montage doesn't need patches
```

Confirm the patch applied:
```bash
cd repos/nf-core_quantms
git status   # should show modified files matching patches/nf-core_quantms.patch
```

## 7. Phase 3 — Download test data

```bash
cd hpc_workflows
bash scripts/download_inputs.sh
```

This pulls test data for 8 nf-core pipelines. Ares had `data/` at ~52GB total; Delta will need similar disk on the project workspace.

For Montage and 1000genome the data layout is workflow-specific — check `runs/Montage/multinode_2node_*/README.md` and `runs/1000genome-workflow/run_*.sh` for input paths.

## 8. Phase 4 — Validate 4 workflows × 4 nodes

Run order matters: do them sequentially, not in parallel, so that profiler issues are isolated.

### 8.1 Montage (smoke)

```bash
cd runs/Montage/multinode_2node_datalife/      # Ares only had 2n; copy & adapt to 4n
sbatch run_slurm.datalife.2node.sh
# Watch: squeue -u $USER
# Wait for completion (typically <1 min on Ares; longer on Delta if env loads slow)
```

**Success criteria:**
- Job exits with code 0
- `mosaic.fits` file produced in output dir, size ≈ 19.3MB (Ares baseline: 19,278,720 bytes — should match exactly if data is identical)
- `datalife_traces_datalife_*node/` directory has ≥ 80 `*.blk_trace.json` files (Ares 2n had 82)
- `md5sum $(which libmonitor.so)` matches the build from Phase 1

If Montage fails, **stop here** and debug. Most likely causes: wrong Datalife path, wrong MPI module, missing C lib.

### 8.2 nf-core_methylseq (Nextflow + Datalife + Darshan)

```bash
cd runs/nf-core_methylseq/small_4node/

# Run 1: baseline (no profiler) — confirms the workflow itself runs on Delta
sbatch run_slurm.4node.sh

# Run 2: with Datalife
sbatch run_slurm.datalife.4node.sh

# Run 3: with Darshan
sbatch run_slurm.darshan.4node.sh
```

**Success criteria:**
- All 3 jobs exit with code 0
- Baseline run produces methylseq outputs (`results/`, `multiqc_report.html`)
- Datalife run: `datalife_traces_datalife_4node/*.blk_trace.json` count ≥ 80 (Ares 4n had 82)
- Darshan run: `*.darshan` files present (Ares 2n had 340)

### 8.3 nf-core_quantms (with patch)

Verify the patch is applied first:
```bash
cd /projects/<alloc>/<user>/hpc_workflows
git -C repos/nf-core_quantms diff --stat   # should show ~6 files modified
```

Then:
```bash
cd runs/nf-core_quantms/small_4node/
sbatch run_slurm.datalife.4node.sh
sbatch run_slurm.darshan.4node.sh
```

**Success criteria:**
- Both jobs exit 0
- Trace counts: DL ≥ 4 at 4n, DH ≥ 30 at 4n (per Ares baseline)

If the patch doesn't apply cleanly: the upstream commit on Delta clone may differ from Ares (unlikely since submodule pin is the same). Check `git -C repos/nf-core_quantms log -1` matches the pinned commit in `.gitmodules`.

### 8.4 nf-core_atacseq (Darshan high-volume)

```bash
cd runs/nf-core_atacseq/small_4node/
sbatch run_slurm.datalife.4node.sh   # Ares 4n: 21 blk_traces
sbatch run_slurm.darshan.4node.sh    # Ares 4n: 42,787 darshan files (huge!)
```

**Success criteria:**
- Both jobs exit 0
- Darshan run produces tens of thousands of `*.darshan` files — confirm filesystem can handle the metadata pressure

This run will be slow due to sheer file count. Expect 60–90 min on a Delta-class system. If your project filesystem has a metadata bottleneck, the Darshan run will surface it here — surface that to the user as a portability finding.

## 9. Phase 5 — Verify against Ares baseline

After all 4 are done, produce a comparison table:

| Workflow | Ares trace count | Delta trace count | Match? |
|---|---|---|---|
| Montage 2n DL | 82 | _____ | _____ |
| methylseq 4n DL | 82 | _____ | _____ |
| methylseq 2n DH | 340 | _____ | _____ |
| quantms 4n DL | 4 | _____ | _____ |
| quantms 4n DH | 30 | _____ | _____ |
| atacseq 4n DL | 21 | _____ | _____ |
| atacseq 4n DH | 42787 | _____ | _____ |

Counts within 10% of Ares are acceptable (workflow non-determinism). Counts off by 100×+ indicate a profiler issue.

## 10. After the bootstrap — scaling up

Once Phase 4–5 pass:
1. Add **PyFLEXTRKR + DaYu** as Phase 6 (HDF5 VOL/VFD path).
2. Add **1000genome-workflow** as Phase 7 — biggest DataLife yield in corpus (122k traces at 2n on Ares); will need Pegasus binary stack on Delta or workaround.
3. Bulk-port the remaining ~25 nf-core workflows via `sed` path-rewrite of the SLURM scripts.
4. Move from 4-node to 50/100-node runs per `notes/scalability_analysis_2026-04-29.md` in the `paper_widget` repo.

## 11. Appendix — Ares-to-Delta path translation cheatsheet

| On Ares | On Delta (replace) |
|---|---|
| `/mnt/common/mtang11/hpc_workflows/` | `/projects/<alloc>/<user>/hpc_workflows/` |
| `/mnt/common/mtang11/scripts/widget-v1/` | `/projects/<alloc>/<user>/widget-v1/` |
| `--partition=ares` | `--partition=<delta-partition>` |
| `--account=<ares_account>` | `--account=<delta-allocation>` |
| `module load openmpi/4.1.4` | match Delta's available OpenMPI module |
| `module load anaconda3` | match Delta's Python/conda module |

## 12. Known Ares-specific quirks that may not carry to Delta

- **Pegasus**: `pegasus-plan` was missing on Ares — 1000genome was run via direct Python loops instead. Delta may have Pegasus available, in which case the `runs/1000genome-workflow/run_pegasus_*.sh` scripts may work natively.
- **DSL1 Nextflow workflows** (`nf-core_eager`, `clipseq`, `dualrnaseq`, `deepvariant`): these need an old Nextflow binary that may behave differently on Delta. Skip them in Phase 1; revisit if needed.
- **Container-only modules** (`airrflow`, `demultiplex`, `scrnaseq`, `viralintegration`): require Singularity/Apptainer. If Delta has Apptainer, these may work where they failed on Ares.
- **LAMMPS Datalife FPE**: `runs/lammps/` had a libmonitor × LAMMPS interaction that crashed with FPE on Ares. Avoid LAMMPS for the bootstrap; debug interactively after.

## 12.5 Delta-specific gotchas (recorded 2026-05-13)

These are the divergences from Ares observed during the first port.
Templates in `templates/delta/` already encode the workarounds.

### Storage: do not use /projects/bekn

The NSF taiga project quota for `/projects/bekn` (Lustre project id
19485) is **500 G soft / 550 G hard with expired grace period**, used
540 G. Writes there fail. Put everything (code, tools, data, runs)
under `/scratch/bekn/mtang9/` (Lustre dltawork, 979 G free of 1.5 TB).

### SLURM partition: prefer cpu-preempt for dev

`cpu-preempt` has `TRESBillingWeights=CPU=500` vs `cpu`'s 1000 — half
the SU rate. Trade-off is preemption (5 min grace before kill). For
the dev/validation loop this is a major budget saver. Use `cpu` only
when preemption mid-run would destroy too much state.

Account name: `bekn-delta-cpu`. CPU partitions only — `bekn-delta-gpu`
exists but is not used by WIDGET.

### Apptainer is the container runtime, NOT Singularity

Delta provides Apptainer 1.4.2 system-wide at `/usr/bin/apptainer`
(NOT a module). Nextflow's `singularity` config section still works —
Apptainer accepts the same CLI. But Nextflow's task wrapper calls
`env -` then `singularity exec`, wiping host env vars (including
LD_PRELOAD). See profiler injection note below.

### Nextflow version: pin to 25.10.5

Set `NXF_VER=25.10.5` in every script. Reasons:
- 26.04+ has a stricter Groovy config parser that breaks nf-core
  pipelines using `def varname = ...` at config top level
  (observed on methylseq 2.7.0 and 4.2.0).
- 24.10 LTS lacks the `nf-schema@2.5.1` plugin newer pipelines
  require.

### Profiler LD_PRELOAD must be injected by Apptainer, not the host

The Ares pattern of setting `LD_PRELOAD=$LIB` in the SLURM wrapper
does NOT work on Delta because Apptainer isolates the container env.
Use Nextflow's `singularity.runOptions = '--env LD_PRELOAD=...'`
plus `--bind /scratch/bekn/mtang9` so the host-built .so file is
accessible from inside containers. See
`templates/delta/datalife.nf.config` and
`templates/delta/darshan.nf.config`.

Do NOT set `LD_PRELOAD=$LIBMONITOR` on the host bash — it loads
libmonitor into the Nextflow Java VM and SIGSEGVs.
(`MONITOR_UNSET_LIB=1` prevents the crash but then no traces get
collected because the preload is cleared before science tools spawn.)

### Known issue: libmonitor.so glibc ABI mismatch (exit 127)

Host libmonitor.so is built against RHEL 9.4 glibc 2.34. Some
BioContainers (older Debian bases, glibc 2.31) refuse to load it and
exit 127. Observed on methylseq 4.2.0 FASTQC container. Workarounds
in `templates/delta/README.md`.

## 13. If you get stuck

Files most useful for triage:
- `notes/multinode_deployment_FINAL_SUMMARY_2026-04-28.md` (in `paper_widget` repo) — final Ares state
- `notes/profiler_coverage_2026-04-29.md` (in `paper_widget`) — per-workflow trace counts
- `notes/scalability_analysis_2026-04-29.md` (in `paper_widget`) — per-workflow expected scaling behavior
- `widget-v1/profiler/datalife/flow-monitor/README.md` — Datalife internals
- `widget-v1/profiler/datalife/flow-monitor/potential_issue.md` — known Datalife edge cases

Surface unexpected results back to the user; don't paper over them. The Ares baseline is empirical, not specified — if Delta diverges, that's a finding worth recording, not a bug to silence.
