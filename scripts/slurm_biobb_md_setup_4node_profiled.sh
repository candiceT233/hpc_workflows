#!/usr/bin/env bash
#SBATCH --job-name=biobb-md-prof
#SBATCH --exclusive
#SBATCH --nodes=4
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/biobb_wf_md_setup/slurm-%j-4node-profiled.out
#SBATCH --error=runs/biobb_wf_md_setup/slurm-%j-4node-profiled.err

set -eo pipefail

if [[ -z "${WORKFLOW_ROOT:-}" ]]; then
  if [[ -f table.md && -d scripts ]]; then
    WORKFLOW_ROOT="$PWD"
  else
    WORKFLOW_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  fi
fi
cd "$WORKFLOW_ROOT"

mkdir -p runs/biobb_wf_md_setup

GMXROOT="${GMXROOT:-$(spack location -i gromacs@2024.3)}"
DATALIFE_LIB="$WORKFLOW_ROOT/tools/widget-v1/profiler/datalife/build/flow-monitor/src/libmonitor.so"
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

export OMP_NUM_THREADS="${SLURM_CPUS_PER_TASK:-40}"
export OMP_PLACES=cores
export OMP_PROC_BIND=close

RUN_DIR="$WORKFLOW_ROOT/runs/biobb_wf_md_setup/4node-profiled-${SLURM_JOB_ID:-manual}"
rm -rf "$RUN_DIR"
mkdir -p "$RUN_DIR"/{datalife,darshan,traces/datalife,traces/darshan,parsed}

read -r -a PDB_CODES <<< "${BIOBB_PDB_CODES:-1AKI 1AKI 1AKI 1AKI}"
replica_count="${#PDB_CODES[@]}"
if (( replica_count < SLURM_NNODES )); then
  echo "Need at least ${SLURM_NNODES} PDB codes, got ${replica_count}" >&2
  exit 3
fi

