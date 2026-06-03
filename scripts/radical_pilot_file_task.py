#!/usr/bin/env python3
import hashlib
import json
import sys
from pathlib import Path


def main() -> None:
    output_dir = Path(sys.argv[1])
    index = int(sys.argv[2])
    size_mb = int(sys.argv[3])
    output_dir.mkdir(parents=True, exist_ok=True)

    block = hashlib.sha256(f"radical-pilot-task-{index}".encode()).digest()
    repeat = (size_mb * 1024 * 1024) // len(block)
    path = output_dir / f"task-{index:04d}.bin"
    with path.open("wb") as fh:
        for _ in range(repeat):
            fh.write(block)

    meta = {
        "index": index,
        "path": str(path),
        "bytes": path.stat().st_size,
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
    }
    (output_dir / f"task-{index:04d}.json").write_text(json.dumps(meta, sort_keys=True))
    print(json.dumps(meta, sort_keys=True))


if __name__ == "__main__":
    main()
