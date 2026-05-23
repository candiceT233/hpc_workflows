#!/usr/bin/env bash
#SBATCH --job-name=hqnf
#SBATCH --account=oddite
#SBATCH --partition=slurm
#SBATCH --nodes=4
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=64
#SBATCH --mem=240000M
#SBATCH --time=04:00:00
# NOTE: --output/--error are set on the sbatch CLI (per-run RUNDIR/logs).
#
# Generic PNNL (Deception) launcher for nf-core (Class C) multi-node runs via
# HyperQueue, with exactly ONE profiler (Rule 7). One SLURM allocation owns N
# whole nodes; an HQ server (head) + one HQ worker per node distribute Nextflow
# tasks. No child sbatch, no --nodelist pinning, no --exclusive deadlock.
# Profiler is injected per-task by the chosen hq_<profiler>.config beforeScript
# (AFTER conda activation). Traces go to NODE-LOCAL /scratch then are collected.
#
# Required env (pass via: sbatch --export=ALL,WF=...,PROFILER=...):
#   WF        = nf-core_methylseq | nf-core_smrnaseq | ...
#   PROFILER  = datalife | darshan | plain
# Optional:
#   NF_PROFILE = test (default; reduced harness-validation scope)
set -o pipefail                                   # Rule 6 (conda-safe)

: "${WF:?set WF=nf-core_<name>}"
: "${PROFILER:?set PROFILER=datalife|darshan|plain}"
: "${NF_PROFILE:=test}"
NODES=${SLURM_NNODES:-4}
NCPU=64

# ---------- PNNL Deception paths ----------
export WORKFLOW_ROOT=/qfs/projects/datamesh/tang584/widget_evaluation/hpc_workflows
export WIDGET_ROOT=/qfs/projects/datamesh/tang584/widget_evaluation/widget-v1
export CONDA_ROOT=/share/apps/python/miniconda25.5.1
source "$CONDA_ROOT/etc/profile.d/conda.sh"
export PATH=$CONDA_ROOT/bin:$PATH
export PATH=/qfs/people/tang584/install/nextflow:$PATH
export JAVA_HOME=$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")
export HQ_BIN=$WORKFLOW_ROOT/tools/hyperqueue/hq
export PATH=$WORKFLOW_ROOT/tools/hyperqueue:$PATH

# Unset any stale/expired AWS STS creds inherited from the login shell. nf-schema
# signs its igenomes_base S3 existence-check with them; an expired token makes
# param validation fail with "token malformed" (S3 400) even for test profiles
# that never touch S3. Scoped to this job's shell only.
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_SECURITY_TOKEN

# Harness-validation runs use the test profile with explicit inputs, so nf-schema
# param validation (which also probes the default igenomes S3 path) is skipped.
VALIDATE_PARAMS=${VALIDATE_PARAMS:-false}

TAG=hq_${PROFILER}_${NODES}node
RUNDIR=$WORKFLOW_ROOT/runs/$WF/multinode_${NODES}node_hq_${PROFILER}
LOG=$RUNDIR/logs
export NXF_WORK=$RUNDIR/work_${TAG}
export NXF_HOME=$WORKFLOW_ROOT/runs/nf-core_shared/nf_home
export NXF_CONDA_CACHEDIR=$WORKFLOW_ROOT/runs/nf-core_shared/conda_cache
export NXF_MAX_FORKS=$((NODES * 16))             # Rule 10 (2-4x nodes, generous for HQ)
mkdir -p "$NXF_WORK" "$LOG" "$RUNDIR/outputs_${TAG}" "$NXF_HOME" "$NXF_CONDA_CACHEDIR"

# ---------- node-local trace root (Bootstrap §4: avoid NFS contention) ----------
LOCAL_TRACE_ROOT=/scratch/$USER/${WF}_${TAG}_${SLURM_JOB_ID}
PRECREATE="$LOCAL_TRACE_ROOT"

