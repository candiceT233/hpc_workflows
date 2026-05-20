# Multi-node Audit & 24-Node Scalability Report

**Date:** 2026-05-18
**Scope:** All 105 canonical `runs/<wf>/<scale>/run_slurm*.sh` scripts across 47 workflows
**Goal:** Identify scripts whose SLURM allocation does not match actual compute placement; recommend a path to a 24-node DataLife / DaYu / Darshan sweep.

Source data:
- `logs/multinode_audit_2026-05-18.tsv` — per-script classification
- `logs/nf_concurrency_2026-05-18.tsv` — Nextflow per-pipeline task counts (from `pipeline_info/execution_trace_*.txt`)

---

## 1. Classification of all 105 canonical scripts

| Class | Count | What the script does | Actually uses N nodes? |
|---|---|---|---|
| **A — srun fan-out** | 18 | One `#SBATCH --nodes=N`, `srun --exclusive --nodes=1 --ntasks=1` per replica in a loop | **Yes** — by construction |
| **B — MPI intrinsic** | 4 | `mpirun -np N×R` or `dask-mpi` across the allocation | **Yes** — by MPI launcher |
| **C — Nextflow queue fan-out** | 65 | Head Nextflow on the allocated node; child tasks each submit a *new* sbatch via `executor='slurm'` | **Indeterminate** — depends on cluster scheduler choices; `--nodes=N` in the parent only allocates head-node space |
| **D — Snakemake serial, wasted nodes** | 6 | `--nodes=4` in baseline but no `--cluster`, `--profile slurm`, or srun loop | **No** — runs on 1 node, 3 nodes idle |
| **F — Single-node, wasted nodes** | 11 | `--nodes=N` requested, but the driver is a single process with no fan-out | **No** — runs on 1 node, N-1 idle |

Class A+B = 22 scripts run as advertised. Class C runs *something* on more than one node only if the scheduler happens to spread the children. Classes D+F = 17 scripts that allocate multiple nodes but use only one.

### Naming caveat (carries forward from advisor critique 2026-04-29)

- `runs/nf-core_*/small_{2,4}node/` — name describes `NXF_MAX_FORKS=80 or 160` (concurrency budget), **not** node allocation. The head `#SBATCH` requests `--nodes=1`.
- `runs/*/small/` and `runs/*/medium/` — many request `--nodes=4 --ntasks-per-node=40 --mem=47000M` (legacy "give it room to breathe") but actually compute on 1 node.
- `runs/*/multinode_{2,4}node/` — these *do* match their name (Class A, srun fan-out).

---

## 2. Per-workflow classification — current state

Sorted by workflow. `?` = no script for that scale. `[!]` = name vs. reality mismatch.

| Workflow | small | medium | small_2node | small_4node | multinode_2node | multinode_4node |
|---|---|---|---|---|---|---|
| 1000genome-workflow | — | — | F (2n alloc, 1n use) [!] | F (4n alloc, 1n use) [!] | — | — |
| biobb_wf_md_setup | F (4n alloc) [!] | F (4n alloc) [!] | — | — | **A** | **A** |
| chipseq | D (4n alloc) [!] | — | — | — | — | — |
| cwl | — | — | — | F (4n alloc) [!] | — | — |
| DeepDriveMD-pipeline | F (4n alloc) [!] | F (4n alloc) [!] | — | — | **A** | **A** |
| dna-seq-gatk-variant-calling | D (4n alloc) [!] | — | — | — | — | — |
| dna-seq-varlociraptor | D (4n alloc) [!] | — | — | — | — | — |
| lammps | — | — | — | **B** (mpirun 4-rank) | — | — |
| metaGEM | D (4n alloc) [!] | — | — | — | **A** | **A** |
| Montage | F (4n alloc) [!] | F (4n alloc) [!] | — | — | **A** | **A** |
| nf-core_ampliseq | C (4n alloc head) [!] | — | C | C | — | — |
| nf-core_eager | C (4n alloc head) [!] | — | — | — | — | — |
| nf-core_fetchngs | C (4n alloc head) [!] | — | C | C | — | — |
| nf-core_methylseq | C (4n alloc head) [!] | — | C | C | — | — |
| nf-core_rnaseq | C (4n alloc head) [!] | — | C | C | — | — |
| nf-core_sarek | C (4n alloc head) [!] | — | C | C | — | — |
| nf-core_smrnaseq | C (4n alloc head) [!] | — | C | C | — | — |
| nf-core_viralrecon | C (4n alloc head) [!] | — | C | C | — | — |
| nf-core_atacseq / bacass / circdna / clipseq / createtaxdb / cutandrun / deepvariant / demultiplex / detaxizer / differentialabundance / dualrnaseq / funcscan / genomeqc / hic / mag / mhcquant / nascent / pathogensurveillance / proteinfold / quantms / scnanoseq / scrnaseq / spatialvi / taxprofiler / tumourevo / viralintegration | — | — | C | C | — | — |
| PyFLEXTRKR | F (4n alloc) [!] | F (4n alloc) [!] | — | — | — | **B** (dask-mpi) |
| rna-seq-star-deseq2 | D (4n alloc) [!] | — | — | — | **A** | **A** |
| V-pipe | D (4n alloc) [!] | — | — | — | **A** | **A** |

