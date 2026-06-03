#!/usr/bin/env bash
#SBATCH --job-name=parsl-prof
#SBATCH --exclusive
#SBATCH --nodes=4
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=16
#SBATCH --mem=45G
#SBATCH --time=08:00:00
#SBATCH --output=runs/parsl/slurm-%j-4node-profiled.out
#SBATCH --error=runs/parsl/slurm-%j-4node-profiled.err

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

RUN_ROOT="$ROOT/runs/parsl/4node-profiled-${SLURM_JOB_ID:-manual}"
rm -rf "$RUN_ROOT"
mkdir -p "$RUN_ROOT"/{datalife,darshan,traces/datalife,traces/darshan,parsed}

scontrol show hostnames "$SLURM_JOB_NODELIST" > "$RUN_ROOT/hosts.txt"
NODE_COUNT="$(wc -l < "$RUN_ROOT/hosts.txt")"
if [ "$NODE_COUNT" -lt 4 ]; then
  echo "ERROR: expected at least 4 Slurm nodes, got $NODE_COUNT" >&2
  exit 1
fi

export PATH="$ROOT/tools/parsl-venv/bin:$PATH"
export PARSL_MULTIPROCESSING_CONTEXT=fork
export PARSL_CHUNK_HELPER="$ROOT/scripts/parsl_write_chunk_task.py"

run_profile_pass() {
  local mode="$1"
  local pass_dir="$RUN_ROOT/$mode"
  local trace_dir="$RUN_ROOT/traces/$mode"
  mkdir -p "$pass_dir" "$trace_dir"

  if [ "$mode" = "datalife" ]; then
    env PARSL_TASK_PROFILE_MODE=datalife \
      PARSL_TASK_DATALIFE_TRACE_DIR="$trace_dir" \
      PARSL_TASK_DATALIFE_FILE_PATTERNS="*.bin" \
      PARSL_TASK_DATALIFE_LIB="$DATALIFE_LIB" \
      "$ROOT/tools/parsl-venv/bin/python" "$ROOT/scripts/run_parsl_workflow.py" \
        --run-dir "$pass_dir" \
        --tasks 512 \
        --size-mb 4 \
        --workers "${SLURM_CPUS_PER_TASK:-16}" \
        --nodes "${SLURM_NNODES:-4}" \
        2>&1 | tee "$pass_dir/parsl-workflow.log"
  else
    env PARSL_TASK_PROFILE_MODE=darshan \
      PARSL_TASK_DARSHAN_TRACE_DIR="$trace_dir" \
      PARSL_TASK_DARSHAN_LIB="$DARSHAN_LIB" \
      "$ROOT/tools/parsl-venv/bin/python" "$ROOT/scripts/run_parsl_workflow.py" \
        --run-dir "$pass_dir" \
        --tasks 512 \
        --size-mb 4 \
        --workers "${SLURM_CPUS_PER_TASK:-16}" \
        --nodes "${SLURM_NNODES:-4}" \
        2>&1 | tee "$pass_dir/parsl-workflow.log"
  fi

  test -s "$pass_dir/manifest.json"
  test -s "$pass_dir/outputs/aggregate.json"
  local chunk_count
  chunk_count="$(find "$pass_dir/outputs" -name 'chunk-*.bin' -type f -size +0c | wc -l)"
  if [ "$chunk_count" -ne 512 ]; then
    echo "Expected 512 Parsl ${mode} output chunks, found ${chunk_count}" >&2
    exit 3
  fi

  "$ROOT/tools/parsl-venv/bin/python" - <<PY
import json
from pathlib import Path
manifest = json.loads(Path("$pass_dir/manifest.json").read_text())
assert manifest["nodes"] >= 4
assert manifest["workers"] == 16
assert manifest["aggregate"]["chunks"] == 512
assert manifest["aggregate"]["total_bytes"] == 512 * 4 * 1024 * 1024
print("Validated Parsl $mode manifest:", manifest["aggregate"]["total_bytes"], "bytes")
PY

  find "$pass_dir/outputs" -type f -size +0c -printf '%P\t%s\n' | sort > "$RUN_ROOT/${mode}-outputs.tsv"
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

echo "Parsl native 4-node profiled HTEX workflow completed across $NODE_COUNT nodes."
