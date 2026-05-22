#!/bin/bash
#SBATCH --job-name=pflex_dayu
#SBATCH --account=oddite
#SBATCH --partition=slurm
#SBATCH --time=04:00:00
#SBATCH --mem=240000M
# --nodes / --ntasks-per-node / -o / -e are set on the sbatch CLI per scale.
#
# Parameterized PyFLEXTRKR saag_summer_sam (olr_pcp) + DaYu VOL+VFD launcher.
# dask-MPI (run_parallel=2) via cluster mpirun/PRRTE (srun here lacks pmix).
# Required env (sbatch --export=ALL,CONFIG_YML=...,SCALE=...):
#   CONFIG_YML : abs path to the run config (sets enddate -> file count, root_path)
#   SCALE      : label for output dirs (e.g. 48files, full)
set -o pipefail
: "${CONFIG_YML:?set CONFIG_YML}"; : "${SCALE:?set SCALE}"

export WORKFLOW_ROOT=/qfs/projects/datamesh/tang584/widget_evaluation/hpc_workflows
export WIDGET_ROOT=/qfs/projects/datamesh/tang584/widget_evaluation/widget-v1
OLDREPO=/qfs/projects/datamesh/tang584/PyFLEXTRKR
source /share/apps/python/miniconda25.5.1/etc/profile.d/conda.sh
module load openmpi/5.0.7
conda activate pyflextrkr
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_SECURITY_TOKEN

TAG=${SCALE}_${SLURM_NNODES}node
SD=$WORKFLOW_ROOT/runs/PyFLEXTRKR/scale_dayu
LOG=$SD/logs_$TAG; mkdir -p "$LOG"
CONFIG=$CONFIG_YML
RUNNER=$OLDREPO/runscripts/run_mcs_tbpf_saag_summer_sam.py

# The conda env ships an incompatible UCX (1.14.1); OpenMPI segfaults in libucs at
# scale. Force ob1/TCP and exclude UCX from pml/osc/btl entirely (also via --mca below).
export PMIX_MCA_gds=hash
export OMPI_MCA_pml=ob1 OMPI_MCA_btl=self,vader,tcp OMPI_MCA_osc=^ucx
export OMPI_MCA_pml_ucx_priority=0 UCX_LOG_LEVEL=error
ulimit -n 65536 2>/dev/null || true
export DASK_DISTRIBUTED__COMM__TIMEOUTS__CONNECT=600s
export DASK_DISTRIBUTED__COMM__TIMEOUTS__TCP=600s

# ---- DaYu VOL+VFD ----
DAYU=$WIDGET_ROOT/profiler/dayu-tracker/build/src
LOCAL=/scratch/$USER/pflex_${TAG}_${SLURM_JOB_ID}
export DAYU_LOG_DIR=$LOCAL/dayu_stat
DASKTMP=$LOCAL/dask
export WORKFLOW_NAME=pyflextrkr
TASKF=$SD/task_files_$TAG
export PATH_FOR_TASK_FILES=$TASKF
unset CURR_TASK
SHARED_TRACE=$SD/dayu_traces_$TAG; mkdir -p "$SHARED_TRACE" "$TASKF"
printf run_idfeature > "$TASKF/${WORKFLOW_NAME}_vfd.curr_task"
printf run_idfeature > "$TASKF/${WORKFLOW_NAME}_vol.curr_task"
srun --ntasks=$SLURM_NNODES --ntasks-per-node=1 mkdir -p "$DAYU_LOG_DIR" "$DASKTMP"

export HDF5_USE_FILE_LOCKING=FALSE
if [ "${NODAYU:-0}" = 1 ]; then
  echo "NODAYU=1: running WITHOUT DaYu (no VOL/VFD) for diagnosis"
else
  export HDF5_VOL_CONNECTOR="tracker under_vol=0;under_info={};path=${DAYU_LOG_DIR};level=2;format="
  export HDF5_PLUGIN_PATH="$DAYU/vol:$DAYU/vfd"
  export HDF5_DRIVER=hdf5_tracker_vfd
  export HDF5_DRIVER_CONFIG="${DAYU_LOG_DIR};8192"
fi

{
  echo "WF=PyFLEXTRKR/saag_summer_sam SCALE=$SCALE TAG=$TAG NODES=$SLURM_NNODES NTASKS=$SLURM_NTASKS"
  echo "JOB=$SLURM_JOB_ID CONFIG=$CONFIG"
  echo "Hostnames: $(scontrol show hostnames "$SLURM_NODELIST" | tr '\n' ' ')"
  echo "enddate: $(grep -m1 '^enddate' "$CONFIG")  root_path: $(grep -m1 '^root_path' "$CONFIG")"
  echo "VOL_MD5=$(md5sum $DAYU/vol/libh5vol_tracker.so | awk '{print $1}')  VFD_MD5=$(md5sum $DAYU/vfd/libh5vfd_tracker.so | awk '{print $1}')"
} > "$LOG/env_at_start.txt" 2>&1

START=$(date +%s)
echo "PyFLEXTRKR dask-MPI: SCALE=$SCALE, $SLURM_NTASKS ranks across $SLURM_NNODES nodes"
mpirun -n $SLURM_NTASKS ${MPIRUN_EXTRA:-} \
     --mca pml ob1 --mca btl self,vader,tcp --mca osc "^ucx" --mca pml_ucx_priority 0 \
     --prtemca oob_tcp_if_include eno1 --mca btl_tcp_if_include eno1 \
     --prtemca routed_radix 256 \
     -x PATH -x LD_LIBRARY_PATH -x CONDA_PREFIX -x PYTHONPATH \
     -x WORKFLOW_NAME -x PATH_FOR_TASK_FILES \
     -x HDF5_VOL_CONNECTOR -x HDF5_PLUGIN_PATH -x HDF5_DRIVER -x HDF5_DRIVER_CONFIG -x HDF5_USE_FILE_LOCKING \
     -x OMPI_MCA_pml -x OMPI_MCA_btl -x OMPI_MCA_osc -x OMPI_MCA_pml_ucx_priority -x UCX_LOG_LEVEL -x PMIX_MCA_gds \
     python "$RUNNER" "$CONFIG" 2>&1 | tee "$LOG/stdout.log"
EXIT_CODE=${PIPESTATUS[0]}
END=$(date +%s)

srun --overlap --ntasks=$SLURM_NNODES --ntasks-per-node=1 bash -c "
  [ -d '$DAYU_LOG_DIR' ] && cp -a '$DAYU_LOG_DIR'/. '$SHARED_TRACE'/ 2>/dev/null; rm -rf '$LOCAL' 2>/dev/null" \
  >> "$LOG/collect.log" 2>&1

ROOT=$(grep -m1 '^root_path' "$CONFIG" | sed -E "s/^root_path: *'?([^']*)'?.*/\1/")
{
  echo "SCALE=$SCALE EXIT_CODE=$EXIT_CODE ELAPSED_SECONDS=$((END-START)) NODES=$SLURM_NNODES NTASKS=$SLURM_NTASKS"
  echo "DAYU_VOL_STAT=$(find "$SHARED_TRACE" -name '*vol_data_stat.json' 2>/dev/null | wc -l)"
  echo "DAYU_VFD_STAT=$(find "$SHARED_TRACE" -name '*vfd_data_stat.json' 2>/dev/null | wc -l)"
  echo "OUTPUT_NC=$(find "$ROOT" -name '*.nc' 2>/dev/null | wc -l)"
} > "$LOG/timing.log"
cat "$LOG/timing.log"
exit $EXIT_CODE
