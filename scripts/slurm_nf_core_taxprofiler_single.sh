#!/bin/bash
#SBATCH --job-name=taxprofiler-single
#SBATCH --exclusive
#SBATCH --partition=compute
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/nf-core_taxprofiler/slurm-%j-single.out
#SBATCH --error=runs/nf-core_taxprofiler/slurm-%j-single.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

REPO="$ROOT/repos/nf-core_taxprofiler"
DATA_DIR="$ROOT/data/nf-core_taxprofiler/full_real"
INPUT="$DATA_DIR/samplesheet_full_https.csv"
DATABASES="$DATA_DIR/database_kraken2_standard8gb_https.csv"
LOCAL_INPUT="$DATA_DIR/samplesheet_full_local.csv"
LOCAL_DATABASES="$DATA_DIR/database_kraken2_standard8gb_local.csv"
OUTDIR="$ROOT/runs/nf-core_taxprofiler/single-${SLURM_JOB_ID:-manual}/results"
WORKDIR="$ROOT/runs/nf-core_taxprofiler/single-${SLURM_JOB_ID:-manual}/work"
RUN_DIR="$(dirname "$OUTDIR")"
NF_ENV="$ROOT/tools/conda-envs/nextflow"
MINIFORGE="$ROOT/tools/miniforge"
mkdir -p "$ROOT/runs/nf-core_taxprofiler" "$OUTDIR" "$WORKDIR" "$ROOT/tools/nextflow-home" "$ROOT/tools/nextflow-conda-cache"
mkdir -p "$DATA_DIR/fastq" "$DATA_DIR/databases"

python3 "$ROOT/scripts/localize_url_table.py" \
  --input "$INPUT" \
  --output "$LOCAL_INPUT" \
  --dest-dir "$DATA_DIR/fastq" \
  --columns fastq_1 fastq_2 \
  --attempts 5

python3 "$ROOT/scripts/localize_url_table.py" \
  --input "$DATABASES" \
  --output "$LOCAL_DATABASES" \
  --dest-dir "$DATA_DIR/databases" \
  --columns db_path \
  --attempts 5

TMP_ROOT="$WORKDIR/tmp"
mkdir -p "$TMP_ROOT"
export TMPDIR="$TMP_ROOT"
export NXF_TEMP="$TMP_ROOT"
export _JAVA_OPTIONS="${_JAVA_OPTIONS:-} -Djava.io.tmpdir=$TMP_ROOT"
export MAMBA_YES=true
export MAMBA_ALWAYS_YES=true
export CONDA_ALWAYS_YES=true
export CONDA_PKGS_DIRS="$RUN_DIR/conda-pkgs"
mkdir -p "$CONDA_PKGS_DIRS" "$RUN_DIR/nextflow-conda-cache"
cat > "$RUN_DIR/condarc" <<'EOF'
always_yes: true
auto_activate_base: false
channel_priority: flexible
channels:
  - conda-forge
  - bioconda
  - defaults
EOF
export CONDARC="$RUN_DIR/condarc"

cat > "$RUN_DIR/taxprofiler_ares_override.config" <<EOF
process {
  resourceLimits = [
    cpus: 40,
    memory: 45.GB,
    time: 48.h
  ]
  withName: /.*BOWTIE2_ALIGN.*/ {
    cpus = 12
    memory = 45.GB
    time = 24.h
  }
  withName: /.*BOWTIE2_BUILD.*/ {
    cpus = 12
    memory = 40.GB
    time = 12.h
  }
}

conda {
  enabled = true
  useMamba = true
  cacheDir = "$RUN_DIR/nextflow-conda-cache"
}

params {
  max_memory = '40.GB'
}
EOF

export JAVA_HOME="$NF_ENV"
export JAVA_CMD="$NF_ENV/bin/java"
export NXF_HOME="$ROOT/tools/nextflow-home"
export NXF_VER="25.04.8"
export NXF_OPTS="-Xms1g -Xmx8g"
export NXF_SYNTAX_PARSER=v1
export PATH="$NF_ENV/bin:$MINIFORGE/bin:$MINIFORGE/condabin:$PATH"

cd "$(dirname "$OUTDIR")"
nextflow run "$REPO" \
  -name "taxprofiler_single_${SLURM_JOB_ID:-manual}" \
  -profile conda \
  -c "$ROOT/config/nextflow_ares_local_conda.config" \
  -c "$RUN_DIR/taxprofiler_ares_override.config" \
  -work-dir "$WORKDIR" \
  --input "$LOCAL_INPUT" \
  --databases "$LOCAL_DATABASES" \
  --run_kraken2 true \
  --outdir "$OUTDIR"

if ! find "$OUTDIR/pipeline_info" -maxdepth 1 -type f -name 'execution_trace*' -size +0 | grep -q .; then
  echo "ERROR: missing Nextflow execution trace in $OUTDIR/pipeline_info" >&2
  exit 1
fi

if ! find "$OUTDIR/multiqc" -type f -name 'multiqc_report.html' -size +100000 | grep -q .; then
  echo "ERROR: missing non-trivial MultiQC report" >&2
  exit 1
fi

if ! find "$OUTDIR" -type f \( -name '*combined_reports*' -o -name '*.profile' -o -name '*.tre' -o -name '*.sylph.tsv' -o -name '*bracken*.tsv' \) -size +0 | grep -q .; then
  echo "ERROR: missing non-empty taxonomic profile outputs" >&2
  exit 1
fi

TOOL_DIRS="$(find "$OUTDIR" -mindepth 1 -maxdepth 1 -type d | wc -l)"
if [ "$TOOL_DIRS" -lt 3 ]; then
  echo "ERROR: too few output tool directories for full taxprofiler baseline: $TOOL_DIRS" >&2
  exit 1
fi

OUTPUT_COUNT="$(find "$OUTDIR" -type f -size +0 | wc -l)"
if [ "$OUTPUT_COUNT" -lt 20 ]; then
  echo "ERROR: too few non-empty outputs for full taxprofiler baseline: $OUTPUT_COUNT" >&2
  exit 1
fi

echo "nf-core/taxprofiler single-node native Nextflow baseline completed with $OUTPUT_COUNT non-empty output files across $TOOL_DIRS tool directories"