# ---------- profiler block (exactly one) ----------
CONFIG=$WORKFLOW_ROOT/runs/nf-core_shared/hq.config
SHARED_TRACE_DIR=""
case "$PROFILER" in
  datalife)
    export DATALIFE_LIB=$WIDGET_ROOT/profiler/datalife/build/flow-monitor/src/libmonitor.so
    export DATALIFE_OUTPUT_PATH=$LOCAL_TRACE_ROOT/traces
    export DATALIFE_JSON_OUTPUT=1
    # Rule 4: tight, workflow-relevant patterns (no greedy bare-prefix globs).
    export DATALIFE_FILE_PATTERNS='*.fastq,*.fastq.gz,*.fq,*.fq.gz,*.bam,*.sam,*.cram,*.gtf,*.gff,*.gff3,*.bed,*.bedGraph,*.fa,*.fasta,*.fai,*.tab,*.tsv,*.bismark,*.cov,*.txt.gz,*.zip,*.html'
    CONFIG=$WORKFLOW_ROOT/runs/nf-core_shared/hq_datalife.config
    SHARED_TRACE_DIR=$RUNDIR/datalife_traces_${TAG}
    PRECREATE="$DATALIFE_OUTPUT_PATH"
    ;;
  darshan)
    export DARSHAN_LIB=/people/tang584/install/darshan_runtime/lib/libdarshan.so
    export DARSHAN_LOGPATH=$LOCAL_TRACE_ROOT/darshan
    export DARSHAN_MODMEM=2048                    # Rule 11 (may be capped at compile time; harmless)
    export DARSHAN_EXCLUDE_DIRS=/proc:/sys:/dev:/etc:/usr:/var:/tmp:$NXF_CONDA_CACHEDIR:$NXF_HOME
    CONFIG=$WORKFLOW_ROOT/runs/nf-core_shared/hq_darshan.config
    SHARED_TRACE_DIR=$RUNDIR/darshan_logs        # verify_ares_runs.py expects darshan_logs/
    # Darshan writes into $DARSHAN_LOGPATH/YYYY/M/D and does NOT mkdir it.
    # Pre-create today + tomorrow (long runs may cross midnight).
    D_TODAY="$DARSHAN_LOGPATH/$(date +%Y)/$(date +%-m)/$(date +%-d)"
    D_TMRW="$DARSHAN_LOGPATH/$(date -d tomorrow +%Y)/$(date -d tomorrow +%-m)/$(date -d tomorrow +%-d)"
    PRECREATE="$D_TODAY $D_TMRW"
    ;;
  plain) : ;;
  *) echo "ERROR: unknown PROFILER=$PROFILER" >&2; exit 2 ;;
esac
[ -n "$SHARED_TRACE_DIR" ] && mkdir -p "$SHARED_TRACE_DIR"

# Pre-create node-local dirs on EVERY node in the allocation.
srun --nodes=$NODES --ntasks=$NODES --ntasks-per-node=1 mkdir -p $PRECREATE 2>/dev/null

# ---------- env log (Rule 2) ----------
export HQ_SERVER_DIR=$RUNDIR/.hq_${SLURM_JOB_ID}
mkdir -p "$HQ_SERVER_DIR"
{
  echo "WF=$WF PROFILER=$PROFILER NF_PROFILE=$NF_PROFILE NODES=$NODES TAG=$TAG"
  echo "JOB=$SLURM_JOB_ID ACCOUNT=$SLURM_JOB_ACCOUNT PARTITION=$SLURM_JOB_PARTITION"
  echo "Hostnames: $(scontrol show hostnames "$SLURM_NODELIST" | tr '\n' ' ')"
  echo "HQ_VERSION=$($HQ_BIN --version 2>&1)"
  echo "NEXTFLOW=$(nextflow -version 2>&1 | grep -i version | head -1)"
  echo "JAVA_HOME=$JAVA_HOME"
  case "$PROFILER" in
    datalife) echo "DATALIFE_LIB_MD5=$(md5sum "$DATALIFE_LIB" 2>/dev/null | awk '{print $1}')"
              echo "DATALIFE_OUTPUT_PATH=$DATALIFE_OUTPUT_PATH (node-local)";;
    darshan)  echo "DARSHAN_LIB_MD5=$(md5sum "$DARSHAN_LIB" 2>/dev/null | awk '{print $1}')"
              echo "DARSHAN_LOGPATH=$DARSHAN_LOGPATH (node-local)";;
  esac
} > "$LOG/env_at_start_${TAG}.txt"

