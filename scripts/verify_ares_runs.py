#!/usr/bin/env python3
"""Adapter for widget-v1's dfl_mcp.verification on Ares-side run directories.

Ares-side runs use TAG-suffixed paths (datalife_traces_<TAG>/, outputs_<TAG>/, etc.)
because multiple profilers can produce traces in the same parent dir over time.
The widget verification expects Delta-style flat names (datalife_traces/,
outputs/, logs/trace.txt). This script creates ephemeral symlinks to bridge
that, runs verify_run, and prints a JSON summary.

Usage:
    python scripts/verify_ares_runs.py runs/nf-core_funcscan/multinode_4node_darshan
    python scripts/verify_ares_runs.py --glob 'runs/*/multinode_*node_darshan'
"""
from __future__ import annotations

import argparse
import glob as glob_module
import json
import os
import re
import sys
from contextlib import contextmanager
from pathlib import Path

WIDGET_SRC = "/mnt/common/mtang11/scripts/widget-v1/src"
ARES_DARSHAN_PARSER = "/home/mtang11/hpc_workflows/tools/darshan/bin/darshan-parser"

# Add widget-v1 src to import path
sys.path.insert(0, WIDGET_SRC)
from dfl_mcp import verification as v  # noqa: E402

# Point Ares-side parser path before any verify_run call
v.DARSHAN_PARSER = ARES_DARSHAN_PARSER

# Patch check_darshan to sample N files instead of iterating all
# (a Phase 1 run with 59K .darshan logs would take 30+ min otherwise).
_DARSHAN_SAMPLE_CAP = int(os.environ.get("DARSHAN_SAMPLE_CAP", "20"))


def check_darshan_sampled(run_dir):
    import subprocess as _sp
    import shutil as _sh
    from dfl_mcp.verification import CheckResult
    res = CheckResult(name="darshan", passed=True)
    candidates = [
        Path(run_dir) / "darshan_logs",
        Path(run_dir) / "darshan_traces",
        Path(run_dir) / "logs" / "darshan",
    ]
    log_dir = next((p for p in candidates if p.is_dir()), None)
    if log_dir is None:
        res.fail(f"no darshan log dir (tried: {[str(p) for p in candidates]})")
        return res
    res.details["log_dir"] = str(log_dir)

    all_logs = sorted(p for p in log_dir.rglob("*.darshan") if p.is_file())
    res.details["log_count"] = len(all_logs)
    if not all_logs:
        res.fail("no *.darshan files")
        return res

    parser = v.DARSHAN_PARSER if Path(v.DARSHAN_PARSER).is_file() else _sh.which("darshan-parser")
    if not parser:
        res.fail("darshan-parser missing")
        return res
    res.details["parser"] = parser

    # Sample by largest file size first — that's where real I/O lives. nf-core
    # runs produce thousands of wrapper-call .darshan logs (coreutil shims with
    # no I/O); the productive logs are big. Sort desc-by-size, take top N.
    n = _DARSHAN_SAMPLE_CAP
    if len(all_logs) <= n:
        sample = all_logs
    else:
        sample = sorted(all_logs, key=lambda p: p.stat().st_size, reverse=True)[:n]
    res.details["sample_size"] = len(sample)
    if sample:
        res.details["sample_size_range_bytes"] = [sample[-1].stat().st_size,
                                                  sample[0].stat().st_size]

    parseable = nonempty = 0
    bad = []
    total_read = total_write = 0
    for log in sample:
        if log.stat().st_size < 64:
            continue
        try:
            out = _sp.run([parser, "--total", str(log)],
                          capture_output=True, text=True, timeout=30)
        except Exception as e:
            bad.append(f"{log.name}: {e}")
            continue
        if out.returncode != 0:
            bad.append(f"{log.name}: exit {out.returncode}: {out.stderr.strip()[:120]}")
            continue
        parseable += 1
        r = w = 0
        for line in out.stdout.splitlines():
            line = line.strip()
            if line.startswith("total_POSIX_BYTES_READ:"):
                try: r = int(line.split(":", 1)[1].strip())
                except: pass
            elif line.startswith("total_POSIX_BYTES_WRITTEN:"):
                try: w = int(line.split(":", 1)[1].strip())
                except: pass
        total_read += r; total_write += w
        if r > 0 or w > 0:
            nonempty += 1
    res.details["parseable"] = parseable
    res.details["nonempty"] = nonempty
    res.details["total_bytes_read"] = total_read
    res.details["total_bytes_written"] = total_write
    res.details["bad_files"] = bad[:10]
    if parseable == 0:
        res.fail(f"0/{len(sample)} sampled darshan files parsed")
    if nonempty == 0:
        res.fail("sampled darshan files all show 0 POSIX bytes")
    if bad:
        res.fail(f"{len(bad)} sampled file(s) failed to parse")
    return res

