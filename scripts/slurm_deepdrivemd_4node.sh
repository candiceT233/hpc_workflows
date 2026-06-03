#!/usr/bin/env bash
#SBATCH --job-name=deepdrivemd-4node
#SBATCH --exclusive
#SBATCH --partition=compute
#SBATCH --nodes=4
#SBATCH --ntasks=4
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/DeepDriveMD-pipeline/slurm-%j-4node.out
#SBATCH --error=runs/DeepDriveMD-pipeline/slurm-%j-4node.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

export RADICAL_CONFIG_USER_DIR="$ROOT/tools/radical-config"
export DEEPMD_RUN_LABEL=4node
export DEEPMD_TITLE="BBA DeepDriveMD Ares 4-node baseline"
export DEEPMD_RESOURCE=ares.local
export DEEPMD_QUEUE=compute
export DEEPMD_SCHEMA=local
export DEEPMD_PROJECT=none
export DEEPMD_CPUS_PER_NODE=40
export DEEPMD_NUM_TASKS=40
export DEEPMD_EXPECT_TASKS=40
export DEEPMD_LAST_N_H5=40
export DEEPMD_SKLEARN_JOBS=40

exec bash "$ROOT/scripts/slurm_deepdrivemd_single.sh"
