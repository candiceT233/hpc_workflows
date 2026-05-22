#!/bin/bash
#SBATCH --job-name=pflex_darshan
#SBATCH --account=oddite
#SBATCH --partition=slurm
#SBATCH --time=04:00:00
#SBATCH --mem=240000M
# --nodes / --ntasks-per-node / -o / -e are set on the sbatch CLI per scale.
#
# PyFLEXTRKR saag_summer_sam (olr_pcp) dask-MPI run profiled with DARSHAN ONLY
# (POSIX). This is a SEPARATE evaluation from the DaYu runs -- Darshan and DaYu/
# DataLife are NEVER stacked. Mirrors run_dayu_saag.sbatch's MPI/MCA setup; the
# only difference is the profiler (LD_PRELOAD=libdarshan, NONMPI per-rank logs;
# no HDF5_VOL/VFD env).
# Required env (sbatch --export=ALL,CONFIG_YML=...,SCALE=...):
#   CONFIG_YML : abs path to the run config; SCALE : label for output dirs
set -o pipefail
: "${CONFIG_YML:?set CONFIG_YML}"; : "${SCALE:?set SCALE}"

export WORKFLOW_ROOT=/qfs/projects/datamesh/tang584/widget_evaluation/hpc_workflows
OLDREPO=/qfs/projects/datamesh/tang584/PyFLEXTRKR
source /share/apps/python/miniconda25.5.1/etc/profile.d/conda.sh
module load openmpi/5.0.7
conda activate pyflextrkr
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_SECURITY_TOKEN

TAG=${SCALE}_${SLURM_NNODES}node
SD=$WORKFLOW_ROOT/runs/PyFLEXTRKR/scale_dayu
LOG=$SD/logs_darshan_$TAG; mkdir -p "$LOG"
CONFIG=$CONFIG_YML
RUNNER=$OLDREPO/runscripts/run_mcs_tbpf_saag_summer_sam.py

# Same UCX/OpenMPI workarounds as the DaYu launcher (conda UCX 1.14.1 is broken).
export PMIX_MCA_gds=hash
export OMPI_MCA_pml=ob1 OMPI_MCA_btl=self,vader,tcp OMPI_MCA_osc=^ucx
export OMPI_MCA_pml_ucx_priority=0 UCX_LOG_LEVEL=error
ulimit -n 65536 2>/dev/null || true
export DASK_DISTRIBUTED__COMM__TIMEOUTS__CONNECT=600s
export DASK_DISTRIBUTED__COMM__TIMEOUTS__TCP=600s
export HDF5_USE_FILE_LOCKING=FALSE

# ---- Darshan (POSIX), per-rank logs (NONMPI) -- NO DaYu VOL/VFD ----
DARSHAN_LIB=/people/tang584/install/darshan_runtime/lib/libdarshan.so
export DARSHAN_ENABLE_NONMPI=1
DLOG=$SD/darshan_traces_$TAG
export DARSHAN_LOGPATH=$DLOG
mkdir -p "$DLOG/$(date +%Y)/$(date +%-m)/$(date +%-d)"   # Darshan needs the dated dir to exist

{
  echo "WF=PyFLEXTRKR/saag_summer_sam PROFILER=darshan SCALE=$SCALE TAG=$TAG NODES=$SLURM_NNODES NTASKS=$SLURM_NTASKS"
  echo "JOB=$SLURM_JOB_ID CONFIG=$CONFIG"
  echo "Hostnames: $(scontrol show hostnames "$SLURM_NODELIST" | tr '\n' ' ')"
  echo "enddate: $(grep -m1 '^enddate' "$CONFIG")  root_path: $(grep -m1 '^root_path' "$CONFIG")"
  echo "DARSHAN_LIB_MD5=$(md5sum "$DARSHAN_LIB" | awk '{print $1}')  DARSHAN_LOGPATH=$DLOG"
} > "$LOG/env_at_start.txt" 2>&1
cat "$LOG/env_at_start.txt"

START=$(date +%s)
echo "PyFLEXTRKR dask-MPI + Darshan: SCALE=$SCALE, $SLURM_NTASKS ranks across $SLURM_NNODES nodes"
# LD_PRELOAD/DARSHAN_* are set only for the mpirun env and forwarded to ranks via -x,
# so the launcher shell itself is not instrumented.
env LD_PRELOAD="$DARSHAN_LIB" \
mpirun -n $SLURM_NTASKS ${MPIRUN_EXTRA:-} \
     --mca pml ob1 --mca btl self,vader,tcp --mca osc "^ucx" --mca pml_ucx_priority 0 \
     --prtemca oob_tcp_if_include eno1 --mca btl_tcp_if_include eno1 \
     --prtemca routed_radix 256 \
     -x PATH -x LD_LIBRARY_PATH -x CONDA_PREFIX -x PYTHONPATH \
     -x LD_PRELOAD -x DARSHAN_ENABLE_NONMPI -x DARSHAN_LOGPATH -x HDF5_USE_FILE_LOCKING \
     -x OMPI_MCA_pml -x OMPI_MCA_btl -x OMPI_MCA_osc -x OMPI_MCA_pml_ucx_priority -x UCX_LOG_LEVEL -x PMIX_MCA_gds \
     python "$RUNNER" "$CONFIG" 2>&1 | tee "$LOG/stdout.log"
EXIT_CODE=${PIPESTATUS[0]}
END=$(date +%s)

ROOT=$(grep -m1 '^root_path' "$CONFIG" | sed -E "s/^root_path: *'?([^']*)'?.*/\1/")
{
  echo "SCALE=$SCALE PROFILER=darshan EXIT_CODE=$EXIT_CODE ELAPSED_SECONDS=$((END-START)) NODES=$SLURM_NNODES NTASKS=$SLURM_NTASKS"
  echo "DARSHAN_LOGS=$(find "$DLOG" -name '*.darshan*' 2>/dev/null | wc -l)"
  echo "DARSHAN_LOGS_python=$(find "$DLOG" -name '*python*.darshan*' 2>/dev/null | wc -l)"
  echo "OUTPUT_NC=$(find "$ROOT" -name '*.nc' 2>/dev/null | wc -l)"
  echo "DARSHAN_LOGPATH=$DLOG"
} > "$LOG/timing.log"
cat "$LOG/timing.log"
exit $EXIT_CODE
