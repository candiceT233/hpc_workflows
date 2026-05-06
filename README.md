# HPC Scientific Workflow Benchmarking Suite

A curated collection of HPC scientific workflow repositories, test data pipelines, execution summaries, and I/O traces from benchmarking on the **Ares HPC cluster**.

**For AI agents:** Start with [AGENT_GUIDE.md](AGENT_GUIDE.md) — it contains everything you need to recreate, rerun, and extend this project.

## Project Structure

```
hpc_workflows/
├── README.md                  # This file
├── AGENT_GUIDE.md             # Comprehensive guide for AI agents
├── repos/                     # Workflow repositories (git submodules)
├── archive/                   # Archived reference repos (document-only)
├── patches/                   # Local code fixes (apply via git apply)
├── summaries/                 # Per-workflow execution summaries
├── prompts/                   # Agent prompt templates for discovery & execution
├── scripts/                   # Reusable execution and data download scripts
├── docs/                      # Catalog, results, and data documentation
├── data/                      # Test input data (NOT in git, re-downloadable)
├── runs/                      # Execution outputs (NOT in git, reproducible)
├── tools/                     # Build tools & envs (NOT in git, rebuildable)
└── logs/                      # Execution logs (NOT in git)
```

## Workflow Repositories in `repos/`

Columns:
- **WMS** — the workflow management system the repo uses (how jobs are defined and orchestrated).
- **Domain** — scientific domain.
- **Single-node (`small/`)** — whether the workflow completes end-to-end on a single node with the test data.
- **Multi-node (2n/4n)** — whether validated multi-node runs produce real outputs at 2-node and 4-node scales on Ares.
- **Notes** — active blockers or fix-forward files.

Legend: ✅ PASS · ⚠️ partial · ❌ blocked · — not applicable / not attempted

### 1. Currently in `repos/` (45 directories: 26 running, 19 dormant)

