#!/usr/bin/env bash
#SBATCH --job-name=ptychonn-single
#SBATCH --exclusive
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=16
#SBATCH --mem=45G
#SBATCH --time=08:00:00
#SBATCH --output=runs/PtychoNN/slurm-%j-single.out
#SBATCH --error=runs/PtychoNN/slurm-%j-single.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
cd "$ROOT"

mkdir -p runs/PtychoNN
RUN_ROOT="$ROOT/runs/PtychoNN/single-${SLURM_JOB_ID}"
mkdir -p "$RUN_ROOT"

export OMP_NUM_THREADS="${SLURM_CPUS_PER_TASK:-16}"
export MKL_NUM_THREADS="${SLURM_CPUS_PER_TASK:-16}"

"$ROOT/tools/ptychonn-venv/bin/python" "$ROOT/scripts/run_ptychonn_pytorch.py" \
  --diff-npz "$ROOT/data/PtychoNN/20191008_39_diff.npz" \
  --labels-npy "$ROOT/data/PtychoNN/20191008_39_amp_pha_10nm_full.npy" \
  --x-test-npy "$ROOT/data/PtychoNN/X_test.npy" \
  --run-dir "$RUN_ROOT" \
  --epochs 1 \
  --train-lines 100 \
  --valid-count 805 \
  --test-limit 3600 \
  --batch-size 64 \
  --num-workers 4 \
  --threads "${SLURM_CPUS_PER_TASK:-16}" \
  2>&1 | tee "$RUN_ROOT/ptychonn-pytorch.log"

test -s "$RUN_ROOT/manifest.json"
test -s "$RUN_ROOT/outputs/best_model_state.pt"
test -s "$RUN_ROOT/outputs/test_predictions.npz"

"$ROOT/tools/ptychonn-venv/bin/python" - <<PY
import json
from pathlib import Path
manifest = json.loads(Path("$RUN_ROOT/manifest.json").read_text())
assert manifest["workflow"] == "PtychoNN"
assert manifest["runner"] == "PyTorch"
assert manifest["epochs"] == 1
assert manifest["data"]["train_lines"] == 100
assert manifest["data"]["train_samples"] == 16100
assert manifest["inference"]["test_samples"] == 3600
assert manifest["inference"]["prediction_bytes"] > 1024 * 1024
print("Validated PtychoNN manifest:", manifest["inference"]["prediction_bytes"], "prediction bytes")
PY

echo "PtychoNN native PyTorch single-node baseline completed."
