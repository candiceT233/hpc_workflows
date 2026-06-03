#!/usr/bin/env bash
#SBATCH --job-name=funcscan-4node
#SBATCH --exclusive
#SBATCH --partition=compute
#SBATCH --nodes=4
#SBATCH --ntasks=4
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/nf-core_funcscan/slurm-%j-4node.out
#SBATCH --error=runs/nf-core_funcscan/slurm-%j-4node.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

REPO="$ROOT/repos/nf-core_funcscan"
DATA_DIR="$ROOT/data/nf-core_funcscan/refseq_bacteria"
REMOTE_INPUT="$DATA_DIR/samplesheet_full_https.csv"
FASTA_DIR="$DATA_DIR/fasta"
INPUT="$DATA_DIR/samplesheet_full_local.csv"
RUN_ROOT="$ROOT/runs/nf-core_funcscan"
RUN_DIR="$RUN_ROOT/4node-${SLURM_JOB_ID:-manual}"
NF_ENV="$ROOT/tools/conda-envs/nextflow"
MINIFORGE="$ROOT/tools/miniforge"

mkdir -p "$RUN_ROOT" "$RUN_DIR" "$ROOT/tools/nextflow-home" "$FASTA_DIR"
cd "$ROOT"

download_gzip() {
  local url="$1"
  local dest="$2"
  local tmp="${dest}.part"
  local attempt
  if [ -s "$dest" ] && gzip -t "$dest" >/dev/null 2>&1; then
    return 0
  fi
  if [ -s "$dest" ] && [ ! -s "$tmp" ]; then
    mv "$dest" "$tmp"
  fi
  for attempt in $(seq 1 20); do
    if curl -L --fail --retry 8 --retry-delay 15 --retry-all-errors --continue-at - "$url" -o "$tmp" \
      && gzip -t "$tmp" >/dev/null 2>&1; then
      mv "$tmp" "$dest"
      return 0
    fi
    sleep 30
  done
  echo "ERROR: failed to download and validate $url -> $dest" >&2
  return 1
}

stage_inputs() {
  if [ ! -s "$REMOTE_INPUT" ]; then
    echo "ERROR: missing funcscan remote samplesheet: $REMOTE_INPUT" >&2
    exit 1
  fi
  {
    IFS=, read -r sample_col fasta_col
    printf '%s,%s\n' "$sample_col" "$fasta_col"
    while IFS=, read -r sample fasta_url; do
      [ -n "$sample" ] || continue
      fasta_dest="$FASTA_DIR/$(basename "$fasta_url")"
      download_gzip "$fasta_url" "$fasta_dest"
      printf '%s,%s\n' "$sample" "$fasta_dest"
    done
  } < "$REMOTE_INPUT" > "$INPUT.tmp"
  mv "$INPUT.tmp" "$INPUT"
}

precreate_conda_env() {
  local prefix="$1"
  local env_file="$2"
  local attempt
  if [ -x "$prefix/bin/antismash" ]; then
    return 0
  fi
  rm -rf "$prefix"
  for attempt in $(seq 1 3); do
    if mamba env create --yes --prefix "$prefix" --file "$env_file"; then
      if [ -x "$prefix/bin/antismash" ]; then
        return 0
      fi
    fi
    rm -rf "$prefix"
    sleep 60
  done
  echo "ERROR: failed to pre-create $env_file at $prefix" >&2
  return 1
}

if [ ! -x "$NF_ENV/bin/nextflow" ] || [ ! -s "$REMOTE_INPUT" ]; then
  echo "ERROR: missing required nf-core/funcscan input or executable" >&2
  exit 1
fi

stage_inputs

run_replica() {
  local replica="$1"
  local rep_dir="$RUN_DIR/replica-${replica}"
  local outdir="$rep_dir/results"
  local workdir="$rep_dir/work"
  local tmp_root="$workdir/tmp"
  local pkgs_root="$rep_dir/conda-pkgs"
  local cache_root="$rep_dir/nextflow-conda-cache"
  local condarc="$rep_dir/condarc"
  local override="$rep_dir/funcscan_ares_override.config"

  mkdir -p "$outdir" "$workdir" "$tmp_root" "$pkgs_root" "$cache_root"
  export TMPDIR="$tmp_root"
  export NXF_TEMP="$tmp_root"
  export CONDA_PKGS_DIRS="$pkgs_root"
  export _JAVA_OPTIONS="${_JAVA_OPTIONS:-} -Djava.io.tmpdir=$tmp_root"
  export MAMBA_YES=true
  export MAMBA_ALWAYS_YES=true
  export CONDA_ALWAYS_YES=true
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
  cacheDir = "$cache_root"
  createTimeout = '90 min'
}
process {
  maxForks = 4
  withName: '.*ANTISMASH_ANTISMASH.*' {
    cpus = 8
    memory = '45.GB'
    time = '24.h'
  }
}
EOF

  export JAVA_HOME="$NF_ENV"
  export JAVA_CMD="$NF_ENV/bin/java"
  export NXF_HOME="$ROOT/tools/nextflow-home"
export NXF_OFFLINE=true
  export NXF_VER=26.04.1
  export NXF_OPTS="-Xms1g -Xmx8g"
  export NXF_SYNTAX_PARSER=v1
  export PATH="$NF_ENV/bin:$MINIFORGE/bin:$MINIFORGE/condabin:$PATH"

  precreate_conda_env \
    "$cache_root/env-3afb2e6d352a088017e79a544d2d4222" \
    "$REPO/modules/nf-core/antismash/antismashdownloaddatabases/environment.yml"

  cd "$rep_dir"
  nextflow run "$REPO" \
    -profile conda \
    -c "$ROOT/config/nextflow_ares_local_conda.config" \
    -c "$override" \
    -work-dir "$workdir" \
    --input "$INPUT" \
    --save_annotations true \
    --run_amp_screening true \
    --amp_skip_amplify true \
    --run_arg_screening true \
    --arg_skip_deeparg true \
    --run_bgc_screening true \
    --bgc_skip_deepbgc true \
    --bgc_mincontiglength 1000 \
    --bgc_antismash_contigminlength 1000 \
    --bgc_savefilteredcontigs true \
    --outdir "$outdir"

  if ! find "$outdir/pipeline_info" -maxdepth 1 -type f -name 'execution_trace*' -size +0 | grep -q .; then
    echo "ERROR: replica $replica missing Nextflow execution trace" >&2
    exit 1
  fi
  if ! find "$outdir/multiqc" -type f -name 'multiqc_report.html' -size +100000 | grep -q .; then
    echo "ERROR: replica $replica missing non-trivial MultiQC report" >&2
    exit 1
  fi
  for subdir in arg amp bgc; do
    if ! find "$outdir/$subdir" -type f -size +0 2>/dev/null | grep -q .; then
      echo "ERROR: replica $replica missing non-empty $subdir outputs" >&2
      exit 1
    fi
  done
  output_count="$(find "$outdir" -type f -size +0 | wc -l)"
  if [ "$output_count" -lt 50 ]; then
    echo "ERROR: replica $replica too few non-empty outputs: $output_count" >&2
    exit 1
  fi
  find "$outdir" -type f -size +0 | sort > "$rep_dir/nonempty-outputs.txt"
  echo "nf-core/funcscan replica $replica native Nextflow baseline completed with $output_count non-empty output files"
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

echo "nf-core/funcscan native 4-node Nextflow baseline completed across 4 nodes"
