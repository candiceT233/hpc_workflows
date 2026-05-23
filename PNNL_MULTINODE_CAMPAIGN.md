# PNNL Deception — multi-node I/O-profiling campaign (two-scale)

Adapts `prompts/merged-prompt.md` (v3.0, Ares) to **PNNL Deception**. Goal: run each
deployable workflow at **two scales** — SMALL (4–30 nodes) and LARGE (80–100+ nodes) —
with I/O profiling, verifying profiler-log correctness, and record pass/fail.

## PNNL cluster block (REPLACES merged-prompt §"Cluster-specific facts")
- **Partition:** `slurm` (271 nodes, 64 CPU / 256 GB, 7-day limit). **Account:** `oddite`
  (NOT `datamesh` — frozen GrpJobs=0). No QoS needed.
- **MPI:** `module load openmpi/5.0.7` + `mpirun`/PRRTE (srun lacks PMIx). Disable conda's
  broken UCX 1.14.1: `--mca pml ob1 --mca osc ^ucx`; pin `--prtemca oob_tcp_if_include eno1`
  + `--prtemca routed_radix 256` at high node counts.
- **Filesystems:** workload I/O on **BeeGFS** `/rcfs/projects/chess/tang584/` (4.5 PB shared,
  limited — **clean up intermediate data after both profiler passes**). Node-local `/scratch`
  (local XFS) for dask spill + profiler trace staging. `/qfs` = NFS (slow). `/vast` = VAST NFS.
- **WORKFLOW_ROOT:** `/qfs/projects/datamesh/tang584/widget_evaluation/hpc_workflows`
- **widget root:** `/qfs/projects/datamesh/tang584/widget_evaluation/widget-v1`
- **libmonitor (DataLife):** `widget-v1/profiler/datalife/build/flow-monitor/src/libmonitor.so`
  (needs `DATALIFE_OUTPUT_PATH`; emits `monitor_timer.<pid>-<host>.datalife.json`).
- **DaYu:** `widget-v1/profiler/dayu-tracker/build/src/{vol,vfd}/*.so` (HDF5/NetCDF only).
- **libdarshan:** `/people/tang584/install/darshan_runtime/lib/libdarshan.so` (POSIX-only,
  no HDF5 module); **darshan-parser:** `/people/tang584/install/darshan_runtime/bin/darshan-parser`.
  Use `DARSHAN_ENABLE_NONMPI=1` for per-process logs; pre-create `LOGPATH/YYYY/M/D`.
- **Java 17:** system `/usr/bin/java` (17.0.14). **nextflow:** `/qfs/people/tang584/install/nextflow/nextflow`.
- **conda:** `/share/apps/python/miniconda25.5.1`. **verification.py:** `widget-v1/src/dfl_mcp/verification.py`.

## Hard rules carried over (unchanged)
Rule 1 (real N-node use; `--ntasks-per-node=1` not `--ntasks=1`), Rule 7 (**never stack
profilers — one job each**, enforced), Rule 2 (verify node spread), Rule 4 (tight DATALIFE
patterns), correctness-of-traces is part of done. **DaYu N/A unless HDF5/NetCDF.**

## Two-scale node assessment (what each scale means per class)
- **SMALL = 4–30 nodes**, **LARGE = 80–100+ nodes**.
- **Class B (MPI/dask)** — LARGE feasible (problem-size driven). PyFLEXTRKR data-capped ~288 workers.
- **Class A (fan-out, 1 unit/node)** — LARGE feasible only with ≥80–100 cheap input units (Montage tiles, DDMD replicas, synth PDBs). Few-unit ones (metaGEM 12, rna-seq 5, V-pipe 2) are SMALL-only.
- **Class C (nf-core/Nextflow)** — DAG-concurrency-capped; even with large input ≈ ≤30 tasks → **SMALL-only (≤~18–30 nodes); LARGE = N/A**.

## Status legend: (blank)=todo · `pass` · `fail` · `N/A` (scale infeasible) · `dep` (needs deploy)

