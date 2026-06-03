#!/usr/bin/env bash
#SBATCH --job-name=dna-varloc-single
#SBATCH --exclusive
#SBATCH --partition=compute
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/dna-seq-varlociraptor/slurm-%j-single.out
#SBATCH --error=runs/dna-seq-varlociraptor/slurm-%j-single.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
RUN_ROOT="$ROOT/runs/dna-seq-varlociraptor"

mkdir -p "$RUN_ROOT" "$ROOT/tools/conda-envs/dna-seq-varlociraptor"
cd "$ROOT"

export PATH="$ROOT/tools/miniforge/bin:$PATH"
export CONDA_PKGS_DIRS="$ROOT/tools/conda-pkgs"
export SNAKEMAKE_OUTPUT_CACHE="$ROOT/tools/snakemake-cache"

conda config --set channel_priority strict --env >/dev/null

find "$ROOT/tools/conda-envs/dna-seq-varlociraptor" -mindepth 1 -maxdepth 1 -type d \
  ! -exec test -d "{}/conda-meta" \; -print -exec rm -rf {} +

cd "$ROOT/repos/dna-seq-varlociraptor"

"$ROOT/tools/conda-envs/snakemake9/bin/snakemake" \
  --snakefile workflow/Snakefile \
  --configfile config_codex_full/config.yaml \
  --use-conda \
  --conda-frontend conda \
  --conda-prefix "$ROOT/tools/conda-envs/dna-seq-varlociraptor" \
  --cores "${SLURM_CPUS_PER_TASK:-40}" \
  --printshellcmds \
  --rerun-incomplete \
  --latency-wait 120

find results -type f -size +0c | sort > "$RUN_ROOT/nonempty-results-${SLURM_JOB_ID:-manual}.txt"
test -s results/qc/multiqc/soil.html
test -s results/qc/multiqc/medium_L.html
test -s results/final-calls/soil/soil.present.variants.fdr-controlled.bcf
test -s results/final-calls/medium_L/medium_L.present.variants.fdr-controlled.bcf

du -sh results sra
echo "dna-seq-varlociraptor single-node native Snakemake baseline completed"
