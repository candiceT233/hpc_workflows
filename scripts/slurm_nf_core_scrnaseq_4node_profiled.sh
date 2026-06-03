#!/usr/bin/env bash
#SBATCH --job-name=scrna-prof
#SBATCH --exclusive
#SBATCH --partition=compute
#SBATCH --nodes=4
#SBATCH --ntasks=4
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/nf-core_scrnaseq/slurm-%j-4node-profiled.out
#SBATCH --error=runs/nf-core_scrnaseq/slurm-%j-4node-profiled.err

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
RUN_ROOT="$ROOT/runs/nf-core_scrnaseq"
RUN_DIR="$RUN_ROOT/4node-profiled-${SLURM_JOB_ID:-manual}"
NF_ENV="$ROOT/tools/conda-envs/nextflow"
MINIFORGE="$ROOT/tools/miniforge"
DATALIFE_LIB="$ROOT/tools/widget-v1/profiler/datalife/build/flow-monitor/src/libmonitor.so"
DARSHAN_RUNTIME="${DARSHAN_RUNTIME:-$(spack location -i darshan-runtime@3.4.6)}"
DARSHAN_UTIL="${DARSHAN_UTIL:-$(spack location -i darshan-util@3.4.6)}"
DARSHAN_LIB="$DARSHAN_RUNTIME/lib/libdarshan.so.0.0.0"
DARSHAN_PARSER="$DARSHAN_UTIL/bin/darshan-parser"

for required in "$NF_ENV/bin/nextflow" "$DATALIFE_LIB" "$DARSHAN_LIB" "$DARSHAN_PARSER" "$ROOT/scripts/profile_tree_io.py"; do
  if [ ! -s "$required" ] && [ ! -x "$required" ]; then
    echo "ERROR: missing required nf-core/scrnaseq profiling artifact: $required" >&2
    exit 1
  fi
done

mkdir -p "$RUN_ROOT" "$RUN_DIR" "$ROOT/tools/nextflow-home"
mkdir -p "$RUN_DIR"/{datalife,darshan,traces/datalife,traces/darshan,parsed}
scontrol show hostnames "$SLURM_JOB_NODELIST" > "$RUN_DIR/hosts.txt"
cd "$ROOT"

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
  if ! find "$outdir" -type f \( -name '*.bam' -o -name '*.bai' \) -size +0 | grep -q .; then
    echo "ERROR: $label missing non-empty STARsolo BAM outputs" >&2
    exit 1
  fi
  if ! find "$outdir" -type f \( -name '*.mtx' -o -name '*.mtx.gz' -o -name '*.h5' -o -name '*.h5ad' -o -name '*.rds' \) -size +0 | grep -q .; then
    echo "ERROR: $label missing non-empty single-cell matrix outputs" >&2
    exit 1
  fi
  output_count="$(find "$outdir" -type f -size +0 | wc -l)"
  if [ "$output_count" -lt 80 ]; then
    echo "ERROR: $label too few non-empty scrnaseq outputs: $output_count" >&2
    exit 1
  fi
  echo "$output_count"
}

