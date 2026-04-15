# Archived Workflows

Workflows that were triaged in Phase 1/2 but moved to `archive/` after Phase 5
failures. Not in scope for the current benchmark campaign. Per-repo rationale
lives in each `archive/<repo>/TRIAGE_REASON.txt`.

Last updated: 2026-04-15

## Upstream-broken (workflow code or pinned deps incompatible with current tooling)

| Repo | Reason |
|---|---|
| `chipseq` (snakemake-workflows) | Snakemake 9 refuses old wrapper URLs (`/raw/0.72.0/bio/fastqc`). |
| `dna-seq-gatk-variant-calling` | `pandas.squeeze(...)` kwarg removed in pandas 2.x; `None\|type` runtime bug in wrapper. |
| `dna-seq-varlociraptor` | Python 3.12 PEP 701 rejects nested quotes in f-string at `mapping.smk:207`. |
| `nf-core_chipseq` | Upstream test samplesheet URLs now 404. |
| `nf-core_atacseq` | Same upstream test-datasets 404 as nf-core_chipseq. |
| `nf-core_eager` | DSL1-only; Nextflow 25 dropped DSL1. |
| `nf-core_ampliseq` | Pipeline failed late after conda solves; partial 3.2 MB output. |
| `nf-core_viralrecon` | R reshape2/stringi conda env missing `libicui18n.so.58`; 153 MB partial. |
| `nf-core_sarek` (partial) | Core analysis PASS (55 MB); fails only at MULTIQC (`rich.panel` AttributeError). |

## Platform missing on Ares

| Repo | Reason |
|---|---|
| `iwc` | Requires a running Galaxy server. Each entry is a Galaxy tool wrapper, not a single cohesive shell-translatable workflow. |

## Revived 2026-04-15 (moved back to `repos/`)

| Repo | Why revived |
|---|---|
| `1000genome-workflow` | Pegasus DAX is just a task graph over plain Python scripts (`bin/individuals.py`, `sifting.py`, `mutation_overlap.py`, `frequency.py`); will be driven by a shell DAG instead of Pegasus WMS. |
| `nf-core_mag` | Was never attempted in Phase 6 — no upstream-bug evidence, just a time-budget defer. |

## Working workflows (remaining in `repos/`)

1. `Montage`
2. `biobb_wf_md_setup`
3. `PyFLEXTRKR`
4. `V-pipe`
5. `metaGEM`
6. `DeepDriveMD-pipeline`
7. `rna-seq-star-deseq2`
8. `nf-core_rnaseq`

See `ASA_UPLOAD_STATUS.md` for the container-packaged subset (7 of 8) pushed to
`grc-iit/awesome-scienctific-applications#candice-workflows`.
