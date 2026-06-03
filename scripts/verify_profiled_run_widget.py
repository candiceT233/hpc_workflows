#!/usr/bin/env python3
"""Verify hpc_workflows profiled runs using widget-v1 validation helpers.

The widget verifier expects a normalized Delta layout. This repository stores
profiled runs as runs/<workflow>/4node-profiled-<jobid>/ with traces under
traces/datalife and traces/darshan, so this adapter validates that layout
directly while reusing widget's DataLife schema checks.
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import re
import shutil
import subprocess
import sys
from dataclasses import asdict, dataclass, field
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WIDGET_SRC = ROOT / "tools" / "widget-v1" / "src"
sys.path.insert(0, str(WIDGET_SRC))

from dfl_mcp import verification as widget_verification  # noqa: E402


RUN_RE = re.compile(r"^4node-profiled-(?P<jobid>\d+|manual)$")


@dataclass
class ProfiledRunReport:
    workflow: str
    run: str
    run_dir: str
    slurm_log: str = ""
    workflow_status: str = "unknown"
    datalife_status: str = "fail"
    darshan_status: str = "fail"
    overall_status: str = "fail"
    datalife_json: int = 0
    datalife_block_traces: int = 0
    datalife_timers: int = 0
    datalife_bad_json: int = 0
    datalife_old_schema: int = 0
    darshan_logs: int = 0
    darshan_parseable: int = 0
    darshan_bad: int = 0
    notes: list[str] = field(default_factory=list)

    def note_once(self, message: str) -> None:
        if message not in self.notes:
            self.notes.append(message)

    def as_tsv_row(self) -> dict[str, str | int]:
        return {
            "workflow": self.workflow,
            "run": self.run,
            "overall_status": self.overall_status,
            "workflow_status": self.workflow_status,
            "datalife_status": self.datalife_status,
            "darshan_status": self.darshan_status,
            "datalife_json": self.datalife_json,
            "datalife_block_traces": self.datalife_block_traces,
            "datalife_timers": self.datalife_timers,
            "datalife_bad_json": self.datalife_bad_json,
            "datalife_old_schema": self.datalife_old_schema,
            "darshan_logs": self.darshan_logs,
            "darshan_parseable": self.darshan_parseable,
            "darshan_bad": self.darshan_bad,
            "slurm_log": self.slurm_log,
            "run_dir": self.run_dir,
            "notes": "; ".join(self.notes),
        }


def slurm_log_for(run_dir: Path) -> Path | None:
    match = RUN_RE.match(run_dir.name)
    if not match:
        return None
    jobid = match.group("jobid")
    if jobid == "manual":
        return None
    candidate = run_dir.parent / f"slurm-{jobid}-4node-profiled.out"
    return candidate if candidate.is_file() else None


def check_workflow(run_dir: Path, log_path: Path | None, report: ProfiledRunReport) -> None:
    output_markers = [
        run_dir / "trace-summary.tsv",
        run_dir / "datalife-outputs.tsv",
        run_dir / "darshan-outputs.tsv",
    ]
    nonempty_markers = [p for p in output_markers if p.is_file() and p.stat().st_size > 0]

    if log_path:
        report.slurm_log = str(log_path.relative_to(ROOT))
        text = log_path.read_text(errors="replace")
        fatal_needles = [
            "BAD TERMINATION",
            "Traceback (most recent call last)",
            "ERROR:",
            "Failed:",
            "exited with exit code",
            "Command exited with non-zero status",
        ]
        fatal_hits = [needle for needle in fatal_needles if needle in text]
        success_hits = [
            "DataLife JSON traces parsed:",
            "Darshan logs parsed:",
            "Completed at:",
            "Pipeline completed successfully",
        ]
        if fatal_hits:
            report.workflow_status = "fail"
            report.note_once("slurm log has fatal marker(s): " + ", ".join(fatal_hits[:3]))
        elif any(marker in text for marker in success_hits) or nonempty_markers:
            report.workflow_status = "pass"
        else:
            report.workflow_status = "unknown"
            report.note_once("no clear workflow success marker in slurm log")
    elif nonempty_markers:
        report.workflow_status = "pass"
        report.note_once("no slurm log found; output marker files are present")
    else:
        report.workflow_status = "unknown"
        report.note_once("no slurm log or output marker files found")


def iter_datalife_json(run_dir: Path) -> list[Path]:
    candidates = [
        run_dir / "traces" / "datalife",
        run_dir / "datalife",
        run_dir / "datalife_traces",
    ]
    files: list[Path] = []
    for candidate in candidates:
        if candidate.is_dir():
            files.extend(p for p in candidate.rglob("*.json") if p.is_file())
    return sorted(set(files))


def check_datalife(run_dir: Path, report: ProfiledRunReport) -> None:
    files = iter_datalife_json(run_dir)
    report.datalife_json = len(files)
    if not files:
        report.note_once("no DataLife JSON traces found")
        return

    bad = 0
    block = 0
    timers = 0
    old_schema = 0
    for path in files:
        rel_name = path.name
        if widget_verification.BLOCK_TRACE_RE.search(rel_name):
            block += 1
            ok, msg, _summary = widget_verification._validate_block_trace(path)
            if not ok:
                if "missing required key" in msg:
                    old_schema += 1
                    if old_schema == 1:
                        report.note_once(f"DataLife block trace old schema example {path.name}: {msg}")
                else:
                    bad += 1
                    if bad <= 3:
                        report.note_once(f"bad DataLife block trace {path.name}: {msg}")
        elif widget_verification.DATALIFE_TIMER_RE.search(rel_name):
            timers += 1
            ok, msg = widget_verification._validate_datalife_timer(path)
            if not ok:
                bad += 1
                if bad <= 3:
                    report.note_once(f"bad DataLife timer {path.name}: {msg}")
        else:
            try:
                json.loads(path.read_text())
            except json.JSONDecodeError as exc:
                bad += 1
                if bad <= 3:
                    report.note_once(f"bad DataLife JSON {path.name}: {exc}")

    report.datalife_block_traces = block
    report.datalife_timers = timers
    report.datalife_bad_json = bad
    report.datalife_old_schema = old_schema

    if bad:
        report.datalife_status = "fail"
    elif block > 0 and old_schema:
        report.datalife_status = "needs_rerun"
        report.note_once("DataLife block traces use old schema missing widget-required metadata; rerun with rebuilt widget")
    elif block > 0 and timers > 0:
        report.datalife_status = "pass"
    elif block > 0:
        report.datalife_status = "needs_rerun"
        report.note_once("DataLife block traces exist but no widget TIMER_JSON timer files; rerun with rebuilt widget")
    else:
        report.datalife_status = "fail"
        report.note_once("DataLife JSON exists but no block traces were found")


def darshan_parser() -> str | None:
    configured = Path(widget_verification.DARSHAN_PARSER)
    if configured.is_file() and os.access(configured, os.X_OK):
        return str(configured)
    parser = shutil.which("darshan-parser")
    if parser:
        return parser
    try:
        proc = subprocess.run(
            ["spack", "location", "-i", "darshan-util@3.4.6"],
            capture_output=True,
            text=True,
            timeout=30,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if proc.returncode != 0:
        return None
    candidate = Path(proc.stdout.strip()) / "bin" / "darshan-parser"
    if candidate.is_file() and os.access(candidate, os.X_OK):
        return str(candidate)
    return None


def iter_darshan_logs(run_dir: Path) -> list[Path]:
    candidates = [
        run_dir / "traces" / "darshan",
        run_dir / "darshan",
        run_dir / "darshan_logs",
        run_dir / "darshan_traces",
        run_dir / "logs" / "darshan",
    ]
    logs: list[Path] = []
    for candidate in candidates:
        if candidate.is_dir():
            logs.extend(p for p in candidate.rglob("*.darshan") if p.is_file() and p.stat().st_size > 0)
    return sorted(set(logs))


def check_darshan(run_dir: Path, report: ProfiledRunReport) -> None:
    logs = iter_darshan_logs(run_dir)
    report.darshan_logs = len(logs)
    if not logs:
        report.note_once("no non-empty Darshan logs found")
        return

    parser = darshan_parser()
    if not parser:
        report.darshan_status = "unknown"
        report.note_once("darshan-parser not available; counted logs only")
        return

    bad = 0
    parseable = 0
    for log in logs:
        try:
            proc = subprocess.run(
                [parser, "--total", str(log)],
                capture_output=True,
                text=True,
                timeout=60,
            )
        except subprocess.TimeoutExpired:
            bad += 1
            if bad <= 3:
                report.note_once(f"darshan-parser timeout: {log.name}")
            continue
        if proc.returncode != 0:
            bad += 1
            if bad <= 3:
                report.note_once(f"darshan-parser failed for {log.name}: {proc.stderr.strip()[:160]}")
            continue
        parseable += 1

    report.darshan_parseable = parseable
    report.darshan_bad = bad
    if bad:
        report.darshan_status = "fail"
    elif parseable > 0:
        report.darshan_status = "pass"


def verify_run(run_dir: Path) -> ProfiledRunReport:
    workflow = run_dir.parent.name
    report = ProfiledRunReport(
        workflow=workflow,
        run=run_dir.name,
        run_dir=str(run_dir.relative_to(ROOT)),
    )
    log_path = slurm_log_for(run_dir)
    check_workflow(run_dir, log_path, report)
    check_datalife(run_dir, report)
    check_darshan(run_dir, report)

    statuses = [report.workflow_status, report.datalife_status, report.darshan_status]
    if statuses == ["pass", "pass", "pass"]:
        report.overall_status = "pass"
    elif "fail" in statuses:
        report.overall_status = "fail"
    elif "needs_rerun" in statuses:
        report.overall_status = "needs_rerun"
    else:
        report.overall_status = "unknown"
    return report


def dirs_from_summary(path: Path) -> list[Path]:
    dirs: list[Path] = []
    with path.open(newline="") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        for row in reader:
            if row.get("mode") != "trace":
                continue
            evidence = row.get("evidence_file", "")
            run = row.get("run", "")
            workflow = row.get("workflow", "")
            if not workflow or not run:
                continue
            run_dir = ROOT / "runs" / workflow / run
            if run_dir.is_dir():
                dirs.append(run_dir)
                continue
            if evidence:
                job = evidence.split("slurm-", 1)[-1].split("-4node-profiled", 1)[0]
                inferred = ROOT / "runs" / workflow / f"4node-profiled-{job}"
                if inferred.is_dir():
                    dirs.append(inferred)
    return dirs


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run_dirs", nargs="*", type=Path)
    parser.add_argument("--from-summary", type=Path, default=ROOT / "summaries" / "latest_workflow_mode_status_last4d.tsv")
    parser.add_argument("--out-tsv", type=Path, default=ROOT / "summaries" / "widget_profiled_verification.tsv")
    parser.add_argument("--out-json", type=Path, default=ROOT / "summaries" / "widget_profiled_verification.json")
    args = parser.parse_args()

    run_dirs = [p.resolve() for p in args.run_dirs]
    if not run_dirs and args.from_summary.is_file():
        run_dirs = dirs_from_summary(args.from_summary)
    run_dirs = sorted(set(run_dirs))
    if not run_dirs:
        raise SystemExit("no profiled run directories to verify")

    reports = [verify_run(path) for path in run_dirs]

    args.out_tsv.parent.mkdir(parents=True, exist_ok=True)
    fields = list(reports[0].as_tsv_row().keys())
    with args.out_tsv.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, delimiter="\t", fieldnames=fields)
        writer.writeheader()
        for report in reports:
            writer.writerow(report.as_tsv_row())

    args.out_json.write_text(json.dumps([asdict(r) for r in reports], indent=2, sort_keys=True))

    for report in reports:
        print(
            f"{report.workflow}\t{report.run}\t{report.overall_status}\t"
            f"workflow={report.workflow_status}\tdatalife={report.datalife_status}"
            f"\tdarshan={report.darshan_status}\t{'; '.join(report.notes[:2])}"
        )
    print(f"wrote {args.out_tsv}")
    print(f"wrote {args.out_json}")
    return 0 if all(r.overall_status == "pass" for r in reports) else 1


if __name__ == "__main__":
    raise SystemExit(main())
