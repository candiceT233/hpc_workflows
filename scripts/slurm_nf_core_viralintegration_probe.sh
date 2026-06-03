#!/bin/bash
#SBATCH --job-name=viralintegration-probe
#SBATCH --exclusive
#SBATCH --partition=compute
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --time=02:00:00
#SBATCH --output=runs/nf-core_viralintegration/slurm-%j-probe.out
#SBATCH --error=runs/nf-core_viralintegration/slurm-%j-probe.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

REPO="$ROOT/repos/nf-core_viralintegration"
OUTDIR="$ROOT/runs/nf-core_viralintegration/probe/results"
WORKDIR="$ROOT/runs/nf-core_viralintegration/probe/work"
NF_ENV="$ROOT/tools/conda-envs/nextflow"

mkdir -p "$ROOT/runs/nf-core_viralintegration" "$OUTDIR" "$WORKDIR" "$ROOT/tools/nextflow-home"

export JAVA_HOME="$NF_ENV"
export JAVA_CMD="$NF_ENV/bin/java"
export NXF_HOME="$ROOT/tools/nextflow-home"
export NXF_VER="24.10.5"
export NXF_OPTS="-Xms1g -Xmx4g"
export PATH="$NF_ENV/bin:$PATH"

nextflow run "$REPO" \
  -name "viralintegration_probe_${SLURM_JOB_ID:-manual}" \
  -profile test_full,docker \
  -c "$ROOT/config/nextflow_ares_local_docker.config" \
  -work-dir "$WORKDIR" \
  --outdir "$OUTDIR"
