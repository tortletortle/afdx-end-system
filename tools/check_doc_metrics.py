#!/usr/bin/env python3
"""Verify {{metric:key}} anchors in doc/submit (+ README) against metrics.json."""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ANCHOR = re.compile(r"\{\{metric:([a-zA-Z0-9_.-]+)\}\}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--metrics",
        type=Path,
        default=Path("out/p9_freeze_dfac58a/metrics.json"),
    )
    ap.add_argument(
        "--roots",
        nargs="+",
        default=["doc/submit", "README.md"],
    )
    ap.add_argument(
        "--allow-missing-metrics",
        action="store_true",
        help="if metrics.json missing, exit 0 with SKIP (skeleton phase)",
    )
    args = ap.parse_args()
    root = Path.cwd()
    metrics_path = args.metrics if args.metrics.is_absolute() else root / args.metrics
    if not metrics_path.is_file():
        if args.allow_missing_metrics:
            print(f"SKIP check_doc_metrics: no {metrics_path}")
            return 0
        print(f"FAIL: missing {metrics_path}", file=sys.stderr)
        return 2

    data = json.loads(metrics_path.read_text(encoding="utf-8"))
    catalog = data.get("metrics") or {}
    if data.get("mode") == "dry_run":
        print("WARN: metrics.json is dry_run mode — not P8 evidence")

    files: list[Path] = []
    for r in args.roots:
        p = root / r
        if p.is_file():
            files.append(p)
        elif p.is_dir():
            for f in sorted(p.rglob("*.md")):
                name = f.name
                # 人工清单/提示词不是提交正文，跳过说明性假锚点
                if name.startswith("人工") or name.startswith("提示词"):
                    continue
                files.append(f)
        else:
            print(f"WARN: missing root {r}")

    missing_keys: list[str] = []
    unknown: list[tuple[str, str]] = []
    used: set[str] = set()
    for f in files:
        text = f.read_text(encoding="utf-8")
        for m in ANCHOR.finditer(text):
            key = m.group(1)
            used.add(key)
            if key not in catalog:
                unknown.append((str(f).replace("\\", "/"), key))

    # catalog keys unused is OK (extra measurements)
    if unknown:
        print("FAIL: anchors without metrics.json entry:")
        for path, key in unknown:
            print(f"  {path}: {{{{metric:{key}}}}}")
        return 1

    print(
        f"PASS check_doc_metrics files={len(files)} anchors={len(used)} "
        f"catalog={len(catalog)}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
