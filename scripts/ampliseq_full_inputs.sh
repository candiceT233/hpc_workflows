#!/usr/bin/env bash

prepare_ampliseq_full_inputs() {
  local root="$1"
  local input_dir="$root/data/nf-core_ampliseq/full"
  local fastq_dir="$input_dir/fastq"
  local samplesheet="$input_dir/Samplesheet_full.local.tsv"
  local metadata="$input_dir/Metadata_full.local.tsv"

  mkdir -p "$input_dir" "$fastq_dir"

  local runs=(
    SRR10070130 SRR10070131 SRR10070132 SRR10070133 SRR10070134 SRR10070141
    SRR10070149 SRR10070150 SRR10070151 SRR10102392 SRR10102393 SRR10102394
  )

  for run in "${runs[@]}"; do
    for mate in 1 2; do
      local fastq="$fastq_dir/${run}_${mate}.fastq.gz"
      if [ ! -s "$fastq" ]; then
        echo "ERROR: missing staged public AMPLICON FASTQ: $fastq" >&2
        echo "These runs are NCBI SRA AMPLICON accessions; stage FASTQs before rerunning." >&2
        return 1
      fi
    done
  done

  {
    printf 'sampleID\tforwardReads\treverseReads\n'
    for run in "${runs[@]}"; do
      printf '%s\t%s\t%s\n' "$run" "$fastq_dir/${run}_1.fastq.gz" "$fastq_dir/${run}_2.fastq.gz"
    done
  } > "$samplesheet"

  cat > "$metadata" <<'EOF'
ID	name	habitat	Riv_vs_Gro	Sed_vs_Soil
SRR10070130	SRR10070130-Riverwater	Riverwater	Riverwater	
SRR10070131	SRR10070131-Riverwater	Riverwater	Riverwater	
SRR10070132	SRR10070132-Groundwater	Groundwater	Groundwater	
SRR10070133	SRR10070133-Groundwater	Groundwater	Groundwater	
SRR10070134	SRR10070134-Riverwater	Riverwater	Riverwater	
SRR10070141	SRR10070141-Groundwater	Groundwater	Groundwater	
SRR10070149	SRR10070149-Sediment	Sediment		Sediment
SRR10070150	SRR10070150-Sediment	Sediment		Sediment
SRR10070151	SRR10070151-Sediment	Sediment		Sediment
SRR10102392	SRR10102392-Soil	Soil		Soil
SRR10102393	SRR10102393-Soil	Soil		Soil
SRR10102394	SRR10102394-Soil	Soil		Soil
EOF

  export AMPLISEQ_SAMPLESHEET="$samplesheet"
  export AMPLISEQ_METADATA="$metadata"
}
