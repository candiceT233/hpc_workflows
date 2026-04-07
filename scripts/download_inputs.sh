#!/usr/bin/env bash
###############################################################################
# download_inputs.sh
# Downloads test input data for 8 nf-core Nextflow pipelines.
# - small: from test.config (minimal CI test data)
# - medium: from test_full.config where HTTPS-accessible; otherwise replicate
#           small data with concatenation to simulate larger inputs
#
# Usage: bash download_inputs.sh [pipeline_name]
#   If pipeline_name given, only that pipeline is downloaded.
#   Otherwise all 8 are downloaded.
#
# Data source: https://github.com/nf-core/test-datasets (various branches)
# Generated: 2026-03-26
###############################################################################
set -euo pipefail

DATA_ROOT="/mnt/common/mtang11/hpc_workflows/data"
LOG="${DATA_ROOT}/download_inputs.log"
> "$LOG"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

# Helper: download a file, skip if already exists
dl() {
    local url="$1" dest="$2"
    local fname
    fname=$(basename "$dest")
    if [[ -f "$dest" ]]; then
        log "  SKIP (exists): $fname"
        return 0
    fi
    log "  Downloading: $fname"
    if wget -q --timeout=120 --tries=3 -O "$dest" "$url" 2>>"$LOG"; then
        log "  OK: $fname ($(du -sh "$dest" | cut -f1))"
        return 0
    else
        log "  FAILED: $fname from $url"
        rm -f "$dest"
        return 1
    fi
}

