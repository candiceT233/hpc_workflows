#!/usr/bin/env bash
#SBATCH --job-name=tumourevo-prof
#SBATCH --exclusive
#SBATCH --partition=compute
#SBATCH --nodes=4
#SBATCH --ntasks=4
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/nf-core_tumourevo/slurm-%j-4node-profiled.out
#SBATCH --error=runs/nf-core_tumourevo/slurm-%j-4node-profiled.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

REPO="$ROOT/repos/nf-core_tumourevo"
INPUT_DIR="$ROOT/data/nf-core_tumourevo/full_real"
INPUT="$INPUT_DIR/samplesheet_cnaqc_set06.csv"
VCF="$INPUT_DIR/Set.06.WGS.merged_filtered.vcf"
TBI="$INPUT_DIR/Set.06.WGS.merged_filtered.vcf.tbi"
CNA_SEGMENTS="$INPUT_DIR/Set6_42.smoothedSegs.txt"
CNA_EXTRA="$INPUT_DIR/Set6_42_confints_CP.txt"
FASTA="$INPUT_DIR/Homo_sapiens.GRCh38.dna.primary_assembly.fa.gz"
DRIVERS_TABLE="$INPUT_DIR/IntOGen_20240920_Compendium_Cancer_Genes.tumourevo.tsv"
VEP_CACHE_URL="${TUMOUREVO_VEP_CACHE_URL:-https://ftp.ensembl.org/pub/release-110/variation/indexed_vep_cache/homo_sapiens_vep_110_GRCh38.tar.gz}"
VEP_CACHE_DIR="${TUMOUREVO_VEP_CACHE_DIR:-$ROOT/data/nf-core_tumourevo/full/vep_cache}"
VEP_CACHE_FILE="$VEP_CACHE_DIR/homo_sapiens_vep_110_GRCh38.tar.gz"
VEP_CACHE_EXTRACTED="$VEP_CACHE_DIR/homo_sapiens"
RUN_ROOT="$ROOT/runs/nf-core_tumourevo"
RUN_DIR="$RUN_ROOT/4node-profiled-${SLURM_JOB_ID:-manual}"
NF_ENV="$ROOT/tools/conda-envs/nextflow"
MINIFORGE="$ROOT/tools/miniforge"
DATALIFE_LIB="$ROOT/tools/widget-v1/profiler/datalife/build/flow-monitor/src/libmonitor.so"
DARSHAN_RUNTIME="${DARSHAN_RUNTIME:-$(spack location -i darshan-runtime@3.4.6)}"
DARSHAN_UTIL="${DARSHAN_UTIL:-$(spack location -i darshan-util@3.4.6)}"
DARSHAN_LIB="$DARSHAN_RUNTIME/lib/libdarshan.so.0.0.0"
DARSHAN_PARSER="$DARSHAN_UTIL/bin/darshan-parser"

mkdir -p "$RUN_ROOT" "$RUN_DIR" "$ROOT/tools/nextflow-home" "$VEP_CACHE_DIR" "$INPUT_DIR"
mkdir -p "$RUN_DIR"/{datalife,darshan,traces/datalife,traces/darshan,parsed}
scontrol show hostnames "$SLURM_JOB_NODELIST" > "$RUN_DIR/hosts.txt"
cd "$ROOT"

ensure_vep_cache() {
  if [ -d "$VEP_CACHE_EXTRACTED" ] && find "$VEP_CACHE_EXTRACTED" -type f -size +0 | grep -q .; then
    return 0
  fi
  if [ -s "$VEP_CACHE_FILE" ]; then
    echo "Resuming incomplete VEP cache download: $VEP_CACHE_FILE"
  fi
  curl --fail --location --retry 20 --retry-delay 30 --continue-at - \
    --output "$VEP_CACHE_FILE" "$VEP_CACHE_URL"
  gzip -t "$VEP_CACHE_FILE"
  tar -xzf "$VEP_CACHE_FILE" -C "$VEP_CACHE_DIR"
  if [ ! -d "$VEP_CACHE_EXTRACTED" ]; then
    echo "ERROR: extracted VEP cache missing $VEP_CACHE_EXTRACTED" >&2
    return 1
  fi
}

write_override() {
  local path="$1"
  local cache_root="$2"
  cat > "$path" <<EOF
process {
  maxForks = 4
}

conda {
  enabled = true
  useMamba = true
  cacheDir = "$cache_root"
  createTimeout = '90 min'
}
EOF
}

