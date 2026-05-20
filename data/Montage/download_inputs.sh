#!/bin/bash
# Download script for Montage input data
# Source repo: /mnt/common/mtang11/hpc_workflows/repos/Montage/
#
# Montage creates astronomical image mosaics from FITS files.
# Since direct IRSA archive downloads require specific image IDs,
# we generate synthetic FITS files with valid WCS headers for testing.
#
# small:  4 overlapping 256x256 FITS tiles (~2 MB) - M17 region
# medium: 25 overlapping 512x512 FITS tiles (~70 MB) - M31 region, 5x5 grid for 24-node sweep

set -e

DATA_DIR="/mnt/common/mtang11/hpc_workflows/data/Montage"
SMALL_DIR="${DATA_DIR}/small"
MEDIUM_DIR="${DATA_DIR}/medium"

echo "=== Montage: Preparing datasets ==="
mkdir -p "${SMALL_DIR}/raw_images"
mkdir -p "${MEDIUM_DIR}/raw_images"

# Create region header for small dataset
cat > "${SMALL_DIR}/region.hdr" << 'HEADER'
SIMPLE  = T
BITPIX  = -64
NAXIS   = 2
NAXIS1  = 512
NAXIS2  = 512
CTYPE1  = 'RA---TAN'
CTYPE2  = 'DEC--TAN'
CRVAL1  = 275.2
CRVAL2  = -16.17
CRPIX1  = 256.5
CRPIX2  = 256.5
CDELT1  = -0.001
CDELT2  = 0.001
EQUINOX = 2000.0
END
HEADER

# Create region header for medium dataset
cat > "${MEDIUM_DIR}/region.hdr" << 'HEADER'
SIMPLE  = T
BITPIX  = -64
NAXIS   = 2
NAXIS1  = 2400
NAXIS2  = 2400
CTYPE1  = 'RA---TAN'
CTYPE2  = 'DEC--TAN'
CRVAL1  = 10.6847
CRVAL2  = 41.2688
CRPIX1  = 1200.5
CRPIX2  = 1200.5
CDELT1  = -0.001
CDELT2  = 0.001
EQUINOX = 2000.0
END
HEADER

# Generate synthetic FITS tiles using numpy for speed
echo "Generating synthetic FITS test data..."
python3 << 'PYEOF'
import os
import numpy as np

def write_fits(filename, ra, dec, nx=256, ny=256, cdelt=0.001):
    """Write a minimal valid FITS file with WCS headers using numpy."""
    cards = []
    def add(key, val, comment=""):
        if isinstance(val, bool):
            v = "T" if val else "F"
            card = f"{key:<8}= {v:>20} / {comment}"
        elif isinstance(val, int):
            card = f"{key:<8}= {val:>20d} / {comment}"
        elif isinstance(val, float):
            card = f"{key:<8}= {val:>20.10E} / {comment}"
        elif isinstance(val, str):
            card = f"{key:<8}= '{val:<8}' / {comment}"
        cards.append(card)

    add("SIMPLE", True, "Standard FITS")
    add("BITPIX", -64, "64-bit floating point")
    add("NAXIS", 2, "Number of axes")
    add("NAXIS1", nx, "Width")
    add("NAXIS2", ny, "Height")
    add("CTYPE1", "RA---TAN", "Projection type")
    add("CTYPE2", "DEC--TAN", "Projection type")
    add("CRVAL1", ra, "Reference RA")
    add("CRVAL2", dec, "Reference DEC")
    add("CRPIX1", float(nx//2), "Reference pixel X")
    add("CRPIX2", float(ny//2), "Reference pixel Y")
    add("CDELT1", -cdelt, "Pixel scale RA")
    add("CDELT2", cdelt, "Pixel scale DEC")
    add("EQUINOX", 2000.0, "Equinox")
    cards.append("END")

    header = ""
    for c in cards:
        header += f"{c:<80}"
    remainder = len(header) % 2880
    if remainder:
        header += " " * (2880 - remainder)

    np.random.seed(42 + int(ra*100) + int(dec*100))
    x = np.arange(nx, dtype=np.float64)
    y = np.arange(ny, dtype=np.float64)
    xx, yy = np.meshgrid(x, y)
    data = 100.0 + 20.0 * np.sin(xx/30.0) * np.cos(yy/30.0) + np.random.normal(0, 2, (ny, nx))
    data_bytes = data.astype('>f8').tobytes()

    remainder = len(data_bytes) % 2880
    if remainder:
        data_bytes += b"\x00" * (2880 - remainder)

    with open(filename, "wb") as f:
        f.write(header.encode("ascii"))
        f.write(data_bytes)

# Small: 4 overlapping 256x256 tiles (M17 region)
small_dir = "/mnt/common/mtang11/hpc_workflows/data/Montage/small/raw_images"
base_ra, base_dec = 275.2, -16.17
for idx, (dra, ddec) in enumerate([(0,0),(0.2,0),(0,0.2),(0.2,0.2)]):
    fname = os.path.join(small_dir, f"tile_{idx:03d}.fits")
    write_fits(fname, base_ra+dra, base_dec+ddec, nx=256, ny=256)
    print(f"Created {fname}")

# Medium: 5x5 grid of 512x512 tiles (M31/Andromeda region) -- 25 tiles for 24-node sweep
med_dir = "/mnt/common/mtang11/hpc_workflows/data/Montage/medium/raw_images"
base_ra, base_dec = 10.6847, 41.2688
for row in range(5):
    for col in range(5):
        ra = base_ra + (col - 2) * 0.4
        dec = base_dec + (row - 2) * 0.4
        fname = os.path.join(med_dir, f"tile_{row:02d}_{col:02d}.fits")
        write_fits(fname, ra, dec, nx=512, ny=512)
        print(f"Created {fname}")

PYEOF

echo "=== Montage: Generation complete ==="
du -sh "${SMALL_DIR}" "${MEDIUM_DIR}"
