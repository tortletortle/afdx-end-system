#!/usr/bin/env python3
"""Independent recompute of T95 afdx_app_top 128VL metrics."""
from __future__ import annotations

import argparse
import csv
import json
import sys
from pathlib import Path


def plen_of(vl: int) -> int:
    if vl < 32:
        return 17
    if vl < 64:
        return 256
    if vl < 96:
        return 1024
    return 1471


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("outdir", nargs="?", type=Path, default=Path("."))
    args = ap.parse_args()

    csv_path = args.outdir / "t95_metrics.csv"
    js_path = args.outdir / "t95_verilog_summary.json"
    if not csv_path.is_file() or not js_path.is_file():
        print(f"FAIL: missing {csv_path} or {js_path}", file=sys.stderr)
        return 2

    summary = json.loads(js_path.read_text(encoding="utf-8").strip().splitlines()[0])
    rows = list(csv.DictReader(csv_path.open(encoding="utf-8")))
    ok = True

    nvl_tx = int(summary["nvl_tx"])
    nvl_rx = int(summary["nvl_rx"])
    if nvl_tx != 128 or nvl_rx != 126:
        print(f"FAIL: nvl_tx/rx {nvl_tx}/{nvl_rx}")
        ok = False
    if int(summary["submit"]) != 128:
        print(f"FAIL: submit={summary['submit']}")
        ok = False
    if int(summary["deliver"]) != 126:
        print(f"FAIL: deliver={summary['deliver']}")
        ok = False
    if int(summary["drop"]) != 0:
        print(f"FAIL: drop={summary['drop']}")
        ok = False
    expect_u = int(summary["expect_unconf"])
    if expect_u != 4:
        print(f"FAIL: expect_unconf={expect_u}")
        ok = False
    if int(summary["unconf_delta"]) != expect_u:
        print(
            f"FAIL: unconf_delta={summary['unconf_delta']} expect={expect_u}"
        )
        ok = False

    if len(rows) != 128:
        print(f"FAIL: csv rows={len(rows)} expect 128")
        ok = False
    for r in rows:
        vl = int(r["vl"])
        if int(r["plen"]) != plen_of(vl):
            print(f"FAIL: vl={vl} plen csv={r['plen']} expect={plen_of(vl)}")
            ok = False
            break

    if ok:
        print("T95_METRICS_CHECK PASS")
        return 0
    print("T95_METRICS_CHECK FAIL", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
