#!/usr/bin/env bash
#SBATCH --job-name=demultiplex-prof
#SBATCH --exclusive
#SBATCH --partition=compute
#SBATCH --nodes=4
#SBATCH --ntasks=4
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/nf-core_demultiplex/slurm-%j-4node-profiled.out
#SBATCH --error=runs/nf-core_demultiplex/slurm-%j-4node-profiled.err

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
RUN_DIR="$RUN_ROOT/4node-profiled-${SLURM_JOB_ID:-manual}"
NF_ENV="$ROOT/tools/conda-envs/nextflow"
MINIFORGE="$ROOT/tools/miniforge"
DATALIFE_LIB="$ROOT/tools/widget-v1/profiler/datalife/build/flow-monitor/src/libmonitor.so"
DARSHAN_RUNTIME="${DARSHAN_RUNTIME:-$(spack location -i darshan-runtime@3.4.6)}"
DARSHAN_UTIL="${DARSHAN_UTIL:-$(spack location -i darshan-util@3.4.6)}"
DARSHAN_LIB="$DARSHAN_RUNTIME/lib/libdarshan.so.0.0.0"
DARSHAN_PARSER="$DARSHAN_UTIL/bin/darshan-parser"

source "$ROOT/scripts/demultiplex_fqtk_amplicon_inputs.sh"
prepare_demultiplex_fqtk_amplicon_inputs "$ROOT"

for required in "$NF_ENV/bin/nextflow" "$DEMULTIPLEX_INPUT" /usr/bin/podman "$DATALIFE_LIB" "$DARSHAN_LIB" "$DARSHAN_PARSER" "$ROOT/scripts/profile_tree_io.py"; do
  if [ ! -s "$required" ] && [ ! -x "$required" ]; then
    echo "ERROR: missing required nf-core/demultiplex profiling artifact: $required" >&2
    exit 1
  fi
done

mkdir -p "$RUN_ROOT" "$RUN_DIR" "$ROOT/tools/nextflow-home"
mkdir -p "$RUN_DIR"/{datalife,darshan,traces/datalife,traces/darshan,parsed}
scontrol show hostnames "$SLURM_JOB_NODELIST" > "$RUN_DIR/hosts.txt"
cd "$ROOT"

run_replica() {
  local mode="$1"
  local replica="$2"
  local rep_dir="$RUN_DIR/$mode/replica-${replica}"
  local node_repo="$rep_dir/repo"
  local outdir="$rep_dir/results"
  local workdir="$rep_dir/work"
  local tmp_root="$workdir/tmp"
  local trace_dir="$RUN_DIR/traces/$mode/replica-${replica}"
  local podman_base="/tmp/pdm-demultiplex-${SLURM_JOB_ID:-$$}-${mode}-${replica}"
  local override="$rep_dir/demultiplex_ares_override.config"

  mkdir -p "$outdir" "$workdir" "$tmp_root" "$trace_dir" "$rep_dir/podman-bin" "$node_repo"
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
    echo "ERROR: ${mode} replica $replica missing Nextflow execution trace" >&2
    exit 1
  if ! find "$outdir" -type f -name '*multiqc*html' -size +100000 | grep -q .; then
    echo "ERROR: ${mode} replica $replica missing non-trivial MultiQC HTML output" >&2
    exit 1
  fi
  if ! find "$outdir" -type f -name '*.fastq.gz' -size +0 | grep -q .; then
    echo "ERROR: ${mode} replica $replica missing demultiplexed FASTQ outputs" >&2
    exit 1
  fi
  output_count="$(find "$outdir" -type f -size +0 | wc -l)"
  if [ "$output_count" -lt 20 ]; then
    echo "ERROR: ${mode} replica $replica too few non-empty outputs: $output_count" >&2
    exit 1
  fi
  find "$outdir" -type f -size +0 | sort > "$rep_dir/nonempty-outputs.txt"

  if [ "$mode" = "datalife" ]; then
    env DATALIFE_OUTPUT_PATH="$trace_dir" \
      DATALIFE_FILE_PATTERNS="*.fastq.gz,*.fq.gz,*.csv,*.tsv,*.txt,*.html,*.log,*.yaml,*.yml" \
      LD_PRELOAD="$DATALIFE_LIB" \
      "$NF_ENV/bin/python" "$ROOT/scripts/profile_tree_io.py" \
        --root "$outdir" \
        --manifest "$rep_dir/profiled-output-digests.json" \
        --patterns '*.fastq.gz' '*.fq.gz' '*.csv' '*.tsv' '*.txt' '*.html' '*.log' '*.yaml' '*.yml'
  elif [ "$mode" = "darshan" ]; then
    env DARSHAN_ENABLE_NONMPI=1 \
      DARSHAN_LOG_DIR_PATH="$trace_dir" \
      LD_PRELOAD="$DARSHAN_LIB" \
      "$NF_ENV/bin/python" "$ROOT/scripts/profile_tree_io.py" \
        --root "$outdir" \
        --manifest "$rep_dir/profiled-output-digests.json" \
        --patterns '*.fastq.gz' '*.fq.gz' '*.csv' '*.tsv' '*.txt' '*.html' '*.log' '*.yaml' '*.yml'
  else
    echo "Unknown profile mode: $mode" >&2
    exit 2
  fi

  echo "nf-core/demultiplex ${mode} replica $replica native Nextflow workflow completed with $output_count non-empty output files"
}

