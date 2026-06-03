#!/usr/bin/env bash
#SBATCH --job-name=eager-envprep
#SBATCH --exclusive
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/nf-core_eager/slurm-%j-envprep.out
#SBATCH --error=runs/nf-core_eager/slurm-%j-envprep.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

ENV_DIR="$ROOT/tools/nextflow-conda-cache/nf-core_eager/nf-core-eager-2.5.3-5850068f31c787707a8e3ee245554bb7"
PKGS_DIR="$ROOT/tools/conda-pkgs"
TMP_ROOT="$ROOT/runs/nf-core_eager/envprep-${SLURM_JOB_ID:-manual}/tmp"

mkdir -p "$ROOT/runs/nf-core_eager" "$PKGS_DIR" "$TMP_ROOT" "$(dirname "$ENV_DIR")"
export TMPDIR="$TMP_ROOT"
export CONDA_PKGS_DIRS="$PKGS_DIR"
export MAMBA_YES=true
export MAMBA_ALWAYS_YES=true
export CONDA_ALWAYS_YES=true

if [ ! -x "$ENV_DIR/bin/python" ]; then
  "$ROOT/tools/miniforge/bin/mamba" env create \
    --prefix "$ENV_DIR" \
    --file "$ROOT/repos/nf-core_eager/environment.yml"
fi

if ! "$ENV_DIR/bin/python" -c 'import pkg_resources' >/dev/null 2>&1; then
  "$ROOT/tools/miniforge/bin/mamba" install --yes --prefix "$ENV_DIR" -c conda-forge 'setuptools<81'
fi

"$ENV_DIR/bin/python" - <<'PY'
import pkg_resources  # noqa: F401
PY

for exe in fastqc AdapterRemoval bwa picard samtools multiqc; do
  command -v "$ENV_DIR/bin/$exe" >/dev/null
done

echo "nf-core/eager shared Conda environment ready at $ENV_DIR"
