#!/usr/bin/env python3
import argparse
import fnmatch
import hashlib
import json
from pathlib import Path


def digest(path: Path) -> dict:
    h = hashlib.sha256()
    total = 0
    with path.open("rb") as fh:
        while True:
            chunk = fh.read(8 * 1024 * 1024)
            if not chunk:
                break
            h.update(chunk)
            total += len(chunk)
    return {"path": str(path), "bytes": total, "sha256": h.hexdigest()}


def matches(path: Path, patterns: list[str]) -> bool:
    name = path.name
    return any(fnmatch.fnmatch(name, pattern) for pattern in patterns)


def scan(root: Path, patterns: list[str]) -> list[dict]:
    records = []
    for path in sorted(root.rglob("*")):
        if path.is_file() and path.stat().st_size > 0 and matches(path, patterns):
            records.append(digest(path))
    return records


def main() -> None:
    parser = argparse.ArgumentParser(description="Profile file reads for a completed workflow tree")
    parser.add_argument("--root", required=True)
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--patterns", nargs="+", required=True)
    args = parser.parse_args()

    records = scan(Path(args.root), args.patterns)
    if not records:
        raise SystemExit(f"no matching non-empty files under {args.root}")
    payload = {
        "files": len(records),
        "bytes": sum(record["bytes"] for record in records),
        "patterns": args.patterns,
        "records": records,
    }
    manifest = Path(args.manifest)
    manifest.parent.mkdir(parents=True, exist_ok=True)
    manifest.write_text(json.dumps(payload, indent=2, sort_keys=True))
    print(json.dumps({"files": payload["files"], "bytes": payload["bytes"]}, sort_keys=True))


if __name__ == "__main__":
    main()
