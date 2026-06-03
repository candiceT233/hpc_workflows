#!/bin/bash
#SBATCH --job-name=createtaxdb-single
#SBATCH --exclusive
#SBATCH --partition=compute
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/nf-core_createtaxdb/slurm-%j-single.out
#SBATCH --error=runs/nf-core_createtaxdb/slurm-%j-single.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
REPO="$ROOT/repos/nf-core_createtaxdb"
OUTDIR="$ROOT/runs/nf-core_createtaxdb/single-${SLURM_JOB_ID:-manual}/results"
WORKDIR="$ROOT/runs/nf-core_createtaxdb/single-${SLURM_JOB_ID:-manual}/work"
RUN_DIR="$(dirname "$OUTDIR")"
CUSTOM_CONFIG="$RUN_DIR/createtaxdb_ares_memory.config"
NF_ENV="$ROOT/tools/conda-envs/nextflow"
MINIFORGE="$ROOT/tools/miniforge"

mkdir -p "$ROOT/runs/nf-core_createtaxdb" "$RUN_DIR" "$OUTDIR" "$WORKDIR" "$ROOT/tools/nextflow-home" "$ROOT/tools/nextflow-conda-cache"

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
export NXF_OFFLINE=true
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

source "$ROOT/scripts/createtaxdb_refseq_viral_inputs.sh"
prepare_createtaxdb_refseq_viral_inputs "$ROOT"

export JAVA_HOME="$NF_ENV"
export JAVA_CMD="$NF_ENV/bin/java"
export NXF_HOME="$ROOT/tools/nextflow-home"
export NXF_OPTS="-Xms1g -Xmx8g"
export NXF_SYNTAX_PARSER=v1
export PATH="$NF_ENV/bin:$MINIFORGE/bin:$MINIFORGE/condabin:$PATH"

cat > "$CUSTOM_CONFIG" <<CONFIG
process {
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
  cacheDir = "$RUN_DIR/nextflow-conda-cache"
}
CONFIG

cd "$(dirname "$OUTDIR")"
nextflow run "$REPO" \
  -profile conda \
  -c "$CUSTOM_CONFIG" \
  -c "$ROOT/config/nextflow_ares_local_conda.config" \
  -work-dir "$WORKDIR" \
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
  --outdir "$OUTDIR"

if ! find "$OUTDIR/pipeline_info" -maxdepth 1 -type f -name 'execution_trace_*.txt' -size +0 | grep -q .; then
  echo "ERROR: missing Nextflow execution trace in $OUTDIR/pipeline_info" >&2
  exit 1
fi

OUTPUT_COUNT="$(find "$OUTDIR" -type f -size +0 | wc -l)"
if [ "$OUTPUT_COUNT" -lt 20 ]; then
  echo "ERROR: too few non-empty outputs for full createtaxdb baseline: $OUTPUT_COUNT" >&2
  exit 1
fi

if ! find "$OUTDIR" -type f \( -name '*.fmi' -o -name '*.k2d' -o -name '*.dmnd' -o -name '*.mmi' -o -name '*.sbt.zip' \) -size +0 | grep -q .; then
  echo "ERROR: no non-empty classifier database artifacts found" >&2
  exit 1
fi

echo "nf-core/createtaxdb single-node native Nextflow baseline completed with $OUTPUT_COUNT non-empty output files"
