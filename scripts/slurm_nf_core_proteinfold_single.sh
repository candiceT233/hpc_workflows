#!/bin/bash
#SBATCH --job-name=proteinfold-single
#SBATCH --exclusive
#SBATCH --partition=compute
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/nf-core_proteinfold/slurm-%j-single.out
#SBATCH --error=runs/nf-core_proteinfold/slurm-%j-single.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

REPO="$ROOT/repos/nf-core_proteinfold"
INPUT="$ROOT/data/nf-core_proteinfold/full/samplesheet_uniprot_reviewed_local.csv"
RUN_DIR="$ROOT/runs/nf-core_proteinfold/single-${SLURM_JOB_ID:-manual}"
OUTDIR_FINAL="$RUN_DIR/results"
NODE_RUN_DIR="$RUN_DIR/node-run"
NODE_REPO="$NODE_RUN_DIR/repo"
OUTDIR="$NODE_RUN_DIR/results"
WORKDIR="$NODE_RUN_DIR/work"
NF_ENV="$ROOT/tools/conda-envs/nextflow"

mkdir -p "$ROOT/runs/nf-core_proteinfold" "$RUN_DIR" "$OUTDIR" "$WORKDIR" "$ROOT/tools/nextflow-home" "$NODE_REPO"
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

export JAVA_HOME="$NF_ENV"
export JAVA_CMD="$NF_ENV/bin/java"
export NXF_HOME="$ROOT/tools/nextflow-home"
export NXF_VER="26.04.1"
export NXF_OPTS="-Xms1g -Xmx8g"
export NXF_SYNTAX_PARSER=v1
export NXF_OFFLINE=true
export PATH="$RUN_DIR/podman-bin:$NF_ENV/bin:$ROOT/tools/miniforge/bin:$ROOT/tools/miniforge/condabin:$PATH"

cd "$NODE_RUN_DIR"
nextflow run "$NODE_REPO" \
  -profile podman \
  -c "$ROOT/config/nextflow_ares_local_podman.config" \
  -work-dir "$WORKDIR" \
  --input "$INPUT" \
  --mode colabfold \
  --use_msa_server true \
  --colabfold_model_preset alphafold2_ptm \
  --colabfold_use_gpu_relax false \
  --colabfold_use_amber false \
  --colabfold_use_templates false \
  --outdir "$OUTDIR"

mkdir -p "$OUTDIR_FINAL"
cp -a "$OUTDIR/." "$OUTDIR_FINAL/"
OUTDIR="$OUTDIR_FINAL"

if ! find "$OUTDIR/pipeline_info" -maxdepth 1 -type f -name '*trace*' -size +0 | grep -q .; then
  echo "ERROR: missing Nextflow execution trace in $OUTDIR/pipeline_info" >&2
  exit 1
fi

if ! find "$OUTDIR/multiqc" -type f -name '*multiqc_report.html' -size +100000 | grep -q .; then
  echo "ERROR: missing non-trivial MultiQC report" >&2
  exit 1
fi

if ! find "$OUTDIR" -type f \( -name '*.pdb' -o -name '*.cif' -o -name '*.json' -o -name '*.pkl' \) -size +0 | grep -q .; then
  echo "ERROR: missing non-empty protein structure prediction outputs" >&2
  exit 1
fi

if ! find "$OUTDIR" -type f -name '*report*.html' -size +10000 | grep -q .; then
  echo "ERROR: missing non-empty proteinfold HTML report" >&2
  exit 1
fi

OUTPUT_COUNT="$(find "$OUTDIR" -type f -size +0 | wc -l)"
if [ "$OUTPUT_COUNT" -lt 10 ]; then
  echo "ERROR: too few non-empty outputs for proteinfold baseline: $OUTPUT_COUNT" >&2
  exit 1
fi

echo "nf-core/proteinfold single-node native Nextflow baseline completed with $OUTPUT_COUNT non-empty output files"
