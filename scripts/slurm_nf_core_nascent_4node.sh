#!/usr/bin/env bash
#SBATCH --job-name=nascent-4node
#SBATCH --exclusive
#SBATCH --partition=compute
#SBATCH --nodes=4
#SBATCH --ntasks=4
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/nf-core_nascent/slurm-%j-4node.out
#SBATCH --error=runs/nf-core_nascent/slurm-%j-4node.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

REPO="$ROOT/repos/nf-core_nascent"
DATA_DIR="$ROOT/data/nf-core_nascent/full"
SOURCE_INPUT="$DATA_DIR/samplesheet_full_https.csv"
FASTQ_DIR="$DATA_DIR/fastq"
INPUT="$DATA_DIR/samplesheet_full_local.csv"
RUN_ROOT="$ROOT/runs/nf-core_nascent"
RUN_DIR="$RUN_ROOT/4node-${SLURM_JOB_ID:-manual}"
NF_ENV="$ROOT/tools/conda-envs/nextflow"
MINIFORGE="$ROOT/tools/miniforge"

mkdir -p "$RUN_ROOT" "$RUN_DIR" "$ROOT/tools/nextflow-home" "$FASTQ_DIR"
cd "$ROOT"

if [ ! -x "$NF_ENV/bin/nextflow" ]; then
  echo "ERROR: missing Nextflow environment: $NF_ENV" >&2
  exit 1
fi
if [ ! -s "$SOURCE_INPUT" ]; then
  echo "ERROR: missing source nascent samplesheet: $SOURCE_INPUT" >&2
  exit 1
fi

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
    if curl -L --fail --retry 8 --retry-delay 15 --retry-all-errors --continue-at - "$url" -o "$tmp"; then
      if gzip -t "$tmp" >/dev/null 2>&1; then
        mv "$tmp" "$dest"
        return 0
      fi
      echo "WARN: downloaded FASTQ failed gzip validation; retrying from scratch: $tmp" >&2
      rm -f "$tmp"
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
    while IFS=, read -r sample fastq_1 fastq_2; do
      [ -n "$sample" ] || continue
      dest="$FASTQ_DIR/${sample}.fastq.gz"
      download_fastq "$fastq_1" "$dest"
      printf '%s,%s,%s\n' "$sample" "$dest" "${fastq_2:-}"
    done
  } < "$SOURCE_INPUT" > "$INPUT.tmp"
  mv "$INPUT.tmp" "$INPUT"
  for fastq in "$FASTQ_DIR"/*.fastq.gz; do
    gzip -t "$fastq"
  done
}

prepare_input

run_replica() {
  local replica="$1"
  local rep_dir="$RUN_DIR/replica-${replica}"
  local outdir="$rep_dir/results"
  local workdir="$rep_dir/work"
  local tmp_root="$workdir/tmp"
  local pkgs_root="$rep_dir/conda-pkgs"
  local cache_root="$rep_dir/nextflow-conda-cache"
  local condarc="$rep_dir/condarc"
  local override="$rep_dir/nascent_ares_override.config"

  mkdir -p "$outdir" "$workdir" "$tmp_root" "$pkgs_root" "$cache_root"
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
    --genome hg38 \
    --assay_type GROseq \
    --outdir "$outdir"

  if ! find "$outdir/pipeline_info" -maxdepth 1 -type f -name 'execution_trace*' -size +0 | grep -q .; then
    echo "ERROR: replica $replica missing Nextflow execution trace" >&2
    exit 1
  fi
  if ! find "$outdir/multiqc" -type f -name 'multiqc_report.html' -size +100000 | grep -q .; then
    echo "ERROR: replica $replica missing non-trivial MultiQC report" >&2
    exit 1
  fi
  if ! find "$outdir" -type f \( -name '*.bam' -o -name '*.bai' \) -size +0 | grep -q .; then
    echo "ERROR: replica $replica missing non-empty BAM alignment outputs" >&2
    exit 1
  fi
  if ! find "$outdir" -type f \( -name '*.bedGraph' -o -name '*.bedGraph.gz' -o -name '*.bw' -o -name '*.bigWig' \) -size +0 | grep -q .; then
    echo "ERROR: replica $replica missing non-empty coverage graph outputs" >&2
    exit 1
  fi
  if ! find "$outdir" -type f \( -name '*.transcripts.txt' -o -name '*.transcripts.bed' -o -name '*.tdFinal.txt' \) -size +0 | grep -q .; then
    echo "ERROR: replica $replica missing non-empty transcript identification outputs" >&2
    exit 1
  fi
  output_count="$(find "$outdir" -type f -size +0 | wc -l)"
  if [ "$output_count" -lt 50 ]; then
    echo "ERROR: replica $replica too few non-empty nascent outputs: $output_count" >&2
    exit 1
  fi
  find "$outdir" -type f -size +0 | sort > "$rep_dir/nonempty-outputs.txt"
  echo "nf-core/nascent replica $replica native Nextflow baseline completed with $output_count non-empty output files"
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

echo "nf-core/nascent native 4-node Nextflow baseline completed across 4 nodes"
