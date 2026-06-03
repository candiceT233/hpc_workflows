#!/usr/bin/env bash
#SBATCH --job-name=viralint-4
#SBATCH --exclusive
#SBATCH --partition=compute
#SBATCH --nodes=4
#SBATCH --ntasks=4
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/nf-core_viralintegration/slurm-%j-4node.out
#SBATCH --error=runs/nf-core_viralintegration/slurm-%j-4node.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

REPO="$ROOT/repos/nf-core_viralintegration"
INPUT_DIR="$ROOT/data/nf-core_viralintegration/full"
INPUT="$INPUT_DIR/samplesheet_srr23719851_hela_wgs.csv"
VIRAL_FASTA="$INPUT_DIR/virus_db.nr.fasta"
HOST_FASTA="$ROOT/data/nf-core_deepvariant/giab_exome/Homo_sapiens.GRCh37.dna.primary_assembly.fa"
HOST_GTF="$INPUT_DIR/Homo_sapiens.GRCh37.87.gtf"
RUN_ROOT="$ROOT/runs/nf-core_viralintegration"
RUN_DIR="$RUN_ROOT/4node-${SLURM_JOB_ID:-manual}"
NF_ENV="$ROOT/tools/conda-envs/nextflow"
MINIFORGE="$ROOT/tools/miniforge"

mkdir -p "$RUN_ROOT" "$RUN_DIR" "$ROOT/tools/nextflow-home" "$INPUT_DIR"
cd "$ROOT"

prepare_inputs() {
  source "$ROOT/scripts/viralintegration_real_inputs.sh"
  prepare_viralintegration_real_inputs "$ROOT" "$INPUT_DIR" "$INPUT" "$VIRAL_FASTA" "$HOST_FASTA" "$HOST_GTF"
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
  if ! find "$outdir" -type f \( -name '*.bam' -o -name '*.bai' -o -name '*.tsv' -o -name '*.png' -o -name '*.html' \) -size +0 | grep -q .; then
    echo "ERROR: $label missing non-empty viral integration terminal outputs" >&2
    exit 1
  fi
  output_count="$(find "$outdir" -type f -size +0 | wc -l)"
  if [ "$output_count" -lt 10 ]; then
    echo "ERROR: $label too few non-empty viralintegration outputs: $output_count" >&2
    exit 1
  fi
  echo "$output_count"
}

run_replica() {
  local replica="$1"
  local rep_dir="$RUN_DIR/replica-${replica}"
  local node_repo="$rep_dir/repo"
  local outdir="$rep_dir/results"
  local workdir="$rep_dir/work"
  local tmp_root="$workdir/tmp"
  local podman_base="/tmp/pdm-viralintegration-${SLURM_JOB_ID:-$$}-${replica}"
  local override="$rep_dir/viralintegration_ares_override.config"

  mkdir -p "$outdir" "$workdir" "$tmp_root" "$rep_dir/podman-bin" "$node_repo" "$podman_base"/{xdg,root,run,tmp}
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
  cat > "$override" <<'EOF'
podman {
  enabled = true
  runOptions = '--userns=keep-id'
}
conda { enabled = false }
EOF

  export TMPDIR="$tmp_root" NXF_TEMP="$tmp_root" XDG_RUNTIME_DIR="$podman_base/xdg"
  export _JAVA_OPTIONS="${_JAVA_OPTIONS:-} -Djava.io.tmpdir=$tmp_root"
  export JAVA_HOME="$NF_ENV" JAVA_CMD="$NF_ENV/bin/java" NXF_HOME="$ROOT/tools/nextflow-home"
  export NXF_OFFLINE=true
  export NXF_VER=24.10.5 NXF_OPTS="-Xms1g -Xmx8g" NXF_SYNTAX_PARSER=v1
  export PATH="$rep_dir/podman-bin:$NF_ENV/bin:$MINIFORGE/bin:$MINIFORGE/condabin:$PATH"

  cd "$rep_dir"
  nextflow run "$node_repo" \
    -name "viralintegration_4node_${SLURM_JOB_ID:-manual}_${replica}" \
    -profile podman \
    -c "$ROOT/config/nextflow_ares_local_podman.config" \
    -c "$override" \
    -work-dir "$workdir" \
    --max_memory 40.GB \
    --max_cpus 40 \
    --max_time 48.h \
    --input "$INPUT" \
    --viral_fasta "$VIRAL_FASTA" \
    --fasta "$HOST_FASTA" \
    --gtf "$HOST_GTF" \
    --igenomes_ignore true \
    --remove_duplicates true \
    --min_reads 5 \
    --max_hits 50 \
    --outdir "$outdir"

  output_count="$(validate_outputs "$outdir" "replica $replica")"
  find "$outdir" -type f -size +0 | sort > "$rep_dir/nonempty-outputs.txt"
  echo "nf-core/viralintegration replica $replica native Nextflow baseline completed with $output_count non-empty output files"
}

if [ "${1:-}" = "worker" ]; then
  run_replica "$2"
  exit 0
fi

prepare_inputs
for replica in 0 1 2 3; do
  srun --exclusive --nodes=1 --ntasks=1 --cpus-per-task="${SLURM_CPUS_PER_TASK:-40}" \
    "$0" worker "$replica" > "$RUN_DIR/replica-${replica}.out" 2> "$RUN_DIR/replica-${replica}.err" &
done
wait

for replica in 0 1 2 3; do
  test -s "$RUN_DIR/replica-${replica}/nonempty-outputs.txt"
done

echo "nf-core/viralintegration native 4-node Nextflow baseline completed across 4 nodes"
