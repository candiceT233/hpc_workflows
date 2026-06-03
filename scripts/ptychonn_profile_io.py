#!/usr/bin/env python3
import argparse
import hashlib
import json
import shutil
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


def main() -> None:
    parser = argparse.ArgumentParser(description="Profiled PtychoNN file staging/readback helper")
    sub = parser.add_subparsers(dest="cmd", required=True)

    copy_p = sub.add_parser("copy")
    copy_p.add_argument("--src", required=True)
    copy_p.add_argument("--dst", required=True)

    scan_p = sub.add_parser("scan")
    scan_p.add_argument("--output", required=True)
    scan_p.add_argument("paths", nargs="+")

    args = parser.parse_args()
    if args.cmd == "copy":
        src = Path(args.src)
        dst = Path(args.dst)
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(src, dst)
        print(json.dumps(digest(dst), sort_keys=True))
    else:
        records = [digest(Path(path)) for path in args.paths]
        output = Path(args.output)
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(records, indent=2, sort_keys=True))
        print(json.dumps({"files": len(records), "bytes": sum(r["bytes"] for r in records)}, sort_keys=True))


if __name__ == "__main__":
    main()
