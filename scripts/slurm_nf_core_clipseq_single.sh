#!/bin/bash
#SBATCH --job-name=clipseq-single
#SBATCH --exclusive
#SBATCH --partition=compute
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/nf-core_clipseq/slurm-%j-single.out
#SBATCH --error=runs/nf-core_clipseq/slurm-%j-single.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
REPO="$ROOT/repos/nf-core_clipseq"
RUN_DIR="$ROOT/runs/nf-core_clipseq/single-${SLURM_JOB_ID:-manual}"
OUTDIR_FINAL="$RUN_DIR/results"
NODE_RUN_DIR="$RUN_DIR/node-run"
NODE_REPO="$NODE_RUN_DIR/repo"
OUTDIR="$NODE_RUN_DIR/results"
WORKDIR="$NODE_RUN_DIR/work"
INPUT="$ROOT/data/nf-core_clipseq/full/metadata_full_https.csv"
FASTQ_DIR="$ROOT/data/nf-core_clipseq/full/fastq"
LOCAL_INPUT="$ROOT/data/nf-core_clipseq/full/metadata_full_local.csv"
REF_DIR="$ROOT/data/nf-core_clipseq/full/reference"
FASTA="$REF_DIR/GRCh38.primary_assembly.genome.fa.gz"
GTF="$REF_DIR/gencode.v37.primary_assembly.annotation.gtf.gz"
NF_ENV="$ROOT/tools/conda-envs/nextflow"
MINIFORGE="$ROOT/tools/miniforge"

mkdir -p "$ROOT/runs/nf-core_clipseq" "$RUN_DIR" "$OUTDIR" "$WORKDIR" "$NODE_REPO" "$ROOT/tools/nextflow-home" "$FASTQ_DIR"
cp -a "$REPO/." "$NODE_REPO/"
mkdir -p "$REF_DIR"

TMP_ROOT="$WORKDIR/tmp"
PKGS_ROOT="$RUN_DIR/conda-pkgs"
mkdir -p "$TMP_ROOT" "$PKGS_ROOT" "$RUN_DIR/nextflow-conda-cache"
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
export CONDA_PKGS_DIRS="$PKGS_ROOT"
export _JAVA_OPTIONS="${_JAVA_OPTIONS:-} -Djava.io.tmpdir=$TMP_ROOT"
export MAMBA_YES=true
export MAMBA_ALWAYS_YES=true
export CONDA_ALWAYS_YES=true
cat > "$RUN_DIR/condarc" <<'EOF'
always_yes: true
auto_activate_base: false
channel_priority: flexible
channels:
  - conda-forge
  - bioconda
  - defaults
EOF
export CONDARC="$RUN_DIR/condarc"

if [ ! -s "$INPUT" ]; then
  echo "ERROR: missing full CLIP-seq metadata: $INPUT" >&2
  exit 1
fi

python3 "$ROOT/scripts/localize_url_table.py" \
  --input "$INPUT" \
  --output "$LOCAL_INPUT" \
  --dest-dir "$FASTQ_DIR" \
  --columns fastq

if [ ! -s "$FASTA" ]; then
  if [ -s "$ROOT/data/nf-core_dualrnaseq/full/reference/GRCh38.primary_assembly.genome.fa.gz" ]; then
    ln -sf "$ROOT/data/nf-core_dualrnaseq/full/reference/GRCh38.primary_assembly.genome.fa.gz" "$FASTA"
  else
    curl -L --fail --retry 5 --retry-delay 10 --continue-at - \
      -o "$FASTA" \
      "https://ftp.ebi.ac.uk/pub/databases/gencode/Gencode_human/release_37/GRCh38.primary_assembly.genome.fa.gz"
  fi
fi
gzip -t "$FASTA"

if [ ! -s "$GTF" ]; then
  curl -L --fail --retry 5 --retry-delay 10 --continue-at - \
    -o "$GTF" \
    "https://ftp.ebi.ac.uk/pub/databases/gencode/Gencode_human/release_37/gencode.v37.primary_assembly.annotation.gtf.gz"
fi
gzip -t "$GTF"

export JAVA_HOME="$NF_ENV"
export JAVA_CMD="$NF_ENV/bin/java"
export NXF_VER=22.10.8
export NXF_HOME="$ROOT/tools/nextflow-home"
export NXF_OFFLINE=true
export NXF_OPTS="-Xms1g -Xmx8g"
export PATH="$RUN_DIR/podman-bin:$NF_ENV/bin:$MINIFORGE/bin:$MINIFORGE/condabin:$PATH"

cd "$NODE_RUN_DIR"
nextflow run "$NODE_REPO" \
  -profile podman \
  -c "$ROOT/config/nextflow_ares_local_podman.config" \
  -work-dir "$WORKDIR" \
  --input "$LOCAL_INPUT" \
  --smrna_org human \
  --fasta "$FASTA" \
  --gtf "$GTF" \
  --move_umi "NNNNNNNNN" \
  --umi_separator "_" \
  --peakcaller "icount,paraclu,pureclip,piranha" \
  --pureclip_iv "chr1;chr2" \
  --motif true \
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

OUTPUT_COUNT="$(find "$OUTDIR" -type f -size +0 | wc -l)"
if [ "$OUTPUT_COUNT" -lt 20 ]; then
  echo "ERROR: too few non-empty outputs for full clipseq baseline: $OUTPUT_COUNT" >&2
  exit 1
fi

echo "nf-core/clipseq single-node native Nextflow baseline completed with $OUTPUT_COUNT non-empty output files"
