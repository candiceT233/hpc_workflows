#!/usr/bin/env bash
#SBATCH --job-name=fetchngs-prof
#SBATCH --exclusive
#SBATCH --partition=compute
#SBATCH --nodes=4
#SBATCH --ntasks=4
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/nf-core_fetchngs/slurm-%j-4node-profiled.out
#SBATCH --error=runs/nf-core_fetchngs/slurm-%j-4node-profiled.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

REPO="$ROOT/repos/nf-core_fetchngs"
INPUT="$ROOT/data/nf-core_fetchngs/full_srp227242/sra_ids.csv"
RUN_ROOT="$ROOT/runs/nf-core_fetchngs"
RUN_DIR="$RUN_ROOT/4node-profiled-${SLURM_JOB_ID:-manual}"
NF_ENV="$ROOT/tools/conda-envs/nextflow"
MINIFORGE="$ROOT/tools/miniforge"
DATALIFE_LIB="$ROOT/tools/widget-v1/profiler/datalife/build/flow-monitor/src/libmonitor.so"
DARSHAN_RUNTIME="${DARSHAN_RUNTIME:-$(spack location -i darshan-runtime@3.4.6)}"
DARSHAN_UTIL="${DARSHAN_UTIL:-$(spack location -i darshan-util@3.4.6)}"
DARSHAN_LIB="$DARSHAN_RUNTIME/lib/libdarshan.so.0.0.0"
DARSHAN_PARSER="$DARSHAN_UTIL/bin/darshan-parser"

for required in "$NF_ENV/bin/nextflow" "$DATALIFE_LIB" "$DARSHAN_LIB" "$DARSHAN_PARSER" "$ROOT/scripts/profile_tree_io.py"; do
  if [ ! -s "$required" ] && [ ! -x "$required" ]; then
    echo "ERROR: missing required nf-core/fetchngs profiling artifact: $required" >&2
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
  local outdir="$rep_dir/results"
  local workdir="$rep_dir/work"
  local tmp_root="$workdir/tmp"
  local pkgs_root="$rep_dir/conda-pkgs"
  local cache_root="$rep_dir/nextflow-conda-cache"
  local trace_dir="$RUN_DIR/traces/$mode/replica-${replica}"
  local condarc="$rep_dir/condarc"
  local override="$rep_dir/fetchngs_ares_override.config"

  mkdir -p "$outdir" "$workdir" "$tmp_root" "$pkgs_root" "$cache_root" "$trace_dir"
  export TMPDIR="$tmp_root"
  export NXF_TEMP="$tmp_root"
  export CONDA_PKGS_DIRS="$pkgs_root"
  export _JAVA_OPTIONS="${_JAVA_OPTIONS:-} -Djava.io.tmpdir=$tmp_root"
  export MAMBA_YES=true
  export MAMBA_ALWAYS_YES=true
  export CONDA_ALWAYS_YES=true
  cat > "$condarc" <<'EOF'
always_yes: true
auto_activate_base: false
channel_priority: flexible
channels:
  - conda-forge
  - bioconda
  - defaults
EOF
  export CONDARC="$condarc"

  cat > "$override" <<EOF
conda {
  enabled = true
  useMamba = true
  cacheDir = "$cache_root"
  createTimeout = '90 min'
}
process.maxForks = 2
EOF

  export JAVA_HOME="$NF_ENV"
  export JAVA_CMD="$NF_ENV/bin/java"
  export NXF_HOME="$ROOT/tools/nextflow-home"
export NXF_OFFLINE=true
  export NXF_VER=22.10.6
  export NXF_OPTS="-Xms1g -Xmx8g"
  export NXF_SYNTAX_PARSER=v1
  export PATH="$NF_ENV/bin:$MINIFORGE/bin:$MINIFORGE/condabin:$PATH"

  cd "$rep_dir"
  nextflow run "$REPO" \
    -profile conda \
    -c "$ROOT/config/nextflow_ares_local_conda.config" \
    -c "$override" \
    -work-dir "$workdir" \
    --input "$INPUT" \
    --nf_core_pipeline rnaseq \
    --outdir "$outdir"

  if ! find "$outdir/pipeline_info" -maxdepth 1 -type f -name 'execution_trace*' -size +0 | grep -q .; then
    echo "ERROR: ${mode} replica $replica missing Nextflow execution trace" >&2
    exit 1
  fi
  if [ ! -s "$outdir/samplesheet/samplesheet.csv" ] || [ ! -s "$outdir/samplesheet/id_mappings.csv" ]; then
    echo "ERROR: ${mode} replica $replica missing generated samplesheet or ID mappings" >&2
    exit 1
  fi
  fastq_count="$(find "$outdir/fastq" -type f -name '*.fastq.gz' -size +0 2>/dev/null | wc -l)"
  if [ "$fastq_count" -lt 8 ]; then
    echo "ERROR: ${mode} replica $replica too few non-empty FASTQ outputs: $fastq_count" >&2
    exit 1
  fi
  output_count="$(find "$outdir" -type f -size +0 | wc -l)"
  if [ "$output_count" -lt 12 ]; then
    echo "ERROR: ${mode} replica $replica too few non-empty outputs: $output_count" >&2
    exit 1
  fi
  find "$outdir" -type f -size +0 | sort > "$rep_dir/nonempty-outputs.txt"

  if [ "$mode" = "datalife" ]; then
    env DATALIFE_OUTPUT_PATH="$trace_dir" \
      DATALIFE_FILE_PATTERNS="*.fastq.gz,*.fq.gz,*.csv,*.tsv,*.txt,*.html,*.json,*.log,*.yaml,*.yml" \
      LD_PRELOAD="$DATALIFE_LIB" \
      "$NF_ENV/bin/python" "$ROOT/scripts/profile_tree_io.py" \
        --root "$outdir" \
        --manifest "$rep_dir/profiled-output-digests.json" \
        --patterns '*.fastq.gz' '*.fq.gz' '*.csv' '*.tsv' '*.txt' '*.html' '*.json' '*.log' '*.yaml' '*.yml'
  elif [ "$mode" = "darshan" ]; then
    env DARSHAN_ENABLE_NONMPI=1 \
      DARSHAN_LOG_DIR_PATH="$trace_dir" \
      LD_PRELOAD="$DARSHAN_LIB" \
      "$NF_ENV/bin/python" "$ROOT/scripts/profile_tree_io.py" \
        --root "$outdir" \
        --manifest "$rep_dir/profiled-output-digests.json" \
        --patterns '*.fastq.gz' '*.fq.gz' '*.csv' '*.tsv' '*.txt' '*.html' '*.json' '*.log' '*.yaml' '*.yml'
  else
    echo "Unknown profile mode: $mode" >&2
    exit 2
  fi

  echo "nf-core/fetchngs ${mode} replica $replica native Nextflow workflow completed with $fastq_count FASTQs and $output_count non-empty output files"
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
echo "nf-core/fetchngs native 4-node profiled Nextflow workflow completed across ${node_count} nodes"
