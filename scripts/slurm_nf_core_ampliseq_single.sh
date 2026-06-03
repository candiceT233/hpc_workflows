#!/bin/bash
#SBATCH --job-name=ampliseq-single
#SBATCH --exclusive
#SBATCH --partition=compute
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/nf-core_ampliseq/slurm-%j-single.out
#SBATCH --error=runs/nf-core_ampliseq/slurm-%j-single.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
REPO="$ROOT/repos/nf-core_ampliseq"
OUTDIR="$ROOT/runs/nf-core_ampliseq/single-${SLURM_JOB_ID:-manual}/results"
WORKDIR="$ROOT/runs/nf-core_ampliseq/single-${SLURM_JOB_ID:-manual}/work"
RUN_DIR="$(dirname "$OUTDIR")"
INPUT_DIR="$ROOT/data/nf-core_ampliseq/full"
REMOTE_SAMPLESHEET="$INPUT_DIR/Samplesheet_full.tsv"
REMOTE_METADATA="$INPUT_DIR/Metadata_full.tsv"
LOCAL_SAMPLESHEET="$INPUT_DIR/Samplesheet_full.local.tsv"
LOCAL_METADATA="$INPUT_DIR/Metadata_full.tsv"
FASTQ_DIR="$INPUT_DIR/fastq"
REF_DIR="$INPUT_DIR/ref"
NF_ENV="$ROOT/tools/conda-envs/nextflow"
MINIFORGE="$ROOT/tools/miniforge"
source "$ROOT/scripts/ampliseq_full_inputs.sh"

mkdir -p "$ROOT/runs/nf-core_ampliseq" "$RUN_DIR" "$OUTDIR" "$WORKDIR" "$ROOT/tools/nextflow-home" "$INPUT_DIR" "$FASTQ_DIR" "$REF_DIR" "$ROOT/tools/nextflow-conda-cache/nf-core_ampliseq"

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
export NXF_OFFLINE=true
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

cat > "$RUN_DIR/ampliseq_ares_override.config" <<EOF
conda {
  enabled = true
  useMamba = true
  cacheDir = "$ROOT/tools/nextflow-conda-cache/nf-core_ampliseq"
  createTimeout = '360 min'
}

process.maxForks = 4
EOF

if [ ! -x "$NF_ENV/bin/nextflow" ]; then
  echo "ERROR: missing local Nextflow environment at $NF_ENV" >&2
  exit 1
fi

download_input() {
  local url="$1"
  local dest="$2"
  if [ ! -s "$dest" ]; then
    curl -L --retry 8 --retry-delay 10 --retry-all-errors -o "$dest.tmp" "$url"
    mv "$dest.tmp" "$dest"
  fi
  test -s "$dest"
}

download_input "https://ndownloader.figshare.com/files/59220347" "$REF_DIR/sbdi-gtdb.assignTaxonomy.fna.gz"
download_input "https://ndownloader.figshare.com/files/59220356" "$REF_DIR/sbdi-gtdb.addSpecies.fna.gz"
download_input "https://data.qiime2.org/2023.7/tutorials/training-feature-classifiers/85_otus.fasta" "$REF_DIR/85_otus.fna"
download_input "https://data.qiime2.org/2023.7/tutorials/training-feature-classifiers/85_otu_taxonomy.txt" "$REF_DIR/85_otu_taxonomy.tax"

prepare_ampliseq_full_inputs "$ROOT"

export JAVA_HOME="$NF_ENV"
export JAVA_CMD="$NF_ENV/bin/java"
export NXF_HOME="$ROOT/tools/nextflow-home"
export NXF_OPTS="-Xms1g -Xmx8g"
export NXF_SYNTAX_PARSER=v1
export PATH="$NF_ENV/bin:$MINIFORGE/bin:$MINIFORGE/condabin:$PATH"

cd "$(dirname "$OUTDIR")"
nextflow run "$REPO" \
  -profile conda \
  -c "$ROOT/config/nextflow_ares_local_conda.config" \
  -c "$RUN_DIR/ampliseq_ares_override.config" \
  -work-dir "$WORKDIR" \
  --input "$AMPLISEQ_SAMPLESHEET" \
  --metadata "$AMPLISEQ_METADATA" \
  --FW_primer "GTGYCAGCMGCCGCGGTAA" \
  --RV_primer "GGACTACNVGGGTWTCTAAT" \
  --dada_ref_tax_custom "$REF_DIR/sbdi-gtdb.assignTaxonomy.fna.gz" \
  --dada_ref_tax_custom_sp "$REF_DIR/sbdi-gtdb.addSpecies.fna.gz" \
  --dada_assign_taxlevels "Domain,Kingdom,Phylum,Class,Order,Family,Genus,Species" \
  --qiime_ref_tax_custom "$REF_DIR/85_otus.fna,$REF_DIR/85_otu_taxonomy.tax" \
  --trunc_qmin 35 \
  --min_samples 3 \
  --min_frequency 30 \
  --metadata_category_barplot "habitat" \
  --qiime_adonis_formula "habitat" \
  --ancom \
  --ancombc \
  --run_pplace false \
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
  echo "ERROR: too few non-empty outputs for full ampliseq baseline: $OUTPUT_COUNT" >&2
  exit 1
fi

echo "nf-core/ampliseq single-node native Nextflow baseline completed with $OUTPUT_COUNT non-empty output files"
