#!/usr/bin/env bash
#SBATCH --job-name=dna-gatk-prof
#SBATCH --exclusive
#SBATCH --partition=compute
#SBATCH --nodes=4
#SBATCH --ntasks=4
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/dna-seq-gatk-variant-calling/slurm-%j-4node-profiled.out
#SBATCH --error=runs/dna-seq-gatk-variant-calling/slurm-%j-4node-profiled.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

RUN_ROOT="$ROOT/runs/dna-seq-gatk-variant-calling"
RUN_DIR="$RUN_ROOT/4node-profiled-${SLURM_JOB_ID:-manual}"
CONDA_PREFIX_DIR="$ROOT/tools/conda-envs/dna-seq-gatk"
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

mkdir -p "$RUN_ROOT" "$RUN_DIR" "$CONDA_PREFIX_DIR" "$ROOT/tools/conda-pkgs/dna-seq-gatk"
mkdir -p "$RUN_DIR"/{datalife,darshan,traces/datalife,traces/darshan,parsed}
scontrol show hostnames "$SLURM_JOB_NODELIST" > "$RUN_DIR/hosts.txt"
cd "$ROOT"

export PATH="$ROOT/tools/miniforge/bin:$ROOT/tools/snakemake-venv/bin:$PATH"
export CONDA_PKGS_DIRS="$ROOT/tools/conda-pkgs/dna-seq-gatk"
export SNAKEMAKE_OUTPUT_CACHE="$ROOT/tools/snakemake-cache"
export CONDA_CHANNEL_PRIORITY=flexible

conda config --set channel_priority flexible >/dev/null

find "$CONDA_PREFIX_DIR" -mindepth 1 -maxdepth 1 -type d \
  ! -exec test -d "{}/conda-meta" \; -print -exec rm -rf {} +

prepare_replica() {
  local mode="$1"
  local replica="$2"
  local rep_dir="$RUN_DIR/$mode/replica-${replica}"
  local repo="$rep_dir/repo"

  rm -rf "$repo"
  mkdir -p "$rep_dir"
  if ! cp -a --reflink=auto "$ROOT/repos/dna-seq-gatk-variant-calling" "$repo" 2>/dev/null; then
    cp -a "$ROOT/repos/dna-seq-gatk-variant-calling" "$repo"
  fi
  rm -rf "$repo/.snakemake" "$repo/results" "$repo/logs"
  awk -v root="$ROOT" 'BEGIN{FS=OFS="\t"} NR==1{print; next} {n=split($4, p4, "/"); $4=root "/data/dna-seq-gatk-variant-calling/full/fastq/" p4[n]; n=split($5, p5, "/"); $5=root "/data/dna-seq-gatk-variant-calling/full/fastq/" p5[n]; print}' \
    "$repo/config_codex_full/units.tsv" > "$repo/config_codex_full/units.tsv.tmp"
  mv "$repo/config_codex_full/units.tsv.tmp" "$repo/config_codex_full/units.tsv"
}

repair_multiqc_envs() {
  while IFS= read -r multiqc_bin; do
    env_dir="$(cd "$(dirname "$multiqc_bin")/.." && pwd)"
    if ! "$env_dir/bin/python" -c 'import pkg_resources' >/dev/null 2>&1; then
      conda install -y -p "$env_dir" -c conda-forge 'setuptools<81'
      "$env_dir/bin/python" -c 'import pkg_resources'
    fi
    site_packages="$("$env_dir/bin/python" - <<'PY'
import site
print(site.getsitepackages()[0])
PY
)"
    cat > "$site_packages/sitecustomize.py" <<'PY'
import collections
import collections.abc

for _name in (
    "Callable",
    "Iterable",
    "Mapping",
    "MutableMapping",
    "MutableSequence",
    "MutableSet",
    "Sequence",
    "Set",
):
    if not hasattr(collections, _name):
        setattr(collections, _name, getattr(collections.abc, _name))
PY
    "$env_dir/bin/python" -c 'import collections; assert collections.Mapping'
  done < <(find "$CONDA_PREFIX_DIR" -type f -path '*/bin/multiqc' | sort)
}

