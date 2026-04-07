#!/usr/bin/env python3
"""
Direct execution runner for the 1000genome-workflow.
Executes the workflow tasks in dependency order with parallelism.
"""

import csv
import os
import shutil
import subprocess
import sys
import time
from concurrent.futures import ProcessPoolExecutor, as_completed
from pathlib import Path

LOCK_FILE = None  # For thread-safe logging

def log(msg, logfile=None):
    ts = time.strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{ts}] {msg}"
    print(line, flush=True)
    if logfile:
        with open(logfile, "a") as f:
            f.write(line + "\n")


def run_task(cmd, work_dir, task_name, logfile=None, timeout=14400):
    """Run a single task, return (task_name, success, elapsed, error_msg)."""
    log(f"  START: {task_name}", logfile)
    start = time.time()
    try:
        result = subprocess.run(
            cmd, cwd=work_dir, capture_output=True, text=True, timeout=timeout,
        )
        elapsed = time.time() - start
        if result.returncode != 0:
            log(f"  FAILED: {task_name} (rc={result.returncode}, {elapsed:.1f}s)", logfile)
            err_msg = result.stderr[:2000] if result.stderr else result.stdout[-1000:]
            log(f"    error: {err_msg[:500]}", logfile)
            return task_name, False, elapsed, err_msg
        else:
            log(f"  OK: {task_name} ({elapsed:.1f}s)", logfile)
            return task_name, True, elapsed, None
    except subprocess.TimeoutExpired:
        elapsed = time.time() - start
        log(f"  TIMEOUT: {task_name} ({elapsed:.1f}s)", logfile)
        return task_name, False, elapsed, "TIMEOUT"
    except Exception as e:
        elapsed = time.time() - start
        log(f"  ERROR: {task_name}: {e}", logfile)
        return task_name, False, elapsed, str(e)


