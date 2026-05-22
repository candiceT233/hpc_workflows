#!/bin/bash
# Per-node Montage reprojection worker (Class-A fan-out, one instance per node).
# Launched by srun --ntasks=<NNODES> --ntasks-per-node=1.  Each instance handles
# every NNODES-th input tile (sharded by SLURM_PROCID) and runs mProjectPP on it
# under exactly one profiler (DataLife OR Darshan), one process per tile with
# PER_NODE_CONC-way intra-node concurrency.  Outputs + traces stay node-local.
#
# Required env (exported by the launcher, passed through srun --export=ALL):
#   TILE_DIR N_TILES NNODES PER_NODE_CONC PROFILER LOCAL OUTBASE MB DL DARSHAN
# I/O placement (BeeGFS benchmark):
#   TILE_DIR  = BeeGFS (input tiles read from /rcfs)
#   OUTBASE   = BeeGFS (reprojected outputs written to /rcfs)  <- workload write I/O
#   LOCAL     = node-local /scratch (profiler trace output only, collected later)
set -u
RANK=${SLURM_PROCID:-0}
NN=${NNODES:?}
TPL="$TILE_DIR/template.hdr"
PROJ="$OUTBASE/proj"          # reprojected outputs on BeeGFS (the write I/O we profile)
mkdir -p "$PROJ" "$LOCAL"
HOST=$(hostname)

# ---- profiler env (LD_PRELOAD is applied per-exec, not to this shell) ----
PRE=""
case "$PROFILER" in
  datalife)
    export DATALIFE_OUTPUT_PATH="$LOCAL/dl"
    export DATALIFE_TASK_NAME="montage_reproject"
    mkdir -p "$DATALIFE_OUTPUT_PATH"
    PRE="$DL" ;;
  darshan)
    export DARSHAN_ENABLE_NONMPI=1
    export DARSHAN_LOGPATH="$LOCAL/darshan"
    mkdir -p "$DARSHAN_LOGPATH/$(date +%Y)/$(date +%-m)/$(date +%-d)"
    PRE="$DARSHAN" ;;
  none) PRE="" ;;
  *) echo "RANK $RANK: unknown PROFILER=$PROFILER" >&2; exit 2 ;;
esac
# HARD RULE: exactly ONE profiler per run. Darshan and DataLife are collected in
# SEPARATE evaluations and must NEVER be stacked in one LD_PRELOAD (two POSIX
# interception libs corrupt each other's traces). Refuse if PRE has >1 entry.
case "$PRE" in *" "*) echo "RANK $RANK: REFUSING to stack profilers (LD_PRELOAD='$PRE')" >&2; exit 3 ;; esac

# ---- build this node's shard (every NN-th tile, deterministic by sorted name) ----
mapfile -t ALL < <(ls "$TILE_DIR"/tile_*.fits 2>/dev/null | sort)
TOTAL=${#ALL[@]}
SHARD=()
for ((i=RANK; i<TOTAL; i+=NN)); do SHARD+=("${ALL[$i]}"); done
NSHARD=${#SHARD[@]}
echo "RANK $RANK host=$HOST profiler=$PROFILER shard=$NSHARD/$TOTAL conc=$PER_NODE_CONC LOCAL=$LOCAL"

[ "$NSHARD" -eq 0 ] && { echo "RANK $RANK: empty shard, nothing to do"; exit 0; }

export PROJ TPL PRE MB
# one mProjectPP per tile, PER_NODE_CONC at a time; LD_PRELOAD only on the binary
printf '%s\n' "${SHARD[@]}" | xargs -P "$PER_NODE_CONC" -I INFILE bash -c '
  out="$PROJ/$(basename "$1" .fits).p.fits"
  if [ -n "$PRE" ]; then
    env LD_PRELOAD="$PRE" "$MB/mProjectPP" "$1" "$out" "$TPL" >/dev/null 2>&1
  else
    "$MB/mProjectPP" "$1" "$out" "$TPL" >/dev/null 2>&1
  fi
' _ INFILE

# ---- per-node accounting ----
# count only THIS node's shard outputs (PROJ is a shared BeeGFS dir across all nodes)
NOUT=0; for f in "${SHARD[@]}"; do [ -f "$PROJ/$(basename "$f" .fits).p.fits" ] && NOUT=$((NOUT+1)); done
# DataLife emits monitor_timer.<pid>-<host>.datalife.json (per-call I/O profile);
# *blk_trace.json only appears when block traces are non-empty. Count all json.
NDL=$(find "$LOCAL/dl" -name '*.json' 2>/dev/null | wc -l)
NDAR=$(find "$LOCAL/darshan" -name '*.darshan*' 2>/dev/null | wc -l)
echo "RANK $RANK host=$HOST DONE profiler=$PROFILER shard=$NSHARD outputs=$NOUT datalife_json=$NDL darshan_logs=$NDAR"
