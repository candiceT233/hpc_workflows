#!/usr/bin/env python3
import hashlib
import json
import sys
from pathlib import Path


def main() -> None:
    index = int(sys.argv[1])
    size_mb = int(sys.argv[2])
    output_dir = Path(sys.argv[3])
    output_dir.mkdir(parents=True, exist_ok=True)

    path = output_dir / f"chunk-{index:04d}.bin"
    block = hashlib.sha256(f"parsl-chunk-{index}".encode()).digest()
    repeat = (size_mb * 1024 * 1024) // len(block)
    with path.open("wb") as fh:
        for _ in range(repeat):
            fh.write(block)

    record = {
        "index": index,
        "path": str(path),
        "bytes": path.stat().st_size,
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
    }
    print(json.dumps(record, sort_keys=True))


if __name__ == "__main__":
    main()
