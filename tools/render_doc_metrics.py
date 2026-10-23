#!/usr/bin/env python3
"""Fill {{metric:key}} in doc/submit/*.md → doc/submit/filled/ (readable pack)."""
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
        default=Path("out/p8_freeze_225cd91/metrics.json"),
    )
    ap.add_argument("--src", type=Path, default=Path("doc/submit"))
    ap.add_argument("--dst", type=Path, default=Path("doc/submit/filled"))
    args = ap.parse_args()
    root = Path.cwd()
    metrics_path = args.metrics if args.metrics.is_absolute() else root / args.metrics
    data = json.loads(metrics_path.read_text(encoding="utf-8"))
    catalog = data.get("metrics") or {}

    def fmt(key: str) -> str:
        if key not in catalog:
            return f"«MISSING:{key}»"
        entry = catalog[key]
        if isinstance(entry, dict) and "value" in entry:
            v = entry["value"]
        else:
            v = entry
        if v is None:
            return "null"
        return str(v)

    src = args.src if args.src.is_absolute() else root / args.src
    dst = args.dst if args.dst.is_absolute() else root / args.dst
    dst.mkdir(parents=True, exist_ok=True)

    n_files = 0
    n_repl = 0
    missing: set[str] = set()
    for f in sorted(src.glob("*.md")):
        if f.name.startswith("人工") or f.name.startswith("提示词"):
            continue
        text = f.read_text(encoding="utf-8")

        def repl(m: re.Match[str]) -> str:
            nonlocal n_repl
            key = m.group(1)
            if key not in catalog:
                missing.add(key)
            n_repl += 1
            return fmt(key)

        out = ANCHOR.sub(repl, text)
        header = (
            f"<!-- rendered from {f.name} using {metrics_path.as_posix()} "
            f"commit={data.get('commit') or catalog.get('freeze_commit', {}).get('value', '')} -->\n\n"
        )
        (dst / f.name).write_text(header + out, encoding="utf-8")
        n_files += 1

    print(f"PASS render_doc_metrics files={n_files} replacements={n_repl} → {dst}")
    if missing:
        print("FAIL missing keys:", ", ".join(sorted(missing)), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
