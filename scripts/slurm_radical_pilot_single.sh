#!/usr/bin/env bash
#SBATCH --job-name=radical-pilot-single
#SBATCH --exclusive
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=16
#SBATCH --mem=45G
#SBATCH --time=04:00:00
#SBATCH --output=runs/radical.pilot/slurm-%j-single.out
#SBATCH --error=runs/radical.pilot/slurm-%j-single.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
cd "$ROOT"

mkdir -p runs/radical.pilot
RUN_ROOT="$ROOT/runs/radical.pilot/single-${SLURM_JOB_ID}"
mkdir -p "$RUN_ROOT"

export PATH="$ROOT/tools/radical-pilot-venv/bin:$PATH"
export PYTHONPATH="$ROOT/repos/radical.pilot/src:${PYTHONPATH:-}"
export RADICAL_BASE="$RUN_ROOT/radical-base"
export RADICAL_VERBOSE=INFO

"$ROOT/tools/radical-pilot-venv/bin/python" "$ROOT/scripts/run_radical_pilot_workflow.py" \
  --run-dir "$RUN_ROOT" \
  --tasks 128 \
  --size-mb 4 \
  --cores "${SLURM_CPUS_PER_TASK:-16}" \
  --runtime 60 \
  2>&1 | tee "$RUN_ROOT/radical-pilot-workflow.log"

test -s "$RUN_ROOT/manifest.json"
chunk_count=$(find "$RUN_ROOT/outputs" -name 'task-*.bin' -type f -size +0c | wc -l)
if (( chunk_count != 128 )); then
  echo "Expected 128 RADICAL-Pilot output chunks, found ${chunk_count}" >&2
  exit 1
fi

"$ROOT/tools/radical-pilot-venv/bin/python" - <<PY
import json
from pathlib import Path
manifest = json.loads(Path("$RUN_ROOT/manifest.json").read_text())
assert manifest["workflow"] == "radical.pilot"
assert manifest["runner"] == "RADICAL-Pilot"
assert manifest["tasks"] == 128
assert manifest["total_bytes"] == 128 * 4 * 1024 * 1024
assert all(state == "DONE" for state in manifest["task_states"].values())
print("Validated RADICAL-Pilot manifest:", manifest["total_bytes"], "bytes")
PY

echo "RADICAL-Pilot native single-node workflow completed."
