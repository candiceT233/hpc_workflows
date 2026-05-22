# Running PyFLEXTRKR + DaYu at scale on another cluster

This is the minimal, reproducible recipe for the **saag_summer_sam (olr_pcp)** MCS-tracking
scaling evaluation that was validated on PNNL Deception (6 → 962 files, up to 80 nodes /
240 dask-MPI workers, all 9 stages, DaYu VOL+VFD). It lists only the scripts actually used
plus the references, and—importantly—**exactly what you must change for a new cluster**.

Validated scales (PNNL Deception):

| Files | Nodes × workers | Result | DaYu traces |
|---:|---|---|---|
| 6   | 4 × 8  | ✅ 9 stages | VOL+VFD valid |
| 48  | 48 × 4 | ✅ 9 stages | VOL 77/77, VFD 73/75 |
| 480 | 80 × 3 | ✅ 9 stages | VOL 81/82, VFD 81/81 |
| 962 | 80 × 3 | ✅ 9 stages, 41 min | VOL 102/102, VFD 100/101 |

---

## 1. What you need

| Component | Source / location (PNNL) | Notes |
|---|---|---|
| **PyFLEXTRKR** workflow | `github.com/candiceT233/PyFLEXTRKR` branch **`ares`** | `pip install -e .`; the runner used is `runscripts/run_mcs_tbpf_saag_summer_sam.py` |
| **DaYu** HDF5 tracker | `widget-v1/profiler/dayu-tracker` | build VOL + VFD `.so` (see §3) |
| **Conda env** | `pyflextrkr` | build from `environment.yml` (or adapt `deception_flextrkr.yml`) |
| **MPI** | `module load openmpi/5.0.7` | must provide `mpirun`/PRRTE with PMIx; dask-MPI needs it |
| **HDF5** | `/people/tang584/install/hdf5` (1.14, **non-threadsafe**) | DaYu links against this; rebuild on the new cluster |
| **Input data** | `/qfs/projects/oddite/tang584/flextrkr_runs/input_data/olr_pcp/` | 962 files (~31 GB); copy manually, see §4 |
| **Launcher** | `runs/PyFLEXTRKR/scale_dayu/run_dayu_saag.sbatch` (this repo) | the validated launcher; configs `cfg_*.yml` |

## 2. Conda environment

```bash
conda env create -n pyflextrkr -f PyFLEXTRKR/environment.yml   # or deception_flextrkr.yml
conda activate pyflextrkr
cd PyFLEXTRKR && pip install -e .          # installs the pyflextrkr package + runscripts
```
Key deps: `dask`, `dask-mpi`, `mpi4py` (built against the *same* MPI you `module load`),
`xarray`, `netcdf4`/`h5netcdf`, `scipy`, `pandas`. **`mpi4py` must be ABI-compatible with the
cluster MPI** — if you switch MPI, `pip install --no-binary mpi4py mpi4py`.

## 3. Build DaYu (VOL + VFD) against HDF5 1.14

DaYu must link a **non-threadsafe HDF5 1.14**. On PNNL the build used a shim `h5cc/h5c++`
(`hpc_workflows/tools/hdf5-shim/`) because the stock `h5cc` had a baked-in missing compiler.
On a new cluster:
```bash
# point at an HDF5 1.14 (non-threadsafe) install
export HDF5_HOME=/path/to/hdf5-1.14
cd widget-v1/profiler/dayu-tracker && mkdir -p build && cd build
cmake .. -DCMAKE_PREFIX_PATH=$HDF5_HOME   # or use the tools/hdf5-shim h5cc/h5c++
make -j
# produces:  build/src/vol/libh5vol_tracker.so  and  build/src/vfd/libh5vfd_tracker.so
```
DaYu source fixes required for scale are already upstreamed to `grc-iit/dayu`
(branch `fix/vol-stat-finalize-on-teardown`); local backup at
`patches/widget/dayu_scale_fixes.patch`. **Build from the widget-v1 source — do not pull DaYu from elsewhere.**

## 4. Input data

