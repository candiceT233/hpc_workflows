#!/bin/bash
#SBATCH --job-name=airrflow-single
#SBATCH --exclusive
#SBATCH --partition=compute
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/nf-core_airrflow/slurm-%j-single.out
#SBATCH --error=runs/nf-core_airrflow/slurm-%j-single.err

set -euo pipefail
umask 000

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
REPO="$ROOT/repos/nf-core_airrflow"
DATA_DIR="$ROOT/data/nf-core_airrflow/full"
REAL_DATA_DIR="$ROOT/data/nf-core_airrflow/full_ena"
PRIMER_DIR="$DATA_DIR/primers"
DB_DIR="$DATA_DIR/database-cache"
RUN_DIR="$ROOT/runs/nf-core_airrflow/single-${SLURM_JOB_ID:-manual}"
OUTDIR_FINAL="$RUN_DIR/results"
NODE_RUN_DIR="$RUN_DIR/node-run"
NODE_REPO="$NODE_RUN_DIR/repo"
NODE_DATA="$NODE_RUN_DIR/data"
OUTDIR="$NODE_RUN_DIR/results"
WORKDIR="$NODE_RUN_DIR/work"
INPUT="$REAL_DATA_DIR/metadata_pcr_umi_airr_ena.tsv"
LOCAL_INPUT="$NODE_RUN_DIR/metadata_pcr_umi_airr_ena.tsv"
CPRIMERS="$PRIMER_DIR/cprimers.fasta"
LOCAL_CPRIMERS="$NODE_DATA/cprimers.fasta"
NF_ENV="$ROOT/tools/conda-envs/nextflow"
MINIFORGE="$ROOT/tools/miniforge"

mkdir -p "$ROOT/runs/nf-core_airrflow" "$RUN_DIR" "$OUTDIR" "$WORKDIR" "$NODE_REPO" "$ROOT/tools/nextflow-home" "$ROOT/tools/nextflow-conda-cache" "$PRIMER_DIR" "$DB_DIR" "$REAL_DATA_DIR"
chmod -R ugo+rwX "$NODE_RUN_DIR"
cp -a "$REPO/." "$NODE_REPO/"
chmod -R ugo+rwX "$NODE_RUN_DIR"

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

if [ ! -x "$NF_ENV/bin/nextflow" ]; then
  echo "ERROR: missing local Nextflow environment at $NF_ENV" >&2
  exit 1
fi

download_artifact() {
  local url="$1"
  local dest="$2"
  if [ ! -s "$dest" ]; then
    curl --fail --location --retry 8 --retry-delay 10 --retry-all-errors \
      --output "$dest.tmp" "$url"
    mv "$dest.tmp" "$dest"
  fi
}

