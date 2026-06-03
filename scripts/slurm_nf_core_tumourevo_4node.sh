#!/usr/bin/env bash
#SBATCH --job-name=tumourevo-4
#SBATCH --exclusive
#SBATCH --partition=compute
#SBATCH --nodes=4
#SBATCH --ntasks=4
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/nf-core_tumourevo/slurm-%j-4node.out
#SBATCH --error=runs/nf-core_tumourevo/slurm-%j-4node.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

REPO="$ROOT/repos/nf-core_tumourevo"
INPUT_DIR="$ROOT/data/nf-core_tumourevo/full_real"
INPUT="$INPUT_DIR/samplesheet_cnaqc_set06.csv"
VCF="$INPUT_DIR/Set.06.WGS.merged_filtered.vcf"
TBI="$INPUT_DIR/Set.06.WGS.merged_filtered.vcf.tbi"
CNA_SEGMENTS="$INPUT_DIR/Set6_42.smoothedSegs.txt"
CNA_EXTRA="$INPUT_DIR/Set6_42_confints_CP.txt"
FASTA="$INPUT_DIR/Homo_sapiens.GRCh38.dna.primary_assembly.fa.gz"
DRIVERS_TABLE="$INPUT_DIR/IntOGen_20240920_Compendium_Cancer_Genes.tumourevo.tsv"
VEP_CACHE_URL="${TUMOUREVO_VEP_CACHE_URL:-https://ftp.ensembl.org/pub/release-110/variation/indexed_vep_cache/homo_sapiens_vep_110_GRCh38.tar.gz}"
VEP_CACHE_DIR="${TUMOUREVO_VEP_CACHE_DIR:-$ROOT/data/nf-core_tumourevo/full/vep_cache}"
VEP_CACHE_FILE="$VEP_CACHE_DIR/homo_sapiens_vep_110_GRCh38.tar.gz"
VEP_CACHE_EXTRACTED="$VEP_CACHE_DIR/homo_sapiens"
RUN_ROOT="$ROOT/runs/nf-core_tumourevo"
RUN_DIR="$RUN_ROOT/4node-${SLURM_JOB_ID:-manual}"
NF_ENV="$ROOT/tools/conda-envs/nextflow"
MINIFORGE="$ROOT/tools/miniforge"

mkdir -p "$RUN_ROOT" "$RUN_DIR" "$ROOT/tools/nextflow-home" "$VEP_CACHE_DIR" "$INPUT_DIR"
cd "$ROOT"

ensure_vep_cache() {
  if [ -d "$VEP_CACHE_EXTRACTED" ] && find "$VEP_CACHE_EXTRACTED" -type f -size +0 | grep -q .; then
    return 0
  fi
  if [ -s "$VEP_CACHE_FILE" ]; then
    echo "Resuming incomplete VEP cache download: $VEP_CACHE_FILE"
  fi
  curl --fail --location --retry 20 --retry-delay 30 --continue-at - \
    --output "$VEP_CACHE_FILE" "$VEP_CACHE_URL"
  gzip -t "$VEP_CACHE_FILE"
  tar -xzf "$VEP_CACHE_FILE" -C "$VEP_CACHE_DIR"
  if [ ! -d "$VEP_CACHE_EXTRACTED" ]; then
    echo "ERROR: extracted VEP cache missing $VEP_CACHE_EXTRACTED" >&2
    return 1
  fi
}

write_override() {
  local path="$1"
  local cache_root="$2"
  cat > "$path" <<EOF
process {
  maxForks = 4
}

conda {
  enabled = true
  useMamba = true
  cacheDir = "$cache_root"
  createTimeout = '90 min'
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
  if ! find "$outdir" -type f \( -name '*.rds' -o -name '*.pdf' -o -name '*.png' -o -name '*.tsv' -o -name '*.csv' \) -size +0 | grep -q .; then
    echo "ERROR: $label missing non-empty tumour evolution analysis outputs" >&2
    exit 1
  fi
  if ! find "$outdir/subclonal_deconvolution" -type f -size +0 | grep -q .; then
    echo "ERROR: $label missing non-empty subclonal deconvolution outputs" >&2
    exit 1
  fi
  output_count="$(find "$outdir" -type f -size +0 | wc -l)"
  if [ "$output_count" -lt 30 ]; then
    echo "ERROR: $label too few non-empty tumourevo outputs: $output_count" >&2
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
  local override="$rep_dir/tumourevo_ares_override.config"

  mkdir -p "$outdir" "$workdir" "$tmp_root" "$pkgs_root" "$cache_root"
  export TMPDIR="$tmp_root" NXF_TEMP="$tmp_root" CONDA_PKGS_DIRS="$pkgs_root"
  export _JAVA_OPTIONS="${_JAVA_OPTIONS:-} -Djava.io.tmpdir=$tmp_root"
  export MAMBA_YES=true MAMBA_ALWAYS_YES=true CONDA_ALWAYS_YES=true
  cat > "$condarc" <<EOF
always_yes: true
auto_activate_base: false
channel_priority: flexible
pkgs_dirs:
  - $pkgs_root
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
    -name "tumourevo_4node_${SLURM_JOB_ID:-manual}_${replica}" \
    -profile conda \
    -c "$ROOT/config/nextflow_ares_local_conda.config" \
	    -c "$override" \
	    -work-dir "$workdir" \
	    --input "$INPUT" \
	    --filter false \
	    --fasta "$FASTA" \
	    --drivers_table "$DRIVERS_TABLE" \
	    --download_cache_vep false \
	    --vep_cache "$VEP_CACHE_DIR" \
	    --vep_genome GRCh38 \
	    --vep_species homo_sapiens \
	    --vep_cache_version 110 \
	    --outdir "$outdir"

  output_count="$(validate_outputs "$outdir" "replica $replica")"
  find "$outdir" -type f -size +0 | sort > "$rep_dir/nonempty-outputs.txt"
  echo "nf-core/tumourevo replica $replica native Nextflow baseline completed with $output_count non-empty output files"
}

if [ "${1:-}" = "worker" ]; then
  run_replica "$2"
  exit 0
fi

source "$ROOT/scripts/tumourevo_real_inputs.sh"
prepare_tumourevo_real_inputs "$ROOT" "$INPUT_DIR" "$INPUT" "$VCF" "$TBI" "$CNA_SEGMENTS" "$CNA_EXTRA" "$FASTA" "$DRIVERS_TABLE"

for required in "$INPUT" "$NF_ENV/bin/nextflow" "$FASTA" "$DRIVERS_TABLE"; do
  if [ ! -s "$required" ] && [ ! -x "$required" ]; then
    echo "ERROR: missing required tumourevo input/runtime: $required" >&2
    exit 1
  fi
done

ensure_vep_cache

for replica in 0 1 2 3; do
  srun --exclusive --nodes=1 --ntasks=1 --cpus-per-task="${SLURM_CPUS_PER_TASK:-40}" \
    "$0" worker "$replica" > "$RUN_DIR/replica-${replica}.out" 2> "$RUN_DIR/replica-${replica}.err" &
done
wait

for replica in 0 1 2 3; do
  test -s "$RUN_DIR/replica-${replica}/nonempty-outputs.txt"
done

echo "nf-core/tumourevo native 4-node Nextflow baseline completed across 4 nodes"