run_replica() {
  local mode="$1"
  local replica="$2"
  local rep_dir="$RUN_DIR/$mode/replica-${replica}"
  local repo="$rep_dir/repo"
  local trace_dir="$RUN_DIR/traces/$mode/replica-${replica}"

  mkdir -p "$trace_dir"
  cd "$repo"
  snakemake \
    --snakefile workflow/Snakefile \
    --configfile config_codex_full/config.yaml \
    --use-conda \
    --conda-frontend conda \
    --conda-prefix "$CONDA_PREFIX_DIR" \
    --cores "${SLURM_CPUS_PER_TASK:-40}" \
    --printshellcmds \
    --rerun-incomplete \
    --latency-wait 120

  find results -type f -size +0c | sort > "$rep_dir/nonempty-results.txt"
  test -s "$rep_dir/nonempty-results.txt"
  test -s results/annotated/all.vcf.gz
  test -s results/qc/multiqc.html
  test -s results/plots/depths.svg
  test -s results/plots/allele-freqs.svg

  if [ "$mode" = "datalife" ]; then
    env DATALIFE_OUTPUT_PATH="$trace_dir" \
      DATALIFE_FILE_PATTERNS="*.bam,*.bai,*.sam,*.vcf,*.vcf.gz,*.tbi,*.html,*.svg,*.txt,*.log,*.tsv" \
      LD_PRELOAD="$DATALIFE_LIB" \
      python3 "$ROOT/scripts/profile_tree_io.py" \
        --root "$repo/results" \
        --manifest "$rep_dir/profiled-output-digests.json" \
        --patterns '*.bam' '*.bai' '*.sam' '*.vcf' '*.vcf.gz' '*.tbi' '*.html' '*.svg' '*.txt' '*.log' '*.tsv'
  elif [ "$mode" = "darshan" ]; then
    env DARSHAN_ENABLE_NONMPI=1 \
      DARSHAN_LOG_DIR_PATH="$trace_dir" \
      LD_PRELOAD="$DARSHAN_LIB" \
      python3 "$ROOT/scripts/profile_tree_io.py" \
        --root "$repo/results" \
        --manifest "$rep_dir/profiled-output-digests.json" \
        --patterns '*.bam' '*.bai' '*.sam' '*.vcf' '*.vcf.gz' '*.tbi' '*.html' '*.svg' '*.txt' '*.log' '*.tsv'
  else
    echo "Unknown profile mode: $mode" >&2
    exit 2
  fi

  echo "dna-seq-gatk ${mode} replica $replica native Snakemake workflow completed"
}

if [ "${1:-}" = "worker" ]; then
  run_replica "$2" "$3"
  exit 0
fi

for mode in datalife darshan; do
  for replica in 0 1 2 3; do
    prepare_replica "$mode" "$replica"
  done
done

cd "$RUN_DIR/datalife/replica-0/repo"
snakemake \
  --snakefile workflow/Snakefile \
  --configfile config_codex_full/config.yaml \
  --use-conda \
  --conda-frontend conda \
  --conda-prefix "$CONDA_PREFIX_DIR" \
  --cores 1 \
  --conda-create-envs-only \
  --rerun-incomplete \
  --latency-wait 120
repair_multiqc_envs

cd "$ROOT"
for mode in datalife darshan; do
  for replica in 0 1 2 3; do
    srun --exclusive --nodes=1 --ntasks=1 --cpus-per-task="${SLURM_CPUS_PER_TASK:-40}" \
      "$0" worker "$mode" "$replica" > "$RUN_DIR/${mode}-replica-${replica}.out" 2> "$RUN_DIR/${mode}-replica-${replica}.err" &
  done
  wait

  find "$RUN_DIR/$mode" -path '*/nonempty-results.txt' -type f -size +0c | sort > "$RUN_DIR/${mode}-result-manifests.txt"
  manifest_count="$(wc -l < "$RUN_DIR/${mode}-result-manifests.txt")"
  if [ "$manifest_count" -ne 4 ]; then
    echo "ERROR: expected 4 ${mode} result manifests, found $manifest_count" >&2
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
echo "dna-seq-gatk-variant-calling native 4-node profiled Snakemake workflow completed across ${node_count} nodes"
