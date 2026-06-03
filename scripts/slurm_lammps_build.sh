#!/usr/bin/env bash
#SBATCH --job-name=lammps-build
#SBATCH --exclusive
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=40
#SBATCH --mem=45G
#SBATCH --time=04:00:00
#SBATCH --output=runs/lammps/slurm-%j-build.out
#SBATCH --error=runs/lammps/slurm-%j-build.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
cd "$ROOT"

mkdir -p runs/lammps tools/lammps-build tools/lammps

source /etc/profile.d/modules.sh 2>/dev/null || true
module load openmpi/5.0.5-gcc-11.4.0-og56sxz

cmake -S "$ROOT/repos/lammps/cmake" -B "$ROOT/tools/lammps-build" \
  -D CMAKE_BUILD_TYPE=Release \
  -D CMAKE_INSTALL_PREFIX="$ROOT/tools/lammps" \
  -D BUILD_MPI=on \
  -D BUILD_OMP=off \
  -D PKG_KSPACE=on \
  -D PKG_MOLECULE=on \
  -D PKG_RIGID=on \
  -D LAMMPS_EXCEPTIONS=on

cmake --build "$ROOT/tools/lammps-build" --parallel "${SLURM_CPUS_PER_TASK:-40}"
cmake --install "$ROOT/tools/lammps-build"

test -x "$ROOT/tools/lammps/bin/lmp"
"$ROOT/tools/lammps/bin/lmp" -h | tee "$ROOT/runs/lammps/lammps-help-${SLURM_JOB_ID}.txt"

grep -E "KSPACE|MOLECULE|RIGID" "$ROOT/runs/lammps/lammps-help-${SLURM_JOB_ID}.txt"
echo "LAMMPS MPI build completed: $ROOT/tools/lammps/bin/lmp"
