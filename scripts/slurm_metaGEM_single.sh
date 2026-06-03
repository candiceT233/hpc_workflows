#!/usr/bin/env bash
#SBATCH --job-name=metaGEM-single
#SBATCH --exclusive
#SBATCH --partition=compute
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/metaGEM/slurm-%j-single.out
#SBATCH --error=runs/metaGEM/slurm-%j-single.err

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
WORKDIR="$RUN_ROOT/single-${SLURM_JOB_ID:-manual}/workdir"
SCRATCH="$RUN_ROOT/single-${SLURM_JOB_ID:-manual}/scratch"

mkdir -p "$RUN_ROOT" "$WORKDIR" "$SCRATCH" "$ROOT/tools/conda-pkgs"
cd "$ROOT"

export PATH="$ROOT/tools/miniforge/bin:$PATH"
export CONDA_PKGS_DIRS="$ROOT/tools/conda-pkgs"

rm -rf "$WORKDIR/config" "$WORKDIR/workflow" "$WORKDIR/scripts"
cp -a "$REPO/config" "$WORKDIR/config"
cp -a "$REPO/workflow" "$WORKDIR/workflow"
cp -a "$REPO/workflow/scripts" "$WORKDIR/scripts"
cp "$REPO/config/config.yaml" "$WORKDIR/config.yaml"
python3 - "$WORKDIR/config.yaml" "$WORKDIR" "$SCRATCH" "$ROOT" <<'PY'
import sys
from pathlib import Path

config = Path(sys.argv[1])
workdir = sys.argv[2]
scratch = sys.argv[3]
root = sys.argv[4]
text = config.read_text()
text = text.replace(f"{root}/runs/metaGEM/single/workdir", workdir)
text = text.replace(f"{root}/runs/metaGEM/single/scratch", scratch)
config.write_text(text)
PY
cp "$WORKDIR/config.yaml" "$WORKDIR/config/config.yaml"
mkdir -p "$RUN_ROOT/single-${SLURM_JOB_ID:-manual}/config"
cp "$WORKDIR/config.yaml" "$RUN_ROOT/single-${SLURM_JOB_ID:-manual}/config/config.yaml"
mkdir -p "$WORKDIR/envs"

if [ ! -x "$WORKDIR/envs/metagem/bin/fastp" ]; then
  conda create -y -p "$WORKDIR/envs/metagem" -c bioconda -c conda-forge fastp
fi

cd "$WORKDIR"

"$ROOT/tools/conda-envs/snakemake9/bin/snakemake" -s workflow/Snakefile --unlock -j 1 || true
"$ROOT/tools/conda-envs/snakemake9/bin/snakemake" -s workflow/Snakefile createFolders -j 1 --printshellcmds

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
  local sample_dir="$WORKDIR/dataset/$sample"
  mkdir -p "$sample_dir"
  download_fastq "$r1_url" "$sample_dir/${sample}_R1.fastq.gz"
  download_fastq "$r2_url" "$sample_dir/${sample}_R2.fastq.gz"
}

stage_metagenome_sample ERR2011066 \
  https://ftp.sra.ebi.ac.uk/vol1/fastq/ERR201/006/ERR2011066/ERR2011066_1.fastq.gz \
  https://ftp.sra.ebi.ac.uk/vol1/fastq/ERR201/006/ERR2011066/ERR2011066_2.fastq.gz
stage_metagenome_sample ERR2011071 \
  https://ftp.sra.ebi.ac.uk/vol1/fastq/ERR201/001/ERR2011071/ERR2011071_1.fastq.gz \
  https://ftp.sra.ebi.ac.uk/vol1/fastq/ERR201/001/ERR2011071/ERR2011071_2.fastq.gz
stage_metagenome_sample ERR2011072 \
  https://ftp.sra.ebi.ac.uk/vol1/fastq/ERR201/002/ERR2011072/ERR2011072_1.fastq.gz \
  https://ftp.sra.ebi.ac.uk/vol1/fastq/ERR201/002/ERR2011072/ERR2011072_2.fastq.gz

find "$WORKDIR/dataset" -type f -name '*.fastq.gz' -print0 | while IFS= read -r -d '' fastq; do
  gzip -t "$fastq"
done

"$ROOT/tools/conda-envs/snakemake9/bin/snakemake" -s workflow/Snakefile all \
  -j "${SLURM_CPUS_PER_TASK:-40}" \
  --rerun-incomplete \
  --printshellcmds \
  --latency-wait 120

find "$WORKDIR/qfiltered" -type f -size +0c | sort > "$RUN_ROOT/nonempty-qfiltered-${SLURM_JOB_ID:-manual}.txt"
for sample in ERR2011066 ERR2011071 ERR2011072; do
  test -s "$WORKDIR/qfiltered/$sample/${sample}_R1.fastq.gz"
  test -s "$WORKDIR/qfiltered/$sample/${sample}_R2.fastq.gz"
  test -s "$WORKDIR/qfiltered/$sample/${sample}.json"
  test -s "$WORKDIR/qfiltered/$sample/${sample}.html"
done

du -sh "$WORKDIR/dataset" "$WORKDIR/qfiltered"
echo "metaGEM single-node native Snakemake qfilter baseline completed"
