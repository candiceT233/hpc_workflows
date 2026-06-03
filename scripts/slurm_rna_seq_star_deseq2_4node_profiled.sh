#!/bin/bash
#SBATCH --job-name=star-deseq2-prof
#SBATCH --exclusive
#SBATCH --partition=compute
#SBATCH --nodes=4
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/rna-seq-star-deseq2/slurm-%j-4node-profiled.out
#SBATCH --error=runs/rna-seq-star-deseq2/slurm-%j-4node-profiled.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

REPO="$ROOT/repos/rna-seq-star-deseq2"
SNAKEMAKE_ENV="$ROOT/tools/conda-envs/snakemake9"
CONDA_PREFIX_DIR="$ROOT/tools/snakemake-conda/rna-seq-star-deseq2"
RUN_ROOT="$ROOT/runs/rna-seq-star-deseq2/4node-profiled-${SLURM_JOB_ID:-manual}"
DATALIFE_LIB="$ROOT/tools/widget-v1/profiler/datalife/build/flow-monitor/src/libmonitor.so"
DARSHAN_RUNTIME="${DARSHAN_RUNTIME:-$(spack location -i darshan-runtime@3.4.6)}"
DARSHAN_UTIL="${DARSHAN_UTIL:-$(spack location -i darshan-util@3.4.6)}"
DARSHAN_LIB="$DARSHAN_RUNTIME/lib/libdarshan.so.0.0.0"
DARSHAN_PARSER="$DARSHAN_UTIL/bin/darshan-parser"

for required in "$SNAKEMAKE_ENV/bin/snakemake" "$DATALIFE_LIB" "$DARSHAN_LIB" "$DARSHAN_PARSER"; do
  if [ ! -s "$required" ]; then
    echo "Required profiling artifact missing: $required" >&2
    exit 2
  fi
done

mkdir -p "$ROOT/runs/rna-seq-star-deseq2"
rm -rf "$RUN_ROOT"
mkdir -p "$RUN_ROOT"/{datalife,darshan,traces/datalife,traces/darshan,parsed}
scontrol show hostnames "$SLURM_JOB_NODELIST" > "$RUN_ROOT/hosts.txt"

cat > "$RUN_ROOT/run_profile_replica.sh" <<'EOS'
#!/bin/bash
set -euo pipefail

rank="${SLURM_PROCID:-0}"
replica_id=$((rank + 1))
mode="$STAR_DESEQ2_PROFILE_MODE"
replica_root="${STAR_DESEQ2_PASS_ROOT}/replica-${replica_id}"
trace_dir="${STAR_DESEQ2_TRACE_ROOT}/replica-${replica_id}"

mkdir -p "$replica_root/config" "$replica_root/tmp" "$trace_dir"
rm -rf "$replica_root/config_sra"
cp -a "$REPO/.test/config_sra" "$replica_root/config_sra"
cp "$REPO/.test/config_sra/config.yaml" "$replica_root/config/config.yaml"

export PATH="$SNAKEMAKE_ENV/bin:$ROOT/tools/miniforge/bin:$ROOT/tools/miniforge/condabin:$PATH"
export TMPDIR="$replica_root/tmp"

if [ "$mode" != "datalife" ] && [ "$mode" != "darshan" ]; then
  echo "Unknown profiling mode: $mode" >&2
  exit 2
fi

snakemake \
  --snakefile "$REPO/workflow/Snakefile" \
  --directory "$replica_root" \
  --configfile "$replica_root/config/config.yaml" \
  --cores "${SLURM_CPUS_PER_TASK:-40}" \
  --use-conda \
  --conda-prefix "$CONDA_PREFIX_DIR" \
  --rerun-incomplete \
  --restart-times 2 \
  --printshellcmds \
  --show-failed-logs

for path in \
  "$replica_root/results/deseq2/normcounts.tsv" \
  "$replica_root/results/diffexp/stb5_vs_control.diffexp.tsv" \
  "$replica_root/results/pca.genotype.svg" \
  "$replica_root/results/qc/multiqc_report.html"; do
  if [ ! -s "$path" ]; then
    echo "ERROR: replica ${replica_id} ${mode} missing expected output: $path" >&2
    exit 1
  fi
done

if ! find "$replica_root/results/star" -type f -name 'Aligned.sortedByCoord.out.bam' -size +100000000c | grep -q .; then
  echo "ERROR: replica ${replica_id} ${mode} missing non-trivial STAR BAM outputs" >&2
  exit 1
fi

output_count="$(find "$replica_root/results" -type f -size +0 | wc -l)"
if [ "$output_count" -lt 200 ]; then
  echo "ERROR: replica ${replica_id} ${mode} too few non-empty outputs: $output_count" >&2
  exit 1
