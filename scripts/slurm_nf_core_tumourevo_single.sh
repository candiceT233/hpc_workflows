#!/bin/bash
#SBATCH --job-name=tumourevo-single
#SBATCH --exclusive
#SBATCH --partition=compute
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/nf-core_tumourevo/slurm-%j-single.out
#SBATCH --error=runs/nf-core_tumourevo/slurm-%j-single.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

REPO="$ROOT/repos/nf-core_tumourevo"
INPUT_DIR="$ROOT/data/nf-core_tumourevo/full_real"
INPUT="$INPUT_DIR/samplesheet_cnaqc_set06.csv"
VCF="$INPUT_DIR/Set.06.WGS.merged_filtered.vcf"
TBI="$INPUT_DIR/Set.06.WGS.merged_filtered.vcf.tbi"
CNA_SEGMENTS="$INPUT_DIR/Set6_42.smoothedSegs.txt"
CNA_EXTRA="$INPUT_DIR/Set6_42_confints_CP.txt"
FASTA="$INPUT_DIR/Homo_sapiens.GRCh38.dna.primary_assembly.fa.gz"
DRIVERS_TABLE="$INPUT_DIR/IntOGen_20240920_Compendium_Cancer_Genes.tumourevo.tsv"
VEP_CACHE_URL="${TUMOUREVO_VEP_CACHE_URL:-https://ftp.ensembl.org/pub/release-110/variation/indexed_vep_cache/homo_sapiens_vep_110_GRCh38.tar.gz}"
VEP_CACHE_DIR="${TUMOUREVO_VEP_CACHE_DIR:-$ROOT/data/nf-core_tumourevo/full/vep_cache}"
VEP_CACHE_FILE="$VEP_CACHE_DIR/homo_sapiens_vep_110_GRCh38.tar.gz"
VEP_CACHE_EXTRACTED="$VEP_CACHE_DIR/homo_sapiens"
OUTDIR="$ROOT/runs/nf-core_tumourevo/single-${SLURM_JOB_ID:-manual}/results"
WORKDIR="$ROOT/runs/nf-core_tumourevo/single-${SLURM_JOB_ID:-manual}/work"
RUN_DIR="$(dirname "$OUTDIR")"
NF_ENV="$ROOT/tools/conda-envs/nextflow"
MINIFORGE="$ROOT/tools/miniforge"

mkdir -p "$ROOT/runs/nf-core_tumourevo" "$RUN_DIR" "$OUTDIR" "$WORKDIR" "$ROOT/tools/nextflow-home" "$VEP_CACHE_DIR" "$INPUT_DIR"

ensure_vep_cache() {
  if [ -d "$VEP_CACHE_EXTRACTED" ] && find "$VEP_CACHE_EXTRACTED" -type f -size +0 | grep -q .; then
    return 0
  fi
  if [ -s "$VEP_CACHE_FILE" ]; then
    echo "Resuming incomplete VEP cache download: $VEP_CACHE_FILE"
  fi
  curl --fail --location --retry 20 --retry-delay 30 --continue-at - \
    --output "$VEP_CACHE_FILE" "$VEP_CACHE_URL"
  gzip -t "$VEP_CACHE_FILE"
  tar -xzf "$VEP_CACHE_FILE" -C "$VEP_CACHE_DIR"
  if [ ! -d "$VEP_CACHE_EXTRACTED" ]; then
    echo "ERROR: extracted VEP cache missing $VEP_CACHE_EXTRACTED" >&2
    return 1
  fi
}

TMP_ROOT="$WORKDIR/tmp"
PKGS_ROOT="$RUN_DIR/conda-pkgs"
CONDARC_FILE="$RUN_DIR/condarc"
mkdir -p "$TMP_ROOT" "$PKGS_ROOT" "$RUN_DIR/nextflow-conda-cache"
cat > "$CONDARC_FILE" <<EOF
always_yes: true
auto_activate_base: false
channel_priority: flexible
pkgs_dirs:
  - $PKGS_ROOT
channels:
  - conda-forge
  - bioconda
  - defaults
EOF
export TMPDIR="$TMP_ROOT"
export NXF_TEMP="$TMP_ROOT"
export _JAVA_OPTIONS="${_JAVA_OPTIONS:-} -Djava.io.tmpdir=$TMP_ROOT"
export MAMBA_YES=true
export MAMBA_ALWAYS_YES=true
export CONDA_ALWAYS_YES=true
export CONDA_PKGS_DIRS="$PKGS_ROOT"
export CONDARC="$CONDARC_FILE"

cat > "$RUN_DIR/tumourevo_ares_override.config" <<EOF
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
export NXF_VER="25.04.8"
export NXF_OPTS="-Xms1g -Xmx8g"
export NXF_SYNTAX_PARSER=v1
export PATH="$NF_ENV/bin:$MINIFORGE/bin:$MINIFORGE/condabin:$PATH"

ensure_vep_cache

source "$ROOT/scripts/tumourevo_real_inputs.sh"
prepare_tumourevo_real_inputs "$ROOT" "$INPUT_DIR" "$INPUT" "$VCF" "$TBI" "$CNA_SEGMENTS" "$CNA_EXTRA" "$FASTA" "$DRIVERS_TABLE"

cd "$(dirname "$OUTDIR")"
nextflow run "$REPO" \
  -name "tumourevo_single_${SLURM_JOB_ID:-manual}" \
  -profile conda \
  -c "$ROOT/config/nextflow_ares_local_conda.config" \
  -c "$RUN_DIR/tumourevo_ares_override.config" \
  -work-dir "$WORKDIR" \
  --input "$INPUT" \
  --filter false \
  --fasta "$FASTA" \
  --drivers_table "$DRIVERS_TABLE" \
  --download_cache_vep false \
  --vep_cache "$VEP_CACHE_DIR" \
  --vep_genome GRCh38 \
  --vep_species homo_sapiens \
  --vep_cache_version 110 \
  --outdir "$OUTDIR"

if ! find "$OUTDIR/pipeline_info" -maxdepth 1 -type f -name 'execution_trace*' -size +0 | grep -q .; then
  echo "ERROR: missing Nextflow execution trace in $OUTDIR/pipeline_info" >&2
  exit 1
fi

if ! find "$OUTDIR" -type f \( -name '*.rds' -o -name '*.pdf' -o -name '*.png' -o -name '*.tsv' -o -name '*.csv' \) -size +0 | grep -q .; then
  echo "ERROR: missing non-empty tumour evolution analysis outputs" >&2
  exit 1
fi

if ! find "$OUTDIR/subclonal_deconvolution" -type f -size +0 | grep -q .; then
  echo "ERROR: missing non-empty subclonal deconvolution outputs" >&2
  exit 1
fi

OUTPUT_COUNT="$(find "$OUTDIR" -type f -size +0 | wc -l)"
if [ "$OUTPUT_COUNT" -lt 30 ]; then
  echo "ERROR: too few non-empty outputs for tumourevo baseline: $OUTPUT_COUNT" >&2
  exit 1
fi

echo "nf-core/tumourevo single-node native Nextflow baseline completed with $OUTPUT_COUNT non-empty output files"
