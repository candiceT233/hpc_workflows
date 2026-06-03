#!/usr/bin/env bash
#SBATCH --job-name=lammps-single
#SBATCH --exclusive
#SBATCH --nodes=1
#SBATCH --ntasks=40
#SBATCH --cpus-per-task=1
#SBATCH --mem=45G
#SBATCH --time=04:00:00
#SBATCH --output=runs/lammps/slurm-%j-single.out
#SBATCH --error=runs/lammps/slurm-%j-single.err

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

RUN_ROOT="$ROOT/runs/lammps/single-${SLURM_JOB_ID:-manual}"
rm -rf "$RUN_ROOT"
mkdir -p "$RUN_ROOT"
cp "$ROOT/repos/lammps/bench/in.lj" "$RUN_ROOT/in.lj"

cd "$RUN_ROOT"
export OMP_NUM_THREADS=1
hostname > "$RUN_ROOT/hostfile"
sed -i 's/$/ slots=40/' "$RUN_ROOT/hostfile"
RANKS="${SLURM_NTASKS:-40}"

mpirun --bind-to none --map-by slot --hostfile "$RUN_ROOT/hostfile" -np "$RANKS" "$LMP" \
  -var x 4 \
  -var y 5 \
  -var z 2 \
  -in in.lj \
  -log log.lammps \
  > lammps.out 2>&1

test -s "$RUN_ROOT/log.lammps"
test -s "$RUN_ROOT/lammps.out"
grep -q "Loop time of" "$RUN_ROOT/log.lammps"
grep -q "on $RANKS procs" "$RUN_ROOT/log.lammps"
grep -q "for 100 steps" "$RUN_ROOT/log.lammps"
grep -q "with 1280000 atoms" "$RUN_ROOT/log.lammps"

bytes="$(stat --printf='%s' "$RUN_ROOT/log.lammps")"
if [ "$bytes" -lt 2000 ]; then
  echo "ERROR: LAMMPS log too small: $bytes bytes" >&2
  exit 1
fi

echo "LAMMPS single-node native MPI LJ scaled benchmark completed with $RANKS ranks and 1280000 atoms."
