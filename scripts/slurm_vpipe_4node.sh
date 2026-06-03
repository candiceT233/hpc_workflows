#!/usr/bin/env bash
#SBATCH --job-name=vpipe-4node
#SBATCH --exclusive
#SBATCH --nodes=4
#SBATCH --ntasks=4
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=40
#SBATCH --time=2-00:00:00
#SBATCH --output=runs/V-pipe/slurm-%j-4node.out
#SBATCH --error=runs/V-pipe/slurm-%j-4node.err

set -euo pipefail

if [ -n "${WORKFLOW_ROOT:-}" ]; then
  ROOT="$WORKFLOW_ROOT"
elif [ -f "$PWD/table.md" ] && [ -d "$PWD/scripts" ]; then
  ROOT="$PWD"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

WORKFLOW="${ROOT}/repos/V-pipe/workflow/Snakefile"
DATA_DIR="${ROOT}/data/V-pipe/full-hiv"
RUN_ROOT="${RUN_ROOT:-${ROOT}/runs/V-pipe}"
RUN_DIR="${RUN_ROOT}/4node-${SLURM_JOB_ID:-manual}"
SNAKEMAKE="${ROOT}/tools/conda-envs/vpipe-snakemake/bin/snakemake"
MINIFORGE="${ROOT}/tools/miniforge"
VPIPE_CORES="${VPIPE_CORES:-8}"
VPIPE_MEM_MB="${VPIPE_MEM_MB:-43000}"

mkdir -p "$RUN_ROOT" "$RUN_DIR" "$DATA_DIR"
if [[ ! -x "${SNAKEMAKE}" ]]; then
  echo "Missing V-pipe Snakemake executable: ${SNAKEMAKE}" >&2
  exit 2
fi

fetch_fastq() {
  local acc=$1
  local read=$2
  local url=$3
  local dest_dir="${DATA_DIR}/${acc}/full/raw_data"
  local dest="${dest_dir}/${acc}_R${read}.fastq.gz"
  mkdir -p "${dest_dir}"
  if [[ -s "${dest}" ]] && gzip -t "${dest}" >/dev/null 2>&1; then
    return 0
  fi
  curl -L --fail --retry 8 --retry-all-errors -C - -o "${dest}.part" "${url}"
  gzip -t "${dest}.part"
  mv "${dest}.part" "${dest}"
}

prepare_inputs() {
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
}

write_project() {
  local rep_dir="$1"
  cd "$rep_dir"
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
  for acc in SRR9588785 SRR9588828 SRR9588829 SRR9588830 SRR9588844; do
    mkdir -p "samples/${acc}/full/raw_data"
    ln -sf "${DATA_DIR}/${acc}/full/raw_data/${acc}_R1.fastq.gz" "samples/${acc}/full/raw_data/${acc}_R1.fastq.gz"
    ln -sf "${DATA_DIR}/${acc}/full/raw_data/${acc}_R2.fastq.gz" "samples/${acc}/full/raw_data/${acc}_R2.fastq.gz"
  done
}

validate_outputs() {
  local rep_dir="$1"
  local label="$2"
  cd "$rep_dir"
  for acc in SRR9588785 SRR9588828 SRR9588829 SRR9588830 SRR9588844; do
    test -s "results/${acc}/full/alignments/REF_aln.bam"
    test -s "results/${acc}/full/variants/SNVs/snvs.vcf"
    test -s "results/${acc}/full/variants/SNVs/snvs.csv"
    test -s "results/${acc}/full/visualization/alignment.html"
  done
  test -s results/aggregated_diversity.csv
  local nonempty
  nonempty=$(find results -type f -size +0c | wc -l)
  if (( nonempty < 40 )); then
    echo "Too few non-empty V-pipe outputs for ${label}: ${nonempty}" >&2
    exit 3
  fi
  echo "$nonempty"
}

run_replica() {
  local replica="$1"
  local rep_dir="${RUN_DIR}/replica-${replica}"
  local conda_prefix_dir="${rep_dir}/snakemake-conda"
  mkdir -p "$rep_dir" "$conda_prefix_dir" "${rep_dir}/conda-pkgs"
  export PATH="${MINIFORGE}/bin:${MINIFORGE}/condabin:${PATH}"
  export CONDA_PKGS_DIRS="${rep_dir}/conda-pkgs"
  export CONDARC="${rep_dir}/condarc"
  cat > "${CONDARC}" <<'EOF'
always_yes: true
auto_activate_base: false
channel_priority: strict
channels:
  - conda-forge
  - bioconda
  - defaults
EOF
  write_project "$rep_dir"
  cd "$rep_dir"
  "${SNAKEMAKE}" \
    -s "${WORKFLOW}" \
    --use-conda \
    --conda-frontend conda \
    --conda-prefix "${conda_prefix_dir}" \
    --cores "${VPIPE_CORES}" \
    --resources "mem_mb=${VPIPE_MEM_MB}" \
    --rerun-incomplete \
    --printshellcmds \
    --show-failed-logs \
    --latency-wait 120
  count="$(validate_outputs "$rep_dir" "replica $replica")"
  find "$rep_dir/results" -type f -size +0c | sort > "$rep_dir/nonempty-outputs.txt"
  echo "V-pipe replica ${replica} native Snakemake baseline completed with ${count} non-empty result files."
}

if [ "${1:-}" = "worker" ]; then
  run_replica "$2"
  exit 0
fi

prepare_inputs
for replica in 0 1 2 3; do
  srun --exclusive --nodes=1 --ntasks=1 --cpus-per-task="${SLURM_CPUS_PER_TASK:-40}" \
    "$0" worker "$replica" > "$RUN_DIR/replica-${replica}.out" 2> "$RUN_DIR/replica-${replica}.err" &
done
wait

for replica in 0 1 2 3; do
  test -s "$RUN_DIR/replica-${replica}/nonempty-outputs.txt"
done

echo "V-pipe native Snakemake 4-node baseline completed across 4 nodes."
