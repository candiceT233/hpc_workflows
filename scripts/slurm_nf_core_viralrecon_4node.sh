#!/usr/bin/env bash
#SBATCH --job-name=viralrecon-4
#SBATCH --exclusive
#SBATCH --partition=compute
#SBATCH --nodes=4
#SBATCH --ntasks=4
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/nf-core_viralrecon/slurm-%j-4node.out
#SBATCH --error=runs/nf-core_viralrecon/slurm-%j-4node.err

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
RUN_ROOT="$ROOT/runs/nf-core_viralrecon"
RUN_DIR="$RUN_ROOT/4node-${SLURM_JOB_ID:-manual}"
INPUT="$RUN_DIR/samplesheet_full_amplicon_illumina_local.csv"
NF_ENV="$ROOT/tools/conda-envs/nextflow"
MINIFORGE="$ROOT/tools/miniforge"
CACHE_ROOT="$ROOT/tools/nextflow-conda-cache/nf-core_viralrecon"
source "$ROOT/scripts/viralrecon_reference_helpers.sh"

mkdir -p "$RUN_ROOT" "$RUN_DIR" "$ROOT/tools/nextflow-home" "$CACHE_ROOT"
mkdir -p "$(dirname "$INPUT_SOURCE")"
cat > "$INPUT_SOURCE" <<EOF
sample,fastq_1,fastq_2
SRR14313561,https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR143/061/SRR14313561/SRR14313561_1.fastq.gz,https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR143/061/SRR14313561/SRR14313561_2.fastq.gz
EOF
cd "$ROOT"
python3 "$ROOT/scripts/localize_url_table.py" \
  --input "$INPUT_SOURCE" \
  --output "$INPUT" \
  --dest-dir "$ROOT/data/nf-core_viralrecon/full/fastq" \
  --columns fastq_1 fastq_2
prepare_viralrecon_references "$ROOT" "$RUN_DIR"

write_override() {
  local path="$1"
  cat > "$path" <<EOF
conda {
  enabled = true
  useMamba = true
  cacheDir = "$CACHE_ROOT"
  createTimeout = '90 min'
}

process {
  maxForks = 4
  withName: /.*BOWTIE2_BUILD.*/ {
    memory = 44.GB
  }
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
  if ! find "$outdir" -type f \( -name '*.sorted.bam' -o -name '*.vcf.gz' -o -name '*.consensus.fa' -o -name 'variants_long_table.csv' \) -size +0 | grep -q .; then
    echo "ERROR: $label missing non-empty variant/consensus outputs" >&2
    exit 1
  fi
  if ! find "$outdir/assembly" -type f \( -name '*.contigs.fa' -o -name '*.contigs.fa.gz' -o -name '*.scaffolds.fa.gz' -o -name '*.assembly.gfa.gz' \) -size +0 | grep -q .; then
    echo "ERROR: $label missing non-empty assembly outputs" >&2
    exit 1
  fi
  output_count="$(find "$outdir" -type f -size +0 | wc -l)"
  if [ "$output_count" -lt 150 ]; then
    echo "ERROR: $label too few non-empty viralrecon outputs: $output_count" >&2
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
  local condarc="$rep_dir/condarc"
  local override="$rep_dir/viralrecon_ares_override.config"

  mkdir -p "$outdir" "$workdir" "$tmp_root" "$pkgs_root"
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
  write_override "$override"

  export JAVA_HOME="$NF_ENV" JAVA_CMD="$NF_ENV/bin/java" NXF_HOME="$ROOT/tools/nextflow-home"
  export NXF_OFFLINE=true
  export NXF_VER=25.04.8 NXF_OPTS="-Xms1g -Xmx8g" NXF_SYNTAX_PARSER=v1
  export PATH="$NF_ENV/bin:$MINIFORGE/bin:$MINIFORGE/condabin:$PATH"

  cd "$rep_dir"
  nextflow run "$REPO" \
    -name "viralrecon_4node_${SLURM_JOB_ID:-manual}_${replica}" \
    -profile conda \
    -c "$ROOT/config/nextflow_ares_local_conda.config" \
    -c "$VIRALRECON_GENOMES_CONFIG" \
    -c "$override" \
    -work-dir "$workdir" \
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
    --outdir "$outdir"

  output_count="$(validate_outputs "$outdir" "replica $replica")"
  find "$outdir" -type f -size +0 | sort > "$rep_dir/nonempty-outputs.txt"
  echo "nf-core/viralrecon replica $replica native Nextflow baseline completed with $output_count non-empty output files"
}

if [ "${1:-}" = "worker" ]; then
  run_replica "$2"
  exit 0
fi

if [ ! -s "$INPUT" ]; then
  echo "ERROR: missing viralrecon full samplesheet: $INPUT" >&2
  exit 1
fi

for replica in 0 1 2 3; do
  srun --exclusive --nodes=1 --ntasks=1 --cpus-per-task="${SLURM_CPUS_PER_TASK:-40}" \
    "$0" worker "$replica" > "$RUN_DIR/replica-${replica}.out" 2> "$RUN_DIR/replica-${replica}.err" &
done
wait

for replica in 0 1 2 3; do
  test -s "$RUN_DIR/replica-${replica}/nonempty-outputs.txt"
done

echo "nf-core/viralrecon native 4-node Nextflow baseline completed across 4 nodes"
