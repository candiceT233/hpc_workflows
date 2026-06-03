#!/usr/bin/env bash
#SBATCH --job-name=viralrecon-prof
#SBATCH --exclusive
#SBATCH --partition=compute
#SBATCH --nodes=4
#SBATCH --ntasks=4
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/nf-core_viralrecon/slurm-%j-4node-profiled.out
#SBATCH --error=runs/nf-core_viralrecon/slurm-%j-4node-profiled.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

REPO="$ROOT/repos/nf-core_viralrecon"
INPUT_SOURCE="$ROOT/data/nf-core_viralrecon/full_articv3_sra/samplesheet_articv3_sra_https.csv"
RUN_ROOT="$ROOT/runs/nf-core_viralrecon"
RUN_DIR="$RUN_ROOT/4node-profiled-${SLURM_JOB_ID:-manual}"
INPUT="$RUN_DIR/samplesheet_full_amplicon_illumina_local.csv"
NF_ENV="$ROOT/tools/conda-envs/nextflow"
MINIFORGE="$ROOT/tools/miniforge"
CACHE_ROOT="$ROOT/tools/nextflow-conda-cache/nf-core_viralrecon"
source "$ROOT/scripts/viralrecon_reference_helpers.sh"
DATALIFE_LIB="$ROOT/tools/widget-v1/profiler/datalife/build/flow-monitor/src/libmonitor.so"
DARSHAN_RUNTIME="${DARSHAN_RUNTIME:-$(spack location -i darshan-runtime@3.4.6)}"
DARSHAN_UTIL="${DARSHAN_UTIL:-$(spack location -i darshan-util@3.4.6)}"
DARSHAN_LIB="$DARSHAN_RUNTIME/lib/libdarshan.so.0.0.0"
DARSHAN_PARSER="$DARSHAN_UTIL/bin/darshan-parser"

for required in "$INPUT_SOURCE" "$NF_ENV/bin/nextflow" "$DATALIFE_LIB" "$DARSHAN_LIB" "$DARSHAN_PARSER" "$ROOT/scripts/profile_tree_io.py"; do
  if [ ! -s "$required" ] && [ ! -x "$required" ]; then
    echo "ERROR: missing required nf-core/viralrecon profiling artifact: $required" >&2
    exit 1
  fi
done

mkdir -p "$RUN_ROOT" "$RUN_DIR" "$ROOT/tools/nextflow-home" "$CACHE_ROOT"
mkdir -p "$RUN_DIR"/{datalife,darshan,traces/datalife,traces/darshan,parsed}
mkdir -p "$(dirname "$INPUT_SOURCE")"
cat > "$INPUT_SOURCE" <<EOF
sample,fastq_1,fastq_2
SRR14313561,https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR143/061/SRR14313561/SRR14313561_1.fastq.gz,https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR143/061/SRR14313561/SRR14313561_2.fastq.gz
EOF
scontrol show hostnames "$SLURM_JOB_NODELIST" > "$RUN_DIR/hosts.txt"
cd "$ROOT"
python3 "$ROOT/scripts/localize_url_table.py" \
  --input "$INPUT_SOURCE" \
  --output "$INPUT" \
  --dest-dir "$ROOT/data/nf-core_viralrecon/full/fastq" \
  --columns fastq_1 fastq_2
prepare_viralrecon_references "$ROOT" "$RUN_DIR"

