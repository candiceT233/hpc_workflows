#!/bin/bash
#SBATCH --job-name=scrnaseq-single
#SBATCH --exclusive
#SBATCH --partition=compute
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/nf-core_scrnaseq/slurm-%j-single.out
#SBATCH --error=runs/nf-core_scrnaseq/slurm-%j-single.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

REPO="$ROOT/repos/nf-core_scrnaseq"
DATA_DIR="$ROOT/data/nf-core_scrnaseq/full_10x_pbmc10k"
FASTQ_DIR="$DATA_DIR/fastq"
FASTQS_TAR="$DATA_DIR/sc5p_v2_hs_PBMC_10k_fastqs.tar"
FASTQS_URL="https://s3-us-west-2.amazonaws.com/10x.files/samples/cell-vdj/4.0.0/sc5p_v2_hs_PBMC_10k/sc5p_v2_hs_PBMC_10k_fastqs.tar"
LOCAL_INPUT="$DATA_DIR/samplesheet_10x_pbmc10k_local.csv"
REF_ROOT="$DATA_DIR/reference"
STAR_INDEX_DIR="$REF_ROOT/STARIndex"
OUTDIR="$ROOT/runs/nf-core_scrnaseq/single-${SLURM_JOB_ID:-manual}/results"
WORKDIR="$ROOT/runs/nf-core_scrnaseq/single-${SLURM_JOB_ID:-manual}/work"
RUN_DIR="$(dirname "$OUTDIR")"
NF_ENV="$ROOT/tools/conda-envs/nextflow"
MINIFORGE="$ROOT/tools/miniforge"

mkdir -p "$ROOT/runs/nf-core_scrnaseq" "$RUN_DIR" "$OUTDIR" "$WORKDIR" "$ROOT/tools/nextflow-home"

TMP_ROOT="$WORKDIR/tmp"
PKGS_ROOT="$RUN_DIR/conda-pkgs"
mkdir -p "$TMP_ROOT" "$PKGS_ROOT" "$RUN_DIR/nextflow-conda-cache"
export TMPDIR="$TMP_ROOT"
export NXF_TEMP="$TMP_ROOT"
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

cat > "$RUN_DIR/scrnaseq_ares_override.config" <<EOF
conda {
  enabled = true
  useMamba = true
  cacheDir = "$RUN_DIR/nextflow-conda-cache"
  createTimeout = '90 min'
}
process {
  maxForks = 4
  resourceLimits = [
    cpus: 40,
    memory: '45.GB',
    time: '48.h'
  ]
  withName: /.*STAR_ALIGN.*/ {
    cpus = 12
    memory = '45.GB'
    time = '24.h'
  }
}
EOF

copy_tree_reflink_or_hardlink() {
  local src="$1"
  local dst="$2"
  mkdir -p "$dst"
  cp -al "$src"/. "$dst"/ 2>/dev/null || cp -a --reflink=auto "$src"/. "$dst"/
}