| # | Workflow | Class | Widget prof | Small nodes | Large nodes | S-Widget | S-Darshan | L-Widget | L-Darshan |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 1000genome-workflow | A* | DataLife | 4–30 | needs fanout rework | dep | dep | N/A? | N/A? |
| 2 | biobb_wf_md_setup | A | DataLife | 4–30 | 80+ (synth PDBs) | dep | dep | dep | dep |
| 3 | chipseq(snakemake) | A/D | DataLife | 4–30 | N/A | dep | dep | N/A | N/A |
| 4 | DeepDriveMD-pipeline | A | DataLife/DaYu | 4–30 | 80–100 (replicas) | dep | dep | dep | dep |
| 5 | dna-seq-gatk-variant-calling | A/D | DataLife | 4–30 | N/A | dep | dep | N/A | N/A |
| 6 | dna-seq-varlociraptor | A/D | DataLife | 4–30 | N/A | dep | dep | N/A | N/A |
| 7 | metaGEM | A | DataLife | ≤12 | N/A | dep | dep | N/A | N/A |
| 8 | **Montage** | A | DataLife | 16 | 120 | **pass** | **pass** | **pass** | **pass** |
| 9–42 | nf-core_* (22 pipelines) | C | DataLife/Darshan | 4 | N/A | (DataLife TBD) | **8 pass / 10 fail** | N/A | N/A |
| 43 | **PyFLEXTRKR** | B | DaYu | 4–48 | 80 | **pass(DaYu)** | | **pass(DaYu)** | **pass(Darshan)** |
| 44 | rna-seq-star-deseq2 | A | DataLife | ≤5 | N/A | dep | dep | N/A | N/A |
| 45 | V-pipe | A | DataLife | ≤2 | N/A | dep | dep | N/A | N/A |
| 46 | nf-core_eager | C(DSL1) | DataLife | 4–18 | N/A | dep | dep | N/A | N/A |
| 47 | iwc | Galaxy | DataLife | ? | N/A | dep | dep | N/A | N/A |
| 48 | lammps | B | Darshan only | 4–30 | 80–100+ | dep | dep | dep | dep |
| 49 | nwchem | B | Darshan(+DaYu?) | 4–30 | 80–100 | dep | dep | dep | dep |
| 50 | parsl | framework | DataLife | 4–30 | 80+ (workload) | dep | dep | dep | dep |
| 51 | pegasus | framework | DataLife | 4–30 | 80+ | dep | dep | dep | dep |
| 52 | PtychoNN | GPU | DataLife/DaYu | GPU axis | GPU axis | dep | dep | dep | dep |
| 53 | radical.pilot | framework | DataLife | 4–30 | 80+ | dep | dep | dep | dep |

(Full per-nf-core rows expand rows 9–42; nf-core LARGE is uniformly N/A by DAG cap.)

## nf-core breadth — Darshan, 4 nodes, `test` profile (SMALL scale) — `logs/nfcore_darshan_sweep.tsv`
Run via HyperQueue (`hq_nfcore_pnnl.sbatch`), serial dependency chain (no concurrent conda-env
creation → no Rule-5 cache corruption). Darshan logs verified parseable + capture real tool I/O
(e.g. samtools POSIX_BYTES_READ=6.5 MB). Logs are noisy (~95% are shell-helper procs: bash/grep/awk).

**8 PASS** (EXIT=0, NF "completed successfully"): bacass, nascent, detaxizer, createtaxdb,
funcscan, taxprofiler, mag, rnaseq.
**10 FAIL/parked:** smrnaseq (test-data merge), methylseq (empty BAM), viralrecon (R reshape2),
genomeqc (GENE_OVERLAPS), circdna (UNICYCLER), ampliseq (qiime2), cutandrun (NF-API drift),
sarek (gatk), clipseq + deepvariant (**DSL1 — needs NF≤22.10**).
Most failures are at terminal/QC steps after the I/O-heavy stages ran (logs still captured), or
tool/version/test-data artifacts — consistent with `test`-profile being a harness map, not a
full-realistic `pass`. **DataLife pass still required** (criterion 3): testing on bacass.

## LARGE-scale (80–100+) feasible set (the real "blow up" list)
**PyFLEXTRKR✅, Montage✅, DeepDriveMD, lammps, nwchem, biobb(synth PDBs)** — plus frameworks
(parsl/pegasus/radical) if given a fan-out workload. Everything else is SMALL-only.

## Cleanup discipline (BeeGFS shared + limited)
After **both** profiler passes for a (workflow,scale) finish AND traces are verified+collected,
delete that run's intermediate workload outputs on BeeGFS (keep only the collected traces).
`KEEP_OUTPUTS=0` already does this for Montage. Track BeeGFS usage; never leave throwaway tiles/
reprojections/NetCDF outputs after verification.

## Execution order (round-robin, ascending by feasibility/readiness)
1. Finish PyFLEXTRKR (Darshan large running) + add SMALL Darshan + SMALL/LARGE remaining cells.
2. Montage SMALL scale (both profilers) to complete its two-scale row.
3. DeepDriveMD (deployed repo; ensemble → both scales; DataLife/DaYu + Darshan).
4. nf-core SMALL scale (Class C, ≤18n) — methylseq/smrnaseq already have scripts; expand realistic input.
5. lammps + nwchem LARGE (Class B, MPI builds) — the big-node story.
6. Class A small-unit (biobb/metaGEM/rna-seq/V-pipe) SMALL scale.
7. Frameworks (parsl/pegasus/radical) + PtychoNN — park if blocked, cycle back (never abandon).
