#!/usr/bin/env bash
#SBATCH --job-name=biobb-md-4node
#SBATCH --exclusive
#SBATCH --nodes=4
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/biobb_wf_md_setup/slurm-%j-4node.out
#SBATCH --error=runs/biobb_wf_md_setup/slurm-%j-4node.err

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

export OMP_NUM_THREADS="${SLURM_CPUS_PER_TASK:-40}"
export OMP_PLACES=cores
export OMP_PROC_BIND=close

RUN_DIR="$WORKFLOW_ROOT/runs/biobb_wf_md_setup/4node-${SLURM_JOB_ID:-manual}"
rm -rf "$RUN_DIR"
mkdir -p "$RUN_DIR"

# Workflow-level parallelism: one isolated BioBB/GROMACS workflow replica per
# allocated node. The current OpenMPI build cannot form a Slurm-launched
# multi-rank GROMACS job on Ares, so do not share one checkpoint path across
# ranks.
read -r -a PDB_CODES <<< "${BIOBB_PDB_CODES:-1AKI 1AKI 1AKI 1AKI}"

replica_count="${#PDB_CODES[@]}"
if (( replica_count < SLURM_NNODES )); then
  echo "Need at least ${SLURM_NNODES} PDB codes, got ${replica_count}" >&2
  exit 2
fi

for ((i = 0; i < SLURM_NNODES; i++)); do
  replica_id=$((i + 1))
  pdb_code="${PDB_CODES[$i]}"
  replica_dir="$RUN_DIR/replica-${replica_id}-${pdb_code}"
  srun --exclusive --nodes=1 --ntasks=1 --cpus-per-task="$OMP_NUM_THREADS" \
    --export=ALL,WORKFLOW_ROOT="$WORKFLOW_ROOT",GMXROOT="$GMXROOT",PDB_CODE="$pdb_code",REPLICA_DIR="$replica_dir",OMP_NUM_THREADS="$OMP_NUM_THREADS" \
    bash -lc '
      set -eo pipefail
      . "$GMXROOT/bin/GMXRC"
      . "$WORKFLOW_ROOT/tools/biobb-venv/bin/activate"
      export OMP_PLACES=cores
      export OMP_PROC_BIND=close
      python "$WORKFLOW_ROOT/scripts/run_biobb_md_setup.py" \
        --pdb-code "$PDB_CODE" \
        --output-dir "$REPLICA_DIR" \
        --gmx-binary "$GMXROOT/bin/gmx_mpi" \
        --omp-threads "$OMP_NUM_THREADS"
    ' &
done

wait

for ((i = 0; i < SLURM_NNODES; i++)); do
  replica_id=$((i + 1))
  pdb_code="${PDB_CODES[$i]}"
  replica_dir="$RUN_DIR/replica-${replica_id}-${pdb_code}"
  for suffix in md.trr md.gro md.edr md.log md.cpt imaged_traj.trr md_dry.gro; do
    path="$replica_dir/${pdb_code}_${suffix}"
    if [[ ! -s "$path" ]]; then
      echo "Missing or empty expected output: $path" >&2
      exit 3
    fi
  done
done

find "$RUN_DIR" -maxdepth 2 -type f \( -name '*_md.trr' -o -name '*_md.gro' -o -name '*_md.edr' -o -name '*_md.log' -o -name '*_md.cpt' -o -name '*_imaged_traj.trr' -o -name '*_md_dry.gro' \) \
  -printf '%P\t%s\n' | sort > "$RUN_DIR/summary.tsv"
cat "$RUN_DIR/summary.tsv"
