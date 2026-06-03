#!/bin/bash
#SBATCH --job-name=pyflextrkr-prof
#SBATCH --exclusive
#SBATCH --partition=compute
#SBATCH --nodes=4
#SBATCH --ntasks=33
#SBATCH --cpus-per-task=1
#SBATCH --time=1-00:00:00
#SBATCH --output=runs/PyFLEXTRKR/slurm-%j-4node-profiled.out
#SBATCH --error=runs/PyFLEXTRKR/slurm-%j-4node-profiled.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

REPO="$ROOT/repos/PyFLEXTRKR"
ENV="$ROOT/tools/conda-envs/pyflextrkr"
DATA_ROOT="$ROOT/data/PyFLEXTRKR/full"
INPUT_DIR="$DATA_ROOT/input"
RUN_ROOT="$ROOT/runs/PyFLEXTRKR/4node-profiled-${SLURM_JOB_ID:-manual}"
N_WORKERS=32

DATALIFE_LIB="$ROOT/tools/widget-v1/profiler/datalife/build/flow-monitor/src/libmonitor.so"
DARSHAN_RUNTIME="${DARSHAN_RUNTIME:-$(spack location -i darshan-runtime@3.4.6)}"
DARSHAN_UTIL="${DARSHAN_UTIL:-$(spack location -i darshan-util@3.4.6)}"
DARSHAN_LIB="$DARSHAN_RUNTIME/lib/libdarshan.so.0.0.0"
DARSHAN_PARSER="$DARSHAN_UTIL/bin/darshan-parser"

for required in "$ENV/bin/python" "$DATALIFE_LIB" "$DARSHAN_LIB" "$DARSHAN_PARSER"; do
  if [ ! -s "$required" ]; then
    echo "Required executable/profiling artifact missing: $required" >&2
    exit 2
  fi
done

mkdir -p "$RUN_ROOT" "$INPUT_DIR"
TMP_ROOT="$RUN_ROOT/tmp"
mkdir -p "$TMP_ROOT"

if ! tar -tzf "$INPUT_DIR/gpm_tb_imerg.tar.gz" >/dev/null 2>&1; then
  curl -L --fail --retry 5 --retry-all-errors -C - \
    https://portal.nersc.gov/project/m1867/PyFLEXTRKR/sample_data/tb_pcp/gpm_tb_imerg.tar.gz \
    -o "$INPUT_DIR/gpm_tb_imerg.tar.gz"
fi

tar -tzf "$INPUT_DIR/gpm_tb_imerg.tar.gz" >/dev/null

if ! find "$INPUT_DIR" -maxdepth 1 -type f -name 'merg_*.nc' -print -quit | grep -q .; then
  tar -xzf "$INPUT_DIR/gpm_tb_imerg.tar.gz" -C "$INPUT_DIR"
fi

scontrol show hostnames "$SLURM_JOB_NODELIST" > "$RUN_ROOT/hosts.txt"
NODE_COUNT="$(wc -l < "$RUN_ROOT/hosts.txt")"
if [ "$NODE_COUNT" -lt 4 ]; then
  echo "ERROR: expected at least 4 Slurm nodes, got $NODE_COUNT" >&2
  exit 1
fi

export PATH="$ENV/bin:$PATH"
export PYTHONPATH="$REPO:${PYTHONPATH:-}"
export DASK_DISTRIBUTED__COMM__TIMEOUTS__CONNECT=360s
export DASK_DISTRIBUTED__COMM__TIMEOUTS__TCP=360s
export OMPI_MCA_btl="^openib"
ulimit -n 64000 || true

