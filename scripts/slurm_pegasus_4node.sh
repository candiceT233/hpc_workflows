#!/usr/bin/env bash
#SBATCH --job-name=pegasus-4node
#SBATCH --exclusive
#SBATCH --nodes=4
#SBATCH --ntasks-per-node=8
#SBATCH --cpus-per-task=1
#SBATCH --mem=16G
#SBATCH --time=02:00:00
#SBATCH --output=runs/pegasus/slurm-%j-4node.out
#SBATCH --error=runs/pegasus/slurm-%j-4node.err

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
command -v srun

RUN_ROOT="$ROOT/runs/pegasus/4node-${SLURM_JOB_ID}"
mkdir -p "$RUN_ROOT"

export PEGASUS_HOSTFILE="$RUN_ROOT/hosts.txt"
export PEGASUS_NODE_LOG="$RUN_ROOT/pegasus-node-dispatch.log"
export PEGASUS_KEG_BIN="$(command -v pegasus-keg)"
export PEGASUS_TRANSFORMATION_PFN="$ROOT/scripts/pegasus-keg-slurm-node.sh"

scontrol show hostnames "$SLURM_JOB_NODELIST" > "$PEGASUS_HOSTFILE"
NODE_COUNT="$(wc -l < "$PEGASUS_HOSTFILE")"
if [ "$NODE_COUNT" -lt 4 ]; then
  echo "ERROR: expected at least 4 Slurm nodes, got $NODE_COUNT" >&2
  exit 1
fi

python3 "$ROOT/scripts/run_pegasus_workflow.py" \
  --run-dir "$RUN_ROOT" \
  --jobs 64 \
  --timeout 3600 \
  --engine shell \
  2>&1 | tee "$RUN_ROOT/pegasus-workflow.log"

test -s "$RUN_ROOT/manifest.json"
test -s "$RUN_ROOT/outputs/final.txt"
grep -q '"jobs": 64' "$RUN_ROOT/manifest.json"
grep -q '"engine": "shell"' "$RUN_ROOT/manifest.json"
grep -q "pegasus-keg-slurm-node.sh" "$RUN_ROOT/manifest.json"
grep -q "SHELL_SCRIPT_FINISHED 0" "$RUN_ROOT/work/submit/jobstate.log"

USED_NODES="$(awk '{print $2}' "$PEGASUS_NODE_LOG" | sort -u | wc -l)"
if [ "$USED_NODES" -lt 4 ]; then
  echo "ERROR: Pegasus process jobs used only $USED_NODES nodes" >&2
  cat "$PEGASUS_NODE_LOG" >&2
  exit 1
fi

echo "Pegasus native 4-node Shell-codegen baseline completed with $USED_NODES nodes used."
