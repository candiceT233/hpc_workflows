#!/usr/bin/env bash
#SBATCH --job-name=eager-single
#SBATCH --exclusive
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/nf-core_eager/slurm-%j-single.out
#SBATCH --error=runs/nf-core_eager/slurm-%j-single.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
RUN_DIR="${ROOT}/runs/nf-core_eager/single-${SLURM_JOB_ID}"
WORK_DIR="${RUN_DIR}/work"
OUT_DIR="${RUN_DIR}/results"
TRACE_FILE="${RUN_DIR}/execution_trace.txt"
REPORT_FILE="${RUN_DIR}/execution_report.html"
TIMELINE_FILE="${RUN_DIR}/timeline.html"
INPUT_SOURCE="${ROOT}/data/nf-core_eager/full_ena/benchmarking_vikingfish_ena.tsv"
INPUT_TSV="${RUN_DIR}/benchmarking_vikingfish_local.tsv"
FASTA_URL="https://ftp.ncbi.nlm.nih.gov/genomes/all/GCF/902/167/405/GCF_902167405.1_gadMor3.0/GCF_902167405.1_gadMor3.0_genomic.fna.gz"
REF_DIR="${ROOT}/data/nf-core_eager/full_ena/reference"
FASTA_GZ="${REF_DIR}/GCF_902167405.1_gadMor3.0_genomic.fna.gz"
FASTA_LOCAL="${REF_DIR}/GCF_902167405.1_gadMor3.0_genomic.fna"

export JAVA_HOME="${ROOT}/tools/conda-envs/nextflow"
export JAVA_CMD="${ROOT}/tools/conda-envs/nextflow/bin/java"
export NXF_HOME="${ROOT}/tools/nextflow-home"
export NXF_OFFLINE=true
export NXF_VER=22.10.6
export PATH="${ROOT}/tools/conda-envs/nextflow/bin:${ROOT}/tools/miniforge/bin:${ROOT}/tools/miniforge/condabin:${PATH}"

mkdir -p "${RUN_DIR}" "${WORK_DIR}" "${OUT_DIR}" "${REF_DIR}"

TMP_ROOT="${WORK_DIR}/tmp"
mkdir -p "${TMP_ROOT}"
export TMPDIR="${TMP_ROOT}"
export NXF_TEMP="${TMP_ROOT}"
export CONDA_PKGS_DIRS="${RUN_DIR}/conda-pkgs"
export _JAVA_OPTIONS="${_JAVA_OPTIONS:-} -Djava.io.tmpdir=${TMP_ROOT}"
export MAMBA_YES=true
export MAMBA_ALWAYS_YES=true
export CONDA_ALWAYS_YES=true
mkdir -p "${CONDA_PKGS_DIRS}" "${RUN_DIR}/nextflow-conda-cache"
cat > "${RUN_DIR}/condarc" <<'EOF'
always_yes: true
auto_activate_base: false
channel_priority: flexible
channels:
  - conda-forge
  - bioconda
  - defaults
EOF
export CONDARC="${RUN_DIR}/condarc"
cat > "${RUN_DIR}/eager_ares_override.config" <<EOF
conda {
  enabled = true
  useMamba = true
  cacheDir = "${ROOT}/tools/nextflow-conda-cache/nf-core_eager"
}
params {
  bwaalnn = 0.04
  bwaalnl = 1024
  run_bam_filtering = true
  bam_unmapped_type = 'discard'
  bam_mapping_quality_threshold = 25
  run_genotyping = true
  genotyping_tool = 'hc'
  genotyping_source = 'raw'
  gatk_ploidy = 2
  schema_ignore_params = 'genomes,input_paths,input'
}
EOF
cd "${ROOT}"
python3 "${ROOT}/scripts/localize_url_table.py" \
    --input "${INPUT_SOURCE}" \
    --output "${INPUT_TSV}" \
    --dest-dir "${ROOT}/data/nf-core_eager/full_ena/fastq" \
    --columns R1 R2 \
    --delimiter tab

if [[ ! -s "${FASTA_LOCAL}" ]]; then
    if [[ ! -s "${FASTA_GZ}" ]]; then
        curl -L --retry 5 --retry-delay 10 -o "${FASTA_GZ}.tmp" "${FASTA_URL}"
        mv "${FASTA_GZ}.tmp" "${FASTA_GZ}"
    fi
    gzip -dc "${FASTA_GZ}" > "${FASTA_LOCAL}.tmp"
    mv "${FASTA_LOCAL}.tmp" "${FASTA_LOCAL}"
fi

cd "${RUN_DIR}"
nextflow run "${ROOT}/repos/nf-core_eager" \
    -profile conda \
    -c "${ROOT}/config/nextflow_ares_local_conda.config" \
    -c "${RUN_DIR}/eager_ares_override.config" \
    -name "eager_single_${SLURM_JOB_ID}" \
    -w "${WORK_DIR}" \
    -with-trace "${TRACE_FILE}" \
    -with-report "${REPORT_FILE}" \
    -with-timeline "${TIMELINE_FILE}" \
    --input "${INPUT_TSV}" \
    --fasta "${FASTA_LOCAL}" \
    --outdir "${OUT_DIR}"

test -s "${TRACE_FILE}"
test -s "${REPORT_FILE}"
test -s "${TIMELINE_FILE}"
test -s "${OUT_DIR}/multiqc"/*multiqc_report.html

nonempty=$(find "${OUT_DIR}" -type f -size +0c | wc -l)
if (( nonempty < 50 )); then
    echo "Too few non-empty nf-core/eager outputs: ${nonempty}" >&2
    exit 3
fi

for expected_dir in FastQC AdapterRemoval Mapping MultiQC; do
    if [[ ! -d "${OUT_DIR}/${expected_dir}" && ! -d "${OUT_DIR}/${expected_dir,,}" ]]; then
        echo "Expected nf-core/eager output directory not found: ${expected_dir}" >&2
        find "${OUT_DIR}" -maxdepth 2 -type d | sort >&2
        exit 4
    fi
done

echo "nf-core/eager native Nextflow single-node baseline completed with ${nonempty} non-empty output files."
