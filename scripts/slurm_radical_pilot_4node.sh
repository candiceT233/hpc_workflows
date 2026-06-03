#!/usr/bin/env bash
#SBATCH --job-name=radical-pilot-4node
#SBATCH --exclusive
#SBATCH --nodes=4
#SBATCH --ntasks=4
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=40
#SBATCH --mem=45G
#SBATCH --time=04:00:00
#SBATCH --output=runs/radical.pilot/slurm-%j-4node.out
#SBATCH --error=runs/radical.pilot/slurm-%j-4node.err

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
RUN_ROOT="$ROOT/runs/radical.pilot/4node-${SLURM_JOB_ID}"
mkdir -p "$RUN_ROOT"

scontrol show hostnames "$SLURM_JOB_NODELIST" > "$RUN_ROOT/hosts.txt"
NODE_COUNT="$(wc -l < "$RUN_ROOT/hosts.txt")"
if [ "$NODE_COUNT" -lt 4 ]; then
  echo "ERROR: expected at least 4 Slurm nodes, got $NODE_COUNT" >&2
  exit 1
fi

export PATH="$ROOT/tools/radical-pilot-venv/bin:$PATH"
export PYTHONPATH="$ROOT/repos/radical.pilot/src:${PYTHONPATH:-}"
export RADICAL_BASE="$RUN_ROOT/radical-base"
export RADICAL_VERBOSE=INFO
export RADICAL_CONFIG_USER_DIR="$ROOT/tools/radical-config"

"$ROOT/tools/radical-pilot-venv/bin/python" "$ROOT/scripts/run_radical_pilot_workflow.py" \
  --run-dir "$RUN_ROOT" \
  --tasks 256 \
  --size-mb 4 \
  --cores 160 \
  --runtime 120 \
  --resource ares.local \
  --queue compute \
  --access-schema local \
  2>&1 | tee "$RUN_ROOT/radical-pilot-workflow.log"

test -s "$RUN_ROOT/manifest.json"
chunk_count=$(find "$RUN_ROOT/outputs" -name 'task-*.bin' -type f -size +0c | wc -l)
if (( chunk_count != 256 )); then
  echo "Expected 256 RADICAL-Pilot output chunks, found ${chunk_count}" >&2
  exit 1
fi

"$ROOT/tools/radical-pilot-venv/bin/python" - <<PY
import json
from pathlib import Path
manifest = json.loads(Path("$RUN_ROOT/manifest.json").read_text())
assert manifest["workflow"] == "radical.pilot"
assert manifest["runner"] == "RADICAL-Pilot"
assert manifest["resource"] == "ares.local"
assert manifest["queue"] == "compute"
assert manifest["access_schema"] == "local"
assert manifest["tasks"] == 256
assert manifest["cores"] == 160
assert manifest["total_bytes"] == 256 * 4 * 1024 * 1024
assert all(state == "DONE" for state in manifest["task_states"].values())
print("Validated RADICAL-Pilot 4-node manifest:", manifest["total_bytes"], "bytes")
PY

echo "RADICAL-Pilot native 4-node workflow completed across $NODE_COUNT nodes."
