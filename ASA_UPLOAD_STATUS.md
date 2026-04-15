# Awesome Scientific Applications — Upload Status

Tracks what this project has contributed to
[grc-iit/awesome-scienctific-applications](https://github.com/grc-iit/awesome-scienctific-applications)
and the evidence that each contributed workflow was validated on Ares
before being packaged as a container.

Last updated: 2026-04-15

---

## Where the contribution lives

- Clone: `/mnt/common/mtang11/hpc_workflows/upload-asa/`
- Branch: `candice-workflows` — **pushed** to
  `origin/candice-workflows`
- Based off `origin/main` at commit `5162768` (main has since advanced
  to `dd33b22`; a rebase or merge will be needed before opening a PR)

## Workflows added (7)

| Folder in ASA repo | Upstream | Stack | Bare-metal scales that SUCCEEDED |
|---|---|---|---|
| `montage/` | [Caltech-IPAC/Montage](https://github.com/Caltech-IPAC/Montage) | C toolkit | small + medium |
| `biobb_wf_md_setup/` | [bioexcel/biobb_wf_md_setup](https://github.com/bioexcel/biobb_wf_md_setup) | Python + GROMACS (conda) | small + medium |
| `pyflextrkr/` | [FlexTRKR/PyFLEXTRKR](https://github.com/FlexTRKR/PyFLEXTRKR) | Python (venv) + Dask-MPI for multi-node | small + medium + **multi-node Dask-MPI** |
| `vpipe/` | [cbg-ethz/V-pipe](https://github.com/cbg-ethz/V-pipe) | Snakemake 7 + conda | small |
| `metagem/` | [franciscozorrilla/metaGEM](https://github.com/franciscozorrilla/metaGEM) | Snakemake 9 + conda | small |
| `deepdrivemd/` | [DeepDriveMD/DeepDriveMD-pipeline](https://github.com/DeepDriveMD/DeepDriveMD-pipeline) | RADICAL-EnTK (Python venv) | small + medium |
| `rna_seq_star_deseq2/` | [snakemake-workflows/rna-seq-star-deseq2](https://github.com/snakemake-workflows/rna-seq-star-deseq2) | Snakemake 9 + conda | small (53/53 steps, re-run 2026-04-14) |

All seven are CPU-only as packaged. GPU reservations can be added by
swapping in real executables (most relevant for `deepdrivemd`, which
currently ships `/bin/echo` placeholders to validate the framework
itself).

## Commits on `candice-workflows`

```
b803dea Add rna_seq_star_deseq2 CPU-only RNA-seq diffexp workflow
098e626 Add deepdrivemd CPU-only adaptive MD framework smoke workflow
1f8708b Add metagem CPU-only metagenomics qfilter workflow
5ff3043 Add vpipe CPU-only virus NGS workflow
eb53202 Add pyflextrkr CPU-only atmospheric-feature-tracking workflow
2e61aab Scope VALIDATION.md to each workflow folder
6edca86 Add montage and biobb_wf_md_setup CPU-only HPC workflows
```

Additional local edits on `pyflextrkr/` (Dask-MPI multi-node support:
`run_demo_multinode.sh`, `run_mcs_tbpf_mpi.py`, plus Dockerfile /
Dockerfile.deploy / docker-compose / README / VALIDATION updates) are
pending — modified/untracked in the working tree, not yet committed.

---

## Ares bare-metal validation (pre-containerisation)

All seven workflows were executed on Ares before being packaged. The
first six on the original 2026-03-26/27 Phase 6 run; the seventh
(`rna_seq_star_deseq2`) on a 2026-04-14 re-run after conda was upgraded
to 26.1.1. PyFLEXTRKR gained a second multi-node validation on
2026-04-14 to cover its Dask-MPI recipe.

| Workflow | Scale | Exit | Elapsed | Output size | SLURM stderr lines | stdout error-pattern lines | Notes |
|---|---|---|---|---|---|---|---|
| Montage | small | 0 | ~3 s | 1.13 MB (`mosaic.fits`) | 0 | 0 | Clean. |
| Montage | medium | 0 | ~12 s | 18.4 MB (`mosaic.fits`) | 0 | 0 | Clean. |
| biobb_wf_md_setup | small | 0 | ~3 s | 3.3 MB | — | 0 | 1AKI, all 5 steps PASS. |
| biobb_wf_md_setup | medium | 0 | ~29 s | 14 MB | — | 5 `Fatal error:` | GROMACS per-PDB diagnostics (non-standard residues); 3/8 PDBs succeed, rest fail at `pdb2gmx` — **expected behaviour**, documented in the PHASE6 summary. |
| PyFLEXTRKR | small | 0 | 271 s | 300 MB | 0 | 0 | Required 1 self-repair: Dask parallel → serial (HDF5 concurrent-access bug). |
| PyFLEXTRKR | medium | 0 | 465 s | 128 MB | 0 | 0 | Serial mode. |
| **PyFLEXTRKR** | **medium (Dask-MPI, job 7978, 2026-04-14)** | **0** | **~6 min 30 s** | same shape as serial | 0 | 0 (cosmetic CommClosedError during MPI teardown) | **All 9 pipeline steps**; `stats/` 8 files, `tracking/` 95, `mcstracking/` 48; byte-identical `grid_area_from_latlon.nc`, `tracknumbers_*.nc`, `trackstats_*.nc`, `trackstats_sparse_*.nc` to the serial reference. See `pyflextrkr/VALIDATION.md`. |
| V-pipe | small | 0 | 1457 s | 115 MB | — | 0 | All 35 Snakemake steps completed. |
| metaGEM | small | 0 | 748 s | 1.6 GB (`qfiltered/`) | — | 0 | qfilter on 3 samples. |
| DeepDriveMD-pipeline | small | 0 | ~37 s | — | 0 | 4 `Traceback` | All from `dry_run.py` negative-path tests (RabbitMQ not configured → ZMQ fallback). Real run: all 4 stages DONE, 1/1 iter. |
| DeepDriveMD-pipeline | medium | 0 | ~37 s | — | 0 | 1 `Traceback` | Same test-harness artefact as small. Real run: all 4 stages DONE per iter, 2/2 iters. |
| **rna-seq-star-deseq2** | **small (job 7963, 2026-04-14)** | **0** | **1311 s (~22 min)** | **25 MB** (`counts/`, `deseq2/`, `diffexp/`, `pca.condition.svg`, `qc/`, `star/`, `trimmed/`) | (stderr merged) | 0 | All **53/53** Snakemake steps done. |

### Summary of stderr / stdout validation

- **SLURM stderr**: zero lines for every workflow that ran under SLURM
  with a dedicated stderr stream (Montage, PyFLEXTRKR, DeepDriveMD, and
  the 2026-04-14 re-runs). The remaining workflows ran Snakemake/python
  directly with stderr merged into the stdout log.
- **stdout error-pattern scan**: six of the nine runs produce zero
  hits; the three that don't (biobb medium, DDMD small/medium) have
  all hits attributable to documented expected behaviour. None of
  these hits indicates an actual pipeline failure; every top-level
  exit code is 0.

---

## 2026-04-14 re-run of previously-failed Phase 6 workflows

Ares currently has conda **26.1.1** (vs. 23.7.2 at Phase 6 time), which
unblocks Snakemake `--use-conda` wrapper workflows. Re-ran the four
Snakemake wrappers; results below.

| Workflow | Exit | Elapsed | Blocker | Action |
|---|---|---|---|---|
| `rna-seq-star-deseq2` | ✅ 0 | 1311 s | — | **Packaged** as `rna_seq_star_deseq2/` in ASA repo. |
| `chipseq` | ❌ 1 | 1835 s | Snakemake 9 refuses old wrapper URLs (`/raw/0.72.0/bio/fastqc`, etc.). All wrapper-backed rules fail. | Skipped — would need upstream Snakefile updates or a pinned Snakemake-7 env. |
| `dna-seq-gatk-variant-calling` | ❌ 1 | 1881 s | pandas 2.x removed `squeeze` kwarg; `None \| type` runtime bug in wrapper; 2/33 steps completed before crash. | Skipped — upstream workflow bug. |
| `dna-seq-varlociraptor` | ❌ 1 | 5 s | Python 3.12 rejects nested `"..."` inside an f-string expression at `mapping.smk:207` (PEP 701). | Skipped — upstream workflow bug; parse-time failure, so the prepared pandas patch never applied. |

Net result: +1 new workflow (`rna_seq_star_deseq2`) in ASA; the other
three are out of scope without upstream fixes.

---

## Java 17 install (for nf-core group)

nf-core pipelines require Nextflow ≥ 25, which requires Java ≥ 17.
Ares system Java is still 11.0.30. Installed Temurin JDK 17.0.13
locally (no sudo needed):

- Location: `/mnt/common/mtang11/hpc_workflows/tools/java17/jdk-17.0.13+11/`
- Verified: `nextflow -v` → `25.10.4.11173` when `JAVA_HOME` is set.

Each `run_slurm.sh` for nf-core pipelines will export
`JAVA_HOME=$WORKFLOW_ROOT/tools/java17/jdk-17.0.13+11` and prepend
`$JAVA_HOME/bin` to `PATH`.

### nf-core/rnaseq smoke run — in progress

- SLURM job **7979** submitted 2026-04-15 via
  `runs/nf-core_rnaseq/small/run_slurm.sh`.
- `nextflow run ... -profile test,conda`.
- Shared Nextflow state under `runs/nf-core_shared/{nf_home,conda_cache}`.
- At last check (18 min in): alignment + dedup + qualimap stages
  complete, still materialising later `stringtie`, `featurecounts`,
  `dupradar`, `rseqc` conda envs. Running normally.

Will update this doc with the final result once the job finishes.

---

## Remaining work

1. **End-to-end Docker build + compose test** on a host with Docker
   daemon access — the Ares login node doesn't grant this account
   membership in the `docker` group, so everything above the
   `VALIDATION.md` row in each workflow folder stops at static
   validation (`bash -n`, `yaml.safe_load`, `podman build` Dockerfile
   parse, image-name consistency). See each workflow's `VALIDATION.md`
   for the specific "not validated" list.

2. **Finish the pyflextrkr Dask-MPI commit.** Working-tree changes to
   `pyflextrkr/` (Dask-MPI multi-node support) are staged locally but
   not yet committed.

3. **Finish the nf-core campaign.** After `nf-core_rnaseq` lands:
   `nf-core_sarek`, `nf-core_eager`, `nf-core_viralrecon`,
   `nf-core_chipseq`, `nf-core_atacseq`, `nf-core_mag`,
   `nf-core_ampliseq`. Each re-uses the same Java 17 + Nextflow + conda
   setup; the bulk of time is per-pipeline conda-env solves.

4. **Out of scope.** `iwc` needs a Galaxy server; `1000genome-workflow`
   uses Pegasus WMS — both remain skipped.
