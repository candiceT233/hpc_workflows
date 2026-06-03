#!/usr/bin/env bash
#SBATCH --job-name=chipseq-single
#SBATCH --exclusive
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=40
#SBATCH --time=48:00:00
#SBATCH --output=runs/chipseq/slurm-%j-single.out
#SBATCH --error=runs/chipseq/slurm-%j-single.err

set -euo pipefail

if [[ -n "${WORKFLOW_ROOT:-}" ]]; then
  ROOT="$WORKFLOW_ROOT"
elif [[ -f "$SLURM_SUBMIT_DIR/table.md" && -d "$SLURM_SUBMIT_DIR/scripts" ]]; then
  ROOT="$SLURM_SUBMIT_DIR"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

cd "$ROOT"
RUN_ROOT="$ROOT/runs/chipseq"
RUN_DIR="$RUN_ROOT/single-${SLURM_JOB_ID:-manual}"
REPO="$RUN_DIR/repo"
CONDA_PREFIX_DIR="$ROOT/tools/conda-envs/chipseq"
SNAKEMAKE_CORES="${CHIPSEQ_SNAKEMAKE_CORES:-8}"
mkdir -p "$RUN_ROOT" "$RUN_DIR" "$CONDA_PREFIX_DIR" "$ROOT/tools/conda-pkgs"

export PATH="$ROOT/tools/miniforge/bin:$ROOT/tools/snakemake-venv/bin:$PATH"
export CONDA_PKGS_DIRS="$ROOT/tools/conda-pkgs"
export SNAKEMAKE_OUTPUT_CACHE="$ROOT/tools/snakemake-cache"
export CONDA_CHANNEL_PRIORITY=flexible

conda config --set channel_priority flexible >/dev/null

find "$CONDA_PREFIX_DIR" -mindepth 1 -maxdepth 1 -type d \
  ! -exec test -d "{}/conda-meta" \; -print -exec rm -rf {} +

rm -rf "$REPO"
if ! cp -a --reflink=auto "$ROOT/repos/chipseq" "$REPO" 2>/dev/null; then
  cp -a "$ROOT/repos/chipseq" "$REPO"
fi
rm -rf "$REPO/.snakemake" "$REPO/results" "$REPO/logs"
ln -sfn "$REPO/config" "$RUN_DIR/config"
awk -v root="$ROOT" 'BEGIN{FS=OFS="\t"} NR==1{print; next} {n=split($5, parts, "/"); $5=root "/data/chipseq/full/fastq/" parts[n]; print}' \
  "$REPO/config_codex_full/units.tsv" > "$REPO/config_codex_full/units.tsv.tmp"
mv "$REPO/config_codex_full/units.tsv.tmp" "$REPO/config_codex_full/units.tsv"

cd "$REPO"

snakemake \
  --snakefile workflow/Snakefile \
  --configfile config_codex_full/config.yaml \
  --use-conda \
  --conda-frontend conda \
  --conda-prefix "$CONDA_PREFIX_DIR" \
  --cores "$SNAKEMAKE_CORES" \
  --printshellcmds \
  --rerun-incomplete \
  --latency-wait 120

find results logs resources/ref -type f -size +0c 2>/dev/null | sort > "$RUN_DIR/nonempty-files.txt"
test -s "$RUN_DIR/nonempty-files.txt"
find results -type f -size +0c 2>/dev/null | sort > "$RUN_DIR/nonempty-results.txt"
test -s "$RUN_DIR/nonempty-results.txt"
echo "chipseq native Snakemake single-node workflow completed"
