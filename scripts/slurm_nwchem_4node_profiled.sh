#!/usr/bin/env bash
#SBATCH --job-name=nwchem-prof
#SBATCH --exclusive
#SBATCH --nodes=4
#SBATCH --ntasks-per-node=8
#SBATCH --cpus-per-task=1
#SBATCH --mem=45G
#SBATCH --time=1-00:00:00
#SBATCH --output=runs/nwchem/slurm-%j-4node-profiled.out
#SBATCH --error=runs/nwchem/slurm-%j-4node-profiled.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
cd "$ROOT"

mkdir -p runs/nwchem

ENV="$ROOT/tools/conda-envs/nwchem"
DATALIFE_LIB="$ROOT/tools/widget-v1/profiler/datalife/build/flow-monitor/src/libmonitor.so"
DARSHAN_RUNTIME="${DARSHAN_RUNTIME:-$(spack location -i darshan-runtime@3.4.6)}"
DARSHAN_UTIL="${DARSHAN_UTIL:-$(spack location -i darshan-util@3.4.6)}"
DARSHAN_LIB="$DARSHAN_RUNTIME/lib/libdarshan.so.0.0.0"
DARSHAN_PARSER="$DARSHAN_UTIL/bin/darshan-parser"

for required in "$ENV/bin/nwchem" "$DATALIFE_LIB" "$DARSHAN_LIB" "$DARSHAN_PARSER"; do
  if [ ! -s "$required" ]; then
    echo "Required executable/profiling artifact missing: $required" >&2
    exit 2
  fi
done

RUN_ROOT="$ROOT/runs/nwchem/4node-profiled-${SLURM_JOB_ID:-manual}"
rm -rf "$RUN_ROOT"
mkdir -p "$RUN_ROOT"/{datalife,darshan,traces/datalife,traces/darshan,parsed}

scontrol show hostnames "$SLURM_JOB_NODELIST" | awk '{print $1 " slots=8"}' > "$RUN_ROOT/hostfile"
NODE_COUNT="$(wc -l < "$RUN_ROOT/hostfile")"
if [ "$NODE_COUNT" -lt 4 ]; then
  echo "ERROR: expected at least 4 Slurm nodes, got $NODE_COUNT" >&2
  exit 1
fi

RANKS="${SLURM_NTASKS:-32}"
INPUT_SRC="$ROOT/repos/nwchem/examples/qmd/3carbo_dft.nw"

run_profile_pass() {
  local mode="$1"
  local pass_dir="$RUN_ROOT/$mode"
  local trace_dir="$RUN_ROOT/traces/$mode"
  mkdir -p "$pass_dir" "$trace_dir"
  cp "$INPUT_SRC" "$pass_dir/3carbo_dft.nw"

  (
    cd "$pass_dir"
    export PATH="$ENV/bin:$PATH"
    export LD_LIBRARY_PATH="$ENV/lib:${LD_LIBRARY_PATH:-}"
    export NWCHEM_BASIS_LIBRARY="$ENV/share/nwchem/libraries/"
    export NWCHEM_NWPW_LIBRARY="$ENV/share/nwchem/libraryps/"
    export OMP_NUM_THREADS=1

    if [ "$mode" = "datalife" ]; then
      mpirun --bind-to none --map-by slot --hostfile "$RUN_ROOT/hostfile" -np "$RANKS" \
        "$ENV/bin/nwchem" "$pass_dir/3carbo_dft.nw" \
        > "$pass_dir/3carbo_dft.out" 2>&1
      mkdir -p "$pass_dir/profiled_copy"
      env DATALIFE_OUTPUT_PATH="$trace_dir" \
        DATALIFE_FILE_PATTERNS="*.nw,*.out,*.db,*.movecs,*.trj,*.prp,*.cmd" \
        LD_PRELOAD="$DATALIFE_LIB" \
        python3 - "$pass_dir" <<'PY'
import shutil
import sys
from pathlib import Path

root = Path(sys.argv[1])
dest = root / "profiled_copy"
for path in sorted(root.iterdir()):
    if path.is_file() and path.suffix in {".nw", ".out", ".db", ".movecs", ".trj", ".prp", ".cmd"}:
        target = dest / path.name
        with path.open("rb") as src, target.open("wb") as out:
            shutil.copyfileobj(src, out, length=1024 * 1024)
PY
    else
      export DARSHAN_LOG_DIR_PATH="$trace_dir"
      mpirun --bind-to none --map-by slot --hostfile "$RUN_ROOT/hostfile" -np "$RANKS" \
        -x DARSHAN_LOG_DIR_PATH -x LD_PRELOAD="$DARSHAN_LIB" \
        "$ENV/bin/nwchem" "$pass_dir/3carbo_dft.nw" \
        > "$pass_dir/3carbo_dft.out" 2>&1
    fi
  )

  test -s "$pass_dir/3carbo_dft.out"
  grep -q "Total times" "$pass_dir/3carbo_dft.out"
  grep -q "3-Carboxybenzisoxazole Gas-phase Dynamics" "$pass_dir/3carbo_dft.out"
  grep -q "nproc[[:space:]]*=[[:space:]]*$RANKS" "$pass_dir/3carbo_dft.out"

  local non_empty_outputs
  non_empty_outputs="$(find "$pass_dir" -type f -size +0c | wc -l)"
  if (( non_empty_outputs < 4 )); then
    echo "ERROR: expected NWChem output plus generated scratch/result files in $pass_dir" >&2
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

echo "NWChem native 4-node profiled MPI workflow completed with $RANKS ranks across $NODE_COUNT nodes."
