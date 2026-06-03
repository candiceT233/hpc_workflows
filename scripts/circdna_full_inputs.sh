#!/usr/bin/env bash

prepare_circdna_full_inputs() {
  local root="$1"
  local data_dir="$root/data/nf-core_circdna/full_prjna1012841"
  local fastq_dir="$data_dir/fastq"
  local sra_dir="$data_dir/sra"
  local samplesheet="$data_dir/samplesheet.prjna1012841.local.csv"
  local miniforge="$root/tools/miniforge"
  local env_dir="$root/tools/conda-envs/sra-tools"
  local lock_file="$root/tools/conda-envs/.sra-tools.lock"

  mkdir -p "$fastq_dir" "$sra_dir" "$(dirname "$lock_file")"

  (
    flock 9
    if [ ! -x "$env_dir/bin/fasterq-dump" ]; then
      rm -rf "$env_dir"
      "$miniforge/bin/mamba" create --yes --quiet \
        --prefix "$env_dir" \
        -c conda-forge -c bioconda \
        bioconda::sra-tools
    fi
  ) 9>"$lock_file"

  export PATH="$env_dir/bin:$PATH"
  export NCBI_SETTINGS="/tmp/${USER:-jcernudagarcia}-sra-settings-${SLURM_JOB_ID:-manual}.mkfg"

  stage_run() {
    local run="$1"
    local r1="$fastq_dir/${run}_1.fastq.gz"
    local r2="$fastq_dir/${run}_2.fastq.gz"
    if [ -s "$r1" ] && [ -s "$r2" ] && gzip -t "$r1" >/dev/null 2>&1 && gzip -t "$r2" >/dev/null 2>&1; then
      return 0
    fi
    rm -f "$fastq_dir/${run}"*.fastq "$r1" "$r2" "$r1.part" "$r2.part"
    prefetch --output-directory "$sra_dir" "$run"
    fasterq-dump --split-files --threads "${SLURM_CPUS_PER_TASK:-8}" --temp "$data_dir/tmp" --outdir "$fastq_dir" "$sra_dir/$run"
    gzip -f "$fastq_dir/${run}_1.fastq" "$fastq_dir/${run}_2.fastq"
    test -s "$r1" && test -s "$r2"
    gzip -t "$r1"
    gzip -t "$r2"
  }

  stage_run SRR25905243
  stage_run SRR25905242

  cat > "$samplesheet" <<EOF
sample,fastq_1,fastq_2
CbA1,$fastq_dir/SRR25905243_1.fastq.gz,$fastq_dir/SRR25905243_2.fastq.gz
CbA2,$fastq_dir/SRR25905242_1.fastq.gz,$fastq_dir/SRR25905242_2.fastq.gz
EOF

  export CIRCDNA_INPUT="$samplesheet"
  export CIRCDNA_FASTA="https://ngi-igenomes.s3.amazonaws.com/igenomes/Mus_musculus/Ensembl/GRCm38/Sequence/WholeGenomeFasta/genome.fa"
  export CIRCDNA_REFERENCE_BUILD="GRCm38"
}