# Helper: create medium data by concatenating small FASTQ files with themselves
replicate_small_to_medium() {
    local small_dir="$1" medium_dir="$2"
    log "  Replicating small -> medium (3x concatenation of FASTQ files)"
    for f in "$small_dir"/*.fastq.gz "$small_dir"/*.fq.gz; do
        [[ -f "$f" ]] || continue
        local bname
        bname=$(basename "$f")
        local dest="$medium_dir/$bname"
        if [[ -f "$dest" ]]; then
            log "  SKIP (exists): medium/$bname"
            continue
        fi
        cat "$f" "$f" "$f" > "$dest"
        log "  Replicated: $bname ($(du -sh "$dest" | cut -f1))"
    done
    # Copy non-FASTQ files as-is (references, samplesheets, etc.)
    for f in "$small_dir"/*; do
        [[ -f "$f" ]] || continue
        local bname
        bname=$(basename "$f")
        case "$bname" in
            *.fastq.gz|*.fq.gz) continue ;;
        esac
        if [[ ! -f "$medium_dir/$bname" ]]; then
            cp "$f" "$medium_dir/$bname"
            log "  Copied ref: $bname"
        fi
    done
}

###############################################################################
# 1. nf-core/rnaseq
###############################################################################
download_rnaseq() {
    local S="$DATA_ROOT/nf-core_rnaseq/small"
    local M="$DATA_ROOT/nf-core_rnaseq/medium"
    mkdir -p "$S/fastq" "$S/reference" "$M/fastq" "$M/reference"
    log "=== nf-core_rnaseq: SMALL ==="

    # Samplesheet
    dl "https://raw.githubusercontent.com/nf-core/test-datasets/626c8fab639062eade4b10747e919341cbf9b41a/samplesheet/v3.10/samplesheet_test.csv" \
       "$S/samplesheet_test.csv"

    # FASTQ files (from samplesheet)
    local BASE="https://raw.githubusercontent.com/nf-core/test-datasets/rnaseq/testdata/GSE110004"
    for srr in SRR6357070 SRR6357071 SRR6357072; do
        dl "${BASE}/${srr}_1.fastq.gz" "$S/fastq/${srr}_1.fastq.gz"
        dl "${BASE}/${srr}_2.fastq.gz" "$S/fastq/${srr}_2.fastq.gz"
    done
    for srr in SRR6357073 SRR6357074 SRR6357075 SRR6357076; do
        dl "${BASE}/${srr}_1.fastq.gz" "$S/fastq/${srr}_1.fastq.gz"
    done
    dl "${BASE}/SRR6357076_2.fastq.gz" "$S/fastq/SRR6357076_2.fastq.gz"

    # Reference genome files
    local RBASE="https://raw.githubusercontent.com/nf-core/test-datasets/626c8fab639062eade4b10747e919341cbf9b41a/reference"
    dl "${RBASE}/genome.fasta" "$S/reference/genome.fasta"
    dl "${RBASE}/genes_with_empty_tid.gtf.gz" "$S/reference/genes_with_empty_tid.gtf.gz"
    dl "${RBASE}/genes.gff.gz" "$S/reference/genes.gff.gz"
    dl "${RBASE}/transcriptome.fasta" "$S/reference/transcriptome.fasta"
    dl "${RBASE}/gfp.fa.gz" "$S/reference/gfp.fa.gz"
    dl "${RBASE}/bbsplit_fasta_list.txt" "$S/reference/bbsplit_fasta_list.txt"
    dl "${RBASE}/hisat2.tar.gz" "$S/reference/hisat2.tar.gz"
    dl "${RBASE}/salmon.tar.gz" "$S/reference/salmon.tar.gz"

    log "=== nf-core_rnaseq: MEDIUM ==="
    # Full test uses GRCh37 igenome (too large). Replicate small data.
    dl "https://raw.githubusercontent.com/nf-core/test-datasets/626c8fab639062eade4b10747e919341cbf9b41a/samplesheet/v3.10/samplesheet_full.csv" \
       "$M/samplesheet_full.csv"
    replicate_small_to_medium "$S/fastq" "$M/fastq"
    cp -n "$S/reference/"* "$M/reference/" 2>/dev/null || true
}

###############################################################################
# 2. nf-core/sarek
###############################################################################
download_sarek() {
    local S="$DATA_ROOT/nf-core_sarek/small"
    local M="$DATA_ROOT/nf-core_sarek/medium"
    mkdir -p "$S/fastq" "$S/reference" "$M/fastq" "$M/reference"
    log "=== nf-core_sarek: SMALL ==="

    # Samplesheet
    cp /mnt/common/mtang11/hpc_workflows/repos/nf-core_sarek/tests/csv/3.0/fastq_single.csv \
       "$S/samplesheet_test.csv" 2>/dev/null || true

    # FASTQ files
    local FBASE="https://raw.githubusercontent.com/nf-core/test-datasets/modules/data/genomics/homo_sapiens/illumina/fastq"
    dl "${FBASE}/test_1.fastq.gz" "$S/fastq/test_1.fastq.gz"
    dl "${FBASE}/test_2.fastq.gz" "$S/fastq/test_2.fastq.gz"

    # Reference genome (from igenomes_base = test-datasets/modules/data/)
    local GBASE="https://raw.githubusercontent.com/nf-core/test-datasets/modules/data/genomics/homo_sapiens/genome"
    dl "${GBASE}/genome.fasta" "$S/reference/genome.fasta"
    dl "${GBASE}/genome.fasta.fai" "$S/reference/genome.fasta.fai"
    dl "${GBASE}/genome.dict" "$S/reference/genome.dict"
    dl "${GBASE}/genome.interval_list" "$S/reference/genome.interval_list"

    # VCF reference files
    local VBASE="${GBASE}/vcf"
    dl "${VBASE}/dbsnp_146.hg38.vcf.gz" "$S/reference/dbsnp_146.hg38.vcf.gz"
    dl "${VBASE}/dbsnp_146.hg38.vcf.gz.tbi" "$S/reference/dbsnp_146.hg38.vcf.gz.tbi"
    dl "${VBASE}/gnomAD.r2.1.1.vcf.gz" "$S/reference/gnomAD.r2.1.1.vcf.gz"
    dl "${VBASE}/gnomAD.r2.1.1.vcf.gz.tbi" "$S/reference/gnomAD.r2.1.1.vcf.gz.tbi"
    dl "${VBASE}/mills_and_1000G.indels.vcf.gz" "$S/reference/mills_and_1000G.indels.vcf.gz"
    dl "${VBASE}/mills_and_1000G.indels.vcf.gz.tbi" "$S/reference/mills_and_1000G.indels.vcf.gz.tbi"

    log "=== nf-core_sarek: MEDIUM ==="
    # Full test uses S3 (HCC1395 WES data, not directly downloadable via HTTPS)
    # Replicate small data for medium scale
    dl "https://raw.githubusercontent.com/nf-core/test-datasets/sarek/testdata/csv/HCC1395_WXS_somatic_full_test.csv" \
       "$M/samplesheet_full.csv"
    replicate_small_to_medium "$S/fastq" "$M/fastq"
    cp -rn "$S/reference/"* "$M/reference/" 2>/dev/null || true
}

###############################################################################
# 3. nf-core/eager
###############################################################################
download_eager() {
    local S="$DATA_ROOT/nf-core_eager/small"
    local M="$DATA_ROOT/nf-core_eager/medium"
    mkdir -p "$S/fastq" "$S/reference" "$M/fastq" "$M/reference"
    log "=== nf-core_eager: SMALL ==="

    # Samplesheet
    dl "https://raw.githubusercontent.com/nf-core/test-datasets/eager/testdata/Mammoth/mammoth_design_fastq.tsv" \
       "$S/samplesheet_test.tsv"

    # FASTQ files (Mammoth data)
    local FBASE="https://github.com/nf-core/test-datasets/raw/eager/testdata/Mammoth/fastq"
    dl "${FBASE}/JK2782_TGGCCGATCAACGA_L008_R1_001.fastq.gz.tengrand.fq.gz" \
       "$S/fastq/JK2782_R1.fq.gz"
    dl "${FBASE}/JK2782_TGGCCGATCAACGA_L008_R2_001.fastq.gz.tengrand.fq.gz" \
       "$S/fastq/JK2782_R2.fq.gz"
    dl "${FBASE}/JK2802_AGAATAACCTACCA_L008_R1_001.fastq.gz.tengrand.fq.gz" \
       "$S/fastq/JK2802_R1.fq.gz"

    # Reference
    dl "https://raw.githubusercontent.com/nf-core/test-datasets/eager/reference/Mammoth/Mammoth_MT_Krause.fasta" \
       "$S/reference/Mammoth_MT_Krause.fasta"

    log "=== nf-core_eager: MEDIUM ==="
    # Full test uses S3 data (cod genome, ENA data). Replicate small.
    dl "https://raw.githubusercontent.com/nf-core/test-datasets/eager/testdata/Benchmarking/benchmarking_vikingfish.tsv" \
       "$M/samplesheet_full.tsv"
    replicate_small_to_medium "$S/fastq" "$M/fastq"
    cp -n "$S/reference/"* "$M/reference/" 2>/dev/null || true
}

###############################################################################
# 4. nf-core/viralrecon
###############################################################################
download_viralrecon() {
    local S="$DATA_ROOT/nf-core_viralrecon/small"
    local M="$DATA_ROOT/nf-core_viralrecon/medium"
    mkdir -p "$S/fastq" "$S/reference" "$M/fastq" "$M/reference"
    log "=== nf-core_viralrecon: SMALL ==="

    # Samplesheet
    dl "https://raw.githubusercontent.com/nf-core/test-datasets/viralrecon/samplesheet/v2.6/samplesheet_test_amplicon_illumina.csv" \
       "$S/samplesheet_test.csv"

    # FASTQ files
    local FBASE="https://raw.githubusercontent.com/nf-core/test-datasets/viralrecon/illumina/amplicon"
    dl "${FBASE}/sample1_R1.fastq.gz" "$S/fastq/sample1_R1.fastq.gz"
    dl "${FBASE}/sample1_R2.fastq.gz" "$S/fastq/sample1_R2.fastq.gz"
    dl "${FBASE}/sample2_R1.fastq.gz" "$S/fastq/sample2_R1.fastq.gz"
    dl "${FBASE}/sample2_R2.fastq.gz" "$S/fastq/sample2_R2.fastq.gz"

    # SARS-CoV-2 reference genome (MN908947.3) from NCBI
    dl "https://ftp.ncbi.nlm.nih.gov/genomes/all/GCF/009/858/895/GCF_009858895.2_ASM985889v3/GCF_009858895.2_ASM985889v3_genomic.fna.gz" \
       "$S/reference/MN908947.3_genome.fna.gz"

    # Kraken2 database
    dl "https://raw.githubusercontent.com/nf-core/test-datasets/viralrecon/genome/kraken2/kraken2_hs22.tar.gz" \
       "$S/reference/kraken2_hs22.tar.gz"

    log "=== nf-core_viralrecon: MEDIUM ==="
    # Full test uses S3 data (48 samples). Replicate small.
    dl "https://raw.githubusercontent.com/nf-core/test-datasets/viralrecon/samplesheet/v2.6/samplesheet_full_amplicon_illumina.csv" \
       "$M/samplesheet_full.csv"
    replicate_small_to_medium "$S/fastq" "$M/fastq"
    cp -rn "$S/reference/"* "$M/reference/" 2>/dev/null || true
}

###############################################################################
# 5. nf-core/chipseq
###############################################################################
download_chipseq() {
    local S="$DATA_ROOT/nf-core_chipseq/small"
    local M="$DATA_ROOT/nf-core_chipseq/medium"
    mkdir -p "$S/fastq" "$S/reference" "$M/fastq" "$M/reference"
    log "=== nf-core_chipseq: SMALL ==="

    # Samplesheet
    dl "https://raw.githubusercontent.com/nf-core/test-datasets/chipseq/samplesheet/v2.1/samplesheet_test.csv" \
       "$S/samplesheet_test.csv"

    # FASTQ files (shared with atacseq test data + chipseq-specific input controls)
    local ABASE="https://raw.githubusercontent.com/nf-core/test-datasets/atacseq/testdata"
    dl "${ABASE}/SRR1822153_1.fastq.gz" "$S/fastq/SRR1822153_1.fastq.gz"
    dl "${ABASE}/SRR1822153_2.fastq.gz" "$S/fastq/SRR1822153_2.fastq.gz"
    dl "${ABASE}/SRR1822154_1.fastq.gz" "$S/fastq/SRR1822154_1.fastq.gz"
    dl "${ABASE}/SRR1822154_2.fastq.gz" "$S/fastq/SRR1822154_2.fastq.gz"
    dl "${ABASE}/SRR1822157_1.fastq.gz" "$S/fastq/SRR1822157_1.fastq.gz"
    dl "${ABASE}/SRR1822157_2.fastq.gz" "$S/fastq/SRR1822157_2.fastq.gz"
    dl "${ABASE}/SRR1822158_1.fastq.gz" "$S/fastq/SRR1822158_1.fastq.gz"
    dl "${ABASE}/SRR1822158_2.fastq.gz" "$S/fastq/SRR1822158_2.fastq.gz"

    local CBASE="https://raw.githubusercontent.com/nf-core/test-datasets/chipseq/testdata"
    dl "${CBASE}/SRR5204809_Spt5-ChIP_Input1_SacCer_ChIP-Seq_ss100k_R1.fastq.gz" \
       "$S/fastq/SRR5204809_Input1_R1.fastq.gz"
    dl "${CBASE}/SRR5204809_Spt5-ChIP_Input1_SacCer_ChIP-Seq_ss100k_R2.fastq.gz" \
       "$S/fastq/SRR5204809_Input1_R2.fastq.gz"
    dl "${CBASE}/SRR5204810_Spt5-ChIP_Input2_SacCer_ChIP-Seq_ss100k_R1.fastq.gz" \
       "$S/fastq/SRR5204810_Input2_R1.fastq.gz"
    dl "${CBASE}/SRR5204810_Spt5-ChIP_Input2_SacCer_ChIP-Seq_ss100k_R2.fastq.gz" \
       "$S/fastq/SRR5204810_Input2_R2.fastq.gz"

    # Reference genome (uses atacseq reference)
    dl "https://raw.githubusercontent.com/nf-core/test-datasets/atacseq/reference/genome.fa" \
       "$S/reference/genome.fa"
    dl "https://raw.githubusercontent.com/nf-core/test-datasets/atacseq/reference/genes.gtf" \
       "$S/reference/genes.gtf"

    log "=== nf-core_chipseq: MEDIUM ==="
    # Full test uses hg19 igenome (too large). Replicate small.
    dl "https://raw.githubusercontent.com/nf-core/test-datasets/chipseq/samplesheet/v2.1/samplesheet_full.csv" \
       "$M/samplesheet_full.csv"
    replicate_small_to_medium "$S/fastq" "$M/fastq"
    cp -rn "$S/reference/"* "$M/reference/" 2>/dev/null || true
}

###############################################################################
# 6. nf-core/atacseq
###############################################################################
download_atacseq() {
    local S="$DATA_ROOT/nf-core_atacseq/small"
    local M="$DATA_ROOT/nf-core_atacseq/medium"
    mkdir -p "$S/fastq" "$S/reference" "$M/fastq" "$M/reference"
    log "=== nf-core_atacseq: SMALL ==="

    # Samplesheet
    dl "https://raw.githubusercontent.com/nf-core/test-datasets/atacseq/samplesheet/v2.0/samplesheet_test.csv" \
       "$S/samplesheet_test.csv"

    # FASTQ files
    local FBASE="https://raw.githubusercontent.com/nf-core/test-datasets/atacseq/testdata"
    dl "${FBASE}/SRR1822153_1.fastq.gz" "$S/fastq/SRR1822153_1.fastq.gz"
    dl "${FBASE}/SRR1822153_2.fastq.gz" "$S/fastq/SRR1822153_2.fastq.gz"
    dl "${FBASE}/SRR1822154_1.fastq.gz" "$S/fastq/SRR1822154_1.fastq.gz"
    dl "${FBASE}/SRR1822154_2.fastq.gz" "$S/fastq/SRR1822154_2.fastq.gz"
    dl "${FBASE}/SRR1822157_1.fastq.gz" "$S/fastq/SRR1822157_1.fastq.gz"
    dl "${FBASE}/SRR1822157_2.fastq.gz" "$S/fastq/SRR1822157_2.fastq.gz"
    dl "${FBASE}/SRR1822158_1.fastq.gz" "$S/fastq/SRR1822158_1.fastq.gz"
    dl "${FBASE}/SRR1822158_2.fastq.gz" "$S/fastq/SRR1822158_2.fastq.gz"

    # Reference
    dl "https://raw.githubusercontent.com/nf-core/test-datasets/atacseq/reference/genome.fa" \
       "$S/reference/genome.fa"
    dl "https://raw.githubusercontent.com/nf-core/test-datasets/atacseq/reference/genes.gtf" \
       "$S/reference/genes.gtf"

    log "=== nf-core_atacseq: MEDIUM ==="
    # Full test uses hg19 igenome. Replicate small.
    dl "https://raw.githubusercontent.com/nf-core/test-datasets/atacseq/samplesheet/v2.0/samplesheet_full.csv" \
       "$M/samplesheet_full.csv"
    replicate_small_to_medium "$S/fastq" "$M/fastq"
    cp -rn "$S/reference/"* "$M/reference/" 2>/dev/null || true
}

###############################################################################
# 7. nf-core/mag
###############################################################################
download_mag() {
    local S="$DATA_ROOT/nf-core_mag/small"
    local M="$DATA_ROOT/nf-core_mag/medium"
    mkdir -p "$S/fastq" "$S/databases" "$M/fastq" "$M/databases"
    log "=== nf-core_mag: SMALL ==="

    # Samplesheet
    dl "https://raw.githubusercontent.com/nf-core/test-datasets/mag/samplesheets/samplesheet.multirun.v4.csv" \
       "$S/samplesheet_test.csv"

    # FASTQ files
    local FBASE="https://github.com/nf-core/test-datasets/raw/mag/test_data"
    dl "${FBASE}/test_minigut_R1.fastq.gz" "$S/fastq/test_minigut_R1.fastq.gz"
    dl "${FBASE}/test_minigut_R2.fastq.gz" "$S/fastq/test_minigut_R2.fastq.gz"
    dl "${FBASE}/test_minigut_sample2_R1.fastq.gz" "$S/fastq/test_minigut_sample2_R1.fastq.gz"
    dl "${FBASE}/test_minigut_sample2_R2.fastq.gz" "$S/fastq/test_minigut_sample2_R2.fastq.gz"

    # Databases
    local DBASE="https://raw.githubusercontent.com/nf-core/test-datasets/mag/databases"
    dl "${DBASE}/busco/bacteria_odb10.2024-01-08.tar.gz" "$S/databases/bacteria_odb10.tar.gz"
    dl "${DBASE}/gtdbtk/gtdbtk_mockup_20250422.tar.gz" "$S/databases/gtdbtk_mockup.tar.gz"
    dl "${DBASE}/cat/minigut_cat.tar.gz" "$S/databases/minigut_cat.tar.gz"

    log "=== nf-core_mag: MEDIUM ==="
    # Full test uses S3 data. Replicate small.
    dl "https://raw.githubusercontent.com/nf-core/test-datasets/refs/heads/mag/samplesheets/samplesheet.full.v4.csv" \
       "$M/samplesheet_full.csv"
    replicate_small_to_medium "$S/fastq" "$M/fastq"
    cp -rn "$S/databases/"* "$M/databases/" 2>/dev/null || true
}

###############################################################################
# 8. nf-core/ampliseq
###############################################################################
download_ampliseq() {
    local S="$DATA_ROOT/nf-core_ampliseq/small"
    local M="$DATA_ROOT/nf-core_ampliseq/medium"
    mkdir -p "$S/fastq" "$S/metadata" "$M/fastq" "$M/metadata"
    log "=== nf-core_ampliseq: SMALL ==="

    # Samplesheet + metadata
    dl "https://raw.githubusercontent.com/nf-core/test-datasets/ampliseq/samplesheets/Samplesheet.tsv" \
       "$S/metadata/Samplesheet.tsv"
    dl "https://raw.githubusercontent.com/nf-core/test-datasets/ampliseq/samplesheets/Metadata.tsv" \
       "$S/metadata/Metadata.tsv"

    # FASTQ files
    local FBASE="https://github.com/nf-core/test-datasets/raw/ampliseq/testdata"
    dl "${FBASE}/1a_S103_L001_R1_001.fastq.gz" "$S/fastq/1a_S103_L001_R1_001.fastq.gz"
    dl "${FBASE}/1a_S103_L001_R2_001.fastq.gz" "$S/fastq/1a_S103_L001_R2_001.fastq.gz"
    dl "${FBASE}/1_S103_L001_R1_001.fastq.gz"  "$S/fastq/1_S103_L001_R1_001.fastq.gz"
    dl "${FBASE}/1_S103_L001_R2_001.fastq.gz"  "$S/fastq/1_S103_L001_R2_001.fastq.gz"
    dl "${FBASE}/2a_S115_L001_R1_001.fastq.gz" "$S/fastq/2a_S115_L001_R1_001.fastq.gz"
    dl "${FBASE}/2a_S115_L001_R2_001.fastq.gz" "$S/fastq/2a_S115_L001_R2_001.fastq.gz"
    dl "${FBASE}/2_S115_L001_R1_001.fastq.gz"  "$S/fastq/2_S115_L001_R1_001.fastq.gz"
    dl "${FBASE}/2_S115_L001_R2_001.fastq.gz"  "$S/fastq/2_S115_L001_R2_001.fastq.gz"

    log "=== nf-core_ampliseq: MEDIUM ==="
    # Full test uses S3 data. Replicate small.
    dl "https://raw.githubusercontent.com/nf-core/test-datasets/ampliseq/samplesheets/Samplesheet_full.tsv" \
       "$M/metadata/Samplesheet_full.tsv"
    dl "https://raw.githubusercontent.com/nf-core/test-datasets/ampliseq/samplesheets/Metadata_full.tsv" \
       "$M/metadata/Metadata_full.tsv"
    replicate_small_to_medium "$S/fastq" "$M/fastq"
}

###############################################################################
# Main
###############################################################################
PIPELINE="${1:-all}"

case "$PIPELINE" in
    nf-core_rnaseq|rnaseq)     download_rnaseq ;;
    nf-core_sarek|sarek)       download_sarek ;;
    nf-core_eager|eager)       download_eager ;;
    nf-core_viralrecon|viralrecon) download_viralrecon ;;
    nf-core_chipseq|chipseq)   download_chipseq ;;
    nf-core_atacseq|atacseq)   download_atacseq ;;
    nf-core_mag|mag)           download_mag ;;
    nf-core_ampliseq|ampliseq) download_ampliseq ;;
    all)
        download_rnaseq
        download_sarek
        download_eager
        download_viralrecon
        download_chipseq
        download_atacseq
        download_mag
        download_ampliseq
        ;;
    *)
        echo "Unknown pipeline: $PIPELINE"
        echo "Valid: rnaseq sarek eager viralrecon chipseq atacseq mag ampliseq all"
        exit 1
        ;;
esac

log "=== DOWNLOAD SUMMARY ==="
for pipe in nf-core_rnaseq nf-core_sarek nf-core_eager nf-core_viralrecon nf-core_chipseq nf-core_atacseq nf-core_mag nf-core_ampliseq; do
    sd="$DATA_ROOT/$pipe/small"
    md="$DATA_ROOT/$pipe/medium"
    if [[ -d "$sd" ]]; then
        small_size=$(du -sh "$sd" 2>/dev/null | cut -f1)
        small_files=$(find "$sd" -type f | wc -l)
    else
        small_size="N/A"; small_files=0
    fi
    if [[ -d "$md" ]]; then
        med_size=$(du -sh "$md" 2>/dev/null | cut -f1)
        med_files=$(find "$md" -type f | wc -l)
    else
        med_size="N/A"; med_files=0
    fi
    log "$pipe: small=${small_size} (${small_files} files), medium=${med_size} (${med_files} files)"
done

log "=== DONE ==="
