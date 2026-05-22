# Reduced PNNL Validation Prompt (v1.0) — 2 workflows × 4 nodes

> Derived from `prompts/merged-prompt.md` (v3.0). This is a **scoped-down**
> operating brief to validate the I/O-profiling harness on **PNNL Deception**
> before any full-scale campaign. It is NOT the 53-workflow mission.

---

## Scope (what "reduced" means here)

- **2 workflows only:** `nf-core_methylseq` (#27) and `nf-core_smrnaseq` (#37).
  Both are nf-core / Class C (Nextflow driver) — chosen because the canonical HQ
  launcher already exists for them and they share one toolchain (low setup cost,
  validates the PNNL port twice with different tools).
- **4 nodes** per run (not ≥4-up-to-full). Partition `slurm` (default), account
  `oddite` (the `datamesh` account is frozen: `GrpJobs=0`).
- **Harness-validation goal, not a profiled `pass`.** `-profile test,conda` is
  ACCEPTABLE here because the user said "no full scale yet — just test it." Under
  the full `merged-prompt`, test data ≠ `pass`; realistic-input runs are the
  follow-up once the PNNL plumbing is proven end-to-end.
- Both profilers (DataLife + Darshan) must independently produce valid, parseable
  traces. DaYu is N/A (HDF5-VOL only; neither workflow uses HDF5).

## Definition of done (reduced)

Per workflow, mark the reduced `table.md` cell `pass` only when, for a **4-node
SLURM run**:
1. SLURM job exits 0 **and** Nextflow reports pipeline success (its own
   "Succeeded"/completion summary) — not merely the wrapper exiting.
2. Expected `--outdir` outputs exist and are non-trivial.
3. **Both** a DataLife run **and** a Darshan run (separate jobs, Rule 7) each
   produced non-empty, parseable traces, confirmed by
   `scripts/verify_ares_runs.py`.

## How to run (PNNL)

One generic launcher: `runs/nf-core_shared/hq_nfcore_pnnl.sbatch`.
```bash
sbatch --account=oddite --job-name=<wf>_<prof>_4n \
  -o runs/<wf>/multinode_4node_hq_<prof>/logs/slurm_%j.out \
  -e runs/<wf>/multinode_4node_hq_<prof>/logs/slurm_%j.err \
  --export=ALL,WF=<wf>,PROFILER=<datalife|darshan|plain>,NF_PROFILE=test \
  runs/nf-core_shared/hq_nfcore_pnnl.sbatch
```
- HyperQueue owns N whole nodes (1 HQ worker/node, `--cpus=64`); Nextflow's `hq`
  executor spreads tasks — no child sbatch, no `--exclusive` deadlock (Bootstrap §2).
- Profiler injected per-task by `hq_<profiler>.config` `beforeScript` (after conda
  activation). Traces → **node-local `/scratch`**, collected to the run dir after
  (Bootstrap §4 — avoids the NFS-contention exit-130).
- Exactly ONE profiler per job (Rule 7). Never put `--ntasks=1` on the parent
  (Rule 1 trap); use `--ntasks-per-node=1`.

## Validate

```bash
python3 scripts/verify_ares_runs.py runs/<wf>/multinode_4node_hq_datalife
python3 scripts/verify_ares_runs.py runs/<wf>/multinode_4node_hq_darshan
```
(Adapter already pointed at PNNL widget src + darshan-parser.)

## Operating principles (carried from merged-prompt)

- **Never abandon; park + log + move on; round-robin** between the 2 workflows so
  neither stalls the other. Only success ends work on a workflow.
- **State surfaces:** `log.md` (append-only working memory: every attempt, job IDs,
  errors, input source), `table.md` (human-facing: empty or `pass` only).
- On an **undocumented error pattern: STOP and report** rather than burning retries.
- `EXIT_CODE=0` with single-node compute is a FAILURE — verify node spread
  (hostnames in `logs/env_at_start_*.txt`; HQ worker count == 4).

## PNNL environment (the cluster-port deltas vs Ares)

| What | PNNL Deception value |
|---|---|
| Scheduler / partition / account | SLURM / `slurm` (default) / `oddite` |
| Node spec | 64 CPU, 256 GB |
| WORKFLOW_ROOT | `/qfs/projects/datamesh/tang584/widget_evaluation/hpc_workflows` |
| WIDGET_ROOT | `/qfs/projects/datamesh/tang584/widget_evaluation/widget-v1` (branch `delta`) |
| DataLife libmonitor | `$WIDGET_ROOT/profiler/datalife/build/flow-monitor/src/libmonitor.so` |
| Darshan (lib / parser) | `/people/tang584/install/darshan_runtime/{lib/libdarshan.so,bin/darshan-parser}` |
| Darshan non-MPI | `DARSHAN_ENABLE_NONMPI=1` REQUIRED; logs to `$DARSHAN_LOGPATH/Y/M/D` (pre-create) |
| node-local trace dir | `/scratch/$USER/...` (per-node `/dev/sda1`, ~233 GB) |
| Java 17 / conda | system `/usr/bin/java` 17 / `/share/apps/python/miniconda25.5.1` |
| Nextflow / HyperQueue | `/qfs/people/tang584/install/nextflow` (25.10.2) / `tools/hyperqueue/hq` (v0.26) |
| Compute-node internet | YES (conda + nf-core test-data fetch on compute work) |

## Reporting

At each phase boundary post per-workflow pass/fail, node-spread verified yes/no,
and trace counts; then continue. On status request render the 2-row `table.md` +
a one-line rollup + what's parked and why (from `log.md`).
