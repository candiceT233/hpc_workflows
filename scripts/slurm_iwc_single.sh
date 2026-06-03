#!/usr/bin/env bash
#SBATCH --job-name=iwc-single
#SBATCH --exclusive
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=40
#SBATCH --mem=45G
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/iwc/slurm-%j.out
#SBATCH --error=runs/iwc/slurm-%j.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
cd "$ROOT"

mkdir -p runs/iwc

RUN_ROOT="$ROOT/runs/iwc/single-${SLURM_JOB_ID}"
PLANEMO_WORK="$RUN_ROOT/planemo"
OUTPUT_DIR="$RUN_ROOT/outputs"
mkdir -p "$PLANEMO_WORK" "$OUTPUT_DIR"

source "$ROOT/tools/galaxy-venv/bin/activate"

export TMPDIR="$RUN_ROOT/tmp"
export PLANEMO_GLOBAL_CONFIG_PATH="$RUN_ROOT/planemo.yml"
export GALAXY_CONFIG_TOOL_DEPENDENCY_DIR="$RUN_ROOT/tool-deps"
export GALAXY_CONFIG_FILE_PATH="$RUN_ROOT/galaxy-files"
mkdir -p "$TMPDIR" "$GALAXY_CONFIG_TOOL_DEPENDENCY_DIR" "$GALAXY_CONFIG_FILE_PATH"

IWC_TOOL_ENV="$ROOT/tools/conda-envs/iwc-galaxy-tools"
if [ ! -x "$IWC_TOOL_ENV/bin/fastp" ] || [ ! -x "$IWC_TOOL_ENV/bin/multiqc" ]; then
  rm -rf "$IWC_TOOL_ENV"
  "$ROOT/tools/miniforge/bin/mamba" create -y -p "$IWC_TOOL_ENV" \
    -c conda-forge -c bioconda \
    fastp multiqc
fi
export PATH="$IWC_TOOL_ENV/bin:$PATH"
fastp --version
multiqc --version

cat > "$PLANEMO_GLOBAL_CONFIG_PATH" <<EOF
conda_prefix: "$ROOT/tools/planemo-conda/iwc"
conda_exec: "$ROOT/tools/miniforge/bin/conda"
EOF

WORKFLOW="$ROOT/repos/iwc/workflows/read-preprocessing/short-read-qc-trimming/short-read-quality-control-and-trimming.ga"
JOB="$ROOT/data/iwc/short_read_qc_full_job.yml"

planemo --directory "$PLANEMO_WORK" run \
  --install_galaxy \
  --galaxy_branch release_25.1 \
  --galaxy_python_version 3.11 \
  --job_workers 40 \
  --conda_dependency_resolution \
  --conda_auto_install \
  --conda_prefix "$ROOT/tools/planemo-conda/iwc" \
  --conda_exec "$ROOT/tools/miniforge/bin/conda" \
  --shed_install \
  --download_outputs \
  --output_directory "$OUTPUT_DIR" \
  --output_json "$RUN_ROOT/planemo-output.json" \
  "$WORKFLOW" "$JOB" \
  2>&1 | tee "$RUN_ROOT/planemo-run.log"

test -s "$RUN_ROOT/planemo-output.json"
test -s "$RUN_ROOT/planemo-run.log"

non_empty_outputs=$(find "$OUTPUT_DIR" -type f -size +0c | wc -l)
if (( non_empty_outputs < 3 )); then
  echo "Expected at least 3 non-empty downloaded Galaxy outputs, found ${non_empty_outputs}" >&2
  exit 1
fi

grep -RIl "Filtered Reads\\|fastp\\|MultiQC" "$OUTPUT_DIR" >/dev/null
grep -Eq "Workflow.*completed|invocation.*ok|Final state.*ok|Downloaded" "$RUN_ROOT/planemo-run.log"

echo "IWC Planemo/Galaxy single-node baseline completed with ${non_empty_outputs} non-empty downloaded outputs."
