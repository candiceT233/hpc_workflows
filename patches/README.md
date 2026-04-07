# Code Patches

These patches document local modifications made to upstream workflow repositories
to fix bugs or compatibility issues encountered during HPC execution on the Ares cluster.

## How to Apply

After cloning this repo with submodules:

```bash
git submodule update --init --recursive
cd <repo_path>
git apply ../../patches/<repo_name>.patch
```

## Patch Summary

### 1. DeepDriveMD-pipeline.patch
- **File:** `deepdrivemd/deepdrivemd.py` (lines 70, 73)
- **Issue:** `_generate_pipeline_iteration()` referenced bare `cfg` instead of `self.cfg`
- **Fix:** Changed `cfg.aggregation_stage` to `self.cfg.aggregation_stage` and `cfg.machine_learning_stage` to `self.cfg.machine_learning_stage`
- **Impact:** Without this fix, the pipeline crashes with `NameError` when evaluating whether to skip aggregation or retrain ML models

### 2. dna-seq-varlociraptor.patch
- **File:** `workflow/rules/common.smk` (line 66)
- **Issue:** pandas 3.0 breaking change - `validate()` calls `.update()` internally, which fails with "Update not allowed with duplicate indexes" on the samples DataFrame
- **Fix:** Reset index before validation: `_samples_for_validate = samples.reset_index(drop=True)` then validate the copy
- **Impact:** Without this fix, Snakemake dry-run fails immediately with pandas ValueError

### 3. metaGEM.patch
- **File:** `workflow/Snakefile` (23 occurrences)
- **Issue:** All shell rules used deprecated `set +u;source activate {env};set -u;` syntax which fails when conda is not initialized via `source activate`
- **Fix:** Replaced all occurrences with `eval "$(conda shell.bash hook)" && conda activate {env};`
- **Impact:** Without this fix, every Snakemake rule that activates a conda environment fails in non-interactive shells

### 4. Montage.patch
- **File:** `lib/src/jpeg-8b/jconfig.h` (line 49)
- **Issue:** `#define DONT_USE_B_MODE 1` caused compilation issues on the Ares HPC system
- **Fix:** Changed to `/* #undef DONT_USE_B_MODE */`
- **Impact:** Required for successful compilation of Montage C toolkit on this system
