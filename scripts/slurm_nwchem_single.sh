#!/usr/bin/env bash
#SBATCH --job-name=nwchem-single
#SBATCH --exclusive
#SBATCH --nodes=1
#SBATCH --ntasks=8
#SBATCH --cpus-per-task=1
#SBATCH --mem=45G
#SBATCH --time=12:00:00
#SBATCH --output=runs/nwchem/slurm-%j-single.out
#SBATCH --error=runs/nwchem/slurm-%j-single.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
cd "$ROOT"

mkdir -p runs/nwchem

RUN_ROOT="$ROOT/runs/nwchem/single-${SLURM_JOB_ID}"
mkdir -p "$RUN_ROOT"
cd "$RUN_ROOT"

ENV="$ROOT/tools/conda-envs/nwchem"
export PATH="$ENV/bin:$PATH"
export LD_LIBRARY_PATH="$ENV/lib:${LD_LIBRARY_PATH:-}"
export NWCHEM_BASIS_LIBRARY="$ENV/share/nwchem/libraries/"
export NWCHEM_NWPW_LIBRARY="$ENV/share/nwchem/libraryps/"
export OMP_NUM_THREADS=1

INPUT_SRC="$ROOT/repos/nwchem/examples/qmd/3carbo_dft.nw"
INPUT="$RUN_ROOT/3carbo_dft.nw"
cp "$INPUT_SRC" "$INPUT"

mpirun --bind-to none -np "${SLURM_NTASKS:-8}" "$ENV/bin/nwchem" "$INPUT" \
  > "$RUN_ROOT/3carbo_dft.out" 2>&1

test -s "$RUN_ROOT/3carbo_dft.out"
grep -q "Total times" "$RUN_ROOT/3carbo_dft.out"
grep -q "3-Carboxybenzisoxazole Gas-phase Dynamics" "$RUN_ROOT/3carbo_dft.out"
grep -q "task.*dft.*dynamics\\|NWChem" "$RUN_ROOT/3carbo_dft.out"

non_empty_outputs=$(find "$RUN_ROOT" -type f -size +0c | wc -l)
if (( non_empty_outputs < 2 )); then
  echo "Expected at least input and output files in $RUN_ROOT" >&2
  exit 1
fi

echo "NWChem single-node MPI baseline completed with ${SLURM_NTASKS:-8} ranks."
