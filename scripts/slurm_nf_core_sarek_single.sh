#!/bin/bash
#SBATCH --job-name=sarek-single
#SBATCH --exclusive
#SBATCH --partition=compute
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/nf-core_sarek/slurm-%j-single.out
#SBATCH --error=runs/nf-core_sarek/slurm-%j-single.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

REPO="$ROOT/repos/nf-core_sarek"
INPUT="$ROOT/data/nf-core_sarek/full_ena/HCC1395_WXS_somatic_full_ena.csv"
LOCAL_INPUT="$ROOT/data/nf-core_sarek/full_ena/HCC1395_WXS_somatic_full_local.csv"
OUTDIR="$ROOT/runs/nf-core_sarek/single-${SLURM_JOB_ID:-manual}/results"
WORKDIR="$ROOT/runs/nf-core_sarek/single-${SLURM_JOB_ID:-manual}/work"
RUN_DIR="$(dirname "$OUTDIR")"
NF_ENV="$ROOT/tools/conda-envs/nextflow"
MINIFORGE="$ROOT/tools/miniforge"

mkdir -p "$ROOT/runs/nf-core_sarek" "$OUTDIR" "$WORKDIR" "$ROOT/tools/nextflow-home" "$ROOT/tools/nextflow-conda-cache"
mkdir -p "$ROOT/data/nf-core_sarek/full_ena/fastq"

python3 "$ROOT/scripts/localize_url_table.py" \
  --input "$INPUT" \
  --output "$LOCAL_INPUT" \
  --dest-dir "$ROOT/data/nf-core_sarek/full_ena/fastq" \
  --columns fastq_1 fastq_2 \
  --attempts 5

TMP_ROOT="$WORKDIR/tmp"
mkdir -p "$TMP_ROOT"
export TMPDIR="$TMP_ROOT"
export NXF_TEMP="$TMP_ROOT"
export _JAVA_OPTIONS="${_JAVA_OPTIONS:-} -Djava.io.tmpdir=$TMP_ROOT"
export MAMBA_YES=true
export MAMBA_ALWAYS_YES=true
export CONDA_ALWAYS_YES=true
export CONDA_PKGS_DIRS="$RUN_DIR/conda-pkgs"
mkdir -p "$CONDA_PKGS_DIRS" "$RUN_DIR/nextflow-conda-cache"
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

cat > "$RUN_DIR/sarek_ares_override.config" <<EOF
conda {
  enabled = true
  useMamba = true
  cacheDir = "$RUN_DIR/nextflow-conda-cache"
}

params {
  bwa = null
  known_indels = [
    'https://ngi-igenomes.s3.amazonaws.com/igenomes/Homo_sapiens/GATK/GRCh38/Annotation/GATKBundle/Mills_and_1000G_gold_standard.indels.hg38.vcf.gz',
    'https://ngi-igenomes.s3.amazonaws.com/igenomes/Homo_sapiens/GATK/GRCh38/Annotation/GATKBundle/beta/Homo_sapiens_assembly38.known_indels.vcf.gz'
  ]
  known_indels_tbi = [
    'https://ngi-igenomes.s3.amazonaws.com/igenomes/Homo_sapiens/GATK/GRCh38/Annotation/GATKBundle/Mills_and_1000G_gold_standard.indels.hg38.vcf.gz.tbi',
    'https://ngi-igenomes.s3.amazonaws.com/igenomes/Homo_sapiens/GATK/GRCh38/Annotation/GATKBundle/beta/Homo_sapiens_assembly38.known_indels.vcf.gz.tbi'
  ]
}
EOF

export JAVA_HOME="$NF_ENV"
export JAVA_CMD="$NF_ENV/bin/java"
export NXF_HOME="$ROOT/tools/nextflow-home"
export NXF_VER="26.04.1"
export NXF_OPTS="-Xms1g -Xmx8g"
export NXF_SYNTAX_PARSER=v1
export PATH="$NF_ENV/bin:$MINIFORGE/bin:$MINIFORGE/condabin:$PATH"

cd "$(dirname "$OUTDIR")"
nextflow run "$REPO" \
  -profile conda \
  -c "$ROOT/config/nextflow_ares_local_conda.config" \
  -c "$RUN_DIR/sarek_ares_override.config" \
  -work-dir "$WORKDIR" \
  --input "$LOCAL_INPUT" \
  --validate_params false \
  --tools "ascat,cnvkit,controlfreec,freebayes,lofreq,manta,msisensor2,muse,mutect2,ngscheckmate,strelka,tiddit" \
  --split_fastq 20000000 \
  --wes true \
  --no_intervals true \
  --filter_vcfs true \
  --normalize_vcfs true \
  --snv_consensus_calling true \
  --igenomes_base "https://ngi-igenomes.s3.amazonaws.com/igenomes/" \
  --outdir "$OUTDIR"

if ! find "$OUTDIR/pipeline_info" -maxdepth 1 -type f -name 'execution_trace*' -size +0 | grep -q .; then
  echo "ERROR: missing Nextflow execution trace in $OUTDIR/pipeline_info" >&2
  exit 1
fi

if ! find "$OUTDIR/multiqc" -type f -name 'multiqc_report.html' -size +100000 | grep -q .; then
  echo "ERROR: missing non-trivial MultiQC report" >&2
  exit 1
fi

if ! find "$OUTDIR" -type f \( -name '*.bam' -o -name '*.bai' -o -name '*.cram' -o -name '*.crai' \) -size +0 | grep -q .; then
  echo "ERROR: missing non-empty alignment outputs" >&2
  exit 1
fi

if ! find "$OUTDIR" -type f \( -name '*.vcf.gz' -o -name '*.bcf' \) -size +0 | grep -q .; then
  echo "ERROR: missing non-empty variant outputs" >&2
  exit 1
fi

OUTPUT_COUNT="$(find "$OUTDIR" -type f -size +0 | wc -l)"
if [ "$OUTPUT_COUNT" -lt 100 ]; then
  echo "ERROR: too few non-empty outputs for full Sarek baseline: $OUTPUT_COUNT" >&2
  exit 1
fi

echo "nf-core/sarek single-node native Nextflow baseline completed with $OUTPUT_COUNT non-empty output files"
