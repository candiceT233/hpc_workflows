#!/usr/bin/env bash
#SBATCH --job-name=methyl_hq_dl
#SBATCH --partition=compute
#SBATCH --output=/mnt/common/mtang11/hpc_workflows/runs/nf-core_methylseq/multinode_2node_hq_datalife/logs/slurm_%j.out
#SBATCH --error=/mnt/common/mtang11/hpc_workflows/runs/nf-core_methylseq/multinode_2node_hq_datalife/logs/slurm_%j.err
#SBATCH --time=01:00:00
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=40
#SBATCH --mem=47000M
set -o pipefail

# HyperQueue-based nf-core run. One SLURM allocation owns N whole nodes; an HQ
# server + one HQ worker per node distribute Nextflow tasks across them. No child
# sbatch, no node-pinning, no --exclusive deadlock. DataLife instruments each task
# via hq_datalife.config's beforeScript.

export WORKFLOW_ROOT=/mnt/common/mtang11/hpc_workflows
export JAVA_HOME=$WORKFLOW_ROOT/tools/java17/jdk-17.0.13+11
export PATH=$JAVA_HOME/bin:$PATH
export HQ_BIN=$WORKFLOW_ROOT/tools/hyperqueue/hq
export PATH=$WORKFLOW_ROOT/tools/hyperqueue:$PATH
export CONDA_ROOT=/mnt/common/mtang11/miniconda3
source $CONDA_ROOT/etc/profile.d/conda.sh
export PATH=$WORKFLOW_ROOT/runs/nf-core_shared/env/conda/bin:$PATH

RUNDIR=$WORKFLOW_ROOT/runs/nf-core_methylseq/multinode_2node_hq_datalife
TAG=hq_datalife_2node
LOG=$RUNDIR/logs
export NXF_WORK=$RUNDIR/work_${TAG}
export NXF_HOME=$WORKFLOW_ROOT/runs/nf-core_shared/nf_home
export NXF_CONDA_CACHEDIR=$WORKFLOW_ROOT/runs/nf-core_shared/conda_cache
export NXF_MAX_FORKS=100

# DataLife env — exported so hq_datalife.config's System.getenv can bake it into
# each task's beforeScript.
export DATALIFE_LIB=/mnt/common/mtang11/scripts/widget-v1/profiler/datalife/build/flow-monitor/src/libmonitor.so
# Write traces to NODE-LOCAL SSD (fast, no NFS contention). 3755 processes each
# writing a timer JSON to a shared NFS dir overwhelmed NFS + the HQ server and
# got early tasks SIGINT'd (exit 130). /mnt/ssd is per-node 477 GB XFS. Same path
# string on every node → each node writes to its own local dir; collected back to
# the shared run dir after the workflow finishes.
LOCAL_TRACE_ROOT=/mnt/ssd/mtang11/hqdl_${SLURM_JOB_ID}
export DATALIFE_OUTPUT_PATH=$LOCAL_TRACE_ROOT/traces
SHARED_TRACE_DIR=$RUNDIR/datalife_traces_${TAG}
export DATALIFE_FILE_PATTERNS='*.fastq,*.fastq.gz,*.fq,*.fq.gz,*.bam,*.sam,*.gtf,*.fa,*.fasta,*.tab,*.tsv,*.bismark,*.cov,*.bedGraph'
export DATALIFE_JSON_OUTPUT=1
mkdir -p "$NXF_WORK" "$LOG" "$RUNDIR/outputs_${TAG}" "$SHARED_TRACE_DIR"
# Pre-create the node-local trace dir on EVERY node in the allocation.
srun --nodes=$SLURM_NNODES --ntasks=$SLURM_NNODES --ntasks-per-node=1 \
     mkdir -p "$DATALIFE_OUTPUT_PATH" 2>/dev/null

# HQ server dir — shared between server, workers, and nextflow's hq executor.
export HQ_SERVER_DIR=$RUNDIR/.hq_${SLURM_JOB_ID}
mkdir -p "$HQ_SERVER_DIR"

