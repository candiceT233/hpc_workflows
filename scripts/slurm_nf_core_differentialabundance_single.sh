#!/bin/bash
#SBATCH --job-name=diffabund-single
#SBATCH --exclusive
#SBATCH --partition=compute
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/nf-core_differentialabundance/slurm-%j-single.out
#SBATCH --error=runs/nf-core_differentialabundance/slurm-%j-single.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

REPO="$ROOT/repos/nf-core_differentialabundance"
OUTDIR="$ROOT/runs/nf-core_differentialabundance/single-${SLURM_JOB_ID:-manual}/results"
WORKDIR="$ROOT/runs/nf-core_differentialabundance/single-${SLURM_JOB_ID:-manual}/work"
RUN_DIR="$(dirname "$OUTDIR")"
NF_ENV="$ROOT/tools/conda-envs/nextflow"
MINIFORGE="$ROOT/tools/miniforge"

mkdir -p "$ROOT/runs/nf-core_differentialabundance" "$OUTDIR" "$WORKDIR" "$ROOT/tools/nextflow-home" "$ROOT/tools/nextflow-conda-cache"

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

cat > "$RUN_DIR/differentialabundance_ares_override.config" <<EOF
conda {
  enabled = true
  useMamba = true
  cacheDir = "$RUN_DIR/nextflow-conda-cache"
  createTimeout = '90 min'
}
process.maxForks = 4
EOF

export JAVA_HOME="$NF_ENV"
export JAVA_CMD="$NF_ENV/bin/java"
export NXF_HOME="$ROOT/tools/nextflow-home"
export NXF_VER=26.04.1
export NXF_OFFLINE=true
export NXF_OPTS="-Xms1g -Xmx8g"
export NXF_SYNTAX_PARSER=v1
export PATH="$NF_ENV/bin:$MINIFORGE/bin:$MINIFORGE/condabin:$PATH"

precreate_conda_env() {
  local name="$1"
  local env_file="$2"
  local check_bin="$3"
  local prefix="$RUN_DIR/nextflow-conda-cache/$name"
  local attempt
  if [ -x "$prefix/bin/$check_bin" ]; then
    return 0
  fi
  rm -rf "$prefix"
  for attempt in $(seq 1 3); do
    if mamba env create --yes --prefix "$prefix" --file "$env_file"; then
      if [ -x "$prefix/bin/$check_bin" ]; then
        return 0
      fi
    fi
    rm -rf "$prefix"
    sleep 60
  done
  echo "ERROR: failed to pre-create $env_file at $prefix" >&2
  return 1
}

precreate_conda_env \
  "env-9ec16da988f50e79fdc98b40f6dd14fa" \
  "$REPO/modules/nf-core/atlasgeneannotationmanipulation/gtf2featureannotation/environment.yml" \
  "gtf2featureAnnotation.R"

precreate_conda_env \
  "env-807cf9583f94eaa2a8d45876800ed0a6" \
  "$REPO/modules/nf-core/shinyngs/validatefomcomponents/environment.yml" \
  "validate_fom_components.R"

download_input() {
  local url="$1"
  local dest="$2"
  if [ -s "$dest" ]; then
    if [[ "$dest" != *.gz ]] || gzip -t "$dest"; then
      return 0
    fi
    rm -f "$dest"
  fi
  curl -L --fail --retry 8 --retry-delay 15 --retry-all-errors \
    -o "$dest.tmp" "$url"
  if [[ "$dest" == *.gz ]]; then
    gzip -t "$dest.tmp"
  fi
  mv "$dest.tmp" "$dest"
}

source "$ROOT/scripts/differentialabundance_gse50790_inputs.sh"
prepare_differentialabundance_gse50790_inputs "$ROOT"

cd "$(dirname "$OUTDIR")"
nextflow run "$REPO" \
  -profile soft,conda \
  -c "$ROOT/config/nextflow_ares_local_conda.config" \
  -c "$RUN_DIR/differentialabundance_ares_override.config" \
  -work-dir "$WORKDIR" \
  --study_name "GSE50790" \
  --input "$DIFFABUND_INPUT" \
  --contrasts "$DIFFABUND_CONTRASTS" \
  --querygse "GSE50790" \
  --exploratory_main_variable "contrasts" \
  --outdir "$OUTDIR"

if ! find "$OUTDIR/pipeline_info" -maxdepth 1 -type f -name 'execution_trace*' -size +0 | grep -q .; then
  echo "ERROR: missing Nextflow execution trace in $OUTDIR/pipeline_info" >&2
  exit 1
fi

if ! find "$OUTDIR/report" -type f -name '*.html' -size +100000 | grep -q .; then
  echo "ERROR: missing non-trivial differentialabundance HTML report" >&2
  exit 1
fi

if ! find "$OUTDIR/tables" -type f \( -name '*.tsv' -o -name '*.csv' \) -size +0 | grep -q .; then
  echo "ERROR: missing non-empty output tables" >&2
  exit 1
fi

OUTPUT_COUNT="$(find "$OUTDIR" -type f -size +0 | wc -l)"
if [ "$OUTPUT_COUNT" -lt 20 ]; then
  echo "ERROR: too few non-empty outputs for full differentialabundance baseline: $OUTPUT_COUNT" >&2
  exit 1
fi

echo "nf-core/differentialabundance single-node native Nextflow baseline completed with $OUTPUT_COUNT non-empty output files"
