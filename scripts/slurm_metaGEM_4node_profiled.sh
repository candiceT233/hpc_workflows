#!/usr/bin/env bash
#SBATCH --job-name=metaGEM-prof
#SBATCH --exclusive
#SBATCH --partition=compute
#SBATCH --nodes=4
#SBATCH --ntasks=4
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/metaGEM/slurm-%j-4node-profiled.out
#SBATCH --error=runs/metaGEM/slurm-%j-4node-profiled.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

REPO="$ROOT/repos/metaGEM"
RUN_ROOT="$ROOT/runs/metaGEM"
RUN_DIR="$RUN_ROOT/4node-profiled-${SLURM_JOB_ID:-manual}"
DATA_ROOT="$ROOT/data/metaGEM/full"
ENV_ROOT="$ROOT/tools/conda-envs/metagem-fastp"
DATALIFE_LIB="$ROOT/tools/widget-v1/profiler/datalife/build/flow-monitor/src/libmonitor.so"
DARSHAN_RUNTIME="${DARSHAN_RUNTIME:-$(spack location -i darshan-runtime@3.4.6)}"
DARSHAN_UTIL="${DARSHAN_UTIL:-$(spack location -i darshan-util@3.4.6)}"
DARSHAN_LIB="$DARSHAN_RUNTIME/lib/libdarshan.so.0.0.0"
DARSHAN_PARSER="$DARSHAN_UTIL/bin/darshan-parser"

for required in "$DATALIFE_LIB" "$DARSHAN_LIB" "$DARSHAN_PARSER" "$ROOT/scripts/profile_tree_io.py"; do
  if [ ! -s "$required" ]; then
    echo "Required profiling artifact missing: $required" >&2
    exit 2
  fi
done

mkdir -p "$RUN_ROOT" "$RUN_DIR" "$DATA_ROOT" "$ROOT/tools/conda-pkgs"
mkdir -p "$RUN_DIR"/{datalife,darshan,traces/datalife,traces/darshan,parsed}
scontrol show hostnames "$SLURM_JOB_NODELIST" > "$RUN_DIR/hosts.txt"
cd "$ROOT"

export PATH="$ROOT/tools/miniforge/bin:$PATH"
export CONDA_PKGS_DIRS="$ROOT/tools/conda-pkgs"

download_fastq() {
  local url="$1"
  local dest="$2"
  local tmp="${dest}.part"
  local attempt

  if [ -s "$dest" ] && gzip -t "$dest" >/dev/null 2>&1; then
    return 0
  fi
  if [ -s "$dest" ] && [ ! -s "$tmp" ]; then
    mv "$dest" "$tmp"
  fi

  for attempt in $(seq 1 20); do
    if curl -L --fail --retry 8 --retry-delay 20 --retry-all-errors --continue-at - -o "$tmp" "$url" \
      && gzip -t "$tmp" >/dev/null 2>&1; then
      mv "$tmp" "$dest"
      return 0
    fi
    sleep 30
  done

  echo "ERROR: failed to download and validate $url -> $dest" >&2
  return 1
}

stage_metagenome_sample() {
  local sample="$1"
  local r1_url="$2"
  local r2_url="$3"
  local sample_dir="$DATA_ROOT/$sample"
  mkdir -p "$sample_dir"
  download_fastq "$r1_url" "$sample_dir/${sample}_R1.fastq.gz"
  download_fastq "$r2_url" "$sample_dir/${sample}_R2.fastq.gz"
}

prepare_shared_inputs() {
  stage_metagenome_sample ERR2011066 \
    https://ftp.sra.ebi.ac.uk/vol1/fastq/ERR201/006/ERR2011066/ERR2011066_1.fastq.gz \
    https://ftp.sra.ebi.ac.uk/vol1/fastq/ERR201/006/ERR2011066/ERR2011066_2.fastq.gz
  stage_metagenome_sample ERR2011071 \
    https://ftp.sra.ebi.ac.uk/vol1/fastq/ERR201/001/ERR2011071/ERR2011071_1.fastq.gz \
    https://ftp.sra.ebi.ac.uk/vol1/fastq/ERR201/001/ERR2011071/ERR2011071_2.fastq.gz
  stage_metagenome_sample ERR2011072 \
    https://ftp.sra.ebi.ac.uk/vol1/fastq/ERR201/002/ERR2011072/ERR2011072_1.fastq.gz \
    https://ftp.sra.ebi.ac.uk/vol1/fastq/ERR201/002/ERR2011072/ERR2011072_2.fastq.gz

  find "$DATA_ROOT" -type f -name '*.fastq.gz' -print0 | while IFS= read -r -d '' fastq; do
    gzip -t "$fastq"
  done
}

prepare_env() {
  if [ ! -x "$ENV_ROOT/bin/fastp" ]; then
    conda create -y -p "$ENV_ROOT" -c bioconda -c conda-forge fastp
  fi
}