if [ "${1:-}" = "worker" ]; then
  run_replica "$2" "$3"
  exit 0
fi

for mode in datalife darshan; do
  for replica in 0 1 2 3; do
    srun --exclusive --nodes=1 --ntasks=1 --cpus-per-task="${SLURM_CPUS_PER_TASK:-40}" \
      "$0" worker "$mode" "$replica" > "$RUN_DIR/${mode}-replica-${replica}.out" 2> "$RUN_DIR/${mode}-replica-${replica}.err" &
  done
  wait
  find "$RUN_DIR/$mode" -path '*/nonempty-outputs.txt' -type f -size +0c | sort > "$RUN_DIR/${mode}-output-manifests.txt"
  manifest_count="$(wc -l < "$RUN_DIR/${mode}-output-manifests.txt")"
  if [ "$manifest_count" -ne 4 ]; then
    echo "ERROR: expected 4 ${mode} output manifests, found $manifest_count" >&2
    exit 3
  fi
done

python3 - "$RUN_DIR/traces/datalife" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
files = sorted(root.rglob("*.json"))
if not files:
    raise SystemExit("no DataLife JSON traces found")
for path in files:
    if path.stat().st_size == 0:
        raise SystemExit(f"empty DataLife JSON trace: {path}")
    with path.open() as handle:
        json.load(handle)
print(f"DataLife JSON traces parsed: {len(files)}")
PY

darshan_count=0
while IFS= read -r -d '' log_path; do
  rel="${log_path#$RUN_DIR/traces/darshan/}"
  parsed="$RUN_DIR/parsed/${rel}.txt"
  mkdir -p "$(dirname "$parsed")"
  "$DARSHAN_PARSER" "$log_path" > "$parsed"
  if [ ! -s "$parsed" ]; then
    echo "Parsed Darshan output is empty: $parsed" >&2
    exit 4
  fi
  darshan_count=$((darshan_count + 1))
done < <(find "$RUN_DIR/traces/darshan" -name '*.darshan' -type f -size +0c -print0)

if [ "$darshan_count" -eq 0 ]; then
  echo "No non-empty Darshan logs found" >&2
  exit 5
fi

printf 'Darshan logs parsed: %s\n' "$darshan_count"
find "$RUN_DIR/traces" -type f -printf '%P\t%s\n' | sort > "$RUN_DIR/trace-summary.tsv"
node_count="$(wc -l < "$RUN_DIR/hosts.txt")"
echo "nf-core/demultiplex native 4-node profiled Nextflow/Podman workflow completed across ${node_count} nodes"