Status verified against `runs/<wf>/{small_,multinode_}{2,4}node/logs/timing.log` exit codes and outputs/ contents on 2026-05-04. **26 workflows have completed at least one multi-node run; 19 are cloned but not yet successfully run** (most of those landed in the 2026-04-29 expansion wave and haven't had a harness built yet).

| # | Repo | WMS | Domain | Single-node | Multi-node (2n / 4n) | Notes |
|---|---|---|---|---|---|---|
| 1 | 1000genome-workflow | Pegasus | Genomics | — | ❌ / ❌ | `pegasus-plan` not installed on Ares; small_{2,4}node dirs scaffolded but 0 outputs |
| 2 | biobb_wf_md_setup | Python (biobb library) | Molecular dynamics | ✅ | ✅ / ✅ | Multi-node via GNU-parallel over 8 PDB inputs per node. gmx not traced under LD_PRELOAD libmonitor |
| 3 | chipseq | Snakemake | ChIP-seq | ❌ | — / — | Test FASTQs missing from `.test/`; needs `--use-conda` + conda ≥24.7.1 |
| 4 | DeepDriveMD-pipeline | RADICAL-EnTK | ML-driven MD | ⚠️ (dry_run only) | ⚠️ / ⚠️ | Needs RabbitMQ broker; EnTK assumes it's available. multinode dirs populated (42/64 files) |
| 5 | dna-seq-gatk-variant-calling | Snakemake | Variant calling | ❌ | — / — | Wrapper cache git parse error; tools missing (needs `--use-conda` + conda ≥24.7.1) |
| 6 | dna-seq-varlociraptor | Snakemake | Variant calling | ❌ | — / — | Upstream Snakefile syntax (`f-string: unmatched '`); needs upstream commit bump or Python 3.12+ |
| 7 | metaGEM | Snakemake | Metagenomics | ✅ | ✅ / ✅ | `run_slurm.fix1.sh` sibling required (Python-based config path rewrite + envs/ symlink; original `sed` approach was broken) |
| 8 | Montage | Shell/C (compiled tools) | Astronomy | ✅ | ✅ / ✅ | Mosaic produced byte-exact across runs |
| 9 | nf-core_airrflow | Nextflow (DSL2) | B/T-cell receptor seq | TBD | ❌ / ❌ | Cloned 2026-04-29; small_4node scaffolded, no successful run yet |
| 10 | nf-core_ampliseq | Nextflow (DSL2) | Amplicon seq | ✅ | ✅ / ✅ | 2n=496s 4n=2005s, 1608/1603 files. Previously listed as removed; re-cloned and now passes |
| 11 | nf-core_atacseq | Nextflow (DSL2) | ATAC-seq | ⚠️ | ⚠️ / — | 2n=658s (fix1 variant), 185M outputs but EXIT_CODE=1; 4-node not yet attempted |
| 12 | nf-core_bacass | Nextflow (DSL2) | Bacterial assembly | ✅ | ✅ / ✅ | 2n=2231s 4n=1747s, 130M/127M outputs (busco, Prokka, QUAST, Unicycler) |
| 13 | nf-core_circdna | Nextflow (DSL2) | Circular DNA | TBD | ❌ / ❌ | Cloned 2026-04-29; not yet run successfully |
| 14 | nf-core_clipseq | Nextflow (DSL2) | CLIP-seq | TBD | ❌ / ❌ | Cloned 2026-04-29; not yet run successfully |
| 15 | nf-core_createtaxdb | Nextflow (DSL2) | Taxonomy DB | TBD | ❌ / ❌ | Cloned 2026-04-29; not yet run successfully |
| 16 | nf-core_cutandrun | Nextflow (DSL2) | CUT&RUN / CUT&Tag | ✅ | ✅ / ✅ | 2n=881s 4n=797s, 324/316 files. Earlier DSL2 bug at `modules/local/for_patch/trimgalore/main.nf:18` resolved |
| 17 | nf-core_deepvariant | Nextflow (DSL2) | Variant calling | TBD | ❌ / ❌ | Cloned 2026-04-29; not yet run successfully |
| 18 | nf-core_demultiplex | Nextflow (DSL2) | NGS demultiplexing | ⚠️ | ⚠️ / — | 2n=38s, EXIT_CODE=1, only 7 files |
| 19 | nf-core_detaxizer | Nextflow (DSL2) | Host decontamination | ✅ | ✅ / ✅ | 2n=781s 4n=238s, 71/71 files |
| 20 | nf-core_differentialabundance | Nextflow (DSL2) | Differential abundance stats | ✅ (patched) | ✅ / ✅ | Local patch (`patches/nf-core_differentialabundance.patch`) fixes 6 module `main.nf` files from relative to absolute conda paths. 2n=2030s 4n=500s |
| 21 | nf-core_dualrnaseq | Nextflow (DSL2) | Dual host/pathogen RNA-seq | TBD | ❌ / ❌ | Cloned 2026-04-29; not yet run successfully |
| 22 | nf-core_fetchngs | Nextflow (DSL2) | SRA/ENA fetch | ✅ | ✅ / ✅ | Canonical working template for all nf-core pipelines on Ares |
| 23 | nf-core_funcscan | Nextflow (DSL2) | Functional annotation | ✅ | ✅ / ✅ | 2n=2601s 4n=1167s, 791/791 files |
| 24 | nf-core_genomeqc | Nextflow (DSL2) | Genome QC | TBD | ❌ / ❌ | Cloned 2026-04-29; not yet run successfully |
| 25 | nf-core_hic | Nextflow (DSL2) | Hi-C | ⚠️ fix2 | ⚠️ / — | fix2 (`cooler=0.8.11 pandas=1.3`) unblocks COOLER_CLOAD; cooltools + MULTIQC downstream need triangulated version pins (fix4 target) |
| 26 | nf-core_mag | Nextflow (DSL2) | Metagenome assembly | ✅ | ✅ / ✅ | Prior Java 11 block resolved by JDK17. 2n=1538s 4n=1098s, 2100/2095 files |
| 27 | nf-core_methylseq | Nextflow (DSL2) | Bisulfite sequencing | ✅ | ✅ / ✅ | |
| 28 | nf-core_mhcquant | Nextflow (DSL2) | MHC peptide quant | TBD | ❌ / ❌ | Cloned 2026-04-29; not yet run successfully |
| 29 | nf-core_nascent | Nextflow (DSL2) | Nascent transcription | ✅ | ✅ / ✅ | 2n=2297s 4n=481s, 347/347 files |
| 30 | nf-core_pathogensurveillance | Nextflow (DSL2) | Pathogen surveillance | ✅ | ✅ / ✅ | 2n=1591s 4n=911s, 16/11 files (small dataset) |
| 31 | nf-core_proteinfold | Nextflow (DSL2) | Protein folding | ✅ | ✅ / ✅ | 2n=420s 4n=94s, 20/20 files |
| 32 | nf-core_quantms | Nextflow (DSL2) | Proteomics quantification | ⚠️ | ⚠️ / — | 2n=764s, EXIT_CODE=1, 126 files; 4-node not yet attempted |
| 33 | nf-core_rnaseq | Nextflow (DSL2) | Bulk RNA-seq | ✅ | ✅ / ✅ | Harness built 2026-04-21 |
| 34 | nf-core_sarek | Nextflow (DSL2) | Variant calling | ✅ | ✅ / ✅ | 2n=475s 4n=546s, 187/182 files. Previously listed as removed; re-cloned |
| 35 | nf-core_scnanoseq | Nextflow (DSL2) | Single-cell nanopore | TBD | ❌ / ❌ | Cloned 2026-04-29; not yet run successfully |
| 36 | nf-core_scrnaseq | Nextflow (DSL2) | Single-cell RNA-seq | ❌ | — / — | UPSTREAM_BLOCKED: CELLRANGERARC_COUNT module does not support conda — requires Docker / Singularity / Podman (not available on Ares) |
| 37 | nf-core_smrnaseq | Nextflow (DSL2) | small RNA-seq (miRNA) | ✅ (5 fixes + patch) | ✅ / ✅ | mirtop 0.4.30 bytes/str bug patched in `patches/mirtop_do_py_str_bytes.patch`; fix1–fix6 resolve 9 `pkg_resources` cases. 2n=492s 4n=491s, 224/224 files. Earlier DATATABLE_MERGE failure resolved |
| 38 | nf-core_spatialvi | Nextflow (DSL2) | Spatial transcriptomics | TBD | ❌ / ❌ | Cloned 2026-04-29; not yet run successfully |
| 39 | nf-core_taxprofiler | Nextflow (DSL2) | Metagenomic taxonomy | ✅ | ✅ / ✅ | 2n=2098s 4n=634s, 549M outputs (22 tool dirs: bbduk, bowtie2, bracken, centrifuge, diamond, fastp, fastqc, ganon, kaiju, kmcp, kraken2, krona, melon, metacache, metaphlan, multiqc, nanoq, nonpareil, porechop_abi, samtools, sylph, taxpasta) |
| 40 | nf-core_tumourevo | Nextflow (DSL2) | Tumour evolution | TBD | ❌ / ❌ | Cloned 2026-04-29; not yet run successfully |
| 41 | nf-core_viralintegration | Nextflow (DSL2) | Viral integration | TBD | ❌ / ❌ | Cloned 2026-04-29; small_2node has 1 file only |
| 42 | nf-core_viralrecon | Nextflow (DSL2) | Viral genomics | ✅ | ✅ / ✅ | 2n=763s 4n=701s, 708/693 files. Previously listed as removed; re-cloned |
| 43 | PyFLEXTRKR | Python (dask-mpi) | Convective cloud tracking | ✅ | ✅ / ✅ | Uses dask-mpi; NetCDF4 I/O (HDF5-backed, so DaYu applies) |
| 44 | rna-seq-star-deseq2 | Snakemake | RNA-seq differential expression | ✅ | ✅ (PASS=2/2) / ✅ (PASS=4/4) | Per-replica input isolation via `cp -rs` works; conda-HTTP transients recovered by snakemake rerun-incomplete |
| 45 | V-pipe | Snakemake | Viral genomics | ✅ | ✅ / ⚠️ (3/4) | 4-node: 3 replicas hit snakemake gunzip race on shared inputs (workflow-level, not profiler) |

### 2. Tier-D deferred (not in `repos/`, blocked upstream)

| Repo | WMS | Blocker |
|---|---|---|
| nf-core_eager | Nextflow (DSL1) | Nextflow DSL1 deprecated; upstream only. Not currently cloned |
| iwc | Galaxy | Galaxy runtime not installed on Ares. Not currently cloned (prior runs exist under `runs/iwc/`) |

### 3. Archived (reference only, not submodules)

| Repo | URL | Purpose |
|---|---|---|
| lammps | https://github.com/lammps/lammps | Molecular dynamics simulator |
| nwchem | https://github.com/nwchemgit/nwchem | Computational chemistry |
| parsl | https://github.com/Parsl/parsl | Parallel scripting library |
| pegasus | https://github.com/pegasus-isi/pegasus | Workflow management system |
| PtychoNN | https://github.com/mcherukara/PtychoNN | Neural network ptychography |
| radical.pilot | https://github.com/radical-cybertools/radical.pilot | HPC pilot framework |

## Multi-node runs directory convention

Each workflow's `runs/<wf>/` may contain any of:
- `small/` — single-node baseline
- `medium/` — larger single-node
- `small_2node/` + `small_4node/` — **nf-core style**: single Nextflow driver on 1 node, child tasks fan out via SLURM executor (see `runs/nf-core_shared/slurm.config`)
- `multinode_2node/` + `multinode_4node/` — **Snakemake/non-nf-core style**: N exclusive `srun` replicas fan-out, each with its own `workdir_node${i}/`

Fix-forward scripts live alongside originals as `run_slurm.fix<N>.sh` (never overwrite).

## Quick Start

```bash
# Clone with submodules
git clone --recurse-submodules <repo-url>
cd hpc_workflows

# Apply included patches (if starting from the base clone)
for p in patches/*.patch; do
  wf=$(basename "$p" .patch)
  if [ -d "repos/$wf" ]; then
    cd "repos/$wf" && git apply "../../patches/$(basename $p)" && cd ../..
  fi
done

# Download test data (requires internet)
bash scripts/download_inputs.sh
```

## Cluster Requirements (Ares)

- **Scheduler:** SLURM (partitions: `compute`, `datacrumbs`, `debug`)
- **Nodes:** 40 CPUs, ~47 GB RAM each, 26–29 usable per partition
- **Java:** 17 (Temurin 17.0.13+11) installed at `tools/java17/jdk-17.0.13+11` — supports Nextflow 25.x
- **Conda:** Miniconda at `/mnt/common/mtang11/miniconda3`
- **No Docker or Singularity** available — use `-profile conda` for nf-core pipelines
- **Nextflow shared cache:** `runs/nf-core_shared/` (conda_cache, nf_home, slurm.config)

## Known cluster-wide gotchas

- `-profile test,conda` is the canonical nf-core configuration; do not rely on `docker`/`singularity` profiles.
- Shell-special chars in `process.conda` directives (`<`, `>`) are parsed by bash before conda sees them — always use exact version pins (`=69`, not `<70`).
- Recent conda-forge `setuptools` (≥74) no longer bundles `pkg_resources` (PEP 632); nf-core pipelines that use older Python tooling (seqcluster, mirtop, mirdeep2, multiqc, umi_tools in smrnaseq) need explicit `conda-forge::setuptools=69` pins in per-process overrides.
- Nextflow SLURM executor in `slurm.config` caps concurrent sbatch submissions via `NXF_MAX_FORKS` — set to 80 for 2-node, 160 for 4-node.

## Related documentation

- [AGENT_GUIDE.md](AGENT_GUIDE.md) — full agent-oriented recreation guide
- `docs/catalog.tsv` — repo-to-URL mapping
- `docs/phase6_results.tsv` — PHASE6 execution results
- `summaries/<workflow>_PHASE6_SUMMARY.txt` — per-workflow PHASE6 report
- `runs/nf-core_shared/slurm.config` — Nextflow SLURM executor config

## Recent multi-node deployment passes

- **2026-04-15 to 2026-04-21**: Profiling infrastructure validation. Montage, V-pipe, biobb, PyFLEXTRKR qualified for DataLife/DaYu/Darshan profiling.
- **2026-04-21 (afternoon)**: `rna-seq-star-deseq2`, `nf-core_rnaseq`, and `metaGEM` graduated to multi-node-ready. Five more nf-core workflows scaffolded (bacass, differentialabundance, hic, scrnaseq, taxprofiler) pending first run.
- **2026-04-21 to 2026-04-29 (expansion wave)**: 25 additional nf-core repos cloned. New successful 2n+4n runs: ampliseq, cutandrun, detaxizer, funcscan, mag, nascent, pathogensurveillance, proteinfold, sarek, viralrecon (10). Partial (2n only / EXIT_CODE=1): atacseq, demultiplex, hic, quantms. Cloned but not yet successfully run: airrflow, circdna, clipseq, createtaxdb, deepvariant, dualrnaseq, genomeqc, mhcquant, scnanoseq, spatialvi, tumourevo, viralintegration. ampliseq/sarek/viralrecon (previously listed as removed) are back and passing.
- **2026-05-04 audit**: 26/45 active workflows have completed multi-node runs.
- Logs: `runs/**/logs/timing.log` (per-workflow). Cross-workflow journal: `../paper_widget/notes/multinode_deployment_status_2026-04-21.md`.
