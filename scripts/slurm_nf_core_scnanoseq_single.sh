#!/bin/bash
#SBATCH --job-name=scnanoseq-single
#SBATCH --exclusive
#SBATCH --partition=compute
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/nf-core_scnanoseq/slurm-%j-single.out
#SBATCH --error=runs/nf-core_scnanoseq/slurm-%j-single.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

REPO="$ROOT/repos/nf-core_scnanoseq"
INPUT="$ROOT/data/nf-core_scnanoseq/full/samplesheet_full_https.csv"
LOCAL_INPUT="$ROOT/data/nf-core_scnanoseq/full/samplesheet_full_local.csv"
FASTQ_DIR="$ROOT/data/nf-core_scnanoseq/full/fastq"
OUTDIR="$ROOT/runs/nf-core_scnanoseq/single-${SLURM_JOB_ID:-manual}/results"
WORKDIR="$ROOT/runs/nf-core_scnanoseq/single-${SLURM_JOB_ID:-manual}/work"
RUN_DIR="$(dirname "$OUTDIR")"
NF_ENV="$ROOT/tools/conda-envs/nextflow"
MINIFORGE="$ROOT/tools/miniforge"

mkdir -p "$ROOT/runs/nf-core_scnanoseq" "$RUN_DIR" "$OUTDIR" "$WORKDIR" "$ROOT/tools/nextflow-home" "$FASTQ_DIR"

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

cat > "$RUN_DIR/scnanoseq_ares_override.config" <<EOF
conda {
  enabled = true
  useMamba = true
  cacheDir = "$RUN_DIR/nextflow-conda-cache"
}
EOF

export JAVA_HOME="$NF_ENV"
export JAVA_CMD="$NF_ENV/bin/java"
export NXF_HOME="$ROOT/tools/nextflow-home"
export NXF_VER="24.10.5"
export NXF_OPTS="-Xms1g -Xmx8g"
export NXF_SYNTAX_PARSER=v1
export PATH="$NF_ENV/bin:$MINIFORGE/bin:$MINIFORGE/condabin:$PATH"

fetch_fastq() {
  local sample="$1"
  local url="$2"
  local dest="$FASTQ_DIR/${sample}.fastq.gz"
  local part="${dest}.part"
  if [ -s "$dest" ] && gzip -t "$dest" >/dev/null 2>&1; then
    echo "Using existing $dest"
  elif [ -s "$part" ] && gzip -t "$part" >/dev/null 2>&1; then
    mv "$part" "$dest"
  else
    rm -f "$dest"
    curl -L --fail --retry 8 --retry-delay 20 --retry-all-errors --continue-at - -o "$part" "$url"
    gzip -t "$part"
    mv "$part" "$dest"
  fi
}

fetch_fastq ERR9958133 https://ftp.sra.ebi.ac.uk/vol1/fastq/ERR995/003/ERR9958133/ERR9958133.fastq.gz
fetch_fastq ERR9958134 https://ftp.sra.ebi.ac.uk/vol1/fastq/ERR995/004/ERR9958134/ERR9958134.fastq.gz

cat > "$LOCAL_INPUT" <<EOF
sample,fastq,cell_count
ERR9958133,$FASTQ_DIR/ERR9958133.fastq.gz,1000
ERR9958134,$FASTQ_DIR/ERR9958134.fastq.gz,1000
EOF

cd "$(dirname "$OUTDIR")"
nextflow run "$REPO" \
  -profile conda \
  -c "$ROOT/config/nextflow_ares_local_conda.config" \
  -c "$RUN_DIR/scnanoseq_ares_override.config" \
  -work-dir "$WORKDIR" \
  --input "$LOCAL_INPUT" \
  --genome_fasta "https://ftp.ebi.ac.uk/pub/databases/gencode/Gencode_human/release_45/GRCh38.primary_assembly.genome.fa.gz" \
  --transcript_fasta "https://ftp.ebi.ac.uk/pub/databases/gencode/Gencode_human/release_45/gencode.v45.transcripts.fa.gz" \
  --gtf "https://ftp.ebi.ac.uk/pub/databases/gencode/Gencode_human/release_45/gencode.v45.annotation.gtf.gz" \
  --barcode_format "10X_3v3" \
  --split_amount 500000 \
  --quantifier "isoquant,oarfish" \
  --outdir "$OUTDIR"

if ! find "$OUTDIR/pipeline_info" -maxdepth 1 -type f -name 'execution_trace*' -size +0 | grep -q .; then
  echo "ERROR: missing Nextflow execution trace in $OUTDIR/pipeline_info" >&2
  exit 1
fi

if ! find "$OUTDIR/multiqc" -type f -name 'multiqc_report.html' -size +100000 | grep -q .; then
  echo "ERROR: missing non-trivial MultiQC report" >&2
  exit 1
fi

if ! find "$OUTDIR" -type f \( -name '*.sorted.bam' -o -name '*.dedup.bam' -o -name '*.tagged.bam' \) -size +0 | grep -q .; then
  echo "ERROR: missing non-empty BAM alignment outputs" >&2
  exit 1
fi

if ! find "$OUTDIR" -type f \( -name '*.gene_counts.tsv' -o -name '*.transcript_counts.tsv' -o -name '*quant*.tsv' -o -name '*quant*.csv' \) -size +0 | grep -q .; then
  echo "ERROR: missing non-empty feature-barcode quantification outputs" >&2
  exit 1
fi

OUTPUT_COUNT="$(find "$OUTDIR" -type f -size +0 | wc -l)"
if [ "$OUTPUT_COUNT" -lt 80 ]; then
  echo "ERROR: too few non-empty outputs for full scnanoseq baseline: $OUTPUT_COUNT" >&2
  exit 1
fi

echo "nf-core/scnanoseq single-node native Nextflow baseline completed with $OUTPUT_COUNT non-empty output files"
