#!/usr/bin/env bash
#SBATCH --job-name=radical-pilot-prof
#SBATCH --exclusive
#SBATCH --nodes=4
#SBATCH --ntasks=4
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=40
#SBATCH --mem=45G
#SBATCH --time=08:00:00
#SBATCH --output=runs/radical.pilot/slurm-%j-4node-profiled.out
#SBATCH --error=runs/radical.pilot/slurm-%j-4node-profiled.err

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

RUN_ROOT="$ROOT/runs/radical.pilot/4node-profiled-${SLURM_JOB_ID:-manual}"
rm -rf "$RUN_ROOT"
mkdir -p "$RUN_ROOT"/{datalife,darshan,traces/datalife,traces/darshan,parsed}

scontrol show hostnames "$SLURM_JOB_NODELIST" > "$RUN_ROOT/hosts.txt"
NODE_COUNT="$(wc -l < "$RUN_ROOT/hosts.txt")"
if [ "$NODE_COUNT" -lt 4 ]; then
  echo "ERROR: expected at least 4 Slurm nodes, got $NODE_COUNT" >&2
  exit 1
fi

export PATH="$ROOT/tools/radical-pilot-venv/bin:$PATH"
export PYTHONPATH="$ROOT/repos/radical.pilot/src:${PYTHONPATH:-}"
export RADICAL_VERBOSE=INFO
export RADICAL_CONFIG_USER_DIR="$ROOT/tools/radical-config"

run_profile_pass() {
  local mode="$1"
  local pass_dir="$RUN_ROOT/$mode"
  local trace_dir="$RUN_ROOT/traces/$mode"
  mkdir -p "$pass_dir" "$trace_dir"

  export RADICAL_BASE="$pass_dir/radical-base"
  if [ "$mode" = "datalife" ]; then
    env RADICAL_TASK_PROFILE_MODE=datalife \
      RADICAL_TASK_DATALIFE_TRACE_DIR="$trace_dir" \
      RADICAL_TASK_DATALIFE_FILE_PATTERNS="*.bin,*.txt,*.log" \
      RADICAL_TASK_DATALIFE_LIB="$DATALIFE_LIB" \
      "$ROOT/tools/radical-pilot-venv/bin/python" "$ROOT/scripts/run_radical_pilot_workflow.py" \
        --run-dir "$pass_dir" \
        --tasks 256 \
        --size-mb 4 \
        --cores 160 \
        --runtime 120 \
        --resource ares.local \
        --queue compute \
        --access-schema local \
        2>&1 | tee "$pass_dir/radical-pilot-workflow.log"
  else
    env RADICAL_TASK_PROFILE_MODE=darshan \
      RADICAL_TASK_DARSHAN_TRACE_DIR="$trace_dir" \
      RADICAL_TASK_DARSHAN_LIB="$DARSHAN_LIB" \
      "$ROOT/tools/radical-pilot-venv/bin/python" "$ROOT/scripts/run_radical_pilot_workflow.py" \
        --run-dir "$pass_dir" \
        --tasks 256 \
        --size-mb 4 \
        --cores 160 \
        --runtime 120 \
        --resource ares.local \
        --queue compute \
        --access-schema local \
        2>&1 | tee "$pass_dir/radical-pilot-workflow.log"
  fi

  test -s "$pass_dir/manifest.json"
  local chunk_count
  chunk_count="$(find "$pass_dir/outputs" -name 'task-*.bin' -type f -size +0c | wc -l)"
  if [ "$chunk_count" -ne 256 ]; then
    echo "Expected 256 RADICAL-Pilot ${mode} output chunks, found ${chunk_count}" >&2
    exit 3
  fi

  "$ROOT/tools/radical-pilot-venv/bin/python" - <<PY
import json
from pathlib import Path
manifest = json.loads(Path("$pass_dir/manifest.json").read_text())
assert manifest["workflow"] == "radical.pilot"
assert manifest["runner"] == "RADICAL-Pilot"
assert manifest["resource"] == "ares.local"
assert manifest["queue"] == "compute"
assert manifest["access_schema"] == "local"
assert manifest["tasks"] == 256
assert manifest["cores"] == 160
assert manifest["total_bytes"] == 256 * 4 * 1024 * 1024
assert all(state == "DONE" for state in manifest["task_states"].values())
print("Validated RADICAL-Pilot $mode manifest:", manifest["total_bytes"], "bytes")
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

mapfile -d '' darshan_logs < <(find "$RUN_ROOT/traces/darshan" -maxdepth 1 -name '*.darshan' -type f -size +0c -print0)
darshan_count=0
for log_path in "${darshan_logs[@]}"; do
  rel="${log_path#$RUN_ROOT/traces/darshan/}"
  parsed="$RUN_ROOT/parsed/${rel}.txt"
  mkdir -p "$(dirname "$parsed")"
  "$DARSHAN_PARSER" "$log_path" > "$parsed"
  if [ ! -s "$parsed" ]; then
    echo "Parsed Darshan output is empty: $parsed" >&2
    exit 4
  fi
  darshan_count=$((darshan_count + 1))
done

if [ "$darshan_count" -eq 0 ]; then
  echo "No non-empty Darshan logs found" >&2
  exit 5
fi

printf 'Darshan logs parsed: %s\n' "$darshan_count"
find "$RUN_ROOT/traces" -type f -printf '%P\t%s\n' | sort > "$RUN_ROOT/trace-summary.tsv"
cat "$RUN_ROOT/datalife-outputs.tsv"
cat "$RUN_ROOT/darshan-outputs.tsv"
cat "$RUN_ROOT/trace-summary.tsv"

echo "RADICAL-Pilot native 4-node profiled workflow completed across $NODE_COUNT nodes."