validate_outputs() {
  local outdir="$1"
  local label="$2"
  if ! find "$outdir/pipeline_info" -maxdepth 1 -type f -name 'execution_trace*' -size +0 | grep -q .; then
    echo "ERROR: $label missing Nextflow execution trace" >&2
    exit 1
  fi
  if ! find "$outdir" -type f \( -name '*.rds' -o -name '*.pdf' -o -name '*.png' -o -name '*.tsv' -o -name '*.csv' \) -size +0 | grep -q .; then
    echo "ERROR: $label missing non-empty tumour evolution analysis outputs" >&2
    exit 1
  fi
  if ! find "$outdir/subclonal_deconvolution" -type f -size +0 | grep -q .; then
    echo "ERROR: $label missing non-empty subclonal deconvolution outputs" >&2
    exit 1
  fi
  output_count="$(find "$outdir" -type f -size +0 | wc -l)"
  if [ "$output_count" -lt 30 ]; then
    echo "ERROR: $label too few non-empty tumourevo outputs: $output_count" >&2
    exit 1
  fi
  echo "$output_count"
}

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
  local override="$rep_dir/tumourevo_ares_override.config"

  mkdir -p "$outdir" "$workdir" "$tmp_root" "$pkgs_root" "$cache_root" "$trace_dir"
  export TMPDIR="$tmp_root" NXF_TEMP="$tmp_root" CONDA_PKGS_DIRS="$pkgs_root"
  export _JAVA_OPTIONS="${_JAVA_OPTIONS:-} -Djava.io.tmpdir=$tmp_root"
  export MAMBA_YES=true MAMBA_ALWAYS_YES=true CONDA_ALWAYS_YES=true
  cat > "$condarc" <<EOF
always_yes: true
auto_activate_base: false
channel_priority: flexible
pkgs_dirs:
  - $pkgs_root
channels:
  - conda-forge
  - bioconda
  - defaults
EOF
  export CONDARC="$condarc"
  write_override "$override" "$cache_root"

  export JAVA_HOME="$NF_ENV" JAVA_CMD="$NF_ENV/bin/java" NXF_HOME="$ROOT/tools/nextflow-home"
  export NXF_OFFLINE=true
  export NXF_VER=25.04.8 NXF_OPTS="-Xms1g -Xmx8g" NXF_SYNTAX_PARSER=v1
  export PATH="$NF_ENV/bin:$MINIFORGE/bin:$MINIFORGE/condabin:$PATH"

  cd "$rep_dir"
  nextflow run "$REPO" \
    -name "tumourevo_${mode}_${SLURM_JOB_ID:-manual}_${replica}" \
    -profile conda \
    -c "$ROOT/config/nextflow_ares_local_conda.config" \
	    -c "$override" \
	    -work-dir "$workdir" \
	    --input "$INPUT" \
	    --filter false \
	    --fasta "$FASTA" \
	    --drivers_table "$DRIVERS_TABLE" \
	    --download_cache_vep false \
	    --vep_cache "$VEP_CACHE_DIR" \
	    --vep_genome GRCh38 \
	    --vep_species homo_sapiens \
	    --vep_cache_version 110 \
	    --outdir "$outdir"

  output_count="$(validate_outputs "$outdir" "${mode} replica $replica")"
  find "$outdir" -type f -size +0 | sort > "$rep_dir/nonempty-outputs.txt"

  if [ "$mode" = "datalife" ]; then
    env DATALIFE_OUTPUT_PATH="$trace_dir" \
      DATALIFE_FILE_PATTERNS="*.vcf,*.vcf.gz,*.bcf,*.rds,*.pdf,*.png,*.tsv,*.csv,*.txt,*.html,*.log,*.gz" \
      LD_PRELOAD="$DATALIFE_LIB" \
      "$NF_ENV/bin/python" "$ROOT/scripts/profile_tree_io.py" \
        --root "$outdir" \
        --manifest "$rep_dir/profiled-output-digests.json" \
        --patterns '*.vcf' '*.vcf.gz' '*.bcf' '*.rds' '*.pdf' '*.png' '*.tsv' '*.csv' '*.txt' '*.html' '*.log' '*.gz'
  elif [ "$mode" = "darshan" ]; then
    env DARSHAN_ENABLE_NONMPI=1 \
      DARSHAN_LOG_DIR_PATH="$trace_dir" \
      LD_PRELOAD="$DARSHAN_LIB" \
      "$NF_ENV/bin/python" "$ROOT/scripts/profile_tree_io.py" \
        --root "$outdir" \
        --manifest "$rep_dir/profiled-output-digests.json" \
        --patterns '*.vcf' '*.vcf.gz' '*.bcf' '*.rds' '*.pdf' '*.png' '*.tsv' '*.csv' '*.txt' '*.html' '*.log' '*.gz'
  else
    echo "Unknown profile mode: $mode" >&2
    exit 2
  fi

  echo "nf-core/tumourevo ${mode} replica $replica native Nextflow workflow completed with $output_count non-empty output files"
}

if [ "${1:-}" = "worker" ]; then
  run_replica "$2" "$3"
  exit 0
fi

source "$ROOT/scripts/tumourevo_real_inputs.sh"
prepare_tumourevo_real_inputs "$ROOT" "$INPUT_DIR" "$INPUT" "$VCF" "$TBI" "$CNA_SEGMENTS" "$CNA_EXTRA" "$FASTA" "$DRIVERS_TABLE"

for required in "$INPUT" "$FASTA" "$DRIVERS_TABLE" "$NF_ENV/bin/nextflow" "$DATALIFE_LIB" "$DARSHAN_LIB" "$DARSHAN_PARSER" "$ROOT/scripts/profile_tree_io.py"; do
  if [ ! -s "$required" ] && [ ! -x "$required" ]; then
    echo "ERROR: missing required nf-core/tumourevo profiling artifact: $required" >&2
    exit 1
  fi
done

for mode in datalife darshan; do
  ensure_vep_cache
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
echo "nf-core/tumourevo native 4-node profiled Nextflow workflow completed across ${node_count} nodes"
