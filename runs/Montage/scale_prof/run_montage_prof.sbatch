#!/bin/bash
#SBATCH --job-name=montage_prof
#SBATCH --account=oddite
#SBATCH --partition=slurm
#SBATCH --time=03:00:00
# --nodes / -o / -e are set on the sbatch CLI per scale.
#
# Montage mProjectPP reprojection at scale (Class-A fan-out, 1 proc/tile), profiled
# with DataLife and Darshan in SEPARATE passes (NEVER stacked -- two POSIX
# interception libs would corrupt each other's traces).  One srun task per node;
# each node reprojects every NNODES-th tile with PER_NODE_CONC intra-node
# concurrency.  Inputs read from shared /qfs; outputs + traces stay node-local
# (/scratch) and trace dirs are tarred back to /qfs per node.
#
# Required env (sbatch --export=ALL,TILE_DIR=...,N_TILES=...,SCALE=...):
#   TILE_DIR : dir with tile_*.fits + template.hdr
#   N_TILES  : number of input tiles (for accounting)
#   SCALE    : label for output dirs (e.g. 6gb, 30gb)
# Optional:
#   PROFILERS     : space-sep passes (default "datalife darshan"); each runs alone
#   PER_NODE_CONC : concurrent mProjectPP per node (default 32)
set -o pipefail
: "${TILE_DIR:?set TILE_DIR}"; : "${N_TILES:?set N_TILES}"; : "${SCALE:?set SCALE}"
export PROFILERS="${PROFILERS:-datalife darshan}"
export PER_NODE_CONC="${PER_NODE_CONC:-32}"
export NNODES=$SLURM_NNODES

ROOT=/qfs/projects/datamesh/tang584/widget_evaluation/hpc_workflows/runs/Montage/scale_prof
export MB=/qfs/people/tang584/install/Montage/bin
export DL=/qfs/projects/datamesh/tang584/widget_evaluation/widget-v1/profiler/datalife/build/flow-monitor/src/libmonitor.so
export DARSHAN=/people/tang584/install/darshan_runtime/lib/libdarshan.so

TAG=${SCALE}_${SLURM_NNODES}node
LOG=$ROOT/logs_$TAG; mkdir -p "$LOG"
LOCALBASE=/scratch/$USER/montage_${TAG}_${SLURM_JOB_ID}                          # node-local: profiler traces only
BGBASE=/rcfs/projects/chess/tang584/montage_eval/run_${TAG}_${SLURM_JOB_ID}      # BeeGFS: workload I/O (outputs) + collected traces
KEEP_OUTPUTS="${KEEP_OUTPUTS:-0}"
mkdir -p "$BGBASE"

{
  echo "WF=Montage/mProjectPP SCALE=$SCALE TAG=$TAG NODES=$SLURM_NNODES TILES=$N_TILES CONC=$PER_NODE_CONC"
  echo "JOB=$SLURM_JOB_ID TILE_DIR=$TILE_DIR PROFILERS='$PROFILERS'"
  echo "BeeGFS: in=$TILE_DIR  out=$BGBASE  (traces node-local->BeeGFS; KEEP_OUTPUTS=$KEEP_OUTPUTS)"
  echo "TILE_DIR_FS=$(stat -f -c %T "$TILE_DIR" 2>/dev/null)  BGBASE_FS=$(stat -f -c %T "$BGBASE" 2>/dev/null)"
  echo "Hostnames: $(scontrol show hostnames "$SLURM_NODELIST" | tr '\n' ' ')"
  echo "MB=$(ls "$MB/mProjectPP" 2>&1)  DL_MD5=$(md5sum "$DL" 2>/dev/null | awk '{print $1}')  DARSHAN_MD5=$(md5sum "$DARSHAN" 2>/dev/null | awk '{print $1}')"
} > "$LOG/env_at_start.txt" 2>&1
cat "$LOG/env_at_start.txt"

OVERALL=0
for PASS in $PROFILERS; do
  echo "============================================================"
  echo "PASS=$PASS  SCALE=$SCALE  NODES=$SLURM_NNODES  TILES=$N_TILES   $(date)"
  echo "============================================================"
  export PROFILER=$PASS
  export LOCAL=$LOCALBASE/$PASS                 # node-local: profiler trace output
  export OUTBASE=$BGBASE/$PASS                  # BeeGFS: reprojected output writes (workload I/O)
  TRACES=$BGBASE/$PASS/traces; mkdir -p "$TRACES" "$OUTBASE"

  START=$(date +%s)
  srun --ntasks=$SLURM_NNODES --ntasks-per-node=1 --export=ALL \
       bash "$ROOT/montage_worker.sh" 2>&1 | tee "$LOG/worker_${PASS}.log"
  RC=${PIPESTATUS[0]}
  END=$(date +%s)
  echo "PASS=$PASS srun rc=$RC elapsed=$((END-START))s"
  [ "$RC" -ne 0 ] && OVERALL=$RC

  # collect: each node tars its node-local trace dir back to shared /qfs
  srun --overlap --ntasks=$SLURM_NNODES --ntasks-per-node=1 --export=ALL bash -c '
    H=$(hostname)
    if [ "'"$PASS"'" = datalife ]; then SRCD="'"$LOCAL"'/dl"; else SRCD="'"$LOCAL"'/darshan"; fi
    [ -d "$SRCD" ] && tar czf "'"$TRACES"'/'"$PASS"'_${H}.tar.gz" -C "$(dirname "$SRCD")" "$(basename "$SRCD")" 2>/dev/null
  ' >> "$LOG/collect_${PASS}.log" 2>&1

  # accounting from worker stdout
  OUTS=$(grep -hoE 'outputs=[0-9]+'      "$LOG/worker_${PASS}.log" | cut -d= -f2 | paste -sd+ | bc 2>/dev/null)
  DLJ=$(grep -hoE 'datalife_json=[0-9]+' "$LOG/worker_${PASS}.log" | cut -d= -f2 | paste -sd+ | bc 2>/dev/null)
  DARL=$(grep -hoE 'darshan_logs=[0-9]+' "$LOG/worker_${PASS}.log" | cut -d= -f2 | paste -sd+ | bc 2>/dev/null)
  TARS=$(ls "$TRACES"/*.tar.gz 2>/dev/null | wc -l)
  {
    echo "PASS=$PASS RC=$RC ELAPSED=$((END-START))s NODES=$SLURM_NNODES TILES=$N_TILES"
    echo "  total_outputs=${OUTS:-0} datalife_json=${DLJ:-0} darshan_logs=${DARL:-0} node_tarballs=$TARS"
    echo "  out(BeeGFS) -> $OUTBASE/proj    traces -> $TRACES"
  } | tee -a "$LOG/timing.log"

  # reprojected outputs are large throwaway (the write I/O is what we profile); drop unless asked to keep
  if [ "$KEEP_OUTPUTS" != 1 ]; then
    srun --overlap --ntasks=$SLURM_NNODES --ntasks-per-node=1 bash -c "rm -rf '$OUTBASE/proj'/* 2>/dev/null" >/dev/null 2>&1
    rm -rf "$OUTBASE/proj" 2>/dev/null
  fi
done

# free node-local scratch
srun --overlap --ntasks=$SLURM_NNODES --ntasks-per-node=1 bash -c "rm -rf '$LOCALBASE' 2>/dev/null" >/dev/null 2>&1
echo "ALL PASSES DONE overall_rc=$OVERALL"; cat "$LOG/timing.log"
exit $OVERALL
