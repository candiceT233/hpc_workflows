# DaYu visualization layer — TODO (lower priority; fix after scale runs)

Status: **the DaYu I/O capture + analysis DATA path is fixed and validated** (VOL+VFD
stats clean, per-stage; `task_file_dep_extract.py` reconstructs the correct per-stage
dataflow DAG — see `hpc_workflows/log.md` 2026-05-20). Only the **Sankey renderer**
(visualization) is broken.

## Issue
`widget-v1/profiler/dayu-tracker/agent/analysis/vol_only.py::build_vol_sankey()` **hangs**
(pathologically slow / non-terminating) in the node-positioning step on the PyFLEXTRKR
saag_summer_sam DAG (~43 task instances across 9 stages). It gets past:
- `utils/stat_loader.load_stat_json` (loads all VOL stat files) ✓
- `utils/vol_stat2graph` task→file graph build + initial node positioning ✓ (prints node positions)
then stalls before emitting the HTML. No `*_sankey.html` is produced; the process must be killed.

Likely culprits (to investigate): the positioning loop in
`flow_analysis/utils/vol_stat2graph.py` / `vol_graph2sankey.py` (possible O(n^2+)/cyclic
re-positioning), or `prepare_sankey_stat` / time-positioning when nodes share positions.
`build_vfd_sankey` and `vol_vfd_combined` likely share the same code path — check all three.

## Reproduce
```bash
conda activate pyflextrkr   # plotly 6.7.0, networkx 3.1 now installed
cd widget-v1/profiler/dayu-tracker
python flow_analysis/task_file_dep_extract.py -path <RUNDIR> -wf dayu_traces   # OK, builds task_to_file.json
python -c "import sys; sys.path.insert(0,'agent'); from analysis.vol_only import build_vol_sankey; \
  build_vol_sankey('<RUNDIR>/dayu_traces', '/tmp/v.html', test_name='dayu_traces')"   # HANGS
```
(`<RUNDIR>` = hpc_workflows/runs/PyFLEXTRKR/multinode_4node_dayu; needs `task_order_list.json`
in the stat dir — the 9 PyFLEXTRKR stages, already present.)

## Not affected
The data the renderer consumes is correct: `dayu_traces-task_to_file.json` has the full
per-stage I/O DAG with io_cnt. The C tracker (VOL+VFD) fix is unrelated and done.