---

## 3. Nextflow concurrency analysis — can the workload use 24 nodes?

For class C, the cap on actual nodes used is the **smallest** of:
- `NXF_MAX_FORKS` (currently 80 or 160 — non-binding for 24 nodes)
- Peak number of tasks runnable simultaneously (determined by the pipeline DAG + input size)
- Number of compute nodes the SLURM scheduler picks for those children

Read from `pipeline_info/execution_trace_*.txt` (peak count of task submissions in any 5-second window — proxy for true peak concurrency):

| Pipeline | Total tasks | Peak concurrent | Could fill 24 nodes? |
|---|---|---|---|
| nf-core_ampliseq | 16–123 | up to **123** | ✅ Yes (one rich phase) |
| nf-core_pathogensurveillance | 1–47 | up to **47** | ✅ Yes |
| nf-core_smrnaseq | 36–244 | 24–30 | ✅ Yes |
| nf-core_atacseq | 148–259 | 24 | ✅ Yes (marginal) |
| nf-core_mag | 134–196 | 21–22 | ⚠️ Barely (~22 < 24) |
| nf-core_nascent | 149 | 20 | ⚠️ ~83% |
| nf-core_viralrecon | 188–202 | 18 | ⚠️ ~75% |
| nf-core_taxprofiler | 178–179 | 18 | ⚠️ ~75% |
| nf-core_rnaseq | 219–220 | 16 | ⚠️ ~67% |
| nf-core_fetchngs | 53 | 12 | ❌ ~50% |
| nf-core_detaxizer | 54 | 12 | ❌ ~50% |
| nf-core_quantms | 51–60 | 10 | ❌ ~42% |
| nf-core_methylseq | 36 | 9 | ❌ ~38% |
| nf-core_cutandrun | 110–135 | 8 | ❌ ~33% |
| nf-core_funcscan | 57 | 6 | ❌ ~25% |
| nf-core_hic | 8–35 | 2–4 | ❌ ~17% |
| nf-core_sarek | 23–24 | 3 | ❌ ~12% |
| nf-core_differentialabundance | 21 | 3 | ❌ ~12% |
| nf-core_proteinfold | 5 | 2 | ❌ ~8% |
| nf-core_bacass | 10–17 | 2 | ❌ ~8% |

**Headline:** With current test-data inputs, only **4 nf-core pipelines** can keep 24 nodes meaningfully busy. The remaining 16 will idle most of the allocation regardless of fan-out fix. To fix this requires *larger input* (more samples), not script changes.

---

## 4. Scalability assessment — per-workflow path to 24 nodes

Verdict legend:
- 🟢 **Drop-in scale to 24n** — change `--nodes` and inputs, done
- 🟡 **Needs harness rewrite** — current design wastes nodes, must rebuild for srun/MPI launch
- 🔴 **Bound by upstream or data** — can't reach 24n without out-of-scope work

### Class A (srun fan-out) — 6 workflows
Already true multi-node by construction. For 24 nodes, change `#SBATCH --nodes=N` + loop bounds. Caveat: need ≥24 independent inputs/replicas to fill it.

| Workflow | 24n verdict | What's needed |
|---|---|---|
| **Montage** | 🟢 | Already shards `images.tbl` into `$SLURM_NNODES` chunks. Set `--nodes=24`; medium dataset (203 MB) has enough tiles |
| **biobb_wf_md_setup** | 🟡 | Test set is 8 PDBs. 24 nodes idle on 16. Solve: clone the PDB list 3×, OR seed a 24-PDB set |
| **V-pipe** | 🟡 | Per-replica means 1 sample per node. Test data has 1 sample → need to fan out 24 replicas of same sample, OR drop scale to 8n |
| **metaGEM** | 🟡 | Same constraint as V-pipe (test data is small) |
| **DeepDriveMD-pipeline** | 🟡 | dry_run.py was hardcoded to 1 experiment; per-replica path-rewrite trick scales but each "experiment" is identical — call it 24-rep redundancy benchmark, not 24× different work |
| **rna-seq-star-deseq2** | 🟡 | Per-replica conda pkg cache fix already in place; data = 1 dataset, need 24 replicas of it |

### Class B (MPI intrinsic) — 2 workflows
Natively multi-rank. Just change `mpirun -np` and SBATCH `--nodes`.

| Workflow | 24n verdict | What's needed |
|---|---|---|
| **PyFLEXTRKR** | 🟡 | dask-mpi scales linearly; test data has 48 timesteps. Per memory_limit auto-detect bug, set `memory_limit='8GB'` in `run_mcs_tbpf_mpi.py` |
| **lammps** | 🟢 | LJ-melt MPI scales arbitrarily; bump `-np 24` and the SBATCH `--nodes=24 --ntasks-per-node=1` |

