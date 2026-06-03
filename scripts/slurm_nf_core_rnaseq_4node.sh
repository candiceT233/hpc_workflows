#!/usr/bin/env bash
#SBATCH --job-name=rnaseq-4node
#SBATCH --exclusive
#SBATCH --partition=compute
#SBATCH --nodes=4
#SBATCH --ntasks=4
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/nf-core_rnaseq/slurm-%j-4node.out
#SBATCH --error=runs/nf-core_rnaseq/slurm-%j-4node.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

REPO="$ROOT/repos/nf-core_rnaseq"
DATA_DIR="$ROOT/data/nf-core_rnaseq/full"
REMOTE_INPUT="$DATA_DIR/encode_gm12878_polya_samplesheet.csv"
FASTQ_DIR="$DATA_DIR/fastq"
REF_DIR="$DATA_DIR/reference"
INPUT="$DATA_DIR/samplesheet_full_local.csv"
FASTA="$REF_DIR/genome.fa"
GTF="$REF_DIR/genes.gtf"
RUN_ROOT="$ROOT/runs/nf-core_rnaseq"
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
  echo "ERROR: missing rnaseq remote samplesheet: $REMOTE_INPUT" >&2
  exit 1
fi

download_file() {
  local url="$1"
  local dest="$2"
  local tmp="${dest}.part"
  local attempt
  if [ -s "$dest" ]; then
    if [[ "$dest" == *.gz ]]; then
      gzip -t "$dest" >/dev/null 2>&1 && return 0
    else
      return 0
    fi
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

prepare_inputs() {
  download_file "https://ngi-igenomes.s3.amazonaws.com/igenomes/Homo_sapiens/Ensembl/GRCh37/Sequence/WholeGenomeFasta/genome.fa" "$FASTA"
  download_file "https://ngi-igenomes.s3.amazonaws.com/igenomes/Homo_sapiens/Ensembl/GRCh37/Annotation/Genes/genes.gtf" "$GTF"

  {
    IFS=, read -r sample_col r1_col r2_col stranded_col
    printf '%s,%s,%s,%s\n' "$sample_col" "$r1_col" "$r2_col" "$stranded_col"
    while IFS=, read -r sample r1 r2 strandedness; do
      [ -n "$sample" ] || continue
      r1_dest="$FASTQ_DIR/$(basename "$r1")"
      r2_dest="$FASTQ_DIR/$(basename "$r2")"
      download_file "$r1" "$r1_dest"
      download_file "$r2" "$r2_dest"
      printf '%s,%s,%s,%s\n' "$sample" "$r1_dest" "$r2_dest" "$strandedness"
    done
  } < "$REMOTE_INPUT" > "$INPUT.tmp"
  mv "$INPUT.tmp" "$INPUT"
}

validate_outputs() {
  local outdir="$1"
  local replica="$2"
  if ! find "$outdir/pipeline_info" -maxdepth 1 -type f -name 'execution_trace*' -size +0 | grep -q .; then
    echo "ERROR: replica $replica missing Nextflow execution trace" >&2
    exit 1
  fi
  if ! find "$outdir/multiqc" -type f -name '*multiqc_report.html' -size +100000 | grep -q .; then
    echo "ERROR: replica $replica missing non-trivial MultiQC report" >&2
    exit 1
  fi
  if ! find "$outdir/star_salmon" -type f \( -name '*.bam' -o -name '*.bai' \) -size +0 | grep -q .; then
    echo "ERROR: replica $replica missing non-empty STAR/BAM outputs" >&2
    exit 1
  fi
  if ! find "$outdir/star_salmon" -type f \( -name 'quant.sf' -o -name '*.counts.tsv' -o -name '*.featureCounts.txt' \) -size +0 | grep -q .; then
    echo "ERROR: replica $replica missing non-empty quantification/count outputs" >&2
    exit 1
  fi
  output_count="$(find "$outdir" -type f -size +0 | wc -l)"
  if [ "$output_count" -lt 100 ]; then
    echo "ERROR: replica $replica too few non-empty rnaseq outputs: $output_count" >&2
    exit 1
  fi
  echo "$output_count"
}

run_replica() {
  local replica="$1"
  local rep_dir="$RUN_DIR/replica-${replica}"
  local outdir="$rep_dir/results"
  local workdir="$rep_dir/work"
  local tmp_root="$workdir/tmp"
  local pkgs_root="$rep_dir/conda-pkgs"
  local cache_root="$rep_dir/nextflow-conda-cache"
  local condarc="$rep_dir/condarc"
  local override="$rep_dir/rnaseq_ares_override.config"

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
process {
  maxForks = 4
}

conda {
  enabled = true
  useMamba = true
  cacheDir = "$cache_root"
  createTimeout = '90 min'
}

params {
  max_cpus = 40
  max_memory = '40.GB'
  max_time = '48.h'
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
    --igenomes_ignore true \
    --fasta "$FASTA" \
    --gtf "$GTF" \
    --outdir "$outdir"

  output_count="$(validate_outputs "$outdir" "$replica")"
  find "$outdir" -type f -size +0 | sort > "$rep_dir/nonempty-outputs.txt"
  echo "nf-core/rnaseq replica $replica native Nextflow baseline completed with $output_count non-empty output files"
}

if [ "${1:-}" = "worker" ]; then
  run_replica "$2"
  exit 0
fi

prepare_inputs

for replica in 0 1 2 3; do
  srun --exclusive --nodes=1 --ntasks=1 --cpus-per-task="${SLURM_CPUS_PER_TASK:-40}" \
    "$0" worker "$replica" > "$RUN_DIR/replica-${replica}.out" 2> "$RUN_DIR/replica-${replica}.err" &
done
wait

for replica in 0 1 2 3; do
  test -s "$RUN_DIR/replica-${replica}/nonempty-outputs.txt"
done

echo "nf-core/rnaseq native 4-node Nextflow baseline completed across 4 nodes"
