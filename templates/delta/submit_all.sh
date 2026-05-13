#!/bin/bash
# Submit the 4 Delta validation jobs (methylseq + ampliseq × DataLife + Darshan).
# Jobs are submitted sequentially with dependencies so the next one starts
# after the previous finishes; failures don't cascade.
#
# Usage: bash submit_all.sh
#
# Expects the run directories at /scratch/bekn/mtang9/runs/ to already exist.
# Run-script copies in those directories are what actually get submitted;
# update them from these templates first if you've changed paths.

set -euo pipefail

WIDGET_ROOT=/scratch/bekn/mtang9
TEMPLATES=$WIDGET_ROOT/hpc_workflows/templates/delta

submit() {
    local script="$1" dep="${2:-}"
    local args=( "$script" )
    [[ -n "$dep" ]] && args=( "--dependency=afterany:$dep" "$script" )
    local jid
    jid=$(sbatch --parsable "${args[@]}")
    echo "  $script  -> $jid"
    echo "$jid"
}

echo "Submitting 4 validation jobs..."

mseq_dl=$(submit "$WIDGET_ROOT/runs/nf-core_methylseq/small_1n32c_datalife/run_slurm.datalife.sh")
mseq_dh=$(submit "$WIDGET_ROOT/runs/nf-core_methylseq/small_1n32c_darshan/run_slurm.darshan.sh"   "$mseq_dl")
amp_dl=$(submit  "$WIDGET_ROOT/runs/nf-core_ampliseq/small_1n32c_datalife/run_slurm.datalife.sh"  "$mseq_dh")
amp_dh=$(submit  "$WIDGET_ROOT/runs/nf-core_ampliseq/small_1n32c_darshan/run_slurm.darshan.sh"    "$amp_dl")

echo
echo "Queued chain:"
echo "  methylseq DL   $mseq_dl"
echo "  methylseq DH   $mseq_dh   (after $mseq_dl)"
echo "  ampliseq  DL   $amp_dl    (after $mseq_dh)"
echo "  ampliseq  DH   $amp_dh    (after $amp_dl)"
echo
echo "Monitor: squeue -u \$USER"
echo "Results: see <run_dir>/datalife_traces/ or <run_dir>/darshan_logs/"
