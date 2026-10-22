#!/usr/bin/env python3
"""Independent recompute of T89 metrics CSV vs Verilog summary JSON."""
from __future__ import annotations

import argparse
import csv
import json
import sys
from pathlib import Path


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("outdir", type=Path, help="sim out dir containing csv+json")
    ap.add_argument("--tol-us", type=float, default=0.05)
    args = ap.parse_args()
    csv_path = args.outdir / "t89_metrics.csv"
    js_path = args.outdir / "t89_verilog_summary.json"
    if not csv_path.is_file() or not js_path.is_file():
        print(f"FAIL: missing {csv_path.name} or {js_path.name}", file=sys.stderr)
        return 2
    summary = json.loads(js_path.read_text(encoding="utf-8").strip().splitlines()[0])
    rows = list(csv.DictReader(csv_path.open(encoding="utf-8")))
    max_tx = 0
    max_rx = 0
    # per-vl latency range for jit32
    vmin: dict[int, int] = {}
    vmax: dict[int, int] = {}
    vcount: dict[int, int] = {}
    for r in rows:
        phase = r["phase"]
        t_commit = int(r["t_commit"])
        t_eof = int(r["t_eof"])
        t_rx = int(r["t_rx_ready"])
        if phase.startswith("tx") or phase == "jit32":
            lat = t_eof - t_commit
            if lat > max_tx:
                max_tx = lat
            if phase == "jit32":
                vl = int(r["vl"])
                vmin[vl] = lat if vl not in vmin else min(vmin[vl], lat)
                vmax[vl] = lat if vl not in vmax else max(vmax[vl], lat)
                vcount[vl] = vcount.get(vl, 0) + 1
        if phase == "rx_lat" and t_rx and t_eof:
            lat = t_rx - t_eof
            if lat > max_rx:
                max_rx = lat
    max_jit = 0
    for vl in vmin:
        max_jit = max(max_jit, vmax[vl] - vmin[vl])

    def ns(cyc: int) -> int:
        return cyc * 8

    def us(cyc: int) -> float:
        return cyc * 0.008

    bound_40 = int(summary.get("bound_40sig_us", 141))
    frames_req = int(summary.get("frames_per_vl", 3))
    ok = True
    checks = [
        ("max_tx_cyc", max_tx, int(summary["max_tx_cyc"])),
        ("max_rx_cyc", max_rx, int(summary["max_rx_cyc"])),
        ("max_jit_cyc", max_jit, int(summary["max_jit_cyc"])),
    ]
    for name, py_v, sv_v in checks:
        if abs(py_v - sv_v) > 2:  # allow 2-cycle edge skew
            print(f"MISMATCH {name}: python={py_v} verilog={sv_v}")
            ok = False
        else:
            print(f"OK {name}: {py_v}")

    if "max_tx_ns" in summary:
        for key, cyc in (("max_tx_ns", max_tx), ("max_rx_ns", max_rx), ("max_jit_ns", max_jit)):
            if abs(ns(cyc) - int(summary[key])) > 16:
                print(f"MISMATCH {key}: python={ns(cyc)} verilog={summary[key]}")
                ok = False

    if frames_req < 3:
        print(f"FAIL: frames_per_vl={frames_req} < 3")
        ok = False
    short = [vl for vl, n in vcount.items() if n < frames_req]
    if short:
        print(f"FAIL: jit32 frames/VL below {frames_req}: {short[:8]}...")
        ok = False
    elif vcount:
        print(f"OK frames_per_vl>={frames_req} (seen min={min(vcount.values())})")

    if us(max_tx) > 2000 + args.tol_us or us(max_rx) > 2000 + args.tol_us:
        print("FAIL: latency exceeds 2ms")
        ok = False
    if us(max_jit) > bound_40 + args.tol_us:
        print(f"FAIL: jitter {us(max_jit):.3f}us > 40+Sigma {bound_40}us")
        ok = False

    print(
        f"SUMMARY max_tx_ns={ns(max_tx)} max_rx_ns={ns(max_rx)} max_jit_ns={ns(max_jit)} "
        f"(us {us(max_tx):.3f}/{us(max_rx):.3f}/{us(max_jit):.3f}) bound_40sig_us={bound_40}"
    )
    if int(summary.get("errors", 1)) != 0:
        print("FAIL: verilog summary errors!=0")
        ok = False
    if ok:
        print("T89_METRICS_CHECK PASS")
        return 0
    print("T89_METRICS_CHECK FAIL")
    return 1


if __name__ == "__main__":
    sys.exit(main())
