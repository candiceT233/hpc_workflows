#!/bin/bash
#SBATCH --job-name=circdna-single
#SBATCH --exclusive
#SBATCH --partition=compute
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/nf-core_circdna/slurm-%j-single.out
#SBATCH --error=runs/nf-core_circdna/slurm-%j-single.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
REPO="$ROOT/repos/nf-core_circdna"
OUTDIR="$ROOT/runs/nf-core_circdna/single-${SLURM_JOB_ID:-manual}/results"
WORKDIR="$ROOT/runs/nf-core_circdna/single-${SLURM_JOB_ID:-manual}/work"
RUN_DIR="$(dirname "$OUTDIR")"
INPUT="$ROOT/data/nf-core_circdna/full/samplesheet.local.csv"
FASTA="$ROOT/data/nf-core_circdna/full/reference/genome.fa"
MOSEK_DIR="$ROOT/data/nf-core_circdna/full/mosek"
NF_ENV="$ROOT/tools/conda-envs/nextflow"
MINIFORGE="$ROOT/tools/miniforge"
source "$ROOT/scripts/circdna_full_inputs.sh"

mkdir -p "$ROOT/runs/nf-core_circdna" "$RUN_DIR" "$OUTDIR" "$WORKDIR" "$ROOT/tools/nextflow-home"

TMP_ROOT="/tmp/${USER:-jcernudagarcia}-circdna-${SLURM_JOB_ID:-manual}"
PKGS_ROOT="$RUN_DIR/conda-pkgs"
mkdir -p "$TMP_ROOT" "$PKGS_ROOT" "$RUN_DIR/nextflow-conda-cache"
export TMPDIR="$TMP_ROOT"
export NXF_TEMP="$TMP_ROOT"
export CONDA_PKGS_DIRS="$PKGS_ROOT"
export _JAVA_OPTIONS="${_JAVA_OPTIONS:-} -Djava.io.tmpdir=$TMP_ROOT"
trap 'rm -rf "$TMP_ROOT"' EXIT
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

cat > "$RUN_DIR/circdna_ares_override.config" <<EOF
conda {
  enabled = true
  useMamba = true
  cacheDir = "$ROOT/tools/nextflow-conda-cache/nf-core_circdna"
  createTimeout = '240 min'
}
EOF

ensure_circexplorer2_env() {
  local cache_dir="$ROOT/tools/nextflow-conda-cache/nf-core_circdna"
  local env_dir="$cache_dir/env-d53d926a553e30025e5d6e0bc9bf58e9"
  local lock_file="$cache_dir/.circexplorer2.lock"
  mkdir -p "$cache_dir"
  (
    flock 9
    if [ ! -x "$env_dir/bin/CIRCexplorer2" ]; then
      rm -rf "$env_dir"
      "$MINIFORGE/bin/mamba" create --yes --quiet \
        --prefix "$env_dir" \
        -c conda-forge -c bioconda \
        bioconda::circexplorer2=2.3.8
    fi
    "$env_dir/bin/CIRCexplorer2" --help >/dev/null 2>&1 || true
  ) 9>"$lock_file"
}

prepare_circdna_full_inputs "$ROOT"

for required in "$CIRCDNA_INPUT" "$MOSEK_DIR/mosek.lic"; do
  if [ ! -s "$required" ]; then
    echo "ERROR: missing required circdna input: $required" >&2
    exit 1
  fi
done

export JAVA_HOME="$NF_ENV"
export JAVA_CMD="$NF_ENV/bin/java"
export NXF_VER=26.04.1
export NXF_HOME="$ROOT/tools/nextflow-home"
export NXF_OFFLINE=true
export NXF_OPTS="-Xms1g -Xmx8g"
export NXF_SYNTAX_PARSER=v1
export PATH="$NF_ENV/bin:$MINIFORGE/bin:$MINIFORGE/condabin:$PATH"

ensure_circexplorer2_env

cd "$(dirname "$OUTDIR")"
nextflow run "$REPO" \
  -profile conda \
  -c "$ROOT/config/nextflow_ares_local_conda.config" \
  -c "$RUN_DIR/circdna_ares_override.config" \
  -work-dir "$WORKDIR" \
  --input "$CIRCDNA_INPUT" \
  --input_format FASTQ \
  --fasta "$CIRCDNA_FASTA" \
  --enable_conda true \
  --circle_identifier "circexplorer2,circle_finder,circle_map_realign,circle_map_repeats,unicycler" \
  --igenomes_ignore true \
  --skip_markduplicates true \
  --mosek_license_dir "$MOSEK_DIR" \
  --aa_data_repo "data_repo" \
  --reference_build "$CIRCDNA_REFERENCE_BUILD" \
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
  echo "ERROR: too few non-empty outputs for circdna baseline: $OUTPUT_COUNT" >&2
  exit 1
fi

echo "nf-core/circdna single-node native Nextflow baseline completed with $OUTPUT_COUNT non-empty output files"
