#!/usr/bin/env bash

download_viralrecon_ref() {
  local url="$1"
  local dest="$2"
  local kind="${3:-file}"

  mkdir -p "$(dirname "$dest")"
  if [ -s "$dest" ]; then
    case "$kind" in
      gzip) gzip -t "$dest" >/dev/null 2>&1 || rm -f "$dest" ;;
      tar) tar -tf "$dest" >/dev/null 2>&1 || rm -f "$dest" ;;
    esac
  fi
  if [ ! -s "$dest" ]; then
    local tmp="${dest}.tmp.$$"
    curl -L --retry 5 --retry-delay 10 --connect-timeout 30 -o "$tmp" "$url"
    case "$kind" in
      gzip) gzip -t "$tmp" ;;
      tar) tar -tf "$tmp" >/dev/null ;;
    esac
    mv "$tmp" "$dest"
  fi
}

prepare_viralrecon_references() {
  local root="$1"
  local run_dir="$2"
  local ref_dir="$root/data/nf-core_viralrecon/full/reference"

  mkdir -p "$ref_dir" "$run_dir"
  download_viralrecon_ref \
    "https://ftp.ncbi.nlm.nih.gov/genomes/all/GCA/009/858/895/GCA_009858895.3_ASM985889v3/GCA_009858895.3_ASM985889v3_genomic.fna.gz" \
    "$ref_dir/GCA_009858895.3_ASM985889v3_genomic.fna.gz" gzip
  download_viralrecon_ref \
    "https://ftp.ncbi.nlm.nih.gov/genomes/all/GCA/009/858/895/GCA_009858895.3_ASM985889v3/GCA_009858895.3_ASM985889v3_genomic.gff.gz" \
    "$ref_dir/GCA_009858895.3_ASM985889v3_genomic.gff.gz" gzip
  download_viralrecon_ref \
    "https://github.com/artic-network/artic-ncov2019/raw/master/primer_schemes/nCoV-2019/V3/nCoV-2019.primer.bed" \
    "$ref_dir/nCoV-2019.V3.primer.bed" file
  export VIRALRECON_GENOMES_CONFIG="$run_dir/viralrecon_genomes_local.config"
  cat > "$VIRALRECON_GENOMES_CONFIG" <<EOF
params {
  genomes {
    'MN908947.3' {
      fasta = '$ref_dir/GCA_009858895.3_ASM985889v3_genomic.fna.gz'
      gff = '$ref_dir/GCA_009858895.3_ASM985889v3_genomic.gff.gz'
      primer_sets {
        artic {
          '3' {
            fasta = '$ref_dir/GCA_009858895.3_ASM985889v3_genomic.fna.gz'
            gff = '$ref_dir/GCA_009858895.3_ASM985889v3_genomic.gff.gz'
            primer_bed = '$ref_dir/nCoV-2019.V3.primer.bed'
            scheme = 'nCoV-2019'
          }
        }
      }
    }
  }
}
EOF

  for required in "$VIRALRECON_GENOMES_CONFIG"; do
    if [ ! -s "$required" ]; then
      echo "ERROR: missing viralrecon reference artifact: $required" >&2
      return 1
    fi
  done
}
