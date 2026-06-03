#!/usr/bin/env bash
#SBATCH --job-name=detaxizer-prof
#SBATCH --exclusive
#SBATCH --partition=compute
#SBATCH --nodes=4
#SBATCH --ntasks=4
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/nf-core_detaxizer/slurm-%j-4node-profiled.out
#SBATCH --error=runs/nf-core_detaxizer/slurm-%j-4node-profiled.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

REPO="$ROOT/repos/nf-core_detaxizer"
DATA_DIR="$ROOT/data/nf-core_detaxizer/full"
REMOTE_INPUT="$DATA_DIR/zenodo_10472796_samplesheet.csv"
FASTQ_DIR="$DATA_DIR/fastq"
REF_DIR="$DATA_DIR/reference"
INPUT="$DATA_DIR/samplesheet.full.local.csv"
FASTA_BBDUK="$REF_DIR/genome.fa"
KRAKEN2DB="$REF_DIR/k2_standard_08gb_20240904.tar.gz"
RUN_ROOT="$ROOT/runs/nf-core_detaxizer"
RUN_DIR="$RUN_ROOT/4node-profiled-${SLURM_JOB_ID:-manual}"
NF_ENV="$ROOT/tools/conda-envs/nextflow"
MINIFORGE="$ROOT/tools/miniforge"
DATALIFE_LIB="$ROOT/tools/widget-v1/profiler/datalife/build/flow-monitor/src/libmonitor.so"
DARSHAN_RUNTIME="${DARSHAN_RUNTIME:-$(spack location -i darshan-runtime@3.4.6)}"
DARSHAN_UTIL="${DARSHAN_UTIL:-$(spack location -i darshan-util@3.4.6)}"
DARSHAN_LIB="$DARSHAN_RUNTIME/lib/libdarshan.so.0.0.0"
DARSHAN_PARSER="$DARSHAN_UTIL/bin/darshan-parser"

mkdir -p "$RUN_ROOT" "$RUN_DIR" "$ROOT/tools/nextflow-home" "$FASTQ_DIR" "$REF_DIR"
mkdir -p "$RUN_DIR"/{datalife,darshan,traces/datalife,traces/darshan,parsed}
scontrol show hostnames "$SLURM_JOB_NODELIST" > "$RUN_DIR/hosts.txt"
cd "$ROOT"

download_file() {
  local url="$1"
  local dest="$2"
  local tmp="${dest}.part"
  local attempt
  if [ -s "$dest" ] && [ "$(stat -c%s "$dest")" -gt 100000000 ]; then
    return 0
  fi
  local staged
  staged="$(find "$ROOT/runs/nf-core_detaxizer" -type f -name "$(basename "$dest")" -size +100000000c -printf '%s %p\n' 2>/dev/null | sort -nr | head -n 1 | cut -d' ' -f2- || true)"
  if [ -n "$staged" ]; then
    rm -f "$dest"
    ln "$staged" "$dest" 2>/dev/null || cp -a --reflink=auto "$staged" "$dest"
    return 0
  fi
  if [ -s "$dest" ] && [ ! -s "$tmp" ]; then
    mv "$dest" "$tmp"
  fi
  for attempt in $(seq 1 20); do
    if curl -L --fail --retry 8 --retry-delay 15 --retry-all-errors --continue-at - "$url" -o "$tmp"; then
      if [[ "$dest" != *.gz ]] || gzip -t "$tmp" >/dev/null 2>&1; then
        mv "$tmp" "$dest"
        return 0
      fi
    fi
    sleep 30
  done
  echo "ERROR: failed to download $url -> $dest" >&2
  return 1
}

