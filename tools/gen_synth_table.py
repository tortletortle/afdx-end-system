#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Generate a checked *submodule-only* synthesis table from eLinx logs.

Usage: python tools/gen_synth_table.py --out out/arena-debug/checks/B9_table.md
The verdict checks the ENTIRE log for ^ERROR, including CHECK after stat.
It does not prove AFDX_top synthesis, placement, or static timing closure.
"""
import argparse
from pathlib import Path
import re
import shlex
import sys

ROOT = Path(__file__).resolve().parents[1]
PRJ = ROOT / "elinx" / "prj"


def table():
    scripts = sorted(PRJ.glob("sub_*.ys"))
    rows = ["| 子模块 | 实际 RTL 路径 | 全日志核验 | Cells（仅统计） |",
            "|---|---|---|---:|"]
    passed = 0
    for script in scripts:
        name = script.stem.removeprefix("sub_")
        script_text = script.read_text(encoding="utf-8")
        match = re.search(r"^read_verilog\s+(.+?)\s*$", script_text, re.M)
        sources = [Path(x) for x in shlex.split(match.group(1))] if match else []
        sources = [p if p.is_absolute() else ROOT / p for p in sources]
        paths = []
        for source in sources:
            try:
                paths.append(source.relative_to(ROOT).as_posix())
            except ValueError:
                paths.append("OUTSIDE_WORKSPACE")
        path_ok = bool(sources) and all(p.is_file() and rel.startswith("rtl/")
                                        for p, rel in zip(sources, paths))
        primary = next((rel for p, rel in zip(sources, paths)
                        if p.name == f"{name}.v"), "MISSING")
        relative = primary + (" (依赖: " + ", ".join(p for p in paths if p != primary) + ")"
                              if len(paths) > 1 else "")
        path_ok = path_ok and primary != "MISSING"
        log = script.with_suffix(".log")
        text = log.read_text(encoding="utf-8", errors="replace") if log.is_file() else ""
        errors = re.findall(r"^ERROR\b", text, re.M)
        success = "Yosys execute success!" in text
        ok = path_ok and success and not errors
        passed += int(ok)
        counts = re.findall(r"^\s*Number of cells:\s*(\d+)", text, re.M)
        cells = counts[-1] if ok and counts else "—"
        verdict = "PASS" if ok else f"FAIL (errors={len(errors)}, marker={success}, source={path_ok})"
        rows.append(f"| `{name}` | `{relative}` | **{verdict}** | {cells} |")
    rows.append(f"\n仅子模块日志：{passed}/{len(scripts)} PASS；判据=源码存在+全日志无 `^ERROR`+执行成功标记。")
    rows.append("**不包含大容量存储子模块或 AFDX_top；不代表顶层综合/STA。**")
    return "\n".join(rows) + "\n", passed == len(scripts) and len(scripts) == 12


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, help="write UTF-8 Markdown table here")
    args = parser.parse_args()
    markdown, ok = table()
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(markdown, encoding="utf-8")
    else:
        print(markdown, end="")
    sys.exit(0 if ok else 1)