v.check_darshan = check_darshan_sampled


def detect_tag(run_dir: Path, profiler: str) -> str | None:
    """Find the TAG suffix used by this run dir, e.g. 'datalife_4node'."""
    pattern = f"{profiler}_traces_*"
    matches = list(run_dir.glob(pattern))
    if matches:
        # darshan_traces_darshan_4node → "darshan_4node"
        return matches[0].name[len(f"{profiler}_traces_"):]
    # fall back: look for outputs_<TAG>/
    outs = list(run_dir.glob("outputs_*"))
    if outs:
        return outs[0].name[len("outputs_"):]
    return None


@contextmanager
def bridge_layout(run_dir: Path, profiler: str):
    """Create ephemeral symlinks so the run_dir matches Delta-style layout.

    Symlinks (only created if target exists, not removed if already a real dir):
      - <run_dir>/outputs          -> outputs_<TAG>/
      - <run_dir>/datalife_traces  -> datalife_traces_<TAG>/   (if profiler==datalife)
      - <run_dir>/darshan_traces   -> darshan_traces_<TAG>/    (if profiler==darshan)
      - <run_dir>/logs/trace.txt   -> outputs_<TAG>/pipeline_info/execution_trace_*.txt
                                     (newest one)
      - <run_dir>/logs/slurm-<id>.out -> existing slurm_dl_<id>.out or slurm_dh_<id>.out
    """
    tag = detect_tag(run_dir, profiler)
    created = []
    try:
        if tag:
            # outputs/
            real_outputs = run_dir / f"outputs_{tag}"
            symlink = run_dir / "outputs"
            if real_outputs.is_dir() and not symlink.exists():
                symlink.symlink_to(real_outputs.name)
                created.append(symlink)

            # datalife_traces or darshan_traces
            real_traces = run_dir / f"{profiler}_traces_{tag}"
            symlink = run_dir / f"{profiler}_traces"
            if real_traces.is_dir() and not symlink.exists():
                symlink.symlink_to(real_traces.name)
                created.append(symlink)

            # logs/trace.txt — newest execution_trace_*.txt under outputs/pipeline_info/
            logs_dir = run_dir / "logs"
            pinfo = real_outputs / "pipeline_info"
            if pinfo.is_dir() and logs_dir.is_dir():
                traces = sorted(pinfo.glob("execution_trace_*.txt"))
                if traces:
                    newest = traces[-1]
                    symlink = logs_dir / "trace.txt"
                    if not symlink.exists():
                        symlink.symlink_to(newest.resolve())
                        created.append(symlink)

            # logs/slurm-<jobid>.out from existing slurm_dl_<id>.out / slurm_dh_<id>.out
            if logs_dir.is_dir():
                for src in logs_dir.glob("slurm_d?_*.out"):
                    # parse jobid out of "slurm_dl_16965.out" or "slurm_dh_16966.out"
                    m = re.match(r"slurm_d[lh]_(\d+)\.out", src.name)
                    if m:
                        target = logs_dir / f"slurm-{m.group(1)}.out"
                        if not target.exists():
                            target.symlink_to(src.name)
                            created.append(target)
        yield tag
    finally:
        for p in created:
            try:
                p.unlink()
            except FileNotFoundError:
                pass


