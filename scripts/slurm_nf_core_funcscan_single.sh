#!/bin/bash
#SBATCH --job-name=funcscan-single
#SBATCH --exclusive
#SBATCH --partition=compute
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/nf-core_funcscan/slurm-%j-single.out
#SBATCH --error=runs/nf-core_funcscan/slurm-%j-single.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

REPO="$ROOT/repos/nf-core_funcscan"
DATA_DIR="$ROOT/data/nf-core_funcscan/refseq_bacteria"
REMOTE_INPUT="$DATA_DIR/samplesheet_full_https.csv"
FASTA_DIR="$DATA_DIR/fasta"
INPUT="$DATA_DIR/samplesheet_full_local.csv"
OUTDIR="$ROOT/runs/nf-core_funcscan/single-${SLURM_JOB_ID:-manual}/results"
WORKDIR="$ROOT/runs/nf-core_funcscan/single-${SLURM_JOB_ID:-manual}/work"
RUN_DIR="$(dirname "$OUTDIR")"
NF_ENV="$ROOT/tools/conda-envs/nextflow"
MINIFORGE="$ROOT/tools/miniforge"

mkdir -p "$ROOT/runs/nf-core_funcscan" "$OUTDIR" "$WORKDIR" "$ROOT/tools/nextflow-home" "$FASTA_DIR"

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

cat > "$RUN_DIR/funcscan_ares_override.config" <<EOF
conda {
  enabled = true
  useMamba = true
  cacheDir = "$RUN_DIR/nextflow-conda-cache"
  createTimeout = '90 min'
}
process {
  maxForks = 4
  withName: '.*ANTISMASH_ANTISMASH.*' {
    cpus = 8
    memory = '45.GB'
    time = '24.h'
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

precreate_conda_env() {
  local name="$1"
  local env_file="$2"
  local prefix="$RUN_DIR/nextflow-conda-cache/$name"
  local attempt
  if [ -x "$prefix/bin/antismash" ]; then
    return 0
  fi
  rm -rf "$prefix"
  for attempt in $(seq 1 3); do
    if mamba env create --yes --prefix "$prefix" --file "$env_file"; then
      if [ -x "$prefix/bin/antismash" ]; then
        return 0
      fi
    fi
    rm -rf "$prefix"
    sleep 60
  done
  echo "ERROR: failed to pre-create $env_file at $prefix" >&2
  return 1
}

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
  echo "ERROR: missing funcscan remote samplesheet: $REMOTE_INPUT" >&2
  exit 1
fi

{
  IFS=, read -r sample_col fasta_col
  printf '%s,%s\n' "$sample_col" "$fasta_col"
  while IFS=, read -r sample fasta_url; do
    [ -n "$sample" ] || continue
    fasta_dest="$FASTA_DIR/$(basename "$fasta_url")"
    download_gzip "$fasta_url" "$fasta_dest"
    printf '%s,%s\n' "$sample" "$fasta_dest"
  done
} < "$REMOTE_INPUT" > "$INPUT.tmp"
mv "$INPUT.tmp" "$INPUT"

precreate_conda_env \
  "env-3afb2e6d352a088017e79a544d2d4222" \
  "$REPO/modules/nf-core/antismash/antismashdownloaddatabases/environment.yml"

cd "$(dirname "$OUTDIR")"
nextflow run "$REPO" \
  -profile conda \
  -c "$ROOT/config/nextflow_ares_local_conda.config" \
  -c "$RUN_DIR/funcscan_ares_override.config" \
  -work-dir "$WORKDIR" \
  --input "$INPUT" \
  --save_annotations true \
  --run_amp_screening true \
  --amp_skip_amplify true \
  --run_arg_screening true \
  --arg_skip_deeparg true \
  --run_bgc_screening true \
  --bgc_skip_deepbgc true \
  --bgc_mincontiglength 1000 \
  --bgc_antismash_contigminlength 1000 \
  --bgc_savefilteredcontigs true \
  --outdir "$OUTDIR"

if ! find "$OUTDIR/pipeline_info" -maxdepth 1 -type f -name 'execution_trace*' -size +0 | grep -q .; then
  echo "ERROR: missing Nextflow execution trace in $OUTDIR/pipeline_info" >&2
  exit 1
fi

if ! find "$OUTDIR/multiqc" -type f -name 'multiqc_report.html' -size +100000 | grep -q .; then
  echo "ERROR: missing non-trivial MultiQC report" >&2
  exit 1
fi

if ! find "$OUTDIR/arg" -type f -size +0 | grep -q .; then
  echo "ERROR: missing non-empty ARG outputs" >&2
  exit 1
fi

if ! find "$OUTDIR/amp" -type f -size +0 | grep -q .; then
  echo "ERROR: missing non-empty AMP outputs" >&2
  exit 1
fi

if ! find "$OUTDIR/bgc" -type f -size +0 | grep -q .; then
  echo "ERROR: missing non-empty BGC outputs" >&2
  exit 1
fi

OUTPUT_COUNT="$(find "$OUTDIR" -type f -size +0 | wc -l)"
if [ "$OUTPUT_COUNT" -lt 50 ]; then
  echo "ERROR: too few non-empty outputs for full funcscan baseline: $OUTPUT_COUNT" >&2
  exit 1
fi

echo "nf-core/funcscan single-node native Nextflow baseline completed with $OUTPUT_COUNT non-empty output files"
