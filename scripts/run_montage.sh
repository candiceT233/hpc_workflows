#!/bin/bash
# Montage mosaic pipeline script
# Usage: run_montage.sh <scale> (small|medium)
set -euo pipefail

SCALE="${1:-small}"
WORKFLOW_ROOT="/mnt/common/mtang11/hpc_workflows"
MONTAGE_BIN="$WORKFLOW_ROOT/repos/Montage/bin"
DATA_DIR="$WORKFLOW_ROOT/data/Montage/${SCALE}"
OUT_DIR="$WORKFLOW_ROOT/runs/Montage/${SCALE}/outputs"
LOG_DIR="$WORKFLOW_ROOT/runs/Montage/${SCALE}/logs"

export PATH="$MONTAGE_BIN:$PATH"

RUNLOG="$LOG_DIR/montage_run.log"
exec > >(tee -a "$RUNLOG") 2>&1

echo "=== Montage Pipeline: scale=$SCALE ==="
echo "Start: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "Data dir: $DATA_DIR"
echo "Output dir: $OUT_DIR"

RAW_DIR="$DATA_DIR/raw_images"
HDR_FILE="$DATA_DIR/region.hdr"
PROJ_DIR="$OUT_DIR/projected"
DIFF_DIR="$OUT_DIR/diffs"
CORR_DIR="$OUT_DIR/corrected"

# Validate inputs
if [ ! -f "$HDR_FILE" ]; then
    echo "ERROR: Header file not found: $HDR_FILE"
    exit 1
fi
FITS_COUNT=$(ls "$RAW_DIR"/*.fits 2>/dev/null | wc -l)
if [ "$FITS_COUNT" -eq 0 ]; then
    echo "ERROR: No FITS files found in $RAW_DIR"
    exit 1
fi
echo "Found $FITS_COUNT FITS files"

# Create working directories
mkdir -p "$PROJ_DIR" "$DIFF_DIR" "$CORR_DIR"

# Step 1: mImgtbl - Create image metadata table
echo ""
echo "--- Step 1: mImgtbl ---"
mImgtbl "$RAW_DIR" "$OUT_DIR/images.tbl"
echo "mImgtbl completed: $(wc -l < "$OUT_DIR/images.tbl") lines in images.tbl"

# Step 2: mProjExec - Reproject all images
echo ""
echo "--- Step 2: mProjExec ---"
mProjExec -p "$RAW_DIR" "$OUT_DIR/images.tbl" "$HDR_FILE" "$PROJ_DIR" "$OUT_DIR/stats.tbl"
echo "mProjExec completed"

# Step 3: mImgtbl on projected images
echo ""
echo "--- Step 3: mImgtbl (projected) ---"
mImgtbl "$PROJ_DIR" "$OUT_DIR/proj_images.tbl"
echo "Projected image table created"

# Step 4: mOverlaps - Find overlapping images
echo ""
echo "--- Step 4: mOverlaps ---"
mOverlaps "$OUT_DIR/proj_images.tbl" "$OUT_DIR/diffs.tbl"
echo "mOverlaps completed"

# Step 5: mDiffExec - Compute difference images
echo ""
echo "--- Step 5: mDiffExec ---"
mDiffExec -p "$PROJ_DIR" "$OUT_DIR/diffs.tbl" "$HDR_FILE" "$DIFF_DIR"
echo "mDiffExec completed"

# Step 6: mFitExec - Fit planes to differences
echo ""
echo "--- Step 6: mFitExec ---"
mFitExec "$OUT_DIR/diffs.tbl" "$OUT_DIR/fits.tbl" "$DIFF_DIR"
echo "mFitExec completed"

# Step 7: mBgModel - Model background corrections
echo ""
echo "--- Step 7: mBgModel ---"
mBgModel "$OUT_DIR/proj_images.tbl" "$OUT_DIR/fits.tbl" "$OUT_DIR/corrections.tbl"
echo "mBgModel completed"

# Step 8: mBgExec - Apply background corrections
echo ""
echo "--- Step 8: mBgExec ---"
mBgExec -p "$PROJ_DIR" "$OUT_DIR/proj_images.tbl" "$OUT_DIR/corrections.tbl" "$CORR_DIR"
echo "mBgExec completed"

# Step 9: mImgtbl on corrected images
echo ""
echo "--- Step 9: mImgtbl (corrected) ---"
mImgtbl "$CORR_DIR" "$OUT_DIR/corr_images.tbl"
echo "Corrected image table created"

# Step 10: mAdd - Co-add corrected images into final mosaic
echo ""
echo "--- Step 10: mAdd ---"
mAdd -p "$CORR_DIR" "$OUT_DIR/corr_images.tbl" "$HDR_FILE" "$OUT_DIR/mosaic.fits"
echo "mAdd completed"

# Validate output
echo ""
echo "=== Output Validation ==="
if [ -f "$OUT_DIR/mosaic.fits" ]; then
    FSIZE=$(stat --printf="%s" "$OUT_DIR/mosaic.fits")
    echo "SUCCESS: mosaic.fits created (${FSIZE} bytes)"
else
    echo "FAILURE: mosaic.fits not found"
    exit 1
fi

echo ""
echo "End: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "=== Pipeline Complete ==="
