#!/usr/bin/env bash
#SBATCH --job-name=vpipe-prof
#SBATCH --exclusive
#SBATCH --nodes=4
#SBATCH --ntasks=4
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/V-pipe/slurm-%j-4node-profiled.out
#SBATCH --error=runs/V-pipe/slurm-%j-4node-profiled.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

RUN_ROOT="${ROOT}/runs/V-pipe"
RUN_DIR="${RUN_ROOT}/4node-profiled-${SLURM_JOB_ID:-manual}"
export VPIPE_CORES="${VPIPE_CORES:-8}"
export VPIPE_MEM_MB="${VPIPE_MEM_MB:-43000}"
DATALIFE_LIB="$ROOT/tools/widget-v1/profiler/datalife/build/flow-monitor/src/libmonitor.so"
DARSHAN_RUNTIME="${DARSHAN_RUNTIME:-$(spack location -i darshan-runtime@3.4.6)}"
DARSHAN_UTIL="${DARSHAN_UTIL:-$(spack location -i darshan-util@3.4.6)}"
DARSHAN_LIB="$DARSHAN_RUNTIME/lib/libdarshan.so.0.0.0"
DARSHAN_PARSER="$DARSHAN_UTIL/bin/darshan-parser"

for required in "$ROOT/scripts/slurm_vpipe_4node.sh" "$DATALIFE_LIB" "$DARSHAN_LIB" "$DARSHAN_PARSER" "$ROOT/scripts/profile_tree_io.py"; do
  if [ ! -s "$required" ] && [ ! -x "$required" ]; then
    echo "ERROR: missing required V-pipe profiling artifact: $required" >&2
    exit 1
  fi
done

mkdir -p "$RUN_DIR"/{datalife,darshan,traces/datalife,traces/darshan,parsed}
scontrol show hostnames "$SLURM_JOB_NODELIST" > "$RUN_DIR/hosts.txt"

run_pass() {
  local mode="$1"
  local pass_dir="$RUN_DIR/$mode"
  mkdir -p "$pass_dir"
  WORKFLOW_ROOT="$ROOT" RUN_ROOT="$RUN_DIR/$mode" \
    "$ROOT/scripts/slurm_vpipe_4node.sh" > "$RUN_DIR/${mode}-workflow.out" 2> "$RUN_DIR/${mode}-workflow.err"

  for replica in 0 1 2 3; do
    local rep_results="$pass_dir/4node-${SLURM_JOB_ID:-manual}/replica-${replica}/results"
    local trace_dir="$RUN_DIR/traces/$mode/replica-${replica}"
    mkdir -p "$trace_dir"
    if [ "$mode" = "datalife" ]; then
      env DATALIFE_OUTPUT_PATH="$trace_dir" \
        DATALIFE_FILE_PATTERNS="*.fastq.gz,*.bam,*.bai,*.vcf,*.csv,*.tsv,*.html,*.log,*.fa,*.fasta,*.gff,*.yaml" \
        LD_PRELOAD="$DATALIFE_LIB" \
        python3 "$ROOT/scripts/profile_tree_io.py" \
          --root "$rep_results" \
          --manifest "$pass_dir/profiled-output-digests-${replica}.json" \
          --patterns '*.fastq.gz' '*.bam' '*.bai' '*.vcf' '*.csv' '*.tsv' '*.html' '*.log' '*.fa' '*.fasta' '*.gff' '*.yaml'
    elif [ "$mode" = "darshan" ]; then
      env DARSHAN_ENABLE_NONMPI=1 \
        DARSHAN_LOG_DIR_PATH="$trace_dir" \
        LD_PRELOAD="$DARSHAN_LIB" \
        python3 "$ROOT/scripts/profile_tree_io.py" \
          --root "$rep_results" \
          --manifest "$pass_dir/profiled-output-digests-${replica}.json" \
          --patterns '*.fastq.gz' '*.bam' '*.bai' '*.vcf' '*.csv' '*.tsv' '*.html' '*.log' '*.fa' '*.fasta' '*.gff' '*.yaml'
    fi
  done
}

run_pass datalife
run_pass darshan

python3 - "$RUN_DIR/traces/datalife" <<'PY'
import json
import sys
from pathlib import Path

files = sorted(Path(sys.argv[1]).rglob("*.json"))
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
  test -s "$parsed"
  darshan_count=$((darshan_count + 1))
done < <(find "$RUN_DIR/traces/darshan" -type f -name '*.darshan' -size +0c -print0)
if [ "$darshan_count" -eq 0 ]; then
  echo "ERROR: no non-empty Darshan logs found" >&2
  exit 4
fi
echo "Darshan logs parsed: $darshan_count"

{
  find "$RUN_DIR/traces/datalife" -type f -name '*.json' -size +0c -printf '%P\t%s\n'
  find "$RUN_DIR/traces/darshan" -type f -name '*.darshan' -size +0c -printf '%P\t%s\n'
} | sort > "$RUN_DIR/trace-summary.tsv"
test -s "$RUN_DIR/trace-summary.tsv"

echo "V-pipe native Snakemake 4-node profiled workflow completed across 4 nodes."
