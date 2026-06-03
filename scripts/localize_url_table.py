#!/usr/bin/env python3
"""Download URL-valued table columns and rewrite them to local paths."""

from __future__ import annotations

import argparse
import csv
import gzip
import os
import shutil
import subprocess
import sys
from pathlib import Path
from urllib.parse import urlparse


def is_url(value: str) -> bool:
    return value.startswith("http://") or value.startswith("https://") or value.startswith("s3://")


def public_url(value: str) -> str:
    parsed = urlparse(value)
    if parsed.scheme == "s3":
        if not parsed.netloc or not parsed.path:
            raise SystemExit(f"cannot translate malformed s3 URL: {value}")
        return f"https://{parsed.netloc}.s3.amazonaws.com{parsed.path}"
    return value


def check_gzip(path: Path) -> bool:
    try:
        with gzip.open(path, "rb") as handle:
            while handle.read(1024 * 1024):
                pass
        return True
    except OSError:
        return False


def download(url: str, dest: Path, attempts: int) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.exists() and dest.stat().st_size > 0:
        if dest.suffix != ".gz" or check_gzip(dest):
            return
        dest.unlink()

    part = dest.with_name(dest.name + ".part")
    if part.exists() and part.stat().st_size > 0:
        if dest.suffix != ".gz" or check_gzip(part):
            os.replace(part, dest)
            return
        part.unlink(missing_ok=True)

    for attempt in range(1, attempts + 1):
        cmd = [
            "curl",
            "-L",
            "--fail",
            "--retry",
            "8",
            "--retry-delay",
            "15",
            "--retry-all-errors",
            "--continue-at",
            "-",
            "-o",
            str(part),
            url,
        ]
        try:
            subprocess.run(cmd, check=True)
            if part.stat().st_size == 0:
                raise RuntimeError(f"downloaded empty file: {url}")
            if dest.suffix == ".gz" and not check_gzip(part):
                part.unlink(missing_ok=True)
                raise RuntimeError(f"gzip validation failed: {url}")
            os.replace(part, dest)
            return
        except Exception as exc:
            if attempt == attempts:
                raise SystemExit(f"failed to download {url} -> {dest}: {exc}") from exc
            if part.exists() and dest.suffix == ".gz" and not check_gzip(part):
                part.unlink(missing_ok=True)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--dest-dir", required=True, type=Path)
    parser.add_argument("--columns", nargs="+", required=True)
    parser.add_argument("--delimiter", choices=[",", "tab"], default=None)
    parser.add_argument("--attempts", type=int, default=3)
    args = parser.parse_args()

    delimiter = "\t" if args.delimiter == "tab" or args.input.suffix == ".tsv" else ","
    with args.input.open(newline="") as handle:
        reader = csv.DictReader(handle, delimiter=delimiter)
        rows = list(reader)
        fieldnames = reader.fieldnames

    if not fieldnames:
        raise SystemExit(f"input table has no header: {args.input}")
    missing = [column for column in args.columns if column not in fieldnames]
    if missing:
        raise SystemExit(f"missing columns in {args.input}: {', '.join(missing)}")

    for row in rows:
        for column in args.columns:
            value = row[column].strip()
            if not value or value == "NA" or not is_url(value):
                continue
            name = Path(urlparse(value).path).name
            if not name:
                raise SystemExit(f"cannot derive filename from URL in {column}: {value}")
            dest = args.dest_dir / name
            download(public_url(value), dest, args.attempts)
            row[column] = str(dest.resolve())

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames, delimiter=delimiter)
        writer.writeheader()
        writer.writerows(rows)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
