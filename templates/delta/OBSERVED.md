# Delta validation runs — observed results

First validation pass on 2026-05-13.

## Setup as tested

- Cluster: NCSA Delta, SLURM 25.11.1, partition `cpu-preempt`, account `bekn-delta-cpu`
- Per-job: 1 node × 32 CPUs × 64 GB × 1.5 h wall
- Nextflow: pinned `NXF_VER=25.10.5`
- Container runtime: Apptainer 1.4.2 (system-wide)
- libmonitor.so md5: `8e53079b4c8714110591ab215e010d00` (delta-port-gcc13-cstdint build)
- libdarshan.so md5: `a2ac5f2f60f266a13283a7066b06a4ed` (darshan 3.5.0 + Cray-MPICH, NONMPI enabled)

## Results

| Run | Job ID | State | Wall | Exit | Pipeline | Traces | SU |
|---|---|---|---|---|---|---|---|
| methylseq DL (host LD_PRELOAD + MONITOR_UNSET_LIB) | 18224472 | COMPLETED | 1:49 | 0 | 36/36 | **0** | 0.4 |
| methylseq DH (host LD_PRELOAD) | 18224838 | COMPLETED | 1:46 | 0 | 36/36 | **0** | 0.4 |
| methylseq DL (`--env LD_PRELOAD` via singularity.runOptions, no MONITOR_UNSET) | 18224998 | FAILED | 0:09 | 139 (SIGSEGV) | n/a | n/a | 0.04 |
| methylseq DL (`--env LD_PRELOAD` only, no host LD_PRELOAD) | 18225081 | PREEMPTED | 32:41 | n/a | failed @ FASTQC 127 | **22** at preempt | 8.7 |

Earlier exploratory failures not included above (Nextflow parser issues for the
26.04 → 25.10.5 pin, methylseq 2.7.0 → 4.2.0 upgrade, etc).

## Conclusions

- Pipeline-level toolchain works: Delta + Nextflow 25.10.5 + Apptainer +
  nf-core/methylseq 4.2.0 runs end-to-end in ~2 min on test profile.
- Host-side `LD_PRELOAD` produces zero traces because Apptainer isolates the
  container env namespace. Either form (`MONITOR_UNSET_LIB=1` keeping the JVM
  stable, or no-unset crashing the JVM with SIGSEGV) is unproductive.
- `singularity.runOptions = '--env LD_PRELOAD=...'` + `--bind /scratch/bekn/mtang9`
  does inject the preload into containers. libmonitor.so loaded successfully on
  trim-galore + Bismark workers (22 traces collected before preemption).
- However, FASTQC containers exit 127 — symptomatic of dynamic-linker failing
  to resolve libmonitor.so symbols against the container's older glibc. Pipeline
  fails at the first FASTQC step. This is a per-container-image issue, not
  global.
- Darshan likely has the same ABI issue against the same containers, but only
  the methylseq DL path was retested with the `--env` pattern. The committed
  darshan template uses the same pattern; behaviour to be verified.

## Workarounds to try next

1. Build libmonitor.so / libdarshan.so against an older glibc inside a
   debian:bullseye chroot or builder container, so .so is compatible with
   BioContainer base images.
2. Use Nextflow `process.withName` selectors to skip LD_PRELOAD for problematic
   containers (FASTQC) while keeping it for the rest.
3. Switch to `-profile conda` for an Apptainer-free run path; requires
   Miniconda installed under `/scratch/bekn/mtang9/`.

## Total SU spent on this pass

~10 SU across 5 jobs (2 successful pipeline runs + 3 failed/preempted).
Live balance at end of session: ~172 / 6005 deposited on bekn-delta-cpu.
