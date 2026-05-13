#!/bin/bash
#SBATCH --account=bekn-delta-cpu
#SBATCH --partition=cpu-preempt
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=32
#SBATCH --mem=64G
#SBATCH --time=01:30:00
#SBATCH --job-name=mseq_dh
#SBATCH --output=/scratch/bekn/mtang9/runs/nf-core_methylseq/small_1n32c_darshan/logs/slurm-%j.out
#SBATCH --error=/scratch/bekn/mtang9/runs/nf-core_methylseq/small_1n32c_darshan/logs/slurm-%j.err

set -euo pipefail

WIDGET_ROOT=/scratch/bekn/mtang9
RUN_DIR=$WIDGET_ROOT/runs/nf-core_methylseq/small_1n32c_darshan
LIBDARSHAN=$WIDGET_ROOT/tools/darshan/lib/libdarshan.so

export PATH=$WIDGET_ROOT/bin:$PATH
export NXF_VER=25.10.5
export NXF_APPTAINER_CACHEDIR=$WIDGET_ROOT/apptainer_cache
mkdir -p "$NXF_APPTAINER_CACHEDIR" "$RUN_DIR/darshan_logs" "$RUN_DIR/outputs" "$RUN_DIR/nf_work"

echo "=== methylseq Darshan run: $(date -u +%FT%TZ) ==="
echo "Host:        $(hostname)"
echo "Job ID:      ${SLURM_JOB_ID:-not-in-slurm}"
echo "libdarshan:  $LIBDARSHAN  md5=$(md5sum "$LIBDARSHAN" | cut -d' ' -f1)"
echo "Nextflow:    $(which nextflow)  $(nextflow -version 2>&1 | grep version | head -1)"
echo "Apptainer:   $(which apptainer)  $(apptainer --version)"
echo

START=$(date +%s)

DARSHAN_LOGPATH="$RUN_DIR/darshan_logs" \
DARSHAN_LOG_DIR_PATH="$RUN_DIR/darshan_logs" \
NXF_OPTS='-Xms2g -Xmx8g' \
nextflow run nf-core/methylseq \
    -r 4.2.0 \
    -profile test,singularity \
    -c "$WIDGET_ROOT/hpc_workflows/templates/delta/darshan.nf.config" \
    --max_cpus 32 \
    --max_memory '60.GB' \
    --max_time '1.h' \
    --outdir "$RUN_DIR/outputs" \
    -work-dir "$RUN_DIR/nf_work" \
    -with-trace "$RUN_DIR/logs/trace.txt" \
    -with-report "$RUN_DIR/logs/report.html" \
    -with-timeline "$RUN_DIR/logs/timeline.html"

EXIT=$?
ELAPSED=$(( $(date +%s) - START ))

echo
echo "=== END: $(date -u +%FT%TZ) exit=$EXIT elapsed=${ELAPSED}s ==="
echo "Darshan logs: $(find "$RUN_DIR/darshan_logs" -name '*.darshan' 2>/dev/null | wc -l) .darshan files"
du -sh "$RUN_DIR/darshan_logs" "$RUN_DIR/outputs" "$RUN_DIR/nf_work" 2>&1

exit $EXIT
