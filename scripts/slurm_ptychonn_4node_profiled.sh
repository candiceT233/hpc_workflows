#!/usr/bin/env bash
#SBATCH --job-name=ptychonn-prof
#SBATCH --exclusive
#SBATCH --nodes=4
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=16
#SBATCH --mem=45G
#SBATCH --time=16:00:00
#SBATCH --output=runs/PtychoNN/slurm-%j-4node-profiled.out
#SBATCH --error=runs/PtychoNN/slurm-%j-4node-profiled.err

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

DATALIFE_LIB="$ROOT/tools/widget-v1/profiler/datalife/build/flow-monitor/src/libmonitor.so"
DARSHAN_RUNTIME="${DARSHAN_RUNTIME:-$(spack location -i darshan-runtime@3.4.6)}"
DARSHAN_UTIL="${DARSHAN_UTIL:-$(spack location -i darshan-util@3.4.6)}"
DARSHAN_LIB="$DARSHAN_RUNTIME/lib/libdarshan.so.0.0.0"
DARSHAN_PARSER="$DARSHAN_UTIL/bin/darshan-parser"

for required in "$DATALIFE_LIB" "$DARSHAN_LIB" "$DARSHAN_PARSER"; do
  if [ ! -s "$required" ]; then
    echo "Required profiling artifact missing: $required" >&2
    exit 2
  fi
done

RUN_ROOT="$ROOT/runs/PtychoNN/4node-profiled-${SLURM_JOB_ID:-manual}"
rm -rf "$RUN_ROOT"
mkdir -p "$RUN_ROOT"/{datalife,darshan,traces/datalife,traces/darshan,parsed}

scontrol show hostnames "$SLURM_JOB_NODELIST" > "$RUN_ROOT/hosts.txt"
NODE_COUNT="$(wc -l < "$RUN_ROOT/hosts.txt")"
if [ "$NODE_COUNT" -lt 4 ]; then
  echo "ERROR: expected at least 4 Slurm nodes, got $NODE_COUNT" >&2
  exit 1
fi

export OMP_NUM_THREADS="${SLURM_CPUS_PER_TASK:-16}"
export MKL_NUM_THREADS="${SLURM_CPUS_PER_TASK:-16}"

cat > "$RUN_ROOT/run_profile_replica.sh" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
replica="${SLURM_PROCID}"
outdir="${PTYCHONN_PASS_ROOT}/replica-${replica}"
trace_dir="${PTYCHONN_TRACE_ROOT}/replica-${replica}"
mkdir -p "$outdir" "$trace_dir"

if [ "$PTYCHONN_PROFILE_MODE" = "datalife" ]; then
  data_dir="$outdir/staged-inputs"
  mkdir -p "$data_dir"
  env DATALIFE_OUTPUT_PATH="$trace_dir" \
    DATALIFE_FILE_PATTERNS="*.npy,*.npz,*.pt,*.txt" \
    LD_PRELOAD="$DATALIFE_LIB" \
    "$PTYCHONN_ROOT/tools/ptychonn-venv/bin/python" "$PTYCHONN_ROOT/scripts/ptychonn_profile_io.py" copy \
      --src "$PTYCHONN_ROOT/data/PtychoNN/20191008_39_diff.npz" \
      --dst "$data_dir/20191008_39_diff.npz"
  env DATALIFE_OUTPUT_PATH="$trace_dir" \
    DATALIFE_FILE_PATTERNS="*.npy,*.npz,*.pt,*.txt" \
    LD_PRELOAD="$DATALIFE_LIB" \
    "$PTYCHONN_ROOT/tools/ptychonn-venv/bin/python" "$PTYCHONN_ROOT/scripts/ptychonn_profile_io.py" copy \
      --src "$PTYCHONN_ROOT/data/PtychoNN/20191008_39_amp_pha_10nm_full.npy" \
      --dst "$data_dir/20191008_39_amp_pha_10nm_full.npy"
  env DATALIFE_OUTPUT_PATH="$trace_dir" \
    DATALIFE_FILE_PATTERNS="*.npy,*.npz,*.pt,*.txt" \
    LD_PRELOAD="$DATALIFE_LIB" \
    "$PTYCHONN_ROOT/tools/ptychonn-venv/bin/python" "$PTYCHONN_ROOT/scripts/ptychonn_profile_io.py" copy \
      --src "$PTYCHONN_ROOT/data/PtychoNN/X_test.npy" \
      --dst "$data_dir/X_test.npy"
  "$PTYCHONN_ROOT/tools/ptychonn-venv/bin/python" "$PTYCHONN_ROOT/scripts/run_ptychonn_pytorch.py" \
      --diff-npz "$data_dir/20191008_39_diff.npz" \
      --labels-npy "$data_dir/20191008_39_amp_pha_10nm_full.npy" \
      --x-test-npy "$data_dir/X_test.npy" \
      --run-dir "$outdir" \
      --epochs 1 \
      --train-lines 100 \
      --valid-count 805 \
      --test-limit 3600 \
      --batch-size 64 \
      --num-workers 4 \
      --threads "${SLURM_CPUS_PER_TASK:-16}" \
      2>&1 | tee "$outdir/ptychonn-pytorch.log"
  env DATALIFE_OUTPUT_PATH="$trace_dir" \
    DATALIFE_FILE_PATTERNS="*.npy,*.npz,*.pt,*.txt" \
    LD_PRELOAD="$DATALIFE_LIB" \
    "$PTYCHONN_ROOT/tools/ptychonn-venv/bin/python" "$PTYCHONN_ROOT/scripts/ptychonn_profile_io.py" scan \
      --output "$outdir/profiled-output-digests.json" \
      "$outdir/outputs/best_model_state.pt" \
      "$outdir/outputs/test_predictions.npz"