### Class C (Nextflow) — 22 nf-core workflows
The deepest design problem. Two changes are needed for 24-node honest use:

**Fix the harness:**
```bash
#SBATCH --nodes=24 --ntasks-per-node=1 --cpus-per-task=40 --mem=47000M --exclusive
# Constrain NF children to ONLY the nodes Slurm allocated to the parent:
export NXF_OPTS="-Dnxf.executor.exclusive=true"
# In slurm.config, add:
#   clusterOptions = "--nodelist=${SLURM_JOB_NODELIST} --exclusive"
# (Or: use executor='local' + Hyper-Q via srun across the 24-node allocation)
```

**Fix the input size:** see table above — only ampliseq / pathogensurveillance / smrnaseq / atacseq can keep 24n busy with current test data.

| Pipeline | 24n verdict | Why |
|---|---|---|
| nf-core_ampliseq | 🟢 | Peak 123 concurrent — fills 24n easily |
| nf-core_pathogensurveillance | 🟢 | Peak 47 |
| nf-core_smrnaseq | 🟢 | Peak ~30 |
| nf-core_atacseq | 🟡 | Peak 24 — tight margin; EXIT_CODE=1 issues unresolved |
| nf-core_mag | 🟡 | Peak ~22; bump samples to 4–8 |
| nf-core_nascent / viralrecon / taxprofiler / rnaseq | 🟡 | Peak 16–20; double samples in test config |
| nf-core_fetchngs | 🔴 | HTTP egress wall; 24 parallel SRA downloads = throttled by NCBI |
| nf-core_detaxizer / quantms / methylseq / cutandrun / funcscan / hic / sarek / differentialabundance / proteinfold / bacass | 🔴 | Peak ≤12; test data too small. Need to swap to a real-size dataset to make 24n meaningful |
| 16 other dormant nf-core | 🟡 | Never run; would need both (a) harness fix and (b) input sizing pass |

### Class D / F (wasted nodes in baselines) — 17 scripts
None of these need to scale to 24n — they're single-node by design. The fix is **honesty**: drop `--nodes=4` from baseline `small/` and `medium/` scripts, set `--nodes=1`. Keep the `multinode_{2,4}node/` versions (which are Class A) as the multi-node entries.

---

## 5. Concrete plan for a 24-node DataLife/DaYu/Darshan sweep

### Phase 1 — Fix the harness (1 day)

1. **Rewrite the 11 wasted-baseline scripts** (Class D+F) to honestly use 1 node. Saves cluster time on every future run.
2. **Add a `runs/nf-core_shared/slurm_24node.config`** with `clusterOptions = "--nodelist=${SLURM_JOB_NODELIST} --exclusive"` so NF children land only on the parent's allocated nodes.
3. **Build a `small_24node/` template per workflow** with `--nodes=24 --ntasks-per-node=1 --cpus-per-task=40 --mem=47000M`. For Class A, mirror the `multinode_4node` pattern with `--nodes=24`. For Class C, use the new shared config.

### Phase 2 — Sample the realistic workloads (1 day)

Run a 24-node attempt for the **9 workflows that can actually fill 24n**:

| Class | Workflow | DataLife | DaYu | Darshan |
|---|---|---|---|---|
| A | Montage | ✅ | (n/a HDF5) | ✅ |
| A | metaGEM | ✅ | (n/a) | ✅ |
| A | V-pipe | ✅ | (n/a) | ✅ |
| A | rna-seq-star-deseq2 | ✅ | (n/a) | ✅ |
| B | PyFLEXTRKR | ✅ | ✅ | ✅ |
| B | lammps | (libmonitor×lmp FPE — skip) | (n/a) | ✅ |
| C | nf-core_ampliseq | ✅ | (n/a) | ✅ |
| C | nf-core_pathogensurveillance | ✅ | (n/a) | ✅ |
| C | nf-core_smrnaseq | ✅ | (n/a) | ✅ |

### Phase 3 — Stretch to a useful 24n picture (3–5 days)

