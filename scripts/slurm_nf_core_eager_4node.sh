#!/usr/bin/env bash
#SBATCH --job-name=eager-4node
#SBATCH --exclusive
#SBATCH --nodes=4
#SBATCH --ntasks=4
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/nf-core_eager/slurm-%j-4node.out
#SBATCH --error=runs/nf-core_eager/slurm-%j-4node.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

RUN_ROOT="${RUN_ROOT:-$ROOT/runs/nf-core_eager}"
RUN_DIR="$RUN_ROOT/4node-${SLURM_JOB_ID:-manual}"
REPO="$ROOT/repos/nf-core_eager"
INPUT_SOURCE="$ROOT/data/nf-core_eager/full_ena/benchmarking_vikingfish_ena.tsv"
INPUT_TSV="$RUN_DIR/benchmarking_vikingfish_local.tsv"
FASTA_URL="https://ftp.ncbi.nlm.nih.gov/genomes/all/GCF/902/167/405/GCF_902167405.1_gadMor3.0/GCF_902167405.1_gadMor3.0_genomic.fna.gz"
REF_DIR="$ROOT/data/nf-core_eager/full_ena/reference"
FASTA_GZ="$REF_DIR/GCF_902167405.1_gadMor3.0_genomic.fna.gz"
FASTA_LOCAL="$REF_DIR/GCF_902167405.1_gadMor3.0_genomic.fna"
NF_ENV="$ROOT/tools/conda-envs/nextflow"
MINIFORGE="$ROOT/tools/miniforge"
CACHE_ROOT="$ROOT/tools/nextflow-conda-cache/nf-core_eager"

mkdir -p "$RUN_ROOT" "$RUN_DIR" "$REF_DIR" "$ROOT/tools/nextflow-home" "$CACHE_ROOT"

for required in "$REPO/main.nf" "$INPUT_SOURCE" "$NF_ENV/bin/nextflow"; do
  if [ ! -s "$required" ] && [ ! -x "$required" ]; then
    echo "ERROR: missing required nf-core/eager artifact: $required" >&2
    exit 1
  fi
done

python3 "$ROOT/scripts/localize_url_table.py" \
  --input "$INPUT_SOURCE" \
  --output "$INPUT_TSV" \
  --dest-dir "$ROOT/data/nf-core_eager/full_ena/fastq" \
  --columns R1 R2 \
  --delimiter tab

if [ ! -s "$FASTA_LOCAL" ]; then
  if [ ! -s "$FASTA_GZ" ]; then
    curl -L --retry 5 --retry-delay 10 -o "$FASTA_GZ.tmp" "$FASTA_URL"
    gzip -t "$FASTA_GZ.tmp"
    mv "$FASTA_GZ.tmp" "$FASTA_GZ"
  fi
  gzip -dc "$FASTA_GZ" > "$FASTA_LOCAL.tmp"
  mv "$FASTA_LOCAL.tmp" "$FASTA_LOCAL"
fi

validate_outputs() {
  local outdir="$1"
  local trace_file="$2"
  local report_file="$3"
  local timeline_file="$4"
  local label="$5"

  test -s "$trace_file"
  test -s "$report_file"
  test -s "$timeline_file"
  test -s "$outdir/multiqc"/*multiqc_report.html
  nonempty="$(find "$outdir" -type f -size +0c | wc -l)"
  if [ "$nonempty" -lt 50 ]; then
    echo "ERROR: $label too few non-empty nf-core/eager outputs: $nonempty" >&2
    exit 3
  fi
  for expected_dir in FastQC AdapterRemoval Mapping MultiQC; do
    if [ ! -d "$outdir/$expected_dir" ] && [ ! -d "$outdir/${expected_dir,,}" ]; then
      echo "ERROR: $label expected nf-core/eager output directory not found: $expected_dir" >&2
      find "$outdir" -maxdepth 2 -type d | sort >&2
      exit 4
    fi
  done
  echo "$nonempty"
}

run_replica() {
  local replica="$1"
  local rep_dir="$RUN_DIR/replica-${replica}"
  local work_dir="$rep_dir/work"
  local out_dir="$rep_dir/results"
  local trace_file="$rep_dir/execution_trace.txt"
  local report_file="$rep_dir/execution_report.html"
  local timeline_file="$rep_dir/timeline.html"
  local tmp_root="$work_dir/tmp"
  local condarc="$rep_dir/condarc"
  local override="$rep_dir/eager_ares_override.config"

  mkdir -p "$work_dir" "$out_dir" "$tmp_root" "$rep_dir/conda-pkgs"
  export TMPDIR="$tmp_root"
  export NXF_TEMP="$tmp_root"
  export CONDA_PKGS_DIRS="$rep_dir/conda-pkgs"
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
conda {
  enabled = true
  useMamba = true
  cacheDir = "$CACHE_ROOT"
}
params {
  bwaalnn = 0.04
  bwaalnl = 1024
  run_bam_filtering = true
  bam_unmapped_type = 'discard'
  bam_mapping_quality_threshold = 25
  run_genotyping = true
  genotyping_tool = 'hc'
  genotyping_source = 'raw'
  gatk_ploidy = 2
  schema_ignore_params = 'genomes,input_paths,input'
}
EOF

  export JAVA_HOME="$NF_ENV"
  export JAVA_CMD="$NF_ENV/bin/java"
  export NXF_HOME="$ROOT/tools/nextflow-home"
  export NXF_OFFLINE=true
  export NXF_VER=22.10.6
  export PATH="$NF_ENV/bin:$MINIFORGE/bin:$MINIFORGE/condabin:$PATH"

  cd "$rep_dir"
  nextflow run "$REPO" \
    -profile conda \
    -c "$ROOT/config/nextflow_ares_local_conda.config" \
    -c "$override" \
    -name "eager_4node_${SLURM_JOB_ID:-manual}_${replica}" \
    -w "$work_dir" \
    -with-trace "$trace_file" \
    -with-report "$report_file" \
    -with-timeline "$timeline_file" \
    --input "$INPUT_TSV" \
    --fasta "$FASTA_LOCAL" \
    --outdir "$out_dir"

  output_count="$(validate_outputs "$out_dir" "$trace_file" "$report_file" "$timeline_file" "replica $replica")"
  find "$out_dir" -type f -size +0c | sort > "$rep_dir/nonempty-outputs.txt"
  echo "nf-core/eager replica $replica native Nextflow baseline completed with $output_count non-empty output files."
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

echo "nf-core/eager native 4-node Nextflow workflow completed across 4 nodes."
