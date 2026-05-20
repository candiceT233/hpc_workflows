# Profiling Campaign — Interim Status (2026-05-19)

Companion to `profiling_campaign.prompt` and `MULTINODE_AUDIT_2026-05-18.md`. This file records pre-work and Phase 1 progress; it does **not** replace the final §17 that will be appended to the audit when all phases finish.

## Pre-work — complete

| # | Task | Result | Artifact |
|---|---|---|---|
| 1 | Author `runs/nf-core_shared/slurm_pinned.config` | Pins NF child sbatches to parent's nodelist | `runs/nf-core_shared/slurm_pinned.config` |
| 2 | Extend Montage medium to ≥24 tiles | 16 → **25** tiles (5×5 grid); region canvas 2048 → 2400 px | `data/Montage/medium/raw_images/` (51 MB), `data/Montage/medium/region.hdr`, `data/Montage/download_inputs.sh` |
| 3 | Curate ≥16 additional biobb PDBs | 8 → **26** PDBs (added 1AHO, 1BBI, 1BTA, 1ENH, 1FAS, 1FME, 1GAB, 1IGD, 1NXB, 1PGB, 1ROP, 2CI2, 1SHG, 1VLT, 1FSD, 1HZ6, 1ACX, 1ADR — 2 spares for swap-out) | `data/biobb_wf_md_setup/medium/*.pdb` |
| 4 | Extend `logs/multinode_sweep.tsv` schema | Added `trace_count` + `hostnames` cols; preserved 16 historical rows; renamed header column `pipeline` → `workflow` per spec | `logs/multinode_sweep.tsv` |
| 5a | PyFLEXTRKR `memory_limit='8GB'` fix | Applied to `runs/PyFLEXTRKR/multinode_4node/run_mcs_tbpf_mpi.py` (line 89, dask-mpi `initialize()` call). Audit-prescribed location `repos/PyFLEXTRKR/run_mcs_tbpf_mpi.py` doesn't exist; the runner is actually per-run-dir. | `patches/PyFLEXTRKR_dask_memory_limit.patch` |

### Pre-work still pending (deferred until Phase 4)

- DDMD `n_replicas = 24` in `dry_run.py` + matching YAML sed-rewrite
- lammps box `0 100` (4M atoms) in `runs/lammps/inputs/melt_*.in`

## Phase 1 — in progress

10 workflows × 2 profilers = **20 sbatches**, node counts 4–8 (datalife + darshan each).

### Scripts authored (all under `runs/<wf>/multinode_<N>node_<profiler>/run_slurm.sh`)

Generator: `scripts/gen_multinode_sbatches.py` stamps Class C (nf-core) scripts from `small_4node/run_slurm.<profiler>.sh` templates by applying path/tag/nodes/clusterOptions substitutions. Class A (rna-seq-star-deseq2) authored directly from existing 4-node templates.

| Workflow | Class | Nodes | Profilers |
|---|---|---|---|
| nf-core_hic | C | 4 | datalife, darshan |
| nf-core_funcscan | C | 4 | datalife, darshan |
| nf-core_cutandrun | C | 5 | datalife, darshan |
| nf-core_detaxizer | C | 5 | datalife, darshan |
| rna-seq-star-deseq2 | A | 5 | datalife, darshan |
| nf-core_methylseq | C | 6 | datalife, darshan |
| nf-core_pathogensurveillance | C | 6 | datalife, darshan |
| nf-core_quantms | C | 6 | datalife, darshan |
| nf-core_fetchngs | C | 7 | datalife, darshan |
| nf-core_nascent | C | 8 | datalife, darshan |

### Bugs surfaced during Phase 1 submission

Both are documented in this section because they're exactly the silent-failure patterns the campaign exists to catch — they'll need to be called out in the final §17 too.

**Bug 1 — `--ntasks=1` silent N→1 downgrade (caught at submit time)**

The inherited `small_4node/run_slurm.<profiler>.sh` templates have `#SBATCH --ntasks=1`. Combined with the new `#SBATCH --nodes=N`, SLURM interprets this as "1 task across N nodes," warns `can't run 1 processes on N nodes`, and **silently downgrades to N=1**. All 18 nf-core jobs initially ran single-node despite requesting 4–8. Caught from sbatch's stderr warning; cancelled all 18 immediately.