run_profile_pass() {
  local mode="$1"
  local pass_root="$RUN_ROOT/$mode"
  local trace_root="$RUN_ROOT/traces/$mode"
  local profiled_input="$pass_root/profiled_input"
  local config="$pass_root/config_imerg_mcs_tbpf_daskmpi.yml"
  local scheduler_file="$pass_root/scheduler.json"
  mkdir -p "$pass_root" "$trace_root" "$profiled_input"

  if [ "$mode" = "datalife" ]; then
    env DATALIFE_OUTPUT_PATH="$trace_root/stage-inputs" \
      DATALIFE_FILE_PATTERNS="*.nc,*.yml,*.log,*.txt" \
      LD_PRELOAD="$DATALIFE_LIB" \
      "$ENV/bin/python" "$ROOT/scripts/pyflextrkr_profile_io.py" copy-inputs \
        --src-dir "$INPUT_DIR" \
        --dst-dir "$profiled_input" \
        --pattern 'merg_*.nc' \
        --manifest "$pass_root/profiled-input-digests.json"
  else
    env DARSHAN_ENABLE_NONMPI=1 \
      DARSHAN_LOG_DIR_PATH="$trace_root/stage-inputs" \
      LD_PRELOAD="$DARSHAN_LIB" \
      "$ENV/bin/python" "$ROOT/scripts/pyflextrkr_profile_io.py" copy-inputs \
        --src-dir "$INPUT_DIR" \
        --dst-dir "$profiled_input" \
        --pattern 'merg_*.nc' \
        --manifest "$pass_root/profiled-input-digests.json"
  fi

  sed \
    -e "s#INPUT_DIR/#$profiled_input/#g" \
    -e "s#TRACK_DIR/#$pass_root/#g" \
    -e "s#run_parallel: 1#run_parallel: 2#g" \
    -e "s#nprocesses : 8#nprocesses : $N_WORKERS#g" \
    -e "s#timeout: 360#timeout: 900#g" \
    "$REPO/config/config_imerg_mcs_tbpf_example.yml" > "$config"

  rm -f "$scheduler_file"

  mpirun -np "$SLURM_NTASKS" dask-mpi \
    --scheduler-file="$scheduler_file" \
    --nthreads=1 \
    --memory-limit=auto \
    --worker-class distributed.Worker \
    --local-directory="$TMP_ROOT" &
  local dask_mpi_pid=$!

  cleanup_dask() {
    if kill -0 "$dask_mpi_pid" 2>/dev/null; then
      kill "$dask_mpi_pid" 2>/dev/null || true
      wait "$dask_mpi_pid" 2>/dev/null || true
    fi
  }
  trap cleanup_dask RETURN

  for _ in $(seq 1 180); do
    if [ -s "$scheduler_file" ]; then
      break
    fi
    sleep 1
  done

  if [ ! -s "$scheduler_file" ]; then
    echo "ERROR: dask-mpi did not create scheduler file $scheduler_file" >&2
    exit 3
  fi

  cd "$REPO"
  "$ENV/bin/python" "$REPO/runscripts/run_mcs_tbpf.py" "$config" "$scheduler_file" "$N_WORKERS"
  cleanup_dask
  trap - RETURN

  if ! find "$pass_root/stats" -type f \( -name 'mcs_tracks_robust_*.nc' -o -name 'mcs_tracks_final_*.nc' -o -name 'trackstats_*.nc' \) -size +0 -print -quit | grep -q .; then
    echo "ERROR: missing non-empty PyFLEXTRKR stats outputs for $mode" >&2
    exit 4
  fi

  if ! find "$pass_root/mcstracking" -type f -name '*.nc' -size +0 -print -quit | grep -q .; then
    echo "ERROR: missing non-empty PyFLEXTRKR pixel tracking outputs for $mode" >&2
    exit 5
  fi

  local output_count
  output_count="$(find "$pass_root" -type f -size +0 | wc -l)"
  if [ "$output_count" -lt 20 ]; then
    echo "ERROR: too few non-empty PyFLEXTRKR outputs for $mode: $output_count" >&2
    exit 6
  fi
  find "$pass_root" -type f -size +0 -printf '%P\t%s\n' | sort > "$RUN_ROOT/${mode}-outputs.tsv"

  if [ "$mode" = "datalife" ]; then
    env DATALIFE_OUTPUT_PATH="$trace_root/read-outputs" \
      DATALIFE_FILE_PATTERNS="*.nc,*.yml,*.log,*.txt" \
      LD_PRELOAD="$DATALIFE_LIB" \
      "$ENV/bin/python" "$ROOT/scripts/pyflextrkr_profile_io.py" scan-outputs \
        --manifest "$pass_root/profiled-output-digests.json" \
        "$pass_root/stats" "$pass_root/mcstracking"
  else
    env DARSHAN_ENABLE_NONMPI=1 \
      DARSHAN_LOG_DIR_PATH="$trace_root/read-outputs" \
      LD_PRELOAD="$DARSHAN_LIB" \
      "$ENV/bin/python" "$ROOT/scripts/pyflextrkr_profile_io.py" scan-outputs \
        --manifest "$pass_root/profiled-output-digests.json" \
        "$pass_root/stats" "$pass_root/mcstracking"
  fi
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
    exit 7
  fi
  darshan_count=$((darshan_count + 1))
done < <(find "$RUN_ROOT/traces/darshan" -name '*.darshan' -type f -size +0c -print0)

if [ "$darshan_count" -eq 0 ]; then
  echo "No non-empty Darshan logs found" >&2
  exit 8
fi

printf 'Darshan logs parsed: %s\n' "$darshan_count"
find "$RUN_ROOT/traces" -type f -printf '%P\t%s\n' | sort > "$RUN_ROOT/trace-summary.tsv"
cat "$RUN_ROOT/datalife-outputs.tsv"
cat "$RUN_ROOT/darshan-outputs.tsv"
cat "$RUN_ROOT/trace-summary.tsv"

echo "PyFLEXTRKR native 4-node profiled dask-mpi workflow completed across $NODE_COUNT nodes."
