#!/bin/bash
#SBATCH --job-name=montage-4node
#SBATCH --exclusive
#SBATCH --partition=compute
#SBATCH --nodes=4
#SBATCH --ntasks=4
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=40
#SBATCH --time=12:00:00
#SBATCH --output=runs/Montage/slurm-%j-4node.out
#SBATCH --error=runs/Montage/slurm-%j-4node.err

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
RUN_ROOT="$ROOT/runs/Montage/4node-${SLURM_JOB_ID}"
mkdir -p "$RUN_ROOT" "$ROOT/runs/Montage"

FITS_COUNT="$(find "$RAW_DIR" -maxdepth 1 -type f -name '*.fits' | wc -l)"
if [ "$FITS_COUNT" -lt 2 ]; then
  echo "ERROR: expected at least two FITS inputs in $RAW_DIR; found $FITS_COUNT" >&2
  exit 1
fi

if [ ! -s "$DATA_DIR/region.hdr" ]; then
  mImgtbl "$RAW_DIR" "$DATA_DIR/images.tbl"
  mMakeHdr "$DATA_DIR/images.tbl" "$DATA_DIR/region.hdr"
fi

cat > "$RUN_ROOT/run_replica.sh" <<'EOS'
#!/bin/bash
set -euo pipefail
rank="${SLURM_PROCID:-0}"
root="$WORKFLOW_ROOT"
scale="${MONTAGE_SCALE:-small}"
replica_dir="$MONTAGE_RUN_ROOT/replica-${rank}"
mkdir -p "$replica_dir/outputs" "$replica_dir/logs"
export MONTAGE_OUT_DIR="$replica_dir/outputs"
export MONTAGE_LOG_DIR="$replica_dir/logs"
bash "$root/scripts/run_montage.sh" "$scale"
mosaic="$MONTAGE_OUT_DIR/mosaic.fits"
test -s "$mosaic"
bytes="$(stat --printf='%s' "$mosaic")"
if [ "$bytes" -lt 1000000 ]; then
  echo "ERROR: replica $rank mosaic too small: $bytes bytes" >&2
  exit 1
fi
echo "replica ${rank} completed: ${mosaic} (${bytes} bytes)"
EOS
chmod +x "$RUN_ROOT/run_replica.sh"

export MONTAGE_RUN_ROOT="$RUN_ROOT"
srun -u -n "$SLURM_NTASKS" --ntasks-per-node=1 "$RUN_ROOT/run_replica.sh"

mosaic_count="$(find "$RUN_ROOT" -path '*/outputs/mosaic.fits' -type f -size +1000000c | wc -l)"
if [ "$mosaic_count" -ne 4 ]; then
  echo "ERROR: expected 4 non-trivial Montage mosaics, found $mosaic_count" >&2
  exit 1
fi

find "$RUN_ROOT" -path '*/outputs/mosaic.fits' -type f -printf '%s %p\n' | sort -nr > "$RUN_ROOT/mosaics.txt"
cat "$RUN_ROOT/mosaics.txt"

echo "Montage native 4-node shell/C baseline completed."
