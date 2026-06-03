#!/usr/bin/env bash
#SBATCH --job-name=demultiplex-4node
#SBATCH --exclusive
#SBATCH --partition=compute
#SBATCH --nodes=4
#SBATCH --ntasks=4
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/nf-core_demultiplex/slurm-%j-4node.out
#SBATCH --error=runs/nf-core_demultiplex/slurm-%j-4node.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

REPO="$ROOT/repos/nf-core_demultiplex"
RUN_ROOT="$ROOT/runs/nf-core_demultiplex"
RUN_DIR="$RUN_ROOT/4node-${SLURM_JOB_ID:-manual}"
NF_ENV="$ROOT/tools/conda-envs/nextflow"
MINIFORGE="$ROOT/tools/miniforge"

mkdir -p "$RUN_ROOT" "$RUN_DIR" "$ROOT/tools/nextflow-home"
cd "$ROOT"

source "$ROOT/scripts/demultiplex_fqtk_amplicon_inputs.sh"
prepare_demultiplex_fqtk_amplicon_inputs "$ROOT"

for required in "$NF_ENV/bin/nextflow" "$DEMULTIPLEX_INPUT" /usr/bin/podman; do
  if [ ! -s "$required" ] && [ ! -x "$required" ]; then
    echo "ERROR: missing required nf-core/demultiplex input or executable: $required" >&2
    exit 1
  fi
done

run_replica() {
  local replica="$1"
  local rep_dir="$RUN_DIR/replica-${replica}"
  local node_repo="$rep_dir/repo"
  local outdir="$rep_dir/results"
  local workdir="$rep_dir/work"
  local tmp_root="$workdir/tmp"
  local podman_base="/tmp/pdm-demultiplex-${SLURM_JOB_ID:-$$}-${replica}"
  local override="$rep_dir/demultiplex_ares_override.config"

  mkdir -p "$outdir" "$workdir" "$tmp_root" "$rep_dir/podman-bin" "$node_repo"
  cp -a "$REPO/." "$node_repo/"
  export TMPDIR="$tmp_root"
  export NXF_TEMP="$tmp_root"
  export XDG_RUNTIME_DIR="$podman_base/xdg"
  mkdir -p "$XDG_RUNTIME_DIR" "$podman_base/root" "$podman_base/run" "$podman_base/tmp"
  chmod 700 "$XDG_RUNTIME_DIR"
  local podman_real
  podman_real="$(command -v podman || true)"
  if [ -z "$podman_real" ]; then
    echo "ERROR: podman is not available on this compute node" >&2
    exit 1
  fi
  cat > "$rep_dir/podman-bin/podman" <<EOF
#!/bin/bash
exec "$podman_real" --root "$podman_base/root" --runroot "$podman_base/run" --tmpdir "$podman_base/tmp" "\$@"
EOF
  chmod +x "$rep_dir/podman-bin/podman"

  cat > "$override" <<'EOF'
process {
  withLabel:process_high {
    cpus = 12
    memory = 45.GB
    time = 24.h
  }
  withName:BCL2FASTQ {
    cpus = 12
    memory = 45.GB
    time = 24.h
  }
}
params.max_memory = '40.GB'
params.max_cpus = 40
params.max_time = '48.h'
EOF

  export _JAVA_OPTIONS="${_JAVA_OPTIONS:-} -Djava.io.tmpdir=$tmp_root"
  export JAVA_HOME="$NF_ENV"
  export JAVA_CMD="$NF_ENV/bin/java"
  export NXF_HOME="$ROOT/tools/nextflow-home"
  export NXF_OFFLINE=true
  export NXF_VER=26.04.1
  export NXF_OPTS="-Xms1g -Xmx8g"
  export NXF_SYNTAX_PARSER=v1
  export PATH="$rep_dir/podman-bin:$NF_ENV/bin:$MINIFORGE/bin:$MINIFORGE/condabin:$PATH"

  cd "$rep_dir"
  nextflow run "$node_repo" \
    -profile podman \
    -c "$ROOT/config/nextflow_ares_local_podman.config" \
    -c "$override" \
    -work-dir "$workdir" \
    --input "$DEMULTIPLEX_INPUT" \
    --demultiplexer "$DEMULTIPLEX_DEMUXER" \
    --outdir "$outdir"

  if ! find "$outdir/pipeline_info" -maxdepth 1 -type f -name 'execution_trace*' -size +0 | grep -q .; then
    echo "ERROR: replica $replica missing Nextflow execution trace" >&2
    exit 1
  fi
  if ! find "$outdir" -type f -name '*multiqc*html' -size +100000 | grep -q .; then
    echo "ERROR: replica $replica missing non-trivial MultiQC HTML output" >&2
    exit 1
  fi
  if ! find "$outdir" -type f -name '*.fastq.gz' -size +0 | grep -q .; then
    echo "ERROR: replica $replica missing demultiplexed FASTQ outputs" >&2
    exit 1
  fi
  output_count="$(find "$outdir" -type f -size +0 | wc -l)"
  if [ "$output_count" -lt 20 ]; then
    echo "ERROR: replica $replica too few non-empty outputs: $output_count" >&2
    exit 1
  fi
  find "$outdir" -type f -size +0 | sort > "$rep_dir/nonempty-outputs.txt"
  echo "nf-core/demultiplex replica $replica native Nextflow baseline completed with $output_count non-empty output files"
}

if [ "${1:-}" = "worker" ]; then
  run_replica "$2"
  exit 0
fi

for replica in 0 1 2 3; do
  srun --exclusive --nodes=1 --ntasks=1 --cpus-per-task="${SLURM_CPUS_PER_TASK:-40}" \
    "$0" worker "$replica" > "$RUN_DIR/replica-${replica}.out" 2> "$RUN_DIR/replica-${replica}.err" &
done
wait

for replica in 0 1 2 3; do
  test -s "$RUN_DIR/replica-${replica}/nonempty-outputs.txt"
done

echo "nf-core/demultiplex native 4-node Nextflow/Podman baseline completed across 4 nodes"
