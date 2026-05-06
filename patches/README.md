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

### 5. mirtop_do_py_str_bytes.patch
- **File:** `mirtop/libs/do.py` (line 79)  — applies to mirtop 0.4.30 (installed via bioconda as a conda env for nf-core/smrnaseq's MIRTOP_GFF/STATS/COUNTS/EXPORT processes)
- **Issue:** `error_msg += "".join(debug_stdout)` fails with `TypeError: sequence item 0: expected str instance, bytes found` because `debug_stdout` is a `collections.deque` of lines read from `subprocess.Popen.stdout` (default `bytes` in Python 3). The error-path crash masks the real underlying samtools-sort failure on the test-profile bam input.
- **Fix:** Decode each bytes item with `errors="replace"` before joining: `error_msg += "".join(l.decode(errors="replace") if isinstance(l, bytes) else l for l in debug_stdout)`
- **Impact:** Without this fix, nf-core/smrnaseq halts at MIRTOP_GFF with an obscure TypeError, masking any downstream issue. With the fix, the actual samtools-sort failure (if any) is surfaced in the error message, allowing real diagnosis.
- **Application target:** This patch modifies the *conda-env-installed* copy of mirtop, not a git-tracked source tree. The target is `runs/nf-core_shared/conda_cache/env-*/lib/python*/site-packages/mirtop/libs/do.py`. All Nextflow-managed conda envs for mirtop share one inode via hardlinks (nlink=7), so a single in-place edit patches all of them. Backup at `do.py.orig.pre-mtang-patch` in the first patched env.
- **Upstream PR target:** https://github.com/miRTop/mirtop — file a PR on the same one-liner against `mirtop/libs/do.py:79`.
- **Rollback:** `cp <any-env>/lib/python*/site-packages/mirtop/libs/do.py.orig.pre-mtang-patch <same-path>/do.py` (all envs' do.py are hardlinks; replacing any one replaces all).

### 6. nf-core_cutandrun.patch
- **File:** `modules/local/for_patch/trimgalore/main.nf` (lines 18-19)
- **Issue:** Pre-25.x DSL2 output-emit syntax `emit: html optional true` (no comma/colon) fails on Nextflow 25.x with `Cannot invoke method optional() on null object`.
- **Fix:** Match the modern syntax used by every other module in the same repo: `, emit: html, optional: true`.
- **Impact:** Without this fix, nf-core/cutandrun pipeline fails in the parse phase (before any task runs).
- **Upstream PR target:** https://github.com/nf-core/cutandrun against modules/local/for_patch/trimgalore/main.nf

### 7. nf-core_quantms.patch
- **Files:** `modules/local/msstats/main.nf`, `modules/local/msstatstmt/main.nf`, `modules/local/openms/proteomicslfq/main.nf`
- **Issue:** pre-25.x DSL2 `path "*.pdf" optional true` / `emit: foo optional true` syntax triggers `Cannot invoke method optional() on null object` on Nextflow 25.x.
- **Fix:** add comma + colon → `path "*.pdf", optional: true` (matching the modern convention used by every other module in the repo).
- **Upstream PR target:** https://github.com/nf-core/quantms

### 8. dna-seq-gatk-variant-calling.patch
- **File:** `workflow/rules/common.smk` (line 44)
- **Issue:** `pd.read_table(fai, header=None, usecols=[0], squeeze=True, dtype=str)` — the `squeeze=True` kwarg was removed in pandas 2.x (TypeError: unexpected keyword argument).
- **Fix:** Drop the kwarg and chain `.squeeze()` method: `pd.read_table(fai, header=None, usecols=[0], dtype=str).squeeze()`.
- **Upstream PR target:** https://github.com/snakemake-workflows/dna-seq-gatk-variant-calling

### 2.b. dna-seq-varlociraptor.patch (addendum)
- **Additional file:** `workflow/rules/mapping.smk` (line 207)
- **Issue:** f-string with nested same-character quotes: `f"-C {get_read_group("-R")(w)}"` — valid in Python 3.12+ (PEP 701) but the project uses earlier Python where this is a SyntaxError.
- **Fix:** Use single quotes for the inner string literal: `f"-C {get_read_group('-R')(w)}"`.
- **Impact:** Without this fix, the workflow fails immediately at DAG build.
