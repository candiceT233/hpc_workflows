#!/usr/bin/env bash
#SBATCH --job-name=1000genome-4node
#SBATCH --exclusive
#SBATCH --partition=compute
#SBATCH --nodes=4
#SBATCH --ntasks-per-node=8
#SBATCH --cpus-per-task=1
#SBATCH --mem=45G
#SBATCH --time=48:00:00
#SBATCH --output=runs/1000genome-workflow/slurm-%j-4node.out
#SBATCH --error=runs/1000genome-workflow/slurm-%j-4node.err

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
command -v srun

RUN_ROOT="$ROOT/runs/1000genome-workflow/4node-${SLURM_JOB_ID}"
mkdir -p "$RUN_ROOT"

export PEGASUS_1000G_REPO="$ROOT/repos/1000genome-workflow"
export PEGASUS_1000G_TRANSFORM_PFN="$ROOT/scripts/1000genome-slurm-transform.sh"
export PEGASUS_1000G_HOSTFILE="$RUN_ROOT/hosts.txt"
export PEGASUS_1000G_NODE_LOG="$RUN_ROOT/1000genome-node-dispatch.log"
export PEGASUS_1000G_COUNTER_FILE="$RUN_ROOT/1000genome-node-counter.txt"

scontrol show hostnames "$SLURM_JOB_NODELIST" > "$PEGASUS_1000G_HOSTFILE"
NODE_COUNT="$(wc -l < "$PEGASUS_1000G_HOSTFILE")"
if [ "$NODE_COUNT" -lt 4 ]; then
  echo "ERROR: expected at least 4 Slurm nodes, got $NODE_COUNT" >&2
  exit 1
fi

python3 "$ROOT/scripts/run_1000genome_pegasus.py" \
  --repo repos/1000genome-workflow \
  --run-dir "$RUN_ROOT" \
  --dir-name "codex-shell-4node-${SLURM_JOB_ID}" \
  --individuals-jobs 4 \
  2>&1 | tee "$RUN_ROOT/1000genome-pegasus.log"

test -s "$RUN_ROOT/manifest.json"
grep -q '"engine": "pegasus-shell"' "$RUN_ROOT/manifest.json"
grep -q '"expected_outputs": 140' "$RUN_ROOT/manifest.json"
grep -q '"individuals_jobs": 4' "$RUN_ROOT/manifest.json"
grep -q "SHELL_SCRIPT_FINISHED 0" "$ROOT/repos/1000genome-workflow/codex-shell-4node-${SLURM_JOB_ID}/jobstate.log"

USED_NODES="$(awk '{print $3}' "$PEGASUS_1000G_NODE_LOG" | sort -u | wc -l)"
if [ "$USED_NODES" -lt 4 ]; then
  echo "ERROR: 1000genome Pegasus transformations used only $USED_NODES nodes" >&2
  cat "$PEGASUS_1000G_NODE_LOG" >&2
  exit 2
fi

echo "1000genome native Pegasus 4-node baseline completed with $USED_NODES nodes used."
