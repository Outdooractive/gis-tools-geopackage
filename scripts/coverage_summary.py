#!/usr/bin/env python3
"""Print line coverage for Sources/GISToolsGeoPackage from codecov JSON.

Run `swift test --enable-code-coverage` first. The optional `--minimum` turns
the summary into a CI gate.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path


def coverage_path() -> Path:
    output = subprocess.check_output(
        ["swift", "test", "--show-codecov-path"],
        text=True,
    ).strip()
    path = Path(output)
    if not path.exists():
        raise SystemExit(f"Coverage file not found: {path}")
    return path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--minimum",
        type=float,
        default=None,
        help="Fail when total line coverage is below this percentage",
    )
    args = parser.parse_args()

    path = coverage_path()
    data = json.loads(path.read_text())
    files = data["data"][0]["files"]

    rows = []
    total = 0
    covered = 0
    for entry in files:
        filename = entry["filename"]
        marker = "/Sources/GISToolsGeoPackage/"
        if marker not in filename:
            continue
        summary = entry["summary"]["lines"]
        count = summary["count"]
        hit = summary["covered"]
        total += count
        covered += hit
        rows.append((
            filename.split(marker, 1)[1],
            count,
            hit,
            summary["percent"],
        ))

    if total == 0:
        raise SystemExit("No GISToolsGeoPackage source files in the coverage data")

    for name, count, hit, percent in sorted(rows, key=lambda row: row[3]):
        print(f"{percent:6.2f}%  {hit:4}/{count:4}  {name}")

    percent = 100.0 * covered / total
    print(f"\nTotal line coverage: {percent:.2f}% ({covered}/{total})")

    if args.minimum is not None and percent < args.minimum:
        print(
            f"Coverage {percent:.2f}% is below the required "
            f"{args.minimum:.2f}%",
            file=sys.stderr,
        )
        sys.exit(1)


if __name__ == "__main__":
    main()