Copy the whole directory (962 files, ~31 GB — includes the landmask):
```bash
rsync -av <source>:/qfs/projects/oddite/tang584/flextrkr_runs/input_data/olr_pcp/ \
         <dest>/olr_pcp/
```
Then in the config (`cfg_*.yml`) set the **only two input paths that must change**:
```yaml
clouddata_path: '<dest>/olr_pcp/'
landmask_filename: '<dest>/olr_pcp/IMERG_landmask_180W-180E_60S-60N.nc'
root_path: '<somewhere writable>/track_full/'    # outputs; use a fast FS (BeeGFS/Lustre)
```
Scale = number of input files, set by `enddate` in the config (see comments in `cfg_full.yml`):
`20160801.0500`→6 files, `...0802.2300`→48, `...0810.2300`→240, `20160910.0000`→962 (full).

## 5. EDIT THESE FOR YOUR CLUSTER (in `scale_dayu/run_dayu_saag.sbatch`)

| Line / var | PNNL value | Change to |
|---|---|---|
| `#SBATCH --account` | `oddite` | your allocation |
| `#SBATCH --partition` | `slurm` | your partition |
| `WORKFLOW_ROOT` / `WIDGET_ROOT` | PNNL abs paths | your checkout paths |
| `OLDREPO` | `/qfs/.../PyFLEXTRKR` | your PyFLEXTRKR clone |
| conda init path | `/share/apps/python/miniconda25.5.1/...` | your conda |
| `module load openmpi/5.0.7` | — | your MPI module (PMIx-enabled) |
| `--prtemca oob_tcp_if_include eno1` / `--mca btl_tcp_if_include eno1` | `eno1` | your node interconnect iface (`ip -o link`) |
| `--prtemca routed_radix 256` | 256 | keep/raise for very high node counts |
| `--mca pml ob1 --mca osc ^ucx` | disables conda's broken UCX 1.14.1 | keep if conda UCX is broken; else allow UCX |
| `DAYU` path | `$WIDGET_ROOT/profiler/dayu-tracker/build/src` | your DaYu build |

## 6. Run

```bash
cd runs/PyFLEXTRKR/scale_dayu
# 962 files / 80 nodes / 240 workers (3 workers/node) — the full validated scale:
sbatch -N 80 --ntasks=240 -o R_full.out -e R_full.out \
       --export=ALL,CONFIG_YML=$PWD/cfg_full.yml,SCALE=full \
       run_dayu_saag.sbatch
```
- `run_parallel: 2` in the config selects **dask-MPI** → the launcher runs
  `mpirun -n <ntasks> python run_mcs_tbpf_saag_summer_sam.py <config>`.
- **Worker/node guidance:** dask single-scheduler saturates around **256–300 workers** — keep
  `--ntasks` ≤ ~288 (96 nodes × 10 overwhelmed it). 80 × 3 = 240 is the proven sweet spot.
- DaYu is enabled by the launcher's HDF5 env (`HDF5_VOL_CONNECTOR=tracker...`,
  `HDF5_DRIVER=hdf5_tracker_vfd`). Set `NODAYU=1` to run a clean baseline without DaYu.
- Traces land per-rank as `<rank>-vol_data_stat.json` + `<rank>-vfd_data_stat.json`, collected
  to `dayu_traces_<scale>_<nodes>/`.

## 7. Gotchas learned at scale (PNNL)
- `srun` lacks PMIx here → must use `mpirun`/PRRTE for the dask-MPI bootstrap.
- conda's bundled UCX 1.14.1 segfaults → force `--mca pml ob1 --mca osc ^ucx`.
- High node counts need the interconnect iface pinned (`oob_tcp_if_include`) + `routed_radix`.
- Unset stale `AWS_*` env (the launcher does this) to avoid unrelated credential errors.
- DaYu requires HDF5/NetCDF4 I/O (PyFLEXTRKR writes NetCDF4-over-HDF5) — that's why DaYu fits
  this workflow; pure-POSIX workflows use Darshan/DataLife instead.
