#!/usr/bin/env bash
#SBATCH --job-name=pflex_dayu
#SBATCH --account=oddite
#SBATCH --partition=slurm
#SBATCH --nodes=4
#SBATCH --ntasks-per-node=8          # = dask-workers per node (Class B-ish: srun fan-out of workers)
#SBATCH --cpus-per-task=8
#SBATCH --mem=240000M
#SBATCH --time=02:00:00
# --output/--error set on the sbatch CLI.
#
# PNNL (Deception) launcher for PyFLEXTRKR multi-node via a manual Dask cluster
# (dask-scheduler on the head + one dask-worker per srun task across all nodes),
# with the DaYu HDF5-VOL+VFD tracker capturing netCDF/HDF5 I/O.
#
# PyFLEXTRKR run_parallel=2 => Client(scheduler_file=...), so NO mpi4py/dask-mpi.
# argv to the runner: <config.yml> <scheduler_file> <n_workers>.
#
# Required env (sbatch --export=ALL,CONFIG_YML=...,RUNNER=...):
#   CONFIG_YML = absolute path to the PyFLEXTRKR config
#   RUNNER     = abs path to runscript (e.g. repos/PyFLEXTRKR/runscripts/run_mcs_tbpf.py)
set -o pipefail

: "${CONFIG_YML:?set CONFIG_YML=/abs/config.yml}"
: "${RUNNER:?set RUNNER=/abs/run_mcs_tbpf.py}"
NODES=${SLURM_NNODES:-4}
WORKERS_PER_NODE=${SLURM_NTASKS_PER_NODE:-8}
N_WORKERS=$((NODES * WORKERS_PER_NODE))

# ---------- PNNL paths ----------
export WORKFLOW_ROOT=/qfs/projects/datamesh/tang584/widget_evaluation/hpc_workflows
export WIDGET_ROOT=/qfs/projects/datamesh/tang584/widget_evaluation/widget-v1
export CONDA_ROOT=/share/apps/python/miniconda25.5.1
source "$CONDA_ROOT/etc/profile.d/conda.sh"
conda activate "$WORKFLOW_ROOT/runs/PyFLEXTRKR/pyflextrkr_env"
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_SECURITY_TOKEN

TAG=dayu_${NODES}node
RUNDIR=$WORKFLOW_ROOT/runs/PyFLEXTRKR/multinode_${NODES}node_dayu
LOG=$RUNDIR/logs
mkdir -p "$LOG" "$RUNDIR"

# ---------- DaYu VOL+VFD env ----------
DAYU_ROOT=$WIDGET_ROOT/profiler/dayu-tracker
VOL_DIR=$(dirname "$(find "$DAYU_ROOT/build" -name '*vol*.so' -type f 2>/dev/null | head -1)")
VFD_DIR=$(dirname "$(find "$DAYU_ROOT/build" -name '*vfd*.so' -type f 2>/dev/null | head -1)")
if [ -z "$VOL_DIR" ] || [ -z "$VFD_DIR" ]; then
  echo "ERROR: DaYu VOL/VFD .so not found under $DAYU_ROOT/build — build DaYu first." >&2; exit 3
fi
# Traces to NODE-LOCAL disk, collected after (avoids shared-FS contention).
LOCAL_TRACE_ROOT=/scratch/$USER/PyFLEXTRKR_${TAG}_${SLURM_JOB_ID}
export DAYU_LOG_DIR=$LOCAL_TRACE_ROOT/dayu
SHARED_TRACE_DIR=$RUNDIR/dayu_traces_${TAG}
mkdir -p "$SHARED_TRACE_DIR"
srun --nodes=$NODES --ntasks=$NODES --ntasks-per-node=1 mkdir -p "$DAYU_LOG_DIR" 2>/dev/null

export CURR_TASK="pyflextrkr"
export HDF5_VOL_CONNECTOR="tracker under_vol=0;under_info={};path=${DAYU_LOG_DIR};level=2;format="
export HDF5_PLUGIN_PATH="$VFD_DIR:$VOL_DIR"
export HDF5_DRIVER=hdf5_tracker_vfd
export HDF5_DRIVER_CONFIG="${DAYU_LOG_DIR};8192"