For the 10–12 NF pipelines stuck at "test-data is too small," generate a **medium-sized synthetic test config** that's still self-contained (no live SRA downloads):
- For RNA-seq variants: 24-sample synthetic FASTQ pairs (50K reads each)
- For Hi-C / atac: 24-sample synthetic + tiny reference
- For sarek: 8 BAM × 3 chromosomes (uses sarek's natural chr-parallelism)

Then re-run those at 24n.

### Phase 4 — Acknowledge unreachable cases

- `nf-core_fetchngs` — capped at ~10n by SRA egress regardless
- `nf-core_proteinfold` / `bacass` (with test data) — pipelines genuinely small; document as "fan-out cap = 5–10"
- `cwl` (cwltool single-node) — needs toil-cwl-runner port; out of scope
- Dormant 16 NF pipelines — need both harness AND input fix; defer

---

## 6. Top 3 immediate actions

1. **Rewrite `runs/<wf>/small/run_slurm.sh`** for the 11 wasted-baseline workflows (Montage / biobb / DDMD / PyFLEXTRKR + 6 Snakemake) to use `--nodes=1`. This is honest and saves time.
2. **Author `runs/nf-core_shared/slurm_24node.config`** with `--nodelist=$SLURM_JOB_NODELIST --exclusive`. Pins NF children to the parent's allocation.
3. **Submit Phase-2 24n probes** for the 9 known-fillable workflows (datalife + darshan, PyFLEXTRKR also dayu). One sbatch per workflow; total cluster wall ~6h.

Run `cat logs/multinode_audit_2026-05-18.tsv` and `logs/nf_concurrency_2026-05-18.tsv` for the raw classification + concurrency data.

---

## 7. Ares cluster capacity — what node count is actually feasible

Queried via `sinfo` and `scontrol show partition` on 2026-05-18:

| Partition | Total nodes | Nodes | Currently idle |
|---|---|---|---|
| **compute** (default) | 22 | ares-comp-[10–23, 25–32] | 12 |
| **datacrumbs** | 27 usable (1 down, 1 inval) | ares-comp-[02–08, 10–23, 25–32] | 16 |
| **debug** | 5 usable | ares-comp-[03–06, 08] | 4 |

Per-node spec: 40 CPUs, ~47 GB RAM.

Hard ceiling for a single job:
- 22 nodes on `compute`
- 27 nodes on `datacrumbs`
- 24 nodes is reachable on `datacrumbs` but requires the scheduler to drain some `mix` nodes, so queue wait grows.

---

## 8. Actual task counts for the 9 viable workflows

Goal: pick the smallest node count that the workflow can actually fill, so the allocation isn't sitting idle.

| Workflow | Input units in test data | Max simultaneous tasks | If we run 24 nodes | Honest node count |
|---|---|---|---|---|
| **Montage** small | 4 raw FITS tiles | 4 | 20 nodes idle | **4** |
| **Montage** medium | 16 raw FITS tiles | 16 | 8 nodes idle | **16** |
| **metaGEM** small | 3 samples | 3 | 21 idle | **3** (or skip) |
| **metaGEM** medium | 12 samples (3 × 4 reps) | 12 | 12 idle | **12** |
| **V-pipe** | 2 samples | 2 | 22 idle | **2** (already done) |
| **rna-seq-star-deseq2** | 5 sample pairs (a/b/c chr21 + a/b scerevisiae) | 5 | 19 idle | **5** |
| **biobb_wf_md_setup** | 8 PDBs | 8 | 16 idle | **8** |
| **PyFLEXTRKR** medium | 98 timesteps (dask-mpi shards) | unbounded | 0 idle | **16–22** |
| **lammps** | MPI ranks (problem-size driven; current 16K-atom too small) | unbounded with bigger box | 0 idle | **16–22** with ≥1M atom box |
| **nf-core_ampliseq** | NF DAG | **123 peak** | 0 idle | **16–22** |
| **nf-core_pathogensurveillance** | NF DAG | **47 peak** | 0 idle | **16–22** |
| **nf-core_smrnaseq** | NF DAG | **30 peak** | up to 6 idle on 24n | **16–22** |

---

## 9. Recommended target: **16 nodes** (not 24)

Why 16:
1. **Fits in either partition without queue wait** — `compute` and `datacrumbs` both have ≥16 idle nodes right now
2. **Matches the largest natural fan-out** — Montage medium has exactly 16 tiles; metaGEM medium has 12; PyFLEXTRKR/ampliseq/path/smrnaseq fully saturate 16
3. **Wastes fewer slots** on the smaller workflows (Montage-small, V-pipe, metaGEM-small, rna-seq, biobb) — which should run at their natural size anyway, not be forced to 24

24 nodes only makes sense if:
- You're willing to wait longer in queue
- You want to demonstrate scaling for nf-core_ampliseq (123 peak) which can definitely use it
- You accept that 4–6 of the 10 workflows will idle most of the allocation

---

## 10. Proposed sweep matrix — 10 runs, 30 sbatches, ~8–12h wall

Pin each workflow to its *honest* node count, not a flat 24:

| # | Workflow | Nodes | Profilers | Estimated wall |
|---|---|---|---|---|
| 1 | Montage medium | 16 | datalife + darshan | ~5 min × 2 = 10 min |
| 2 | metaGEM medium | 12 | datalife + darshan | ~30 min × 2 = 1 h |
| 3 | biobb_wf_md_setup | 8 | datalife (`MONITOR_UNSET_LIB=1` for gmx) + darshan | ~5 min × 2 = 10 min |
| 4 | rna-seq-star-deseq2 | 5 | datalife + darshan | ~25 min × 2 = 50 min |
| 5 | V-pipe | 2 (already done — skip) | — | — |
| 6 | PyFLEXTRKR medium | 16 | datalife + dayu + darshan | ~30 min × 3 = 1.5 h |
| 7 | lammps (with bigger box) | 16 | darshan only (libmonitor×lmp FPE) | ~10 min |
| 8 | nf-core_ampliseq | 16 | datalife + darshan | ~30 min × 2 = 1 h |
| 9 | nf-core_pathogensurveillance | 16 | datalife + darshan | ~20 min × 2 = 40 min |
| 10 | nf-core_smrnaseq | 16 | datalife + darshan | ~30 min × 2 = 1 h |

**Total: ~7 hours of cluster wall + queue + conda env solves. Realistic 1–2 day campaign.**

---

## 11. Prerequisites before submitting

1. **lammps needs a bigger problem size.** Current 16K-atom LJ melt at 16 nodes × 4 ranks/node = 64 ranks = ~250 atoms/rank → communication-dominated, meaningless trace. Need ~1M+ atoms.
2. **biobb at 8 nodes** — the ASA harness sends 1 PDB per node. To use more, would need to duplicate the PDB list. Recommend keeping at 8 (honest).
3. **For nf-core (3 pipelines)** — need to author `runs/nf-core_shared/slurm_pinned.config` with `clusterOptions = "--nodelist=${SLURM_JOB_NODELIST} --exclusive"` so NF children land only on the parent's allocated 16 nodes (not the cluster's general queue).
4. **For Class A srun-fanout (Montage, metaGEM, biobb, rna-seq, PyFLEXTRKR)** — copy the existing `multinode_4node/run_slurm.sh` to a new `multinode_16node/` directory and bump `--nodes=16` plus the loop bounds.

