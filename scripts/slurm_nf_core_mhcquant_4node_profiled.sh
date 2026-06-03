#!/usr/bin/env bash
#SBATCH --job-name=mhcquant-prof
#SBATCH --exclusive
#SBATCH --partition=compute
#SBATCH --nodes=4
#SBATCH --ntasks=4
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/nf-core_mhcquant/slurm-%j-4node-profiled.out
#SBATCH --error=runs/nf-core_mhcquant/slurm-%j-4node-profiled.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

REPO="$ROOT/repos/nf-core_mhcquant"
DATA_DIR="$ROOT/data/nf-core_mhcquant/full_uniprot"
SOURCE_INPUT="$DATA_DIR/sample_sheet_full_https.tsv"
RAW_DIR="$DATA_DIR/raw"
FASTA_DIR="$DATA_DIR/fasta"
INPUT="$DATA_DIR/sample_sheet_full_local.tsv"
RUN_ROOT="$ROOT/runs/nf-core_mhcquant"
RUN_DIR="$RUN_ROOT/4node-profiled-${SLURM_JOB_ID:-manual}"
NF_ENV="$ROOT/tools/conda-envs/nextflow"
MINIFORGE="$ROOT/tools/miniforge"
DATALIFE_LIB="$ROOT/tools/widget-v1/profiler/datalife/build/flow-monitor/src/libmonitor.so"
DARSHAN_RUNTIME="${DARSHAN_RUNTIME:-$(spack location -i darshan-runtime@3.4.6)}"
DARSHAN_UTIL="${DARSHAN_UTIL:-$(spack location -i darshan-util@3.4.6)}"
DARSHAN_LIB="$DARSHAN_RUNTIME/lib/libdarshan.so.0.0.0"
DARSHAN_PARSER="$DARSHAN_UTIL/bin/darshan-parser"

for required in "$NF_ENV/bin/nextflow" "$DATALIFE_LIB" "$DARSHAN_LIB" "$DARSHAN_PARSER" "$ROOT/scripts/profile_tree_io.py" "$SOURCE_INPUT"; do
  if [ ! -s "$required" ] && [ ! -x "$required" ]; then
    echo "ERROR: missing required nf-core/mhcquant profiling artifact: $required" >&2
    exit 1
  fi
done

mkdir -p "$RUN_ROOT" "$RUN_DIR" "$ROOT/tools/nextflow-home" "$RAW_DIR" "$FASTA_DIR"
mkdir -p "$RUN_DIR"/{datalife,darshan,traces/datalife,traces/darshan,parsed}
scontrol show hostnames "$SLURM_JOB_NODELIST" > "$RUN_DIR/hosts.txt"
cd "$ROOT"

remote_size() {
  local url="$1"
  curl -sIL --fail "$url" | awk 'tolower($1) == "content-length:" { size=$2 } END { gsub("\r", "", size); print size }'
}

download_file() {
  local url="$1"
  local dest="$2"
  local tmp="${dest}.part"
  local expected actual attempt
  expected="$(remote_size "$url" || true)"
  actual="0"
  if [ -s "$dest" ]; then
    actual="$(stat -c '%s' "$dest")"
  fi
  if [ -n "$expected" ] && [ "$actual" = "$expected" ]; then
    return 0
  fi
  if [ -z "$expected" ] && [ -s "$dest" ]; then
    return 0
  fi
  if [ -s "$dest" ] && [ ! -s "$tmp" ]; then
    mv "$dest" "$tmp"
  fi
  if [ -n "$expected" ] && [ -s "$tmp" ] && [ "$(stat -c '%s' "$tmp")" -gt "$expected" ]; then
    rm -f "$tmp"
  fi
  for attempt in $(seq 1 20); do
    if curl -L --fail --retry 8 --retry-delay 15 --retry-all-errors --continue-at - "$url" -o "$tmp"; then
      actual="$(stat -c '%s' "$tmp")"
      if [ -z "$expected" ] || [ "$actual" = "$expected" ]; then
        mv "$tmp" "$dest"
        return 0
      fi
      echo "download size mismatch for $url: got $actual expected $expected" >&2
    fi
    sleep 30
  done
  echo "ERROR: failed to download and validate $url -> $dest" >&2
  return 1
}