fi

if [ "$mode" = "datalife" ]; then
  env DATALIFE_OUTPUT_PATH="$trace_dir" \
    DATALIFE_FILE_PATTERNS="*.bam,*.bai,*.tsv,*.html,*.svg,*.txt,*.log" \
    LD_PRELOAD="$DATALIFE_LIB" \
    "$SNAKEMAKE_ENV/bin/python" "$ROOT/scripts/profile_tree_io.py" \
      --root "$replica_root/results" \
      --manifest "$replica_root/profiled-output-digests.json" \
      --patterns '*.bam' '*.bai' '*.tsv' '*.html' '*.svg' '*.txt' '*.log'
else
  env DARSHAN_ENABLE_NONMPI=1 \
    DARSHAN_LOG_DIR_PATH="$trace_dir" \
    LD_PRELOAD="$DARSHAN_LIB" \
    "$SNAKEMAKE_ENV/bin/python" "$ROOT/scripts/profile_tree_io.py" \
      --root "$replica_root/results" \
      --manifest "$replica_root/profiled-output-digests.json" \
      --patterns '*.bam' '*.bai' '*.tsv' '*.html' '*.svg' '*.txt' '*.log'
fi

echo "${mode} replica ${replica_id} completed with ${output_count} non-empty result files"
EOS
chmod +x "$RUN_ROOT/run_profile_replica.sh"

run_profile_pass() {
  local mode="$1"
  local pass_root="$RUN_ROOT/$mode"
  local trace_root="$RUN_ROOT/traces/$mode"
  mkdir -p "$pass_root" "$trace_root"

  srun -u -n "$SLURM_NTASKS" --ntasks-per-node=1 \
    --export=ALL,ROOT="$ROOT",REPO="$REPO",SNAKEMAKE_ENV="$SNAKEMAKE_ENV",CONDA_PREFIX_DIR="$CONDA_PREFIX_DIR",STAR_DESEQ2_PROFILE_MODE="$mode",STAR_DESEQ2_PASS_ROOT="$pass_root",STAR_DESEQ2_TRACE_ROOT="$trace_root",DATALIFE_LIB="$DATALIFE_LIB",DARSHAN_LIB="$DARSHAN_LIB" \
    "$RUN_ROOT/run_profile_replica.sh"

  local replica_count
  replica_count="$(find "$pass_root" -maxdepth 1 -type d -name 'replica-*' | wc -l)"
  if [ "$replica_count" -ne "$SLURM_NTASKS" ]; then
    echo "ERROR: expected $SLURM_NTASKS ${mode} replicas, found $replica_count" >&2
    exit 3
  fi
  find "$pass_root"/replica-*/results -type f -size +0 -printf '%h/%f\t%s\n' > "$RUN_ROOT/${mode}-outputs.tsv"
  local total_outputs
  total_outputs="$(wc -l < "$RUN_ROOT/${mode}-outputs.tsv")"
  if [ "$total_outputs" -lt 800 ]; then
    echo "ERROR: too few ${mode} outputs across replicas: $total_outputs" >&2
    exit 4
  fi
  echo "${mode} pass completed with ${replica_count} replicas and ${total_outputs} non-empty result files"
}

run_profile_pass datalife
run_profile_pass darshan

python3 - "$RUN_ROOT/traces/datalife" <<'PY'
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
  rel="${log_path#$RUN_ROOT/traces/darshan/}"
  parsed="$RUN_ROOT/parsed/${rel}.txt"
  mkdir -p "$(dirname "$parsed")"
  "$DARSHAN_PARSER" "$log_path" > "$parsed"
  if [ ! -s "$parsed" ]; then
    echo "Parsed Darshan output is empty: $parsed" >&2
    exit 5
  fi
  darshan_count=$((darshan_count + 1))
done < <(find "$RUN_ROOT/traces/darshan" -name '*.darshan' -type f -size +0c -print0)

if [ "$darshan_count" -eq 0 ]; then
  echo "No non-empty Darshan logs found" >&2
  exit 6
fi

printf 'Darshan logs parsed: %s\n' "$darshan_count"
find "$RUN_ROOT/traces" -type f -printf '%P\t%s\n' | sort > "$RUN_ROOT/trace-summary.tsv"
cat "$RUN_ROOT/datalife-outputs.tsv"
cat "$RUN_ROOT/darshan-outputs.tsv"
cat "$RUN_ROOT/trace-summary.tsv"

node_count="$(wc -l < "$RUN_ROOT/hosts.txt")"
echo "rna-seq-star-deseq2 native Snakemake 4-node profiled workflow completed across ${node_count} nodes."
