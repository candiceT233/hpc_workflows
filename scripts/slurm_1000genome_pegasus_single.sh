#!/usr/bin/env bash
#SBATCH --job-name=1000genome-pegasus
#SBATCH --exclusive
#SBATCH --partition=compute
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=40
#SBATCH --mem=45G
#SBATCH --time=48:00:00
#SBATCH --output=runs/1000genome-workflow/slurm-%j-single.out
#SBATCH --error=runs/1000genome-workflow/slurm-%j-single.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

cd "$ROOT"
mkdir -p runs/1000genome-workflow

export PATH="$ROOT/scripts/bin:$ROOT/scripts/pegasus-bin:/usr/bin:/bin:$PATH"
export PYTHONPATH="$(pegasus-config --python):${PYTHONPATH:-}"

command -v pegasus-plan
command -v pegasus-kickstart

RUN_ROOT="$ROOT/runs/1000genome-workflow/single-${SLURM_JOB_ID}"
mkdir -p "$RUN_ROOT"

python3 "$ROOT/scripts/run_1000genome_pegasus.py" \
  --repo repos/1000genome-workflow \
  --run-dir "$RUN_ROOT" \
  --dir-name "codex-shell-single-${SLURM_JOB_ID}" \
  --individuals-jobs 1 \
  2>&1 | tee "$RUN_ROOT/1000genome-pegasus.log"

test -s "$RUN_ROOT/manifest.json"
grep -q '"engine": "pegasus-shell"' "$RUN_ROOT/manifest.json"
grep -q '"expected_outputs": 140' "$RUN_ROOT/manifest.json"
grep -q "SHELL_SCRIPT_FINISHED 0" "$ROOT/repos/1000genome-workflow/codex-shell-single-${SLURM_JOB_ID}/jobstate.log"

echo "1000genome native Pegasus single-node baseline completed."
