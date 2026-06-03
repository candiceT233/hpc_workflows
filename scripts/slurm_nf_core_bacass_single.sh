#!/bin/bash
#SBATCH --job-name=bacass-single
#SBATCH --exclusive
#SBATCH --partition=compute
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/nf-core_bacass/slurm-%j-single.out
#SBATCH --error=runs/nf-core_bacass/slurm-%j-single.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
REPO="$ROOT/repos/nf-core_bacass"
DATA_DIR="$ROOT/data/nf-core_bacass/full"
FASTQ_DIR="$DATA_DIR/fastq"
INPUT_TSV="$DATA_DIR/bacass_full_local.tsv"
OUTDIR="$ROOT/runs/nf-core_bacass/single-${SLURM_JOB_ID:-manual}/results"
WORKDIR="$ROOT/runs/nf-core_bacass/single-${SLURM_JOB_ID:-manual}/work"
RUN_DIR="$(dirname "$OUTDIR")"
NF_ENV="$ROOT/tools/conda-envs/nextflow"
MINIFORGE="$ROOT/tools/miniforge"

mkdir -p "$ROOT/runs/nf-core_bacass" "$RUN_DIR" "$OUTDIR" "$WORKDIR" "$ROOT/tools/nextflow-home" "$FASTQ_DIR"

TMP_ROOT="$WORKDIR/tmp"
PKGS_ROOT="$RUN_DIR/conda-pkgs"
mkdir -p "$TMP_ROOT" "$PKGS_ROOT" "$RUN_DIR/nextflow-conda-cache"
export TMPDIR="$TMP_ROOT"
export NXF_TEMP="$TMP_ROOT"
export CONDA_PKGS_DIRS="$PKGS_ROOT"
export _JAVA_OPTIONS="${_JAVA_OPTIONS:-} -Djava.io.tmpdir=$TMP_ROOT"
export MAMBA_YES=true
export MAMBA_ALWAYS_YES=true
export CONDA_ALWAYS_YES=true
cat > "$RUN_DIR/condarc" <<'EOF'
always_yes: true
auto_activate_base: false
channel_priority: flexible
channels:
  - conda-forge
  - bioconda
  - defaults
EOF
export CONDARC="$RUN_DIR/condarc"

cat > "$RUN_DIR/bacass_ares_override.config" <<EOF
conda {
  enabled = true
  useMamba = true
  cacheDir = "$RUN_DIR/nextflow-conda-cache"
  createTimeout = '240 min'
}

process {
  resourceLimits = [
    cpus: 40,
    memory: '45.GB',
    time: '48.h'
  ]
  withName: /.*UNICYCLER.*/ {
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
export NXF_OPTS="-Xms1g -Xmx8g"
export NXF_SYNTAX_PARSER=v1
export PATH="$NF_ENV/bin:$MINIFORGE/bin:$MINIFORGE/condabin:$PATH"

download_file() {
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

download_file "https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR848/005/SRR8482585/SRR8482585_1.fastq.gz" "$FASTQ_DIR/SRR8482585_1.fastq.gz"
download_file "https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR848/005/SRR8482585/SRR8482585_2.fastq.gz" "$FASTQ_DIR/SRR8482585_2.fastq.gz"
download_file "https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR100/029/SRR10093029/SRR10093029_1.fastq.gz" "$FASTQ_DIR/SRR10093029_1.fastq.gz"
download_file "https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR100/029/SRR10093029/SRR10093029_2.fastq.gz" "$FASTQ_DIR/SRR10093029_2.fastq.gz"

for fastq in "$FASTQ_DIR"/*.fastq.gz; do
  gzip -t "$fastq"
done

cat > "$INPUT_TSV" <<EOF
ID	R1	R2	LongFastQ	Fast5	GenomeSize
SRR8482585	$FASTQ_DIR/SRR8482585_1.fastq.gz	$FASTQ_DIR/SRR8482585_2.fastq.gz	NA	NA	NA
SRR10093029	$FASTQ_DIR/SRR10093029_1.fastq.gz	$FASTQ_DIR/SRR10093029_2.fastq.gz	NA	NA	NA
EOF

cd "$(dirname "$OUTDIR")"
nextflow run "$REPO" \
  -profile conda \
  -c "$ROOT/config/nextflow_ares_local_conda.config" \
  -c "$RUN_DIR/bacass_ares_override.config" \
  -work-dir "$WORKDIR" \
  --input "$INPUT_TSV" \
  --assembly_type short \
  --kraken2db "https://genome-idx.s3.amazonaws.com/kraken/k2_standard_8gb_20210517.tar.gz" \
  --kmerfinderdb "https://zenodo.org/records/13447056/files/20190108_kmerfinder_stable_dirs.tar.gz" \
  --outdir "$OUTDIR"

if ! find "$OUTDIR/pipeline_info" -maxdepth 1 -type f -name 'execution_trace_*.txt' -size +0 | grep -q .; then
  echo "ERROR: missing Nextflow execution trace in $OUTDIR/pipeline_info" >&2
  exit 1
fi

if ! find "$OUTDIR" -type f -name '*multiqc*html' -size +100000 | grep -q .; then
  echo "ERROR: missing non-trivial MultiQC HTML output" >&2
  exit 1
fi

OUTPUT_COUNT="$(find "$OUTDIR" -type f -size +0 | wc -l)"
if [ "$OUTPUT_COUNT" -lt 20 ]; then
  echo "ERROR: too few non-empty outputs for full bacass baseline: $OUTPUT_COUNT" >&2
  exit 1
fi

echo "nf-core/bacass single-node native Nextflow baseline completed with $OUTPUT_COUNT non-empty output files"
