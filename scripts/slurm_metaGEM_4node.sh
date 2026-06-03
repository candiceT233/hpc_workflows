#!/usr/bin/env bash
#SBATCH --job-name=metaGEM-4node
#SBATCH --exclusive
#SBATCH --partition=compute
#SBATCH --nodes=4
#SBATCH --ntasks=4
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/metaGEM/slurm-%j-4node.out
#SBATCH --error=runs/metaGEM/slurm-%j-4node.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

REPO="$ROOT/repos/metaGEM"
RUN_ROOT="$ROOT/runs/metaGEM"
RUN_DIR="$RUN_ROOT/4node-${SLURM_JOB_ID:-manual}"
DATA_ROOT="$ROOT/data/metaGEM/full"
ENV_ROOT="$ROOT/tools/conda-envs/metagem-fastp"

mkdir -p "$RUN_ROOT" "$RUN_DIR" "$DATA_ROOT" "$ROOT/tools/conda-pkgs"
cd "$ROOT"

export PATH="$ROOT/tools/miniforge/bin:$PATH"
export CONDA_PKGS_DIRS="$ROOT/tools/conda-pkgs"

download_fastq() {
  local url="$1"
  local dest="$2"
  local tmp="${dest}.part"
  local attempt

  if [ -s "$dest" ] && gzip -t "$dest" >/dev/null 2>&1; then
    return 0
  fi
  if [ -s "$dest" ] && [ ! -s "$tmp" ]; then
    mv "$dest" "$tmp"
  fi

  for attempt in $(seq 1 20); do
    if curl -L --fail --retry 8 --retry-delay 20 --retry-all-errors --continue-at - -o "$tmp" "$url" \
      && gzip -t "$tmp" >/dev/null 2>&1; then
      mv "$tmp" "$dest"
      return 0
    fi
    sleep 30
  done

  echo "ERROR: failed to download and validate $url -> $dest" >&2
  return 1
}

stage_metagenome_sample() {
  local sample="$1"
  local r1_url="$2"
  local r2_url="$3"
  local sample_dir="$DATA_ROOT/$sample"
  mkdir -p "$sample_dir"
  download_fastq "$r1_url" "$sample_dir/${sample}_R1.fastq.gz"
  download_fastq "$r2_url" "$sample_dir/${sample}_R2.fastq.gz"
}

prepare_shared_inputs() {
  stage_metagenome_sample ERR2011066 \
    https://ftp.sra.ebi.ac.uk/vol1/fastq/ERR201/006/ERR2011066/ERR2011066_1.fastq.gz \
    https://ftp.sra.ebi.ac.uk/vol1/fastq/ERR201/006/ERR2011066/ERR2011066_2.fastq.gz
  stage_metagenome_sample ERR2011071 \
    https://ftp.sra.ebi.ac.uk/vol1/fastq/ERR201/001/ERR2011071/ERR2011071_1.fastq.gz \
    https://ftp.sra.ebi.ac.uk/vol1/fastq/ERR201/001/ERR2011071/ERR2011071_2.fastq.gz
  stage_metagenome_sample ERR2011072 \
    https://ftp.sra.ebi.ac.uk/vol1/fastq/ERR201/002/ERR2011072/ERR2011072_1.fastq.gz \
    https://ftp.sra.ebi.ac.uk/vol1/fastq/ERR201/002/ERR2011072/ERR2011072_2.fastq.gz

  find "$DATA_ROOT" -type f -name '*.fastq.gz' -print0 | while IFS= read -r -d '' fastq; do
    gzip -t "$fastq"
  done
}

prepare_env() {
  if [ ! -x "$ENV_ROOT/bin/fastp" ]; then
    conda create -y -p "$ENV_ROOT" -c bioconda -c conda-forge fastp
  fi
}

run_replica() {
  local replica="$1"
  local rep_dir="$RUN_DIR/replica-${replica}"
  local workdir="$rep_dir/workdir"
  local scratch="$rep_dir/scratch"

  mkdir -p "$workdir" "$scratch"
  rm -rf "$workdir/config" "$workdir/workflow" "$workdir/scripts"
  cp -a "$REPO/config" "$workdir/config"
  cp -a "$REPO/workflow" "$workdir/workflow"
  cp -a "$REPO/workflow/scripts" "$workdir/scripts"
  cp "$REPO/config/config.yaml" "$workdir/config.yaml"

  python3 - "$workdir/config.yaml" "$workdir" "$scratch" "$ENV_ROOT" "$ROOT" <<'PY'
import sys
from pathlib import Path

config = Path(sys.argv[1])
workdir = sys.argv[2]
scratch = sys.argv[3]
env_root = sys.argv[4]
root = sys.argv[5]
text = config.read_text()
text = text.replace(f"{root}/runs/metaGEM/single/workdir", workdir)
text = text.replace(f"{root}/runs/metaGEM/single/scratch", scratch)
text = text.replace(f"{workdir}/envs/metagem", env_root)
config.write_text(text)
PY
  cp "$workdir/config.yaml" "$workdir/config/config.yaml"
  mkdir -p "$rep_dir/config"
  cp "$workdir/config.yaml" "$rep_dir/config/config.yaml"

  for sample in ERR2011066 ERR2011071 ERR2011072; do
    mkdir -p "$workdir/dataset/$sample"
    ln -sf "$DATA_ROOT/$sample/${sample}_R1.fastq.gz" "$workdir/dataset/$sample/${sample}_R1.fastq.gz"
    ln -sf "$DATA_ROOT/$sample/${sample}_R2.fastq.gz" "$workdir/dataset/$sample/${sample}_R2.fastq.gz"
  done

  cd "$workdir"
  "$ROOT/tools/conda-envs/snakemake9/bin/snakemake" -s workflow/Snakefile --unlock -j 1 || true
  "$ROOT/tools/conda-envs/snakemake9/bin/snakemake" -s workflow/Snakefile createFolders -j 1 --printshellcmds
  "$ROOT/tools/conda-envs/snakemake9/bin/snakemake" -s workflow/Snakefile all \
    -j "${SLURM_CPUS_PER_TASK:-40}" \
    --rerun-incomplete \
    --printshellcmds \
    --latency-wait 120

  find "$workdir/qfiltered" -type f -size +0c | sort > "$rep_dir/nonempty-qfiltered.txt"
  for sample in ERR2011066 ERR2011071 ERR2011072; do
    test -s "$workdir/qfiltered/$sample/${sample}_R1.fastq.gz"
    test -s "$workdir/qfiltered/$sample/${sample}_R2.fastq.gz"
    test -s "$workdir/qfiltered/$sample/${sample}.json"
    test -s "$workdir/qfiltered/$sample/${sample}.html"
  done

  du -sh "$workdir/dataset" "$workdir/qfiltered" > "$rep_dir/du.txt"
  echo "metaGEM replica $replica native Snakemake qfilter completed"
}

if [ "${1:-}" = "worker" ]; then
  run_replica "$2"
  exit 0
fi

prepare_shared_inputs
prepare_env

for replica in 0 1 2 3; do
  srun --exclusive --nodes=1 --ntasks=1 --cpus-per-task="${SLURM_CPUS_PER_TASK:-40}" \
    "$0" worker "$replica" > "$RUN_DIR/replica-${replica}.out" 2> "$RUN_DIR/replica-${replica}.err" &
done
wait

for replica in 0 1 2 3; do
  test -s "$RUN_DIR/replica-${replica}/nonempty-qfiltered.txt"
  grep -q "qfiltered" "$RUN_DIR/replica-${replica}/du.txt"
done

echo "metaGEM native 4-node Snakemake qfilter workflow completed across 4 nodes"
