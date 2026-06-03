#!/usr/bin/env bash

prepare_tumourevo_real_inputs() {
  local root="$1"
  local input_dir="$2"
  local input_csv="$3"
  local vcf="$4"
  local tbi="$5"
  local cna_segments="$6"
  local cna_extra="$7"
  local fasta="$8"
  local drivers_table="$9"

  mkdir -p "$input_dir"

  download_plain() {
    local url="$1"
    local dest="$2"
    local tmp="${dest}.part"

    if [ -s "$dest" ]; then
      return 0
    fi
    for attempt in $(seq 1 20); do
      if curl -L --fail --retry 8 --retry-delay 10 --retry-all-errors --continue-at - "$url" -o "$tmp" \
        && [ -s "$tmp" ]; then
        mv "$tmp" "$dest"
        return 0
      fi
      sleep 30
    done
    echo "ERROR: failed to download $url -> $dest" >&2
    return 1
  }

  download_gzip() {
    local url="$1"
    local dest="$2"
    local tmp="${dest}.part"

    if [ -s "$dest" ] && gzip -t "$dest" >/dev/null 2>&1; then
      return 0
    fi
    for attempt in $(seq 1 20); do
      if curl -L --fail --retry 8 --retry-delay 10 --retry-all-errors --continue-at - "$url" -o "$tmp" \
        && gzip -t "$tmp" >/dev/null 2>&1; then
        mv "$tmp" "$dest"
        return 0
      fi
      sleep 30
    done
    echo "ERROR: failed to download and validate $url -> $dest" >&2
    return 1
  }

  download_plain \
    "https://raw.githubusercontent.com/caravagnalab/CNAqc_datasets/main/MSeq_Set06/Mutations/Set.06.WGS.merged_filtered.vcf" \
    "$vcf"
  grep -q '^#CHROM' "$vcf"

  # The upstream VCF is uncompressed and VEP does not consume the input index. The
  # nf-core samplesheet schema still requires a .tbi path, so keep a harmless
  # placeholder while VEP creates the real annotated .vcf.gz.tbi downstream.
  : > "$tbi"

  download_plain \
    "https://raw.githubusercontent.com/caravagnalab/CNAqc_datasets/main/MSeq_Set06/Copy%20Number/final/Set6_42.smoothedSegs.txt" \
    "$cna_segments"
  download_plain \
    "https://raw.githubusercontent.com/caravagnalab/CNAqc_datasets/main/MSeq_Set06/Copy%20Number/final/Set6_42_confints_CP.txt" \
    "$cna_extra"
  grep -q 'chromosome.*start.pos.*end.pos' "$cna_segments"
  grep -q 'cellularity.*ploidy.estimate' "$cna_extra"

  download_gzip \
    "https://ftp.ensembl.org/pub/release-110/fasta/homo_sapiens/dna/Homo_sapiens.GRCh38.dna.primary_assembly.fa.gz" \
    "$fasta"

  if [ ! -s "$drivers_table" ]; then
    local zip="$input_dir/IntOGen-Drivers-20240920.zip"
    download_plain "https://www.intogen.org/download?file=IntOGen-Drivers-20240920.zip" "$zip"
    unzip -p "$zip" '2024-06-18_IntOGen-Drivers/Compendium_Cancer_Genes.tsv' \
      | awk -F '\t' 'BEGIN{OFS="\t"} NR==1{print "SYMBOL","TUMOUR_TYPE"; next} $1 != "" {print $1,"PANCANCER"}' \
      | sort -u > "${drivers_table}.tmp"
    mv "${drivers_table}.tmp" "$drivers_table"
  fi
  grep -q '^SYMBOL' "$drivers_table"

  cat > "$input_csv" <<EOF
dataset,patient,tumour_sample,normal_sample,vcf,tbi,cna_segments,cna_extra,cna_caller,cancer_type
CNAQC_Set06,Set06,Set6_42,Set6_54_N,$vcf,$tbi,$cna_segments,$cna_extra,sequenza,PANCANCER
EOF
}
