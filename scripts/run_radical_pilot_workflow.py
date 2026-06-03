#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import sys
import time
from pathlib import Path

import radical.pilot as rp


FINAL_STATES = {rp.DONE, rp.FAILED, rp.CANCELED}


def main() -> None:
    parser = argparse.ArgumentParser(description="Native RADICAL-Pilot file-producing workflow")
    parser.add_argument("--run-dir", required=True)
    parser.add_argument("--tasks", type=int, default=128)
    parser.add_argument("--size-mb", type=int, default=4)
    parser.add_argument("--cores", type=int, default=int(os.environ.get("SLURM_CPUS_PER_TASK", "8")))
    parser.add_argument("--runtime", type=int, default=30)
    parser.add_argument("--resource", default="local.localhost")
    parser.add_argument("--queue", default=None)
    parser.add_argument("--access-schema", default=None)
    parser.add_argument("--project", default=None)
    args = parser.parse_args()

    run_dir = Path(args.run_dir).resolve()
    output_dir = run_dir / "outputs"
    output_dir.mkdir(parents=True, exist_ok=True)
    started = time.time()

    session = rp.Session()
    tasks = []
    try:
        pmgr = rp.PilotManager(session=session)
        tmgr = rp.TaskManager(session=session)
        pilot_description = {
            "resource": args.resource,
            "runtime": args.runtime,
            "cores": args.cores,
            "gpus": 0,
            "exit_on_error": True,
        }
        if args.queue:
            pilot_description["queue"] = args.queue
        if args.access_schema:
            pilot_description["access_schema"] = args.access_schema
        if args.project:
            pilot_description["project"] = args.project
        pdesc = rp.PilotDescription(pilot_description)
        pilot = pmgr.submit_pilots(pdesc)
        tmgr.add_pilots(pilot)

        task_script = str((Path(__file__).resolve().parent / "radical_pilot_file_task.py"))
        descriptions = []
        task_env = {
            key: value
            for key, value in os.environ.items()
            if key.startswith("DATALIFE_") or key.startswith("DARSHAN_") or key == "LD_PRELOAD"
        }
        task_profile_mode = os.environ.get("RADICAL_TASK_PROFILE_MODE", "")
        if task_profile_mode == "datalife":
            task_env = {
                "DATALIFE_OUTPUT_PATH": os.environ["RADICAL_TASK_DATALIFE_TRACE_DIR"],
                "DATALIFE_FILE_PATTERNS": os.environ.get("RADICAL_TASK_DATALIFE_FILE_PATTERNS", "*.bin,*.txt,*.log"),
                "LD_PRELOAD": os.environ["RADICAL_TASK_DATALIFE_LIB"],
            }
        elif task_profile_mode == "darshan":
            task_env = {
                "DARSHAN_ENABLE_NONMPI": "1",
                "DARSHAN_LOG_DIR_PATH": os.environ["RADICAL_TASK_DARSHAN_TRACE_DIR"],
                "LD_PRELOAD": os.environ["RADICAL_TASK_DARSHAN_LIB"],
            }
        for index in range(args.tasks):
            td = rp.TaskDescription()
            td.executable = sys.executable
            td.arguments = [task_script, str(output_dir), str(index), str(args.size_mb)]
            td.cpu_processes = 1
            td.cpu_threads = 1
            if task_env:
                td.environment = task_env
            descriptions.append(td)

        tasks = tmgr.submit_tasks(descriptions)
        tmgr.wait_tasks()
        failed = [task for task in tasks if task.state != rp.DONE]
        if failed:
            details = [{"uid": task.uid, "state": task.state, "exit_code": task.exit_code, "stderr": task.stderr} for task in failed]
            raise RuntimeError(f"RADICAL-Pilot tasks failed: {json.dumps(details, sort_keys=True)}")

    finally:
        session.close(download=True)

    records = []
    combined = hashlib.sha256()
    for path in sorted(output_dir.glob("task-*.json")):
        record = json.loads(path.read_text())
        records.append(record)
        combined.update(Path(record["path"]).read_bytes())

    expected_bytes = args.tasks * args.size_mb * 1024 * 1024
    total_bytes = sum(record["bytes"] for record in records)
    if len(records) != args.tasks:
        raise RuntimeError(f"Expected {args.tasks} task metadata files, found {len(records)}")
    if total_bytes != expected_bytes:
        raise RuntimeError(f"Expected {expected_bytes} bytes, got {total_bytes}")

    manifest = {
        "workflow": "radical.pilot",
        "runner": "RADICAL-Pilot",
        "session": session.uid,
        "tasks": args.tasks,
        "resource": args.resource,
        "queue": args.queue,
        "access_schema": args.access_schema,
        "project": args.project,
        "cores": args.cores,
        "size_mb": args.size_mb,
        "total_bytes": total_bytes,
        "combined_sha256": combined.hexdigest(),
        "task_states": {task.uid: task.state for task in tasks},
        "elapsed_seconds": time.time() - started,
    }
    (run_dir / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True))
    print(json.dumps(manifest, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