cat > "$INPUT" <<EOF
sample_id	filename_R1	filename_R2	subject_id	species	pcr_target_locus	treatment	tissue	population	single_cell	sex	age	biomaterial_provider
SRR1383451	https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR138/001/SRR1383451/SRR1383451_1.fastq.gz	https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR138/001/SRR1383451/SRR1383451_2.fastq.gz	M4	human	IG	Lymph_node	Baseline	Bcell	FALSE	male	80	uni_tue
SRR1383452	https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR138/002/SRR1383452/SRR1383452_1.fastq.gz	https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR138/002/SRR1383452/SRR1383452_2.fastq.gz	M4	human	IG	Lymph_node	Baseline	Bcell	FALSE	male	80	uni_tue
SRR1383453	https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR138/003/SRR1383453/SRR1383453_1.fastq.gz	https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR138/003/SRR1383453/SRR1383453_2.fastq.gz	M4	human	IG	Lymph_node	Baseline	Bcell	FALSE	male	80	uni_tue
SRR1383456	https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR138/006/SRR1383456/SRR1383456_1.fastq.gz	https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR138/006/SRR1383456/SRR1383456_2.fastq.gz	M4	human	IG	Brain_lesion	Baseline	Bcell	FALSE	male	80	uni_tue
SRR1383463	https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR138/003/SRR1383463/SRR1383463_1.fastq.gz	https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR138/003/SRR1383463/SRR1383463_2.fastq.gz	M5	human	IG	Lymph_node	Baseline	Bcell	FALSE	female	63	uni_tue
SRR1383464	https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR138/004/SRR1383464/SRR1383464_1.fastq.gz	https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR138/004/SRR1383464/SRR1383464_2.fastq.gz	M5	human	IG	Lymph_node	Baseline	Bcell	FALSE	female	63	uni_tue
SRR1383465	https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR138/005/SRR1383465/SRR1383465_1.fastq.gz	https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR138/005/SRR1383465/SRR1383465_2.fastq.gz	M5	human	IG	Lymph_node	Baseline	Bcell	FALSE	female	63	uni_tue
SRR1383466	https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR138/006/SRR1383466/SRR1383466_1.fastq.gz	https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR138/006/SRR1383466/SRR1383466_2.fastq.gz	M5	human	IG	Brain_lesion	Baseline	Bcell	FALSE	female	63	uni_tue
SRR1383467	https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR138/007/SRR1383467/SRR1383467_1.fastq.gz	https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR138/007/SRR1383467/SRR1383467_2.fastq.gz	M5	human	IG	Brain_lesion	Baseline	Bcell	FALSE	female	63	uni_tue
SRR1383468	https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR138/008/SRR1383468/SRR1383468_1.fastq.gz	https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR138/008/SRR1383468/SRR1383468_2.fastq.gz	M5	human	IG	Brain_lesion	Baseline	Bcell	FALSE	female	63	uni_tue
EOF
download_artifact "https://raw.githubusercontent.com/immcantation/immcantation/refs/heads/master/protocols/Universal/Human_IG_CRegion_RC.fasta" "$CPRIMERS"

export JAVA_HOME="$NF_ENV"
export JAVA_CMD="$NF_ENV/bin/java"
export NXF_HOME="$ROOT/tools/nextflow-home"
export NXF_OFFLINE=true
export NXF_OPTS="-Xms1g -Xmx8g"
export NXF_SYNTAX_PARSER=v1
export PATH="$RUN_DIR/podman-bin:$NF_ENV/bin:$MINIFORGE/bin:$MINIFORGE/condabin:$PATH"

cp "$INPUT" "$LOCAL_INPUT"
mkdir -p "$NODE_DATA"
cp "$CPRIMERS" "$LOCAL_CPRIMERS"
chmod -R ugo+rwX "$NODE_DATA"

cd "$NODE_RUN_DIR"
nextflow run "$NODE_REPO" \
  -profile podman \
  -c "$ROOT/config/nextflow_ares_local_podman.config" \
  -work-dir "$WORKDIR" \
  --input "$LOCAL_INPUT" \
  --cprimers "$LOCAL_CPRIMERS" \
  --fetch_imgt true \
  --mode fastq \
  --library_generation_method dt_5p_race_umi \
  --race_linker AAGCAGTGGTATCAACGCAGAGTACATGGG \
  --cprimer_position R1 \
  --umi_length 15 \
  --umi_position R2 \
  --cluster_sets false \
  --lineage_trees true \
  --outdir "$OUTDIR"

mkdir -p "$OUTDIR_FINAL"
cp -a "$OUTDIR/." "$OUTDIR_FINAL/"
OUTDIR="$OUTDIR_FINAL"

if [ ! -s "$OUTDIR/pipeline_info/execution_trace.txt" ] && ! find "$OUTDIR/pipeline_info" -maxdepth 1 -type f -name 'execution_trace_*.txt' -size +0 | grep -q .; then
  echo "ERROR: missing Nextflow execution trace in $OUTDIR/pipeline_info" >&2
  exit 1
fi

if ! find "$OUTDIR" -type f -name '*multiqc*html' -size +100000 | grep -q .; then
  echo "ERROR: missing non-trivial MultiQC HTML output" >&2
  exit 1
fi

OUTPUT_COUNT="$(find "$OUTDIR" -type f -size +0 | wc -l)"
if [ "$OUTPUT_COUNT" -lt 20 ]; then
  echo "ERROR: too few non-empty outputs for full airrflow baseline: $OUTPUT_COUNT" >&2
  exit 1
fi

echo "nf-core/airrflow single-node native Nextflow baseline completed with $OUTPUT_COUNT non-empty output files"
