#!/bin/bash
#SBATCH --job-name=nascent-single
#SBATCH --exclusive
#SBATCH --partition=compute
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/nf-core_nascent/slurm-%j-single.out
#SBATCH --error=runs/nf-core_nascent/slurm-%j-single.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

REPO="$ROOT/repos/nf-core_nascent"
SOURCE_INPUT="$ROOT/data/nf-core_nascent/full/samplesheet_full_https.csv"
DATA_DIR="$ROOT/data/nf-core_nascent/full"
FASTQ_DIR="$DATA_DIR/fastq"
INPUT="$DATA_DIR/samplesheet_full_local.csv"
OUTDIR="$ROOT/runs/nf-core_nascent/single-${SLURM_JOB_ID:-manual}/results"
WORKDIR="$ROOT/runs/nf-core_nascent/single-${SLURM_JOB_ID:-manual}/work"
RUN_DIR="$(dirname "$OUTDIR")"
NF_ENV="$ROOT/tools/conda-envs/nextflow"
MINIFORGE="$ROOT/tools/miniforge"

mkdir -p "$ROOT/runs/nf-core_nascent" "$RUN_DIR" "$OUTDIR" "$WORKDIR" "$ROOT/tools/nextflow-home" "$FASTQ_DIR"

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

cat > "$RUN_DIR/nascent_ares_override.config" <<EOF
conda {
  enabled = true
  useMamba = true
  cacheDir = "$RUN_DIR/nextflow-conda-cache"
}
EOF

if [ ! -s "$SOURCE_INPUT" ]; then
  echo "ERROR: missing source nascent samplesheet: $SOURCE_INPUT" >&2
  exit 1
fi

download_fastq() {
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
    if curl -L --fail --retry 8 --retry-delay 15 --retry-all-errors --continue-at - "$url" -o "$tmp"; then
      if gzip -t "$tmp" >/dev/null 2>&1; then
        mv "$tmp" "$dest"
        return 0
      fi
      echo "WARN: downloaded FASTQ failed gzip validation; retrying from scratch: $tmp" >&2
      rm -f "$tmp"
    fi
    sleep 30
  done

  echo "ERROR: failed to download and validate $url -> $dest" >&2
  return 1
}

{
  IFS= read -r header
  printf '%s\n' "$header"
  while IFS=, read -r sample fastq_1 fastq_2; do
    [ -n "$sample" ] || continue
    dest="$FASTQ_DIR/${sample}.fastq.gz"
    download_fastq "$fastq_1" "$dest"
    printf '%s,%s,%s\n' "$sample" "$dest" "${fastq_2:-}"
  done
} < "$SOURCE_INPUT" > "$INPUT"

for fastq in "$FASTQ_DIR"/*.fastq.gz; do
  gzip -t "$fastq"
done

export JAVA_HOME="$NF_ENV"
export JAVA_CMD="$NF_ENV/bin/java"
export NXF_HOME="$ROOT/tools/nextflow-home"
export NXF_VER=26.04.1
export NXF_OPTS="-Xms1g -Xmx8g"
export NXF_SYNTAX_PARSER=v1
export PATH="$NF_ENV/bin:$MINIFORGE/bin:$MINIFORGE/condabin:$PATH"

cd "$(dirname "$OUTDIR")"
nextflow run "$REPO" \
  -profile conda \
  -c "$ROOT/config/nextflow_ares_local_conda.config" \
  -c "$RUN_DIR/nascent_ares_override.config" \
  -work-dir "$WORKDIR" \
  --input "$INPUT" \
  --genome hg38 \
  --assay_type GROseq \
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
  echo "ERROR: missing non-empty BAM alignment outputs" >&2
  exit 1
fi

if ! find "$OUTDIR" -type f \( -name '*.bedGraph' -o -name '*.bedGraph.gz' -o -name '*.bw' -o -name '*.bigWig' \) -size +0 | grep -q .; then
  echo "ERROR: missing non-empty coverage graph outputs" >&2
  exit 1
fi

if ! find "$OUTDIR" -type f \( -name '*.transcripts.txt' -o -name '*.transcripts.bed' -o -name '*.tdFinal.txt' \) -size +0 | grep -q .; then
  echo "ERROR: missing non-empty transcript identification outputs" >&2
  exit 1
fi

OUTPUT_COUNT="$(find "$OUTDIR" -type f -size +0 | wc -l)"
if [ "$OUTPUT_COUNT" -lt 50 ]; then
  echo "ERROR: too few non-empty outputs for full nascent baseline: $OUTPUT_COUNT" >&2
  exit 1
fi

echo "nf-core/nascent single-node native Nextflow baseline completed with $OUTPUT_COUNT non-empty output files"
