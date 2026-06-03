#!/bin/bash
#SBATCH --job-name=star-deseq2-single
#SBATCH --exclusive
#SBATCH --partition=compute
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/rna-seq-star-deseq2/slurm-%j-single.out
#SBATCH --error=runs/rna-seq-star-deseq2/slurm-%j-single.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

REPO="$ROOT/repos/rna-seq-star-deseq2"
SNAKEMAKE_ENV="$ROOT/tools/conda-envs/snakemake9"
RUN_ROOT="$ROOT/runs/rna-seq-star-deseq2/single-${SLURM_JOB_ID:-manual}"
CONDA_PREFIX_DIR="$ROOT/tools/snakemake-conda/rna-seq-star-deseq2"

mkdir -p "$RUN_ROOT" "$CONDA_PREFIX_DIR" "$ROOT/runs/rna-seq-star-deseq2"
rm -rf "$RUN_ROOT/config_sra" "$RUN_ROOT/config"
mkdir -p "$RUN_ROOT/config"
cp -a "$REPO/.test/config_sra" "$RUN_ROOT/config_sra"
cp "$REPO/.test/config_sra/config.yaml" "$RUN_ROOT/config/config.yaml"

export PATH="$SNAKEMAKE_ENV/bin:$ROOT/tools/miniforge/bin:$ROOT/tools/miniforge/condabin:$PATH"
export TMPDIR="${TMPDIR:-$RUN_ROOT/tmp}"
mkdir -p "$TMPDIR"

snakemake \
  --snakefile "$REPO/workflow/Snakefile" \
  --directory "$RUN_ROOT" \
  --configfile "$RUN_ROOT/config/config.yaml" \
  --cores "${SLURM_CPUS_PER_TASK:-40}" \
  --use-conda \
  --conda-prefix "$CONDA_PREFIX_DIR" \
  --rerun-incomplete \
  --restart-times 2 \
  --printshellcmds \
  --show-failed-logs

if [ ! -s "$RUN_ROOT/results/deseq2/normcounts.tsv" ]; then
  echo "ERROR: missing DESeq2 normalized counts" >&2
  exit 1
fi

if [ ! -s "$RUN_ROOT/results/diffexp/stb5_vs_control.diffexp.tsv" ]; then
  echo "ERROR: missing differential expression table" >&2
  exit 1
fi

if [ ! -s "$RUN_ROOT/results/pca.genotype.svg" ]; then
  echo "ERROR: missing PCA output" >&2
  exit 1
fi

if [ ! -s "$RUN_ROOT/results/qc/multiqc_report.html" ]; then
  echo "ERROR: missing MultiQC report" >&2
  exit 1
fi

if ! find "$RUN_ROOT/results/star" -type f -name 'Aligned.sortedByCoord.out.bam' -size +0 | grep -q .; then
  echo "ERROR: missing non-empty STAR BAM outputs" >&2
  exit 1
fi

OUTPUT_COUNT="$(find "$RUN_ROOT/results" -type f -size +0 | wc -l)"
if [ "$OUTPUT_COUNT" -lt 20 ]; then
  echo "ERROR: too few non-empty rna-seq-star-deseq2 outputs: $OUTPUT_COUNT" >&2
  exit 1
fi

echo "rna-seq-star-deseq2 single-node native Snakemake baseline completed with $OUTPUT_COUNT non-empty result files"