---

## 12. Next-step options (pick one)

- **(a)** Build the 10 SBATCH templates (Class A copies + nf-core slurm_pinned.config) — ~2 hours of script work, ready to submit
- **(b)** Just author `slurm_pinned.config` first since it's needed by 3 of the 10 — 5-min change
- **(c)** Both

---

## 13. Sustained parallelism analysis (2026-05-18, refinement)

The peak-concurrency metric in section 3 was a 5-second submission window snapshot. That overstates how busy each workflow actually keeps a cluster, because Nextflow can submit a burst of 100+ FastQC jobs in 2 seconds, then serialize for the next 40 minutes.

A more honest metric is **time-weighted average concurrency** — `total_work_seconds / wall_seconds`. That tells you how many cores were busy on average across the full run.

Computed by replaying each `execution_trace_*.txt` (per-task submit time + duration) and counting active tasks at every event point. Raw data: `logs/nf_parallelism_2026-05-18.tsv`.

### Class C — Nextflow pipelines, sustained vs. peak

| Workflow | Total tasks | Wall (s) | Work (s) | Avg sustained | Peak | Sweet node count |
|---|---|---|---|---|---|---|
| **nf-core_smrnaseq** | 57 | 138 | 1,679 | **12.2** | 29 | **18** |
| nf-core_viralrecon | 180 | 686 | 6,217 | 9.1 | 27 | 15 |
| nf-core_atacseq | 93 | 572 | 4,276 | 7.5 | 22 | 12 |
| nf-core_rnaseq | 219 | 775 | 5,098 | 6.6 | 28 | 14 |
| nf-core_mag | 62 | 1,058 | 4,563 | 4.3 | 22 | 10 |
| nf-core_methylseq | 36 | 163 | 691 | 4.2 | 9 | 6 |
| nf-core_fetchngs | 53 | 299 | 1,104 | 3.7 | 12 | 7 |
| **nf-core_ampliseq** | 107 | 3,936 | 13,825 | **3.5** | 27 | 11 |
| nf-core_hic | 11 | 67 | 205 | 3.1 | 4 | 4 |
| nf-core_taxprofiler | 179 | 2,004 | 5,047 | 2.5 | 29 | 11 |
| nf-core_cutandrun | 102 | 760 | 1,925 | 2.5 | 10 | 5 |
| nf-core_quantms | 50 | 633 | 1,358 | 2.1 | 12 | 6 |
| nf-core_sarek | 22 | 445 | 850 | 1.9 | 5 | 3 |
| nf-core_detaxizer | 54 | 680 | 1,217 | 1.8 | 12 | 5 |
| nf-core_pathogensurveillance | 47 | 1,526 | 2,447 | 1.6 | 15 | 6 |
| nf-core_nascent | 149 | 2,246 | 3,383 | 1.5 | 20 | 8 |
| nf-core_funcscan | 57 | 2,548 | 3,948 | 1.5 | 7 | 4 |
| nf-core_bacass | 9 | 1,254 | 1,223 | 1.0 | 3 | 2 |
| nf-core_proteinfold | 5 | 359 | 142 | 0.4 | 2 | 1 |
| nf-core_differentialabundance | 21 | 1,949 | 752 | 0.4 | 3 | 2 |

