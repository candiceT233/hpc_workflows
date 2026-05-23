#!/bin/bash
# Submit a list of nf-core pipelines as a SERIAL SLURM dependency chain (afterany),
# so only one runs at a time -> no concurrent conda-env creation -> no shared
# pkg-cache corruption (merged-prompt Rule 5). Each runs via hq_nfcore_pnnl.sbatch
# with one profiler. Env reuse across pipelines (shared NXF_CONDA_CACHEDIR) is safe
# because creation is serialized.
#
# Usage: bash submit_chain.sh <profiler> <nodes> wf1 wf2 wf3 ...
#   e.g. bash submit_chain.sh darshan 4 nf-core_ampliseq nf-core_nascent ...
set -u
HW=/qfs/projects/datamesh/tang584/widget_evaluation/hpc_workflows
SH=$HW/runs/nf-core_shared
PROFILER=$1; NODES=$2; shift 2
DEP=""; PREV=""
for wf in "$@"; do
  mkdir -p "$HW/runs/$wf/multinode_${NODES}node_hq_${PROFILER}/logs"
  DEPOPT=""; [ -n "$PREV" ] && DEPOPT="--dependency=afterany:$PREV"
  for i in 1 2 3 4 5; do
    J=$(sbatch --parsable $DEPOPT -N$NODES -A oddite -p slurm -t 02:00:00 \
        -o "$HW/runs/$wf/multinode_${NODES}node_hq_${PROFILER}/logs/sbatch_%j.out" \
        -e "$HW/runs/$wf/multinode_${NODES}node_hq_${PROFILER}/logs/sbatch_%j.out" \
        --export=ALL,WF=$wf,PROFILER=$PROFILER,NF_PROFILE=test "$SH/hq_nfcore_pnnl.sbatch" 2>/dev/null)
    [ -n "$J" ] && break; sleep 3
  done
  echo "$wf -> jid=$J (after=${PREV:-none})"; PREV=$J; DEP="$DEP $J"
done
echo "CHAIN_JIDS=${DEP# }"
