#!/bin/bash
#SBATCH --job-name=demultiplex-single
#SBATCH --exclusive
#SBATCH --partition=compute
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/nf-core_demultiplex/slurm-%j-single.out
#SBATCH --error=runs/nf-core_demultiplex/slurm-%j-single.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

REPO="$ROOT/repos/nf-core_demultiplex"
RUN_DIR="$ROOT/runs/nf-core_demultiplex/single-${SLURM_JOB_ID:-manual}"
OUTDIR_FINAL="$RUN_DIR/results"
NODE_RUN_DIR="$RUN_DIR/node-run"
NODE_REPO="$NODE_RUN_DIR/repo"
OUTDIR="$NODE_RUN_DIR/results"
WORKDIR="$NODE_RUN_DIR/work"
LOCAL_INPUT="$NODE_RUN_DIR/pipeline_samplesheet.csv"
OVERRIDE="$RUN_DIR/demultiplex_ares_override.config"
NF_ENV="$ROOT/tools/conda-envs/nextflow"
MINIFORGE="$ROOT/tools/miniforge"

mkdir -p "$ROOT/runs/nf-core_demultiplex" "$RUN_DIR" "$OUTDIR" "$WORKDIR" "$NODE_REPO" "$ROOT/tools/nextflow-home" "$ROOT/tools/nextflow-conda-cache"
cp -a "$REPO/." "$NODE_REPO/"

TMP_ROOT="$WORKDIR/tmp"
mkdir -p "$TMP_ROOT"
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
export CONDA_ALWAYS_YES=true

cat > "$OVERRIDE" <<'EOF'
process {
  withLabel:process_high {
    cpus = 12
    memory = 45.GB
    time = 24.h
  }
  withName:BCL2FASTQ {
    cpus = 12
    memory = 45.GB
    time = 24.h
  }
}
params.max_memory = '40.GB'
params.max_cpus = 40
params.max_time = '48.h'
EOF

export JAVA_HOME="$NF_ENV"
export JAVA_CMD="$NF_ENV/bin/java"
export NXF_HOME="$ROOT/tools/nextflow-home"
export NXF_OFFLINE=true
export NXF_VER=26.04.1
export NXF_OPTS="-Xms1g -Xmx8g"
export NXF_SYNTAX_PARSER=v1
export PATH="$RUN_DIR/podman-bin:$NF_ENV/bin:$MINIFORGE/bin:$MINIFORGE/condabin:$PATH"

source "$ROOT/scripts/demultiplex_fqtk_amplicon_inputs.sh"
prepare_demultiplex_fqtk_amplicon_inputs "$ROOT"
cp "$DEMULTIPLEX_INPUT" "$LOCAL_INPUT"

cd "$NODE_RUN_DIR"
nextflow run "$NODE_REPO" \
  -profile podman \
  -c "$ROOT/config/nextflow_ares_local_podman.config" \
  -c "$OVERRIDE" \
  -work-dir "$WORKDIR" \
  --input "$LOCAL_INPUT" \
  --demultiplexer "$DEMULTIPLEX_DEMUXER" \
  --outdir "$OUTDIR"

mkdir -p "$OUTDIR_FINAL"
cp -a "$OUTDIR/." "$OUTDIR_FINAL/"
OUTDIR="$OUTDIR_FINAL"

if ! find "$OUTDIR/pipeline_info" -maxdepth 1 -type f -name 'execution_trace*' -size +0 | grep -q .; then
  echo "ERROR: missing Nextflow execution trace in $OUTDIR/pipeline_info" >&2
  exit 1
fi

if ! find "$OUTDIR" -type f -name '*multiqc*html' -size +100000 | grep -q .; then
  echo "ERROR: missing non-trivial MultiQC HTML output" >&2
  exit 1
fi

if ! find "$OUTDIR" -type f -name '*.fastq.gz' -size +0 | grep -q .; then
  echo "ERROR: missing demultiplexed FASTQ outputs" >&2
  exit 1
fi

OUTPUT_COUNT="$(find "$OUTDIR" -type f -size +0 | wc -l)"
if [ "$OUTPUT_COUNT" -lt 20 ]; then
  echo "ERROR: too few non-empty outputs for full demultiplex baseline: $OUTPUT_COUNT" >&2
  exit 1
fi

echo "nf-core/demultiplex single-node native Nextflow baseline completed with $OUTPUT_COUNT non-empty output files"
