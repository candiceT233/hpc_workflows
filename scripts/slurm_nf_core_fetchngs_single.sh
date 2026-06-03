#!/bin/bash
#SBATCH --job-name=fetchngs-single
#SBATCH --exclusive
#SBATCH --partition=compute
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/nf-core_fetchngs/slurm-%j-single.out
#SBATCH --error=runs/nf-core_fetchngs/slurm-%j-single.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

REPO="$ROOT/repos/nf-core_fetchngs"
INPUT="$ROOT/data/nf-core_fetchngs/full_srp227242/sra_ids.csv"
OUTDIR="$ROOT/runs/nf-core_fetchngs/single-${SLURM_JOB_ID:-manual}/results"
WORKDIR="$ROOT/runs/nf-core_fetchngs/single-${SLURM_JOB_ID:-manual}/work"
RUN_DIR="$(dirname "$OUTDIR")"
NF_ENV="$ROOT/tools/conda-envs/nextflow"
MINIFORGE="$ROOT/tools/miniforge"

mkdir -p "$ROOT/runs/nf-core_fetchngs" "$RUN_DIR" "$OUTDIR" "$WORKDIR" "$ROOT/tools/nextflow-home"

TMP_ROOT="$WORKDIR/tmp"
PKGS_ROOT="$RUN_DIR/conda-pkgs"
mkdir -p "$TMP_ROOT" "$PKGS_ROOT" "$RUN_DIR/nextflow-conda-cache"
export TMPDIR="$TMP_ROOT"
export NXF_TEMP="$TMP_ROOT"
export CONDA_PKGS_DIRS="$PKGS_ROOT"
export _JAVA_OPTIONS="${_JAVA_OPTIONS:-} -Djava.io.tmpdir=$TMP_ROOT"
export MAMBA_YES=true
export MAMBA_ALWAYS_YES=true
export CONDA_ALWAYS_YES=true
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

cat > "$RUN_DIR/fetchngs_ares_override.config" <<EOF
conda {
  enabled = true
  useMamba = true
  cacheDir = "$ROOT/tools/nextflow-conda-cache/nf-core_fetchngs"
}
process {
  maxForks = 2
}
EOF

export JAVA_HOME="$NF_ENV"
export JAVA_CMD="$NF_ENV/bin/java"
export NXF_HOME="$ROOT/tools/nextflow-home"
export NXF_VER=25.04.8
export NXF_OFFLINE=true
export NXF_OPTS="-Xms1g -Xmx8g"
export NXF_SYNTAX_PARSER=v1
export PATH="$NF_ENV/bin:$MINIFORGE/bin:$MINIFORGE/condabin:$PATH"

cd "$(dirname "$OUTDIR")"
nextflow run "$REPO" \
  -profile conda \
  -c "$ROOT/config/nextflow_ares_local_conda.config" \
  -c "$RUN_DIR/fetchngs_ares_override.config" \
  -work-dir "$WORKDIR" \
  --input "$INPUT" \
  --nf_core_pipeline rnaseq \
  --outdir "$OUTDIR"

if ! find "$OUTDIR/pipeline_info" -maxdepth 1 -type f -name 'execution_trace*' -size +0 | grep -q .; then
  echo "ERROR: missing Nextflow execution trace in $OUTDIR/pipeline_info" >&2
  exit 1
fi

if [ ! -s "$OUTDIR/samplesheet/samplesheet.csv" ]; then
  echo "ERROR: missing non-empty generated samplesheet" >&2
  exit 1
fi

if [ ! -s "$OUTDIR/samplesheet/id_mappings.csv" ]; then
  echo "ERROR: missing non-empty ID mappings file" >&2
  exit 1
fi

FASTQ_COUNT="$(find "$OUTDIR/fastq" -type f -name '*.fastq.gz' -size +0 2>/dev/null | wc -l)"
if [ "$FASTQ_COUNT" -lt 8 ]; then
  echo "ERROR: too few non-empty FASTQ outputs for full fetchngs baseline: $FASTQ_COUNT" >&2
  exit 1
fi

OUTPUT_COUNT="$(find "$OUTDIR" -type f -size +0 | wc -l)"
if [ "$OUTPUT_COUNT" -lt 12 ]; then
  echo "ERROR: too few non-empty outputs for full fetchngs baseline: $OUTPUT_COUNT" >&2
  exit 1
fi

echo "nf-core/fetchngs single-node native Nextflow baseline completed with $FASTQ_COUNT FASTQ files and $OUTPUT_COUNT non-empty output files"
