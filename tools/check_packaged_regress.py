#!/usr/bin/env python3
"""Validate a packaged regress.csv + run_metadata.json (no workspace required).

Used by REPLAY on evidence/<commit7>/ without the original run workspace tree.
"""
from __future__ import annotations

import argparse
import csv
import json
import sys
from pathlib import Path


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--csv", type=Path, required=True)
    ap.add_argument("--manifest", type=Path, required=True)
    ap.add_argument("--require-n", type=int, default=0)
    args = ap.parse_args()
    csv_path = args.csv.resolve()
    meta_path = csv_path.parent / "run_metadata.json"
    if not csv_path.is_file() or not meta_path.is_file():
        print("FAIL missing csv or run_metadata.json", file=sys.stderr)
        return 1
    rows = list(csv.DictReader(csv_path.open(encoding="utf-8-sig")))
    meta = json.loads(meta_path.read_text(encoding="utf-8-sig"))
    if not rows:
        print("FAIL empty csv", file=sys.stderr)
        return 1
    if any(r.get("result") != "PASS" for r in rows):
        print("FAIL not all PASS", file=sys.stderr)
        return 1
    if meta.get("pass_count") != len(rows) or meta.get("test_count") != len(rows):
        print("FAIL metadata counts mismatch", file=sys.stderr)
        return 1
    if meta.get("regression_result") != "PASS":
        print("FAIL metadata regression_result != PASS", file=sys.stderr)
        return 1
    # manifest order
    man_ids = []
    for line in args.manifest.read_text(encoding="utf-8").splitlines():
        s = line.split("#", 1)[0].strip()
        if not s:
            continue
        man_ids.append(s.split()[0])
    csv_ids = [r.get("test_id", "") for r in rows]
    if csv_ids != man_ids:
        print(
            f"FAIL csv order/ids != manifest (csv={len(csv_ids)} man={len(man_ids)})",
            file=sys.stderr,
        )
        return 1
    if args.require_n and len(rows) != args.require_n:
        print(f"FAIL n={len(rows)} require_n={args.require_n}", file=sys.stderr)
        return 1
    print(f"PASS check_packaged_regress n={len(rows)} all PASS ordered=manifest")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