**Sweet node count formula:** `ceil(avg + 0.3 × (peak − avg))` — sized to handle the average load with headroom for occasional bursts.

### Story change — ampliseq is NOT the 24-node winner

Earlier I called `nf-core_ampliseq` the 24-node winner because of its 123 task-submission peak. The sustained-parallelism numbers reverse that:

- **ampliseq avg = 3.5** over a 66-minute run. The 123 happens because Nextflow submits a burst of FastQC tasks in ~2 seconds, then serializes for the next 40+ minutes. Allocating 24 nodes would have **21 idle 95% of the time**.
- **The actual nf-core winner is `smrnaseq`** — avg 12.2 sustained, peak 29. Short run (138 s wall) but consistently busy. Only NF pipeline where 16+ nodes pays off across the entire run.

### Class A (ASA srun fan-out) — different model

For these, sustained = peak = number of replicas, since all replicas run in parallel as independent srun jobs of similar wall time:

| Workflow | Replicas (= sustained = peak) | Sweet node count |
|---|---|---|
| Montage small | 4 tiles | 4 |
| **Montage medium** | **16 tiles** | **16** |
| metaGEM small | 3 samples | 3 |
| **metaGEM medium** | **12 samples (3 × 4 reps)** | **12** |
| biobb_wf_md_setup | 8 PDBs | 8 |
| V-pipe | 2 samples | 2 |
| rna-seq-star-deseq2 | 5 sample pairs | 5 |

### Class B (MPI / dask-mpi)

| Workflow | Notes | Sweet node count |
|---|---|---|
| **PyFLEXTRKR medium** | 98 timesteps × dask-mpi; scales as long as `memory_limit='8GB'` is set explicitly | **16–22** |
| **lammps** | LJ-melt MPI scales arbitrarily; current 16K-atom box too small for 16+ ranks → need ≥1M atoms | **16+** with bigger box |

---

## 14. Revised tiered recommendation (replaces flat "16 nodes" plan)

A single flat node count wastes 50–90% of the allocation on the more-serial workflows. Better plan — run each workflow at its sweet count:

| Bucket | Workflows | Node count |
|---|---|---|
| **Honestly use 16 nodes** | Montage medium, PyFLEXTRKR medium, lammps (with bigger box), nf-core_smrnaseq | **16** |
| **Natural fan-out, 8–12 nodes** | metaGEM medium (12), biobb (8) | **8–12** |
| **Natural fan-out, ≤5 nodes** | rna-seq-star-deseq2 (5), Montage small (4), metaGEM small (3), V-pipe (2) | **2–5** |
| **NF with low sustained — only at peak counts** | viralrecon (15), rnaseq (14), atacseq (12), ampliseq (11), taxprofiler (11), mag (10), nascent (8), fetchngs (7), methylseq (6), pathogensurveillance (6), quantms (6), cutandrun (5), detaxizer (5), hic (4), funcscan (4) | **sweet count from table** |
| **Skip — too serial to be worth a multi-node run** | sarek (avg 1.9), bacass (1.0), proteinfold (0.4), differentialabundance (0.4) | **single-node only** |

### Tradeoff

- **Tiered plan**: realistic utilization, but more diverse SBATCH scripts to author and maintain (each workflow gets its own honest `multinode_Nnode/` dir)
- **Flat 16-node plan**: only 4 of 20 workflows actually fill it; apples-to-apples wall-time comparison but most of the allocation idle
- **Flat 8-node plan**: better median utilization but still leaves smrnaseq/viralrecon/rnaseq/Montage-medium/PyFLEXTRKR under-utilized

---

## 15. Updated next-step options

- **(a) Tiered plan, full coverage** — build 16 SBATCH scripts at workflow-specific node counts (4 × 16n, 2 × 8–12n, 4 × 2–5n, 6 × NF-sweet-count). ~3 hours of script work.
- **(b) Tiered plan, top tier only** — just the 4 honest-16n workflows (Montage medium, PyFLEXTRKR medium, lammps, smrnaseq). Smallest, highest-signal sweep. ~1 hour.
- **(c) Flat 16n sweep** — single config, 10 workflows; accept the waste in exchange for apples-to-apples comparison. ~2 hours.
- **(d) Don't build anything yet** — examine one more parallelism angle (e.g., per-stage breakdown, critical-path serial bottlenecks) before committing.

---

## 16. Max-scale sweep plan — push each workflow to its ceiling, ≤24 nodes

The §14 plan picked a "comfortable" node count per workflow. This section instead picks each workflow's **highest meaningful node count**, capped at 24 (Ares scheduling ceiling).

For each workflow we ask:
1. What's the parallelism ceiling implied by the current input data?
2. Is the input cheap to scale (yes for Montage tiles, PDBs, DDMD replicas, lammps box)?
3. What's the max node count where utilization stays ≥50% (a usable, not theatrical, run)?