Fix: generator now substitutes `#SBATCH --ntasks=1` → `#SBATCH --ntasks-per-node=1`. With ntasks-per-node, parent honours `--nodes=N` and holds N nodes correctly. Verified post-resubmit (e.g. `nfc_methyl_6n_da` allocated on `ares-comp-[18-23]` — 6 distinct nodes).

This is the exact pattern Rule 1 audits against — N>1 alloc but compute on 1 node. The bug was inherited from the older `small_4node` templates which weren't intended for true multi-node use.

**Bug 2 — Child-sbatch `--exclusive` deadlock (caught after resubmit)**

After fixing Bug 1, all 18 parents allocated multi-node correctly. But Nextflow children submitted via `slurm_pinned.config`'s `clusterOptions = "--nodelist=${SLURM_JOB_NODELIST} --exclusive"` got stuck PENDING with `Reason=ReqNodeNotAvail, UnavailableNodes:ares-comp-[N1..Nk]` — the parent's own nodes.

**Root cause:** SLURM treats any node holding a running job as "in-use" for `--exclusive` requests, even when the new job is from the same user and the parent only holds 4 CPUs / 8 GB on the head node. Parent waits for children; children wait for parent's exclusive hold to release. Deadlock — parents would burn their full walltime producing nothing.

Cancelled all 18 parents + 60+ pending children. Edited `slurm_pinned.config` to drop `--exclusive` from clusterOptions (one-line change). Children remain pinned to parent's nodes via `--nodelist`, but can now coexist with the parent's lightweight driver hold. Resubmitted; children scheduled within seconds.

**Note on the audit:** §5/§11 of `MULTINODE_AUDIT_2026-05-18.md` prescribed `--exclusive` on both parent and children. As written, that recipe deadlocks for the same reason. The audit was a planning document, not end-to-end tested. The current working pattern is:

- Parent: `--nodes=N --ntasks-per-node=1 --cpus-per-task=4 --mem=8G` (no `--exclusive`)
- Children via `slurm_pinned.config`: `--nodelist=$SLURM_JOB_NODELIST` (no `--exclusive`)

This will be folded into the §17 final write-up as a correction to the audit's Class C recipe.

### Current state (as of write-time)

- **Submitted batch:** job IDs 17043–17060 (nf-core parents), 16953/16954 (rna-seq-star-deseq2 parents)
- **Submission log:** `logs/phase1_submissions/submitted_20260519_115326.tsv`
- **Class A jobs (rsd_5n_*):** RUNNING on `ares-comp-[11-15]` and `ares-comp-[16-20]` — distinct 5-node allocations each
- **Class C parents:** running with their child sbatches scheduling normally; first wave of children (FETCHNGS, QUANTMS, PATHOGENSURVEILLANCE, HIC, FUNCSCAN) actively executing
- **No deadlock symptoms:** all PENDING children show `Reason=Resources` (normal scheduler queueing), not `Reason=ReqNodeNotAvail`

## Three different parallelism models (recap)

| Class | Parent claims whole nodes? | Internal dispatch | Used by (this campaign) |
|---|---|---|---|
| A — Snakemake / Montage | Implicitly via full-node SBATCH resources | `srun --exclusive --nodes=1` loop, one replica per node | rna-seq-star-deseq2, Montage, biobb, V-pipe, metaGEM, DDMD |
| B — MPI / dask-mpi | Yes (full-node ranks) | `mpirun -n $SLURM_NTASKS` across allocation | PyFLEXTRKR, lammps |
| C — Nextflow | No (driver-only 4 CPU / 8 GB hold) | Driver submits child sbatches via `executor='slurm'`, pinned to parent's nodelist | All nf-core_* |

The whole `slurm_pinned.config` apparatus only exists because Class C's child-sbatch model is the only multi-node option Nextflow gives us on Ares. Classes A and B don't need it.

## Next steps (in order)

1. Wait for ≥5 Phase 1 completions, then summarize Phase 1 pass/fail
2. Author Phase 2 (7 workflows: mag, ampliseq, taxprofiler, metaGEM-medium, atacseq, rnaseq, viralrecon at 10–15 nodes)
3. Author Phase 3 (smrnaseq at 18n)
4. Apply remaining Phase 4 prep (DDMD replicas, lammps box)
5. Author + submit Phase 4 (Montage/biobb/DDMD/PyFLEXTRKR/lammps at 24n)
6. Append §17 to `MULTINODE_AUDIT_2026-05-18.md` with full per-run results
