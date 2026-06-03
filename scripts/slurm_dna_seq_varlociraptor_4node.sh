#!/usr/bin/env bash
#SBATCH --job-name=dna-varloc-4node
#SBATCH --exclusive
#SBATCH --partition=compute
#SBATCH --nodes=4
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/dna-seq-varlociraptor/slurm-%j-4node.out
#SBATCH --error=runs/dna-seq-varlociraptor/slurm-%j-4node.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

REPO="$ROOT/repos/dna-seq-varlociraptor"
SNAKEMAKE_ENV="$ROOT/tools/conda-envs/snakemake9"
RUN_ROOT="$ROOT/runs/dna-seq-varlociraptor/4node-${SLURM_JOB_ID:-manual}"

mkdir -p "$ROOT/runs/dna-seq-varlociraptor" "$RUN_ROOT"
rm -rf "$RUN_ROOT"/replica-*

cat > "$RUN_ROOT/run_replica.sh" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail

rank="${SLURM_PROCID:-0}"
replica_id=$((rank + 1))
replica_root="$RUN_ROOT/replica-${replica_id}"
replica_repo="$replica_root/repo"

mkdir -p "$replica_root/tmp" "$replica_root/conda-envs" "$replica_root/conda-pkgs" "$replica_repo"

tar -C "$REPO" \
  --exclude='./.git' \
  --exclude='./.snakemake' \
  --exclude='./benchmarks' \
  --exclude='./logs' \
  --exclude='./results' \
  --exclude='./sra' \
  -cf - . | tar -C "$replica_repo" -xf -

if [ -d "$REPO/sra" ]; then
  cp -a "$REPO/sra" "$replica_repo/sra"
fi

export PATH="$ROOT/tools/miniforge/bin:$SNAKEMAKE_ENV/bin:$PATH"
export TMPDIR="$replica_root/tmp"
export CONDA_PKGS_DIRS="$replica_root/conda-pkgs"
export SNAKEMAKE_OUTPUT_CACHE="$ROOT/tools/snakemake-cache"

conda config --set channel_priority strict --env >/dev/null

"$SNAKEMAKE_ENV/bin/snakemake" \
  --snakefile "$replica_repo/workflow/Snakefile" \
  --directory "$replica_repo" \
  --configfile "$replica_repo/config_codex_full/config.yaml" \
  --use-conda \
  --conda-frontend conda \
  --conda-prefix "$replica_root/conda-envs" \
  --cores "${SLURM_CPUS_PER_TASK:-40}" \
  --printshellcmds \
  --rerun-incomplete \
  --latency-wait 120

for path in \
  "$replica_repo/results/qc/multiqc/soil.html" \
  "$replica_repo/results/qc/multiqc/medium_L.html" \
  "$replica_repo/results/final-calls/soil/soil.present.variants.fdr-controlled.bcf" \
  "$replica_repo/results/final-calls/medium_L/medium_L.present.variants.fdr-controlled.bcf"; do
  if [ ! -s "$path" ]; then
    echo "ERROR: replica ${replica_id} missing expected output: $path" >&2
    exit 1
  fi
done

output_count="$(find "$replica_repo/results" -type f -size +0c | wc -l)"
if [ "$output_count" -lt 800 ]; then
  echo "ERROR: replica ${replica_id} too few non-empty outputs: $output_count" >&2
  exit 1
fi

du -sh "$replica_repo/results" "$replica_repo/sra"
echo "replica ${replica_id} completed with ${output_count} non-empty result files"
EOS
chmod +x "$RUN_ROOT/run_replica.sh"

export ROOT REPO SNAKEMAKE_ENV RUN_ROOT
srun -u -n "$SLURM_NTASKS" --ntasks-per-node=1 "$RUN_ROOT/run_replica.sh"

replica_count="$(find "$RUN_ROOT" -maxdepth 1 -type d -name 'replica-*' | wc -l)"
if [ "$replica_count" -ne "$SLURM_NTASKS" ]; then
  echo "ERROR: expected $SLURM_NTASKS replicas, found $replica_count" >&2
  exit 1
fi

find "$RUN_ROOT"/replica-*/repo/results -type f -size +0c -printf '%p\t%s\n' > "$RUN_ROOT/output_manifest.tsv"
total_outputs="$(wc -l < "$RUN_ROOT/output_manifest.tsv")"
if [ "$total_outputs" -lt 3200 ]; then
  echo "ERROR: too few total outputs across replicas: $total_outputs" >&2
  exit 1
fi

echo "dna-seq-varlociraptor 4-node native Snakemake baseline completed with ${replica_count} replicas and ${total_outputs} non-empty result files"
