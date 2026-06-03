#!/usr/bin/env bash
#SBATCH --job-name=deepdrivemd-prof
#SBATCH --exclusive
#SBATCH --partition=compute
#SBATCH --nodes=4
#SBATCH --ntasks=4
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/DeepDriveMD-pipeline/slurm-%j-4node-profiled.out
#SBATCH --error=runs/DeepDriveMD-pipeline/slurm-%j-4node-profiled.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
cd "$ROOT"
export WORKFLOW_ROOT="$ROOT"

DATALIFE_LIB="$ROOT/tools/widget-v1/profiler/datalife/build/flow-monitor/src/libmonitor.so"
DARSHAN_RUNTIME="${DARSHAN_RUNTIME:-$(spack location -i darshan-runtime@3.4.6)}"
DARSHAN_UTIL="${DARSHAN_UTIL:-$(spack location -i darshan-util@3.4.6)}"
DARSHAN_LIB="$DARSHAN_RUNTIME/lib/libdarshan.so.0.0.0"
DARSHAN_PARSER="$DARSHAN_UTIL/bin/darshan-parser"

for required in "$DATALIFE_LIB" "$DARSHAN_LIB" "$DARSHAN_PARSER"; do
  if [[ ! -s "$required" ]]; then
    echo "Required profiling artifact missing: $required" >&2
    exit 2
  fi
done

mkdir -p runs/DeepDriveMD-pipeline
RUN_ROOT="$ROOT/runs/DeepDriveMD-pipeline/4node-profiled-${SLURM_JOB_ID:-manual}"
rm -rf "$RUN_ROOT"
mkdir -p "$RUN_ROOT"/{traces/datalife,traces/darshan,parsed}

run_profile_pass() {
  local profile_mode="$1"
  local trace_dir="$RUN_ROOT/traces/$profile_mode"
  local label="4node-profiled-${profile_mode}"
  local pass_run="$ROOT/runs/DeepDriveMD-pipeline/${label}-${SLURM_JOB_ID:-manual}"

  printf 'DeepDriveMD profiled pass starting: %s\n' "$profile_mode"
  rm -rf "$pass_run"
  mkdir -p "$trace_dir"

  export WORKFLOW_ROOT="$ROOT"
  export RADICAL_CONFIG_USER_DIR="$ROOT/tools/radical-config"
  export DEEPMD_RUN_LABEL="$label"
  export DEEPMD_TITLE="BBA DeepDriveMD Ares 4-node ${profile_mode} profiled"
  export DEEPMD_RESOURCE=ares.local
  export DEEPMD_QUEUE=compute
  export DEEPMD_SCHEMA=local
  export DEEPMD_PROJECT=none
  export DEEPMD_CPUS_PER_NODE=40
  export DEEPMD_NUM_TASKS=40
  export DEEPMD_EXPECT_TASKS=40
  export DEEPMD_LAST_N_H5=40
  export DEEPMD_SKLEARN_JOBS=40

  if [[ "$profile_mode" == "datalife" ]]; then
    export DEEPMD_PROFILE_MODE=datalife
    export DEEPMD_PROFILE_TRACE_DIR="$trace_dir"
    export DEEPMD_PROFILE_FILE_PATTERNS="*.pdb,*.h5,*.dcd,*.log,*.pt,*.yaml,*.txt"
    export DEEPMD_PROFILE_LIB="$DATALIFE_LIB"
  else
    export DEEPMD_PROFILE_MODE=darshan
    export DEEPMD_PROFILE_TRACE_DIR="$trace_dir"
    export DEEPMD_PROFILE_LIB="$DARSHAN_LIB"
    unset DEEPMD_PROFILE_FILE_PATTERNS
  fi
  unset LD_PRELOAD DATALIFE_OUTPUT_PATH DATALIFE_FILE_PATTERNS DARSHAN_ENABLE_NONMPI DARSHAN_LOG_DIR_PATH

  bash "$ROOT/scripts/slurm_deepdrivemd_single.sh"
  unset DEEPMD_PROFILE_MODE DEEPMD_PROFILE_TRACE_DIR DEEPMD_PROFILE_FILE_PATTERNS DEEPMD_PROFILE_LIB

  for manifest in md_h5_files.txt md_dcd_files.txt md_log_files.txt ml_checkpoint_files.txt model_selection_json.txt agent_json.txt; do
    if [[ ! -s "$pass_run/$manifest" ]]; then
      echo "DeepDriveMD $profile_mode pass missing manifest: $pass_run/$manifest" >&2
      return 10
    fi
  done
  for manifest in md_h5_files.txt md_dcd_files.txt md_log_files.txt; do
    local count
    count="$(wc -l < "$pass_run/$manifest")"
    if (( count < 40 )); then
      echo "DeepDriveMD $profile_mode pass has too few entries in $manifest: $count" >&2
      return 11
    fi
  done

  find "$pass_run/experiment" -type f -printf '%P\t%s\n' | sort > "$RUN_ROOT/${profile_mode}-outputs.tsv"
  printf 'DeepDriveMD profiled pass completed: %s\n' "$profile_mode"
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
non_empty = [path for path in files if path.stat().st_size > 0]
if len(non_empty) != len(files):
    raise SystemExit("some DataLife JSON traces are empty")
for path in files:
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
  if [[ ! -s "$parsed" ]]; then
    echo "Parsed Darshan output is empty: $parsed" >&2
    exit 5
  fi
  darshan_count=$((darshan_count + 1))
done < <(find "$RUN_ROOT/traces/darshan" -name '*.darshan' -type f -size +0c -print0)

if (( darshan_count == 0 )); then
  echo "No non-empty Darshan logs found" >&2
  exit 6
fi

printf 'Darshan logs parsed: %s\n' "$darshan_count"
find "$RUN_ROOT/traces" -type f -printf '%P\t%s\n' | sort > "$RUN_ROOT/trace-summary.tsv"
cat "$RUN_ROOT/trace-summary.tsv"
