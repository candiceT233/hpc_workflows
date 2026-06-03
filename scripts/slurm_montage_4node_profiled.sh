#!/bin/bash
#SBATCH --job-name=montage-prof
#SBATCH --exclusive
#SBATCH --partition=compute
#SBATCH --nodes=4
#SBATCH --ntasks=4
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=40
#SBATCH --time=12:00:00
#SBATCH --output=runs/Montage/slurm-%j-4node-profiled.out
#SBATCH --error=runs/Montage/slurm-%j-4node-profiled.err

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
export PATH="$ROOT/repos/Montage/bin:$PATH"

SCALE="${MONTAGE_SCALE:-small}"
DATA_DIR="$ROOT/data/Montage/${SCALE}"
RAW_DIR="$DATA_DIR/raw_images"
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

FITS_COUNT="$(find "$RAW_DIR" -maxdepth 1 -type f -name '*.fits' | wc -l)"
if [ "$FITS_COUNT" -lt 2 ]; then
  echo "ERROR: expected at least two FITS inputs in $RAW_DIR; found $FITS_COUNT" >&2
  exit 1
fi

if [ ! -s "$DATA_DIR/region.hdr" ]; then
  mImgtbl "$RAW_DIR" "$DATA_DIR/images.tbl"
  mMakeHdr "$DATA_DIR/images.tbl" "$DATA_DIR/region.hdr"
fi

RUN_ROOT="$ROOT/runs/Montage/4node-profiled-${SLURM_JOB_ID:-manual}"
rm -rf "$RUN_ROOT"
mkdir -p "$RUN_ROOT"/{datalife,darshan,traces/datalife,traces/darshan,parsed} "$ROOT/runs/Montage"

cat > "$RUN_ROOT/run_profile_replica.sh" <<'EOS'
#!/bin/bash
set -euo pipefail
rank="${SLURM_PROCID:-0}"
root="$WORKFLOW_ROOT"
scale="${MONTAGE_SCALE:-small}"
mode="$MONTAGE_PROFILE_MODE"
replica_dir="$MONTAGE_PASS_ROOT/replica-${rank}"
trace_dir="$MONTAGE_TRACE_ROOT/replica-${rank}"
mkdir -p "$replica_dir/outputs" "$replica_dir/logs" "$trace_dir"
export MONTAGE_OUT_DIR="$replica_dir/outputs"
export MONTAGE_LOG_DIR="$replica_dir/logs"
if [ "$mode" = "datalife" ]; then
  env MONTAGE_PROFILE_MODE=datalife \
    MONTAGE_TRACE_DIR="$trace_dir" \
    MONTAGE_DATALIFE_FILE_PATTERNS="*.fits,*.tbl,*.hdr,*.log" \
    DATALIFE_LIB="$DATALIFE_LIB" \
    bash "$root/scripts/run_montage.sh" "$scale"
else
  env MONTAGE_PROFILE_MODE=darshan \
    MONTAGE_TRACE_DIR="$trace_dir" \
    DARSHAN_LIB="$DARSHAN_LIB" \
    bash "$root/scripts/run_montage.sh" "$scale"
fi
mosaic="$MONTAGE_OUT_DIR/mosaic.fits"
test -s "$mosaic"
bytes="$(stat --printf='%s' "$mosaic")"
if [ "$bytes" -lt 1000000 ]; then
  echo "ERROR: replica $rank $mode mosaic too small: $bytes bytes" >&2
  exit 1
fi
echo "${mode} replica ${rank} completed: ${mosaic} (${bytes} bytes)"
EOS
chmod +x "$RUN_ROOT/run_profile_replica.sh"

run_profile_pass() {
  local mode="$1"
  export MONTAGE_PROFILE_MODE="$mode"
  export MONTAGE_PASS_ROOT="$RUN_ROOT/$mode"
  export MONTAGE_TRACE_ROOT="$RUN_ROOT/traces/$mode"
  mkdir -p "$MONTAGE_PASS_ROOT" "$MONTAGE_TRACE_ROOT"
  srun -u -n "$SLURM_NTASKS" --ntasks-per-node=1 \
    --export=ALL,WORKFLOW_ROOT="$ROOT",MONTAGE_SCALE="$SCALE",MONTAGE_PROFILE_MODE="$mode",MONTAGE_PASS_ROOT="$MONTAGE_PASS_ROOT",MONTAGE_TRACE_ROOT="$MONTAGE_TRACE_ROOT",DATALIFE_LIB="$DATALIFE_LIB",DARSHAN_LIB="$DARSHAN_LIB" \
    "$RUN_ROOT/run_profile_replica.sh"

  local mosaic_count
  mosaic_count="$(find "$MONTAGE_PASS_ROOT" -path '*/outputs/mosaic.fits' -type f -size +1000000c | wc -l)"
  if [ "$mosaic_count" -ne 4 ]; then
    echo "ERROR: expected 4 non-trivial ${mode} Montage mosaics, found $mosaic_count" >&2
    exit 3
  fi
  find "$MONTAGE_PASS_ROOT" -path '*/outputs/mosaic.fits' -type f -printf '%s %p\n' | sort -nr > "$RUN_ROOT/${mode}-mosaics.txt"
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
cat "$RUN_ROOT/datalife-mosaics.txt"
cat "$RUN_ROOT/darshan-mosaics.txt"
cat "$RUN_ROOT/trace-summary.tsv"

echo "Montage native 4-node profiled shell/C workflow completed."