def run_workflow(scale, data_dir, data_csv, work_dir, output_dir, log_dir, logfile,
                 bin_dir, ind_jobs=10, timeout=14400, max_workers=4):
    """Execute the 1000genome workflow with parallel task execution."""
    os.makedirs(work_dir, exist_ok=True)
    os.makedirs(output_dir, exist_ok=True)
    os.makedirs(log_dir, exist_ok=True)

    log(f"=== Starting {scale} workflow ===", logfile)
    log(f"  data_dir: {data_dir}", logfile)
    log(f"  work_dir: {work_dir}", logfile)
    log(f"  ind_jobs: {ind_jobs}, max_workers: {max_workers}", logfile)

    overall_start = time.time()
    task_results = {}
    python = sys.executable

    # Parse data.csv
    chromosomes = []
    with open(data_csv, "r") as f:
        for row in csv.reader(f):
            chromosomes.append({
                "vcf": row[0], "threshold": int(row[1]), "annotation": row[2],
            })

    pop_dir = os.path.join(data_dir, "populations")
    populations = sorted(os.listdir(pop_dir))
    log(f"  Chromosomes: {len(chromosomes)}, Populations: {populations}", logfile)

    # Symlink all needed files into work_dir
    dataset_dir = os.path.join(data_dir, "20130502")
    columns_dst = os.path.join(work_dir, "columns.txt")
    if not os.path.exists(columns_dst):
        os.symlink(os.path.join(dataset_dir, "columns.txt"), columns_dst)

    for pop in populations:
        dst = os.path.join(work_dir, pop)
        if not os.path.exists(dst):
            os.symlink(os.path.join(pop_dir, pop), dst)

    for chrom in chromosomes:
        for fname in [chrom["vcf"], chrom["annotation"]]:
            dst = os.path.join(work_dir, fname)
            if not os.path.exists(dst):
                src = os.path.join(dataset_dir, fname)
                if not os.path.exists(src):
                    src = os.path.join(dataset_dir, "sifting", fname)
                os.symlink(src, dst)

    # Extract chromosome numbers
    for chrom in chromosomes:
        vcf = chrom["vcf"]
        c_num = vcf[vcf.find("chr") + 3:]
        c_num = c_num[0:c_num.find(".")]
        chrom["c_num"] = c_num

    # ========================================
    # PHASE 1: Run individuals + sifting in parallel
    # All individuals tasks for all chromosomes can run in parallel
    # Sifting tasks are independent and can also run in parallel
    # ========================================
    log("--- Phase 1: Individuals + Sifting (parallel) ---", logfile)

    phase1_tasks = []  # (cmd, work_dir, task_name)

    for chrom in chromosomes:
        c_num = chrom["c_num"]
        threshold = chrom["threshold"]
        jobs = min(ind_jobs, threshold)
        step = threshold // jobs
        if threshold % jobs != 0:
            log(f"  Adjusting ind_jobs for chr{c_num}: {jobs} -> 1", logfile)
            jobs = 1
            step = threshold

        counter = 1
        ind_outputs = []
        while counter < threshold:
            stop = counter + step
            out_name = f"chr{c_num}n-{counter}-{stop}.tar.gz"
            ind_outputs.append(out_name)
            task_name = f"individuals_chr{c_num}_{counter}_{stop}"
            cmd = [python, os.path.join(bin_dir, "individuals.py"),
                   chrom["vcf"], c_num, str(counter), str(stop), str(threshold)]
            phase1_tasks.append((cmd, work_dir, task_name))
            counter += step

        chrom["ind_outputs"] = ind_outputs

        # Sifting task
        task_name = f"sifting_chr{c_num}"
        cmd = [python, os.path.join(bin_dir, "sifting.py"), chrom["annotation"], c_num]
        phase1_tasks.append((cmd, work_dir, task_name))

    log(f"  Submitting {len(phase1_tasks)} Phase 1 tasks with {max_workers} workers", logfile)

    failed_critical = False
    with ProcessPoolExecutor(max_workers=max_workers) as executor:
        futures = {}
        for cmd, wd, tn in phase1_tasks:
            f = executor.submit(run_task, cmd, wd, tn, logfile, timeout)
            futures[f] = tn

        for future in as_completed(futures):
            tn, ok, elapsed, err = future.result()
            task_results[tn] = {"ok": ok, "elapsed": elapsed, "error": err}
            if not ok:
                log(f"  CRITICAL FAILURE: {tn}", logfile)
                failed_critical = True

    if failed_critical:
        log(f"  Phase 1 had failures, aborting {scale}", logfile)
        return False, {"tasks": task_results, "elapsed": time.time() - overall_start,
                       "failed_tasks": [k for k, v in task_results.items() if not v["ok"]],
                       "output_files": [], "critical_failures": [k for k, v in task_results.items() if not v["ok"]]}

    # ========================================
    # PHASE 1.5: Merge individuals (sequential per chromosome, can parallel across chromosomes)
    # ========================================
    log("--- Phase 1.5: Individuals Merge ---", logfile)

    merge_tasks = []
    for chrom in chromosomes:
        c_num = chrom["c_num"]
        task_name = f"individuals_merge_chr{c_num}"
        cmd = [python, os.path.join(bin_dir, "individuals_merge.py"), c_num] + chrom["ind_outputs"]
        merge_tasks.append((cmd, work_dir, task_name))

    with ProcessPoolExecutor(max_workers=max_workers) as executor:
        futures = {}
        for cmd, wd, tn in merge_tasks:
            f = executor.submit(run_task, cmd, wd, tn, logfile, timeout)
            futures[f] = tn

        for future in as_completed(futures):
            tn, ok, elapsed, err = future.result()
            task_results[tn] = {"ok": ok, "elapsed": elapsed, "error": err}
            if not ok:
                failed_critical = True

    if failed_critical:
        log(f"  Merge had failures, aborting {scale}", logfile)
        return False, {"tasks": task_results, "elapsed": time.time() - overall_start,
                       "failed_tasks": [k for k, v in task_results.items() if not v["ok"]],
                       "output_files": [], "critical_failures": [k for k, v in task_results.items() if not v["ok"]]}

    # ========================================
    # PHASE 2: Mutation Overlap + Frequency (parallel)
    # ========================================
    log("--- Phase 2: Mutation Overlap + Frequency (parallel) ---", logfile)

    phase2_tasks = []
    for chrom in chromosomes:
        c_num = chrom["c_num"]
        for pop in populations:
            task_name = f"mutation_overlap_chr{c_num}_{pop}"
            cmd = [python, os.path.join(bin_dir, "mutation_overlap.py"), "-c", c_num, "-pop", pop]
            phase2_tasks.append((cmd, work_dir, task_name))

            task_name = f"frequency_chr{c_num}_{pop}"
            cmd = [python, os.path.join(bin_dir, "frequency.py"), "-c", c_num, "-pop", pop]
            phase2_tasks.append((cmd, work_dir, task_name))

    log(f"  Submitting {len(phase2_tasks)} Phase 2 tasks with {max_workers} workers", logfile)

    with ProcessPoolExecutor(max_workers=max_workers) as executor:
        futures = {}
        for cmd, wd, tn in phase2_tasks:
            f = executor.submit(run_task, cmd, wd, tn, logfile, timeout)
            futures[f] = tn

        for future in as_completed(futures):
            tn, ok, elapsed, err = future.result()
            task_results[tn] = {"ok": ok, "elapsed": elapsed, "error": err}
            if not ok:
                log(f"  WARNING: {tn} failed", logfile)

    # ========================================
    # Collect outputs
    # ========================================
    log("--- Collecting outputs ---", logfile)
    output_files = []
    for f in os.listdir(work_dir):
        if f.endswith(".tar.gz") or f.startswith("sifted.SIFT."):
            src = os.path.join(work_dir, f)
            if os.path.isfile(src):
                dst = os.path.join(output_dir, f)
                if not os.path.exists(dst):
                    shutil.copy2(src, dst)
                    output_files.append(f)

    total_elapsed = time.time() - overall_start
    failed_tasks = [k for k, v in task_results.items() if not v["ok"]]
    critical_failures = [k for k in failed_tasks
                        if "individuals" in k or "sifting" in k or "merge" in k]

    log(f"=== {scale} workflow completed ===", logfile)
    log(f"  Total time: {total_elapsed:.1f}s ({total_elapsed/60:.1f}min)", logfile)
    log(f"  Tasks: {len(task_results)} total, {len(failed_tasks)} failed", logfile)
    log(f"  Output files: {len(output_files)}", logfile)
    if failed_tasks:
        log(f"  Failed: {failed_tasks}", logfile)

    success = len(critical_failures) == 0
    return success, {
        "tasks": task_results,
        "elapsed": total_elapsed,
        "output_files": output_files,
        "failed_tasks": failed_tasks,
        "critical_failures": critical_failures,
    }


