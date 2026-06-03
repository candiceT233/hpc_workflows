#!/usr/bin/env bash
#SBATCH --job-name=chipseq-4node
#SBATCH --exclusive
#SBATCH --partition=compute
#SBATCH --nodes=4
#SBATCH --ntasks=4
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/chipseq/slurm-%j-4node.out
#SBATCH --error=runs/chipseq/slurm-%j-4node.err

set -euo pipefail

if [[ -n "${WORKFLOW_ROOT:-}" ]]; then
  ROOT="$WORKFLOW_ROOT"
elif [[ -f "$SLURM_SUBMIT_DIR/table.md" && -d "$SLURM_SUBMIT_DIR/scripts" ]]; then
  ROOT="$SLURM_SUBMIT_DIR"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

RUN_ROOT="$ROOT/runs/chipseq"
RUN_DIR="$RUN_ROOT/4node-${SLURM_JOB_ID:-manual}"
CONDA_PREFIX_DIR="$ROOT/tools/conda-envs/chipseq"
SNAKEMAKE_CORES="${CHIPSEQ_SNAKEMAKE_CORES:-8}"
mkdir -p "$RUN_ROOT" "$RUN_DIR" "$CONDA_PREFIX_DIR" "$ROOT/tools/conda-pkgs"
cd "$ROOT"

export PATH="$ROOT/tools/miniforge/bin:$ROOT/tools/snakemake-venv/bin:$PATH"
export CONDA_PKGS_DIRS="$ROOT/tools/conda-pkgs"
export SNAKEMAKE_OUTPUT_CACHE="$ROOT/tools/snakemake-cache"
export CONDA_CHANNEL_PRIORITY=flexible

conda config --set channel_priority flexible >/dev/null

find "$CONDA_PREFIX_DIR" -mindepth 1 -maxdepth 1 -type d \
  ! -exec test -d "{}/conda-meta" \; -print -exec rm -rf {} +

prepare_replica() {
  local replica="$1"
  local rep_dir="$RUN_DIR/replica-${replica}"
  local repo="$rep_dir/repo"

  rm -rf "$repo"
  mkdir -p "$rep_dir"
  if ! cp -a --reflink=auto "$ROOT/repos/chipseq" "$repo" 2>/dev/null; then
    cp -a "$ROOT/repos/chipseq" "$repo"
  fi
  rm -rf "$repo/.snakemake" "$repo/results" "$repo/logs"
  ln -sfn "$repo/config" "$rep_dir/config"
  awk -v root="$ROOT" 'BEGIN{FS=OFS="\t"} NR==1{print; next} {n=split($5, parts, "/"); $5=root "/data/chipseq/full/fastq/" parts[n]; print}' \
    "$repo/config_codex_full/units.tsv" > "$repo/config_codex_full/units.tsv.tmp"
  mv "$repo/config_codex_full/units.tsv.tmp" "$repo/config_codex_full/units.tsv"
}

run_replica() {
  local replica="$1"
  local rep_dir="$RUN_DIR/replica-${replica}"
  local repo="$rep_dir/repo"

  cd "$repo"
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

  find results logs resources/ref -type f -size +0c 2>/dev/null | sort > "$rep_dir/nonempty-files.txt"
  test -s "$rep_dir/nonempty-files.txt"
  find results -type f -size +0c 2>/dev/null | sort > "$rep_dir/nonempty-results.txt"
  test -s "$rep_dir/nonempty-results.txt"
  echo "chipseq replica $replica native Snakemake workflow completed"
}

if [[ "${1:-}" == "worker" ]]; then
  run_replica "$2"
  exit 0
fi

for replica in 0 1 2 3; do
  prepare_replica "$replica"
done

cd "$RUN_DIR/replica-0/repo"
snakemake \
  --snakefile workflow/Snakefile \
  --configfile config_codex_full/config.yaml \
  --use-conda \
  --conda-frontend conda \
  --conda-prefix "$CONDA_PREFIX_DIR" \
  --cores 1 \
  --conda-create-envs-only \
  --rerun-incomplete \
  --latency-wait 120

cd "$ROOT"
for replica in 0 1 2 3; do
  srun --exclusive --nodes=1 --ntasks=1 --cpus-per-task="${SLURM_CPUS_PER_TASK:-40}" \
    "$0" worker "$replica" > "$RUN_DIR/replica-${replica}.out" 2> "$RUN_DIR/replica-${replica}.err" &
done
wait

for replica in 0 1 2 3; do
  test -s "$RUN_DIR/replica-${replica}/nonempty-results.txt"
done

echo "chipseq native 4-node Snakemake workflow completed across 4 nodes"