run_pass() {
  local profile_mode="$1"
  local pass_dir="$RUN_DIR/$profile_mode"

  for ((i = 0; i < SLURM_NNODES; i++)); do
    local replica_id=$((i + 1))
    local pdb_code="${PDB_CODES[$i]}"
    local replica_dir="$pass_dir/replica-${replica_id}-${pdb_code}"
    local trace_dir="$RUN_DIR/traces/$profile_mode/replica-${replica_id}-${pdb_code}"
    mkdir -p "$replica_dir" "$trace_dir"

    if [[ "$profile_mode" == "datalife" ]]; then
      srun --exclusive --nodes=1 --ntasks=1 --cpus-per-task="$OMP_NUM_THREADS" \
        --export=ALL,WORKFLOW_ROOT="$WORKFLOW_ROOT",GMXROOT="$GMXROOT",PDB_CODE="$pdb_code",REPLICA_DIR="$replica_dir",OMP_NUM_THREADS="$OMP_NUM_THREADS",DATALIFE_LIB="$DATALIFE_LIB",TRACE_DIR="$trace_dir" \
        bash -lc '
          set -eo pipefail
          . "$GMXROOT/bin/GMXRC"
          . "$WORKFLOW_ROOT/tools/biobb-venv/bin/activate"
          export OMP_PLACES=cores
          export OMP_PROC_BIND=close
          env REAL_GMX_BINARY="$GMXROOT/bin/gmx_mpi" \
            python "$WORKFLOW_ROOT/scripts/run_biobb_md_setup.py" \
              --pdb-code "$PDB_CODE" \
              --output-dir "$REPLICA_DIR" \
              --gmx-binary "$WORKFLOW_ROOT/scripts/gmx_profile_wrapper.sh" \
              --omp-threads "$OMP_NUM_THREADS"
          mkdir -p "$REPLICA_DIR/profiled_copy"
          env DATALIFE_OUTPUT_PATH="$TRACE_DIR" \
            DATALIFE_FILE_PATTERNS="*.pdb,*.gro,*.trr,*.edr,*.cpt,*.xvg,*.zip,*.tpr,*.log" \
            LD_PRELOAD="$DATALIFE_LIB" \
            python3 - "$REPLICA_DIR" <<'"'"'PY'"'"'
import shutil
import sys
from pathlib import Path

root = Path(sys.argv[1])
dest = root / "profiled_copy"
suffixes = {".pdb", ".gro", ".trr", ".edr", ".cpt", ".xvg", ".zip", ".tpr", ".log"}
for path in sorted(root.iterdir()):
    if path.is_file() and path.suffix in suffixes:
        with path.open("rb") as src, (dest / path.name).open("wb") as out:
            shutil.copyfileobj(src, out, length=1024 * 1024)
PY
        ' &
    else
      srun --exclusive --nodes=1 --ntasks=1 --cpus-per-task="$OMP_NUM_THREADS" \
        --export=ALL,WORKFLOW_ROOT="$WORKFLOW_ROOT",GMXROOT="$GMXROOT",PDB_CODE="$pdb_code",REPLICA_DIR="$replica_dir",OMP_NUM_THREADS="$OMP_NUM_THREADS",DARSHAN_LIB="$DARSHAN_LIB",TRACE_DIR="$trace_dir" \
        bash -lc '
          set -eo pipefail
          . "$GMXROOT/bin/GMXRC"
          . "$WORKFLOW_ROOT/tools/biobb-venv/bin/activate"
          export OMP_PLACES=cores
          export OMP_PROC_BIND=close
          env BIOBB_PROFILE_MODE=darshan \
            BIOBB_TRACE_DIR="$TRACE_DIR" \
            DARSHAN_LIB="$DARSHAN_LIB" \
            REAL_GMX_BINARY="$GMXROOT/bin/gmx_mpi" \
            python "$WORKFLOW_ROOT/scripts/run_biobb_md_setup.py" \
              --pdb-code "$PDB_CODE" \
              --output-dir "$REPLICA_DIR" \
              --gmx-binary "$WORKFLOW_ROOT/scripts/gmx_profile_wrapper.sh" \
              --omp-threads "$OMP_NUM_THREADS"
        ' &
    fi
  done

  wait

  for ((i = 0; i < SLURM_NNODES; i++)); do
    local replica_id=$((i + 1))
    local pdb_code="${PDB_CODES[$i]}"
    local replica_dir="$pass_dir/replica-${replica_id}-${pdb_code}"
    for suffix in md.trr md.gro md.edr md.log md.cpt imaged_traj.trr md_dry.gro; do
      local path="$replica_dir/${pdb_code}_${suffix}"
      if [[ ! -s "$path" ]]; then
        echo "Missing or empty expected output: $path" >&2
        exit 4
      fi
    done
  done

  find "$pass_dir" -maxdepth 2 -type f \( -name '*_md.trr' -o -name '*_md.gro' -o -name '*_md.edr' -o -name '*_md.log' -o -name '*_md.cpt' -o -name '*_imaged_traj.trr' -o -name '*_md_dry.gro' \) \
    -printf '%P\t%s\n' | sort > "$RUN_DIR/${profile_mode}-summary.tsv"
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
  if [[ ! -s "$parsed" ]]; then
    echo "Parsed Darshan output is empty: $parsed" >&2
    exit 5
  fi
  darshan_count=$((darshan_count + 1))
done < <(find "$RUN_DIR/traces/darshan" -name '*.darshan' -type f -print0)

if (( darshan_count == 0 )); then
  echo "No Darshan logs found" >&2
  exit 6
fi

printf 'Darshan logs parsed: %s\n' "$darshan_count"

find "$RUN_DIR/traces" -type f -printf '%P\t%s\n' | sort > "$RUN_DIR/trace-summary.tsv"
cat "$RUN_DIR/datalife-summary.tsv"
cat "$RUN_DIR/darshan-summary.tsv"
cat "$RUN_DIR/trace-summary.tsv"
