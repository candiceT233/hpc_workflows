# PNNL Port — Bootstrap & Handoff for a New Agent

This is the minimum a fresh agent on a PNNL cluster needs to get the workflow
I/O-profiling campaign functional. Read `prompts/merged-prompt.md` for the full
operating rules; this file is the cluster-port checklist + the hard-won
architecture decisions that aren't obvious from the code.

---

## 0. Repos to clone (both required)

```bash
# 1. Profiling toolkit (libmonitor / DataLife + DaYu + verification.py)
git clone -b delta https://github.com/candiceT233/widget-v1.git
cd widget-v1 && git submodule update --init --recursive   # pulls datalife@delta, dayu

# 2. Campaign harness (workflows, configs, launchers, patches, prompts)
git clone -b delta https://github.com/candiceT233/hpc_workflows.git
```

You need **both**. widget-v1 has the profilers; hpc_workflows has the workflows
+ SBATCH/HQ launchers + verification adapter + patches.

---

## 1. Build libmonitor (DataLife)

```bash
cd widget-v1/profiler/datalife
bash agent/build.sh         # already passes -DTIMER_JSON=ON (REQUIRED)
md5sum build/flow-monitor/src/libmonitor.so
```

`build.sh` (datalife@delta, commit ≥ 8bd0625) enables `-DTIMER_JSON=ON` so the
`monitor_timer.<pid>-<host>.datalife.json` files get written. Without those,
`verification.py` fails criterion 3 even when block traces exist.

libmonitor@delta already contains the four Ares-discovered fixes:
1. wrapper-helper skip list (ps/grep/awk/sed/head/tail/cat/ls/wc/cut/sort/uniq/tr/expr/date) — avoids nxf_tree destructor pile-up.
2. `tty`/`stty`/`tput` in the skip list — avoids Nextflow tty-parse abort.
3. skip files inside `$DATALIFE_OUTPUT_PATH` — avoids recursive trace-filename explosion.
4. destructor `[MONITOR]` output → stderr (`dup(2)`) — avoids polluting child-process stdout that Nextflow parses as YAML.

(Backup of the source diff: `hpc_workflows/patches/widget/libmonitor_ares_fixes.patch`.)

---

## 2. Get HyperQueue (the executor that makes nf-core multi-node work)

```bash
mkdir -p hpc_workflows/tools/hyperqueue && cd hpc_workflows/tools/hyperqueue
ver=$(curl -sfL https://api.github.com/repos/It4innovations/hyperqueue/releases/latest \
      | grep tag_name | sed -E 's/.*"([^"]+)".*/\1/')
curl -sfL -o hq.tar.gz \
  "https://github.com/It4innovations/hyperqueue/releases/download/${ver}/hq-${ver}-linux-x64.tar.gz"
tar xzf hq.tar.gz && ./hq --version    # static binary, no root needed
```

**Why HyperQueue, not the Nextflow `slurm` executor:** nf-core pipelines are
Class C (a Nextflow driver that schedules tasks). The `slurm` executor submits
one child `sbatch` per task, which on a node-pinned parent **deadlocks**
(children can't get onto the parent's nodes). HyperQueue replaces that: one
SLURM allocation owns N whole nodes, an HQ server + one HQ worker per node
distribute the tasks. No child sbatch, no `--nodelist` pinning, no `--exclusive`
deadlock. Proven on Ares: tasks spread across all allocated nodes.

---

## 3. The working run pattern (HQ + DataLife)

See `runs/nf-core_methylseq/multinode_2node_hq_datalife/run_slurm.sh` as the
canonical launcher. Skeleton:

```
#SBATCH --nodes=N --ntasks-per-node=1 --cpus-per-task=<full node> --mem=<full node>
export HQ_SERVER_DIR=$RUNDIR/.hq_$SLURM_JOB_ID
hq server start &                              # head node
srun --ntasks-per-node=1 hq worker start --cpus=<full> &   # one worker per node
# DataLife traces to NODE-LOCAL disk (NOT shared FS — see §4), then collected:
export DATALIFE_OUTPUT_PATH=<node-local>/traces
nextflow run <wf>/main.nf -profile <realistic>,conda -c runs/nf-core_shared/hq_datalife.config ...
srun --ntasks-per-node=1 cp -a <node-local>/traces/. <shared>/   # collect
hq worker stop all; hq server stop
```

Configs (in `runs/nf-core_shared/`):
- `hq.config`          — plain HQ executor (no profiling)
- `hq_datalife.config` — HQ + per-task `beforeScript` injecting `LD_PRELOAD`
  (libmonitor) AFTER conda activation, with `DATALIFE_JSON_OUTPUT=1`. This is how
  the science tools (not just the driver) get traced.

For Class A (Snakemake/srun-fanout) and Class B (MPI/dask-mpi) workflows, HQ is
not needed — they own their nodes directly. See `prompts/merged-prompt.md` Rule 1.

