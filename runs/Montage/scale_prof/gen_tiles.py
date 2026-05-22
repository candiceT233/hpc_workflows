#!/usr/bin/env python3
"""Generate N synthetic FITS tiles + one shared Montage template.hdr.

Each tile is a 512x512 float64 image (~2.0 MB on disk) with a valid WCS that is
*identical* across all tiles (only the pixel data differs, by seed).  mProjectPP
reprojects each tile against the shared template.hdr -> one output tile + area
file.  This is the I/O-heavy / compute-light Montage reprojection stage, fanned
out one process per tile.

Usage: gen_tiles.py <out_dir> <n_tiles> [n_procs]
  6 GB  set: n_tiles=3000   (3000 * ~2.005 MB ~= 6.0 GB)
  30 GB set: n_tiles=15000  (15000 * ~2.005 MB ~= 30.1 GB)
"""
import os, sys
import numpy as np
from multiprocessing import Pool

NX, NY, CDELT = 512, 512, 0.001
CRVAL1, CRVAL2 = 275.2, -16.17
CRPIX1, CRPIX2 = NX / 2.0 + 0.5, NY / 2.0 + 0.5


def _card(key, val, comment=""):
    if isinstance(val, bool):
        body = f"{key:<8}= {('T' if val else 'F'):>20} / {comment}"
    elif isinstance(val, int):
        body = f"{key:<8}= {val:>20d} / {comment}"
    elif isinstance(val, float):
        body = f"{key:<8}= {val:>20.10E} / {comment}"
    else:
        body = f"{key:<8}= '{val:<8}' / {comment}"
    return f"{body:<80}"

CARDS = [
    _card("SIMPLE", True, "Standard FITS"),
    _card("BITPIX", -64, "64-bit floating point"),
    _card("NAXIS", 2, "Number of axes"),
    _card("NAXIS1", NX, "Width"),
    _card("NAXIS2", NY, "Height"),
    _card("CTYPE1", "RA---TAN", "Projection type"),
    _card("CTYPE2", "DEC--TAN", "Projection type"),
    _card("CRVAL1", float(CRVAL1), "Reference RA"),
    _card("CRVAL2", float(CRVAL2), "Reference DEC"),
    _card("CRPIX1", float(CRPIX1), "Reference pixel X"),
    _card("CRPIX2", float(CRPIX2), "Reference pixel Y"),
    _card("CDELT1", float(-CDELT), "Pixel scale RA"),
    _card("CDELT2", float(CDELT), "Pixel scale DEC"),
    _card("EQUINOX", 2000.0, "Equinox"),
]

def _fits_header_bytes():
    h = "".join(CARDS) + f"{'END':<80}"
    rem = len(h) % 2880
    if rem:
        h += " " * (2880 - rem)
    return h.encode("ascii")

HDR = _fits_header_bytes()

def write_template(out_dir):
    # Montage .hdr template: plain-text FITS cards, one per line, terminated by END.
    lines = [c.rstrip() for c in CARDS] + ["END"]
    with open(os.path.join(out_dir, "template.hdr"), "w") as f:
        f.write("\n".join(lines) + "\n")

def write_tile(args):
    idx, out_dir = args
    fname = os.path.join(out_dir, f"tile_{idx:06d}.fits")
    rng = np.random.RandomState(idx + 1)
    x = np.arange(NX, dtype=np.float64)
    y = np.arange(NY, dtype=np.float64)
    xx, yy = np.meshgrid(x, y)
    data = 100.0 + 20.0 * np.sin(xx / 30.0) * np.cos(yy / 30.0) + rng.normal(0, 2, (NY, NX))
    b = data.astype(">f8").tobytes()
    rem = len(b) % 2880
    if rem:
        b += b"\x00" * (2880 - rem)
    with open(fname, "wb") as f:
        f.write(HDR)
        f.write(b)
    return idx

def main():
    out_dir = sys.argv[1]
    n = int(sys.argv[2])
    nproc = int(sys.argv[3]) if len(sys.argv) > 3 else os.cpu_count()
    os.makedirs(out_dir, exist_ok=True)
    write_template(out_dir)
    work = [(i, out_dir) for i in range(n)]
    done = 0
    with Pool(nproc) as p:
        for _ in p.imap_unordered(write_tile, work, chunksize=16):
            done += 1
            if done % 1000 == 0:
                print(f"  {done}/{n} tiles", flush=True)
    print(f"DONE: {n} tiles -> {out_dir} (template.hdr written)", flush=True)

if __name__ == "__main__":
    main()
