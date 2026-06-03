#!/bin/bash
#SBATCH --job-name=genomeqc-single
#SBATCH --exclusive
#SBATCH --partition=compute
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/nf-core_genomeqc/slurm-%j-single.out
#SBATCH --error=runs/nf-core_genomeqc/slurm-%j-single.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

REPO="$ROOT/repos/nf-core_genomeqc"
INPUT="$ROOT/data/nf-core_genomeqc/full/hymenoptera_refseq_samplesheet.csv"
OUTDIR="$ROOT/runs/nf-core_genomeqc/single-${SLURM_JOB_ID:-manual}/results"
WORKDIR="$ROOT/runs/nf-core_genomeqc/single-${SLURM_JOB_ID:-manual}/work"
RUN_DIR="$(dirname "$OUTDIR")"
NF_ENV="$ROOT/tools/conda-envs/nextflow"
MINIFORGE="$ROOT/tools/miniforge"

mkdir -p "$ROOT/runs/nf-core_genomeqc" "$OUTDIR" "$WORKDIR" "$ROOT/tools/nextflow-home" "$ROOT/tools/nextflow-conda-cache"

TMP_ROOT="$WORKDIR/tmp"
PKGS_ROOT="$WORKDIR/conda-pkgs"
mkdir -p "$TMP_ROOT" "$PKGS_ROOT"
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
EOF
export CONDARC="$RUN_DIR/condarc"

cat > "$RUN_DIR/genomeqc_ares_override.config" <<EOF
conda {
  enabled = true
  useMamba = true
  cacheDir = "$RUN_DIR/nextflow-conda-cache"
}

process {
  withName: /.*GENE_OVERLAPS.*/ {
    conda = 'conda-forge::r-base=4.3 conda-forge::r-dplyr bioconda::bioconductor-genomicranges'
  }
}
EOF
mkdir -p "$RUN_DIR/nextflow-conda-cache"

export JAVA_HOME="$NF_ENV"
export JAVA_CMD="$NF_ENV/bin/java"
export NXF_HOME="$ROOT/tools/nextflow-home"
export NXF_OFFLINE=true
export NXF_VER=26.04.1
export NXF_OPTS="-Xms1g -Xmx8g"
export NXF_SYNTAX_PARSER=v1
export PATH="$NF_ENV/bin:$MINIFORGE/bin:$MINIFORGE/condabin:$PATH"

cd "$(dirname "$OUTDIR")"
nextflow run "$REPO" \
  -profile conda \
  -c "$ROOT/config/nextflow_ares_local_conda.config" \
  -c "$RUN_DIR/genomeqc_ares_override.config" \
  -work-dir "$WORKDIR" \
  --input "$INPUT" \
  --groups invertebrate \
  --busco_lineage hymenoptera_odb10 \
  --outdir "$OUTDIR"

if ! find "$OUTDIR/pipeline_info" -maxdepth 1 -type f -name 'execution_trace*' -size +0 | grep -q .; then
  echo "ERROR: missing Nextflow execution trace in $OUTDIR/pipeline_info" >&2
  exit 1
fi

if ! find "$OUTDIR/multiqc" -type f -name 'multiqc_report.html' -size +100000 | grep -q .; then
  echo "ERROR: missing non-trivial MultiQC report" >&2
  exit 1
fi

if ! find "$OUTDIR/quast" -type f -size +0 | grep -q .; then
  echo "ERROR: missing non-empty QUAST outputs" >&2
  exit 1
fi

if ! find "$OUTDIR/busco" -type f -size +0 | grep -q .; then
  echo "ERROR: missing non-empty BUSCO outputs" >&2
  exit 1
fi

OUTPUT_COUNT="$(find "$OUTDIR" -type f -size +0 | wc -l)"
if [ "$OUTPUT_COUNT" -lt 30 ]; then
  echo "ERROR: too few non-empty outputs for genomeqc baseline: $OUTPUT_COUNT" >&2
  exit 1
fi

echo "nf-core/genomeqc single-node native Nextflow baseline completed with $OUTPUT_COUNT non-empty output files"
