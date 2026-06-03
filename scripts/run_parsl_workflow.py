#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import subprocess
import sys
import time
from pathlib import Path

import parsl
from parsl import python_app
from parsl.config import Config
from parsl.executors import HighThroughputExecutor
from parsl.launchers import SrunLauncher
from parsl.providers import LocalProvider
from parsl.addresses import address_by_hostname


@python_app
def produce_chunk(index: int, size_mb: int, output_dir: str) -> dict:
    import hashlib
    import json
    import os
    import subprocess
    import sys
    from pathlib import Path

    helper = Path(os.environ.get("PARSL_CHUNK_HELPER", ""))
    profile_mode = os.environ.get("PARSL_TASK_PROFILE_MODE", "")
    if helper.is_file() and profile_mode:
        env = os.environ.copy()
        if profile_mode == "datalife":
            env["DATALIFE_OUTPUT_PATH"] = os.environ["PARSL_TASK_DATALIFE_TRACE_DIR"]
            env["DATALIFE_FILE_PATTERNS"] = os.environ.get("PARSL_TASK_DATALIFE_FILE_PATTERNS", "*.bin,*.json")
            env["LD_PRELOAD"] = os.environ["PARSL_TASK_DATALIFE_LIB"]
            env.pop("DARSHAN_ENABLE_NONMPI", None)
            env.pop("DARSHAN_LOG_DIR_PATH", None)
        elif profile_mode == "darshan":
            env["DARSHAN_ENABLE_NONMPI"] = "1"
            env["DARSHAN_LOG_DIR_PATH"] = os.environ["PARSL_TASK_DARSHAN_TRACE_DIR"]
            env["LD_PRELOAD"] = os.environ["PARSL_TASK_DARSHAN_LIB"]
            env.pop("DATALIFE_OUTPUT_PATH", None)
            env.pop("DATALIFE_FILE_PATTERNS", None)
        result = subprocess.run(
            [sys.executable, str(helper), str(index), str(size_mb), output_dir],
            check=True,
            text=True,
            capture_output=True,
            env=env,
        )
        decoder = json.JSONDecoder()
        return decoder.raw_decode(result.stdout.lstrip())[0]

    path = Path(output_dir) / f"chunk-{index:04d}.bin"
    block = hashlib.sha256(f"parsl-chunk-{index}".encode()).digest()
    repeat = (size_mb * 1024 * 1024) // len(block)
    with path.open("wb") as fh:
        for _ in range(repeat):
            fh.write(block)

    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    return {"index": index, "path": str(path), "bytes": path.stat().st_size, "sha256": digest}


@python_app
def aggregate_chunks(*records: dict, output_dir: str) -> dict:
    import hashlib
    import json
    from pathlib import Path

    output = Path(output_dir) / "aggregate.json"
    combined = hashlib.sha256()
    total = 0
    for record in sorted(records, key=lambda item: item["index"]):
        path = Path(record["path"])
        combined.update(path.read_bytes())
        total += record["bytes"]

    result = {
        "chunks": len(records),
        "total_bytes": total,
        "combined_sha256": combined.hexdigest(),
        "records": records,
    }
    output.write_text(json.dumps(result, indent=2, sort_keys=True))
    return result


def build_config(run_dir: Path, workers_per_node: int, nodes: int) -> Config:
    worker_init = f"cd {run_dir}"
    if nodes > 1:
        provider = LocalProvider(
            nodes_per_block=nodes,
            init_blocks=1,
            min_blocks=1,
            max_blocks=1,
            worker_init=worker_init,
            launcher=SrunLauncher(overrides=f"--nodes {nodes} --ntasks-per-node 1"),
        )
    else:
        provider = LocalProvider(
            init_blocks=1,
            min_blocks=1,
            max_blocks=1,
            worker_init=worker_init,
        )

    return Config(
        executors=[
            HighThroughputExecutor(
                label="htex",
                address=address_by_hostname(),
                cores_per_worker=1,
                max_workers_per_node=workers_per_node,
                provider=provider,
                worker_logdir_root=str(run_dir / "worker-logs"),
            )
        ],
        run_dir=str(run_dir / "parsl-runinfo"),
        usage_tracking=False,
    )


def main() -> None:
    parser = argparse.ArgumentParser(description="Native Parsl HTEX file-producing workflow")
    parser.add_argument("--run-dir", required=True)
    parser.add_argument("--tasks", type=int, default=64)
    parser.add_argument("--size-mb", type=int, default=4)
    parser.add_argument("--workers", type=int, default=int(os.environ.get("SLURM_CPUS_PER_TASK", "8")))
    parser.add_argument("--nodes", type=int, default=int(os.environ.get("SLURM_NNODES", "1")))
    args = parser.parse_args()

    run_dir = Path(args.run_dir).resolve()
    output_dir = run_dir / "outputs"
    output_dir.mkdir(parents=True, exist_ok=True)

    started = time.time()
    config = build_config(run_dir, args.workers, args.nodes)

    with parsl.load(config):
        chunk_futures = [produce_chunk(i, args.size_mb, str(output_dir)) for i in range(args.tasks)]
        aggregate_future = aggregate_chunks(*chunk_futures, output_dir=str(output_dir))
        aggregate = aggregate_future.result()

    elapsed = time.time() - started
    manifest = {
        "tasks": args.tasks,
        "size_mb": args.size_mb,
        "workers": args.workers,
        "nodes": args.nodes,
        "elapsed_seconds": elapsed,
        "aggregate": aggregate,
    }
    manifest_path = run_dir / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True))

    expected_bytes = args.tasks * args.size_mb * 1024 * 1024
    if aggregate["chunks"] != args.tasks:
        raise RuntimeError(f"Expected {args.tasks} chunks, got {aggregate['chunks']}")
    if aggregate["total_bytes"] != expected_bytes:
        raise RuntimeError(f"Expected {expected_bytes} bytes, got {aggregate['total_bytes']}")

    print(json.dumps(manifest, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
