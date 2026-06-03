#!/bin/bash
#SBATCH --job-name=viralrecon-single
#SBATCH --exclusive
#SBATCH --partition=compute
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/nf-core_viralrecon/slurm-%j-single.out
#SBATCH --error=runs/nf-core_viralrecon/slurm-%j-single.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

REPO="$ROOT/repos/nf-core_viralrecon"
INPUT_SOURCE="$ROOT/data/nf-core_viralrecon/full_articv3_sra/samplesheet_articv3_sra_https.csv"
OUTDIR="$ROOT/runs/nf-core_viralrecon/single-${SLURM_JOB_ID:-manual}/results"
WORKDIR="$ROOT/runs/nf-core_viralrecon/single-${SLURM_JOB_ID:-manual}/work"
RUN_DIR="$(dirname "$OUTDIR")"
INPUT="$RUN_DIR/samplesheet_full_amplicon_illumina_local.csv"
NF_ENV="$ROOT/tools/conda-envs/nextflow"
MINIFORGE="$ROOT/tools/miniforge"
source "$ROOT/scripts/viralrecon_reference_helpers.sh"

mkdir -p "$ROOT/runs/nf-core_viralrecon" "$OUTDIR" "$WORKDIR" "$ROOT/tools/nextflow-home" "$ROOT/tools/nextflow-conda-cache/nf-core_viralrecon"
mkdir -p "$(dirname "$INPUT_SOURCE")"
cat > "$INPUT_SOURCE" <<EOF
sample,fastq_1,fastq_2
SRR14313561,https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR143/061/SRR14313561/SRR14313561_1.fastq.gz,https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR143/061/SRR14313561/SRR14313561_2.fastq.gz
EOF

TMP_ROOT="$WORKDIR/tmp"
mkdir -p "$TMP_ROOT"
export TMPDIR="$TMP_ROOT"
export NXF_TEMP="$TMP_ROOT"
export _JAVA_OPTIONS="${_JAVA_OPTIONS:-} -Djava.io.tmpdir=$TMP_ROOT"
export MAMBA_YES=true
export MAMBA_ALWAYS_YES=true
export CONDA_ALWAYS_YES=true
export CONDA_PKGS_DIRS="$RUN_DIR/conda-pkgs"
mkdir -p "$CONDA_PKGS_DIRS"
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

cat > "$RUN_DIR/viralrecon_ares_override.config" <<EOF
conda {
  enabled = true
  useMamba = true
  cacheDir = "$ROOT/tools/nextflow-conda-cache/nf-core_viralrecon"
  createTimeout = '90 min'
}

process {
  maxForks = 4

  withName: /.*BOWTIE2_BUILD.*/ {
    memory = 44.GB
  }
}
EOF

export JAVA_HOME="$NF_ENV"
export JAVA_CMD="$NF_ENV/bin/java"
export NXF_HOME="$ROOT/tools/nextflow-home"
export NXF_VER="25.04.8"
export NXF_OPTS="-Xms1g -Xmx8g"
export NXF_SYNTAX_PARSER=v1
export NXF_OFFLINE=true
export PATH="$NF_ENV/bin:$MINIFORGE/bin:$MINIFORGE/condabin:$PATH"
python3 "$ROOT/scripts/localize_url_table.py" \
  --input "$INPUT_SOURCE" \
  --output "$INPUT" \
  --dest-dir "$ROOT/data/nf-core_viralrecon/full/fastq" \
  --columns fastq_1 fastq_2
prepare_viralrecon_references "$ROOT" "$RUN_DIR"

cd "$(dirname "$OUTDIR")"
nextflow run "$REPO" \
  -name "viralrecon_single_${SLURM_JOB_ID:-manual}" \
  -profile conda \
  -c "$ROOT/config/nextflow_ares_local_conda.config" \
  -c "$VIRALRECON_GENOMES_CONFIG" \
  -c "$RUN_DIR/viralrecon_ares_override.config" \
  -work-dir "$WORKDIR" \
  --input "$INPUT" \
  --platform illumina \
  --protocol amplicon \
  --genome MN908947.3 \
  --primer_set artic \
  --primer_set_version 3 \
  --variant_caller ivar \
  --assemblers spades \
  --skip_kraken2 true \
  --skip_pangolin true \
  --skip_nextclade true \
  --skip_freyja true \
  --skip_snpeff true \
  --outdir "$OUTDIR"

if ! find "$OUTDIR/pipeline_info" -maxdepth 1 -type f -name 'execution_trace*' -size +0 | grep -q .; then
  echo "ERROR: missing Nextflow execution trace in $OUTDIR/pipeline_info" >&2
  exit 1
fi

if ! find "$OUTDIR/multiqc" -type f -name 'multiqc_report.html' -size +100000 | grep -q .; then
  echo "ERROR: missing non-trivial MultiQC report" >&2
  exit 1
fi

if ! find "$OUTDIR" -type f \( -name '*.sorted.bam' -o -name '*.vcf.gz' -o -name '*.consensus.fa' -o -name 'variants_long_table.csv' \) -size +0 | grep -q .; then
  echo "ERROR: missing non-empty variant/consensus outputs" >&2
  exit 1
fi

if ! find "$OUTDIR/assembly" -type f \( -name '*.contigs.fa' -o -name '*.contigs.fa.gz' -o -name '*.scaffolds.fa.gz' -o -name '*.assembly.gfa.gz' \) -size +0 | grep -q .; then
  echo "ERROR: missing non-empty assembly outputs" >&2
  exit 1
fi

OUTPUT_COUNT="$(find "$OUTDIR" -type f -size +0 | wc -l)"
if [ "$OUTPUT_COUNT" -lt 150 ]; then
  echo "ERROR: too few non-empty outputs for full viralrecon baseline: $OUTPUT_COUNT" >&2
  exit 1
fi

echo "nf-core/viralrecon single-node native Nextflow baseline completed with $OUTPUT_COUNT non-empty output files"
