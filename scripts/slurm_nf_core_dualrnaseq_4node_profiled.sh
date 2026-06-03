#!/usr/bin/env bash
#SBATCH --job-name=dualrnaseq-prof
#SBATCH --exclusive
#SBATCH --partition=compute
#SBATCH --nodes=4
#SBATCH --ntasks=4
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/nf-core_dualrnaseq/slurm-%j-4node-profiled.out
#SBATCH --error=runs/nf-core_dualrnaseq/slurm-%j-4node-profiled.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

REPO="$ROOT/repos/nf-core_dualrnaseq"
DATA="$ROOT/data/nf-core_dualrnaseq/full"
RUN_ROOT="$ROOT/runs/nf-core_dualrnaseq"
RUN_DIR="$RUN_ROOT/4node-profiled-${SLURM_JOB_ID:-manual}"
NF_ENV="$ROOT/tools/conda-envs/nextflow"
MINIFORGE="$ROOT/tools/miniforge"
HOST_FASTA="$DATA/reference/GRCh38.primary_assembly.genome.fa.gz"
HOST_GFF="$DATA/reference/gencode.v35.annotation.gff3.gz"
HOST_FASTA_URL="https://ftp.ebi.ac.uk/pub/databases/gencode/Gencode_human/release_35/GRCh38.primary_assembly.genome.fa.gz"
HOST_GFF_URL="https://ftp.ebi.ac.uk/pub/databases/gencode/Gencode_human/release_35/gencode.v35.annotation.gff3.gz"
FASTQ_DIR="$DATA/fastq"
FASTQ_R1="$FASTQ_DIR/SRR10355817.fastq.gz"
FASTQ_R2="$FASTQ_DIR/SRR10355818.fastq.gz"
FASTQ_R3="$FASTQ_DIR/SRR10355819.fastq.gz"
FASTQ_R1_URL="https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR103/017/SRR10355817/SRR10355817.fastq.gz"
FASTQ_R2_URL="https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR103/018/SRR10355818/SRR10355818.fastq.gz"
FASTQ_R3_URL="https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR103/019/SRR10355819/SRR10355819.fastq.gz"
DATALIFE_LIB="$ROOT/tools/widget-v1/profiler/datalife/build/flow-monitor/src/libmonitor.so"
DARSHAN_RUNTIME="${DARSHAN_RUNTIME:-$(spack location -i darshan-runtime@3.4.6)}"
DARSHAN_UTIL="${DARSHAN_UTIL:-$(spack location -i darshan-util@3.4.6)}"
DARSHAN_LIB="$DARSHAN_RUNTIME/lib/libdarshan.so.0.0.0"
DARSHAN_PARSER="$DARSHAN_UTIL/bin/darshan-parser"

for required in "$NF_ENV/bin/nextflow" "$DATA/reference/Karp_LS398548.1.fasta" "$DATA/reference/Karp_LS398548.1.gff3" "$DATA/SRP227242_runinfo.csv" "$DATALIFE_LIB" "$DARSHAN_LIB" "$DARSHAN_PARSER" "$ROOT/scripts/profile_tree_io.py"; do
  if [ ! -s "$required" ] && [ ! -x "$required" ]; then
    echo "ERROR: missing dualrnaseq profiling input or artifact: $required" >&2
    exit 1
  fi
done

mkdir -p "$RUN_ROOT" "$RUN_DIR" "$ROOT/tools/nextflow-home" "$DATA/reference" "$FASTQ_DIR"
mkdir -p "$RUN_DIR"/{datalife,darshan,traces/datalife,traces/darshan,parsed}
scontrol show hostnames "$SLURM_JOB_NODELIST" > "$RUN_DIR/hosts.txt"
cd "$ROOT"

download_gzip() {
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
  if [ -s "$tmp" ] && gzip -t "$tmp" >/dev/null 2>&1; then
    mv "$tmp" "$dest"
    return 0
  fi
  for attempt in $(seq 1 20); do
    if [ -s "$tmp" ]; then
      curl -L --fail --retry 8 --retry-delay 20 --retry-all-errors --continue-at - -o "$tmp" "$url" || rm -f "$tmp"
    fi
    if [ ! -s "$tmp" ]; then
      curl -L --fail --retry 8 --retry-delay 20 --retry-all-errors -o "$tmp" "$url" || true
    fi
    if [ -s "$tmp" ] && gzip -t "$tmp" >/dev/null 2>&1; then
      mv "$tmp" "$dest"
      return 0
    fi
    rm -f "$tmp"
    sleep 30
  done
  echo "ERROR: failed to download and validate $url -> $dest" >&2
  return 1
}

download_gzip "$HOST_FASTA_URL" "$HOST_FASTA"
download_gzip "$HOST_GFF_URL" "$HOST_GFF"
download_gzip "$FASTQ_R1_URL" "$FASTQ_R1"
download_gzip "$FASTQ_R2_URL" "$FASTQ_R2"
download_gzip "$FASTQ_R3_URL" "$FASTQ_R3"