# ---------- env log (Rule 2) ----------
{
  echo "WF=PyFLEXTRKR PROFILER=dayu NODES=$NODES WORKERS=$N_WORKERS TAG=$TAG"
  echo "JOB=$SLURM_JOB_ID ACCOUNT=$SLURM_JOB_ACCOUNT PARTITION=$SLURM_JOB_PARTITION"
  echo "Hostnames: $(scontrol show hostnames "$SLURM_NODELIST" | tr '\n' ' ')"
  echo "CONDA_PREFIX=$CONDA_PREFIX"
  echo "DaYu VOL_DIR=$VOL_DIR VFD_DIR=$VFD_DIR"
  echo "DAYU_LOG_DIR=$DAYU_LOG_DIR (node-local)"
  echo "CONFIG_YML=$CONFIG_YML RUNNER=$RUNNER"
  python -c "import netCDF4; print('netCDF4', netCDF4.__version__, 'HDF5', netCDF4.__hdf5libversion__)"
} > "$LOG/env_at_start_${TAG}.txt" 2>&1

ulimit -n 32000 2>/dev/null || true
export DASK_DISTRIBUTED__COMM__TIMEOUTS__CONNECT=360s
export DASK_DISTRIBUTED__COMM__TIMEOUTS__TCP=360s

SCHEDULER_FILE=$RUNDIR/scheduler_${SLURM_JOB_ID}.json
rm -f "$SCHEDULER_FILE"

cleanup() {
  echo "=== cleanup ===" >> "$LOG/dask_${TAG}.log"
  pkill -f "dask-scheduler --scheduler-file=$SCHEDULER_FILE" 2>/dev/null || true
}
trap cleanup EXIT

START=$(date +%s)

# 1. Dask scheduler on the head node.
dask-scheduler --scheduler-file="$SCHEDULER_FILE" > "$LOG/dask_scheduler_${TAG}.log" 2>&1 &
for i in $(seq 1 60); do [ -f "$SCHEDULER_FILE" ] && break; sleep 1; done
echo "scheduler file present after ${i}s" >> "$LOG/dask_${TAG}.log"

# 2. One dask-worker per srun task, across all nodes (DaYu env inherited).
srun --nodes=$NODES --ntasks=$N_WORKERS --ntasks-per-node=$WORKERS_PER_NODE \
     dask-worker --scheduler-file="$SCHEDULER_FILE" --nthreads=1 \
     --memory-limit=8GB --local-directory="$LOCAL_TRACE_ROOT/dask" \
     > "$LOG/dask_workers_${TAG}.log" 2>&1 &

# 3. Run PyFLEXTRKR (run_parallel=2 -> Client(scheduler_file), waits for workers).
python "$RUNNER" "$CONFIG_YML" "$SCHEDULER_FILE" "$N_WORKERS" 2>&1 | tee "$LOG/stdout_${TAG}.log"
EXIT_CODE=${PIPESTATUS[0]}

# 4. Collect node-local DaYu traces back to shared run dir.
echo "=== collecting DaYu traces from $NODES nodes ===" >> "$LOG/dask_${TAG}.log"
srun --overlap --nodes=$NODES --ntasks=$NODES --ntasks-per-node=1 bash -c "
  if [ -d '$DAYU_LOG_DIR' ]; then
    cp -a '$DAYU_LOG_DIR'/. '$SHARED_TRACE_DIR'/ 2>/dev/null || true
    rm -rf '$LOCAL_TRACE_ROOT' 2>/dev/null || true
  fi" >> "$LOG/dask_${TAG}.log" 2>&1

END=$(date +%s)
{
  echo "WF=PyFLEXTRKR PROFILER=dayu"
  echo "EXIT_CODE=$EXIT_CODE"
  echo "ELAPSED_SECONDS=$((END - START))"
  echo "NODES=$NODES N_WORKERS=$N_WORKERS"
  echo "DAYU_VOL_STAT=$(find "$SHARED_TRACE_DIR" -name '*vol_data_stat.json' 2>/dev/null | wc -l)"
  echo "DAYU_VFD_STAT=$(find "$SHARED_TRACE_DIR" -name '*vfd_data_stat.json' 2>/dev/null | wc -l)"
} > "$LOG/timing_${TAG}.log"
cat "$LOG/timing_${TAG}.log"
exit $EXIT_CODE
