#!/usr/bin/env bash
#SBATCH --job-name=lammps-prof
#SBATCH --exclusive
#SBATCH --nodes=4
#SBATCH --ntasks-per-node=8
#SBATCH --cpus-per-task=1
#SBATCH --mem=45G
#SBATCH --time=08:00:00
#SBATCH --output=runs/lammps/slurm-%j-4node-profiled.out
#SBATCH --error=runs/lammps/slurm-%j-4node-profiled.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
cd "$ROOT"

source /etc/profile.d/modules.sh 2>/dev/null || true
module load openmpi/5.0.5-gcc-11.4.0-og56sxz

LMP="$ROOT/tools/lammps/bin/lmp"
DATALIFE_LIB="$ROOT/tools/widget-v1/profiler/datalife/build/flow-monitor/src/libmonitor.so"
DARSHAN_RUNTIME="${DARSHAN_RUNTIME:-$(spack location -i darshan-runtime@3.4.6)}"
DARSHAN_UTIL="${DARSHAN_UTIL:-$(spack location -i darshan-util@3.4.6)}"
DARSHAN_LIB="$DARSHAN_RUNTIME/lib/libdarshan.so.0.0.0"
DARSHAN_PARSER="$DARSHAN_UTIL/bin/darshan-parser"

for required in "$LMP" "$DATALIFE_LIB" "$DARSHAN_LIB" "$DARSHAN_PARSER"; do
  if [ ! -s "$required" ]; then
    echo "Required executable/profiling artifact missing: $required" >&2
    exit 2
  fi
done

RUN_ROOT="$ROOT/runs/lammps/4node-profiled-${SLURM_JOB_ID:-manual}"
rm -rf "$RUN_ROOT"
mkdir -p "$RUN_ROOT"/{datalife,darshan,traces/datalife,traces/darshan,parsed}

scontrol show hostnames "$SLURM_JOB_NODELIST" | awk '{print $1 " slots=8"}' > "$RUN_ROOT/hostfile"
NODE_COUNT="$(wc -l < "$RUN_ROOT/hostfile")"
if [ "$NODE_COUNT" -lt 4 ]; then
  echo "ERROR: expected at least 4 Slurm nodes, got $NODE_COUNT" >&2
  exit 1
fi

RANKS="${SLURM_NTASKS:-160}"
export OMP_NUM_THREADS=1

run_profile_pass() {
  local mode="$1"
  local pass_dir="$RUN_ROOT/$mode"
  local trace_dir="$RUN_ROOT/traces/$mode"
  mkdir -p "$pass_dir" "$trace_dir"
  cp "$ROOT/repos/lammps/bench/in.lj" "$pass_dir/in.lj"

  (
    cd "$pass_dir"
    if [ "$mode" = "datalife" ]; then
      env DATALIFE_OUTPUT_PATH="$trace_dir" \
        DATALIFE_FILE_PATTERNS="*.lj,*.lammps,*.out,*.log" \
        LD_PRELOAD="$DATALIFE_LIB" \
        mpirun --bind-to none --map-by slot --hostfile "$RUN_ROOT/hostfile" -np "$RANKS" "$LMP" \
          -var x 4 \
          -var y 5 \
          -var z 4 \
          -in in.lj \
          -log log.lammps \
          > lammps.out 2>&1
    else
      env DARSHAN_LOG_DIR_PATH="$trace_dir" \
        LD_PRELOAD="$DARSHAN_LIB" \
        mpirun --bind-to none --map-by slot --hostfile "$RUN_ROOT/hostfile" -np "$RANKS" "$LMP" \
          -var x 4 \
          -var y 5 \
          -var z 4 \
          -in in.lj \
          -log log.lammps \
          > lammps.out 2>&1
    fi
  )

  test -s "$pass_dir/log.lammps"
  test -s "$pass_dir/lammps.out"
  grep -q "Loop time of" "$pass_dir/log.lammps"
  grep -q "on $RANKS procs" "$pass_dir/log.lammps"
  grep -q "for 100 steps" "$pass_dir/log.lammps"
  grep -q "with 2560000 atoms" "$pass_dir/log.lammps"

  local bytes
  bytes="$(stat --printf='%s' "$pass_dir/log.lammps")"
  if [ "$bytes" -lt 2000 ]; then
    echo "ERROR: LAMMPS ${mode} log too small: $bytes bytes" >&2
    exit 3
  fi
  find "$pass_dir" -type f -size +0c -printf '%P\t%s\n' | sort > "$RUN_ROOT/${mode}-outputs.tsv"
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

echo "LAMMPS native 4-node profiled MPI LJ scaled benchmark completed with $RANKS ranks across $NODE_COUNT nodes and 2560000 atoms."