run_replica() {
  local mode="$1"
  local replica="$2"
  local rep_dir="$RUN_DIR/$mode/replica-${replica}"
  local workdir="$rep_dir/workdir"
  local scratch="$rep_dir/scratch"
  local trace_dir="$RUN_DIR/traces/$mode/replica-${replica}"

  mkdir -p "$workdir" "$scratch" "$trace_dir"
  rm -rf "$workdir/config" "$workdir/workflow" "$workdir/scripts"
  cp -a "$REPO/config" "$workdir/config"
  cp -a "$REPO/workflow" "$workdir/workflow"
  cp -a "$REPO/workflow/scripts" "$workdir/scripts"
  cp "$REPO/config/config.yaml" "$workdir/config.yaml"

  python3 - "$workdir/config.yaml" "$workdir" "$scratch" "$ENV_ROOT" "$ROOT" <<'PY'
import sys
from pathlib import Path

config = Path(sys.argv[1])
workdir = sys.argv[2]
scratch = sys.argv[3]
env_root = sys.argv[4]
root = sys.argv[5]
text = config.read_text()
text = text.replace(f"{root}/runs/metaGEM/single/workdir", workdir)
text = text.replace(f"{root}/runs/metaGEM/single/scratch", scratch)
text = text.replace(f"{workdir}/envs/metagem", env_root)
config.write_text(text)
PY
  cp "$workdir/config.yaml" "$workdir/config/config.yaml"
  mkdir -p "$rep_dir/config"
  cp "$workdir/config.yaml" "$rep_dir/config/config.yaml"

  for sample in ERR2011066 ERR2011071 ERR2011072; do
    mkdir -p "$workdir/dataset/$sample"
    ln -sf "$DATA_ROOT/$sample/${sample}_R1.fastq.gz" "$workdir/dataset/$sample/${sample}_R1.fastq.gz"
    ln -sf "$DATA_ROOT/$sample/${sample}_R2.fastq.gz" "$workdir/dataset/$sample/${sample}_R2.fastq.gz"
  done

  cd "$workdir"
  "$ROOT/tools/conda-envs/snakemake9/bin/snakemake" -s workflow/Snakefile --unlock -j 1 || true
  "$ROOT/tools/conda-envs/snakemake9/bin/snakemake" -s workflow/Snakefile createFolders -j 1 --printshellcmds
  "$ROOT/tools/conda-envs/snakemake9/bin/snakemake" -s workflow/Snakefile all \
    -j "${SLURM_CPUS_PER_TASK:-40}" \
    --rerun-incomplete \
    --printshellcmds \
    --latency-wait 120

  find "$workdir/qfiltered" -type f -size +0c | sort > "$rep_dir/nonempty-qfiltered.txt"
  for sample in ERR2011066 ERR2011071 ERR2011072; do
    test -s "$workdir/qfiltered/$sample/${sample}_R1.fastq.gz"
    test -s "$workdir/qfiltered/$sample/${sample}_R2.fastq.gz"
    test -s "$workdir/qfiltered/$sample/${sample}.json"
    test -s "$workdir/qfiltered/$sample/${sample}.html"
  done

  if [ "$mode" = "datalife" ]; then
    env DATALIFE_OUTPUT_PATH="$trace_dir" \
      DATALIFE_FILE_PATTERNS="*.fastq.gz,*.json,*.html,*.log,*.txt" \
      LD_PRELOAD="$DATALIFE_LIB" \
      python3 "$ROOT/scripts/profile_tree_io.py" \
        --root "$workdir/qfiltered" \
        --manifest "$rep_dir/profiled-output-digests.json" \
        --patterns '*.fastq.gz' '*.json' '*.html' '*.log' '*.txt'
  elif [ "$mode" = "darshan" ]; then
    env DARSHAN_ENABLE_NONMPI=1 \
      DARSHAN_LOG_DIR_PATH="$trace_dir" \
      LD_PRELOAD="$DARSHAN_LIB" \
      python3 "$ROOT/scripts/profile_tree_io.py" \
        --root "$workdir/qfiltered" \
        --manifest "$rep_dir/profiled-output-digests.json" \
        --patterns '*.fastq.gz' '*.json' '*.html' '*.log' '*.txt'
  else
    echo "Unknown profile mode: $mode" >&2
    exit 2
  fi

  echo "metaGEM ${mode} replica $replica native Snakemake qfilter completed"
}

if [ "${1:-}" = "worker" ]; then
  run_replica "$2" "$3"
  exit 0
fi

prepare_shared_inputs
prepare_env

for mode in datalife darshan; do
  mkdir -p "$RUN_DIR/$mode"
  for replica in 0 1 2 3; do
    srun --exclusive --nodes=1 --ntasks=1 --cpus-per-task="${SLURM_CPUS_PER_TASK:-40}" \
      "$0" worker "$mode" "$replica" > "$RUN_DIR/${mode}-replica-${replica}.out" 2> "$RUN_DIR/${mode}-replica-${replica}.err" &
  done
  wait

  find "$RUN_DIR/$mode" -path '*/nonempty-qfiltered.txt' -type f -size +0c | sort > "$RUN_DIR/${mode}-qfiltered-manifests.txt"
  manifest_count="$(wc -l < "$RUN_DIR/${mode}-qfiltered-manifests.txt")"
  if [ "$manifest_count" -ne 4 ]; then
    echo "ERROR: expected 4 ${mode} qfiltered manifests, found $manifest_count" >&2
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
echo "metaGEM native 4-node profiled Snakemake qfilter workflow completed across ${node_count} nodes"
