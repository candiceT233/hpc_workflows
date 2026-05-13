#!/bin/bash
#SBATCH --account=bekn-delta-cpu
#SBATCH --partition=cpu-preempt
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=32
#SBATCH --mem=64G
#SBATCH --time=01:30:00
#SBATCH --job-name=amp_dl
#SBATCH --output=/scratch/bekn/mtang9/runs/nf-core_ampliseq/small_1n32c_datalife/logs/slurm-%j.out
#SBATCH --error=/scratch/bekn/mtang9/runs/nf-core_ampliseq/small_1n32c_datalife/logs/slurm-%j.err

set -euo pipefail

WIDGET_ROOT=/scratch/bekn/mtang9
RUN_DIR=$WIDGET_ROOT/runs/nf-core_ampliseq/small_1n32c_datalife
LIBMONITOR=$WIDGET_ROOT/widget-v1/profiler/datalife/flow-monitor/build/src/libmonitor.so

export PATH=$WIDGET_ROOT/bin:$PATH
export NXF_VER=25.10.5
export NXF_APPTAINER_CACHEDIR=$WIDGET_ROOT/apptainer_cache
mkdir -p "$NXF_APPTAINER_CACHEDIR" "$RUN_DIR/datalife_traces" "$RUN_DIR/outputs" "$RUN_DIR/nf_work"

echo "=== ampliseq DataLife run: $(date -u +%FT%TZ) ==="
echo "Host:         $(hostname)"
echo "Job ID:       ${SLURM_JOB_ID:-not-in-slurm}"
echo "libmonitor:   $LIBMONITOR  md5=$(md5sum "$LIBMONITOR" | cut -d' ' -f1)"
echo "Nextflow:     $(which nextflow)  $(nextflow -version 2>&1 | grep version | head -1)"
echo "Apptainer:    $(which apptainer)  $(apptainer --version)"
echo

START=$(date +%s)

LD_PRELOAD="$LIBMONITOR" \
MONITOR_UNSET_LIB=1 \
DATALIFE_OUTPUT_PATH="$RUN_DIR/datalife_traces" \
DATALIFE_FILE_PATTERNS='*.fastq,*.fastq.gz,*.fq,*.fq.gz,*.fasta,*.fa,*.tsv,*.csv,*.biom,*.qza,*.qzv,*.html,*.txt,results*' \
NXF_OPTS='-Xms2g -Xmx8g' \
nextflow run nf-core/ampliseq \
    -r 2.17.0 \
    -profile test,singularity \
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
echo "DataLife traces: $(find "$RUN_DIR/datalife_traces" -name '*.blk_trace.json' 2>/dev/null | wc -l) blk_trace.json files"
du -sh "$RUN_DIR/datalife_traces" "$RUN_DIR/outputs" "$RUN_DIR/nf_work" 2>&1

exit $EXIT
