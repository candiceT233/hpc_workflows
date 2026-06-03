#!/usr/bin/env bash

prepare_viralintegration_real_inputs() {
  local root="$1"
  local input_dir="$2"
  local input_csv="$3"
  local viral_fasta="$4"
  local host_fasta="$5"
  local host_gtf="$6"

  mkdir -p "$input_dir"

  download_gzip() {
    local url="$1"
    local dest="$2"
    local tmp="${dest}.part"

    if [ -s "$dest" ] && gzip -t "$dest" >/dev/null 2>&1; then
      return 0
    fi
    if [ -s "$dest" ] && [ ! -s "$tmp" ]; then
      mv "$dest" "$tmp"
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

  download_gzip \
    "https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR237/051/SRR23719851/SRR23719851_1.fastq.gz" \
    "$input_dir/SRR23719851_1.fastq.gz"
  download_gzip \
    "https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR237/051/SRR23719851/SRR23719851_2.fastq.gz" \
    "$input_dir/SRR23719851_2.fastq.gz"

  if [ ! -s "$viral_fasta" ]; then
    download_plain \
      "https://data.broadinstitute.org/Trinity/CTAT_RESOURCE_LIB/VIRUS_INSERTION_FINDING_LIB_SUPPLEMENT/virus_db.nr.fasta" \
      "$viral_fasta"
  fi
  grep -q '^>' "$viral_fasta"

  if [ ! -s "$host_fasta" ]; then
    echo "ERROR: missing host FASTA: $host_fasta" >&2
    echo "Expected existing full GRCh37 FASTA from the deepvariant GIAB route." >&2
    return 1
  fi
  grep -q '^>' "$host_fasta"

  if [ ! -s "$host_gtf" ]; then
    local gtf_gz="${host_gtf}.gz"
    download_gzip \
      "https://ftp.ensembl.org/pub/grch37/release-87/gtf/homo_sapiens/Homo_sapiens.GRCh37.87.gtf.gz" \
      "$gtf_gz"
    gzip -cd "$gtf_gz" > "${host_gtf}.tmp"
    mv "${host_gtf}.tmp" "$host_gtf"
  fi
  grep -q -v '^#' "$host_gtf"

  cat > "$input_csv" <<EOF
sample,fastq_1,fastq_2
HeLa_SE4_h2_3,$input_dir/SRR23719851_1.fastq.gz,$input_dir/SRR23719851_2.fastq.gz
EOF
}
