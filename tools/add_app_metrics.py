#!/usr/bin/env python3
"""Append T92-T95 and afdx_app_top synthesis keys to a copy of a freeze metrics.json.

Every value is parsed from a console/log line of the given run directories and carries
source_file / source_line / file_sha256 like the existing entries. The base file is never modified.

Usage:
  python tools/add_app_metrics.py --base out/p9_freeze_dfac58a/metrics.json \
      --out out/p10_draft/metrics.json \
      --t92 sim/out/<run> --t93 sim/out/<run> --t94 sim/out/<run> --t95 sim/out/<run> \
      --synth out/app_top_synth_bram3 [--core-cells 106241 --core-alt 507]
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def sha256(p: Path) -> str:
    h = hashlib.sha256()
    with p.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def rel(p: Path) -> str:
    try:
        return p.resolve().relative_to(ROOT).as_posix()
    except ValueError:
        return p.as_posix()


def find(path: Path, pattern: str) -> tuple[int, re.Match[str]]:
    """Last line matching pattern (a run may print the verdict line once; take the last)."""
    rx = re.compile(pattern)
    hit = None
    for no, line in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
        m = rx.search(line)
        if m:
            hit = (no, m)
    if hit is None:
        raise SystemExit(f"FAIL: pattern not found in {path}: {pattern}")
    return hit


def entry(key, value, unit, grade, path: Path, line: int, note: str | None = None) -> dict:
    e = {
        "key": key,
        "value": value,
        "unit": unit,
        "grade": grade,
        "source_file": rel(path),
        "source_line": line,
        "file_sha256": sha256(path),
    }
    if note:
        e["note"] = note
    return e


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--base", type=Path, required=True)
    ap.add_argument("--out", type=Path, required=True)
    for t in ("t92", "t93", "t94", "t95"):
        ap.add_argument(f"--{t}", type=Path, required=True, help=f"regression run dir containing {t.upper()}_console.txt")
    ap.add_argument("--synth", type=Path, required=True, help="out/app_top_synth_* dir with run_status.json")
    ap.add_argument("--core-cells", type=int, default=106241)
    ap.add_argument("--core-alt", type=int, default=507)
    args = ap.parse_args()

    base = json.loads(args.base.read_text(encoding="utf-8"))
    m = base["metrics"]
    add: dict[str, dict] = {}

    c92 = args.t92 / "T92_console.txt"
    n, g = find(c92, r"T92 PASS checks=(\d+) drop=(\d+) submit=(\d+) deliver=(\d+)")
    add["t92_pass"] = entry("t92_pass", "PASS", "enum", "P", c92, n)
    add["t92_checks"] = entry("t92_checks", int(g[1]), "count", "P", c92, n)

    c93 = args.t93 / "T93_console.txt"
    n, g = find(c93, r"T93 PASS checks=(\d+) A_max_ns=(\d+) B_max_ns=(\d+) A_jit_ns=(\d+)")
    add["t93_pass"] = entry("t93_pass", "PASS", "enum", "P", c93, n)
    add["t93_a_max_ns"] = entry("t93_a_max_ns", int(g[2]), "ns", "P", c93, n)
    add["t93_b_max_ns"] = entry("t93_b_max_ns", int(g[3]), "ns", "P", c93, n)
    add["t93_a_jit_ns"] = entry("t93_a_jit_ns", int(g[4]), "ns", "P", c93, n)
    n, g = find(c93, r"T93_METRIC phaseB max_ns=(\d+) min_ns=(\d+) jit_ns=(\d+)")
    add["t93_b_jit_ns"] = entry("t93_b_jit_ns", int(g[3]), "ns", "P", c93, n)
    n, g = find(
        c93,
        r"T93_METRIC vl_bag bag_cyc=(\d+) vl_with_gap=(\d+) gap_min_cyc=(\d+) gap_max_cyc=(\d+) viol=(\d+)",
    )
    add["t93_bag_cyc"] = entry("t93_bag_cyc", int(g[1]), "cycles", "P", c93, n)
    add["t93_vl_gap_min_cyc"] = entry("t93_vl_gap_min_cyc", int(g[3]), "cycles", "P", c93, n)
    add["t93_vl_bag_viol"] = entry("t93_vl_bag_viol", int(g[5]), "count", "P", c93, n)

    c94 = args.t94 / "T94_console.txt"
    n, g = find(c94, r"T94 PASS checks=(\d+) steady_rx_mbps=([\d.]+) submit=(\d+) deliver=(\d+)")
    add["t94_pass"] = entry("t94_pass", "PASS", "enum", "P", c94, n)
    add["t94_steady_rx_mbps"] = entry("t94_steady_rx_mbps", round(float(g[2]), 2), "Mbps", "P", c94, n)
    add["t94_submit"] = entry("t94_submit", int(g[3]), "count", "P", c94, n)
    add["t94_deliver"] = entry("t94_deliver", int(g[4]), "count", "P", c94, n)

    c95 = args.t95 / "T95_console.txt"
    n, g = find(c95, r"T95 PASS checks=(\d+) submit=(\d+) deliver=(\d+) unconf=(\d+)")
    add["t95_pass"] = entry("t95_pass", "PASS", "enum", "P", c95, n)
    add["t95_submit"] = entry("t95_submit", int(g[2]), "count", "P", c95, n)
    add["t95_deliver"] = entry("t95_deliver", int(g[3]), "count", "P", c95, n)
    add["t95_unconf"] = entry("t95_unconf", int(g[4]), "count", "P", c95, n)

    rs = args.synth / "run_status.json"
    st = json.loads(rs.read_text(encoding="utf-8"))
    if st.get("overall") != "SYNTHESIS_PASS":
        raise SystemExit(f"FAIL: {rs} overall={st.get('overall')}")
    lines = rs.read_text(encoding="utf-8").splitlines()

    def jl(key: str) -> int:
        return next(i for i, ln in enumerate(lines, 1) if f'"{key}"' in ln)

    add["app_synth_pass"] = entry("app_synth_pass", "PASS", "enum", "P", rs, jl("overall"),
                                  "eLinx memory_bram+stat on afdx_app_top; not Fit/STA/GUI LUT")
    add["app_synth_cells"] = entry("app_synth_cells", st["cells"], "count", "I", rs, jl("cells"))
    add["app_synth_altsyncram"] = entry("app_synth_altsyncram", st["altsyncram"], "count", "I", rs, jl("altsyncram"))
    add["app_synth_delta_cells"] = entry("app_synth_delta_cells", st["cells"] - args.core_cells, "count", "I", rs, jl("cells"),
                                         f"minus core {args.core_cells}")
    add["app_synth_delta_altsyncram"] = entry("app_synth_delta_altsyncram", st["altsyncram"] - args.core_alt, "count", "I", rs,
                                              jl("altsyncram"), f"minus core {args.core_alt}")

    clash = sorted(set(add) & set(m))
    if clash:
        raise SystemExit(f"FAIL: keys already in base: {clash}")
    m.update(add)
    base["updated_local"] = datetime.now().astimezone().strftime("%Y-%m-%dT%H:%M:%S%z")
    base["app_metrics_base"] = rel(args.base)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(base, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"PASS add_app_metrics keys+={len(add)} -> {args.out}")
    for k, v in add.items():
        print(f"  {k} = {v['value']} ({v['grade']})  {v['source_file']}:{v['source_line']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
