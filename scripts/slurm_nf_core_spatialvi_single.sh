#!/bin/bash
#SBATCH --job-name=spatialvi-single
#SBATCH --exclusive
#SBATCH --partition=compute
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/nf-core_spatialvi/slurm-%j-single.out
#SBATCH --error=runs/nf-core_spatialvi/slurm-%j-single.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

REPO="$ROOT/repos/nf-core_spatialvi"
DATA_DIR="$ROOT/data/nf-core_spatialvi/full"
INPUT="$DATA_DIR/visium_ovarian_full_samplesheet_local.csv"
RUN_DIR="$ROOT/runs/nf-core_spatialvi/single-${SLURM_JOB_ID:-manual}"
OUTDIR_FINAL="$RUN_DIR/results"
NODE_RUN_DIR="$RUN_DIR/node-run"
NODE_REPO="$NODE_RUN_DIR/repo"
OUTDIR="$NODE_RUN_DIR/results"
WORKDIR="$NODE_RUN_DIR/work"
NF_ENV="$ROOT/tools/conda-envs/nextflow"
REFERENCE="$DATA_DIR/refdata-gex-GRCh38-2020-A.tar.gz"
FASTQS_TAR="$DATA_DIR/Visium_FFPE_Human_Ovarian_Cancer_fastqs.tar"
IMAGE="$DATA_DIR/Visium_FFPE_Human_Ovarian_Cancer_image.jpg"
SLIDEFILE="$DATA_DIR/V10L13-020.gpr"

mkdir -p "$ROOT/runs/nf-core_spatialvi" "$RUN_DIR" "$OUTDIR" "$WORKDIR" "$NODE_REPO" "$ROOT/tools/nextflow-home" "$ROOT/tools/nextflow-conda-cache" "$DATA_DIR"
cp -a "$REPO/." "$NODE_REPO/"

TMP_ROOT="$WORKDIR/tmp"
mkdir -p "$TMP_ROOT"
export TMPDIR="$TMP_ROOT"
export NXF_TEMP="$TMP_ROOT"
PODMAN_BASE="$RUN_DIR/podman-storage"
rm -rf "$PODMAN_BASE"
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
export NXF_VER="25.10.4"
export NXF_OPTS="-Xms1g -Xmx8g"
export NXF_SYNTAX_PARSER=v1
export NXF_OFFLINE=true
export PATH="$RUN_DIR/podman-bin:$NF_ENV/bin:$ROOT/tools/miniforge/bin:$ROOT/tools/miniforge/condabin:$PATH"

download_artifact() {
  local url="$1"
  local dest="$2"
  if [ ! -s "$dest" ]; then
    curl --fail --location --retry 8 --retry-delay 10 --retry-all-errors \
      --output "$dest.tmp" "$url"
    mv "$dest.tmp" "$dest"
  fi
}

download_artifact "https://cf.10xgenomics.com/samples/spatial-exp/1.3.0/Visium_FFPE_Human_Ovarian_Cancer/Visium_FFPE_Human_Ovarian_Cancer_fastqs.tar" "$FASTQS_TAR"
download_artifact "https://cf.10xgenomics.com/samples/spatial-exp/1.3.0/Visium_FFPE_Human_Ovarian_Cancer/Visium_FFPE_Human_Ovarian_Cancer_image.jpg" "$IMAGE"
download_artifact "https://s3.us-west-2.amazonaws.com/10x.spatial-slides/gpr/V10L13/V10L13-020.gpr" "$SLIDEFILE"
download_artifact "https://cf.10xgenomics.com/supp/spatial-exp/refdata-gex-GRCh38-2020-A.tar.gz" "$REFERENCE"

cat > "$INPUT" <<EOF
sample,fastq_dir,image,slide,area,manual_alignment,slidefile
Visium_FFPE_Human_Ovarian_Cancer,$FASTQS_TAR,$IMAGE,V10L13-020,D1,,$SLIDEFILE
EOF

OVERRIDE="$RUN_DIR/spatialvi_ares_override.config"
cat > "$OVERRIDE" <<'EOF'
process {
  resourceLimits = [ cpus: 40, memory: 45.GB, time: 48.h ]
  withLabel:process_high {
    cpus = 12
    memory = 45.GB
  }
  withLabel:process_spaceranger {
    cpus = 12
    memory = 45.GB
  }
}
EOF

cd "$NODE_RUN_DIR"
nextflow run "$NODE_REPO" \
  -profile podman \
  -c "$ROOT/config/nextflow_ares_local_podman.config" \
  -c "$OVERRIDE" \
  -work-dir "$WORKDIR" \
  --input "$INPUT" \
  --spaceranger_reference "$REFERENCE" \
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

if ! find "$OUTDIR" -type f \( -name '*.h5ad' -o -name '*.zarr' -o -name 'report-*.html' -o -name 'report-integrated.html' \) -size +0 | grep -q .; then
  echo "ERROR: missing non-empty downstream spatial analysis outputs" >&2
  exit 1
fi

OUTPUT_COUNT="$(find "$OUTDIR" -type f -size +0 | wc -l)"
if [ "$OUTPUT_COUNT" -lt 50 ]; then
  echo "ERROR: too few non-empty outputs for full spatialvi baseline: $OUTPUT_COUNT" >&2
  exit 1
fi

echo "nf-core/spatialvi single-node native Nextflow baseline completed with $OUTPUT_COUNT non-empty output files"
