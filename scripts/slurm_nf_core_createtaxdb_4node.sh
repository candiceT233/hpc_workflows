#!/usr/bin/env bash
#SBATCH --job-name=createtaxdb-4node
#SBATCH --exclusive
#SBATCH --partition=compute
#SBATCH --nodes=4
#SBATCH --ntasks=4
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/nf-core_createtaxdb/slurm-%j-4node.out
#SBATCH --error=runs/nf-core_createtaxdb/slurm-%j-4node.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

REPO="$ROOT/repos/nf-core_createtaxdb"
RUN_ROOT="$ROOT/runs/nf-core_createtaxdb"
RUN_DIR="$RUN_ROOT/4node-${SLURM_JOB_ID:-manual}"
NF_ENV="$ROOT/tools/conda-envs/nextflow"
MINIFORGE="$ROOT/tools/miniforge"

mkdir -p "$RUN_ROOT" "$RUN_DIR" "$ROOT/tools/nextflow-home"
cd "$ROOT"

source "$ROOT/scripts/createtaxdb_refseq_viral_inputs.sh"
prepare_createtaxdb_refseq_viral_inputs "$ROOT"

for required in "$NF_ENV/bin/nextflow" "$CREATETAXDB_INPUT" "$CREATETAXDB_ACCESSION2TAXID" "$CREATETAXDB_PROT2TAXID" "$CREATETAXDB_NODESDMP" "$CREATETAXDB_NAMESDMP"; do
  if [ ! -s "$required" ] && [ ! -x "$required" ]; then
    echo "ERROR: missing required nf-core/createtaxdb artifact: $required" >&2
    exit 1
  fi
done

run_replica() {
  local replica="$1"
  local rep_dir="$RUN_DIR/replica-${replica}"
  local outdir="$rep_dir/results"
  local workdir="$rep_dir/work"
  local tmp_root="$workdir/tmp"
  local pkgs_root="$rep_dir/conda-pkgs"
  local cache_root="$rep_dir/nextflow-conda-cache"
  local condarc="$rep_dir/condarc"
  local override="$rep_dir/createtaxdb_ares_override.config"

  mkdir -p "$outdir" "$workdir" "$tmp_root" "$pkgs_root" "$cache_root"
  export TMPDIR="$tmp_root"
  export NXF_TEMP="$tmp_root"
  export CONDA_PKGS_DIRS="$pkgs_root"
  export _JAVA_OPTIONS="${_JAVA_OPTIONS:-} -Djava.io.tmpdir=$tmp_root"
  export MAMBA_YES=true
  export MAMBA_ALWAYS_YES=true
  export CONDA_ALWAYS_YES=true
  export NXF_OFFLINE=true
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
  withLabel: process_high {
    cpus = 8
    memory = '40 GB'
  }
  withName: /.*GANON_BUILDCUSTOM.*/ {
    cpus = 8
    memory = '40 GB'
  }
  withName: /.*SYLPH_SKETCHGENOMES.*/ {
    cpus = 8
    memory = '40 GB'
  }
  withName: /.*KAIJU_MKFMI.*/ {
    cpus = 8
    memory = '40 GB'
  }
  withName: /.*METACACHE_BUILD.*/ {
    cpus = 8
    memory = '40 GB'
  }
}

conda {
  enabled = true
  useMamba = true
  cacheDir = "$cache_root"
  createTimeout = '90 min'
}
EOF

  export JAVA_HOME="$NF_ENV"
  export JAVA_CMD="$NF_ENV/bin/java"
  export NXF_HOME="$ROOT/tools/nextflow-home"
  export NXF_OPTS="-Xms1g -Xmx8g"
  export NXF_SYNTAX_PARSER=v1
  export PATH="$NF_ENV/bin:$MINIFORGE/bin:$MINIFORGE/condabin:$PATH"

  cd "$rep_dir"
  nextflow run "$REPO" \
    -profile conda \
    -c "$override" \
    -c "$ROOT/config/nextflow_ares_local_conda.config" \
    -work-dir "$workdir" \
    --input "$CREATETAXDB_INPUT" \
    --dbname "ncbi_refseq_viral" \
    --accession2taxid "$CREATETAXDB_ACCESSION2TAXID" \
    --prot2taxid "$CREATETAXDB_PROT2TAXID" \
    --nodesdmp "$CREATETAXDB_NODESDMP" \
    --namesdmp "$CREATETAXDB_NAMESDMP" \
    --build_diamond \
    --diamond_build_options "--no-parse-seqids" \
    --build_kraken2 \
    --generate_downstream_samplesheets \
    --generate_pipeline_samplesheets "taxprofiler" \
    --outdir "$outdir"

  if ! find "$outdir/pipeline_info" -maxdepth 1 -type f -name 'execution_trace_*.txt' -size +0 | grep -q .; then
    echo "ERROR: replica $replica missing Nextflow execution trace" >&2
    exit 1
  fi
  output_count="$(find "$outdir" -type f -size +0 | wc -l)"
  if [ "$output_count" -lt 20 ]; then
    echo "ERROR: replica $replica too few non-empty outputs: $output_count" >&2
    exit 1
  fi
  if ! find "$outdir" -type f \( -name '*.fmi' -o -name '*.k2d' -o -name '*.dmnd' -o -name '*.mmi' -o -name '*.sbt.zip' \) -size +0 | grep -q .; then
    echo "ERROR: replica $replica has no non-empty classifier database artifacts" >&2
    exit 1
  fi
  find "$outdir" -type f -size +0 | sort > "$rep_dir/nonempty-outputs.txt"
  echo "nf-core/createtaxdb replica $replica native Nextflow baseline completed with $output_count non-empty output files"
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

echo "nf-core/createtaxdb native 4-node Nextflow baseline completed across 4 nodes"