def main():
    WORKFLOW_ROOT = "/mnt/common/mtang11/hpc_workflows"
    REPO = f"{WORKFLOW_ROOT}/repos/1000genome-workflow"
    DATA_BASE = f"{WORKFLOW_ROOT}/data/1000genome-workflow"
    RUN_BASE = f"{WORKFLOW_ROOT}/runs/1000genome-workflow"
    BIN_DIR = f"{REPO}/bin"
    RUNLOG = f"{WORKFLOW_ROOT}/logs/phase6/1000genome-workflow_phase6.log"

    os.makedirs(os.path.dirname(RUNLOG), exist_ok=True)

    # Determine available CPUs
    n_cpus = len(os.sched_getaffinity(0))
    # Use at most n_cpus - 1 workers, min 2
    max_workers = max(2, min(n_cpus - 1, 8))

    log("=" * 60, RUNLOG)
    log("1000genome-workflow Phase 6 Execution", RUNLOG)
    log(f"Available CPUs: {n_cpus}, Workers: {max_workers}", RUNLOG)
    log("=" * 60, RUNLOG)

    # Validate data
    for scale in ["small", "medium"]:
        ddir = os.path.join(DATA_BASE, scale)
        if not os.path.isdir(ddir):
            log(f"ERROR: Data directory missing: {ddir}", RUNLOG)
            sys.exit(1)
        total = sum(
            os.path.getsize(os.path.join(dp, f))
            for dp, dn, fnames in os.walk(ddir)
            for f in fnames
            if os.path.isfile(os.path.join(dp, f))
        )
        total_gb = total / (1024**3)
        log(f"  {scale} data: {total_gb:.2f} GB", RUNLOG)
        if total_gb > 50:
            log(f"ERROR: {scale} data exceeds 50 GB limit", RUNLOG)
            sys.exit(1)

    max_attempts = 3

    # ===== SMALL =====
    small_csv = f"{RUN_BASE}/small/data_small.csv"
    small_work = f"{RUN_BASE}/small/workdir_exec"
    small_out = f"{RUN_BASE}/small/outputs"
    small_log = f"{RUN_BASE}/small/logs"
    small_success = False
    small_summary = None

    for attempt in range(1, max_attempts + 1):
        log(f"\n*** SMALL scale - attempt {attempt}/{max_attempts} ***", RUNLOG)
        if os.path.exists(small_work):
            shutil.rmtree(small_work)

        # ind_jobs=5: with threshold=25000, each task handles 5000 records (~70 min)
        # 2 chroms * 5 tasks = 10 tasks, 8 workers => ~2 batches => ~140 min
        small_success, small_summary = run_workflow(
            scale="small",
            data_dir=f"{DATA_BASE}/small",
            data_csv=small_csv,
            work_dir=small_work,
            output_dir=small_out,
            log_dir=small_log,
            logfile=RUNLOG,
            bin_dir=BIN_DIR,
            ind_jobs=5,
            timeout=14400,
            max_workers=max_workers,
        )

        if small_success:
            log(f"SMALL scale succeeded on attempt {attempt}", RUNLOG)
            break
        else:
            log(f"SMALL scale failed on attempt {attempt}", RUNLOG)

    # ===== MEDIUM =====
    medium_success = False
    medium_summary = None

    if small_success:
        medium_csv = f"{RUN_BASE}/medium/data_medium.csv"
        medium_work = f"{RUN_BASE}/medium/workdir_exec"
        medium_out = f"{RUN_BASE}/medium/outputs"
        medium_log = f"{RUN_BASE}/medium/logs"

        for attempt in range(1, max_attempts + 1):
            log(f"\n*** MEDIUM scale - attempt {attempt}/{max_attempts} ***", RUNLOG)
            if os.path.exists(medium_work):
                shutil.rmtree(medium_work)

            # ind_jobs=10: with threshold=50000, each task handles 5000 records (~70 min)
            # 10 chroms * 10 tasks = 100 tasks, 8 workers => ~13 batches => ~910 min
            # Too many tasks. Use ind_jobs=5: 10 chroms * 5 = 50 tasks, 8 workers => ~7 batches => ~490 min
            # Still tight. But with 50000 threshold (not 250000), tasks are smaller.
            medium_success, medium_summary = run_workflow(
                scale="medium",
                data_dir=f"{DATA_BASE}/medium",
                data_csv=medium_csv,
                work_dir=medium_work,
                output_dir=medium_out,
                log_dir=medium_log,
                logfile=RUNLOG,
                bin_dir=BIN_DIR,
                ind_jobs=10,
                timeout=14400,
                max_workers=max_workers,
            )

            if medium_success:
                log(f"MEDIUM scale succeeded on attempt {attempt}", RUNLOG)
                break
            else:
                log(f"MEDIUM scale failed on attempt {attempt}", RUNLOG)
    else:
        log("Skipping MEDIUM scale because SMALL failed", RUNLOG)

    # Determine final status
    if small_success and medium_success:
        status = "BOTH_SUCCESS"
    elif small_success:
        status = "SMALL_ONLY"
    else:
        status = "BOTH_FAILED"

    log(f"\n{'='*60}", RUNLOG)
    log(f"FINAL STATUS: {status}", RUNLOG)
    log(f"{'='*60}", RUNLOG)

    # Write summary - both to logs and to run directory
    summary_path = f"{WORKFLOW_ROOT}/logs/phase6/PHASE6_SUMMARY.txt"
    run_summary_path = f"{RUN_BASE}/PHASE6_SUMMARY.txt"
    with open(summary_path, "w") as f:
        f.write("=" * 60 + "\n")
        f.write("1000genome-workflow Phase 6 Summary\n")
        f.write(f"Date: {time.strftime('%Y-%m-%d %H:%M:%S')}\n")
        f.write("=" * 60 + "\n\n")
        f.write(f"STATUS: {status}\n\n")

        for s_name, s_ok, s_sum in [("SMALL", small_success, small_summary),
                                     ("MEDIUM", medium_success, medium_summary)]:
            f.write(f"--- {s_name} Scale ---\n")
            f.write(f"  Success: {s_ok}\n")
            if s_sum:
                f.write(f"  Total time: {s_sum['elapsed']:.1f}s ({s_sum['elapsed']/60:.1f}min)\n")
                f.write(f"  Tasks: {len(s_sum['tasks'])} total\n")
                f.write(f"  Failed tasks: {len(s_sum.get('failed_tasks', []))}\n")
                f.write(f"  Output files: {len(s_sum.get('output_files', []))}\n")
                if s_sum.get('failed_tasks'):
                    f.write(f"  Failed: {s_sum['failed_tasks']}\n")
            f.write("\n")

        f.write(f"Log: {RUNLOG}\n")
        f.write(f"Small outputs: {RUN_BASE}/small/outputs/\n")
        f.write(f"Medium outputs: {RUN_BASE}/medium/outputs/\n")

    # Copy summary to run directory
    import shutil as _shutil
    _shutil.copy2(summary_path, run_summary_path)
    log(f"Summary written to {summary_path}", RUNLOG)
    log(f"Summary copied to {run_summary_path}", RUNLOG)
    return status


if __name__ == "__main__":
    status = main()
    sys.exit(0 if status != "BOTH_FAILED" else 1)
