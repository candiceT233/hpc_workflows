#!/usr/bin/env bash
#SBATCH --job-name=circdna-4node
#SBATCH --exclusive
#SBATCH --partition=compute
#SBATCH --nodes=4
#SBATCH --ntasks=4
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/nf-core_circdna/slurm-%j-4node.out
#SBATCH --error=runs/nf-core_circdna/slurm-%j-4node.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

REPO="$ROOT/repos/nf-core_circdna"
RUN_ROOT="$ROOT/runs/nf-core_circdna"
RUN_DIR="$RUN_ROOT/4node-${SLURM_JOB_ID:-manual}"
INPUT="$ROOT/data/nf-core_circdna/full/samplesheet.local.csv"
FASTA="$ROOT/data/nf-core_circdna/full/reference/genome.fa"
MOSEK_DIR="$ROOT/data/nf-core_circdna/full/mosek"
NF_ENV="$ROOT/tools/conda-envs/nextflow"
MINIFORGE="$ROOT/tools/miniforge"
source "$ROOT/scripts/circdna_full_inputs.sh"

mkdir -p "$RUN_ROOT" "$RUN_DIR" "$ROOT/tools/nextflow-home" "$ROOT/tools/nextflow-conda-cache/nf-core_circdna"
cd "$ROOT"
prepare_circdna_full_inputs "$ROOT"

for required in "$NF_ENV/bin/nextflow" "$CIRCDNA_INPUT" "$MOSEK_DIR/mosek.lic"; do
  if [ ! -s "$required" ] && [ ! -x "$required" ]; then
    echo "ERROR: missing required nf-core/circdna artifact: $required" >&2
    exit 1
  fi
done

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

run_replica() {
  local replica="$1"
  local rep_dir="$RUN_DIR/replica-${replica}"
  local outdir="$rep_dir/results"
  local workdir="$rep_dir/work"
  local tmp_root="/tmp/${USER:-jcernudagarcia}-circdna-${SLURM_JOB_ID:-manual}-${replica}"
  local pkgs_root="$rep_dir/conda-pkgs"
  local condarc="$rep_dir/condarc"
  local override="$rep_dir/circdna_ares_override.config"

  mkdir -p "$outdir" "$workdir" "$tmp_root" "$pkgs_root"
  export TMPDIR="$tmp_root"
  export NXF_TEMP="$tmp_root"
  export CONDA_PKGS_DIRS="$pkgs_root"
  export _JAVA_OPTIONS="${_JAVA_OPTIONS:-} -Djava.io.tmpdir=$tmp_root"
  trap 'rm -rf "$tmp_root"' EXIT
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
  cacheDir = "$ROOT/tools/nextflow-conda-cache/nf-core_circdna"
  createTimeout = '90 min'
}
EOF

  export JAVA_HOME="$NF_ENV"
  export JAVA_CMD="$NF_ENV/bin/java"
  export NXF_VER=26.04.1
  export NXF_HOME="$ROOT/tools/nextflow-home"
export NXF_OFFLINE=true
  export NXF_OPTS="-Xms1g -Xmx8g"
  export NXF_SYNTAX_PARSER=v1
  export PATH="$NF_ENV/bin:$MINIFORGE/bin:$MINIFORGE/condabin:$PATH"

  cd "$rep_dir"
  nextflow run "$REPO" \
    -profile conda \
    -c "$ROOT/config/nextflow_ares_local_conda.config" \
    -c "$override" \
    -work-dir "$workdir" \
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
    --outdir "$outdir"

  if ! find "$outdir/pipeline_info" -maxdepth 1 -type f -name 'execution_trace_*.txt' -size +0 | grep -q .; then
    echo "ERROR: replica $replica missing Nextflow execution trace" >&2
    exit 1
  fi
  if ! find "$outdir" -type f -name '*multiqc*html' -size +100000 | grep -q .; then
    echo "ERROR: replica $replica missing non-trivial MultiQC HTML output" >&2
    exit 1
  fi
  output_count="$(find "$outdir" -type f -size +0 | wc -l)"
  if [ "$output_count" -lt 20 ]; then
    echo "ERROR: replica $replica too few non-empty outputs: $output_count" >&2
    exit 1
  fi
  find "$outdir" -type f -size +0 | sort > "$rep_dir/nonempty-outputs.txt"
  echo "nf-core/circdna replica $replica native Nextflow baseline completed with $output_count non-empty output files"
}

if [ "${1:-}" = "worker" ]; then
  run_replica "$2"
  exit 0
fi

ensure_circexplorer2_env

for replica in 0 1 2 3; do
  srun --exclusive --nodes=1 --ntasks=1 --cpus-per-task="${SLURM_CPUS_PER_TASK:-40}" \
    "$0" worker "$replica" > "$RUN_DIR/replica-${replica}.out" 2> "$RUN_DIR/replica-${replica}.err" &
done
wait

for replica in 0 1 2 3; do
  test -s "$RUN_DIR/replica-${replica}/nonempty-outputs.txt"
done

echo "nf-core/circdna native 4-node Nextflow baseline completed across 4 nodes"