{
  echo "PROFILER=datalife (HyperQueue executor)"
  echo "HQ_VERSION=$($HQ_BIN --version 2>&1)"
  echo "DATALIFE_LIB_MD5=$(md5sum $DATALIFE_LIB | awk '{print $1}')"
  echo "DATALIFE_JSON_OUTPUT=$DATALIFE_JSON_OUTPUT"
  echo "Nodes=$SLURM_NNODES Hostnames: $(scontrol show hostnames $SLURM_NODELIST | tr '\n' ' ')"
} > "$LOG/env_at_start_${TAG}.txt"

cleanup() {
  echo "=== cleanup: stopping HQ workers + server ===" >> "$LOG/hq_${TAG}.log"
  "$HQ_BIN" worker stop all >> "$LOG/hq_${TAG}.log" 2>&1 || true
  "$HQ_BIN" server stop      >> "$LOG/hq_${TAG}.log" 2>&1 || true
}
trap cleanup EXIT

START=$(date +%s)

# 1. Start HQ server (background) on the head node.
"$HQ_BIN" server start > "$LOG/hq_server_${TAG}.log" 2>&1 &
# wait until server is reachable
for i in $(seq 1 30); do
  "$HQ_BIN" server info >/dev/null 2>&1 && break
  sleep 1
done
echo "HQ server up after ${i}s" >> "$LOG/hq_${TAG}.log"

# 2. Start one HQ worker per node (each advertises the node's 40 cpus), via srun.
srun --nodes=$SLURM_NNODES --ntasks=$SLURM_NNODES --ntasks-per-node=1 \
     "$HQ_BIN" worker start --cpus=40 --on-server-lost=finish-running \
     > "$LOG/hq_workers_${TAG}.log" 2>&1 &
# wait until N workers register
for i in $(seq 1 60); do
  nw=$("$HQ_BIN" worker list 2>/dev/null | grep -c RUNNING)
  [ "${nw:-0}" -ge "$SLURM_NNODES" ] && break
  sleep 1
done
echo "HQ workers registered: $("$HQ_BIN" worker list 2>/dev/null | grep -c RUNNING)/$SLURM_NNODES after ${i}s" >> "$LOG/hq_${TAG}.log"

# 3. Run Nextflow with the HQ executor. No LD_PRELOAD on the driver — each task
#    gets it via hq_datalife.config beforeScript.
nextflow run $WORKFLOW_ROOT/repos/nf-core_methylseq/main.nf \
    -profile test,conda \
    -c $WORKFLOW_ROOT/runs/nf-core_shared/hq_datalife.config \
    --outdir "$RUNDIR/outputs_${TAG}" \
    -work-dir "$NXF_WORK" \
    -resume 2>&1 | tee "$LOG/stdout_${TAG}.log"
EXIT_CODE=${PIPESTATUS[0]}

# Collect node-local traces from every node back to the shared NFS run dir.
echo "=== collecting node-local traces from $SLURM_NNODES nodes ===" >> "$LOG/hq_${TAG}.log"
srun --nodes=$SLURM_NNODES --ntasks=$SLURM_NNODES --ntasks-per-node=1 bash -c "
  if [ -d '$DATALIFE_OUTPUT_PATH' ]; then
    cp -a '$DATALIFE_OUTPUT_PATH'/. '$SHARED_TRACE_DIR'/ 2>/dev/null || true
    rm -rf '$LOCAL_TRACE_ROOT' 2>/dev/null || true
  fi" >> "$LOG/hq_${TAG}.log" 2>&1

END=$(date +%s)
{
  echo "EXIT_CODE=$EXIT_CODE"
  echo "ELAPSED_SECONDS=$((END - START))"
  echo "NODES=$SLURM_NNODES"
  echo "DATALIFE_BLK_COUNT=$(find "$SHARED_TRACE_DIR" -name '*blk_trace.json' 2>/dev/null | wc -l)"
  echo "DATALIFE_TIMER_COUNT=$(find "$SHARED_TRACE_DIR" -name 'monitor_timer*.datalife.json' 2>/dev/null | wc -l)"
  echo "NON_MAINNF_BLK=$(find "$SHARED_TRACE_DIR" -name '*blk_trace.json' ! -name 'main.nf*' 2>/dev/null | wc -l)"
} > "$LOG/timing_${TAG}.log"
exit $EXIT_CODE
