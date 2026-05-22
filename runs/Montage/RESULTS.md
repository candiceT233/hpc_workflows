# Montage mProjectPP scaling eval — results (PNNL Deception)

**Workload:** Montage `mProjectPP` reprojection, Class-A fan-out, **1 process per tile**,
~32 concurrent per node. I/O-heavy / compute-light (each tile: read ~2 MB → write output +
area ≈ 4.2 MB). Synthetic 512×512 float64 FITS tiles (~2.0 MB each), reprojected against a
shared `template.hdr`.

**Filesystem:** all workload I/O on **BeeGFS** (`/rcfs/projects/chess/tang584/montage_eval`):
input tiles read from BeeGFS, reprojected outputs written to BeeGFS. Profiler trace output is
written node-local (`/scratch`) then collected to BeeGFS — so the profiler's own writes do
**not** pollute the BeeGFS workload-I/O measurement.

**Profilers:** DataLife and Darshan, **collected in SEPARATE passes — never stacked** (two
POSIX-interception libs under one `LD_PRELOAD` would corrupt both traces). One pass per
profiler, one trace per tile.

## Results (120 nodes)

| Scale | Tiles | Nodes | Pass | Elapsed | Outputs | Traces collected |
|---|---:|---:|---|---:|---:|---|
| 6 GB verify | 3,000 | 120 | DataLife | 36s | 3,000 | 3,000 `*.datalife.json` (120 tarballs) |
| 6 GB verify | 3,000 | 120 | Darshan | 42s | 3,000 | 3,000 `*.darshan` (120 tarballs) |
| **30 GB full** | **15,000** | 120 | DataLife | 119s | 15,000 | **15,000** `*.datalife.json` (120 tarballs) |
| **30 GB full** | **15,000** | 120 | Darshan | 118s | 15,000 | **15,000** `*.darshan` (120 tarballs) |

Both scales: `overall_rc=0`, per-shard output count exact (125 tiles/node × 120 = 15,000).
DataLife emits `monitor_timer.<pid>-<host>.datalife.json` (per-call I/O profile); Darshan
emits one `.darshan` per process (NONMPI), parseable with `darshan-parser` (confirmed: exe +
BeeGFS paths + POSIX counters captured).

## Trace locations (BeeGFS)
```
/rcfs/projects/chess/tang584/montage_eval/run_30gb_120node_<jobid>/datalife/traces/*.tar.gz   (120 node tarballs, 15000 json)
/rcfs/projects/chess/tang584/montage_eval/run_30gb_120node_<jobid>/darshan/traces/*.tar.gz    (120 node tarballs, 15000 logs)
```

## Scripts (this repo, `runs/Montage/scale_prof/`)
- `run_montage_prof.sbatch` — launcher (separate profiler passes, BeeGFS I/O, node-local→BeeGFS trace collection)
- `montage_worker.sh` — per-node worker (shards tiles, one mProjectPP/tile under exactly one profiler; hard-refuses stacking)
- `gen_tiles.py` + `gen.sbatch` — synthetic tile generator (N × 512² f64 FITS + shared template.hdr)
- `smoke.sh`, `debug_datalife.sh` — single-node validation helpers

## Notes
- Montage toolkit: prebuilt at `/qfs/people/tang584/install/Montage/bin` (123 tools) — no build needed.
- DaYu is **N/A** for Montage (no HDF5/NetCDF) → DataLife + Darshan are the right profilers.
- Task count (15,000) far exceeds PyFLEXTRKR's 962 files — this is the "blow up the scale" axis (cheap fan-out, add tiles).