run_replica() {
  local mode="$1"
  local replica="$2"
  local rep_dir="$RUN_DIR/$mode/replica-${replica}"
  local outdir="$rep_dir/results"
  local workdir="$rep_dir/work"
  local tmp_root="$workdir/tmp"
  local pkgs_root="$rep_dir/conda-pkgs"
  local cache_root="$rep_dir/nextflow-conda-cache"
  local trace_dir="$RUN_DIR/traces/$mode/replica-${replica}"
  local condarc="$rep_dir/condarc"
  local override="$rep_dir/scrnaseq_ares_override.config"

  mkdir -p "$outdir" "$workdir" "$tmp_root" "$pkgs_root" "$cache_root" "$trace_dir"
  export TMPDIR="$tmp_root" NXF_TEMP="$tmp_root" CONDA_PKGS_DIRS="$pkgs_root"
  export _JAVA_OPTIONS="${_JAVA_OPTIONS:-} -Djava.io.tmpdir=$tmp_root"
  export MAMBA_YES=true MAMBA_ALWAYS_YES=true CONDA_ALWAYS_YES=true
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
conda {
  enabled = true
  useMamba = true
  cacheDir = "$cache_root"
  createTimeout = '90 min'
}
EOF

  export JAVA_HOME="$NF_ENV" JAVA_CMD="$NF_ENV/bin/java" NXF_HOME="$ROOT/tools/nextflow-home"
  export NXF_OFFLINE=true
  export NXF_VER=25.04.8 NXF_OPTS="-Xms1g -Xmx8g" NXF_SYNTAX_PARSER=v1
  export PATH="$NF_ENV/bin:$MINIFORGE/bin:$MINIFORGE/condabin:$PATH"

  cd "$rep_dir"
  nextflow run "$REPO" \
    -name "scrnaseq_${mode}_${SLURM_JOB_ID:-manual}_${replica}" \
    -profile conda \
    -c "$ROOT/config/nextflow_ares_local_conda.config" \
    -c "$override" \
    -work-dir "$workdir" \
    --input "$LOCAL_INPUT" \
    --aligner star \
    --protocol 10XV2 \
    --star_index "$STAR_INDEX_DIR" \
    --fasta "$STAR_INDEX_DIR/genome.fa" \
    --gtf "$STAR_INDEX_DIR/genes.gtf" \
    --igenomes_ignore true \
    --outdir "$outdir"

  output_count="$(validate_outputs "$outdir" "${mode} replica $replica")"
  find "$outdir" -type f -size +0 | sort > "$rep_dir/nonempty-outputs.txt"

  if [ "$mode" = "datalife" ]; then
    env DATALIFE_OUTPUT_PATH="$trace_dir" \
      DATALIFE_FILE_PATTERNS="*.fastq.gz,*.fq.gz,*.bam,*.bai,*.mtx,*.mtx.gz,*.h5,*.h5ad,*.rds,*.tsv,*.csv,*.txt,*.html,*.log,*.pdf,*.png,*.gz" \
      LD_PRELOAD="$DATALIFE_LIB" \
      "$NF_ENV/bin/python" "$ROOT/scripts/profile_tree_io.py" \
        --root "$outdir" \
        --manifest "$rep_dir/profiled-output-digests.json" \
        --patterns '*.fastq.gz' '*.fq.gz' '*.bam' '*.bai' '*.mtx' '*.mtx.gz' '*.h5' '*.h5ad' '*.rds' '*.tsv' '*.csv' '*.txt' '*.html' '*.log' '*.pdf' '*.png' '*.gz'
  elif [ "$mode" = "darshan" ]; then
    env DARSHAN_ENABLE_NONMPI=1 \
      DARSHAN_LOG_DIR_PATH="$trace_dir" \
      LD_PRELOAD="$DARSHAN_LIB" \
      "$NF_ENV/bin/python" "$ROOT/scripts/profile_tree_io.py" \
        --root "$outdir" \
        --manifest "$rep_dir/profiled-output-digests.json" \
        --patterns '*.fastq.gz' '*.fq.gz' '*.bam' '*.bai' '*.mtx' '*.mtx.gz' '*.h5' '*.h5ad' '*.rds' '*.tsv' '*.csv' '*.txt' '*.html' '*.log' '*.pdf' '*.png' '*.gz'
  else
    echo "Unknown profile mode: $mode" >&2
    exit 2
  fi

  echo "nf-core/scrnaseq ${mode} replica $replica native Nextflow workflow completed with $output_count non-empty output files"
}

if [ "${1:-}" = "worker" ]; then
  run_replica "$2" "$3"
  exit 0
fi

ensure_scrnaseq_inputs

for mode in datalife darshan; do
  for replica in 0 1 2 3; do
    srun --exclusive --nodes=1 --ntasks=1 --cpus-per-task="${SLURM_CPUS_PER_TASK:-40}" \
      "$0" worker "$mode" "$replica" > "$RUN_DIR/${mode}-replica-${replica}.out" 2> "$RUN_DIR/${mode}-replica-${replica}.err" &
  done
  wait
  find "$RUN_DIR/$mode" -path '*/nonempty-outputs.txt' -type f -size +0c | sort > "$RUN_DIR/${mode}-output-manifests.txt"
  manifest_count="$(wc -l < "$RUN_DIR/${mode}-output-manifests.txt")"
  if [ "$manifest_count" -ne 4 ]; then
    echo "ERROR: expected 4 ${mode} output manifests, found $manifest_count" >&2
    exit 3
  fi
done

python3 - "$RUN_DIR/traces/datalife" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
files = sorted(root.rglob("*.json"))
if not files:
    raise SystemExit("no DataLife JSON traces found")
for path in files:
    if path.stat().st_size == 0:
        raise SystemExit(f"empty DataLife JSON trace: {path}")
    with path.open() as handle:
        json.load(handle)
print(f"DataLife JSON traces parsed: {len(files)}")
PY

darshan_count=0
while IFS= read -r -d '' log_path; do
  rel="${log_path#$RUN_DIR/traces/darshan/}"
  parsed="$RUN_DIR/parsed/${rel}.txt"
  mkdir -p "$(dirname "$parsed")"
  "$DARSHAN_PARSER" "$log_path" > "$parsed"
  if [ ! -s "$parsed" ]; then
    echo "Parsed Darshan output is empty: $parsed" >&2
    exit 4
  fi
  darshan_count=$((darshan_count + 1))
done < <(find "$RUN_DIR/traces/darshan" -name '*.darshan' -type f -size +0c -print0)

if [ "$darshan_count" -eq 0 ]; then
  echo "No non-empty Darshan logs found" >&2
  exit 5
fi

printf 'Darshan logs parsed: %s\n' "$darshan_count"
find "$RUN_DIR/traces" -type f -printf '%P\t%s\n' | sort > "$RUN_DIR/trace-summary.tsv"
node_count="$(wc -l < "$RUN_DIR/hosts.txt")"
echo "nf-core/scrnaseq native 4-node profiled Nextflow workflow completed across ${node_count} nodes"
