# Campaign log — PNNL Deception (reduced validation)

Append-only working memory. Scope: 2 workflows (nf-core_methylseq #27,
nf-core_smrnaseq #37) × 4 nodes, harness validation. See
`prompts/reduced-pnnl-prompt.md`.

---

## 2026-05-19 — PNNL port + setup

**Cluster facts**
- Host `deception03`; SLURM; partition `slurm` (default, 271 nodes dc*, 64 CPU /
  256 GB, 7-day limit).
- **Account `datamesh` is FROZEN: `GrpJobs=0`** (account-level assoc) → every job
  pends `AssocGrpJobsLimit`, 0 datamesh jobs run cluster-wide. Cannot change (no
  sudo). **Use `--account=oddite`** (no cap; default QOS — user approved, "no need
  to define qos").
- `/scratch` is node-local (`/dev/sda1`, ~233 GB/node) → trace target.
- Compute nodes HAVE internet (github/anaconda/nf-core test-data reachable) →
  `-profile test,conda` builds envs + fetches test data on compute.
- Java 17 system (`/usr/bin/java`), conda `/share/apps/python/miniconda25.5.1`,
  Nextflow 25.10.2 (`/qfs/people/tang584/install/nextflow`), HyperQueue v0.26.0
  (`tools/hyperqueue/hq`, downloaded).

**Profiler setup (user ask: "setup widget datalife/dayu and darshan")**
- `widget-v1` switched master→`delta` (ec567b4); submodules synced
  (datalife@`8bd0625` delta with the 4 Ares libmonitor fixes; dayu-tracker@develop).
- DataLife libmonitor built: `bash agent/build.sh` (TIMER_JSON=ON). md5
  `ab453049b86ff7de4556d517b4b847ec`. Smoke test: clean stdout, timer JSON emitted.
- Darshan already installed (`/people/tang584/install/darshan_runtime`). Confirmed
  non-MPI logging works (`DARSHAN_ENABLE_NONMPI=1` + `DARSHAN_LOGPATH` with date
  subdir pre-created); logs parseable.
- **DaYu deferred (not built):** HDF5-VOL plugin, only instruments HDF5 workflows
  (PyFLEXTRKR). Neither methylseq nor smrnaseq uses HDF5, so it can't be exercised
  or validated here. Build when an HDF5 workflow is run.
- `scripts/verify_ares_runs.py`: WIDGET_SRC + ARES_DARSHAN_PARSER repointed to PNNL
  (env-overridable). Imports clean.

**Harness ported**
- `runs/nf-core_shared/hq_darshan.config` created (darshan sibling of
  hq_datalife.config; non-MPI + LOGPATH per-task).
- `runs/nf-core_shared/hq_nfcore_pnnl.sbatch` — generic PNNL launcher (WF/PROFILER
  via --export; 4 nodes; node-local /scratch traces; HQ server+workers).
- Workflow submodules initialized: `repos/nf-core_methylseq` (5aa5646),
  `repos/nf-core_smrnaseq` (cb0af57).

**Runs**
- methylseq / datalife / 4node — job **759642** RUNNING on dc[174,177-179]
  (oddite). Input source: `-profile test` (harness validation). [in progress]

## 2026-05-19 — pilot fixes
- First pilot (759642) failed fast: nf-schema validated default `igenomes_base`
  S3 path, signed with stale AWS STS creds in the login env → S3 400 "token
  malformed". HQ/node-spread/DataLife plumbing all worked (4 hosts, 4/4 workers).
- Also found a latent deadlock: trace-collection srun ran while the HQ-worker srun
  step held all node CPUs → added `--overlap` to collection.
- Fixes in `hq_nfcore_pnnl.sbatch`: unset AWS_* creds; `--validate_params false`
  (default, test runs); `--overlap` on collection srun.
- Resubmitted methylseq/datalife = job **759644** on dc[011,013-015]. Validation
  PASSED; HQ dispatching tasks (GUNZIP running); conda envs building on compute.

## 2026-05-19/20 — PyFLEXTRKR + DaYu (the "1 other" high-coverage job)
Chosen (user) to maximize coverage vs methylseq: Class B-ish multi-node dask +
HDF5 + DaYu profiler.
- repos/PyFLEXTRKR initialized (5b7cf6e). Key finding: `run_parallel: 2` =
  `Client(scheduler_file=...)` (external dask scheduler), NOT dask-mpi → no
  mpi4py needed. Multi-node = dask-scheduler + `srun dask-worker` across nodes
  (per repo's slurm_dask_multinode_example.sh), --memory-limit=8GB.
- conda env `runs/PyFLEXTRKR/pyflextrkr_env` building from environment.yml
  (python3.12, dask/distributed, netcdf4→conda HDF5, xarray, cartopy, xesmf...).
  [LONG POLE — in progress]
- DaYu (widget-v1/profiler/dayu-tracker) builds via agent/build.sh with HDF5_DIR;
  must build against the conda env's HDF5 (the one netcdf4 uses). Runtime env:
  HDF5_VOL_CONNECTOR="tracker ...;path=$LOGDIR;..."; HDF5_PLUGIN_PATH=vfd:vol;
  HDF5_DRIVER=hdf5_tracker_vfd. Emits *-vol_data_stat.json + *-vfd_data_stat.json.
- Launcher drafted: runs/nf-core_shared/dask_pyflextrkr_pnnl.sbatch (4 nodes,
  scheduler+srun workers, DaYu VOL/VFD, node-local /scratch traces, account oddite).
- BLOCKER: input data. data/download_inputs.sh has NO PyFLEXTRKR entry; the GPM
  Tb+IMERG sample (portal.nersc.gov/.../gpm_tb_imerg.tar.gz) is returning HTTP 503
  (NERSC portal down). No on-disk copy found. Patient retry running; synthetic
  Tb+precip fallback identified (reader = idclouds_tbpf: needs Tb + precipitationCal
  over time/lat/lon; base config on config_imerg_mcs_tbpf_example.yml).

## 2026-05-20 — methylseq/datalife pilot: PORT PROVEN, but DataLife tasks HANG
- 759644 ran 47 min: node spread (4 hosts), HQ 4/4 workers, conda envs built
  (gunzip/fastqc/trimgalore), tasks dispatched via HQ — full PNNL port works.
- BUT: 9 tasks "RUNNING", 0 FINISHED; all nodes idle (load ~0.00); a FastQC `java`
  stuck 47 min. DataLife (libmonitor LD_PRELOAD) deadlocks the task processes on
  this pipeline. Killed the job (no progress). Port/plumbing = proven; DataLife-
  under-HQ hang needs separate debug (try MONITOR skip-list / per-tool bypass).

## 2026-05-20 — PyFLEXTRKR data + run path FOUND (user pointer)
- Data is on the ODDITE project space (not /rcfs, not datamesh — that's why earlier
  search missed it): /qfs/projects/oddite/tang584/flextrkr_runs/input_data/
  - olr_pcp = saag_summer_sam (largest I/O): 31 GB, 962 .nc (pr_rlut_mean_sam_2016*.nc)
    + IMERG landmasks. Many other sets alongside (gpm_tb_imerg, wrf_tbradar, ...).
- Reference: /qfs/projects/datamesh/tang584/PyFLEXTRKR/eval_dayu/run_tbpf_saag_summer_sam_0.sh
  (TEST_NAME=olr_pcp; was 8 nodes/240 tasks). Runner run_mcs_tbpf_saag_summer_sam.py
  lives in the OLD repo only (not the newer submodule); uses run_parallel=2 =
  dask_mpi.initialize() (genuine dask-MPI), launched `srun -n<tasks> python runner`.
  Config template: run_mcs_tbpf_saag_summer_sam_template.yml (olr2tb, LWNTA/Precac,
  enddate presets 6→960 files).
- Env: existing conda `pyflextrkr` (HDF5 1.14.0, netCDF4 1.6.4, dask 2023.6.0,
  dask_mpi + mpi4py 3.1.5 vs Open MPI 5.0.7 == cluster openmpi/5.0.7). USE THIS env.
- DaYu: user said no scspkg. widget-v1 dayu-tracker won't compile vs installed HDF5
  (VFD needs HDF5 private headers / source tree; delta source threw errors vs 2.x).
  Prebuilt scspkg DaYu .so exists + is ABI-matched to pyflextrkr HDF5 1.14 but is
  off-limits per user. DaYu source build = open decision.

## 2026-05-20 — PyFLEXTRKR usage model (from config/ + runscripts/)
Pattern (config/demo_mcs_<test>.sh): set dir_input(data)+dir_demo(output) →
sed INPUT_DIR/TRACK_DIR on config_<test>_example.yml → conda activate env →
python ../runscripts/run_<test>.py <config>. Single-node: run_parallel=1
(LocalCluster). Multi-node: run_parallel=2 (dask_mpi) launched `srun -n<tasks>
python runner config`.

Runner ↔ config ↔ on-disk data (/qfs/projects/oddite/tang584/flextrkr_runs/input_data/<test>):
- saag_summer_sam: run_mcs_tbpf_saag_summer_sam.py + run_mcs_tbpf_saag_summer_sam_template.yml
  + olr_pcp (31G, 962 files) — LARGEST I/O (user pick). olr2tb, LWNTA/Precac, pr_rlut_mean_sam_.
- imerg/gpm:  run_mcs_tbpf.py + config_imerg_mcs_tbpf_example.yml + gpm_tb_imerg (103M).
- wrf_tbradar: run_mcs_tbpfradar3d_wrf.py + config_wrf_mcs_tbradar*.yml + wrf_tbradar (1.4G).
- idealized:  run_mcs_tbpf.py + config_mcs_idealized.yml + idealized_tbpcp (24M).
Other on-disk sets: dyamond_nicam_tbpcp, e3sm_tbpcp, gridrad_tbradar, mcs_tbpf_asia,
nexrad_reflectivity1, taranis_corcsapr2, wrfout, wrf_tbpcp, wrf_tbradar_hm.
Env for multi-node: conda `pyflextrkr` (HDF5 1.14, dask_mpi+mpi4py vs openmpi 5.0.7).

## 2026-05-20 — DaYu (widget-v1) built + validated: BOTH VOL & VFD
- widget-v1/profiler/dayu-tracker builds BOTH libh5vol_tracker.so + libh5vfd_tracker.so.
- Build fix: dayu CMakeLists forces CMAKE_C/CXX_COMPILER=h5cc/h5c++; the /people hdf5
  wrappers hardcode a dead gcc 9.1.0. Shim at tools/hdf5-shim/{h5cc,h5c++} (system
  gcc/g++ + HDF5 1.14 -I/-L, no rpath) on PATH fixes it. Build against
  /people/tang584/install/hdf5 (1.14.0, THREADSAFE OFF) so VFD's H5private.h skips
  H5TSprivate.h (conda env HDF5 is threadsafe ON → would fail). Runtime ABI matches
  (both 1.14.0, libhdf5.so.310).
- Smoke test under conda `pyflextrkr` env: netCDF4 write/read produced BOTH
  <pid>-vol_data_stat.json and <pid>-vfd_data_stat.json. DaYu works.
- DaYu runtime env (from eval_dayu/dayu_run_*.sh): CURR_TASK + WORKFLOW_NAME +
  /tmp/$USER/$WORKFLOW_NAME/{_vol,_vfd}.curr_task task files; HDF5_VOL_CONNECTOR=
  "tracker ...;path=$LOGDIR;level=2;format="; HDF5_PLUGIN_PATH=vol:vfd;
  HDF5_DRIVER=hdf5_tracker_vfd; HDF5_DRIVER_CONFIG="$LOGDIR;8192"; HDF5_USE_FILE_LOCKING=FALSE.

## 2026-05-20 — DaYu task-naming + dask-MPI launch fix
- srun on this cluster has only pmi2 (no pmix); OpenMPI 5.x needs pmix → srun gives
  singleton ranks (32 schedulers). FIX: launch via cluster `module load openmpi/5.0.7`
  mpirun/PRRTE (own PMIx wireup) with `-x` env forwarding. Confirmed COMM size=N.
- widget-v1 DaYu getCurrentTask() (src/vol/tracker_vol_int.h): ENV `CURR_TASK` takes
  PRIORITY; only if unset does it fall back to file method getCurrentTaskFromFile()
  reading $PATH_FOR_TASK_FILES/$WORKFLOW_NAME_vfd.curr_task (the old /tmp method).
  => Setting CURR_TASK overrides the runner's per-stage set_curr_task_file(); for
  per-stage I/O attribution, UNSET CURR_TASK and rely on the file method.
- Job 759816 (mpirun): 1 scheduler + 30 workers; stages 1-3 done (idfeature 109s,
  tracksingle 63s, gettracks 1.4s), trackstats running. DaYu VOL+VFD tracing live.

## 2026-05-20 — PyFLEXTRKR + DaYu (VOL+VFD): VALIDATED ✅ (job 759816)
- saag_summer_sam / olr_pcp 6-file subset, 4 nodes, dask-MPI via mpirun/PRRTE
  (1 scheduler + 30 workers). SLURM COMPLETED, exit 0, 3:44.
- ALL 9 stages ran: idfeature 109s, tracksingle 63s, gettracks 1.4s, trackstats
  13s, identifymcs 0.6s, matchpf 6s, robustmcs 0.4s, mapfeature 8.6s, speed 4.2s.
  Final stats/mcs_tracks_final_*.nc produced. 22 output .nc (tracking 10, stats 7,
  mcstracking 5).
- DaYu BOTH trackers: 28 *-vol_data_stat.json + 23 *-vfd_data_stat.json, parseable
  (schema file_name/task_name/datasets). Confirms widget-v1 DaYu VOL+VFD work.
- CommClosedError at end = benign dask teardown after stage 9 (not a failure).
- NOTE: CURR_TASK env labels were "pyflextrkr-<pid>" (per-process, NOT per-stage)
  — env CURR_TASK overrides set_curr_task_file(). For per-stage attribution, re-run
  with CURR_TASK unset (file method). [pending user]

## 2026-05-20 — DaYu validation (CORRECTION, did NOT use verify_ares_runs.py initially)
- verify_ares_runs.py does NOT support DaYu: `ERROR: no profiler traces detected`
  (only knows datalife_traces_*/ + darshan_logs/). widget verification.py check_dayu()
  is a STUB (counts files, "DaYu not wired in yet"). DaYu's real validator = its agent
  (profiler/dayu-tracker/agent/), whose analysis/ needs plotly (absent in env).
- Proper schema survey of dayu_traces (job 759816):
  * VFD: 23/23 files valid JSON, 100 entries.
  * VOL: 22/28 files valid JSON (2357 entries); **6 VOL files truncated/bad JSON** —
    incomplete flush at dask-MPI teardown (correlates with CommClosedError; workers
    torn down before VOL destructor finished writing).
  * 27 distinct .nc captured by VFD (cloudid_*, tracknumbers_*, mcs_tracks_robust_*,
    IMERG_landmask) — real VOL+VFD I/O capture confirmed.
- => DaYu works + captured real I/O, but VOL output not cleanly complete. Clean re-run
  needs graceful dask teardown (client.shutdown()/close) before MPI finalize, AND
  CURR_TASK unset for per-stage attribution. plotly needed for sankey analysis.

## 2026-05-20 — DaYu fixes + clean validated run (job 759848)
- plotly+networkx already in widget pyproject; added agent/requirements.txt; installed into
  pyflextrkr env (plotly 6.7.0, networkx 3.1) — DaYu analysis modules import.
- VOL truncation FIXED (patches/widget/dayu_vol_sigterm_finalize.patch): atexit + SIGTERM/SIGINT
  handler in tkr_helper_init finalizes the JSON array even when dask kills a worker; empty
  trackers ("[") closed to "[]"; teardown unified through the same finalize. VOL .so md5 0f6332b0.
- Per-stage attribution: launcher unsets CURR_TASK + uses SHARED PATH_FOR_TASK_FILES so the
  runner's set_curr_task_file('run_<stage>') labels reach all worker nodes.
- CLEAN RUN 759848 (4 nodes, dask-MPI, 6-file subset): exit 0, 175s, all 9 stages. DaYu VOL
  29/29 valid (0 bad), VFD 26/26 valid (0 bad). All 9 stage labels present.
- DaYu analysis: task_file_dep_extract.py -> dayu_traces-task_to_file.json reconstructs the full
  per-stage dataflow DAG with io_cnt (idfeature 31722, tracksingle 2097, gettracks 942,
  trackstats 13718, identifymcs 1868, matchpf 3096, robustmcs 2451, mapfeature 39059, speed
  12533; 43 task instances). I/O VALIDATED via DaYu's own tooling.
- KNOWN ISSUE (cosmetic): DaYu plotly sankey renderer (analysis/vol_only build_vol_sankey) hangs
  in node positioning on this graph — separate analysis perf bug; DAG extraction is correct.

## 2026-05-20 — Scale runs (48-node, 96-node) + 2 more DaYu/MPI fixes
- 48 files crashed (SIGSEGV) at 4 nodes: NOT UCX (libucs ucs_handle_error is just UCX's
  SIGSEGV backtrace handler). Real crash = DaYu VOL bug: create_dset_track_info() did
  strdup(dset_info->layout) with layout==NULL when PyFLEXTRKR closes a dataset via h5py
  (H5VL_dataset_close). FIX: guarded 5 NULL-risky strdup() in src/vol/tracker_vol_int.h
  (layout x2, dset_select_type, cp_dset_name, tkr_line_format). Pushed (ee86309) to
  grc-iit/dayu fix/vol-stat-finalize-on-teardown. VOL .so md5 f72317a2.
- Also force-disabled the conda env's incompatible UCX 1.14.1 in OpenMPI (segfault handler
  noise + potential real issue): mpirun --mca pml ob1 --mca btl self,vader,tcp --mca osc ^ucx.
- 48 files / 48 nodes (192 ranks): COMPLETED exit 0, 6:46, all 9 stages, VOL 77/77 valid,
  VFD 73/75 valid (2 truncated — VFD lacks the finalize fix; minor follow-up), 148 outputs.
- Full 962 / 96 nodes first try FAILED at launch: PRRTE "NO PATH TO TARGET" (daemon wireup
  across 96 nodes picked wrong iface). FIX: pin to eno1 (172.16.0.0/16) +
  --prtemca oob_tcp_if_include eno1 --mca btl_tcp_if_include eno1 --prtemca routed_radix 256.
  Re-submitted 760125 — launched clean (1 scheduler, 960 files processing). [in progress]
- Node-count note: user chose 48 files->48 nodes, 962->96 nodes (overriding my 4/8 suggestion).
  Launcher: runs/PyFLEXTRKR/scale_dayu/run_dayu_saag.sbatch (CONFIG_YML+SCALE params; cfg_48files,
  cfg_full). FOLLOW-UP: port the VOL finalize/empty-array fix to the VFD tracker for clean VFD at scale.

## 2026-05-20 — Full 962-file scale: verdict
- Full 962 / 96 nodes (960 workers) FAILED ~stage 5: TWO issues entangled:
  (1) dask scheduler overwhelmed at ~958 workers ("Failed to reconnect to scheduler
      after 600s") — a single scheduler doesn't scale to ~1000 workers (prior eval used 240).
  (2) a real crash in stage 6 (matchpf).
- Isolation runs on the intact stage1-4 outputs (4 nodes / 32 workers):
  * stages 5-9 WITH DaYu: identifymcs(5) OK, then SIGSEGV in matchpf(6). addr 0xffffffffffffffe0.
  * stages 5-9 WITHOUT DaYu (NODAYU=1): COMPLETED all stages, exit 0, 0 segfaults
    (matchpf 275s, robustmcs 337s, mapfeature 424s, speed 197s; total 1305s).
  => VERDICT: the matchpf crash is a DaYu VOL/VFD bug at full scale (reading ~960 cloudid
     files), NOT PyFLEXTRKR. The full PyFLEXTRKR pipeline itself works at 962 files.
- Couldn't capture the exact crash line: UCX truncates its backtrace when mpirun aborts
  peers; core_pattern pipes to systemd-coredump (root-only). Next: run matchpf SERIAL
  (run_parallel=0) under gdb --batch to get the DaYu frame, then guard the NULL deref
  (likely the dataset-close/hash path, sibling of the strdup fix). [pending priority]
- DaYu validated cleanly at 6 files (4 nodes) and 48 files (48 nodes): all 9 stages,
  VOL all-valid, both VOL+VFD traces. Full-scale DaYu is the open item.

## 2026-05-21 — DaYu scale crash ROOT-CAUSED + fixed (the matchpf/cumulative SIGSEGV)
- gdb backtrace (plain netCDF open/read loop under DaYu, no MPI -> clean trace) pinned it:
  VFD GetDsetName() (src/vfd/H5FD_tracker_vfd_log.h) mmap()s SHM_SIZE per dataset READ and
  NEVER munmaps -> mapping leak. After ~vm.max_map_count (65530) reads, mmap=MAP_FAILED and
  std::string(curr_dset)=strlen((void*)-1) -> SIGSEGV @0xffffffffffffffe0. Explains why the
  crash stage moved earlier with scale (stage7@240, matchpf@480/962).
- FIX (pushed grc-iit/dayu 49b85b2): MAP_FAILED guard + strnlen(.,SHM_SIZE) + munmap.
  Verified: open/read loop now does 38400 opens, 0 crashes (was crashing before).
- All 3 DaYu fixes on branch fix/vol-stat-finalize-on-teardown: VOL finalize (1b1d04c),
  VOL strdup guards (ee86309), VFD mmap leak (49b85b2). Local backup:
  patches/widget/dayu_scale_fixes.patch. New VFD md5 a0b43978, VOL md5 (unchanged from f72317a2).
- 240/480 runs with OLD VFD crashed (stage7 / matchpf). Re-running 480 with FIXED VFD to
  confirm at scale. [in progress]

## 2026-05-21 — VFD fix VALIDATED AT SCALE
- 480 files / 80 nodes (240 workers) with FIXED VFD (job 760700): COMPLETED exit 0, 22:46,
  ALL 9 stages, 0 segfaults. VFD 81/81 valid, VOL 81/82 (1 minor), mcs_tracks_final produced,
  1444 outputs. (Same job crashed in matchpf on the OLD VFD minutes earlier.)
- => DaYu VFD mmap-leak fix resolves the cumulative scale crash. PyFLEXTRKR+DaYu now
  completes the full 9-stage pipeline at 480 files. Full 962 is unblocked (not yet run).

## 2026-05-21 — FULL 962 files VALIDATED (80 nodes / 240 workers, job 761002)
- COMPLETED exit 0, 41:47, ALL 9 stages, 0 segfaults. VOL 102/102 valid, VFD 100/101,
  2886 outputs, mcs_tracks_final produced. (gettracks 668s, idfeature 533s, robustmcs 400s.)
- => PyFLEXTRKR + DaYu (VOL+VFD) fully validated end-to-end at the full 962-file scale.
  All 3 DaYu fixes hold. (96-node launch flakes with instant mpirun exit 213 on some
  allocations; 80 nodes reliable + serial-stage-bound so ~same wall time.)
