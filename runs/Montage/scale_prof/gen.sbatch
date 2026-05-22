#!/bin/bash
#SBATCH --job-name=mtg_gen
#SBATCH --account=oddite
#SBATCH --partition=slurm
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=32
#SBATCH --time=00:30:00
# Generate synthetic Montage FITS tiles on a compute node.
# Env: OUT_DIR (target), N_TILES.
set -eu
source /share/apps/python/miniconda25.5.1/etc/profile.d/conda.sh
conda activate base
ROOT=/qfs/projects/datamesh/tang584/widget_evaluation/hpc_workflows/runs/Montage/scale_prof
echo "host=$(hostname) generating N_TILES=$N_TILES -> $OUT_DIR"
time python3 "$ROOT/gen_tiles.py" "$OUT_DIR" "$N_TILES" 32
echo "size: $(du -sh "$OUT_DIR" | cut -f1)  files: $(ls "$OUT_DIR"/tile_*.fits | wc -l)"
