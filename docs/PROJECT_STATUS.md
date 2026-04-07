# Project Status: HPC Workflow Benchmarking on Ares

**Last updated:** 2026-04-07  
**Next milestone:** Get all 20 workflows running on SLURM with 2-4 nodes on Ares

---

## Current State Summary

Out of 20 active workflows, **6 ran successfully** and **14 failed** during Phase 6 execution. The failures fall into 3 distinct categories, each with a clear fix path.

### Tier 1: Fully Successful (4 workflows, both small + medium scales)

| Workflow | WMS | SLURM Partition | Darshan Traced | Notes |
|----------|-----|-----------------|----------------|-------|
| biobb_wf_md_setup | Python | compute, 4 nodes | Yes (19+43 files) | GROMACS via conda-forge |
| DeepDriveMD-pipeline | RADICAL-EnTK | datacrumbs, 4 nodes | Yes (8+8 files) | Placeholder executables (/bin/echo), framework validated |
| Montage | Shell/C | datacrumbs, 4 nodes | Yes (23+23 files) | Compiled from source, patch applied |
| PyFLEXTRKR | Python | datacrumbs, 4 nodes | Yes (39+7 files) | Serial mode (Dask parallel HDF5 bug) |

### Tier 2: Partially Successful (2 workflows, small scale only)

| Workflow | WMS | SLURM Partition | Darshan Traced | Why Medium Skipped |
|----------|-----|-----------------|----------------|--------------------|
| V-pipe | Snakemake 7 | compute, 4 nodes | Yes (2123 files) | Time constraint, small succeeded |
| metaGEM | Snakemake 9 | compute, 4 nodes | Yes (143 files) | Time constraint, small succeeded |

### Tier 3: Failed (14 workflows)

#### Category A: nf-core / Nextflow pipelines (8 workflows) -- Java version blocker

**Affected:** nf-core_rnaseq, nf-core_sarek, nf-core_eager, nf-core_viralrecon, nf-core_chipseq, nf-core_atacseq, nf-core_mag, nf-core_ampliseq

**Root cause (two layers):**
1. **Java 11** (openjdk 11.0.30) on Ares limits Nextflow to <=23.10.x
2. Modern nf-core pipelines require **Nextflow >=25.x** for `nf-schema` / `nf-core-utils` plugins
3. Even if Nextflow upgraded, **no Docker/Singularity** available for tool containers

**Fix plan:**
- Install Java 17+ (via conda or manual JDK install under `$WORKFLOW_ROOT/tools/`)
- Install latest Nextflow (self-installs, just needs Java 17+)
- Use `-profile conda` to install tools via conda instead of containers
- Alternative: Install Singularity/Apptainer if cluster admin allows

**Special case -- nf-core_eager:** Uses DSL1 (requires Nextflow <=22.10.x), separate from the Java issue. May need to pin an older pipeline version or port to DSL2.

#### Category B: Snakemake wrapper workflows (4 workflows) -- conda integration missing

**Affected:** chipseq, dna-seq-gatk-variant-calling, dna-seq-varlociraptor, rna-seq-star-deseq2

**Root cause:**
- Snakemake wrappers use `--use-conda` to create isolated tool environments
- Initial runs did NOT use `--use-conda` flag
- conda version 23.7.2 is too old (Snakemake requires >=24.7.1)
- Corrupt conda package cache (`icu-78.3` archive error in rna-seq-star-deseq2 retry)

**Additional issues per workflow:**
- **dna-seq-varlociraptor:** pandas 3.0 incompatibility (PATCHED), plus Python 3.12+ f-string syntax in mapping.smk
- **chipseq:** Test FASTQ files missing from `.test/` directory
- **rna-seq-star-deseq2:** Dry-run passes (53 jobs), execution fails at first rule (fastp not found)
- **dna-seq-gatk-variant-calling:** Dry-run passes (38 jobs), wrapper cache git parse error, then tools missing

**Fix plan:**
- Update conda to >=24.7.1: `conda update -n base conda`
- Clean corrupt package cache: `conda clean --all`
- Run with `snakemake --use-conda --conda-prefix $WORKFLOW_ROOT/runs/<name>/env/conda_envs`
- For chipseq: download test data into `resources/reads/` directory
- For dna-seq-varlociraptor: may need Python 3.12+ or downgrade the workflow version

#### Category C: Platform incompatibility (2 workflows)

| Workflow | Issue | Fix Plan |
|----------|-------|----------|
| iwc | Requires Galaxy server (not CLI-executable) | Install Planemo for CLI execution, or skip |
| 1000genome-workflow | Skipped by design (Pegasus WMS) | Install Pegasus WMS or use the standalone `run_1000genome.py` script |

---

## SLURM Job History

| Job IDs | Workflows | Status |
|---------|-----------|--------|
| 7650-7655 | First batch (6 jobs) | ALL CANCELLED (likely rna-seq-star-deseq2 SLURM batch) |
| 7656-7657 | Montage small/medium | SUCCESS |
| 7658-7659 | DeepDriveMD small/medium | SUCCESS |
| 7660-7662 | PyFLEXTRKR small (2 attempts) + medium | SUCCESS |

---

## Fix Priority for Next Phase

### High Priority (unblock the most workflows)

1. **Update conda to >=24.7.1** -- unblocks 4 Snakemake wrapper workflows
2. **Install Java 17+** -- unblocks 8 nf-core pipelines  
3. **Clean conda cache** -- fixes corrupt package errors

### Medium Priority (per-workflow fixes)

4. Run V-pipe medium scale (small already succeeded)
5. Run metaGEM medium scale (small already succeeded)
6. Download chipseq test data
7. Fix dna-seq-varlociraptor Python 3.12+ syntax issue

### Low Priority / Optional

8. Install Planemo for iwc Galaxy workflows
9. Install Pegasus WMS for 1000genome-workflow
10. Investigate nf-core_eager DSL1 compatibility

---

## Target: All Workflows on 2-4 SLURM Nodes

SLURM job template for multi-node runs:
```bash
#!/bin/bash
#SBATCH --partition=datacrumbs    # or compute
#SBATCH --nodes=4
#SBATCH --ntasks-per-node=40
#SBATCH --mem=47000M
#SBATCH --time=02:00:00
#SBATCH --job-name=<workflow>

export WORKFLOW_ROOT="/mnt/common/mtang11/hpc_workflows"
source /mnt/common/mtang11/miniconda3/etc/profile.d/conda.sh

# Darshan tracing
export DARSHAN_LOG_DIR="$WORKFLOW_ROOT/runs/<workflow>/<scale>/darshan_logs"
mkdir -p "$DARSHAN_LOG_DIR"
export LD_PRELOAD="$WORKFLOW_ROOT/tools/darshan/lib/libdarshan.so"

# Run workflow
# ...
```
