#!/bin/bash
#SBATCH --job-name=viralintegration-single
#SBATCH --exclusive
#SBATCH --partition=compute
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/nf-core_viralintegration/slurm-%j-single.out
#SBATCH --error=runs/nf-core_viralintegration/slurm-%j-single.err

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
RUN_DIR="$ROOT/runs/nf-core_viralintegration/single-${SLURM_JOB_ID:-manual}"
OUTDIR_FINAL="$RUN_DIR/results"
NODE_RUN_DIR="$RUN_DIR/node-run"
NODE_REPO="$NODE_RUN_DIR/repo"
OUTDIR="$NODE_RUN_DIR/results"
WORKDIR="$NODE_RUN_DIR/work"
NF_ENV="$ROOT/tools/conda-envs/nextflow"
MINIFORGE="$ROOT/tools/miniforge"

mkdir -p "$ROOT/runs/nf-core_viralintegration" "$RUN_DIR" "$OUTDIR" "$WORKDIR" "$NODE_REPO" "$ROOT/tools/nextflow-home" "$INPUT_DIR"
cp -a "$REPO/." "$NODE_REPO/"

TMP_ROOT="$WORKDIR/tmp"
PKGS_ROOT="$RUN_DIR/conda-pkgs"
CONDARC_FILE="$RUN_DIR/condarc"
mkdir -p "$TMP_ROOT" "$PKGS_ROOT" "$RUN_DIR/nextflow-conda-cache"
cat > "$CONDARC_FILE" <<EOF
always_yes: true
auto_activate_base: false
channel_priority: flexible
pkgs_dirs:
  - $PKGS_ROOT
channels:
  - conda-forge
  - bioconda
  - defaults
EOF
export TMPDIR="$TMP_ROOT"
export NXF_TEMP="$TMP_ROOT"
PODMAN_BASE="$RUN_DIR/podman-storage"
export XDG_RUNTIME_DIR="$PODMAN_BASE/xdg"
mkdir -p "$XDG_RUNTIME_DIR" "$PODMAN_BASE/root" "$PODMAN_BASE/run" "$PODMAN_BASE/tmp" "$RUN_DIR/podman-bin"
chmod 700 "$XDG_RUNTIME_DIR"
PODMAN_REAL="$(command -v podman || true)"
if [ -z "$PODMAN_REAL" ]; then
  echo "ERROR: podman is not available on this compute node" >&2
  exit 1
fi
cat > "$RUN_DIR/podman-bin/podman" <<EOF
#!/bin/bash
exec "$PODMAN_REAL" --storage-driver vfs --root "$PODMAN_BASE/root" --runroot "$PODMAN_BASE/run" --tmpdir "$PODMAN_BASE/tmp" "\$@"
EOF
chmod +x "$RUN_DIR/podman-bin/podman"
export _JAVA_OPTIONS="${_JAVA_OPTIONS:-} -Djava.io.tmpdir=$TMP_ROOT"
export MAMBA_YES=true
export MAMBA_ALWAYS_YES=true
export CONDA_ALWAYS_YES=true
export CONDA_PKGS_DIRS="$PKGS_ROOT"
export CONDARC="$CONDARC_FILE"

cat > "$RUN_DIR/viralintegration_ares_override.config" <<EOF
podman {
  enabled = true
  runOptions = '--userns=keep-id'
}

conda {
  enabled = false
}
EOF

export JAVA_HOME="$NF_ENV"
export JAVA_CMD="$NF_ENV/bin/java"
export NXF_HOME="$ROOT/tools/nextflow-home"
export NXF_OFFLINE=true
export NXF_VER="24.10.5"
export NXF_OPTS="-Xms1g -Xmx8g"
export NXF_SYNTAX_PARSER=v1
export PATH="$RUN_DIR/podman-bin:$NF_ENV/bin:$MINIFORGE/bin:$MINIFORGE/condabin:$PATH"

source "$ROOT/scripts/viralintegration_real_inputs.sh"
prepare_viralintegration_real_inputs "$ROOT" "$INPUT_DIR" "$INPUT" "$VIRAL_FASTA" "$HOST_FASTA" "$HOST_GTF"

cd "$NODE_RUN_DIR"
nextflow run "$NODE_REPO" \
  -name "viralintegration_single_${SLURM_JOB_ID:-manual}" \
  -profile podman \
  -c "$ROOT/config/nextflow_ares_local_podman.config" \
  -c "$RUN_DIR/viralintegration_ares_override.config" \
  -work-dir "$WORKDIR" \
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
  --outdir "$OUTDIR"

mkdir -p "$OUTDIR_FINAL"
cp -a "$OUTDIR/." "$OUTDIR_FINAL/"
OUTDIR="$OUTDIR_FINAL"

if ! find "$OUTDIR/pipeline_info" -maxdepth 1 -type f -name 'execution_trace*' -size +0 | grep -q .; then
  echo "ERROR: missing Nextflow execution trace in $OUTDIR/pipeline_info" >&2
  exit 1
fi

if ! find "$OUTDIR/multiqc" -type f -name 'multiqc_report.html' -size +100000 | grep -q .; then
  echo "ERROR: missing non-trivial MultiQC report" >&2
  exit 1
fi

if ! find "$OUTDIR" -type f \( -name '*.bam' -o -name '*.bai' -o -name '*.tsv' -o -name '*.png' -o -name '*.html' \) -size +0 | grep -q .; then
  echo "ERROR: missing non-empty viral integration terminal outputs" >&2
  exit 1
fi

OUTPUT_COUNT="$(find "$OUTDIR" -type f -size +0 | wc -l)"
if [ "$OUTPUT_COUNT" -lt 10 ]; then
  echo "ERROR: too few non-empty outputs for viralintegration baseline: $OUTPUT_COUNT" >&2
  exit 1
fi

echo "nf-core/viralintegration single-node native Nextflow baseline completed with $OUTPUT_COUNT non-empty output files"
