# Scaling-potential assessment — "can it blow up the scale like PyFLEXTRKR?"

Base: `MULTINODE_AUDIT_2026-05-18.md` (Ares, ≤24n) + `logs/nf_{concurrency,parallelism}_2026-05-18.tsv`,
re-projected onto **PNNL Deception** (`slurm` partition = **271 nodes, 64 cores/node**).
Reference: PyFLEXTRKR validated to **962 files / 240 workers / 80 nodes / 9 stages** (dask-MPI).

## What sets the ceiling (3 regimes)
- **Class B (MPI / dask-MPI) — UNBOUNDED**, scale is problem/data-driven. The true "blow up" class.
- **Class A (ensemble / fan-out) — 1 task/node**, bounded by input units, but **cheap inputs → blow up by adding units**.
- **Class C (nf-core / Nextflow) — bounded by the DAG**: peak concurrency ≈ **28–30 tasks max** (can't blow up beyond ~18 nodes).

## Per-workflow scaling table (PNNL numbers)

| Workflow | Class | Parallel unit | What bounds it | **Max useful scale on PNNL** | Profiler | PNNL-deployed? |
|---|---|---|---|---|---|---|
| **PyFLEXTRKR** | B dask-MPI | timesteps→workers | data + dask scheduler (~300 workers) | **DONE**: 962 files, 240 workers, 80n | DaYu+Darshan | ✅ |
| **lammps** | B MPI | atoms→ranks | problem size (**unbounded**) | **~270n × 64 = ~17K ranks** w/ proportional box (4M atoms→~960 ranks healthy; ~68M→~17K) | Darshan only (libmonitor FPE) | ❌ source build |
| **DeepDriveMD** | A ensemble | replica MD sims | replica count (**cheap: bump `n_replicas`**) | **up to ~270 replicas / 270 nodes** (1 sim/node) | DataLife/**DaYu**+Darshan | ✅ (PNNL dirs incl. `*ddmd+volvfd`) |
| **Montage** | A fan-out | FITS tiles | tile count (**cheap: add 2MASS tiles**) | **up to ~270 tiles / 270 nodes** | DataLife+Darshan | ❌ deploy |
| **biobb_wf_md_setup** | A fan-out | PDBs | PDB count (cheap: curate PDBs) | up to ~270 PDBs / 270 nodes | DataLife+Darshan | ❌ deploy |
| **metaGEM** | A fan-out | samples | 12 (more = synthetic) | ~12 nodes | DataLife+Darshan | ❌ deploy |
| **rna-seq-star-deseq2** | A fan-out | sample pairs | 5 | ~5 nodes | DataLife+Darshan | ❌ deploy |
| **nf-core_smrnaseq / taxprofiler / rnaseq** | C NF | DAG tasks | peak ~28–30 | **~14–18 nodes** (peak ≤30 tasks) | DataLife+Darshan | ❌ deploy |
| other nf-core | C NF | DAG tasks | peak 2–22 | sweet 1–12n (see audit §13) | DataLife+Darshan | ❌ deploy |
| **1000genome** | F→rework | genome chunks | repo script uses **1 node** (Class F) | needs rework to actually fan out | DataLife+Darshan | ✅ (script is 1-node) |

## "Blow up the scale" ranking (biggest → smallest potential)
1. **lammps** — unbounded MPI; PNNL could hit ~10K–17K ranks with a big enough box. *Biggest* potential, but needs a from-source MPI build + bigger box.
2. **PyFLEXTRKR** — done (dask-MPI; data-bounded at 962 files, worker-bounded ~300 by the dask scheduler).
3. **DeepDriveMD** — ensemble; bump replicas to fill **any** node count (96, 240, ~270). Cheap, and **already deployed + DaYu(volvfd)-wired on PNNL** → the easiest large-node-count run available now.
4. **Montage / biobb** — cheap fan-out to hundreds of nodes (add tiles / PDBs), but need PNNL deployment.
5. **nf-core (smrnaseq/taxprofiler/rnaseq)** — capped at ~30 tasks / ~18 nodes by the DAG. Moderate.
6. **metaGEM (12) / rna-seq (5) / V-pipe (2)** — small natural ceilings.

## Recommendation for "next"
- **Easiest big run now:** **DeepDriveMD** — already on PNNL with DaYu (`*ddmd+volvfd` dirs), pure ensemble → set replicas = your node count (e.g., 96 or 240) for an instant high-node-count + DaYu I/O run. (Caveat: replicas are identical → it's a redundancy/I/O-scaling benchmark, not 240× distinct science.)
- **Biggest blow-up (more setup):** **lammps** — source build + ≥4M-atom box → thousands of MPI ranks; true HPC strong-scaling, Darshan profiling.
- **Cheap fan-out (needs deploy):** **Montage** — tile-parallel to hundreds of nodes.
