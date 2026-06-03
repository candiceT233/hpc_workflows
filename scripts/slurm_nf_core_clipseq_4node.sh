#!/usr/bin/env bash
#SBATCH --job-name=clipseq-4node
#SBATCH --exclusive
#SBATCH --partition=compute
#SBATCH --nodes=4
#SBATCH --ntasks=4
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/nf-core_clipseq/slurm-%j-4node.out
#SBATCH --error=runs/nf-core_clipseq/slurm-%j-4node.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

REPO="$ROOT/repos/nf-core_clipseq"
RUN_ROOT="$ROOT/runs/nf-core_clipseq"
RUN_DIR="$RUN_ROOT/4node-${SLURM_JOB_ID:-manual}"
INPUT="$ROOT/data/nf-core_clipseq/full/metadata_full_https.csv"
FASTQ_DIR="$ROOT/data/nf-core_clipseq/full/fastq"
LOCAL_INPUT="$ROOT/data/nf-core_clipseq/full/metadata_full_local.csv"
REF_DIR="$ROOT/data/nf-core_clipseq/full/reference"
FASTA="$REF_DIR/GRCh38.primary_assembly.genome.fa.gz"
GTF="$REF_DIR/gencode.v37.primary_assembly.annotation.gtf.gz"
NF_ENV="$ROOT/tools/conda-envs/nextflow"
MINIFORGE="$ROOT/tools/miniforge"

mkdir -p "$RUN_ROOT" "$RUN_DIR" "$ROOT/tools/nextflow-home" "$FASTQ_DIR"
cd "$ROOT"

for required in "$NF_ENV/bin/nextflow" "$INPUT" "$FASTA" "$GTF"; do
  if [ ! -s "$required" ] && [ ! -x "$required" ]; then
    echo "ERROR: missing required nf-core/clipseq artifact: $required" >&2
    exit 1
  fi
done

python3 "$ROOT/scripts/localize_url_table.py" \
  --input "$INPUT" \
  --output "$LOCAL_INPUT" \
  --dest-dir "$FASTQ_DIR" \
  --columns fastq

run_replica() {
  local replica="$1"
  local rep_dir="$RUN_DIR/replica-${replica}"
  local node_repo="$rep_dir/repo"
  local outdir="$rep_dir/results"
  local workdir="$rep_dir/work"
  local tmp_root="$workdir/tmp"
  local podman_base="/tmp/pdm-${SLURM_JOB_ID:-manual}-clipseq-${replica}"

  mkdir -p "$outdir" "$workdir" "$tmp_root" "$rep_dir/podman-bin" "$node_repo" \
    "$podman_base/xdg" "$podman_base/root" "$podman_base/run" "$podman_base/tmp"
  cp -a "$REPO/." "$node_repo/"
  chmod 700 "$podman_base/xdg"
  local podman_real
  podman_real="$(command -v podman || true)"
  if [ -z "$podman_real" ]; then
    echo "ERROR: podman is not available on this compute node" >&2
    exit 1
  fi
  cat > "$rep_dir/podman-bin/podman" <<EOF
#!/bin/bash
exec "$podman_real" --root "$podman_base/root" --runroot "$podman_base/run" --tmpdir "$podman_base/tmp" "\$@"
EOF
  chmod +x "$rep_dir/podman-bin/podman"

  export TMPDIR="$tmp_root"
  export NXF_TEMP="$tmp_root"
  export XDG_RUNTIME_DIR="$podman_base/xdg"
  export _JAVA_OPTIONS="${_JAVA_OPTIONS:-} -Djava.io.tmpdir=$tmp_root"
  export JAVA_HOME="$NF_ENV"
  export JAVA_CMD="$NF_ENV/bin/java"
  export NXF_VER=22.10.8
  export NXF_HOME="$ROOT/tools/nextflow-home"
  export NXF_OFFLINE=true
  export NXF_OPTS="-Xms1g -Xmx8g"
  export PATH="$rep_dir/podman-bin:$NF_ENV/bin:$MINIFORGE/bin:$MINIFORGE/condabin:$PATH"

  cd "$rep_dir"
  nextflow run "$node_repo" \
    -profile podman \
    -c "$ROOT/config/nextflow_ares_local_podman.config" \
    -work-dir "$workdir" \
    --input "$LOCAL_INPUT" \
    --smrna_org human \
    --fasta "$FASTA" \
    --gtf "$GTF" \
    --move_umi "NNNNNNNNN" \
    --umi_separator "_" \
    --peakcaller "icount,paraclu,pureclip,piranha" \
    --pureclip_iv "chr1;chr2" \
    --motif true \
    --outdir "$outdir"

  if ! find "$outdir/pipeline_info" -maxdepth 1 -type f -name 'execution_trace*' -size +0 | grep -q .; then
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
  echo "nf-core/clipseq replica $replica native Nextflow baseline completed with $output_count non-empty output files"
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

echo "nf-core/clipseq native 4-node Nextflow baseline completed across 4 nodes"
