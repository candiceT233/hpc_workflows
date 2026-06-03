#!/bin/bash
#SBATCH --job-name=pathosurv-single
#SBATCH --exclusive
#SBATCH --partition=compute
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/nf-core_pathogensurveillance/slurm-%j-single.out
#SBATCH --error=runs/nf-core_pathogensurveillance/slurm-%j-single.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

REPO="$ROOT/repos/nf-core_pathogensurveillance"
DATA_DIR="$ROOT/data/nf-core_pathogensurveillance/full"
SAMPLESHEET="$DATA_DIR/samplesheets/bordetella.csv"
OUTDIR="$ROOT/runs/nf-core_pathogensurveillance/single-${SLURM_JOB_ID:-manual}/results"
WORKDIR="$ROOT/runs/nf-core_pathogensurveillance/single-${SLURM_JOB_ID:-manual}/work"
RUN_DIR="$(dirname "$OUTDIR")"
NF_ENV="$ROOT/tools/conda-envs/nextflow"
MINIFORGE="$ROOT/tools/miniforge"

mkdir -p "$ROOT/runs/nf-core_pathogensurveillance" "$OUTDIR" "$WORKDIR" "$DATA_DIR/samplesheets" "$ROOT/tools/nextflow-home" "$ROOT/tools/nextflow-conda-cache"

if [ ! -s "$SAMPLESHEET" ]; then
  echo "ERROR: missing local Bordetella pathogensurveillance samplesheet: $SAMPLESHEET" >&2
  exit 1
fi

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

cat > "$RUN_DIR/pathogensurveillance_ares_override.config" <<EOF
conda {
  enabled = true
  useMamba = true
  cacheDir = "$RUN_DIR/nextflow-conda-cache"
  createTimeout = '90 min'
}
process.maxForks = 4
EOF

export JAVA_HOME="$NF_ENV"
export JAVA_CMD="$NF_ENV/bin/java"
export NXF_HOME="$ROOT/tools/nextflow-home"
export NXF_OFFLINE=true
export NXF_VER=26.04.1
export NXF_OPTS="-Xms1g -Xmx8g"
export NXF_SYNTAX_PARSER=v1
export PATH="$NF_ENV/bin:$MINIFORGE/bin:$MINIFORGE/condabin:$PATH"

cd "$(dirname "$OUTDIR")"
nextflow run "$REPO" \
  -profile conda \
  -c "$ROOT/config/nextflow_ares_local_conda.config" \
  -c "$RUN_DIR/pathogensurveillance_ares_override.config" \
  -work-dir "$WORKDIR" \
  --input "$SAMPLESHEET" \
  --data_dir "$DATA_DIR/downloads" \
  --max_parallel_downloads 1 \
  --outdir "$OUTDIR"

if ! find "$OUTDIR/pipeline_info" -maxdepth 1 -type f -name '*trace*' -size +0 | grep -q .; then
  echo "ERROR: missing Nextflow execution trace in $OUTDIR/pipeline_info" >&2
  exit 1
fi

if ! find "$OUTDIR" -type f -path '*/multiqc/*multiqc_report.html' -size +100000 | grep -q .; then
  echo "ERROR: missing non-trivial MultiQC report" >&2
  exit 1
fi

if ! find "$OUTDIR/reports" -type f -name '*_pathsurveil_report.html' -size +100000 | grep -q .; then
  echo "ERROR: missing non-trivial pathogensurveillance HTML report" >&2
  exit 1
fi

if ! find "$OUTDIR/assemblies" -type f \( -name '*.fasta' -o -name '*.fa' -o -name '*.fasta.gz' -o -name '*.fa.gz' \) -size +0 | grep -q .; then
  echo "ERROR: missing non-empty assembly outputs" >&2
  exit 1
fi

if ! find "$OUTDIR/quality_control" -type f \( -name '*.html' -o -name '*.json' -o -name 'report.tsv' \) -size +0 | grep -q .; then
  echo "ERROR: missing non-empty quality-control outputs" >&2
  exit 1
fi

OUTPUT_COUNT="$(find "$OUTDIR" -type f -size +0 | wc -l)"
if [ "$OUTPUT_COUNT" -lt 50 ]; then
  echo "ERROR: too few non-empty outputs for full pathogensurveillance baseline: $OUTPUT_COUNT" >&2
  exit 1
fi

echo "nf-core/pathogensurveillance single-node native Nextflow baseline completed with $OUTPUT_COUNT non-empty output files"
