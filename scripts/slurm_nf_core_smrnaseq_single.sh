#!/bin/bash
#SBATCH --job-name=smrnaseq-single
#SBATCH --exclusive
#SBATCH --partition=compute
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/nf-core_smrnaseq/slurm-%j-single.out
#SBATCH --error=runs/nf-core_smrnaseq/slurm-%j-single.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

REPO="$ROOT/repos/nf-core_smrnaseq"
INPUT="$ROOT/data/nf-core_smrnaseq/full/encode_gm12878_smallrna_samplesheet.csv"
OUTDIR="$ROOT/runs/nf-core_smrnaseq/single-${SLURM_JOB_ID:-manual}/results"
WORKDIR="$ROOT/runs/nf-core_smrnaseq/single-${SLURM_JOB_ID:-manual}/work"
RUN_DIR="$(dirname "$OUTDIR")"
NF_ENV="$ROOT/tools/conda-envs/nextflow"
MINIFORGE="$ROOT/tools/miniforge"

mkdir -p "$ROOT/runs/nf-core_smrnaseq" "$RUN_DIR" "$OUTDIR" "$WORKDIR" "$ROOT/tools/nextflow-home"

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

cat > "$RUN_DIR/smrnaseq_ares_override.config" <<EOF
process {
  maxForks = 4
}

conda {
  enabled = true
  useMamba = true
  cacheDir = "$RUN_DIR/nextflow-conda-cache"
  createTimeout = '90 min'
}
EOF

export JAVA_HOME="$NF_ENV"
export JAVA_CMD="$NF_ENV/bin/java"
export NXF_HOME="$ROOT/tools/nextflow-home"
export NXF_OFFLINE=true
export NXF_VER="25.04.8"
export NXF_OPTS="-Xms1g -Xmx8g"
export NXF_SYNTAX_PARSER=v1
export PATH="$NF_ENV/bin:$MINIFORGE/bin:$MINIFORGE/condabin:$PATH"

cd "$(dirname "$OUTDIR")"
nextflow run "$REPO" \
  -profile conda \
  -c "$ROOT/config/nextflow_ares_local_conda.config" \
  -c "$RUN_DIR/smrnaseq_ares_override.config" \
  -work-dir "$WORKDIR" \
  --input "$INPUT" \
  --genome GRCh37 \
  --mirtrace_species hsa \
  --igenomes_base "https://ngi-igenomes.s3.amazonaws.com/igenomes/" \
  --outdir "$OUTDIR"

if ! find "$OUTDIR/pipeline_info" -maxdepth 1 -type f -name 'execution_trace*' -size +0 | grep -q .; then
  echo "ERROR: missing Nextflow execution trace in $OUTDIR/pipeline_info" >&2
  exit 1
fi

if ! find "$OUTDIR/multiqc" -type f -name 'multiqc_report.html' -size +100000 | grep -q .; then
  echo "ERROR: missing non-trivial MultiQC report" >&2
  exit 1
fi

if ! find "$OUTDIR" -type f \( -name '*.bam' -o -name '*.bai' \) -size +0 | grep -q .; then
  echo "ERROR: missing non-empty miRNA/genome BAM outputs" >&2
  exit 1
fi

if ! find "$OUTDIR" -type f \( -name 'joined_samples_mirtop.tsv' -o -name 'mirna.tsv' -o -name '*normalized_CPM.txt' -o -name 'result_*.csv' \) -size +0 | grep -q .; then
  echo "ERROR: missing non-empty miRNA quantification outputs" >&2
  exit 1
fi

OUTPUT_COUNT="$(find "$OUTDIR" -type f -size +0 | wc -l)"
if [ "$OUTPUT_COUNT" -lt 100 ]; then
  echo "ERROR: too few non-empty outputs for full smrnaseq baseline: $OUTPUT_COUNT" >&2
  exit 1
fi

echo "nf-core/smrnaseq single-node native Nextflow baseline completed with $OUTPUT_COUNT non-empty output files"
