# HPC Scientific Workflow Benchmarking Suite

A curated collection of 26 HPC scientific workflow repositories, test data pipelines, execution summaries, and I/O traces from benchmarking on the **Ares HPC cluster**.

**For AI agents:** Start with [AGENT_GUIDE.md](AGENT_GUIDE.md) -- it contains everything you need to recreate, rerun, and extend this project.

## Project Structure

```
hpc_workflows/
├── README.md                  # This file
├── AGENT_GUIDE.md             # Comprehensive guide for AI agents
├── repos/                     # 20 workflow repositories (git submodules)
├── archive/                   # 6 archived repos (document-only, see docs/)
├── patches/                   # 4 git patches for local code fixes
│   ├── README.md              # Patch descriptions and apply instructions
│   ├── DeepDriveMD-pipeline.patch
│   ├── dna-seq-varlociraptor.patch
│   ├── metaGEM.patch
│   └── Montage.patch
├── summaries/                 # Per-workflow execution summaries (Phase 6)
├── prompts/                   # Agent prompt templates for discovery & execution
│   ├── workflow_discovery.prompt
│   └── workflow_run.prompt
├── scripts/                   # Reusable execution and data download scripts
│   ├── download_inputs.sh     # Downloads test data for 8 nf-core pipelines
│   ├── run_montage.sh         # Montage mosaic pipeline runner
│   └── run_1000genome.py      # 1000 Genomes direct execution runner
├── docs/                      # Catalog, results, and data documentation
│   ├── catalog.tsv            # All 26 repos: name, URL, source, clone date
│   ├── phase6_results.tsv     # Execution results: status, timing, output size
│   ├── data_status.tsv        # Data download status per pipeline
│   ├── triage_pass.tsv        # Workflows that passed triage for execution
│   └── README_DATA.txt        # Test data documentation (8 nf-core pipelines)
├── data/                      # Test input data (NOT in git, re-downloadable)
├── runs/                      # Execution outputs (NOT in git, reproducible)
├── tools/                     # Build tools & envs (NOT in git, rebuildable)
└── logs/                      # Execution logs (NOT in git)
```

## Workflow Repositories (20 submodules in repos/)

| # | Repo | WMS | Domain | Status |
|---|------|-----|--------|--------|
| 1 | 1000genome-workflow | Pegasus | Genomics | Skipped |
| 2 | biobb_wf_md_setup | Python | Molecular dynamics | Both Success |
| 3 | chipseq | Snakemake | ChIP-seq | Both Failed (needs conda) |
| 4 | DeepDriveMD-pipeline | RADICAL-EnTK | ML-driven MD | Both Success |
| 5 | dna-seq-gatk-variant-calling | Snakemake | Variant calling | Both Failed (needs conda) |
| 6 | dna-seq-varlociraptor | Snakemake | Variant calling | Both Failed (needs conda) |
| 7 | iwc | Galaxy | Multi-domain | Both Failed (needs Galaxy) |
| 8 | metaGEM | Snakemake | Metagenomics | Small Only |
| 9 | Montage | Shell/C | Astronomy | Both Success |
| 10 | nf-core_ampliseq | Nextflow | Amplicon seq | Both Failed (Java 11) |
| 11 | nf-core_atacseq | Nextflow | ATAC-seq | Both Failed (Java 11) |
| 12 | nf-core_chipseq | Nextflow | ChIP-seq | Both Failed (Java 11) |
| 13 | nf-core_eager | Nextflow | Ancient DNA | Both Failed (DSL1) |
| 14 | nf-core_mag | Nextflow | Metagenome assembly | Both Failed (Java 11) |
| 15 | nf-core_rnaseq | Nextflow | RNA-seq | Both Failed (Java 11) |
| 16 | nf-core_sarek | Nextflow | Variant calling | Both Failed (Java 11) |
| 17 | nf-core_viralrecon | Nextflow | Viral genomics | Both Failed (Java 11) |
| 18 | PyFLEXTRKR | Python | Weather tracking | Both Success |
| 19 | rna-seq-star-deseq2 | Snakemake | RNA-seq | Both Failed (needs conda) |
| 20 | V-pipe | Snakemake | Viral genomics | Small Only |

## Archived Repositories (6, not submodules)

These are large framework/application repos archived for reference. Clone manually if needed:

| Repo | URL | Purpose |
|------|-----|---------|
| lammps | https://github.com/lammps/lammps | Molecular dynamics simulator |
| nwchem | https://github.com/nwchemgit/nwchem | Computational chemistry |
| parsl | https://github.com/Parsl/parsl | Parallel scripting library |
| pegasus | https://github.com/pegasus-isi/pegasus | Workflow management system |
| PtychoNN | https://github.com/mcherukara/PtychoNN | Neural network ptychography |
| radical.pilot | https://github.com/radical-cybertools/radical.pilot | HPC pilot framework |

## Quick Start

```bash
# Clone with submodules
git clone --recurse-submodules <repo-url>
cd hpc_workflows

# Apply patches to modified repos
cd repos/DeepDriveMD-pipeline && git apply ../../patches/DeepDriveMD-pipeline.patch && cd ../..
cd repos/dna-seq-varlociraptor && git apply ../../patches/dna-seq-varlociraptor.patch && cd ../..
cd repos/metaGEM && git apply ../../patches/metaGEM.patch && cd ../..
cd repos/Montage && git apply ../../patches/Montage.patch && cd ../..

# Download test data (requires internet)
bash scripts/download_inputs.sh
```

## Cluster Requirements (Ares)

- **Scheduler:** SLURM (partitions: datacrumbs, compute, debug)
- **Nodes:** 40 CPUs, ~47 GB RAM each
- **Java:** 11 (limits Nextflow to <=23.10.x)
- **Conda:** Miniconda at `/mnt/common/mtang11/miniconda3`
- **No Docker/Singularity** available
