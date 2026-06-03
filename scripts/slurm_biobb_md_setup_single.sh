#!/usr/bin/env bash
#SBATCH --job-name=biobb-md-single
#SBATCH --exclusive
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/biobb_wf_md_setup/slurm-%j-single.out
#SBATCH --error=runs/biobb_wf_md_setup/slurm-%j-single.err

set -eo pipefail

if [[ -z "${WORKFLOW_ROOT:-}" ]]; then
  if [[ -f table.md && -d scripts ]]; then
    WORKFLOW_ROOT="$PWD"
  else
    WORKFLOW_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  fi
fi
cd "$WORKFLOW_ROOT"

mkdir -p runs/biobb_wf_md_setup

GMXROOT="${GMXROOT:-$(spack location -i gromacs@2024.3)}"
. "$GMXROOT/bin/GMXRC"
. "$WORKFLOW_ROOT/tools/biobb-venv/bin/activate"

export OMP_NUM_THREADS="${SLURM_CPUS_PER_TASK:-40}"
export OMP_PLACES=cores
export OMP_PROC_BIND=close

RUN_DIR="$WORKFLOW_ROOT/runs/biobb_wf_md_setup/single-${SLURM_JOB_ID:-manual}"
rm -rf "$RUN_DIR"

python "$WORKFLOW_ROOT/scripts/run_biobb_md_setup.py" \
  --output-dir "$RUN_DIR" \
  --gmx-binary "$GMXROOT/bin/gmx_mpi" \
  --omp-threads "$OMP_NUM_THREADS"
