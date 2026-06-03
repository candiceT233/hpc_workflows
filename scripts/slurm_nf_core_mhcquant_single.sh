#!/bin/bash
#SBATCH --job-name=mhcquant-single
#SBATCH --exclusive
#SBATCH --partition=compute
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/nf-core_mhcquant/slurm-%j-single.out
#SBATCH --error=runs/nf-core_mhcquant/slurm-%j-single.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

REPO="$ROOT/repos/nf-core_mhcquant"
SOURCE_INPUT="$ROOT/data/nf-core_mhcquant/full_uniprot/sample_sheet_full_https.tsv"
DATA_DIR="$ROOT/data/nf-core_mhcquant/full_uniprot"
RAW_DIR="$DATA_DIR/raw"
FASTA_DIR="$DATA_DIR/fasta"
INPUT="$DATA_DIR/sample_sheet_full_local.tsv"
OUTDIR="$ROOT/runs/nf-core_mhcquant/single-${SLURM_JOB_ID:-manual}/results"
WORKDIR="$ROOT/runs/nf-core_mhcquant/single-${SLURM_JOB_ID:-manual}/work"
RUN_DIR="$(dirname "$OUTDIR")"
NF_ENV="$ROOT/tools/conda-envs/nextflow"
MINIFORGE="$ROOT/tools/miniforge"

mkdir -p "$ROOT/runs/nf-core_mhcquant" "$RUN_DIR" "$OUTDIR" "$WORKDIR" "$ROOT/tools/nextflow-home" "$RAW_DIR" "$FASTA_DIR"

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

cat > "$RUN_DIR/mhcquant_ares_override.config" <<EOF
conda {
  enabled = true
  useMamba = true
  cacheDir = "$RUN_DIR/nextflow-conda-cache"
  createTimeout = '90 min'
}
process.maxForks = 4
EOF

if [ ! -s "$SOURCE_INPUT" ]; then
  echo "ERROR: missing source MHCquant sample sheet: $SOURCE_INPUT" >&2
  exit 1
fi

remote_size() {
  local url="$1"
  curl -sIL --fail "$url" \
    | awk 'tolower($1) == "content-length:" { size=$2 } END { gsub("\r", "", size); print size }'
}

download_file() {
  local url="$1"
  local dest="$2"
  local tmp="${dest}.part"
  local expected actual attempt

  expected="$(remote_size "$url" || true)"
  actual="0"
  if [ -s "$dest" ]; then
    actual="$(stat -c '%s' "$dest")"
  fi
  if [ -n "$expected" ] && [ "$actual" = "$expected" ]; then
    return 0
  fi
  if [ -z "$expected" ] && [ -s "$dest" ]; then
    return 0
  fi

  if [ -s "$dest" ] && [ ! -s "$tmp" ]; then
    mv "$dest" "$tmp"
  fi
  if [ -n "$expected" ] && [ -s "$tmp" ] && [ "$(stat -c '%s' "$tmp")" -gt "$expected" ]; then
    rm -f "$tmp"
  fi

  for attempt in $(seq 1 20); do
    if curl -L --fail --retry 8 --retry-delay 15 --retry-all-errors --continue-at - "$url" -o "$tmp"; then
      actual="$(stat -c '%s' "$tmp")"
      if [ -z "$expected" ] || [ "$actual" = "$expected" ]; then
        mv "$tmp" "$dest"
        return 0
      fi
      echo "download size mismatch for $url: got $actual expected $expected" >&2
    fi
    sleep 30
  done

  echo "ERROR: failed to download and validate $url -> $dest" >&2
  return 1
}

{
  IFS= read -r header
  printf '%s\n' "$header"
  while IFS=$'\t' read -r id sample condition replicate fasta; do
    [ -n "$id" ] || continue
    raw_dest="$RAW_DIR/$(basename "$replicate")"
    fasta_gz_dest="$FASTA_DIR/$(basename "$fasta")"
    fasta_dest="${fasta_gz_dest%.gz}"
    download_file "$replicate" "$raw_dest"
    download_file "$fasta" "$fasta_gz_dest"
    if [ ! -s "$fasta_dest" ] || [ "$fasta_gz_dest" -nt "$fasta_dest" ]; then
      gzip -dc "$fasta_gz_dest" > "$fasta_dest.tmp"
      mv "$fasta_dest.tmp" "$fasta_dest"
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$sample" "$condition" "$raw_dest" "$fasta_dest"
  done
} < "$SOURCE_INPUT" > "$INPUT"

export JAVA_HOME="$NF_ENV"
export JAVA_CMD="$NF_ENV/bin/java"
export NXF_HOME="$ROOT/tools/nextflow-home"
export NXF_OFFLINE=true
export NXF_VER=26.04.1
export NXF_OPTS="-Xms1g -Xmx8g"
export NXF_SYNTAX_PARSER=v1
export PATH="$NF_ENV/bin:$MINIFORGE/bin:$MINIFORGE/condabin:$PATH"

cd "$(dirname "$OUTDIR")"
nextflow run "$REPO" \
  -profile conda \
  -c "$ROOT/config/nextflow_ares_local_conda.config" \
  -c "$RUN_DIR/mhcquant_ares_override.config" \
  -work-dir "$WORKDIR" \
  --input "$INPUT" \
  --outdir "$OUTDIR"

if ! find "$OUTDIR/pipeline_info" -maxdepth 1 -type f -name 'execution_trace*' -size +0 | grep -q .; then
  echo "ERROR: missing Nextflow execution trace in $OUTDIR/pipeline_info" >&2
  exit 1
fi

if ! find "$OUTDIR/multiqc" -type f -name 'multiqc_report.html' -size +100000 | grep -q .; then
  echo "ERROR: missing non-trivial MultiQC report" >&2
  exit 1
fi

if ! find "$OUTDIR" -type f \( -name '*.tsv' -o -name '*.mzTab' -o -name '*.idXML' \) -size +0 | grep -q .; then
  echo "ERROR: missing non-empty peptide identification/quantification outputs" >&2
  exit 1
fi

if ! find "$OUTDIR/intermediate_results" -type f -size +0 | grep -q .; then
  echo "ERROR: missing non-empty intermediate search outputs" >&2
  exit 1
fi

OUTPUT_COUNT="$(find "$OUTDIR" -type f -size +0 | wc -l)"
if [ "$OUTPUT_COUNT" -lt 30 ]; then
  echo "ERROR: too few non-empty outputs for full mhcquant baseline: $OUTPUT_COUNT" >&2
  exit 1
fi

echo "nf-core/mhcquant single-node native Nextflow baseline completed with $OUTPUT_COUNT non-empty output files"
