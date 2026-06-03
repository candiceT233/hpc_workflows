#!/bin/bash
#SBATCH --job-name=methylseq-single
#SBATCH --exclusive
#SBATCH --partition=compute
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/nf-core_methylseq/slurm-%j-single.out
#SBATCH --error=runs/nf-core_methylseq/slurm-%j-single.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

REPO="$ROOT/repos/nf-core_methylseq"
REMOTE_INPUT="$ROOT/data/nf-core_methylseq/full/encode_gm12878_wgbs_samplesheet.csv"
INPUT="$ROOT/data/nf-core_methylseq/full/samplesheet_full_local.csv"
FASTQ_DIR="$ROOT/data/nf-core_methylseq/full/fastq"
REF_DIR="$ROOT/data/nf-core_methylseq/full/reference"
FASTA="$REF_DIR/GRCh38.primary_assembly.genome.fa.gz"
FALLBACK_FASTA="$ROOT/data/nf-core_dualrnaseq/full/reference/GRCh38.primary_assembly.genome.fa.gz"
OUTDIR="$ROOT/runs/nf-core_methylseq/single-${SLURM_JOB_ID:-manual}/results"
WORKDIR="$ROOT/runs/nf-core_methylseq/single-${SLURM_JOB_ID:-manual}/work"
RUN_DIR="$(dirname "$OUTDIR")"
NF_ENV="$ROOT/tools/conda-envs/nextflow"
MINIFORGE="$ROOT/tools/miniforge"

mkdir -p "$ROOT/runs/nf-core_methylseq" "$RUN_DIR" "$OUTDIR" "$WORKDIR" "$ROOT/tools/nextflow-home" "$FASTQ_DIR" "$REF_DIR"

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

cat > "$RUN_DIR/methylseq_ares_override.config" <<EOF
process {
  withLabel: process_high {
    cpus = 8
    memory = 40.GB
  }
}

conda {
  enabled = true
  useMamba = true
  cacheDir = "$RUN_DIR/nextflow-conda-cache"
}

params {
  max_cpus = 40
  max_memory = '40.GB'
  max_time = '48.h'
}
EOF

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
    if curl -L --fail --retry 8 --retry-delay 10 --retry-all-errors --continue-at - "$url" -o "$tmp" \
      && gzip -t "$tmp" >/dev/null 2>&1; then
      mv "$tmp" "$dest"
      return 0
    fi
    sleep 30
  done

  echo "ERROR: failed to download and validate $url -> $dest" >&2
  return 1
}

if [ ! -s "$FASTA" ]; then
  if [ -s "$FALLBACK_FASTA" ] && gzip -t "$FALLBACK_FASTA" >/dev/null 2>&1; then
    ln -sf "$FALLBACK_FASTA" "$FASTA"
  else
    download_gzip \
      "https://ftp.ebi.ac.uk/pub/databases/gencode/Gencode_human/release_43/GRCh38.primary_assembly.genome.fa.gz" \
      "$FASTA"
  fi
fi

{
  IFS=',' read -r sample_col fastq1_col fastq2_col genome_col
  printf '%s,%s,%s,%s\n' "$sample_col" "$fastq1_col" "$fastq2_col" "$genome_col"
  while IFS=',' read -r sample fastq_1 fastq_2 genome; do
    [ -n "$sample" ] || continue
    fastq1_dest="$FASTQ_DIR/$(basename "$fastq_1")"
    fastq2_dest="$FASTQ_DIR/$(basename "$fastq_2")"
    download_gzip "$fastq_1" "$fastq1_dest"
    download_gzip "$fastq_2" "$fastq2_dest"
    printf '%s,%s,%s,%s\n' "$sample" "$fastq1_dest" "$fastq2_dest" "${genome:-}"
  done
} < "$REMOTE_INPUT" > "$INPUT.tmp"
mv "$INPUT.tmp" "$INPUT"

export JAVA_HOME="$NF_ENV"
export JAVA_CMD="$NF_ENV/bin/java"
export NXF_HOME="$ROOT/tools/nextflow-home"
export NXF_VER=26.04.1
export NXF_OPTS="-Xms1g -Xmx8g"
export NXF_SYNTAX_PARSER=v1
export NXF_OFFLINE=true
export PATH="$NF_ENV/bin:$MINIFORGE/bin:$MINIFORGE/condabin:$PATH"

cd "$(dirname "$OUTDIR")"
nextflow run "$REPO" \
  -profile conda \
  -c "$ROOT/config/nextflow_ares_local_conda.config" \
  -c "$RUN_DIR/methylseq_ares_override.config" \
  -work-dir "$WORKDIR" \
  --input "$INPUT" \
  --igenomes_ignore true \
  --fasta "$FASTA" \
  --save_reference true \
  --outdir "$OUTDIR"

if ! find "$OUTDIR/pipeline_info" -maxdepth 1 -type f -name 'execution_trace*' -size +0 | grep -q .; then
  echo "ERROR: missing Nextflow execution trace in $OUTDIR/pipeline_info" >&2
  exit 1
fi

if ! find "$OUTDIR/multiqc" -type f -name 'multiqc_report.html' -size +100000 | grep -q .; then
  echo "ERROR: missing non-trivial MultiQC report" >&2
  exit 1
fi

if ! find "$OUTDIR/bismark" -type f -size +0 | grep -q .; then
  echo "ERROR: missing non-empty Bismark outputs" >&2
  exit 1
fi

if ! find "$OUTDIR/bismark/methylation_calls" -type f -size +0 | grep -q .; then
  echo "ERROR: missing non-empty methylation-call outputs" >&2
  exit 1
fi

OUTPUT_COUNT="$(find "$OUTDIR" -type f -size +0 | wc -l)"
if [ "$OUTPUT_COUNT" -lt 50 ]; then
  echo "ERROR: too few non-empty outputs for full methylseq baseline: $OUTPUT_COUNT" >&2
  exit 1
fi

echo "nf-core/methylseq single-node native Nextflow baseline completed with $OUTPUT_COUNT non-empty output files"