stage_inputs() {
  if [ ! -s "$REMOTE_INPUT" ]; then
    echo "ERROR: missing detaxizer remote samplesheet: $REMOTE_INPUT" >&2
    exit 1
  fi
  download_file "https://ngi-igenomes.s3.amazonaws.com/igenomes/Homo_sapiens/NCBI/GRCh38/Sequence/WholeGenomeFasta/genome.fa" "$FASTA_BBDUK"
  download_file "https://genome-idx.s3.amazonaws.com/kraken/k2_standard_08gb_20240904.tar.gz" "$KRAKEN2DB"
  {
    IFS=, read -r sample_col r1_col r2_col long_col
    printf '%s,%s,%s,%s\n' "$sample_col" "$r1_col" "$r2_col" "$long_col"
    while IFS=, read -r sample r1 r2 long || [ -n "${sample:-}" ]; do
      [ -n "$sample" ] || continue
      r1_dest="$FASTQ_DIR/$(basename "$r1")"
      r2_dest="$FASTQ_DIR/$(basename "$r2")"
      long_dest="$FASTQ_DIR/$(basename "$long")"
      download_file "$r1" "$r1_dest"
      download_file "$r2" "$r2_dest"
      download_file "$long" "$long_dest"
      printf '%s,%s,%s,%s\n' "$sample" "$r1_dest" "$r2_dest" "$long_dest"
    done
  } < "$REMOTE_INPUT" > "$INPUT.tmp"
  mv "$INPUT.tmp" "$INPUT"
}

for required in "$NF_ENV/bin/nextflow" "$REMOTE_INPUT" "$DATALIFE_LIB" "$DARSHAN_LIB" "$DARSHAN_PARSER" "$ROOT/scripts/profile_tree_io.py"; do
  if [ ! -s "$required" ] && [ ! -x "$required" ]; then
    echo "ERROR: missing required nf-core/detaxizer profiling artifact: $required" >&2
    exit 1
  fi
done

stage_inputs

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
  local override="$rep_dir/detaxizer_ares_override.config"

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
process {
  maxForks = 4
  resourceLimits = [
    cpus: 40,
    memory: '45.GB',
    time: '48.h'
  ]
  withName: /.*KRAKEN2PREPARATION.*/ {
    cpus = 12
    memory = '45.GB'
    time = '12.h'
  }
}
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
    --fasta_bbduk "$FASTA_BBDUK" \
    --kraken2db "$KRAKEN2DB" \
    --classification_bbduk \
    --classification_kraken2 \
    --classification_kraken2_post_filtering \
    --output_removed_reads \
    --generate_downstream_samplesheets \
    --generate_pipeline_samplesheets "taxprofiler,mag" \
    --outdir "$outdir"

  if ! find "$outdir/pipeline_info" -maxdepth 1 -type f -name 'execution_trace*' -size +0 | grep -q .; then
    echo "ERROR: ${mode} replica $replica missing Nextflow execution trace" >&2
    exit 1
  fi
  if ! find "$outdir" -type f -name '*multiqc*html' -size +100000 | grep -q .; then
    echo "ERROR: ${mode} replica $replica missing non-trivial MultiQC HTML output" >&2
    exit 1
  fi
  if ! find "$outdir/filter" -type f -name '*filtered*.fastq.gz' -size +0 | grep -q .; then
    echo "ERROR: ${mode} replica $replica missing filtered FASTQ outputs" >&2
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
      DATALIFE_FILE_PATTERNS="*.fastq.gz,*.fq.gz,*.fa,*.fasta,*.bam,*.bai,*.txt,*.tsv,*.csv,*.html,*.log,*.yaml,*.yml" \
      LD_PRELOAD="$DATALIFE_LIB" \
      "$NF_ENV/bin/python" "$ROOT/scripts/profile_tree_io.py" \
        --root "$outdir" \
        --manifest "$rep_dir/profiled-output-digests.json" \
        --patterns '*.fastq.gz' '*.fq.gz' '*.fa' '*.fasta' '*.bam' '*.bai' '*.txt' '*.tsv' '*.csv' '*.html' '*.log' '*.yaml' '*.yml'
  elif [ "$mode" = "darshan" ]; then
    env DARSHAN_ENABLE_NONMPI=1 \
      DARSHAN_LOG_DIR_PATH="$trace_dir" \
      LD_PRELOAD="$DARSHAN_LIB" \
      "$NF_ENV/bin/python" "$ROOT/scripts/profile_tree_io.py" \
        --root "$outdir" \
        --manifest "$rep_dir/profiled-output-digests.json" \
        --patterns '*.fastq.gz' '*.fq.gz' '*.fa' '*.fasta' '*.bam' '*.bai' '*.txt' '*.tsv' '*.csv' '*.html' '*.log' '*.yaml' '*.yml'
  else
    echo "Unknown profile mode: $mode" >&2
    exit 2
  fi

  echo "nf-core/detaxizer ${mode} replica $replica native Nextflow workflow completed with $output_count non-empty output files"
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
echo "nf-core/detaxizer native 4-node profiled Nextflow workflow completed across ${node_count} nodes"
