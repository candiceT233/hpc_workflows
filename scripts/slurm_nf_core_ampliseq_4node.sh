#!/usr/bin/env bash
#SBATCH --job-name=ampliseq-4node
#SBATCH --exclusive
#SBATCH --partition=compute
#SBATCH --nodes=4
#SBATCH --ntasks=4
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/nf-core_ampliseq/slurm-%j-4node.out
#SBATCH --error=runs/nf-core_ampliseq/slurm-%j-4node.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

REPO="$ROOT/repos/nf-core_ampliseq"
RUN_ROOT="$ROOT/runs/nf-core_ampliseq"
RUN_DIR="$RUN_ROOT/4node-${SLURM_JOB_ID:-manual}"
INPUT_DIR="$ROOT/data/nf-core_ampliseq/full"
LOCAL_SAMPLESHEET="$INPUT_DIR/Samplesheet_full.local.tsv"
LOCAL_METADATA="$INPUT_DIR/Metadata_full.tsv"
REF_DIR="$INPUT_DIR/ref"
NF_ENV="$ROOT/tools/conda-envs/nextflow"
MINIFORGE="$ROOT/tools/miniforge"
source "$ROOT/scripts/ampliseq_full_inputs.sh"

mkdir -p "$RUN_ROOT" "$RUN_DIR" "$ROOT/tools/nextflow-home" "$ROOT/tools/nextflow-conda-cache/nf-core_ampliseq"
cd "$ROOT"
prepare_ampliseq_full_inputs "$ROOT"

for required in "$NF_ENV/bin/nextflow" "$AMPLISEQ_SAMPLESHEET" "$AMPLISEQ_METADATA" \
  "$REF_DIR/sbdi-gtdb.assignTaxonomy.fna.gz" "$REF_DIR/sbdi-gtdb.addSpecies.fna.gz" \
  "$REF_DIR/85_otus.fna" "$REF_DIR/85_otu_taxonomy.tax"; do
  if [ ! -s "$required" ] && [ ! -x "$required" ]; then
    echo "ERROR: missing required nf-core/ampliseq artifact: $required" >&2
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
  local override="$rep_dir/ampliseq_ares_override.config"

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
conda {
  enabled = true
  useMamba = true
  cacheDir = "$ROOT/tools/nextflow-conda-cache/nf-core_ampliseq"
  createTimeout = '360 min'
}

process.maxForks = 4
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
    -c "$ROOT/config/nextflow_ares_local_conda.config" \
    -c "$override" \
    -work-dir "$workdir" \
    --input "$AMPLISEQ_SAMPLESHEET" \
    --metadata "$AMPLISEQ_METADATA" \
    --FW_primer "GTGYCAGCMGCCGCGGTAA" \
    --RV_primer "GGACTACNVGGGTWTCTAAT" \
    --dada_ref_tax_custom "$REF_DIR/sbdi-gtdb.assignTaxonomy.fna.gz" \
    --dada_ref_tax_custom_sp "$REF_DIR/sbdi-gtdb.addSpecies.fna.gz" \
    --dada_assign_taxlevels "Domain,Kingdom,Phylum,Class,Order,Family,Genus,Species" \
    --qiime_ref_tax_custom "$REF_DIR/85_otus.fna,$REF_DIR/85_otu_taxonomy.tax" \
    --trunc_qmin 35 \
    --min_samples 3 \
    --min_frequency 30 \
    --metadata_category_barplot "habitat" \
    --qiime_adonis_formula "habitat" \
    --ancom \
    --ancombc \
    --run_pplace false \
    --outdir "$outdir"

  if ! find "$outdir/pipeline_info" -maxdepth 1 -type f -name 'execution_trace_*.txt' -size +0 | grep -q .; then
    echo "ERROR: replica $replica missing Nextflow execution trace" >&2
    exit 1
  fi
  if ! find "$outdir" -type f -name '*multiqc*html' -size +100000 | grep -q .; then
    echo "ERROR: replica $replica missing non-trivial MultiQC HTML output" >&2
    exit 1
  fi
  output_count="$(find "$outdir" -type f -size +0 | wc -l)"
  if [ "$output_count" -lt 20 ]; then
    echo "ERROR: replica $replica too few non-empty outputs: $output_count" >&2
    exit 1
  fi
  find "$outdir" -type f -size +0 | sort > "$rep_dir/nonempty-outputs.txt"
  echo "nf-core/ampliseq replica $replica native Nextflow baseline completed with $output_count non-empty output files"
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

echo "nf-core/ampliseq native 4-node Nextflow baseline completed across 4 nodes"