write_override() {
  local path="$1"
  cat > "$path" <<EOF
conda {
  enabled = true
  useMamba = true
  cacheDir = "$CACHE_ROOT"
  createTimeout = '90 min'
}

process {
  maxForks = 4
  withName: /.*BOWTIE2_BUILD.*/ {
    memory = 44.GB
  }
}
EOF
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
  if ! find "$outdir" -type f \( -name '*.sorted.bam' -o -name '*.vcf.gz' -o -name '*.consensus.fa' -o -name 'variants_long_table.csv' \) -size +0 | grep -q .; then
    echo "ERROR: $label missing non-empty variant/consensus outputs" >&2
    exit 1
  fi
  if ! find "$outdir/assembly" -type f \( -name '*.contigs.fa' -o -name '*.contigs.fa.gz' -o -name '*.scaffolds.fa.gz' -o -name '*.assembly.gfa.gz' \) -size +0 | grep -q .; then
    echo "ERROR: $label missing non-empty assembly outputs" >&2
    exit 1
  fi
  output_count="$(find "$outdir" -type f -size +0 | wc -l)"
  if [ "$output_count" -lt 150 ]; then
    echo "ERROR: $label too few non-empty viralrecon outputs: $output_count" >&2
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
  local trace_dir="$RUN_DIR/traces/$mode/replica-${replica}"
  local condarc="$rep_dir/condarc"
  local override="$rep_dir/viralrecon_ares_override.config"

  mkdir -p "$outdir" "$workdir" "$tmp_root" "$pkgs_root" "$trace_dir"
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
  write_override "$override"

  export JAVA_HOME="$NF_ENV" JAVA_CMD="$NF_ENV/bin/java" NXF_HOME="$ROOT/tools/nextflow-home"
  export NXF_OFFLINE=true
  export NXF_VER=25.04.8 NXF_OPTS="-Xms1g -Xmx8g" NXF_SYNTAX_PARSER=v1
  export PATH="$NF_ENV/bin:$MINIFORGE/bin:$MINIFORGE/condabin:$PATH"

  cd "$rep_dir"
  nextflow run "$REPO" \
    -name "viralrecon_${mode}_${SLURM_JOB_ID:-manual}_${replica}" \
    -profile conda \
    -c "$ROOT/config/nextflow_ares_local_conda.config" \
    -c "$VIRALRECON_GENOMES_CONFIG" \
    -c "$override" \
    -work-dir "$workdir" \
    --input "$INPUT" \
    --platform illumina \
    --protocol amplicon \
    --genome MN908947.3 \
    --primer_set artic \
    --primer_set_version 3 \
    --variant_caller ivar \
    --assemblers spades \
    --skip_kraken2 true \
    --skip_pangolin true \
    --skip_nextclade true \
    --skip_freyja true \
    --skip_snpeff true \
    --outdir "$outdir"

  output_count="$(validate_outputs "$outdir" "${mode} replica $replica")"
  find "$outdir" -type f -size +0 | sort > "$rep_dir/nonempty-outputs.txt"

  if [ "$mode" = "datalife" ]; then
    env DATALIFE_OUTPUT_PATH="$trace_dir" \
      DATALIFE_FILE_PATTERNS="*.fastq.gz,*.fq.gz,*.bam,*.bai,*.vcf.gz,*.fa,*.fasta,*.gfa.gz,*.csv,*.tsv,*.html,*.txt,*.log,*.png,*.gz" \
      LD_PRELOAD="$DATALIFE_LIB" \
      "$NF_ENV/bin/python" "$ROOT/scripts/profile_tree_io.py" \
        --root "$outdir" \
        --manifest "$rep_dir/profiled-output-digests.json" \
        --patterns '*.fastq.gz' '*.fq.gz' '*.bam' '*.bai' '*.vcf.gz' '*.fa' '*.fasta' '*.gfa.gz' '*.csv' '*.tsv' '*.html' '*.txt' '*.log' '*.png' '*.gz'
  elif [ "$mode" = "darshan" ]; then
    env DARSHAN_ENABLE_NONMPI=1 \
      DARSHAN_LOG_DIR_PATH="$trace_dir" \
      LD_PRELOAD="$DARSHAN_LIB" \
      "$NF_ENV/bin/python" "$ROOT/scripts/profile_tree_io.py" \
        --root "$outdir" \
        --manifest "$rep_dir/profiled-output-digests.json" \
        --patterns '*.fastq.gz' '*.fq.gz' '*.bam' '*.bai' '*.vcf.gz' '*.fa' '*.fasta' '*.gfa.gz' '*.csv' '*.tsv' '*.html' '*.txt' '*.log' '*.png' '*.gz'
  else
    echo "Unknown profile mode: $mode" >&2
    exit 2
  fi

  echo "nf-core/viralrecon ${mode} replica $replica native Nextflow workflow completed with $output_count non-empty output files"
}

if [ "${1:-}" = "worker" ]; then
  run_replica "$2" "$3"
  exit 0
fi

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
echo "nf-core/viralrecon native 4-node profiled Nextflow workflow completed across ${node_count} nodes"
