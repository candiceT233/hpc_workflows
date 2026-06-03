#!/usr/bin/env bash
#SBATCH --job-name=vpipe-single
#SBATCH --exclusive
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/V-pipe/slurm-%j-single.out
#SBATCH --error=runs/V-pipe/slurm-%j-single.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
WORKFLOW="${ROOT}/repos/V-pipe/workflow/Snakefile"
RUN_DIR="${ROOT}/runs/V-pipe/single-${SLURM_JOB_ID}"
DATA_DIR="${ROOT}/data/V-pipe/full-hiv"
CONDA_PREFIX_DIR="${RUN_DIR}/snakemake-conda"
SNAKEMAKE="${ROOT}/tools/conda-envs/vpipe-snakemake/bin/snakemake"
VPIPE_CORES="${VPIPE_CORES:-8}"
VPIPE_MEM_MB="${VPIPE_MEM_MB:-43000}"

export PATH="${ROOT}/tools/miniforge/bin:${ROOT}/tools/miniforge/condabin:${PATH}"
export CONDA_PKGS_DIRS="${RUN_DIR}/conda-pkgs"
export CONDARC="${RUN_DIR}/condarc"

if [[ ! -x "${SNAKEMAKE}" ]]; then
    echo "Missing V-pipe Snakemake executable: ${SNAKEMAKE}" >&2
    exit 2
fi

mkdir -p "${RUN_DIR}" "${DATA_DIR}" "${CONDA_PKGS_DIRS}"
cat > "${CONDARC}" <<'EOF'
always_yes: true
auto_activate_base: false
channel_priority: strict
channels:
  - conda-forge
  - bioconda
  - defaults
EOF
cd "${RUN_DIR}"

"${ROOT}/repos/V-pipe/init_project.sh" -m -n

cat > config.yaml <<EOF
general:
    virus_base_config: ""
    aligner: bwa
    snv_caller: shorah
    haplotype_reconstruction: haploclique

input:
    reference: "${ROOT}/repos/V-pipe/resources/hiv/HXB2.fasta"
    metainfo_file: "${ROOT}/repos/V-pipe/resources/hiv/metainfo.yaml"
    gff_directory: "${ROOT}/repos/V-pipe/resources/hiv/gffs/"
    genes_gff: "${ROOT}/repos/V-pipe/resources/hiv/gffs/GCF_000864765.1_ViralProj15476_genomic.gff"
    datadir: samples/
    read_length: 301
    samples_file: samples.tsv
    paired: true

snv:
    consensus: false
    mem: 12000

haploclique:
    mem: 10000

output:
    datadir: results
    snv: true
    local: true
    global: true
    visualization: true
    QA: false
    diversity: true
EOF

cat > samples.tsv <<'EOF'
SRR9588785	full	301
SRR9588828	full	301
SRR9588829	full	301
SRR9588830	full	301
SRR9588844	full	301
EOF

fetch_fastq() {
    local acc=$1
    local read=$2
    local url=$3
    local dest_dir="${DATA_DIR}/${acc}/full/raw_data"
    local dest="${dest_dir}/${acc}_R${read}.fastq.gz"
    mkdir -p "${dest_dir}"
    if [[ -s "${dest}" ]] && gzip -t "${dest}"; then
        echo "Using existing ${dest}"
    else
        rm -f "${dest}"
        curl -L --fail --retry 5 --retry-all-errors -C - -o "${dest}" "${url}"
        gzip -t "${dest}"
    fi
    mkdir -p "samples/${acc}/full/raw_data"
    ln -sf "${dest}" "samples/${acc}/full/raw_data/${acc}_R${read}.fastq.gz"
}

fetch_fastq SRR9588785 1 https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR958/005/SRR9588785/SRR9588785_1.fastq.gz
fetch_fastq SRR9588785 2 https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR958/005/SRR9588785/SRR9588785_2.fastq.gz
fetch_fastq SRR9588828 1 https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR958/008/SRR9588828/SRR9588828_1.fastq.gz
fetch_fastq SRR9588828 2 https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR958/008/SRR9588828/SRR9588828_2.fastq.gz
fetch_fastq SRR9588829 1 https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR958/009/SRR9588829/SRR9588829_1.fastq.gz
fetch_fastq SRR9588829 2 https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR958/009/SRR9588829/SRR9588829_2.fastq.gz
fetch_fastq SRR9588830 1 https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR958/000/SRR9588830/SRR9588830_1.fastq.gz
fetch_fastq SRR9588830 2 https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR958/000/SRR9588830/SRR9588830_2.fastq.gz
fetch_fastq SRR9588844 1 https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR958/004/SRR9588844/SRR9588844_1.fastq.gz
fetch_fastq SRR9588844 2 https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR958/004/SRR9588844/SRR9588844_2.fastq.gz

mkdir -p "${CONDA_PREFIX_DIR}"
for prefix in "${CONDA_PREFIX_DIR}"/*; do
    [[ -d "${prefix}" ]] || continue
    if [[ ! -d "${prefix}/conda-meta" ]]; then
        echo "Removing incomplete V-pipe conda prefix: ${prefix}"
        rm -rf "${prefix}"
    fi
done

"${SNAKEMAKE}" \
    -s "${WORKFLOW}" \
    --use-conda \
    --conda-frontend conda \
    --conda-prefix "${CONDA_PREFIX_DIR}" \
    --cores "${VPIPE_CORES}" \
    --resources "mem_mb=${VPIPE_MEM_MB}" \
    --rerun-incomplete \
    --printshellcmds \
    --show-failed-logs \
    --latency-wait 120

for acc in SRR9588785 SRR9588828 SRR9588829 SRR9588830 SRR9588844; do
    test -s "results/${acc}/full/alignments/REF_aln.bam"
    test -s "results/${acc}/full/variants/SNVs/snvs.vcf"
    test -s "results/${acc}/full/variants/SNVs/snvs.csv"
    test -s "results/${acc}/full/visualization/alignment.html"
done
test -s results/aggregated_diversity.csv

nonempty=$(find results -type f -size +0c | wc -l)
if (( nonempty < 40 )); then
    echo "Too few non-empty V-pipe outputs: ${nonempty}" >&2
    exit 3
fi

echo "V-pipe native Snakemake single-node baseline completed with ${nonempty} non-empty result files."
