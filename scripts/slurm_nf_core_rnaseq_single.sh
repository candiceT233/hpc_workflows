#!/bin/bash
#SBATCH --job-name=rnaseq-single
#SBATCH --exclusive
#SBATCH --partition=compute
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/nf-core_rnaseq/slurm-%j-single.out
#SBATCH --error=runs/nf-core_rnaseq/slurm-%j-single.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

REPO="$ROOT/repos/nf-core_rnaseq"
DATA_DIR="$ROOT/data/nf-core_rnaseq/full"
REMOTE_INPUT="$DATA_DIR/encode_gm12878_polya_samplesheet.csv"
FASTQ_DIR="$DATA_DIR/fastq"
REF_DIR="$DATA_DIR/reference"
INPUT="$DATA_DIR/samplesheet_full_local.csv"
FASTA="$REF_DIR/genome.fa"
GTF="$REF_DIR/genes.gtf"
OUTDIR="$ROOT/runs/nf-core_rnaseq/single-${SLURM_JOB_ID:-manual}/results"
WORKDIR="$ROOT/runs/nf-core_rnaseq/single-${SLURM_JOB_ID:-manual}/work"
RUN_DIR="$(dirname "$OUTDIR")"
NF_ENV="$ROOT/tools/conda-envs/nextflow"
MINIFORGE="$ROOT/tools/miniforge"

mkdir -p "$ROOT/runs/nf-core_rnaseq" "$RUN_DIR" "$OUTDIR" "$WORKDIR" "$ROOT/tools/nextflow-home" "$FASTQ_DIR" "$REF_DIR"

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

cat > "$RUN_DIR/rnaseq_ares_override.config" <<EOF
conda {
  enabled = true
  useMamba = true
  cacheDir = "$RUN_DIR/nextflow-conda-cache"
}
EOF

export JAVA_HOME="$NF_ENV"
export JAVA_CMD="$NF_ENV/bin/java"
export NXF_HOME="$ROOT/tools/nextflow-home"
export NXF_VER=26.04.1
export NXF_OPTS="-Xms1g -Xmx8g"
export NXF_SYNTAX_PARSER=v1
export PATH="$NF_ENV/bin:$MINIFORGE/bin:$MINIFORGE/condabin:$PATH"

download_file() {
  local url="$1"
  local dest="$2"
  local tmp="${dest}.part"
  local attempt
  if [ -s "$dest" ]; then
    if [[ "$dest" == *.gz ]]; then
      gzip -t "$dest" >/dev/null 2>&1 && return 0
    else
      return 0
    fi
  fi
  if [ -s "$dest" ] && [ ! -s "$tmp" ]; then
    mv "$dest" "$tmp"
  fi
  for attempt in $(seq 1 20); do
    if curl -L --fail --retry 8 --retry-delay 15 --retry-all-errors --continue-at - "$url" -o "$tmp"; then
      if [[ "$dest" != *.gz ]] || gzip -t "$tmp" >/dev/null 2>&1; then
        mv "$tmp" "$dest"
        return 0
      fi
    fi
    sleep 30
  done
  echo "ERROR: failed to download $url -> $dest" >&2
  return 1
}

if [ ! -s "$REMOTE_INPUT" ]; then
  echo "ERROR: missing rnaseq remote samplesheet: $REMOTE_INPUT" >&2
  exit 1
fi

download_file "https://ngi-igenomes.s3.amazonaws.com/igenomes/Homo_sapiens/Ensembl/GRCh37/Sequence/WholeGenomeFasta/genome.fa" "$FASTA"
download_file "https://ngi-igenomes.s3.amazonaws.com/igenomes/Homo_sapiens/Ensembl/GRCh37/Annotation/Genes/genes.gtf" "$GTF"

{
  IFS=, read -r sample_col r1_col r2_col stranded_col
  printf '%s,%s,%s,%s\n' "$sample_col" "$r1_col" "$r2_col" "$stranded_col"
  while IFS=, read -r sample r1 r2 strandedness; do
    [ -n "$sample" ] || continue
    r1_dest="$FASTQ_DIR/$(basename "$r1")"
    r2_dest="$FASTQ_DIR/$(basename "$r2")"
    download_file "$r1" "$r1_dest"
    download_file "$r2" "$r2_dest"
    printf '%s,%s,%s,%s\n' "$sample" "$r1_dest" "$r2_dest" "$strandedness"
  done
} < "$REMOTE_INPUT" > "$INPUT.tmp"
mv "$INPUT.tmp" "$INPUT"

cd "$(dirname "$OUTDIR")"
nextflow run "$REPO" \
  -profile conda \
  -c "$ROOT/config/nextflow_ares_local_conda.config" \
  -c "$RUN_DIR/rnaseq_ares_override.config" \
  -work-dir "$WORKDIR" \
  --input "$INPUT" \
  --igenomes_ignore true \
  --fasta "$FASTA" \
  --gtf "$GTF" \
  --outdir "$OUTDIR"

if ! find "$OUTDIR/pipeline_info" -maxdepth 1 -type f -name 'execution_trace*' -size +0 | grep -q .; then
  echo "ERROR: missing Nextflow execution trace in $OUTDIR/pipeline_info" >&2
  exit 1
fi

if ! find "$OUTDIR/multiqc" -type f -name '*multiqc_report.html' -size +100000 | grep -q .; then
  echo "ERROR: missing non-trivial MultiQC report" >&2
  exit 1
fi

if ! find "$OUTDIR/star_salmon" -type f \( -name '*.bam' -o -name '*.bai' \) -size +0 | grep -q .; then
  echo "ERROR: missing non-empty STAR/BAM outputs" >&2
  exit 1
fi

if ! find "$OUTDIR/star_salmon" -type f \( -name 'quant.sf' -o -name '*.counts.tsv' -o -name '*.featureCounts.txt' \) -size +0 | grep -q .; then
  echo "ERROR: missing non-empty quantification/count outputs" >&2
  exit 1
fi

OUTPUT_COUNT="$(find "$OUTDIR" -type f -size +0 | wc -l)"
if [ "$OUTPUT_COUNT" -lt 100 ]; then
  echo "ERROR: too few non-empty outputs for full rnaseq baseline: $OUTPUT_COUNT" >&2
  exit 1
fi

echo "nf-core/rnaseq single-node native Nextflow baseline completed with $OUTPUT_COUNT non-empty output files"
