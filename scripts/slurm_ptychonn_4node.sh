#!/usr/bin/env bash
#SBATCH --job-name=ptychonn-4node
#SBATCH --exclusive
#SBATCH --nodes=4
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=16
#SBATCH --mem=45G
#SBATCH --time=08:00:00
#SBATCH --output=runs/PtychoNN/slurm-%j-4node.out
#SBATCH --error=runs/PtychoNN/slurm-%j-4node.err

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
RUN_ROOT="$ROOT/runs/PtychoNN/4node-${SLURM_JOB_ID}"
mkdir -p "$RUN_ROOT"

scontrol show hostnames "$SLURM_JOB_NODELIST" > "$RUN_ROOT/hosts.txt"
NODE_COUNT="$(wc -l < "$RUN_ROOT/hosts.txt")"
if [ "$NODE_COUNT" -lt 4 ]; then
  echo "ERROR: expected at least 4 Slurm nodes, got $NODE_COUNT" >&2
  exit 1
fi

export OMP_NUM_THREADS="${SLURM_CPUS_PER_TASK:-16}"
export MKL_NUM_THREADS="${SLURM_CPUS_PER_TASK:-16}"
export PTYCHONN_ROOT="$ROOT"
export PTYCHONN_RUN_ROOT="$RUN_ROOT"

srun --nodes=4 --ntasks=4 --ntasks-per-node=1 --cpus-per-task="${SLURM_CPUS_PER_TASK:-16}" --exclusive \
  bash -lc '
    set -euo pipefail
    replica="${SLURM_PROCID}"
    outdir="${PTYCHONN_RUN_ROOT}/replica-${replica}"
    mkdir -p "$outdir"
    "${PTYCHONN_ROOT}/tools/ptychonn-venv/bin/python" "${PTYCHONN_ROOT}/scripts/run_ptychonn_pytorch.py" \
      --diff-npz "${PTYCHONN_ROOT}/data/PtychoNN/20191008_39_diff.npz" \
      --labels-npy "${PTYCHONN_ROOT}/data/PtychoNN/20191008_39_amp_pha_10nm_full.npy" \
      --x-test-npy "${PTYCHONN_ROOT}/data/PtychoNN/X_test.npy" \
      --run-dir "$outdir" \
      --epochs 1 \
      --train-lines 100 \
      --valid-count 805 \
      --test-limit 3600 \
      --batch-size 64 \
      --num-workers 4 \
      --threads "${SLURM_CPUS_PER_TASK:-16}" \
      2>&1 | tee "$outdir/ptychonn-pytorch.log"
  '

"$ROOT/tools/ptychonn-venv/bin/python" - <<PY
import json
from pathlib import Path
run_root = Path("$RUN_ROOT")
replicas = sorted(run_root.glob("replica-*"))
assert len(replicas) == 4, f"expected 4 replicas, found {len(replicas)}"
for replica in replicas:
    manifest_path = replica / "manifest.json"
    model_path = replica / "outputs" / "best_model_state.pt"
    pred_path = replica / "outputs" / "test_predictions.npz"
    assert manifest_path.is_file() and manifest_path.stat().st_size > 0
    assert model_path.is_file() and model_path.stat().st_size > 1024 * 1024
    assert pred_path.is_file() and pred_path.stat().st_size > 1024 * 1024
    manifest = json.loads(manifest_path.read_text())
    assert manifest["workflow"] == "PtychoNN"
    assert manifest["runner"] == "PyTorch"
    assert manifest["epochs"] == 1
    assert manifest["data"]["train_lines"] == 100
    assert manifest["data"]["train_samples"] == 16100
    assert manifest["inference"]["test_samples"] == 3600
    assert manifest["inference"]["prediction_bytes"] > 1024 * 1024
summary = {
    "workflow": "PtychoNN",
    "stage": "4node",
    "replicas": len(replicas),
    "nodes": Path("$RUN_ROOT/hosts.txt").read_text().splitlines(),
}
(run_root / "manifest-4node.json").write_text(json.dumps(summary, indent=2, sort_keys=True))
print("Validated PtychoNN 4-node replicas:", len(replicas))
PY

echo "PtychoNN native PyTorch 4-node baseline completed across $NODE_COUNT nodes."
