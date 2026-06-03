#!/bin/bash
#SBATCH --job-name=star-deseq2-4node
#SBATCH --exclusive
#SBATCH --partition=compute
#SBATCH --nodes=4
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/rna-seq-star-deseq2/slurm-%j-4node.out
#SBATCH --error=runs/rna-seq-star-deseq2/slurm-%j-4node.err

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
CONDA_PREFIX_DIR="$ROOT/tools/snakemake-conda/rna-seq-star-deseq2"
RUN_ROOT="$ROOT/runs/rna-seq-star-deseq2/4node-${SLURM_JOB_ID:-manual}"

mkdir -p "$RUN_ROOT" "$CONDA_PREFIX_DIR" "$ROOT/runs/rna-seq-star-deseq2"
rm -rf "$RUN_ROOT"/replica-*

cat > "$RUN_ROOT/run_replica.sh" <<'EOS'
#!/bin/bash
set -euo pipefail

rank="${SLURM_PROCID:-0}"
replica_id=$((rank + 1))
replica_root="${RUN_ROOT}/replica-${replica_id}"

mkdir -p "$replica_root/config" "$replica_root/tmp"
rm -rf "$replica_root/config_sra"
cp -a "$REPO/.test/config_sra" "$replica_root/config_sra"
cp "$REPO/.test/config_sra/config.yaml" "$replica_root/config/config.yaml"

export PATH="$SNAKEMAKE_ENV/bin:$ROOT/tools/miniforge/bin:$ROOT/tools/miniforge/condabin:$PATH"
export TMPDIR="$replica_root/tmp"

snakemake \
  --snakefile "$REPO/workflow/Snakefile" \
  --directory "$replica_root" \
  --configfile "$replica_root/config/config.yaml" \
  --cores "${SLURM_CPUS_PER_TASK:-40}" \
  --use-conda \
  --conda-prefix "$CONDA_PREFIX_DIR" \
  --rerun-incomplete \
  --restart-times 2 \
  --printshellcmds \
  --show-failed-logs

for path in \
  "$replica_root/results/deseq2/normcounts.tsv" \
  "$replica_root/results/diffexp/stb5_vs_control.diffexp.tsv" \
  "$replica_root/results/pca.genotype.svg" \
  "$replica_root/results/qc/multiqc_report.html"; do
  if [ ! -s "$path" ]; then
    echo "ERROR: replica ${replica_id} missing expected output: $path" >&2
    exit 1
  fi
done

if ! find "$replica_root/results/star" -type f -name 'Aligned.sortedByCoord.out.bam' -size +0 | grep -q .; then
  echo "ERROR: replica ${replica_id} missing non-empty STAR BAM outputs" >&2
  exit 1
fi

output_count="$(find "$replica_root/results" -type f -size +0 | wc -l)"
if [ "$output_count" -lt 20 ]; then
  echo "ERROR: replica ${replica_id} too few non-empty outputs: $output_count" >&2
  exit 1
fi

echo "replica ${replica_id} completed with ${output_count} non-empty result files"
EOS
chmod +x "$RUN_ROOT/run_replica.sh"

export ROOT REPO SNAKEMAKE_ENV CONDA_PREFIX_DIR RUN_ROOT
srun -u -n "$SLURM_NTASKS" --ntasks-per-node=1 "$RUN_ROOT/run_replica.sh"

replica_count="$(find "$RUN_ROOT" -maxdepth 1 -type d -name 'replica-*' | wc -l)"
if [ "$replica_count" -ne "$SLURM_NTASKS" ]; then
  echo "ERROR: expected $SLURM_NTASKS replicas, found $replica_count" >&2
  exit 1
fi

find "$RUN_ROOT"/replica-*/results -type f -size +0 -printf '%h/%f\t%s\n' > "$RUN_ROOT/output_manifest.tsv"
total_outputs="$(wc -l < "$RUN_ROOT/output_manifest.tsv")"
if [ "$total_outputs" -lt 80 ]; then
  echo "ERROR: too few total outputs across replicas: $total_outputs" >&2
  exit 1
fi

echo "rna-seq-star-deseq2 4-node native Snakemake baseline completed with ${replica_count} replicas and ${total_outputs} non-empty result files"
