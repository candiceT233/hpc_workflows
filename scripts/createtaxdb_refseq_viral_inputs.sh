#!/usr/bin/env bash

prepare_createtaxdb_refseq_viral_inputs() {
  local root="$1"
  local data_dir="$root/data/nf-core_createtaxdb/refseq_viral"
  local fasta_dir="$data_dir/viralrefseq"
  local tax_dir="$data_dir/taxonomy"
  local tax_zip="$tax_dir/taxdmp.zip"

  mkdir -p "$fasta_dir" "$tax_dir"

  download_gzip() {
    local url="$1"
    local dest="$2"
    mkdir -p "$(dirname "$dest")"
    if [ -s "$dest" ] && gzip -t "$dest"; then
      return 0
    fi
    rm -f "$dest" "$dest.part"
    curl -L --fail --retry 8 --retry-delay 15 --retry-all-errors \
      -o "$dest.part" "$url"
    gzip -t "$dest.part"
    mv "$dest.part" "$dest"
  }

  download_file() {
    local url="$1"
    local dest="$2"
    mkdir -p "$(dirname "$dest")"
    if [ -s "$dest" ]; then
      return 0
    fi
    rm -f "$dest.part"
    curl -L --fail --retry 8 --retry-delay 15 --retry-all-errors \
      -o "$dest.part" "$url"
    test -s "$dest.part"
    mv "$dest.part" "$dest"
  }

  download_gzip \
    "https://ftp.ncbi.nlm.nih.gov/refseq/release/viral/viral.1.1.genomic.fna.gz" \
    "$fasta_dir/viral.1.1.genomic.fna.gz"
  download_gzip \
    "https://ftp.ncbi.nlm.nih.gov/refseq/release/viral/viral.1.protein.faa.gz" \
    "$fasta_dir/viral.1.protein.faa.gz"
  download_gzip \
    "https://ftp.ncbi.nlm.nih.gov/pub/taxonomy/accession2taxid/nucl_gb.accession2taxid.gz" \
    "$tax_dir/nucl_gb.accession2taxid.gz"
  download_gzip \
    "https://ftp.ncbi.nlm.nih.gov/pub/taxonomy/accession2taxid/prot.accession2taxid.gz" \
    "$tax_dir/prot.accession2taxid.gz"

  if [ ! -s "$tax_dir/nucl_gb.accession2taxid" ]; then
    gzip -cd "$tax_dir/nucl_gb.accession2taxid.gz" > "$tax_dir/nucl_gb.accession2taxid.tmp"
    mv "$tax_dir/nucl_gb.accession2taxid.tmp" "$tax_dir/nucl_gb.accession2taxid"
  fi

  download_file \
    "https://ftp.ncbi.nlm.nih.gov/pub/taxonomy/taxdmp.zip" \
    "$tax_zip"
  if [ ! -s "$tax_dir/nodes.dmp" ] || [ ! -s "$tax_dir/names.dmp" ]; then
    unzip -o "$tax_zip" nodes.dmp names.dmp -d "$tax_dir"
  fi

  cat > "$data_dir/samplesheet_refseq_viral.csv" <<EOF
id,taxid,fasta_dna,fasta_aa
ViralRefSeq,1,$fasta_dir/viral.1.1.genomic.fna.gz,$fasta_dir/viral.1.protein.faa.gz
EOF

  export CREATETAXDB_INPUT="$data_dir/samplesheet_refseq_viral.csv"
  export CREATETAXDB_ACCESSION2TAXID="$tax_dir/nucl_gb.accession2taxid"
  export CREATETAXDB_PROT2TAXID="$tax_dir/prot.accession2taxid.gz"
  export CREATETAXDB_NODESDMP="$tax_dir/nodes.dmp"
  export CREATETAXDB_NAMESDMP="$tax_dir/names.dmp"
}
