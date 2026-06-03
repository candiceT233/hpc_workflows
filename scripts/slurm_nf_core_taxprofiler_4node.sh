#!/usr/bin/env bash
#SBATCH --job-name=taxprof-4
#SBATCH --exclusive
#SBATCH --partition=compute
#SBATCH --nodes=4
#SBATCH --ntasks=4
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/nf-core_taxprofiler/slurm-%j-4node.out
#SBATCH --error=runs/nf-core_taxprofiler/slurm-%j-4node.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

REPO="$ROOT/repos/nf-core_taxprofiler"
DATA_DIR="$ROOT/data/nf-core_taxprofiler/full_real"
INPUT="$DATA_DIR/samplesheet_full_https.csv"
DATABASES="$DATA_DIR/database_kraken2_standard8gb_https.csv"
LOCAL_INPUT="$DATA_DIR/samplesheet_full_local.csv"
LOCAL_DATABASES="$DATA_DIR/database_kraken2_standard8gb_local.csv"
RUN_ROOT="$ROOT/runs/nf-core_taxprofiler"
RUN_DIR="$RUN_ROOT/4node-${SLURM_JOB_ID:-manual}"
NF_ENV="$ROOT/tools/conda-envs/nextflow"
MINIFORGE="$ROOT/tools/miniforge"

mkdir -p "$RUN_ROOT" "$RUN_DIR" "$ROOT/tools/nextflow-home"
cd "$ROOT"

mkdir -p "$DATA_DIR/fastq" "$DATA_DIR/databases"
python3 "$ROOT/scripts/localize_url_table.py" \
  --input "$INPUT" \
  --output "$LOCAL_INPUT" \
  --dest-dir "$DATA_DIR/fastq" \
  --columns fastq_1 fastq_2 \
  --attempts 5
python3 "$ROOT/scripts/localize_url_table.py" \
  --input "$DATABASES" \
  --output "$LOCAL_DATABASES" \
  --dest-dir "$DATA_DIR/databases" \
  --columns db_path \
  --attempts 5
write_override() {
  local path="$1"
  local cache_root="$2"
  cat > "$path" <<EOF
process {
  resourceLimits = [
    cpus: 40,
    memory: 45.GB,
    time: 48.h
  ]
  withName: /.*BOWTIE2_ALIGN.*/ {
    cpus = 12
    memory = 45.GB
    time = 24.h
  }
  withName: /.*BOWTIE2_BUILD.*/ {
    cpus = 12
    memory = 40.GB
    time = 12.h
  }
  maxForks = 4
}

conda {
  enabled = true
  useMamba = true
  cacheDir = "$cache_root"
  createTimeout = '90 min'
}

params {
  max_memory = '40.GB'
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
  if ! find "$outdir/multiqc" -type f -name 'multiqc_report.html' -size +100000 | grep -q .; then
    echo "ERROR: $label missing non-trivial MultiQC report" >&2
    exit 1
  fi
  if ! find "$outdir" -type f \( -name '*combined_reports*' -o -name '*.profile' -o -name '*.tre' -o -name '*.sylph.tsv' -o -name '*bracken*.tsv' \) -size +0 | grep -q .; then
    echo "ERROR: $label missing non-empty taxonomic profile outputs" >&2
    exit 1
  fi
  tool_dirs="$(find "$outdir" -mindepth 1 -maxdepth 1 -type d | wc -l)"
  if [ "$tool_dirs" -lt 3 ]; then
    echo "ERROR: $label too few output tool directories: $tool_dirs" >&2
    exit 1
  fi
  output_count="$(find "$outdir" -type f -size +0 | wc -l)"
  if [ "$output_count" -lt 20 ]; then
    echo "ERROR: $label too few non-empty taxprofiler outputs: $output_count" >&2
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
  local override="$rep_dir/taxprofiler_ares_override.config"

  mkdir -p "$outdir" "$workdir" "$tmp_root" "$pkgs_root" "$cache_root"
  export TMPDIR="$tmp_root" NXF_TEMP="$tmp_root" CONDA_PKGS_DIRS="$pkgs_root"
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
  write_override "$override" "$cache_root"

  export JAVA_HOME="$NF_ENV" JAVA_CMD="$NF_ENV/bin/java" NXF_HOME="$ROOT/tools/nextflow-home"
  export NXF_OFFLINE=true
  export NXF_VER=25.04.8 NXF_OPTS="-Xms1g -Xmx8g" NXF_SYNTAX_PARSER=v1
  export PATH="$NF_ENV/bin:$MINIFORGE/bin:$MINIFORGE/condabin:$PATH"

  cd "$rep_dir"
  nextflow run "$REPO" \
    -name "taxprofiler_4node_${SLURM_JOB_ID:-manual}_${replica}" \
    -profile conda \
    -c "$ROOT/config/nextflow_ares_local_conda.config" \
    -c "$override" \
    -work-dir "$workdir" \
    --input "$LOCAL_INPUT" \
    --databases "$LOCAL_DATABASES" \
    --run_kraken2 true \
    --outdir "$outdir"

  output_count="$(validate_outputs "$outdir" "replica $replica")"
  find "$outdir" -type f -size +0 | sort > "$rep_dir/nonempty-outputs.txt"
  echo "nf-core/taxprofiler replica $replica native Nextflow baseline completed with $output_count non-empty output files"
}

if [ "${1:-}" = "worker" ]; then
  run_replica "$2"
  exit 0
fi

for required in "$LOCAL_INPUT" "$LOCAL_DATABASES" "$NF_ENV/bin/nextflow"; do
  if [ ! -s "$required" ] && [ ! -x "$required" ]; then
    echo "ERROR: missing required taxprofiler input/runtime: $required" >&2
    exit 1
  fi
done

for replica in 0 1 2 3; do
  srun --exclusive --nodes=1 --ntasks=1 --cpus-per-task="${SLURM_CPUS_PER_TASK:-40}" \
    "$0" worker "$replica" > "$RUN_DIR/replica-${replica}.out" 2> "$RUN_DIR/replica-${replica}.err" &
done
wait

for replica in 0 1 2 3; do
  test -s "$RUN_DIR/replica-${replica}/nonempty-outputs.txt"
done

echo "nf-core/taxprofiler native 4-node Nextflow baseline completed across 4 nodes"