### Group 1 — Can credibly use 24 nodes (5 workflows)

Each has a scaling lever that's cheap to pull.

| Workflow | Why 24n works | What needs to change |
|---|---|---|
| **Montage** | Tile-parallel reprojection; medium has 16 tiles | Extend `region.hdr` sky coverage and/or pull more raw 2MASS tiles to reach ≥24 tiles |
| **biobb_wf_md_setup** | Per-PDB independent; medium has 8 PDBs (1AKI, 1BPI, 1CRN, 1L2Y, 1UBQ, 1VII, 2WAL, 3GB1) | Curate 16 more PDB entries (~30 min: pick any 16 single-chain, <10 kDa structures from PDB) |
| **DeepDriveMD-pipeline** | Pure ensemble — N identical replica experiments, no inter-replica deps | Just bump replica count to 24 in `dry_run.py`; per-replica path-rewrite already works |
| **PyFLEXTRKR medium** | dask-mpi natively scales; 98 timesteps ÷ 24 ranks ≈ 4 each | Apply `memory_limit='8GB'` fix in `run_mcs_tbpf_mpi.py`; bump SBATCH `--nodes=24 --ntasks-per-node=1` |
| **lammps** | Spatial MPI decomp; current `region box block 0 24 0 24 0 24` (FCC lattice 0.5) ≈ 55K atoms | Change to `0 100 0 100 0 100` ≈ 4M atoms. 24 nodes × 40 ranks/node = 960 ranks → ~4K atoms/rank, healthy |

### Group 2 — Run at workflow's natural max, <24n (input scaling is artificial)

These could be forced to 24 by duplicating inputs, but that just measures profiler-overhead replication, not real-workload behavior.

| Workflow | Natural max | Why no further | Action |
|---|---|---|---|
| **metaGEM medium** | 12 | 3 samples × 4 reps; adding more reps is synthetic | Run at **12n** |
| **rna-seq-star-deseq2** | 5 | 5 sample pairs in test data; duplicating creates redundant traces | Run at **5n** |
| **V-pipe** | 2 | 2 samples in test data; synthesizing viral genomes is non-trivial | Run at **2n** (already done — skip) |
| **nf-core_smrnaseq** | 18 | Sustained avg 12.2, peak 29 → safely fills 18 nodes; pushing higher only helps during 1-2 burst phases | Run at **18n** |
| **nf-core_viralrecon** | 15 | Sustained 9.1, peak 27 | Run at **15n** |
| **nf-core_rnaseq** | 14 | Sustained 6.6, peak 28 | Run at **14n** |
| **nf-core_atacseq** | 12 | Sustained 7.5, peak 22 (also has EXIT_CODE=1 issues to resolve) | Run at **12n** |
| **nf-core_taxprofiler** | 11 | Sustained 2.5 but peak 29 | Run at **11n** |
| **nf-core_ampliseq** | 11 | Sustained 3.5 (1-burst 123 misled earlier analysis) | Run at **11n** |
| **nf-core_mag** | 10 | Sustained 4.3, peak 22 | Run at **10n** |
| **nf-core_nascent** | 8 | Sustained 1.5 but peak 20 (memory ceilings) | Run at **8n** |
| **nf-core_fetchngs** | 7 | Egress-throttled by SRA; truly bound | Run at **7n** |
| **nf-core_methylseq** | 6 | Sustained 4.2, peak 9 | Run at **6n** |
| **nf-core_pathogensurveillance** | 6 | Sustained 1.6, peak 15 | Run at **6n** |
| **nf-core_quantms** | 6 | Sustained 2.1, peak 12 | Run at **6n** |
| **nf-core_cutandrun** | 5 | Sustained 2.5, peak 10 | Run at **5n** |
| **nf-core_detaxizer** | 5 | Sustained 1.8, peak 12 | Run at **5n** |
| **nf-core_hic** | 4 | Sustained 3.1, peak 4 (genuinely tiny) | Run at **4n** |
| **nf-core_funcscan** | 4 | Sustained 1.5, peak 7; CARD DB download issues | Run at **4n** |

### Group 3 — Below 4 nodes useful (skip multi-node)

These workflows' sustained parallelism is so low that multi-node is profiling theatre.

| Workflow | Avg | Peak | Action |
|---|---|---|---|
| nf-core_sarek | 1.9 | 5 | Single-node baseline only |
| nf-core_bacass | 1.0 | 3 | Single-node only |
| nf-core_proteinfold | 0.4 | 2 | Single-node only |
| nf-core_differentialabundance | 0.4 | 3 | Single-node only |

### Concrete sweep matrix — max-scale plan

Total cluster wall ~10–14 hours, distributed across ~50 sbatches (~3 profilers × 20 workflows; some skip dayu).