prepare_input() {
  {
    IFS= read -r header
    printf '%s\n' "$header"
    while IFS=$'\t' read -r id sample condition replicate fasta; do
      [ -n "$id" ] || continue
      raw_dest="$RAW_DIR/$(basename "$replicate")"
      fasta_gz_dest="$FASTA_DIR/$(basename "$fasta")"
      fasta_dest="${fasta_gz_dest%.gz}"
      download_file "$replicate" "$raw_dest"
      download_file "$fasta" "$fasta_gz_dest"
      if [ ! -s "$fasta_dest" ] || [ "$fasta_gz_dest" -nt "$fasta_dest" ]; then
        gzip -dc "$fasta_gz_dest" > "$fasta_dest.tmp"
        mv "$fasta_dest.tmp" "$fasta_dest"
      fi
      printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$sample" "$condition" "$raw_dest" "$fasta_dest"
    done
  } < "$SOURCE_INPUT" > "$INPUT.tmp"
  mv "$INPUT.tmp" "$INPUT"
}

prepare_input

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
  local override="$rep_dir/mhcquant_ares_override.config"

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
process.maxForks = 4
EOF

  export JAVA_HOME="$NF_ENV"
  export JAVA_CMD="$NF_ENV/bin/java"
  export NXF_HOME="$ROOT/tools/nextflow-home"
export NXF_OFFLINE=true
  export NXF_VER=26.04.1
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
    --outdir "$outdir"

  if ! find "$outdir/pipeline_info" -maxdepth 1 -type f -name 'execution_trace*' -size +0 | grep -q .; then
    echo "ERROR: ${mode} replica $replica missing Nextflow execution trace" >&2
    exit 1
  fi
  if ! find "$outdir/multiqc" -type f -name 'multiqc_report.html' -size +100000 | grep -q .; then
    echo "ERROR: ${mode} replica $replica missing non-trivial MultiQC report" >&2
    exit 1
  fi
  if ! find "$outdir" -type f \( -name '*.tsv' -o -name '*.mzTab' -o -name '*.idXML' \) -size +0 | grep -q .; then
    echo "ERROR: ${mode} replica $replica missing peptide identification/quantification outputs" >&2
    exit 1
  fi
  if ! find "$outdir/intermediate_results" -type f -size +0 | grep -q .; then
    echo "ERROR: ${mode} replica $replica missing non-empty intermediate search outputs" >&2
    exit 1
  fi
  output_count="$(find "$outdir" -type f -size +0 | wc -l)"
  if [ "$output_count" -lt 30 ]; then
    echo "ERROR: ${mode} replica $replica too few non-empty MHCquant outputs: $output_count" >&2
    exit 1
  fi
  find "$outdir" -type f -size +0 | sort > "$rep_dir/nonempty-outputs.txt"

  if [ "$mode" = "datalife" ]; then
    env DATALIFE_OUTPUT_PATH="$trace_dir" \
      DATALIFE_FILE_PATTERNS="*.raw,*.mzML,*.mzTab,*.idXML,*.tsv,*.csv,*.txt,*.fasta,*.fa,*.html,*.json,*.log,*.pdf,*.png" \
      LD_PRELOAD="$DATALIFE_LIB" \
      "$NF_ENV/bin/python" "$ROOT/scripts/profile_tree_io.py" \
        --root "$outdir" \
        --manifest "$rep_dir/profiled-output-digests.json" \
        --patterns '*.raw' '*.mzML' '*.mzTab' '*.idXML' '*.tsv' '*.csv' '*.txt' '*.fasta' '*.fa' '*.html' '*.json' '*.log' '*.pdf' '*.png'
  elif [ "$mode" = "darshan" ]; then
    env DARSHAN_ENABLE_NONMPI=1 \
      DARSHAN_LOG_DIR_PATH="$trace_dir" \
      LD_PRELOAD="$DARSHAN_LIB" \
      "$NF_ENV/bin/python" "$ROOT/scripts/profile_tree_io.py" \
        --root "$outdir" \
        --manifest "$rep_dir/profiled-output-digests.json" \
        --patterns '*.raw' '*.mzML' '*.mzTab' '*.idXML' '*.tsv' '*.csv' '*.txt' '*.fasta' '*.fa' '*.html' '*.json' '*.log' '*.pdf' '*.png'
  else
    echo "Unknown profile mode: $mode" >&2
    exit 2
  fi

  echo "nf-core/mhcquant ${mode} replica $replica native Nextflow workflow completed with $output_count non-empty output files"
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
echo "nf-core/mhcquant native 4-node profiled Nextflow workflow completed across ${node_count} nodes"