else
  data_dir="$outdir/staged-inputs"
  mkdir -p "$data_dir"
  env DARSHAN_ENABLE_NONMPI=1 \
    DARSHAN_LOG_DIR_PATH="$trace_dir" \
    LD_PRELOAD="$DARSHAN_LIB" \
    "$PTYCHONN_ROOT/tools/ptychonn-venv/bin/python" "$PTYCHONN_ROOT/scripts/ptychonn_profile_io.py" copy \
      --src "$PTYCHONN_ROOT/data/PtychoNN/20191008_39_diff.npz" \
      --dst "$data_dir/20191008_39_diff.npz"
  env DARSHAN_ENABLE_NONMPI=1 \
    DARSHAN_LOG_DIR_PATH="$trace_dir" \
    LD_PRELOAD="$DARSHAN_LIB" \
    "$PTYCHONN_ROOT/tools/ptychonn-venv/bin/python" "$PTYCHONN_ROOT/scripts/ptychonn_profile_io.py" copy \
      --src "$PTYCHONN_ROOT/data/PtychoNN/20191008_39_amp_pha_10nm_full.npy" \
      --dst "$data_dir/20191008_39_amp_pha_10nm_full.npy"
  env DARSHAN_ENABLE_NONMPI=1 \
    DARSHAN_LOG_DIR_PATH="$trace_dir" \
    LD_PRELOAD="$DARSHAN_LIB" \
    "$PTYCHONN_ROOT/tools/ptychonn-venv/bin/python" "$PTYCHONN_ROOT/scripts/ptychonn_profile_io.py" copy \
      --src "$PTYCHONN_ROOT/data/PtychoNN/X_test.npy" \
      --dst "$data_dir/X_test.npy"
  "$PTYCHONN_ROOT/tools/ptychonn-venv/bin/python" "$PTYCHONN_ROOT/scripts/run_ptychonn_pytorch.py" \
      --diff-npz "$data_dir/20191008_39_diff.npz" \
      --labels-npy "$data_dir/20191008_39_amp_pha_10nm_full.npy" \
      --x-test-npy "$data_dir/X_test.npy" \
      --run-dir "$outdir" \
      --epochs 1 \
      --train-lines 100 \
      --valid-count 805 \
      --test-limit 3600 \
      --batch-size 64 \
      --num-workers 4 \
      --threads "${SLURM_CPUS_PER_TASK:-16}" \
      2>&1 | tee "$outdir/ptychonn-pytorch.log"
  env DARSHAN_ENABLE_NONMPI=1 \
    DARSHAN_LOG_DIR_PATH="$trace_dir" \
    LD_PRELOAD="$DARSHAN_LIB" \
    "$PTYCHONN_ROOT/tools/ptychonn-venv/bin/python" "$PTYCHONN_ROOT/scripts/ptychonn_profile_io.py" scan \
      --output "$outdir/profiled-output-digests.json" \
      "$outdir/outputs/best_model_state.pt" \
      "$outdir/outputs/test_predictions.npz"
fi
EOS
chmod +x "$RUN_ROOT/run_profile_replica.sh"

