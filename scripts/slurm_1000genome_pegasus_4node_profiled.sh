#!/usr/bin/env bash
#SBATCH --job-name=1000genome-prof
#SBATCH --exclusive
#SBATCH --partition=compute
#SBATCH --nodes=4
#SBATCH --ntasks-per-node=8
#SBATCH --cpus-per-task=1
#SBATCH --mem=45G
#SBATCH --time=48:00:00
#SBATCH --output=runs/1000genome-workflow/slurm-%j-4node-profiled.out
#SBATCH --error=runs/1000genome-workflow/slurm-%j-4node-profiled.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

cd "$ROOT"
mkdir -p runs/1000genome-workflow

export PATH="$ROOT/scripts/bin:$ROOT/scripts/pegasus-bin:/usr/bin:/bin:$PATH"
export PYTHONPATH="$(pegasus-config --python):${PYTHONPATH:-}"

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

RUN_ROOT="$ROOT/runs/1000genome-workflow/4node-profiled-${SLURM_JOB_ID:-manual}"
rm -rf "$RUN_ROOT"
mkdir -p "$RUN_ROOT"/{datalife,darshan,traces/datalife,traces/darshan,parsed}

HOSTFILE="$RUN_ROOT/hosts.txt"
scontrol show hostnames "$SLURM_JOB_NODELIST" > "$HOSTFILE"
NODE_COUNT="$(wc -l < "$HOSTFILE")"
if [ "$NODE_COUNT" -lt 4 ]; then
  echo "ERROR: expected at least 4 Slurm nodes, got $NODE_COUNT" >&2
  exit 1
fi

run_profile_pass() {
  local mode="$1"
  local pass_dir="$RUN_ROOT/$mode"
  local dir_name="codex-shell-4node-profiled-${mode}-${SLURM_JOB_ID:-manual}"
  mkdir -p "$pass_dir"

  export PEGASUS_1000G_REPO="$ROOT/repos/1000genome-workflow"
  export PEGASUS_1000G_TRANSFORM_PFN="$ROOT/scripts/1000genome-slurm-transform.sh"
  export PEGASUS_1000G_HOSTFILE="$HOSTFILE"
  export PEGASUS_1000G_NODE_LOG="$pass_dir/1000genome-node-dispatch.log"
  export PEGASUS_1000G_COUNTER_FILE="$pass_dir/1000genome-node-counter.txt"
  export PEGASUS_1000G_PROFILE_MODE="$mode"
  export PEGASUS_1000G_DATALIFE_LIB="$DATALIFE_LIB"
  export PEGASUS_1000G_DATALIFE_TRACE_DIR="$RUN_ROOT/traces/datalife"
  export PEGASUS_1000G_DATALIFE_FILE_PATTERNS="*.vcf,*.tar.gz,*.txt,*.log,*.out,*.err"
  export PEGASUS_1000G_DARSHAN_LIB="$DARSHAN_LIB"
  export PEGASUS_1000G_DARSHAN_TRACE_DIR="$RUN_ROOT/traces/darshan"
  : > "$PEGASUS_1000G_NODE_LOG"

  python3 "$ROOT/scripts/run_1000genome_pegasus.py" \
    --repo repos/1000genome-workflow \
    --run-dir "$pass_dir" \
    --dir-name "$dir_name" \
    --individuals-jobs 4 \
    2>&1 | tee "$pass_dir/1000genome-pegasus.log"

  test -s "$pass_dir/manifest.json"
  grep -q '"engine": "pegasus-shell"' "$pass_dir/manifest.json"
  grep -q '"expected_outputs": 140' "$pass_dir/manifest.json"
  grep -q '"individuals_jobs": 4' "$pass_dir/manifest.json"
  grep -q "SHELL_SCRIPT_FINISHED 0" "$ROOT/repos/1000genome-workflow/$dir_name/jobstate.log"

  local used_nodes
  used_nodes="$(awk '{print $3}' "$PEGASUS_1000G_NODE_LOG" | sort -u | wc -l)"
  if [ "$used_nodes" -lt 4 ]; then
    echo "ERROR: 1000genome Pegasus ${mode} transformations used only $used_nodes nodes" >&2
    cat "$PEGASUS_1000G_NODE_LOG" >&2
    exit 3
  fi

  find "$pass_dir" -type f -size +0c -printf '%P\t%s\n' | sort > "$RUN_ROOT/${mode}-files.tsv"
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

echo "1000genome native Pegasus 4-node profiled workflow completed across $NODE_COUNT nodes."
