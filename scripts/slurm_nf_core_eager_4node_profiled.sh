#!/usr/bin/env bash
#SBATCH --job-name=eager-prof
#SBATCH --exclusive
#SBATCH --nodes=4
#SBATCH --ntasks=4
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/nf-core_eager/slurm-%j-4node-profiled.out
#SBATCH --error=runs/nf-core_eager/slurm-%j-4node-profiled.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

RUN_ROOT="$ROOT/runs/nf-core_eager"
RUN_DIR="$RUN_ROOT/4node-profiled-${SLURM_JOB_ID:-manual}"
DATALIFE_LIB="$ROOT/tools/widget-v1/profiler/datalife/build/flow-monitor/src/libmonitor.so"
DARSHAN_RUNTIME="${DARSHAN_RUNTIME:-$(spack location -i darshan-runtime@3.4.6)}"
DARSHAN_UTIL="${DARSHAN_UTIL:-$(spack location -i darshan-util@3.4.6)}"
DARSHAN_LIB="$DARSHAN_RUNTIME/lib/libdarshan.so.0.0.0"
DARSHAN_PARSER="$DARSHAN_UTIL/bin/darshan-parser"

for required in "$ROOT/scripts/slurm_nf_core_eager_4node.sh" "$ROOT/scripts/profile_tree_io.py" "$DATALIFE_LIB" "$DARSHAN_LIB" "$DARSHAN_PARSER"; do
  if [ ! -s "$required" ] && [ ! -x "$required" ]; then
    echo "ERROR: missing required nf-core/eager profiling artifact: $required" >&2
    exit 1
  fi
done

mkdir -p "$RUN_DIR"/{datalife,darshan,traces/datalife,traces/darshan,parsed}
scontrol show hostnames "$SLURM_JOB_NODELIST" > "$RUN_DIR/hosts.txt"

run_pass() {
  local mode="$1"
  local pass_root="$RUN_DIR/$mode"
  mkdir -p "$pass_root"
  WORKFLOW_ROOT="$ROOT" RUN_ROOT="$pass_root" bash "$ROOT/scripts/slurm_nf_core_eager_4node.sh"

  for replica in 0 1 2 3; do
    local output_dir="$pass_root/4node-${SLURM_JOB_ID:-manual}/replica-${replica}/results"
    local trace_dir="$RUN_DIR/traces/$mode/replica-${replica}"
    local manifest="$pass_root/profiled-output-digests-${replica}.json"
    mkdir -p "$trace_dir"
    if [ "$mode" = "datalife" ]; then
      env DATALIFE_OUTPUT_PATH="$trace_dir" \
        DATALIFE_FILE_PATTERNS="*.fastq.gz,*.fq.gz,*.bam,*.bai,*.html,*.json,*.txt,*.log,*.gz" \
        LD_PRELOAD="$DATALIFE_LIB" \
        "$ROOT/tools/conda-envs/nextflow/bin/python" "$ROOT/scripts/profile_tree_io.py" \
          --root "$output_dir" \
          --manifest "$manifest" \
          --patterns '*.fastq.gz' '*.fq.gz' '*.bam' '*.bai' '*.html' '*.json' '*.txt' '*.log' '*.gz'
    else
      env DARSHAN_ENABLE_NONMPI=1 \
        DARSHAN_LOG_DIR_PATH="$trace_dir" \
        LD_PRELOAD="$DARSHAN_LIB" \
        "$ROOT/tools/conda-envs/nextflow/bin/python" "$ROOT/scripts/profile_tree_io.py" \
          --root "$output_dir" \
          --manifest "$manifest" \
          --patterns '*.fastq.gz' '*.fq.gz' '*.bam' '*.bai' '*.html' '*.json' '*.txt' '*.log' '*.gz'
    fi
  done
}

run_pass datalife
run_pass darshan

python3 - "$RUN_DIR/traces/datalife" <<'PY'
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
  rel="${log_path#$RUN_DIR/traces/darshan/}"
  parsed="$RUN_DIR/parsed/${rel}.txt"
  mkdir -p "$(dirname "$parsed")"
  "$DARSHAN_PARSER" "$log_path" > "$parsed"
  if [ ! -s "$parsed" ]; then
    echo "Parsed Darshan output is empty: $parsed" >&2
    exit 4
  fi
  darshan_count=$((darshan_count + 1))
done < <(find "$RUN_DIR/traces/darshan" -name '*.darshan' -type f -size +0c -print0)

if [ "$darshan_count" -eq 0 ]; then
  echo "No non-empty Darshan logs found" >&2
  exit 5
fi

printf 'Darshan logs parsed: %s\n' "$darshan_count"
find "$RUN_DIR/traces" -type f -printf '%P\t%s\n' | sort > "$RUN_DIR/trace-summary.tsv"
node_count="$(wc -l < "$RUN_DIR/hosts.txt")"
echo "nf-core/eager native 4-node profiled Nextflow workflow completed across ${node_count} nodes."