write_config() {
  local config_path="$1"
  local cache_root="$2"
  cat > "$config_path" <<CONFIG
params {
  config_profile_name = 'Full Karp HUVEC replacement profile'
  config_profile_description = 'Full dual RNA-seq Karp-infected HUVEC runs from GSE139498/SRP227242'
  max_cpus = 40
  max_memory = '40.GB'
  max_time = '48.h'
  single_end = true
  genomes_ignore = true
  run_bbduk = true
  qtrim = 'rl'
  run_salmon_selective_alignment = true
  libtype = 'A'
  gene_feature_gff_to_create_transcriptome_pathogen = ['CDS','tRNA','rRNA','ncRNA']
  mapping_statistics = true
  input_paths = [
    ['Human_Karp_R1', ['$FASTQ_R1']],
    ['Human_Karp_R2', ['$FASTQ_R2']],
    ['Human_Karp_R3', ['$FASTQ_R3']]
  ]
  genomes {
    'full_karp_host' {
      fasta_host = '$HOST_FASTA'
      gff_host = '$HOST_GFF'
      gff_host_tRNA = ''
    }
    'full_karp_pathogen' {
      fasta_pathogen = '$DATA/reference/Karp_LS398548.1.fasta'
      gff_pathogen = '$DATA/reference/Karp_LS398548.1.gff3'
    }
  }
  genome_host = 'full_karp_host'
  genome_pathogen = 'full_karp_pathogen'
}
conda {
  enabled = true
  useMamba = true
  cacheDir = "$cache_root"
  createTimeout = '90 min'
}
process.maxForks = 4
CONFIG
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
  local custom_config="$rep_dir/dualrnaseq_karp_full.config"

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
  write_config "$custom_config" "$cache_root"

  export JAVA_HOME="$NF_ENV"
  export JAVA_CMD="$NF_ENV/bin/java"
  export NXF_HOME="$ROOT/tools/nextflow-home"
export NXF_OFFLINE=true
  export NXF_VER=21.10.6
  export NXF_OPTS="-Xms1g -Xmx8g"
  export PATH="$NF_ENV/bin:$MINIFORGE/bin:$MINIFORGE/condabin:$PATH"

  cd "$rep_dir"
  nextflow run "$REPO" \
    -profile conda \
    -c "$ROOT/config/nextflow_ares_local_conda.config" \
    -c "$custom_config" \
    -work-dir "$workdir" \
    --outdir "$outdir"

  if ! find "$outdir/pipeline_info" -maxdepth 1 -type f -name 'execution_trace*' -size +0 | grep -q .; then
    echo "ERROR: ${mode} replica $replica missing Nextflow execution trace" >&2
    exit 1
  fi
  if ! find "$outdir" -type f \( -name '*.bam' -o -name '*.sam' -o -name '*.quant.sf' -o -name '*.tsv' -o -name '*.csv' \) -size +0 | grep -q .; then
    echo "ERROR: ${mode} replica $replica missing non-empty dual RNA-seq analysis outputs" >&2
    exit 1
  fi
  output_count="$(find "$outdir" -type f -size +0 | wc -l)"
  if [ "$output_count" -lt 30 ]; then
    echo "ERROR: ${mode} replica $replica too few non-empty outputs: $output_count" >&2
    exit 1
  fi
  find "$outdir" -type f -size +0 | sort > "$rep_dir/nonempty-outputs.txt"

  if [ "$mode" = "datalife" ]; then
    env DATALIFE_OUTPUT_PATH="$trace_dir" \
      DATALIFE_FILE_PATTERNS="*.fastq.gz,*.fq.gz,*.fa,*.fasta,*.gff3,*.gtf,*.bam,*.bai,*.sam,*.sf,*.tsv,*.csv,*.txt,*.html,*.log,*.yaml,*.yml" \
      LD_PRELOAD="$DATALIFE_LIB" \
      "$NF_ENV/bin/python" "$ROOT/scripts/profile_tree_io.py" \
        --root "$outdir" \
        --manifest "$rep_dir/profiled-output-digests.json" \
        --patterns '*.fastq.gz' '*.fq.gz' '*.fa' '*.fasta' '*.gff3' '*.gtf' '*.bam' '*.bai' '*.sam' '*.sf' '*.tsv' '*.csv' '*.txt' '*.html' '*.log' '*.yaml' '*.yml'
  elif [ "$mode" = "darshan" ]; then
    env DARSHAN_ENABLE_NONMPI=1 \
      DARSHAN_LOG_DIR_PATH="$trace_dir" \
      LD_PRELOAD="$DARSHAN_LIB" \
      "$NF_ENV/bin/python" "$ROOT/scripts/profile_tree_io.py" \
        --root "$outdir" \
        --manifest "$rep_dir/profiled-output-digests.json" \
        --patterns '*.fastq.gz' '*.fq.gz' '*.fa' '*.fasta' '*.gff3' '*.gtf' '*.bam' '*.bai' '*.sam' '*.sf' '*.tsv' '*.csv' '*.txt' '*.html' '*.log' '*.yaml' '*.yml'
  else
    echo "Unknown profile mode: $mode" >&2
    exit 2
  fi

  echo "nf-core/dualrnaseq ${mode} replica $replica native Nextflow workflow completed with $output_count non-empty output files"
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
echo "nf-core/dualrnaseq native 4-node profiled Nextflow workflow completed across ${node_count} nodes"
