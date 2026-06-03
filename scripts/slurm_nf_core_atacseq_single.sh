#!/bin/bash
#SBATCH --job-name=atacseq-single
#SBATCH --exclusive
#SBATCH --partition=compute
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/nf-core_atacseq/slurm-%j-single.out
#SBATCH --error=runs/nf-core_atacseq/slurm-%j-single.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
REPO="$ROOT/repos/nf-core_atacseq"
OUTDIR="$ROOT/runs/nf-core_atacseq/single-${SLURM_JOB_ID:-manual}/results"
WORKDIR="$ROOT/runs/nf-core_atacseq/single-${SLURM_JOB_ID:-manual}/work"
RUN_DIR="$(dirname "$OUTDIR")"
DATA_DIR="$ROOT/data/nf-core_atacseq/full"
SOURCE_INPUT="$ROOT/data/nf-core_atacseq/full/encode_gm12878_samplesheet.csv"
INPUT="$DATA_DIR/samplesheet_full_local.csv"
FASTQ_DIR="$DATA_DIR/fastq"
NF_ENV="$ROOT/tools/conda-envs/nextflow"
MINIFORGE="$ROOT/tools/miniforge"

mkdir -p "$ROOT/runs/nf-core_atacseq" "$OUTDIR" "$WORKDIR" "$ROOT/tools/nextflow-home" "$ROOT/tools/nextflow-conda-cache"

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

cat > "$RUN_DIR/atacseq_ares_override.config" <<EOF
conda {
  enabled = true
  useMamba = true
  cacheDir = "$RUN_DIR/nextflow-conda-cache"
  createTimeout = '90 min'
}
EOF

for required in "$SOURCE_INPUT"; do
  if [ ! -s "$required" ]; then
    echo "ERROR: missing required ATAC-seq input: $required" >&2
    exit 1
  fi
done

python3 "$ROOT/scripts/localize_url_table.py" \
  --input "$SOURCE_INPUT" \
  --output "$INPUT" \
  --dest-dir "$FASTQ_DIR" \
  --columns fastq_1 fastq_2 \
  --attempts 5

export JAVA_HOME="$NF_ENV"
export JAVA_CMD="$NF_ENV/bin/java"
export NXF_HOME="$ROOT/tools/nextflow-home"
export NXF_OFFLINE=true
export NXF_OPTS="-Xms1g -Xmx8g"
export NXF_SYNTAX_PARSER=v1
export NXF_VER=23.04.0
REAL_MAMBA="$(command -v mamba || true)"
if [ -z "$REAL_MAMBA" ]; then
  REAL_MAMBA="$MINIFORGE/bin/mamba"
fi
mkdir -p "$RUN_DIR/bin"
cat > "$RUN_DIR/bin/mamba" <<EOF
#!/usr/bin/env bash
args=()
for arg in "\$@"; do
  if [ "\$arg" = "--mkdir" ]; then
    continue
  fi
  args+=("\$arg")
done
exec "$REAL_MAMBA" "\${args[@]}"
EOF
chmod +x "$RUN_DIR/bin/mamba"
export PATH="$RUN_DIR/bin:$NF_ENV/bin:$MINIFORGE/bin:$MINIFORGE/condabin:$PATH"

cd "$(dirname "$OUTDIR")"
nextflow run "$REPO" \
  -profile conda \
  -c "$ROOT/config/nextflow_ares_local_conda.config" \
  -c "$RUN_DIR/atacseq_ares_override.config" \
  -work-dir "$WORKDIR" \
  --input "$INPUT" \
  --genome hg19 \
  --igenomes_base "https://ngi-igenomes.s3.amazonaws.com/igenomes" \
  --read_length 50 \
  --mito_name MT \
  --fingerprint_bins 100 \
  --outdir "$OUTDIR"

if ! find "$OUTDIR/pipeline_info" -maxdepth 1 -type f -name 'execution_trace_*.txt' -size +0 | grep -q .; then
  echo "ERROR: missing Nextflow execution trace in $OUTDIR/pipeline_info" >&2
  exit 1
fi

if ! find "$OUTDIR" -type f -name '*multiqc*html' -size +100000 | grep -q .; then
  echo "ERROR: missing non-trivial MultiQC HTML output" >&2
  exit 1
fi

OUTPUT_COUNT="$(find "$OUTDIR" -type f -size +0 | wc -l)"
if [ "$OUTPUT_COUNT" -lt 20 ]; then
  echo "ERROR: too few non-empty outputs for ATAC-seq baseline: $OUTPUT_COUNT" >&2
  exit 1
fi

echo "nf-core/atacseq single-node native Nextflow baseline completed with $OUTPUT_COUNT non-empty output files"