cleanup() {
  echo "=== cleanup: stopping HQ ===" >> "$LOG/hq_${TAG}.log"
  "$HQ_BIN" worker stop all >> "$LOG/hq_${TAG}.log" 2>&1 || true
  "$HQ_BIN" server stop      >> "$LOG/hq_${TAG}.log" 2>&1 || true
}
trap cleanup EXIT

START=$(date +%s)

# 1. HQ server on head node.
"$HQ_BIN" server start > "$LOG/hq_server_${TAG}.log" 2>&1 &
for i in $(seq 1 30); do "$HQ_BIN" server info >/dev/null 2>&1 && break; sleep 1; done
echo "HQ server up after ${i}s" >> "$LOG/hq_${TAG}.log"

# 2. One HQ worker per node (each advertises all node CPUs), via srun.
srun --nodes=$NODES --ntasks=$NODES --ntasks-per-node=1 \
     "$HQ_BIN" worker start --cpus=$NCPU --on-server-lost=finish-running \
     > "$LOG/hq_workers_${TAG}.log" 2>&1 &
for i in $(seq 1 90); do
  nw=$("$HQ_BIN" worker list 2>/dev/null | grep -c RUNNING)
  [ "${nw:-0}" -ge "$NODES" ] && break; sleep 1
done
echo "HQ workers RUNNING: $("$HQ_BIN" worker list 2>/dev/null | grep -c RUNNING)/$NODES after ${i}s" >> "$LOG/hq_${TAG}.log"

# 3. Run Nextflow with the HQ executor. No LD_PRELOAD on the driver; each task
#    gets the profiler via the config beforeScript.
nextflow run "$WORKFLOW_ROOT/repos/$WF/main.nf" \
    -profile ${NF_PROFILE},conda \
    -c "$CONFIG" \
    --validate_params ${VALIDATE_PARAMS} \
    --outdir "$RUNDIR/outputs_${TAG}" \
    -work-dir "$NXF_WORK" \
    -resume 2>&1 | tee "$LOG/stdout_${TAG}.log"
EXIT_CODE=${PIPESTATUS[0]}

# 4. Collect node-local traces back to shared run dir.
if [ -n "$SHARED_TRACE_DIR" ]; then
  echo "=== collecting node-local traces from $NODES nodes ===" >> "$LOG/hq_${TAG}.log"
  case "$PROFILER" in
    datalife) COLLECT_SRC="$DATALIFE_OUTPUT_PATH";;
    darshan)  COLLECT_SRC="$DARSHAN_LOGPATH";;
  esac
  # --overlap: the HQ-worker srun step still holds all node CPUs at this point,
  # so the collection step must share resources or it would block forever.
  srun --overlap --nodes=$NODES --ntasks=$NODES --ntasks-per-node=1 bash -c "
    if [ -d '$COLLECT_SRC' ]; then
      cp -a '$COLLECT_SRC'/. '$SHARED_TRACE_DIR'/ 2>/dev/null || true
      rm -rf '$LOCAL_TRACE_ROOT' 2>/dev/null || true
    fi" >> "$LOG/hq_${TAG}.log" 2>&1
fi

END=$(date +%s)
{
  echo "WF=$WF PROFILER=$PROFILER NF_PROFILE=$NF_PROFILE"
  echo "EXIT_CODE=$EXIT_CODE"
  echo "ELAPSED_SECONDS=$((END - START))"
  echo "NODES=$NODES"
  if [ "$PROFILER" = datalife ]; then
    echo "DATALIFE_BLK_COUNT=$(find "$SHARED_TRACE_DIR" -name '*blk_trace.json' 2>/dev/null | wc -l)"
    echo "DATALIFE_TIMER_COUNT=$(find "$SHARED_TRACE_DIR" -name 'monitor_timer*.datalife.json' 2>/dev/null | wc -l)"
  elif [ "$PROFILER" = darshan ]; then
    echo "DARSHAN_LOG_COUNT=$(find "$SHARED_TRACE_DIR" -name '*.darshan' 2>/dev/null | wc -l)"
  fi
} > "$LOG/timing_${TAG}.log"
cat "$LOG/timing_${TAG}.log"
exit $EXIT_CODE
