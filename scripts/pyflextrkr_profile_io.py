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


def copy_tree(src_dir: Path, dst_dir: Path, pattern: str) -> list[dict]:
    records = []
    for src in sorted(src_dir.glob(pattern)):
        if not src.is_file():
            continue
        dst = dst_dir / src.name
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(src, dst)
        records.append(digest(dst))
    return records


def scan_outputs(paths: list[Path]) -> list[dict]:
    records = []
    for root in paths:
        if root.is_file():
            records.append(digest(root))
            continue
        for path in sorted(root.rglob("*.nc")):
            if path.is_file():
                records.append(digest(path))
    return records


def write_records(path: Path, records: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "files": len(records),
        "bytes": sum(record["bytes"] for record in records),
        "records": records,
    }
    path.write_text(json.dumps(payload, indent=2, sort_keys=True))
    print(json.dumps({"files": payload["files"], "bytes": payload["bytes"]}, sort_keys=True))


def main() -> None:
    parser = argparse.ArgumentParser(description="Profiled PyFLEXTRKR file staging/readback helper")
    sub = parser.add_subparsers(dest="cmd", required=True)

    copy_p = sub.add_parser("copy-inputs")
    copy_p.add_argument("--src-dir", required=True)
    copy_p.add_argument("--dst-dir", required=True)
    copy_p.add_argument("--pattern", default="merg_*.nc")
    copy_p.add_argument("--manifest", required=True)

    scan_p = sub.add_parser("scan-outputs")
    scan_p.add_argument("--manifest", required=True)
    scan_p.add_argument("paths", nargs="+")

    args = parser.parse_args()
    if args.cmd == "copy-inputs":
        records = copy_tree(Path(args.src_dir), Path(args.dst_dir), args.pattern)
        if not records:
            raise SystemExit(f"no inputs matched {args.pattern} under {args.src_dir}")
        write_records(Path(args.manifest), records)
    else:
        records = scan_outputs([Path(path) for path in args.paths])
        if not records:
            raise SystemExit("no output NetCDF files found to scan")
        write_records(Path(args.manifest), records)


if __name__ == "__main__":
    main()
