#!/usr/bin/env bash
#SBATCH --job-name=pegasus-single
#SBATCH --exclusive
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=16G
#SBATCH --time=02:00:00
#SBATCH --output=runs/pegasus/slurm-%j-single.out
#SBATCH --error=runs/pegasus/slurm-%j-single.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
cd "$ROOT"

mkdir -p runs/pegasus

export PATH="$ROOT/scripts/bin:/usr/bin:/bin:$PATH"
export PYTHONPATH="$(pegasus-config --python):${PYTHONPATH:-}"

command -v pegasus-plan
command -v pegasus-keg

RUN_ROOT="$ROOT/runs/pegasus/single-${SLURM_JOB_ID}"
mkdir -p "$RUN_ROOT"

python3 "$ROOT/scripts/run_pegasus_workflow.py" \
  --run-dir "$RUN_ROOT" \
  --jobs 32 \
  --timeout 1800 \
  --engine shell \
  2>&1 | tee "$RUN_ROOT/pegasus-workflow.log"

test -s "$RUN_ROOT/manifest.json"
test -s "$RUN_ROOT/outputs/final.txt"
grep -q '"jobs": 32' "$RUN_ROOT/manifest.json"
grep -q '"engine": "shell"' "$RUN_ROOT/manifest.json"
grep -q "SHELL_SCRIPT_FINISHED 0" "$RUN_ROOT/work/submit/jobstate.log"

echo "Pegasus native single-node baseline completed."
