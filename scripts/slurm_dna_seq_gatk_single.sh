#!/usr/bin/env bash
#SBATCH --job-name=dna-gatk-single
#SBATCH --exclusive
#SBATCH --partition=compute
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/dna-seq-gatk-variant-calling/slurm-%j-single.out
#SBATCH --error=runs/dna-seq-gatk-variant-calling/slurm-%j-single.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
RUN_ROOT="$ROOT/runs/dna-seq-gatk-variant-calling"
RUN_DIR="$RUN_ROOT/single-${SLURM_JOB_ID:-manual}"
REPO="$RUN_DIR/repo"
CONDA_PREFIX_DIR="$ROOT/tools/conda-envs/dna-seq-gatk"

mkdir -p "$RUN_ROOT" "$RUN_DIR" "$CONDA_PREFIX_DIR" "$ROOT/tools/conda-pkgs/dna-seq-gatk"
cd "$ROOT"

export PATH="$ROOT/tools/miniforge/bin:$ROOT/tools/snakemake-venv/bin:$PATH"
export CONDA_PKGS_DIRS="$ROOT/tools/conda-pkgs/dna-seq-gatk"
export SNAKEMAKE_OUTPUT_CACHE="$ROOT/tools/snakemake-cache"
export CONDA_CHANNEL_PRIORITY=flexible

conda config --set channel_priority flexible >/dev/null

find "$CONDA_PREFIX_DIR" -mindepth 1 -maxdepth 1 -type d \
  ! -exec test -d "{}/conda-meta" \; -print -exec rm -rf {} +

rm -rf "$REPO"
if ! cp -a --reflink=auto "$ROOT/repos/dna-seq-gatk-variant-calling" "$REPO" 2>/dev/null; then
  cp -a "$ROOT/repos/dna-seq-gatk-variant-calling" "$REPO"
fi
rm -rf "$REPO/.snakemake" "$REPO/results" "$REPO/logs"
awk -v root="$ROOT" 'BEGIN{FS=OFS="\t"} NR==1{print; next} {n=split($4, p4, "/"); $4=root "/data/dna-seq-gatk-variant-calling/full/fastq/" p4[n]; n=split($5, p5, "/"); $5=root "/data/dna-seq-gatk-variant-calling/full/fastq/" p5[n]; print}' \
  "$REPO/config_codex_full/units.tsv" > "$REPO/config_codex_full/units.tsv.tmp"
mv "$REPO/config_codex_full/units.tsv.tmp" "$REPO/config_codex_full/units.tsv"

cd "$REPO"
find results -type f -size 0 -print -delete 2>/dev/null || true

snakemake \
  --snakefile workflow/Snakefile \
  --configfile config_codex_full/config.yaml \
  --unlock || true

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

while IFS= read -r multiqc_bin; do
  env_dir="$(cd "$(dirname "$multiqc_bin")/.." && pwd)"
  if ! "$env_dir/bin/python" -c 'import pkg_resources' >/dev/null 2>&1; then
    conda install -y -p "$env_dir" -c conda-forge 'setuptools<81'
    "$env_dir/bin/python" -c 'import pkg_resources'
  fi
  site_packages="$("$env_dir/bin/python" - <<'PY'
import site
print(site.getsitepackages()[0])
PY
)"
  cat > "$site_packages/sitecustomize.py" <<'PY'
import collections
import collections.abc

for _name in (
    "Callable",
    "Iterable",
    "Mapping",
    "MutableMapping",
    "MutableSequence",
    "MutableSet",
    "Sequence",
    "Set",
):
    if not hasattr(collections, _name):
        setattr(collections, _name, getattr(collections.abc, _name))
PY
  "$env_dir/bin/python" -c 'import collections; assert collections.Mapping'
done < <(find "$CONDA_PREFIX_DIR" -type f -path '*/bin/multiqc' | sort)

snakemake \
  --snakefile workflow/Snakefile \
  --configfile config_codex_full/config.yaml \
  --unlock || true

snakemake \
  --snakefile workflow/Snakefile \
  --configfile config_codex_full/config.yaml \
  --use-conda \
  --conda-frontend conda \
  --conda-prefix "$CONDA_PREFIX_DIR" \
  --cores "${SLURM_CPUS_PER_TASK:-40}" \
  --printshellcmds \
  --rerun-incomplete \
  --latency-wait 120

find results -type f -size +0c | sort > "$RUN_DIR/nonempty-results.txt"
test -s results/annotated/all.vcf.gz
test -s results/qc/multiqc.html
test -s results/plots/depths.svg
test -s results/plots/allele-freqs.svg

du -sh results
echo "dna-seq-gatk-variant-calling single-node native Snakemake baseline completed"
