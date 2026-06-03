#!/bin/bash
#SBATCH --job-name=pyflextrkr-single
#SBATCH --exclusive
#SBATCH --partition=compute
#SBATCH --nodes=1
#SBATCH --ntasks=9
#SBATCH --cpus-per-task=1
#SBATCH --time=12:00:00
#SBATCH --output=runs/PyFLEXTRKR/slurm-%j-single.out
#SBATCH --error=runs/PyFLEXTRKR/slurm-%j-single.err

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
RUN_ROOT="$ROOT/runs/PyFLEXTRKR/single"
DATA_ROOT="$ROOT/data/PyFLEXTRKR/full"
INPUT_DIR="$DATA_ROOT/input"
CONFIG="$RUN_ROOT/config_imerg_mcs_tbpf_daskmpi.yml"
SCHEDULER_FILE="$RUN_ROOT/scheduler_${SLURM_JOB_ID:-manual}.json"
N_WORKERS=8

mkdir -p "$RUN_ROOT" "$INPUT_DIR"

if [ ! -x "$ENV/bin/python" ]; then
  echo "ERROR: missing PyFLEXTRKR environment at $ENV" >&2
  exit 1
fi

if ! tar -tzf "$INPUT_DIR/gpm_tb_imerg.tar.gz" >/dev/null 2>&1; then
  curl -L --fail --retry 5 --retry-all-errors -C - \
    https://portal.nersc.gov/project/m1867/PyFLEXTRKR/sample_data/tb_pcp/gpm_tb_imerg.tar.gz \
    -o "$INPUT_DIR/gpm_tb_imerg.tar.gz"
fi

tar -tzf "$INPUT_DIR/gpm_tb_imerg.tar.gz" >/dev/null

if ! find "$INPUT_DIR" -maxdepth 1 -type f -name 'merg_*.nc' | grep -q .; then
  tar -xzf "$INPUT_DIR/gpm_tb_imerg.tar.gz" -C "$INPUT_DIR"
fi

sed \
  -e "s#INPUT_DIR/#$INPUT_DIR/#g" \
  -e "s#TRACK_DIR/#$RUN_ROOT/#g" \
  -e "s#run_parallel: 1#run_parallel: 2#g" \
  -e "s#nprocesses : 8#nprocesses : $N_WORKERS#g" \
  -e "s#timeout: 360#timeout: 900#g" \
  "$REPO/config/config_imerg_mcs_tbpf_example.yml" > "$CONFIG"

export PATH="$ENV/bin:$PATH"
export PYTHONPATH="$REPO:${PYTHONPATH:-}"
export DASK_DISTRIBUTED__COMM__TIMEOUTS__CONNECT=360s
export DASK_DISTRIBUTED__COMM__TIMEOUTS__TCP=360s
export OMPI_MCA_btl="^openib"
ulimit -n 32000 || true

rm -f "$SCHEDULER_FILE"

mpirun -np "$SLURM_NTASKS" dask-mpi \
  --scheduler-file="$SCHEDULER_FILE" \
  --nthreads=1 \
  --memory-limit=auto \
  --worker-class distributed.Worker \
  --local-directory="${TMPDIR:-/tmp}" &
DASK_MPI_PID=$!

cleanup() {
  if kill -0 "$DASK_MPI_PID" 2>/dev/null; then
    kill "$DASK_MPI_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

for _ in $(seq 1 120); do
  if [ -s "$SCHEDULER_FILE" ]; then
    break
  fi
  sleep 1
done

if [ ! -s "$SCHEDULER_FILE" ]; then
  echo "ERROR: dask-mpi did not create scheduler file $SCHEDULER_FILE" >&2
  exit 1
fi

cd "$REPO"
"$ENV/bin/python" "$REPO/runscripts/run_mcs_tbpf.py" "$CONFIG" "$SCHEDULER_FILE" "$N_WORKERS"

if ! find "$RUN_ROOT/stats" -type f \( -name 'mcs_tracks_robust_*.nc' -o -name 'mcs_tracks_final_*.nc' -o -name 'trackstats_*.nc' \) -size +0 -print -quit | grep -q .; then
  echo "ERROR: missing non-empty PyFLEXTRKR stats outputs" >&2
  exit 1
fi

if ! find "$RUN_ROOT/mcstracking" -type f -name '*.nc' -size +0 -print -quit | grep -q .; then
  echo "ERROR: missing non-empty PyFLEXTRKR pixel tracking outputs" >&2
  exit 1
fi

OUTPUT_COUNT="$(find "$RUN_ROOT" -type f -size +0 | wc -l)"
if [ "$OUTPUT_COUNT" -lt 20 ]; then
  echo "ERROR: too few non-empty PyFLEXTRKR outputs: $OUTPUT_COUNT" >&2
  exit 1
fi

echo "PyFLEXTRKR single-node dask-mpi baseline completed with $OUTPUT_COUNT non-empty output files"