run_profile_pass() {
  local mode="$1"
  export PTYCHONN_PROFILE_MODE="$mode"
  export PTYCHONN_ROOT="$ROOT"
  export PTYCHONN_PASS_ROOT="$RUN_ROOT/$mode"
  export PTYCHONN_TRACE_ROOT="$RUN_ROOT/traces/$mode"
  mkdir -p "$PTYCHONN_PASS_ROOT" "$PTYCHONN_TRACE_ROOT"

  srun -u --nodes=4 --ntasks=4 --ntasks-per-node=1 --cpus-per-task="${SLURM_CPUS_PER_TASK:-16}" --exclusive \
    --export=ALL,PTYCHONN_PROFILE_MODE="$mode",PTYCHONN_ROOT="$ROOT",PTYCHONN_PASS_ROOT="$PTYCHONN_PASS_ROOT",PTYCHONN_TRACE_ROOT="$PTYCHONN_TRACE_ROOT",DATALIFE_LIB="$DATALIFE_LIB",DARSHAN_LIB="$DARSHAN_LIB" \
    "$RUN_ROOT/run_profile_replica.sh"

  "$ROOT/tools/ptychonn-venv/bin/python" - <<PY
import json
from pathlib import Path
run_root = Path("$PTYCHONN_PASS_ROOT")
replicas = sorted(run_root.glob("replica-*"))
assert len(replicas) == 4, f"expected 4 replicas, found {len(replicas)}"
for replica in replicas:
    manifest_path = replica / "manifest.json"
    model_path = replica / "outputs" / "best_model_state.pt"
    pred_path = replica / "outputs" / "test_predictions.npz"
    profile_digest_path = replica / "profiled-output-digests.json"
    assert manifest_path.is_file() and manifest_path.stat().st_size > 0
    assert model_path.is_file() and model_path.stat().st_size > 1024 * 1024
    assert pred_path.is_file() and pred_path.stat().st_size > 1024 * 1024
    assert profile_digest_path.is_file() and profile_digest_path.stat().st_size > 0
    manifest = json.loads(manifest_path.read_text())
    assert manifest["workflow"] == "PtychoNN"
    assert manifest["runner"] == "PyTorch"
    assert manifest["epochs"] == 1
    assert manifest["data"]["train_lines"] == 100
    assert manifest["data"]["train_samples"] == 16100
    assert manifest["inference"]["test_samples"] == 3600
    assert manifest["inference"]["prediction_bytes"] > 1024 * 1024
print("Validated PtychoNN $mode replicas:", len(replicas))
PY

  find "$PTYCHONN_PASS_ROOT" -type f -size +0c -printf '%P\t%s\n' | sort > "$RUN_ROOT/${mode}-outputs.tsv"
}

run_profile_pass datalife
run_profile_pass darshan

python3 - "$RUN_ROOT/traces/datalife" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
files = sorted(root.rglob("*.json"))
if not files:
    raise SystemExit("no DataLife JSON traces found")
for path in files:
    if path.stat().st_size == 0:
        raise SystemExit(f"empty DataLife JSON trace: {path}")
    with path.open() as handle:
        json.load(handle)
print(f"DataLife JSON traces parsed: {len(files)}")
PY

darshan_count=0
while IFS= read -r -d '' log_path; do
  rel="${log_path#$RUN_ROOT/traces/darshan/}"
  parsed="$RUN_ROOT/parsed/${rel}.txt"
  mkdir -p "$(dirname "$parsed")"
  "$DARSHAN_PARSER" "$log_path" > "$parsed"
  if [ ! -s "$parsed" ]; then
    echo "Parsed Darshan output is empty: $parsed" >&2
    exit 4
  fi
  darshan_count=$((darshan_count + 1))
done < <(find "$RUN_ROOT/traces/darshan" -name '*.darshan' -type f -size +0c -print0)

if [ "$darshan_count" -eq 0 ]; then
  echo "No non-empty Darshan logs found" >&2
  exit 5
fi

printf 'Darshan logs parsed: %s\n' "$darshan_count"
find "$RUN_ROOT/traces" -type f -printf '%P\t%s\n' | sort > "$RUN_ROOT/trace-summary.tsv"
cat "$RUN_ROOT/datalife-outputs.tsv"
cat "$RUN_ROOT/darshan-outputs.tsv"
cat "$RUN_ROOT/trace-summary.tsv"

echo "PtychoNN native PyTorch 4-node profiled workflow completed across $NODE_COUNT nodes."