ensure_scrnaseq_inputs() {
  mkdir -p "$STAR_INDEX_DIR" "$FASTQ_DIR"
  if [ ! -s "$STAR_INDEX_DIR/SA" ]; then
    local src
    src="$(find "$ROOT/runs/nf-core_scrnaseq" -path '*/STARIndex/SA' -size +20000000000c -printf '%h\n' 2>/dev/null | head -n 1 || true)"
    if [ -z "$src" ]; then
      echo "ERROR: no complete staged STARIndex found for nf-core/scrnaseq" >&2
      exit 1
    fi
    copy_tree_reflink_or_hardlink "$src" "$STAR_INDEX_DIR"
  fi
  for required in SA Genome SAindex genome.fa genes.gtf transcriptInfo.tab sjdbInfo.txt; do
    if [ ! -s "$STAR_INDEX_DIR/$required" ]; then
      echo "ERROR: incomplete STARIndex, missing $STAR_INDEX_DIR/$required" >&2
      exit 1
    fi
  done
  if [ ! -s "$FASTQS_TAR" ]; then
    curl -L --fail --retry 3 --retry-delay 20 -o "$FASTQS_TAR.part" "$FASTQS_URL"
    mv "$FASTQS_TAR.part" "$FASTQS_TAR"
  fi
  if [ ! -f "$FASTQ_DIR/.10x_pbmc10k_extracted" ]; then
    tar -xf "$FASTQS_TAR" -C "$FASTQ_DIR"
    touch "$FASTQ_DIR/.10x_pbmc10k_extracted"
  fi
  python3 - "$LOCAL_INPUT" "$FASTQ_DIR" <<'PY'
import csv
import sys
from pathlib import Path

dst_csv, fastq_dir = Path(sys.argv[1]), Path(sys.argv[2])
r1s = sorted(fastq_dir.rglob("*_R1_001.fastq.gz"))
preferred = [p for p in r1s if "GEX" in p.name.upper()]
if preferred:
    r1s = preferred
else:
    r1s = [p for p in r1s if not any(token in str(p).lower() for token in ("vdj", "bcr", "tcr", "feature"))]
rows = []
for r1 in r1s:
    r2 = Path(str(r1).replace("_R1_001.fastq.gz", "_R2_001.fastq.gz"))
    if r2.exists() and r1.stat().st_size > 0 and r2.stat().st_size > 0:
        rows.append({"sample": "sc5p_v2_hs_PBMC_10k", "fastq_1": str(r1), "fastq_2": str(r2), "expected_cells": "10000"})
if not rows:
    raise SystemExit(f"no paired 10x GEX FASTQs found under {fastq_dir}")
with dst_csv.open("w", newline="") as handle:
    writer = csv.DictWriter(handle, fieldnames=["sample", "fastq_1", "fastq_2", "expected_cells"])
    writer.writeheader()
    writer.writerows(rows)
print(f"wrote {len(rows)} 10x PBMC10k FASTQ rows to {dst_csv}")
PY
}

export JAVA_HOME="$NF_ENV"
export JAVA_CMD="$NF_ENV/bin/java"
export NXF_HOME="$ROOT/tools/nextflow-home"
export NXF_OFFLINE=true
export NXF_VER="25.04.8"
export NXF_OPTS="-Xms1g -Xmx8g"
export NXF_SYNTAX_PARSER=v1
export PATH="$NF_ENV/bin:$MINIFORGE/bin:$MINIFORGE/condabin:$PATH"

ensure_scrnaseq_inputs

cd "$(dirname "$OUTDIR")"
nextflow run "$REPO" \
  -name "scrnaseq_single_${SLURM_JOB_ID:-manual}" \
  -profile conda \
  -c "$ROOT/config/nextflow_ares_local_conda.config" \
  -c "$RUN_DIR/scrnaseq_ares_override.config" \
  -work-dir "$WORKDIR" \
  --input "$LOCAL_INPUT" \
  --aligner star \
  --protocol 10XV2 \
  --star_index "$STAR_INDEX_DIR" \
  --fasta "$STAR_INDEX_DIR/genome.fa" \
  --gtf "$STAR_INDEX_DIR/genes.gtf" \
  --igenomes_ignore true \
  --outdir "$OUTDIR"

if ! find "$OUTDIR/pipeline_info" -maxdepth 1 -type f -name 'execution_trace*' -size +0 | grep -q .; then
  echo "ERROR: missing Nextflow execution trace in $OUTDIR/pipeline_info" >&2
  exit 1
fi

if ! find "$OUTDIR/multiqc" -type f -name 'multiqc_report.html' -size +100000 | grep -q .; then
  echo "ERROR: missing non-trivial MultiQC report" >&2
  exit 1
fi

if ! find "$OUTDIR" -type f \( -name '*.bam' -o -name '*.bai' \) -size +0 | grep -q .; then
  echo "ERROR: missing non-empty STARsolo BAM outputs" >&2
  exit 1
fi

if ! find "$OUTDIR" -type f \( -name '*.mtx' -o -name '*.mtx.gz' -o -name '*.h5' -o -name '*.h5ad' -o -name '*.rds' \) -size +0 | grep -q .; then
  echo "ERROR: missing non-empty single-cell matrix outputs" >&2
  exit 1
fi

OUTPUT_COUNT="$(find "$OUTDIR" -type f -size +0 | wc -l)"
if [ "$OUTPUT_COUNT" -lt 80 ]; then
  echo "ERROR: too few non-empty outputs for full scrnaseq baseline: $OUTPUT_COUNT" >&2
  exit 1
fi

echo "nf-core/scrnaseq single-node native Nextflow baseline completed with $OUTPUT_COUNT non-empty output files"
