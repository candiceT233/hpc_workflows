#!/usr/bin/env bash
#SBATCH --job-name=detaxizer-4node
#SBATCH --exclusive
#SBATCH --partition=compute
#SBATCH --nodes=4
#SBATCH --ntasks=4
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/nf-core_detaxizer/slurm-%j-4node.out
#SBATCH --error=runs/nf-core_detaxizer/slurm-%j-4node.err

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
RUN_DIR="$RUN_ROOT/4node-${SLURM_JOB_ID:-manual}"
NF_ENV="$ROOT/tools/conda-envs/nextflow"
MINIFORGE="$ROOT/tools/miniforge"

mkdir -p "$RUN_ROOT" "$RUN_DIR" "$ROOT/tools/nextflow-home" "$FASTQ_DIR" "$REF_DIR"
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

for required in "$NF_ENV/bin/nextflow" "$REMOTE_INPUT"; do
  if [ ! -s "$required" ] && [ ! -x "$required" ]; then
    echo "ERROR: missing required nf-core/detaxizer input or executable: $required" >&2
    exit 1
  fi
done

stage_inputs

run_replica() {
  local replica="$1"
  local rep_dir="$RUN_DIR/replica-${replica}"
  local outdir="$rep_dir/results"
  local workdir="$rep_dir/work"
  local tmp_root="$workdir/tmp"
  local pkgs_root="$rep_dir/conda-pkgs"
  local cache_root="$rep_dir/nextflow-conda-cache"
  local condarc="$rep_dir/condarc"
  local override="$rep_dir/detaxizer_ares_override.config"

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
    echo "ERROR: replica $replica missing Nextflow execution trace" >&2
    exit 1
  fi
  if ! find "$outdir" -type f -name '*multiqc*html' -size +100000 | grep -q .; then
    echo "ERROR: replica $replica missing non-trivial MultiQC HTML output" >&2
    exit 1
  fi
  if ! find "$outdir/filter" -type f -name '*filtered*.fastq.gz' -size +0 | grep -q .; then
    echo "ERROR: replica $replica missing filtered FASTQ outputs" >&2
    exit 1
  fi
  output_count="$(find "$outdir" -type f -size +0 | wc -l)"
  if [ "$output_count" -lt 20 ]; then
    echo "ERROR: replica $replica too few non-empty outputs: $output_count" >&2
    exit 1
  fi
  find "$outdir" -type f -size +0 | sort > "$rep_dir/nonempty-outputs.txt"
  echo "nf-core/detaxizer replica $replica native Nextflow baseline completed with $output_count non-empty output files"
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

echo "nf-core/detaxizer native 4-node Nextflow baseline completed across 4 nodes"
