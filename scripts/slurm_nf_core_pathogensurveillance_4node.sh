#!/usr/bin/env bash
#SBATCH --job-name=pathosurv-4node
#SBATCH --exclusive
#SBATCH --partition=compute
#SBATCH --nodes=4
#SBATCH --ntasks=4
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/nf-core_pathogensurveillance/slurm-%j-4node.out
#SBATCH --error=runs/nf-core_pathogensurveillance/slurm-%j-4node.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

REPO="$ROOT/repos/nf-core_pathogensurveillance"
RUN_ROOT="$ROOT/runs/nf-core_pathogensurveillance"
RUN_DIR="$RUN_ROOT/4node-${SLURM_JOB_ID:-manual}"
DATA_DIR="$ROOT/data/nf-core_pathogensurveillance/full"
SAMPLESHEET="$DATA_DIR/samplesheets/bordetella.csv"
NF_ENV="$ROOT/tools/conda-envs/nextflow"
MINIFORGE="$ROOT/tools/miniforge"

mkdir -p "$RUN_ROOT" "$RUN_DIR" "$DATA_DIR/samplesheets" "$ROOT/tools/nextflow-home"
cd "$ROOT"

if [ ! -s "$SAMPLESHEET" ]; then
  echo "ERROR: missing local Bordetella pathogensurveillance samplesheet: $SAMPLESHEET" >&2
  exit 1
fi

for required in "$NF_ENV/bin/nextflow" "$SAMPLESHEET"; do
  if [ ! -s "$required" ] && [ ! -x "$required" ]; then
    echo "ERROR: missing required nf-core/pathogensurveillance artifact: $required" >&2
    exit 1
  fi
done

run_replica() {
  local replica="$1"
  local rep_dir="$RUN_DIR/replica-${replica}"
  local outdir="$rep_dir/results"
  local workdir="$rep_dir/work"
  local tmp_root="$workdir/tmp"
  local pkgs_root="$rep_dir/conda-pkgs"
  local cache_root="$rep_dir/nextflow-conda-cache"
  local condarc="$rep_dir/condarc"
  local override="$rep_dir/pathogensurveillance_ares_override.config"

  mkdir -p "$outdir" "$workdir" "$tmp_root" "$pkgs_root" "$cache_root"
  export TMPDIR="$tmp_root"
  export NXF_TEMP="$tmp_root"
  export CONDA_PKGS_DIRS="$pkgs_root"
  export _JAVA_OPTIONS="${_JAVA_OPTIONS:-} -Djava.io.tmpdir=$tmp_root"
  export MAMBA_YES=true
  export MAMBA_ALWAYS_YES=true
  export CONDA_ALWAYS_YES=true
  cat > "$condarc" <<'EOF'
always_yes: true
auto_activate_base: false
channel_priority: flexible
channels:
  - conda-forge
  - bioconda
  - defaults
EOF
  export CONDARC="$condarc"

  cat > "$override" <<EOF
conda {
  enabled = true
  useMamba = true
  cacheDir = "$cache_root"
  createTimeout = '90 min'
}
process.maxForks = 4
EOF

  export JAVA_HOME="$NF_ENV"
  export JAVA_CMD="$NF_ENV/bin/java"
  export NXF_HOME="$ROOT/tools/nextflow-home"
export NXF_OFFLINE=true
  export NXF_VER=26.04.1
  export NXF_OPTS="-Xms1g -Xmx8g"
  export NXF_SYNTAX_PARSER=v1
  export PATH="$NF_ENV/bin:$MINIFORGE/bin:$MINIFORGE/condabin:$PATH"

  cd "$rep_dir"
  nextflow run "$REPO" \
    -profile conda \
    -c "$ROOT/config/nextflow_ares_local_conda.config" \
    -c "$override" \
    -work-dir "$workdir" \
    --input "$SAMPLESHEET" \
    --data_dir "$rep_dir/downloads" \
    --max_parallel_downloads 1 \
    --outdir "$outdir"

  if ! find "$outdir/pipeline_info" -maxdepth 1 -type f -name '*trace*' -size +0 | grep -q .; then
    echo "ERROR: replica $replica missing Nextflow execution trace" >&2
    exit 1
  fi
  if ! find "$outdir" -type f -path '*/multiqc/*multiqc_report.html' -size +100000 | grep -q .; then
    echo "ERROR: replica $replica missing non-trivial MultiQC report" >&2
    exit 1
  fi
  if ! find "$outdir/reports" -type f -name '*_pathsurveil_report.html' -size +100000 | grep -q .; then
    echo "ERROR: replica $replica missing non-trivial pathogensurveillance HTML report" >&2
    exit 1
  fi
  if ! find "$outdir/assemblies" -type f \( -name '*.fasta' -o -name '*.fa' -o -name '*.fasta.gz' -o -name '*.fa.gz' \) -size +0 | grep -q .; then
    echo "ERROR: replica $replica missing non-empty assembly outputs" >&2
    exit 1
  fi
  if ! find "$outdir/quality_control" -type f \( -name '*.html' -o -name '*.json' -o -name 'report.tsv' \) -size +0 | grep -q .; then
    echo "ERROR: replica $replica missing non-empty quality-control outputs" >&2
    exit 1
  fi
  output_count="$(find "$outdir" -type f -size +0 | wc -l)"
  if [ "$output_count" -lt 50 ]; then
    echo "ERROR: replica $replica too few non-empty pathogensurveillance outputs: $output_count" >&2
    exit 1
  fi
  find "$outdir" -type f -size +0 | sort > "$rep_dir/nonempty-outputs.txt"
  echo "nf-core/pathogensurveillance replica $replica native Nextflow baseline completed with $output_count non-empty output files"
}

if [ "${1:-}" = "worker" ]; then
  run_replica "$2"
  exit 0
fi

for replica in 0 1 2 3; do
  srun --exclusive --nodes=1 --ntasks=1 --cpus-per-task="${SLURM_CPUS_PER_TASK:-40}" \
    "$0" worker "$replica" > "$RUN_DIR/replica-${replica}.out" 2> "$RUN_DIR/replica-${replica}.err" &
done
wait

for replica in 0 1 2 3; do
  test -s "$RUN_DIR/replica-${replica}/nonempty-outputs.txt"
done

echo "nf-core/pathogensurveillance native 4-node Nextflow baseline completed across 4 nodes"
