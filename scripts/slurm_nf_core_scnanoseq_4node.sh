#!/usr/bin/env bash
#SBATCH --job-name=scnanoseq-4
#SBATCH --exclusive
#SBATCH --partition=compute
#SBATCH --nodes=4
#SBATCH --ntasks=4
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/nf-core_scnanoseq/slurm-%j-4node.out
#SBATCH --error=runs/nf-core_scnanoseq/slurm-%j-4node.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

REPO="$ROOT/repos/nf-core_scnanoseq"
DATA_DIR="$ROOT/data/nf-core_scnanoseq/full"
LOCAL_INPUT="$DATA_DIR/samplesheet_full_local.csv"
FASTQ_DIR="$DATA_DIR/fastq"
RUN_ROOT="$ROOT/runs/nf-core_scnanoseq"
RUN_DIR="$RUN_ROOT/4node-${SLURM_JOB_ID:-manual}"
NF_ENV="$ROOT/tools/conda-envs/nextflow"
MINIFORGE="$ROOT/tools/miniforge"

mkdir -p "$RUN_ROOT" "$RUN_DIR" "$ROOT/tools/nextflow-home" "$FASTQ_DIR"
cd "$ROOT"

fetch_fastq() {
  local sample="$1"
  local url="$2"
  local dest="$FASTQ_DIR/${sample}.fastq.gz"
  local part="${dest}.part"
  if [ -s "$dest" ] && gzip -t "$dest" >/dev/null 2>&1; then
    return 0
  fi
  if [ -s "$part" ] && gzip -t "$part" >/dev/null 2>&1; then
    mv "$part" "$dest"
    return 0
  fi
  rm -f "$dest"
  curl -L --fail --retry 8 --retry-delay 20 --retry-all-errors --continue-at - -o "$part" "$url"
  gzip -t "$part"
  mv "$part" "$dest"
}

prepare_inputs() {
  fetch_fastq ERR9958133 https://ftp.sra.ebi.ac.uk/vol1/fastq/ERR995/003/ERR9958133/ERR9958133.fastq.gz
  fetch_fastq ERR9958134 https://ftp.sra.ebi.ac.uk/vol1/fastq/ERR995/004/ERR9958134/ERR9958134.fastq.gz
  cat > "$LOCAL_INPUT" <<EOF
sample,fastq,cell_count
ERR9958133,$FASTQ_DIR/ERR9958133.fastq.gz,1000
ERR9958134,$FASTQ_DIR/ERR9958134.fastq.gz,1000
EOF
}

validate_outputs() {
  local outdir="$1"
  local label="$2"
  if ! find "$outdir/pipeline_info" -maxdepth 1 -type f -name 'execution_trace*' -size +0 | grep -q .; then
    echo "ERROR: $label missing Nextflow execution trace" >&2
    exit 1
  fi
  if ! find "$outdir/multiqc" -type f -name 'multiqc_report.html' -size +100000 | grep -q .; then
    echo "ERROR: $label missing non-trivial MultiQC report" >&2
    exit 1
  fi
  if ! find "$outdir" -type f \( -name '*.sorted.bam' -o -name '*.dedup.bam' -o -name '*.tagged.bam' -o -name '*.bam' \) -size +0 | grep -q .; then
    echo "ERROR: $label missing non-empty BAM alignment outputs" >&2
    exit 1
  fi
  if ! find "$outdir" -type f \( -name '*.gene_counts.tsv' -o -name '*.transcript_counts.tsv' -o -name '*quant*.tsv' -o -name '*quant*.csv' \) -size +0 | grep -q .; then
    echo "ERROR: $label missing non-empty feature-barcode quantification outputs" >&2
    exit 1
  fi
  output_count="$(find "$outdir" -type f -size +0 | wc -l)"
  if [ "$output_count" -lt 80 ]; then
    echo "ERROR: $label too few non-empty scnanoseq outputs: $output_count" >&2
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
  local override="$rep_dir/scnanoseq_ares_override.config"

  mkdir -p "$outdir" "$workdir" "$tmp_root" "$pkgs_root" "$cache_root"
  export TMPDIR="$tmp_root"
  export NXF_TEMP="$tmp_root"
  export CONDA_PKGS_DIRS="$pkgs_root"
  export _JAVA_OPTIONS="${_JAVA_OPTIONS:-} -Djava.io.tmpdir=$tmp_root"
  export MAMBA_YES=true MAMBA_ALWAYS_YES=true CONDA_ALWAYS_YES=true
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
process { maxForks = 4 }
conda {
  enabled = true
  useMamba = true
  cacheDir = "$cache_root"
  createTimeout = '90 min'
}
EOF

  export JAVA_HOME="$NF_ENV" JAVA_CMD="$NF_ENV/bin/java" NXF_HOME="$ROOT/tools/nextflow-home"
  export NXF_OFFLINE=true
  export NXF_VER=24.10.5 NXF_OPTS="-Xms1g -Xmx8g" NXF_SYNTAX_PARSER=v1
  export PATH="$NF_ENV/bin:$MINIFORGE/bin:$MINIFORGE/condabin:$PATH"

  cd "$rep_dir"
  nextflow run "$REPO" \
    -profile conda \
    -c "$ROOT/config/nextflow_ares_local_conda.config" \
    -c "$override" \
    -work-dir "$workdir" \
    --input "$LOCAL_INPUT" \
    --genome_fasta "https://ftp.ebi.ac.uk/pub/databases/gencode/Gencode_human/release_45/GRCh38.primary_assembly.genome.fa.gz" \
    --transcript_fasta "https://ftp.ebi.ac.uk/pub/databases/gencode/Gencode_human/release_45/gencode.v45.transcripts.fa.gz" \
    --gtf "https://ftp.ebi.ac.uk/pub/databases/gencode/Gencode_human/release_45/gencode.v45.annotation.gtf.gz" \
    --barcode_format "10X_3v3" \
    --split_amount 500000 \
    --quantifier "isoquant,oarfish" \
    --outdir "$outdir"

  output_count="$(validate_outputs "$outdir" "replica $replica")"
  find "$outdir" -type f -size +0 | sort > "$rep_dir/nonempty-outputs.txt"
  echo "nf-core/scnanoseq replica $replica native Nextflow baseline completed with $output_count non-empty output files"
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

echo "nf-core/scnanoseq native 4-node Nextflow baseline completed across 4 nodes"
