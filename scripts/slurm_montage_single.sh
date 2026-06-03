#!/bin/bash
#SBATCH --job-name=montage-single
#SBATCH --exclusive
#SBATCH --partition=compute
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=40
#SBATCH --time=12:00:00
#SBATCH --output=runs/Montage/slurm-%j-single.out
#SBATCH --error=runs/Montage/slurm-%j-single.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
export WORKFLOW_ROOT="$ROOT"
export PATH="$ROOT/repos/Montage/bin:$PATH"

SCALE="${MONTAGE_SCALE:-small}"
DATA_DIR="$ROOT/data/Montage/${SCALE}"
RAW_DIR="$DATA_DIR/raw_images"
OUT_DIR="$ROOT/runs/Montage/${SCALE}/outputs"
LOG_DIR="$ROOT/runs/Montage/${SCALE}/logs"

mkdir -p "$RAW_DIR" "$OUT_DIR" "$LOG_DIR" "$ROOT/runs/Montage"

FITS_COUNT="$(find "$RAW_DIR" -maxdepth 1 -type f -name '*.fits' | wc -l)"
if [ "$FITS_COUNT" -lt 2 ]; then
  echo "ERROR: expected at least two FITS inputs in $RAW_DIR; found $FITS_COUNT" >&2
  exit 1
fi

if [ ! -s "$DATA_DIR/region.hdr" ]; then
  mImgtbl "$RAW_DIR" "$DATA_DIR/images.tbl"
  mMakeHdr "$DATA_DIR/images.tbl" "$DATA_DIR/region.hdr"
fi

bash "$ROOT/scripts/run_montage.sh" "$SCALE"

MOSAIC="$OUT_DIR/mosaic.fits"
if [ ! -s "$MOSAIC" ]; then
  echo "ERROR: missing/non-empty terminal mosaic: $MOSAIC" >&2
  exit 1
fi

BYTES="$(stat --printf='%s' "$MOSAIC")"
if [ "$BYTES" -lt 1000000 ]; then
  echo "ERROR: mosaic too small to count as non-trivial output: $BYTES bytes" >&2
  exit 1
fi

echo "Montage single-node native shell/C baseline completed: $MOSAIC ($BYTES bytes)"
