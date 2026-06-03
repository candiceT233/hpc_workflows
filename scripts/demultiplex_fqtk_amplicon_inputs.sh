#!/usr/bin/env bash

prepare_demultiplex_fqtk_amplicon_inputs() {
  local root="$1"
  local src_dir="$root/data/nf-core_ampliseq/full/fastq"
  local data_dir="$root/data/nf-core_demultiplex/fqtk_public_amplicon"
  local flowcell_dir="$data_dir/flowcell"
  local flowcell_tar="$data_dir/FCDEMUX_AMPlicon.tar.gz"
  local samplesheet="$data_dir/fqtk_samplesheet.csv"
  local manifest="$data_dir/per_flowcell_manifest.csv"
  local pipeline_sheet="$data_dir/pipeline_samplesheet.csv"

  mkdir -p "$data_dir" "$flowcell_dir"

  local runs=(
    SRR10070130 SRR10070131 SRR10070132 SRR10070133
    SRR10070134 SRR10070141 SRR10070149 SRR10070150
    SRR10070151 SRR10102392 SRR10102393 SRR10102394
  )
  local barcodes=(
    AAGCCCAATAAACCAC TCTGACTGGCCGAATA GGGATATAGGCAACGA CATGTGCGGCGACCCT
    TGCGACAGTGACGCTT TCGCCGTTGCCTAAAC CTATTTGAAGGAGTCT AGCAGCCGCAGTAAGG
    CACAATACCTCGTCCG TGTTACCAGACCAAAC AAGACGTCCTCTTCAA TGTTTAAATGACCCTC
  )

  for run in "${runs[@]}"; do
    for mate in 1 2; do
      if [ ! -s "$src_dir/${run}_${mate}.fastq.gz" ]; then
        echo "ERROR: missing staged public AMPLICON FASTQ: $src_dir/${run}_${mate}.fastq.gz" >&2
        return 1
      fi
    done
  done

  cat > "$samplesheet" <<'EOF'
sample_id,barcode
EOF
  for i in "${!runs[@]}"; do
    printf '%s,%s\n' "${runs[$i]}" "${barcodes[$i]}" >> "$samplesheet"
  done

  cat > "$manifest" <<'EOF'
fastq,read_structure
out_L001_I1_001.fastq.gz,8B
out_L001_I2_001.fastq.gz,8B
out_L001_R1_001.fastq.gz,+T
out_L001_R2_001.fastq.gz,+T
EOF

  if [ ! -s "$flowcell_tar" ]; then
    rm -f "$flowcell_dir"/out_L001_*.fastq.gz "$flowcell_tar.part"
    python3 - "$src_dir" "$flowcell_dir" "${runs[*]}" "${barcodes[*]}" <<'PY'
import gzip
import sys
from pathlib import Path

src = Path(sys.argv[1])
out = Path(sys.argv[2])
runs = sys.argv[3].split()
barcodes = sys.argv[4].split()

handles = {
    "R1": gzip.open(out / "out_L001_R1_001.fastq.gz", "wt"),
    "R2": gzip.open(out / "out_L001_R2_001.fastq.gz", "wt"),
    "I1": gzip.open(out / "out_L001_I1_001.fastq.gz", "wt"),
    "I2": gzip.open(out / "out_L001_I2_001.fastq.gz", "wt"),
}

def records(path):
    with gzip.open(path, "rt", errors="replace") as handle:
        while True:
            header = handle.readline()
            if not header:
                return
            seq = handle.readline()
            plus = handle.readline()
            qual = handle.readline()
            if not qual:
                raise SystemExit(f"truncated FASTQ: {path}")
            yield seq.rstrip(), qual.rstrip()

try:
    for sample_idx, (run, barcode) in enumerate(zip(runs, barcodes), start=1):
        barcode1, barcode2 = barcode[:8], barcode[8:]
        r1_path = src / f"{run}_1.fastq.gz"
        r2_path = src / f"{run}_2.fastq.gz"
        for read_idx, ((seq1, qual1), (seq2, qual2)) in enumerate(zip(records(r1_path), records(r2_path)), start=1):
            tile = 1101 + (read_idx // 100000)
            x = read_idx % 100000
            y = sample_idx
            base = f"@ARES:1:FCDEMUX:{sample_idx}:{tile}:{x}:{y}"
            suffix = f"1:N:0:{barcode1}+{barcode2}"
            handles["R1"].write(f"{base} {suffix}\n{seq1}\n+\n{qual1}\n")
            handles["R2"].write(f"{base} {suffix}\n{seq2}\n+\n{qual2}\n")
            handles["I1"].write(f"{base} 1:N:0:{barcode1}\n{barcode1}\n+\n{'I' * len(barcode1)}\n")
            handles["I2"].write(f"{base} 1:N:0:{barcode2}\n{barcode2}\n+\n{'I' * len(barcode2)}\n")
finally:
    for handle in handles.values():
        handle.close()
PY
    for fastq in "$flowcell_dir"/out_L001_*.fastq.gz; do
      gzip -t "$fastq"
    done
    tar -C "$flowcell_dir" -czf "$flowcell_tar.part" .
    mv "$flowcell_tar.part" "$flowcell_tar"
  fi

  cat > "$pipeline_sheet" <<EOF
id,samplesheet,lane,flowcell,per_flowcell_manifest
FCDEMUX,$samplesheet,1,$flowcell_tar,$manifest
EOF

  export DEMULTIPLEX_INPUT="$pipeline_sheet"
  export DEMULTIPLEX_DEMUXER="fqtk"
}
