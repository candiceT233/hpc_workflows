#!/bin/bash
#SBATCH --job-name=mag-single
#SBATCH --exclusive
#SBATCH --partition=compute
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/nf-core_mag/slurm-%j-single.out
#SBATCH --error=runs/nf-core_mag/slurm-%j-single.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

REPO="$ROOT/repos/nf-core_mag"
DATA_DIR="$ROOT/data/nf-core_mag/full"
REMOTE_INPUT="$DATA_DIR/zenodo_10472796_samplesheet.csv"
FASTQ_DIR="$DATA_DIR/fastq"
REF_DIR="$DATA_DIR/reference"
INPUT="$DATA_DIR/samplesheet.full.v4.local.csv"
HOST_FASTA="$REF_DIR/GRCh38_genome.fa.gz"
OUTDIR="$ROOT/runs/nf-core_mag/single-${SLURM_JOB_ID:-manual}/results"
WORKDIR="$ROOT/runs/nf-core_mag/single-${SLURM_JOB_ID:-manual}/work"
RUN_DIR="$(dirname "$OUTDIR")"
NF_ENV="$ROOT/tools/conda-envs/nextflow"
MINIFORGE="$ROOT/tools/miniforge"

mkdir -p "$ROOT/runs/nf-core_mag" "$RUN_DIR" "$OUTDIR" "$WORKDIR" "$ROOT/tools/nextflow-home" "$FASTQ_DIR" "$REF_DIR"

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

cat > "$RUN_DIR/mag_ares_override.config" <<EOF
conda {
  enabled = true
  useMamba = true
  cacheDir = "$RUN_DIR/nextflow-conda-cache"
}

process {
  withName: /.*METASPADES.*/ {
    ext.args = "--tmp-dir $WORKDIR/spades-tmp --meta"
  }
}
EOF

export JAVA_HOME="$NF_ENV"
export JAVA_CMD="$NF_ENV/bin/java"
export NXF_HOME="$ROOT/tools/nextflow-home"
export NXF_OFFLINE=true
export NXF_VER=26.04.1
export NXF_OPTS="-Xms1g -Xmx8g"
export NXF_SYNTAX_PARSER=v1
export PATH="$NF_ENV/bin:$MINIFORGE/bin:$MINIFORGE/condabin:$PATH"

download_gzip() {
  local url="$1"
  local dest="$2"
  local tmp="${dest}.part"
  local attempt
  if [ -s "$dest" ] && gzip -t "$dest" >/dev/null 2>&1; then
    return 0
  fi
  if [ -s "$dest" ] && [ ! -s "$tmp" ]; then
    mv "$dest" "$tmp"
  fi
  for attempt in $(seq 1 20); do
    if curl -L --fail --retry 8 --retry-delay 15 --retry-all-errors --continue-at - "$url" -o "$tmp" \
      && gzip -t "$tmp" >/dev/null 2>&1; then
      mv "$tmp" "$dest"
      return 0
    fi
    sleep 30
  done
  echo "ERROR: failed to download and validate $url -> $dest" >&2
  return 1
}

if [ ! -s "$REMOTE_INPUT" ]; then
  echo "ERROR: missing MAG remote samplesheet: $REMOTE_INPUT" >&2
  exit 1
fi

if [ ! -s "$REF_DIR/GRCh38_genome.fa" ]; then
  curl -L --fail --retry 8 --retry-delay 15 --retry-all-errors \
    "https://ngi-igenomes.s3.amazonaws.com/igenomes/Homo_sapiens/NCBI/GRCh38/Sequence/WholeGenomeFasta/genome.fa" \
    -o "$REF_DIR/GRCh38_genome.fa"
fi
if [ ! -s "$HOST_FASTA" ] || ! gzip -t "$HOST_FASTA" >/dev/null 2>&1; then
  gzip -c "$REF_DIR/GRCh38_genome.fa" > "$HOST_FASTA.tmp"
  mv "$HOST_FASTA.tmp" "$HOST_FASTA"
fi

{
  IFS=, read -r sample_col group_col short_platform_col short1_col short2_col long_platform_col long_col
  printf '%s,%s,%s,%s,%s,%s,%s\n' "$sample_col" "$group_col" "$short_platform_col" "$short1_col" "$short2_col" "$long_platform_col" "$long_col"
  while IFS=, read -r sample group short_platform short1 short2 long_platform long; do
    [ -n "$sample" ] || continue
    short1_dest="$FASTQ_DIR/$(basename "$short1")"
    short2_dest="$FASTQ_DIR/$(basename "$short2")"
    long_dest="$FASTQ_DIR/$(basename "$long")"
    download_gzip "$short1" "$short1_dest"
    download_gzip "$short2" "$short2_dest"
    download_gzip "$long" "$long_dest"
    printf '%s,%s,%s,%s,%s,%s,%s\n' "$sample" "$group" "$short_platform" "$short1_dest" "$short2_dest" "$long_platform" "$long_dest"
  done
} < "$REMOTE_INPUT" > "$INPUT.tmp"
mv "$INPUT.tmp" "$INPUT"

cd "$(dirname "$OUTDIR")"
nextflow run "$REPO" \
  -profile conda \
  -c "$ROOT/config/nextflow_ares_local_conda.config" \
  -c "$RUN_DIR/mag_ares_override.config" \
  -work-dir "$WORKDIR" \
  --input "$INPUT" \
  --host_fasta "$HOST_FASTA" \
  --skip_gtdbtk true \
  --skip_spades false \
  --skip_spadeshybrid true \
  --spades_fix_cpus 10 \
  --spadeshybrid_fix_cpus 10 \
  --megahit_fix_cpu_1 true \
  --longread_percentidentity 85 \
  --skip_concoct true \
  --run_checkm2 true \
  --run_busco false \
  --prokka_with_compliance true \
  --prokka_compliance_centre nfcore \
  --outdir "$OUTDIR"

if ! find "$OUTDIR/pipeline_info" -maxdepth 1 -type f -name 'execution_trace*' -size +0 | grep -q .; then
  echo "ERROR: missing Nextflow execution trace in $OUTDIR/pipeline_info" >&2
  exit 1
fi

if ! find "$OUTDIR/multiqc" -type f -name 'multiqc_report.html' -size +100000 | grep -q .; then
  echo "ERROR: missing non-trivial MultiQC report" >&2
  exit 1
fi

if ! find "$OUTDIR/Assembly" "$OUTDIR/assembly" -type f -size +0 2>/dev/null | grep -q .; then
  echo "ERROR: missing non-empty assembly outputs" >&2
  exit 1
fi

if ! find "$OUTDIR" -type f \( -name '*bin*.fa' -o -name '*bin*.fa.gz' -o -name '*bins*.tsv' \) -size +0 | grep -q .; then
  echo "ERROR: missing non-empty binning outputs" >&2
  exit 1
fi

OUTPUT_COUNT="$(find "$OUTDIR" -type f -size +0 | wc -l)"
if [ "$OUTPUT_COUNT" -lt 100 ]; then
  echo "ERROR: too few non-empty outputs for full MAG baseline: $OUTPUT_COUNT" >&2
  exit 1
fi

echo "nf-core/mag single-node native Nextflow baseline completed with $OUTPUT_COUNT non-empty output files"
