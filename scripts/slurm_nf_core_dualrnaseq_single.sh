#!/bin/bash
#SBATCH --job-name=dualrnaseq-single
#SBATCH --exclusive
#SBATCH --partition=compute
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/nf-core_dualrnaseq/slurm-%j-single.out
#SBATCH --error=runs/nf-core_dualrnaseq/slurm-%j-single.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

REPO="$ROOT/repos/nf-core_dualrnaseq"
DATA="$ROOT/data/nf-core_dualrnaseq/full"
OUTDIR="$ROOT/runs/nf-core_dualrnaseq/single-${SLURM_JOB_ID:-manual}/results"
WORKDIR="$ROOT/runs/nf-core_dualrnaseq/single-${SLURM_JOB_ID:-manual}/work"
RUN_DIR="$(dirname "$OUTDIR")"
CUSTOM_CONFIG="$RUN_DIR/dualrnaseq_karp_full.config"
NF_ENV="$ROOT/tools/conda-envs/nextflow"
MINIFORGE="$ROOT/tools/miniforge"
HOST_FASTA="$DATA/reference/GRCh38.primary_assembly.genome.fa.gz"
HOST_GFF="$DATA/reference/gencode.v35.annotation.gff3.gz"
HOST_FASTA_URL="https://ftp.ebi.ac.uk/pub/databases/gencode/Gencode_human/release_35/GRCh38.primary_assembly.genome.fa.gz"
HOST_GFF_URL="https://ftp.ebi.ac.uk/pub/databases/gencode/Gencode_human/release_35/gencode.v35.annotation.gff3.gz"
FASTQ_DIR="$DATA/fastq"
FASTQ_R1="$FASTQ_DIR/SRR10355817.fastq.gz"
FASTQ_R2="$FASTQ_DIR/SRR10355818.fastq.gz"
FASTQ_R3="$FASTQ_DIR/SRR10355819.fastq.gz"
FASTQ_R1_URL="https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR103/017/SRR10355817/SRR10355817.fastq.gz"
FASTQ_R2_URL="https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR103/018/SRR10355818/SRR10355818.fastq.gz"
FASTQ_R3_URL="https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR103/019/SRR10355819/SRR10355819.fastq.gz"

mkdir -p "$RUN_DIR" "$OUTDIR" "$WORKDIR" "$ROOT/tools/nextflow-home" "$ROOT/tools/nextflow-conda-cache"

TMP_ROOT="$WORKDIR/tmp"
PKGS_ROOT="$RUN_DIR/conda-pkgs"
mkdir -p "$TMP_ROOT" "$PKGS_ROOT" "$RUN_DIR/nextflow-conda-cache" "$DATA/reference" "$FASTQ_DIR"
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

for required in "$DATA/reference/Karp_LS398548.1.fasta" "$DATA/reference/Karp_LS398548.1.gff3" "$DATA/SRP227242_runinfo.csv"; do
  if [ ! -s "$required" ]; then
    echo "ERROR: missing dualrnaseq full input metadata/reference: $required" >&2
    exit 1
  fi
done

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
  if [ -s "$tmp" ] && gzip -t "$tmp" >/dev/null 2>&1; then
    mv "$tmp" "$dest"
    return 0
  fi

  for attempt in $(seq 1 20); do
    if [ -s "$tmp" ]; then
      curl -L --fail --retry 8 --retry-delay 20 --retry-all-errors --continue-at - -o "$tmp" "$url" || rm -f "$tmp"
    fi
    if [ ! -s "$tmp" ]; then
      curl -L --fail --retry 8 --retry-delay 20 --retry-all-errors -o "$tmp" "$url" || true
    fi
    if [ -s "$tmp" ] && gzip -t "$tmp" >/dev/null 2>&1; then
      mv "$tmp" "$dest"
      return 0
    fi
    rm -f "$tmp"
    sleep 30
  done

  echo "ERROR: failed to download and validate $url -> $dest" >&2
  return 1
}

download_gzip "$HOST_FASTA_URL" "$HOST_FASTA"
download_gzip "$HOST_GFF_URL" "$HOST_GFF"
download_gzip "$FASTQ_R1_URL" "$FASTQ_R1"
download_gzip "$FASTQ_R2_URL" "$FASTQ_R2"
download_gzip "$FASTQ_R3_URL" "$FASTQ_R3"

cat > "$CUSTOM_CONFIG" <<CONFIG
params {
  config_profile_name = 'Full Karp HUVEC replacement profile'
  config_profile_description = 'Full dual RNA-seq Karp-infected HUVEC runs from GSE139498/SRP227242'

  max_cpus = 40
  max_memory = '40.GB'
  max_time = '48.h'

  single_end = true
  genomes_ignore = true
  run_bbduk = true
  qtrim = 'rl'
  run_salmon_selective_alignment = true
  libtype = 'A'
  gene_feature_gff_to_create_transcriptome_pathogen = ['CDS','tRNA','rRNA','ncRNA']
  mapping_statistics = true

  input_paths = [
    ['Human_Karp_R1', ['$FASTQ_R1']],
    ['Human_Karp_R2', ['$FASTQ_R2']],
    ['Human_Karp_R3', ['$FASTQ_R3']]
  ]

  genomes {
    'full_karp_host' {
      fasta_host = '$HOST_FASTA'
      gff_host = '$HOST_GFF'
      gff_host_tRNA = ''
    }
    'full_karp_pathogen' {
      fasta_pathogen = '$DATA/reference/Karp_LS398548.1.fasta'
      gff_pathogen = '$DATA/reference/Karp_LS398548.1.gff3'
    }
  }

  genome_host = 'full_karp_host'
  genome_pathogen = 'full_karp_pathogen'
}

conda {
  enabled = true
  useMamba = true
  cacheDir = "$RUN_DIR/nextflow-conda-cache"
}
CONFIG

export JAVA_HOME="$NF_ENV"
export JAVA_CMD="$NF_ENV/bin/java"
export NXF_HOME="$ROOT/tools/nextflow-home"
export NXF_VER=21.10.6
export NXF_OPTS="-Xms1g -Xmx8g"
export PATH="$NF_ENV/bin:$MINIFORGE/bin:$MINIFORGE/condabin:$PATH"

cd "$RUN_DIR"
nextflow run "$REPO" \
  -profile conda \
  -c "$ROOT/config/nextflow_ares_local_conda.config" \
  -c "$CUSTOM_CONFIG" \
  -work-dir "$WORKDIR" \
  --outdir "$OUTDIR"

if ! find "$OUTDIR/pipeline_info" -maxdepth 1 -type f -name 'execution_trace*' -size +0 | grep -q .; then
  echo "ERROR: missing Nextflow execution trace in $OUTDIR/pipeline_info" >&2
  exit 1
fi

if ! find "$OUTDIR" -type f \( -name '*.bam' -o -name '*.sam' -o -name '*.quant.sf' -o -name '*.tsv' -o -name '*.csv' \) -size +0 | grep -q .; then
  echo "ERROR: missing non-empty dual RNA-seq analysis outputs" >&2
  exit 1
fi

OUTPUT_COUNT="$(find "$OUTDIR" -type f -size +0 | wc -l)"
if [ "$OUTPUT_COUNT" -lt 30 ]; then
  echo "ERROR: too few non-empty outputs for full dualrnaseq baseline: $OUTPUT_COUNT" >&2
  exit 1
fi

echo "nf-core/dualrnaseq single-node native Nextflow baseline completed with $OUTPUT_COUNT non-empty output files"
