#!/usr/bin/env bash
#SBATCH --job-name=lammps-4node
#SBATCH --exclusive
#SBATCH --nodes=4
#SBATCH --ntasks-per-node=8
#SBATCH --cpus-per-task=1
#SBATCH --mem=45G
#SBATCH --time=04:00:00
#SBATCH --output=runs/lammps/slurm-%j-4node.out
#SBATCH --error=runs/lammps/slurm-%j-4node.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
cd "$ROOT"

source /etc/profile.d/modules.sh 2>/dev/null || true
module load openmpi/5.0.5-gcc-11.4.0-og56sxz

LMP="$ROOT/tools/lammps/bin/lmp"
if [ ! -x "$LMP" ]; then
  echo "ERROR: missing LAMMPS executable at $LMP; run scripts/slurm_lammps_build.sh first" >&2
  exit 1
fi

RUN_ROOT="$ROOT/runs/lammps/4node-${SLURM_JOB_ID:-manual}"
rm -rf "$RUN_ROOT"
mkdir -p "$RUN_ROOT"
cp "$ROOT/repos/lammps/bench/in.lj" "$RUN_ROOT/in.lj"

scontrol show hostnames "$SLURM_JOB_NODELIST" | awk '{print $1 " slots=8"}' > "$RUN_ROOT/hostfile"
NODE_COUNT="$(wc -l < "$RUN_ROOT/hostfile")"
if [ "$NODE_COUNT" -lt 4 ]; then
  echo "ERROR: expected at least 4 Slurm nodes, got $NODE_COUNT" >&2
  exit 1
fi

cd "$RUN_ROOT"
export OMP_NUM_THREADS=1
RANKS="${SLURM_NTASKS:-32}"

mpirun --bind-to none --map-by slot --hostfile "$RUN_ROOT/hostfile" -np "$RANKS" "$LMP" \
  -var x 4 \
  -var y 5 \
  -var z 4 \
  -in in.lj \
  -log log.lammps \
  > lammps.out 2>&1

test -s "$RUN_ROOT/log.lammps"
test -s "$RUN_ROOT/lammps.out"
grep -q "Loop time of" "$RUN_ROOT/log.lammps"
grep -q "on $RANKS procs" "$RUN_ROOT/log.lammps"
grep -q "for 100 steps" "$RUN_ROOT/log.lammps"
grep -q "with 2560000 atoms" "$RUN_ROOT/log.lammps"

bytes="$(stat --printf='%s' "$RUN_ROOT/log.lammps")"
if [ "$bytes" -lt 2000 ]; then
  echo "ERROR: LAMMPS log too small: $bytes bytes" >&2
  exit 1
fi

echo "LAMMPS native 4-node MPI LJ scaled benchmark completed with $RANKS ranks, $NODE_COUNT nodes, and 2560000 atoms."
