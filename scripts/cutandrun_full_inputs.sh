#!/usr/bin/env bash

prepare_cutandrun_full_inputs() {
  local root="$1"
  local data_dir="$root/data/nf-core_cutandrun/full"
  local fastq_dir="$data_dir/fastq"
  local samplesheet="$data_dir/gse145187_full_samplesheet.csv"

  mkdir -p "$fastq_dir"

  download_file() {
    local url="$1"
    local dest="$2"
    if [ -s "$dest" ]; then
      return 0
    fi
    mkdir -p "$(dirname "$dest")"
    curl -L --fail --retry 8 --retry-delay 15 --retry-all-errors \
      --continue-at - "$url" -o "$dest.part"
    mv "$dest.part" "$dest"
  }

  download_file "https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR110/054/SRR11074254/SRR11074254_1.fastq.gz" "$fastq_dir/SRR11074254_1.fastq.gz"
  download_file "https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR110/054/SRR11074254/SRR11074254_2.fastq.gz" "$fastq_dir/SRR11074254_2.fastq.gz"
  download_file "https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR110/055/SRR11074255/SRR11074255_1.fastq.gz" "$fastq_dir/SRR11074255_1.fastq.gz"
  download_file "https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR110/055/SRR11074255/SRR11074255_2.fastq.gz" "$fastq_dir/SRR11074255_2.fastq.gz"
  download_file "https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR122/017/SRR12246717/SRR12246717_1.fastq.gz" "$fastq_dir/SRR12246717_1.fastq.gz"
  download_file "https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR122/017/SRR12246717/SRR12246717_2.fastq.gz" "$fastq_dir/SRR12246717_2.fastq.gz"
  download_file "https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR119/025/SRR11923225/SRR11923225_1.fastq.gz" "$fastq_dir/SRR11923225_1.fastq.gz"
  download_file "https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR119/025/SRR11923225/SRR11923225_2.fastq.gz" "$fastq_dir/SRR11923225_2.fastq.gz"
  download_file "https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR119/024/SRR11923224/SRR11923224_1.fastq.gz" "$fastq_dir/SRR11923224_1.fastq.gz"
  download_file "https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR119/024/SRR11923224/SRR11923224_2.fastq.gz" "$fastq_dir/SRR11923224_2.fastq.gz"

  cat > "$samplesheet" <<EOF
group,replicate,fastq_1,fastq_2,control
h3k4me3,1,$fastq_dir/SRR11074254_1.fastq.gz,$fastq_dir/SRR11074254_2.fastq.gz,igg_ctrl
h3k4me3,2,$fastq_dir/SRR11074255_1.fastq.gz,$fastq_dir/SRR11074255_2.fastq.gz,igg_ctrl
h3k27me3,1,$fastq_dir/SRR12246717_1.fastq.gz,$fastq_dir/SRR12246717_2.fastq.gz,igg_ctrl
h3k27me3,2,$fastq_dir/SRR11923225_1.fastq.gz,$fastq_dir/SRR11923225_2.fastq.gz,igg_ctrl
igg_ctrl,1,$fastq_dir/SRR11923224_1.fastq.gz,$fastq_dir/SRR11923224_2.fastq.gz,
EOF

  export CUTANDRUN_SAMPLESHEET="$samplesheet"
  export CUTANDRUN_IGENOMES_BASE="https://ngi-igenomes.s3.amazonaws.com/igenomes"
}
