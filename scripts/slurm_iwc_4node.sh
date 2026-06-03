#!/usr/bin/env bash
#SBATCH --job-name=iwc-4node
#SBATCH --exclusive
#SBATCH --nodes=4
#SBATCH --ntasks=4
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=40
#SBATCH --mem=45G
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/iwc/slurm-%j-4node.out
#SBATCH --error=runs/iwc/slurm-%j-4node.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

RUN_ROOT="${RUN_ROOT:-$ROOT/runs/iwc}"
RUN_DIR="$RUN_ROOT/4node-${SLURM_JOB_ID:-manual}"
WORKFLOW="$ROOT/repos/iwc/workflows/read-preprocessing/short-read-qc-trimming/short-read-quality-control-and-trimming.ga"
JOB="$ROOT/data/iwc/short_read_qc_full_job.yml"
IWC_TOOL_ENV="$ROOT/tools/conda-envs/iwc-galaxy-tools"

mkdir -p "$RUN_ROOT" "$RUN_DIR"

for required in "$WORKFLOW" "$JOB" "$ROOT/tools/galaxy-venv/bin/planemo"; do
  if [ ! -s "$required" ] && [ ! -x "$required" ]; then
    echo "ERROR: missing required IWC artifact: $required" >&2
    exit 1
  fi
done

if [ ! -x "$IWC_TOOL_ENV/bin/fastp" ] || [ ! -x "$IWC_TOOL_ENV/bin/multiqc" ]; then
  "$ROOT/tools/miniforge/bin/mamba" create -y -p "$IWC_TOOL_ENV" \
    -c conda-forge -c bioconda fastp multiqc
fi

run_replica() {
  local replica="$1"
  local rep_dir="$RUN_DIR/replica-${replica}"
  local planemo_work="$rep_dir/planemo"
  local output_dir="$rep_dir/outputs"

  mkdir -p "$planemo_work" "$output_dir" "$rep_dir/tmp" "$rep_dir/tool-deps" "$rep_dir/galaxy-files"
  source "$ROOT/tools/galaxy-venv/bin/activate"

  export TMPDIR="$rep_dir/tmp"
  export PLANEMO_GLOBAL_CONFIG_PATH="$rep_dir/planemo.yml"
  export GALAXY_CONFIG_TOOL_DEPENDENCY_DIR="$rep_dir/tool-deps"
  export GALAXY_CONFIG_FILE_PATH="$rep_dir/galaxy-files"
  export PATH="$IWC_TOOL_ENV/bin:$PATH"

  cat > "$PLANEMO_GLOBAL_CONFIG_PATH" <<EOF
conda_prefix: "$ROOT/tools/planemo-conda/iwc"
conda_exec: "$ROOT/tools/miniforge/bin/conda"
EOF

  cd "$rep_dir"
  planemo --directory "$planemo_work" run \
    --install_galaxy \
    --galaxy_branch release_25.1 \
    --galaxy_python_version 3.11 \
    --job_workers "${SLURM_CPUS_PER_TASK:-40}" \
    --conda_dependency_resolution \
    --conda_auto_install \
    --conda_prefix "$ROOT/tools/planemo-conda/iwc" \
    --conda_exec "$ROOT/tools/miniforge/bin/conda" \
    --shed_install \
    --download_outputs \
    --output_directory "$output_dir" \
    --output_json "$rep_dir/planemo-output.json" \
    "$WORKFLOW" "$JOB" \
    2>&1 | tee "$rep_dir/planemo-run.log"

  test -s "$rep_dir/planemo-output.json"
  test -s "$rep_dir/planemo-run.log"
  non_empty_outputs="$(find "$output_dir" -type f -size +0c | wc -l)"
  if [ "$non_empty_outputs" -lt 3 ]; then
    echo "ERROR: replica $replica expected at least 3 non-empty Galaxy outputs, found $non_empty_outputs" >&2
    exit 1
  fi
  grep -RIl "Filtered Reads\\|fastp\\|MultiQC" "$output_dir" >/dev/null
  grep -Eq "Workflow.*completed|invocation.*ok|Final state.*ok|Downloaded" "$rep_dir/planemo-run.log"
  find "$output_dir" -type f -size +0c | sort > "$rep_dir/nonempty-outputs.txt"
  echo "IWC Planemo/Galaxy replica $replica completed with $non_empty_outputs non-empty downloaded outputs."
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

echo "IWC native Planemo/Galaxy 4-node baseline completed across 4 nodes."
