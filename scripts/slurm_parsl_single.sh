#!/usr/bin/env bash
#SBATCH --job-name=parsl-single
#SBATCH --exclusive
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=16
#SBATCH --mem=45G
#SBATCH --time=04:00:00
#SBATCH --output=runs/parsl/slurm-%j-single.out
#SBATCH --error=runs/parsl/slurm-%j-single.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
cd "$ROOT"

mkdir -p runs/parsl

RUN_ROOT="$ROOT/runs/parsl/single-${SLURM_JOB_ID}"
mkdir -p "$RUN_ROOT"

export PATH="$ROOT/tools/parsl-venv/bin:$PATH"

"$ROOT/tools/parsl-venv/bin/python" "$ROOT/scripts/run_parsl_workflow.py" \
  --run-dir "$RUN_ROOT" \
  --tasks 128 \
  --size-mb 4 \
  --workers "${SLURM_CPUS_PER_TASK:-16}" \
  2>&1 | tee "$RUN_ROOT/parsl-workflow.log"

test -s "$RUN_ROOT/manifest.json"
test -s "$RUN_ROOT/outputs/aggregate.json"
chunk_count=$(find "$RUN_ROOT/outputs" -name 'chunk-*.bin' -type f -size +0c | wc -l)
if (( chunk_count != 128 )); then
  echo "Expected 128 Parsl output chunks, found ${chunk_count}" >&2
  exit 1
fi

"$ROOT/tools/parsl-venv/bin/python" - <<PY
import json
from pathlib import Path
manifest = json.loads(Path("$RUN_ROOT/manifest.json").read_text())
assert manifest["aggregate"]["chunks"] == 128
assert manifest["aggregate"]["total_bytes"] == 128 * 4 * 1024 * 1024
print("Validated Parsl manifest:", manifest["aggregate"]["total_bytes"], "bytes")
PY

echo "Parsl native single-node HTEX workflow completed."
