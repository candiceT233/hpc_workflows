#!/bin/bash
#SBATCH --job-name=quantms-single
#SBATCH --exclusive
#SBATCH --partition=compute
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/nf-core_quantms/slurm-%j-single.out
#SBATCH --error=runs/nf-core_quantms/slurm-%j-single.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

REPO="$ROOT/repos/nf-core_quantms"
DATA_DIR="$ROOT/data/nf-core_quantms/full_pxd001819"
INPUT="$DATA_DIR/PXD001819.sdrf.tsv"
DATABASE="$DATA_DIR/db/uniprot_yeast_human_reviewed.fasta"
OUTDIR="$ROOT/runs/nf-core_quantms/single-${SLURM_JOB_ID:-manual}/results"
WORKDIR="$ROOT/runs/nf-core_quantms/single-${SLURM_JOB_ID:-manual}/work"
RUN_DIR="$(dirname "$OUTDIR")"
NF_ENV="$ROOT/tools/conda-envs/nextflow"
MINIFORGE="$ROOT/tools/miniforge"

mkdir -p "$ROOT/runs/nf-core_quantms" "$RUN_DIR" "$OUTDIR" "$WORKDIR" "$ROOT/tools/nextflow-home"

for required in "$INPUT" "$DATABASE"; do
  if [ ! -s "$required" ]; then
    echo "ERROR: missing required nf-core/quantms full-input artifact: $required" >&2
    exit 1
  fi
done

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

cat > "$RUN_DIR/quantms_ares_override.config" <<EOF
conda {
  enabled = true
  useMamba = true
  cacheDir = "$ROOT/tools/nextflow-conda-cache/nf-core_quantms"
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
  -c "$RUN_DIR/quantms_ares_override.config" \
  -work-dir "$WORKDIR" \
  --input "$INPUT" \
  --database "$DATABASE" \
  --posterior_probabilities percolator \
  --search_engines msgf,comet \
  --add_decoys true \
  --add_triqler_output true \
  --protein_level_fdr_cutoff 0.01 \
  --psm_pep_fdr_cutoff 0.01 \
  --outdir "$OUTDIR" \
  --max_cpus 40 \
  --max_memory 40.GB \
  --max_time 48.h

if ! find "$OUTDIR/pipeline_info" -maxdepth 1 -type f -name 'execution_trace*' -size +0 | grep -q .; then
  echo "ERROR: missing Nextflow execution trace in $OUTDIR/pipeline_info" >&2
  exit 1
fi

if ! find "$OUTDIR/multiqc" -type f -name '*multiqc_report.html' -size +100000 | grep -q .; then
  echo "ERROR: missing non-trivial MultiQC report" >&2
  exit 1
fi

if ! find "$OUTDIR" -type f \( -name '*.mzTab' -o -name '*.mztab' -o -name '*msstats*.csv' -o -name '*triqler*.tsv' \) -size +0 | grep -q .; then
  echo "ERROR: missing non-empty quantification result outputs" >&2
  exit 1
fi

if ! find "$OUTDIR" -type f \( -name '*.idXML' -o -name '*.consensusXML' -o -name '*.featureXML' \) -size +0 | grep -q .; then
  echo "ERROR: missing non-empty OpenMS intermediate outputs" >&2
  exit 1
fi

OUTPUT_COUNT="$(find "$OUTDIR" -type f -size +0 | wc -l)"
if [ "$OUTPUT_COUNT" -lt 50 ]; then
  echo "ERROR: too few non-empty outputs for full quantms baseline: $OUTPUT_COUNT" >&2
  exit 1
fi

echo "nf-core/quantms single-node native Nextflow baseline completed with $OUTPUT_COUNT non-empty output files"