def detect_profilers(run_dir: Path) -> list[str]:
    """Auto-detect which profilers this run dir was profiled with."""
    profs = []
    if any(run_dir.glob("datalife_traces*")):
        profs.append("datalife")
    if any(run_dir.glob("darshan_traces*")):
        profs.append("darshan")
    # Could also probe for dayu_traces, but DaYu not used here yet
    return profs


def verify_one(run_dir: Path) -> dict:
    """Run verification for every profiler this run dir has traces for."""
    out = {"run_dir": str(run_dir), "profilers": {}}
    profilers = detect_profilers(run_dir)
    if not profilers:
        out["error"] = "no profiler traces detected"
        return out
    for prof in profilers:
        with bridge_layout(run_dir, prof) as tag:
            try:
                report = v.verify_run(run_dir, profiler=prof)
                report_dict = report.to_dict()
                report_dict["tag"] = tag
                # condense: keep summary, drop large details lists for top-line
                summary = {
                    "passed": report_dict["passed"],
                    "tag": tag,
                    "checks": {},
                }
                for ck_name, ck in report_dict["checks"].items():
                    summary["checks"][ck_name] = {
                        "passed": ck["passed"],
                        "errors": ck.get("errors", []),
                        # keep just the high-signal details
                        "details": {
                            k: v_ for k, v_ in ck.get("details", {}).items()
                            if k in (
                                "trace_rows", "completed", "failed", "cached",
                                "nextflow_summary", "r_blk_count", "w_blk_count",
                                "timer_count", "log_count", "parseable",
                                "nonempty", "total_bytes_read", "total_bytes_written",
                            )
                        },
                    }
                out["profilers"][prof] = summary
            except Exception as e:
                out["profilers"][prof] = {"passed": False, "errors": [f"exception: {e}"]}
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("run_dirs", nargs="*",
                    help="Run dirs to verify; if absent, use --glob.")
    ap.add_argument("--glob",
                    help="Glob pattern under cwd to expand into run_dirs.")
    ap.add_argument("--out", help="If given, write JSON results to this file.")
    args = ap.parse_args()

    targets = [Path(p) for p in args.run_dirs]
    if args.glob:
        targets += [Path(p) for p in sorted(glob_module.glob(args.glob))]
    if not targets:
        ap.error("provide run_dirs or --glob")

    all_results = []
    for rd in targets:
        if not rd.is_dir():
            print(f"SKIP (not a dir): {rd}", file=sys.stderr)
            continue
        result = verify_one(rd)
        all_results.append(result)
        # Single-line per result for terminal scan
        print(f"\n=== {rd} ===")
        if "error" in result:
            print(f"  ERROR: {result['error']}")
            continue
        for prof, summary in result["profilers"].items():
            verdict = "PASS" if summary["passed"] else "FAIL"
            print(f"  {prof}: {verdict} (tag={summary.get('tag')})")
            for ck_name, ck in summary.get("checks", {}).items():
                ck_verdict = "ok" if ck["passed"] else "FAIL"
                print(f"    - {ck_name}: {ck_verdict}")
                if ck["errors"]:
                    for e in ck["errors"][:3]:
                        print(f"        ! {e}")
                if ck.get("details"):
                    keys = ", ".join(f"{k}={v}" for k, v in ck["details"].items()
                                      if not isinstance(v, dict))
                    if keys:
                        print(f"        {keys}")
    if args.out:
        Path(args.out).write_text(json.dumps(all_results, indent=2))
        print(f"\n→ wrote {args.out}")


if __name__ == "__main__":
    main()