---

## 4. CRITICAL: trace output to node-local disk, not shared FS

DataLife writes one `monitor_timer.*.json` per traced process. nf-core tasks
spawn thousands of processes; writing them all to a shared NFS dir simultaneously
overwhelms NFS + the HQ server and gets early tasks SIGINT'd (exit 130, observed
on Ares). **Write traces to per-node local disk** (Ares: `/mnt/ssd/mtang11`;
PNNL: pick the node-local scratch), then `srun`-collect to shared storage after
the workflow finishes. The launcher in §3 shows the pattern.

> STATUS: the node-local-trace fix is implemented in the HQ launchers but its
> end-to-end pass was still being validated when this was written (the 2-node
> methylseq test was queued behind a busy cluster). Plain HQ (no profiling) is
> fully proven. Re-confirm the datalife-under-HQ pass before scaling out.

---

## 5. Verification (definition of done, criterion 3)

```bash
PYTHONPATH=widget-v1/src python3 hpc_workflows/scripts/verify_ares_runs.py <run_dir>
```

`verify_ares_runs.py` adapts widget's `dfl_mcp.verification` to TAG-suffixed run
dirs and samples darshan logs by size. **Change `ARES_DARSHAN_PARSER`** at the
top to PNNL's darshan-parser path. It checks: workflow success (trace.txt rows),
DataLife schema (blk_trace.json + monitor_timer), Darshan parseability + nonzero
POSIX bytes.

Known Darshan caveat: `DARSHAN_MODMEM` is NOT honored by the 3.5.0 build tested
(compile-time record cap) — high-fan-out metadata processes (java driver,
python) truncate with "POSIX module contains incomplete data". The science-tool
logs are what carry real I/O; with realistic data they dominate. Don't block on
driver-log truncation.

---

## 6. Cluster-specific things to change for PNNL

| What | Where | Ares value (replace) |
|---|---|---|
| Partition names / node counts / per-node cpu+mem | every SBATCH header | compute/datacrumbs, 40cpu/47GB |
| `WORKFLOW_ROOT` | every launcher | /mnt/common/mtang11/hpc_workflows |
| libmonitor path (`DATALIFE_LIB`) | launchers | widget-v1/profiler/datalife/build/.../libmonitor.so |
| libdarshan + darshan-parser paths | darshan launchers + verify_ares_runs.py | /home/mtang11/hpc_workflows/tools/darshan/... |
| node-local trace dir | HQ launchers (`LOCAL_TRACE_ROOT`) | /mnt/ssd/mtang11 |
| Java 17 / conda roots | launchers | tools/java17/..., /mnt/common/mtang11/miniconda3 |
| HyperQueue binary | tools/hyperqueue/hq | (download per §2) |

The 6 non-submodule workflow repos (lammps, nwchem, parsl, pegasus, PtychoNN,
radical.pilot) must be `git clone`d — see `prompts/merged-prompt.md` clone table.

---

## 7. Patches to re-apply

`hpc_workflows/patches/`:
- `PyFLEXTRKR_dask_memory_limit.patch` — dask-mpi `memory_limit='8GB'` (auto-detect
  OOMs at scale). Apply to each `runs/PyFLEXTRKR/multinode_*/run_mcs_tbpf_mpi.py`.
- `widget/libmonitor_ares_fixes.patch` — backup of the libmonitor source fixes
  (already in datalife@delta; here for reference / re-apply if building from a
  different base).
- Other `<wf>.patch` files — workflow-specific source fixes.

---

## 8. Generators / helpers

- `scripts/gen_multinode_sbatches.py` — stamps slurm-executor multinode scripts
  from `small_4node` templates (Phase 1/2/3 lists). NOTE: this predates the HQ
  pivot; it produces `executor=slurm` scripts. For nf-core on PNNL, prefer the
  HQ launcher pattern (§3). Keep the generator for Class A/B or adapt it to emit
  HQ launchers.
- `scripts/verify_ares_runs.py` — verification adapter (§5).

---

## 9. What's proven vs in-progress (honest status as of handoff)

- ✅ HyperQueue executor end-to-end (plain methylseq ran full pipeline on 2 nodes,
  tasks spread across both)
- ✅ libmonitor 4 fixes + TIMER_JSON build (smoke-tested: clean stdout, timer +
  blk_trace.json produced)
- ✅ DataLife per-task injection under HQ produces real child-tool block traces
  (named by data files) + timer files
- 🟡 DataLife-under-HQ full PASS (exit-130 fix via node-local traces) — implemented,
  final verification pending (cluster was busy)
- 🟡 Realistic-input sourcing — not started; all runs so far used `-profile test`
  (harness validation only, not profiled passes per merged-prompt criterion)
- ⚠️ Darshan `DARSHAN_MODMEM` truncation on metadata-heavy processes — known, not
  blocking science-tool I/O
