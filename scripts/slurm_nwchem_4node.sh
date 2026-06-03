#!/usr/bin/env bash
#SBATCH --job-name=nwchem-4node
#SBATCH --exclusive
#SBATCH --nodes=4
#SBATCH --ntasks-per-node=8
#SBATCH --cpus-per-task=1
#SBATCH --mem=45G
#SBATCH --time=12:00:00
#SBATCH --output=runs/nwchem/slurm-%j-4node.out
#SBATCH --error=runs/nwchem/slurm-%j-4node.err

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

RUN_ROOT="$ROOT/runs/nwchem/4node-${SLURM_JOB_ID}"
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

scontrol show hostnames "$SLURM_JOB_NODELIST" | awk '{print $1 " slots=8"}' > "$RUN_ROOT/hostfile"
NODE_COUNT="$(wc -l < "$RUN_ROOT/hostfile")"
if [ "$NODE_COUNT" -lt 4 ]; then
  echo "ERROR: expected at least 4 Slurm nodes, got $NODE_COUNT" >&2
  exit 1
fi

RANKS="${SLURM_NTASKS:-32}"
mpirun --bind-to none --map-by slot --hostfile "$RUN_ROOT/hostfile" -np "$RANKS" "$ENV/bin/nwchem" "$INPUT" \
  > "$RUN_ROOT/3carbo_dft.out" 2>&1

test -s "$RUN_ROOT/3carbo_dft.out"
grep -q "Total times" "$RUN_ROOT/3carbo_dft.out"
grep -q "3-Carboxybenzisoxazole Gas-phase Dynamics" "$RUN_ROOT/3carbo_dft.out"
grep -q "nproc[[:space:]]*=[[:space:]]*$RANKS" "$RUN_ROOT/3carbo_dft.out"

non_empty_outputs=$(find "$RUN_ROOT" -type f -size +0c | wc -l)
if (( non_empty_outputs < 4 )); then
  echo "ERROR: expected NWChem output plus generated scratch/result files in $RUN_ROOT" >&2
  exit 1
fi

echo "NWChem 4-node MPI baseline completed with $RANKS ranks across $NODE_COUNT nodes."