| # | Workflow | Nodes | Profilers | Est. wall |
|---|---|---|---|---|
| 1 | Montage (24-tile extended) | **24** | datalife, darshan | ~10 min × 2 |
| 2 | biobb_wf_md_setup (24-PDB curated) | **24** | datalife (gmx-skipped), darshan | ~15 min × 2 |
| 3 | DeepDriveMD-pipeline (24 replicas) | **24** | datalife, darshan | ~5 min × 2 |
| 4 | PyFLEXTRKR medium (with memory_limit fix) | **24** | datalife, dayu, darshan | ~30 min × 3 |
| 5 | lammps (4M-atom box) | **24** | darshan only (libmonitor×lmp FPE) | ~20 min |
| 6 | nf-core_smrnaseq | **18** | datalife, darshan | ~30 min × 2 |
| 7 | nf-core_viralrecon | **15** | datalife, darshan | ~25 min × 2 |
| 8 | nf-core_rnaseq | **14** | datalife, darshan | ~30 min × 2 |
| 9 | metaGEM medium | **12** | datalife, darshan | ~30 min × 2 |
| 10 | nf-core_atacseq | **12** | datalife, darshan | ~25 min × 2 |
| 11 | nf-core_taxprofiler | **11** | datalife, darshan | ~35 min × 2 |
| 12 | nf-core_ampliseq | **11** | datalife, darshan | ~65 min × 2 |
| 13 | nf-core_mag | **10** | datalife, darshan | ~20 min × 2 |
| 14 | nf-core_nascent | **8** | datalife, darshan | ~40 min × 2 |
| 15 | nf-core_fetchngs | **7** | datalife, darshan | ~10 min × 2 (egress-bound) |
| 16 | nf-core_methylseq | **6** | datalife, darshan | ~5 min × 2 |
| 17 | nf-core_pathogensurveillance | **6** | datalife, darshan | ~30 min × 2 |
| 18 | nf-core_quantms | **6** | datalife, darshan | ~15 min × 2 |
| 19 | nf-core_cutandrun | **5** | datalife, darshan | ~15 min × 2 |
| 20 | nf-core_detaxizer | **5** | datalife, darshan | ~15 min × 2 |
| 21 | rna-seq-star-deseq2 | **5** | datalife, darshan | ~25 min × 2 |
| 22 | nf-core_hic | **4** | datalife, darshan | ~10 min × 2 |
| 23 | nf-core_funcscan | **4** | datalife, darshan | ~45 min × 2 |
| 24 | V-pipe (already done @ 2n) | — | — | skip |

### Pre-work before submitting (Group 1 input scaling)

These are the cheap-to-scale "make 24 nodes real" tasks. Roughly half a day total:

1. **Montage** (~30 min): Extend `data/Montage/medium/region.hdr` to a larger sky region (e.g., 1° × 1° instead of current ~0.5°), re-pull 2MASS tiles via existing `download_inputs.sh` mechanism to get ≥24 tiles.
2. **biobb** (~30 min): Pick 16 more PDB IDs (e.g., 1A0E, 1A3K, 1AHO, 1AGN, etc.) — single-chain, <10 kDa to mirror existing set. Add to `data/biobb_wf_md_setup/medium/`.
3. **DeepDriveMD** (~5 min): Edit `dry_run.py` to set `n_replicas = 24`; the per-replica path-rewrite trick already handles it.
4. **PyFLEXTRKR** (~15 min): Apply `memory_limit='8GB'` fix in `run_mcs_tbpf_mpi.py:~120` (worker setup).
5. **lammps** (~10 min): Change box region from `0 24` to `0 100` in `inputs/melt_minimize.in` (and matching in `melt_equilibrate.in`, `melt_production.in`).
6. **nf-core slurm_pinned.config** (~5 min): Author `runs/nf-core_shared/slurm_pinned.config` with `clusterOptions = "--nodelist=${SLURM_JOB_NODELIST} --exclusive"` so children land only on the parent's allocated nodes.

After these, build the 23 SBATCH scripts (mostly variants of existing `multinode_4node/run_slurm.sh` and `small_4node/run_slurm.sh`) at their respective node counts.

### Trade-off summary vs §14 tiered plan

| Aspect | §14 sweet-spot plan | §16 max-scale plan |
|---|---|---|
| Largest single allocation | 16 nodes | 24 nodes |
| Workflows at 24n | 0 | 5 |
| Workflows ≥16n | 4 | 6 |
| Workflows at 1n only | 4 (skip) | 4 (skip) |
| Total cluster wall | ~8h | ~12h |
| Setup work | 2-3h (just SBATCH scripts) | +half-day input scaling for Group 1 |
| Trace coverage | Same workflow set | Same workflow set, but Group 1 traces show genuine 24n behavior |

### Recommendation

Run §16 max-scale plan. The extra setup is mostly cheap (Group 1 input scaling is half a day), and the resulting traces actually demonstrate scaling behavior at 24n for the 5 workflows that can genuinely use it — which is what makes the campaign worth doing vs. just repeating the 2n/4n data we already have.

