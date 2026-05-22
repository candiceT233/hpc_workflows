# Scale-up workflows — deployment TODO (PNNL Deception)

Workflows that scale to many processes/nodes (the PyFLEXTRKR class) but are **not yet
deployed** in this repo (no submodule, no `runs/<wf>/` script, no input). Goal: deploy
each, then profile at scale with widget (**DataLife/DaYu**) **+ Darshan**.

**Template:** PyFLEXTRKR (#43) is the proven pattern — Class B dask-MPI, validated to the
full 962-file scale (80 nodes / 240 workers, all 9 stages, VOL 102/102). See
`runs/PyFLEXTRKR/scale_dayu/` (launcher `run_dayu_saag.sbatch`, configs `cfg_*.yml`) and
`log.md` (2026-05-20/21). DaYu source fixes upstreamed to `grc-iit/dayu`
(`fix/vol-stat-finalize-on-teardown`); local backup `patches/widget/dayu_scale_fixes.patch`.

**Scheduling reminders (learned from PyFLEXTRKR):** account `oddite` (datamesh frozen);
partition `slurm`; cluster `module load openmpi/5.0.7` + `mpirun` (srun lacks pmix);
`--mca pml ob1 --mca osc ^ucx` (conda UCX 1.14.1 is broken); pin `--prtemca oob_tcp_if_include eno1`
at high node counts; dask single-scheduler caps ~256–300 workers (96×10 overwhelmed it).

| # | Workflow | What it is / scaling | Max procs | Profiler fit | Setup status | Effort |
|---|---|---|---|---|---|---|
| 49 | **nwchem** | MPI computational chemistry (Global Arrays) | thousands of ranks | Darshan (libmonitor risky on big Fortran bin; DaYu N/A unless HDF5 output) | **binary ready**: `module load nwchem/7.2.3` (MPI vs openmpi 5.0.7, `/share/apps/nwchem/7.2.3/bin/nwchem`) | **LOW** — needs input deck + Class-B mpirun launcher |
| 48 | **lammps** | MPI molecular dynamics | thousands of ranks (needs ≥1M-atom box) | Darshan only (libmonitor FPEs on `lmp`); DaYu N/A | conda-forge is **nompi** only → MPI build from source | **HIGH** — source build (GA/MPI) + big problem |
| 50 | **parsl** | Python parallel-scripting framework (HighThroughputExecutor) | hundreds–thousands workers | Darshan/DataLife (on the task payload) | `pip install parsl` (not in base) | **MED** — install + define a workload + SLURM provider |
| 53 | **radical.pilot** | HPC pilot framework (massive task throughput) | thousands of tasks | Darshan (task payload) | `pip install radical.pilot` (not in base); historically needs MongoDB | **MED–HIGH** — framework setup + workload |
| 51 | **pegasus** | Workflow mgmt (HTCondor/DAGMan) | many tasks across nodes | Darshan/DataLife (task payload) | **partly installed**: `/people/tang584/install/pegasus-5.0.5`; needs HTCondor + a DAG | **MED** — verify HTCondor, build a workflow |
| 52 | **PtychoNN** | GPU deep-learning ptychography (PyTorch) | GPU/data-parallel (not CPU-MPI) | Darshan/DataLife; **DaYu likely** (ptycho data is often HDF5/.cxi) | GPU partitions exist (`dl`,`a100`,`h100`); needs PyTorch env + data | **MED** — GPU env + data; different (GPU) axis |
| — | **GenoMAS** (Liu-Hy/GenoMAS) | LLM multi-agent genomics; `multiprocessing` over cohorts | ~2–N cohorts, **API-rate-limited (not CPU/MPI)** | Darshan/DataLife (CSV/POSIX, light) | `pip install -r requirements.txt` + LLM API keys (.env) or Ollama + ~42 GB GenoTEX data | **MED** — not an HPC rank-scaler; API-bound. Explored at `../GenoMAS_explore` |

## Per-workflow deploy steps

### nwchem (#49) — lowest effort, do first when ready
1. `module load nwchem/7.2.3` (binary ready, MPI vs openmpi 5.0.7).
2. Write an input deck (`.nw`). **Method sets the I/O volume:** direct DFT ≈ MB (too light);
   **conventional SCF/DFT** (disk 2e-integrals) ≈ tens of GB; **MP2** ≈ GBs–10s GB;
   **CCSD(T)** ≈ 10s GB–TB (best for I/O profiling; per-rank scratch scales with ranks).
3. Class-B launcher: `mpirun -n <ranks> nwchem deck.nw` (clone PyFLEXTRKR's mpirun MCA flags).
   Set NWChem `scratch_dir`/`permanent_dir` to node-local `/scratch` + collect.
4. Profiler: Darshan (POSIX). Try DataLife cautiously (may FPE like lammps).

### lammps (#48)
- conda-forge has only **nompi** builds → for multi-rank scaling, build MPI LAMMPS from
  source (or find an MPI module). Use ≥1M-atom LJ-melt so ranks aren't comm-starved.
- Profiler: **Darshan only** (libmonitor FPEs on `lmp`).

### parsl / radical.pilot / pegasus
- These are *frameworks* — need a representative workload (e.g., a fan-out of file-I/O tasks)
  to profile. parsl: pip + SlurmProvider/HighThroughputExecutor. pegasus: 5.0.5 installed,
  verify HTCondor + build a sample DAG. radical.pilot: pip + check MongoDB-free mode.

### PtychoNN (#52)
- GPU workflow (PyTorch) on `dl`/`a100`/`h100`. Build env + obtain ptychography data
  (often HDF5/.cxi → DaYu-relevant). Scaling is GPU/data-parallel, not CPU-MPI.

### GenoMAS
- LLM-agent; not an HPC rank-scaler (API-bound). If pursued: pip + .env keys (or local Ollama),
  download ~42 GB GenoTEX, run `python main.py --parallel-mode cohorts --max-workers N`.
  Profile the agent-executed pandas code's CSV I/O with Darshan/DataLife.

## Status
- ✅ PyFLEXTRKR (#43) — deployed + validated 6/48/480/962 files (DaYu VOL+VFD).
- ⬜ Above 7 — not yet deployed (this list).
