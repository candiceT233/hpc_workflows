# AI Agent Guide: HPC Workflow Benchmarking Suite

This guide provides everything an LLM agent (Claude, Gemini, etc.) needs to recreate, rerun, and extend the HPC workflow benchmarking environment from scratch.

## Table of Contents
1. [Project Overview](#1-project-overview)
2. [Environment Setup](#2-environment-setup)
3. [Repository Setup](#3-repository-setup)
4. [Data Acquisition](#4-data-acquisition)
5. [Per-Workflow Recreation Guide](#5-per-workflow-recreation-guide)
6. [Execution Results Summary](#6-execution-results-summary)
7. [Known Issues and Blockers](#7-known-issues-and-blockers)
8. [Extending the Suite](#8-extending-the-suite)

---

## 1. Project Overview

This project benchmarks 26 publicly available HPC scientific workflows on the Ares cluster. Workflows span bioinformatics (nf-core, Snakemake), molecular dynamics, astronomy, weather tracking, and ML-driven simulations.

**Pipeline phases** (see `prompts/` for full agent prompts):
1. **Discovery** -- Find and clone workflow repos from nf-core, Snakemake catalog, Galaxy IWC, GitHub topics, and known HPC workflows
2. **Triage** -- Evaluate feasibility on the target cluster
3. **Data Download** -- Acquire test inputs at small and medium scales
4. **Environment Setup** -- Install dependencies (conda envs, pip venvs, compiled tools)
5. **Execution** -- Run workflows with Darshan I/O tracing via SLURM
6. **Summary** -- Collect results, timing, output sizes, repair logs

**Key files:**
- `docs/catalog.tsv` -- All 26 repos with URLs and sources
- `docs/phase6_results.tsv` -- Execution status, timing, and output sizes
- `summaries/*_PHASE6_SUMMARY.txt` -- Detailed per-workflow execution reports
- `patches/` -- Code fixes applied to 4 repos
- `scripts/` -- Download and execution scripts

---

## 2. Environment Setup

### Ares Cluster Specifics
```bash
# SLURM partitions
#   datacrumbs: preferred, MaxTime=2d, ~29 nodes
#   compute: fallback, MaxTime=2d, ~22 nodes
#   debug: MaxTime=4d, ~6 nodes
# Node shape: 40 CPUs, ~47759 MiB RAM

# Set project root
export WORKFLOW_ROOT="/mnt/common/mtang11/hpc_workflows"

# Conda -- NOT on PATH by default in batch shells
export CONDA_ROOT="/mnt/common/mtang11/miniconda3"
source "$CONDA_ROOT/etc/profile.d/conda.sh"

# Java version (limits Nextflow compatibility)
java -version  # openjdk 11.0.30 -- max Nextflow 23.10.x

# No Docker or Singularity available
# No `module load conda` available
```

### Darshan I/O Tracing (built from source)
```bash
# Darshan 3.5.0 built at $WORKFLOW_ROOT/tools/darshan
# To use:
export DARSHAN_LOG_DIR="<run_dir>/darshan_logs"
export LD_PRELOAD="$WORKFLOW_ROOT/tools/darshan/lib/libdarshan.so"
# Run workflow under SLURM with these exports
```

---

## 3. Repository Setup

### Clone This Repo
```bash
git clone --recurse-submodules <this-repo-url> hpc_workflows
cd hpc_workflows
```

### Apply Code Patches
Four repos require local patches (see `patches/README.md` for details):
```bash
# DeepDriveMD: fix self.cfg bug
cd repos/DeepDriveMD-pipeline && git apply ../../patches/DeepDriveMD-pipeline.patch && cd ../..

# dna-seq-varlociraptor: pandas 3.0 compatibility
cd repos/dna-seq-varlociraptor && git apply ../../patches/dna-seq-varlociraptor.patch && cd ../..

# metaGEM: conda activate syntax fix (23 occurrences)
cd repos/metaGEM && git apply ../../patches/metaGEM.patch && cd ../..

# Montage: jconfig.h compilation fix
cd repos/Montage && git apply ../../patches/Montage.patch && cd ../..
```

### Archive Repos (clone separately if needed)
These are too large for submodules. Clone only if you need them:
```bash
git clone https://github.com/lammps/lammps archive/lammps
git clone https://github.com/nwchemgit/nwchem archive/nwchem
git clone https://github.com/Parsl/parsl archive/parsl
git clone https://github.com/pegasus-isi/pegasus archive/pegasus
git clone https://github.com/mcherukara/PtychoNN archive/PtychoNN
git clone https://github.com/radical-cybertools/radical.pilot archive/radical.pilot
```

---

## 4. Data Acquisition

### nf-core Pipeline Data (8 pipelines, ~967 MB total)
```bash
# Download all 8 nf-core pipeline test datasets
bash scripts/download_inputs.sh

# Or download a single pipeline
bash scripts/download_inputs.sh rnaseq
```

Each pipeline gets `data/<name>/small/` and `data/<name>/medium/` directories.
See `docs/README_DATA.txt` for full data documentation.

**Scale definitions:**
- **small/** -- Minimal CI test data from each pipeline's `conf/test.config`
- **medium/** -- 3x concatenation of small FASTQ files (most pipelines) or scaled-up test_full.config data where HTTPS-accessible

### Non-nf-core Workflow Data
These workflows have their own data acquisition steps:

| Workflow | Data Source | How to Get |
|----------|-----------|------------|
| 1000genome-workflow | VCF files from 1000 Genomes Project | Included in repo test data |
| biobb_wf_md_setup | PDB structures from RCSB | Fetched by workflow (1AKI default) |
| DeepDriveMD-pipeline | PDB + pretrained .pt model | In repo `examples/` or test data |
| Montage | FITS astronomical images | Downloaded from IRSA/2MASS |
| PyFLEXTRKR | NetCDF radar/satellite data | From ARM/GPM archives |
| metaGEM | FASTQ metagenome reads | From test-datasets or SRA |
| V-pipe | SARS-CoV-2 amplicon FASTQ | Built-in test data in repo |

---

## 5. Per-Workflow Recreation Guide

### Successfully Executed Workflows

#### biobb_wf_md_setup (Python, Both Success)
```bash
# Environment
source "$CONDA_ROOT/etc/profile.d/conda.sh"
conda create -p $WORKFLOW_ROOT/runs/biobb_wf_md_setup/env/conda python=3.10 -y
conda activate $WORKFLOW_ROOT/runs/biobb_wf_md_setup/env/conda
conda install -c conda-forge gromacs=2026.0 -y
pip install biobb_wf_md_setup  # or install from repo

# Run small scale (1AKI lysozyme)
cd $WORKFLOW_ROOT/runs/biobb_wf_md_setup/small
python -m biobb_wf_md_setup  # 5 steps: fetch, fix, pdb2gmx, editconf, solvate

# Medium scale: 8 PDB structures, 3/8 succeed (force field compatibility limits)
```

#### DeepDriveMD-pipeline (RADICAL-EnTK, Both Success)
```bash
# IMPORTANT: Apply patch first (self.cfg bug fix)
cd repos/DeepDriveMD-pipeline && git apply ../../patches/DeepDriveMD-pipeline.patch

# Environment
python3 -m venv $WORKFLOW_ROOT/runs/DeepDriveMD-pipeline/env/venv
source $WORKFLOW_ROOT/runs/DeepDriveMD-pipeline/env/venv/bin/activate
pip install pydantic==1.10.26  # must be v1, not v2
pip install PyYAML h5py numpy scipy MDAnalysis pathos tqdm
pip install radical.entk radical.pilot radical.utils
pip install openmm  # v8.5 via pip
pip install git+https://github.com/braceal/MD-tools.git
pip install -e repos/DeepDriveMD-pipeline/

# Dependency notes:
#   - h5py: repo pins ==2.10.0, won't build on Python 3.10; use latest
#   - PyYAML: repo pins <6.0.0; 6.0.3 works fine
#   - OpenMM via pip, simtk.openmm compat shim is functional

# Run small (1 iteration, 1 task, uses /bin/echo as placeholder executable)
# Run medium (2 iterations, 4 tasks)
# See summaries/DeepDriveMD-pipeline_PHASE6_SUMMARY.txt for config details
```

#### Montage (Shell/C, Both Success)
```bash
# IMPORTANT: Apply patch first (jconfig.h fix)
cd repos/Montage && git apply ../../patches/Montage.patch

# Compile from source
cd repos/Montage && make && cd ../..

# Run
bash scripts/run_montage.sh small   # 4 FITS files, ~3s
bash scripts/run_montage.sh medium  # 16 FITS files, ~12s
```

#### PyFLEXTRKR (Python, Both Success)
```bash
# Environment
python3 -m venv $WORKFLOW_ROOT/runs/PyFLEXTRKR/env/venv
source $WORKFLOW_ROOT/runs/PyFLEXTRKR/env/venv/bin/activate
pip install xarray dask netcdf4 scipy scikit-image
pip install -e repos/PyFLEXTRKR/

# Small: NEXRAD convective cell tracking (35 netCDF files)
# Config: runs/PyFLEXTRKR/small/config_small.yml
# Driver: repos/PyFLEXTRKR/runscripts/run_celltracking.py
# NOTE: Use run_parallel=0 (serial) -- Dask parallel mode causes HDF5 concurrent access errors

# Medium: GPM IMERG MCS tracking (98 netCDF files)
# Config: runs/PyFLEXTRKR/medium/config_medium.yml
# Driver: repos/PyFLEXTRKR/runscripts/run_mcs_tbpf.py
```

#### V-pipe (Snakemake 7, Small Only)
```bash
# IMPORTANT: Requires Snakemake v7 (load_configfile removed in v8+)
source "$CONDA_ROOT/etc/profile.d/conda.sh"
conda create -p $WORKFLOW_ROOT/runs/V-pipe/env/conda python=3.10 snakemake=7.32.4 -y
conda activate $WORKFLOW_ROOT/runs/V-pipe/env/conda

# CRITICAL: Isolate from user site-packages
export PYTHONNOUSERSITE=1

# Run SARS-CoV-2 test (2 samples, QA + SNV calling)
cd $WORKFLOW_ROOT/data/V-pipe/small/sars-cov-2/
snakemake --cores 4 --use-conda
```

#### metaGEM (Snakemake, Small Only)
```bash
# IMPORTANT: Apply patch first (conda activate syntax fix)
cd repos/metaGEM && git apply ../../patches/metaGEM.patch

# Environment: Snakemake v9 + dedicated fastp conda env
source "$CONDA_ROOT/etc/profile.d/conda.sh"
conda create -p $WORKFLOW_ROOT/runs/metaGEM/env/conda snakemake=9.18.2 -y

# Config: Replace placeholder paths in workflow/config.yaml with actual WORKFLOW_ROOT paths
# Default target: qfilter (fastp quality filtering on all samples)
# Small: 3 samples, ~748s
```

### Failed Workflows (and why)

#### All nf-core Pipelines (rnaseq, sarek, eager, viralrecon, chipseq, atacseq, mag, ampliseq)
**Root cause:** Two-layer incompatibility:
1. Java 11 on Ares limits Nextflow to <=23.10.x, but modern nf-core pipelines require Nextflow >=25.x (for nf-schema/nf-core-utils plugins)
2. No Docker/Singularity/Conda profile available for bioinformatics tool installation

**To fix:** Install Java 17+, upgrade Nextflow, and provide either Docker, Singularity, or configure conda profile.

#### Snakemake Wrapper Workflows (chipseq, dna-seq-gatk-variant-calling, rna-seq-star-deseq2)
**Root cause:** Snakemake wrappers require `--use-conda` to install tools (BWA, GATK, samtools, etc.) into isolated conda environments. Without conda integration, the wrapper scripts execute but underlying bioinformatics tools are missing.

**To fix:** Ensure conda/mamba is available and run with `--use-conda`.

#### dna-seq-varlociraptor
**Root cause:** pandas 3.0 breaking change (see patch). Even with fix, still needs conda for tools.

#### iwc (Galaxy)
**Root cause:** Galaxy server not available. Galaxy workflows (.ga files) require a running Galaxy instance.

---

## 6. Execution Results Summary

| Workflow | WMS | Small | Medium | Repair Attempts | Darshan Files |
|----------|-----|-------|--------|-----------------|---------------|
| biobb_wf_md_setup | Python | SUCCESS (3s) | SUCCESS (29s) | 1 | 19 + 43 |
| DeepDriveMD-pipeline | RADICAL-EnTK | SUCCESS (37s) | SUCCESS (37s) | 2 | 8 + 8 |
| Montage | Shell/C | SUCCESS (174s) | SUCCESS (182s) | 0 | 23 + 23 |
| PyFLEXTRKR | Python | SUCCESS (271s) | SUCCESS (465s) | 1 | 39 + 7 |
| V-pipe | Snakemake 7 | SUCCESS (1457s) | SKIPPED | 2 | 2123 |
| metaGEM | Snakemake 9 | SUCCESS (748s) | SKIPPED | 3 | 143 |
| rna-seq-star-deseq2 | Snakemake | FATAL | SKIPPED | 3 | 5257 |
| dna-seq-gatk-variant-calling | Snakemake | FATAL | SKIPPED | 2 | 0 |
| All 8 nf-core | Nextflow | FATAL | SKIPPED | 2-3 each | 0 |
| chipseq | Snakemake | FATAL | SKIPPED | 3 | 0 |
| dna-seq-varlociraptor | Snakemake | FATAL | SKIPPED | 1 | 0 |
| iwc | Galaxy | FATAL | SKIPPED | 0 | 0 |

**6/20 workflows executed successfully** (4 both scales, 2 small only).

---

## 7. Known Issues and Blockers

1. **Java 11 limitation** -- Ares only has openjdk 11.0.30. Modern nf-core requires Java 17+ for Nextflow >=25.x
2. **No container runtime** -- No Docker or Singularity, limiting nf-core and many bioinformatics workflows
3. **Conda not on default PATH** -- Must explicitly source conda.sh in all scripts and SLURM jobs
4. **PyFLEXTRKR parallel mode** -- Dask LocalCluster causes HDF5 concurrent file access errors; use serial mode
5. **Snakemake version split** -- V-pipe needs v7, metaGEM uses v9; incompatible in same env
6. **pandas 3.0 breaking changes** -- Affects dna-seq-varlociraptor (patched)
7. **medium scale data** -- Most nf-core test_full.config references S3 buckets requiring AWS credentials; medium data is 3x concatenation of small instead

---

## 8. Extending the Suite

### Adding a New Workflow
1. Add as submodule: `git submodule add <url> repos/<name>`
2. Create data directory: `mkdir -p data/<name>/{small,medium}`
3. Download test inputs
4. Set up environment in `runs/<name>/env/`
5. Run at small then medium scale
6. Write `summaries/<name>_PHASE6_SUMMARY.txt`
7. If code changes needed, save patch to `patches/<name>.patch` and update `patches/README.md`

### Re-running with Darshan Tracing
```bash
#!/bin/bash
#SBATCH --partition=datacrumbs
#SBATCH --nodes=4
#SBATCH --ntasks-per-node=40
#SBATCH --mem=47000M

export WORKFLOW_ROOT="/mnt/common/mtang11/hpc_workflows"
export DARSHAN_LOG_DIR="$WORKFLOW_ROOT/runs/<name>/<scale>/darshan_logs"
mkdir -p "$DARSHAN_LOG_DIR"
export LD_PRELOAD="$WORKFLOW_ROOT/tools/darshan/lib/libdarshan.so"

# Source conda if needed
source /mnt/common/mtang11/miniconda3/etc/profile.d/conda.sh

# Run your workflow here
```

### Agent Prompt Templates
The `prompts/` directory contains reusable agent prompts:
- `workflow_discovery.prompt` -- Multi-phase pipeline for discovering, triaging, and cataloging workflows
- `workflow_run.prompt` -- Execution phase with self-repair, Darshan tracing, and summary generation
