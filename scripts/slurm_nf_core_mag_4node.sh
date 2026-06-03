#!/usr/bin/env bash
#SBATCH --job-name=mag-4node
#SBATCH --exclusive
#SBATCH --partition=compute
#SBATCH --nodes=4
#SBATCH --ntasks=4
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/nf-core_mag/slurm-%j-4node.out
#SBATCH --error=runs/nf-core_mag/slurm-%j-4node.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

REPO="$ROOT/repos/nf-core_mag"
DATA_DIR="$ROOT/data/nf-core_mag/full"
REMOTE_INPUT="$DATA_DIR/zenodo_10472796_samplesheet.csv"
FASTQ_DIR="$DATA_DIR/fastq"
REF_DIR="$DATA_DIR/reference"
HOST_FASTA="$REF_DIR/GRCh38_genome.fa.gz"
RUN_ROOT="$ROOT/runs/nf-core_mag"
RUN_DIR="$RUN_ROOT/4node-${SLURM_JOB_ID:-manual}"
NF_ENV="$ROOT/tools/conda-envs/nextflow"
MINIFORGE="$ROOT/tools/miniforge"

mkdir -p "$RUN_ROOT" "$RUN_DIR" "$ROOT/tools/nextflow-home" "$FASTQ_DIR" "$REF_DIR"
cd "$ROOT"

if [ ! -x "$NF_ENV/bin/nextflow" ]; then
  echo "ERROR: missing Nextflow environment: $NF_ENV" >&2
  exit 1
fi
if [ ! -s "$REMOTE_INPUT" ]; then
  echo "ERROR: missing MAG remote samplesheet: $REMOTE_INPUT" >&2
  exit 1
fi

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
  for attempt in $(seq 1 20); do
    if curl -L --fail --retry 8 --retry-delay 15 --retry-all-errors --continue-at - "$url" -o "$tmp" \
      && gzip -t "$tmp" >/dev/null 2>&1; then
      mv "$tmp" "$dest"
      return 0
    fi
    sleep 30
  done
  echo "ERROR: failed to download and validate $url -> $dest" >&2
  return 1
}

prepare_input() {
  local input="$DATA_DIR/samplesheet.full.v4.local.csv"
  if [ ! -s "$REF_DIR/GRCh38_genome.fa" ]; then
    curl -L --fail --retry 8 --retry-delay 15 --retry-all-errors \
      "https://ngi-igenomes.s3.amazonaws.com/igenomes/Homo_sapiens/NCBI/GRCh38/Sequence/WholeGenomeFasta/genome.fa" \
      -o "$REF_DIR/GRCh38_genome.fa"
  fi
  if [ ! -s "$HOST_FASTA" ] || ! gzip -t "$HOST_FASTA" >/dev/null 2>&1; then
    gzip -c "$REF_DIR/GRCh38_genome.fa" > "$HOST_FASTA.tmp"
    mv "$HOST_FASTA.tmp" "$HOST_FASTA"
  fi
  {
    IFS=, read -r sample_col group_col short_platform_col short1_col short2_col long_platform_col long_col
    printf '%s,%s,%s,%s,%s,%s,%s\n' "$sample_col" "$group_col" "$short_platform_col" "$short1_col" "$short2_col" "$long_platform_col" "$long_col"
    while IFS=, read -r sample group short_platform short1 short2 long_platform long; do
      [ -n "$sample" ] || continue
      short1_dest="$FASTQ_DIR/$(basename "$short1")"
      short2_dest="$FASTQ_DIR/$(basename "$short2")"
      long_dest="$FASTQ_DIR/$(basename "$long")"
      download_gzip "$short1" "$short1_dest"
      download_gzip "$short2" "$short2_dest"
      download_gzip "$long" "$long_dest"
      printf '%s,%s,%s,%s,%s,%s,%s\n' "$sample" "$group" "$short_platform" "$short1_dest" "$short2_dest" "$long_platform" "$long_dest"
    done
  } < "$REMOTE_INPUT" > "$input.tmp"
  mv "$input.tmp" "$input"
  printf '%s\n' "$input"
}

INPUT="$(prepare_input)"

run_replica() {
  local replica="$1"
  local rep_dir="$RUN_DIR/replica-${replica}"
  local outdir="$rep_dir/results"
  local workdir="$rep_dir/work"
  local tmp_root="$workdir/tmp"
  local pkgs_root="$rep_dir/conda-pkgs"
  local cache_root="$rep_dir/nextflow-conda-cache"
  local condarc="$rep_dir/condarc"
  local override="$rep_dir/mag_ares_override.config"

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
    --host_fasta "$HOST_FASTA" \
    --skip_gtdbtk true \
    --skip_spades false \
    --skip_spadeshybrid true \
    --spades_fix_cpus 10 \
    --spadeshybrid_fix_cpus 10 \
    --megahit_fix_cpu_1 true \
    --longread_percentidentity 85 \
    --skip_concoct true \
    --run_checkm2 true \
    --run_busco false \
    --prokka_with_compliance true \
    --prokka_compliance_centre nfcore \
    --outdir "$outdir"

  if ! find "$outdir/pipeline_info" -maxdepth 1 -type f -name 'execution_trace*' -size +0 | grep -q .; then
    echo "ERROR: replica $replica missing Nextflow execution trace" >&2
    exit 1
  fi
  if ! find "$outdir/multiqc" -type f -name 'multiqc_report.html' -size +100000 | grep -q .; then
    echo "ERROR: replica $replica missing non-trivial MultiQC report" >&2
    exit 1
  fi
  if ! find "$outdir/Assembly" "$outdir/assembly" -type f -size +0 2>/dev/null | grep -q .; then
    echo "ERROR: replica $replica missing non-empty assembly outputs" >&2
    exit 1
  fi
  if ! find "$outdir" -type f \( -name '*bin*.fa' -o -name '*bin*.fa.gz' -o -name '*bins*.tsv' \) -size +0 | grep -q .; then
    echo "ERROR: replica $replica missing non-empty binning outputs" >&2
    exit 1
  fi
  output_count="$(find "$outdir" -type f -size +0 | wc -l)"
  if [ "$output_count" -lt 100 ]; then
    echo "ERROR: replica $replica too few non-empty MAG outputs: $output_count" >&2
    exit 1
  fi
  find "$outdir" -type f -size +0 | sort > "$rep_dir/nonempty-outputs.txt"
  echo "nf-core/mag replica $replica native Nextflow baseline completed with $output_count non-empty output files"
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

echo "nf-core/mag native 4-node Nextflow baseline completed across 4 nodes"
