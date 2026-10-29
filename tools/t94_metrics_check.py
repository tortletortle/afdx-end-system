#!/usr/bin/env python3
"""Independent recompute of T94 afdx_app_top throughput metrics."""
from __future__ import annotations

import argparse
import csv
import json
import sys
from pathlib import Path

MIN_MBPS = 100.0


def mbps(bytes_: int, window_cycles: int, ns_per_cyc: float) -> float:
    if window_cycles <= 0:
        return 0.0
    return bytes_ * 8.0 / (window_cycles * ns_per_cyc * 1e-3)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("outdir", nargs="?", type=Path, default=Path("."))
    ap.add_argument("--tol-mbps", type=float, default=0.05)
    ap.add_argument("--min-mbps", type=float, default=MIN_MBPS)
    args = ap.parse_args()

    csv_path = args.outdir / "t94_metrics.csv"
    js_path = args.outdir / "t94_verilog_summary.json"
    if not csv_path.is_file() or not js_path.is_file():
        print(f"FAIL: missing {csv_path} or {js_path}", file=sys.stderr)
        return 2

    summary = json.loads(js_path.read_text(encoding="utf-8").strip().splitlines()[0])
    rows = {r["direction"]: r for r in csv.DictReader(csv_path.open(encoding="utf-8"))}
    ok = True

    nvl = int(summary["nvl"])
    rounds = int(summary["rounds"])
    plen = int(summary["plen"])
    expect = int(summary["expect"])
    if expect != nvl * rounds:
        print(f"FAIL: expect {expect} != nvl*rounds {nvl * rounds}")
        ok = False
    if int(summary["submit"]) != expect or int(summary["deliver"]) != expect:
        print(
            f"FAIL: submit/deliver "
            f"{summary['submit']}/{summary['deliver']} expect {expect}"
        )
        ok = False
    if int(summary["drop"]) != 0:
        print(f"FAIL: drop={summary['drop']}")
        ok = False

    ns = float(summary.get("clock_period_ns", 8))
    for key, bytes_key, cyc_key, mbps_key in (
        ("tx", "tx_bytes", "window_cycles", "tx_payload_mbps"),
        ("rx", "rx_bytes", "window_cycles", "rx_payload_mbps"),
        ("rx_steady", "steady_rx_bytes", "steady_cycles", "steady_rx_mbps"),
    ):
        if key not in rows:
            print(f"FAIL: CSV missing direction={key}")
            ok = False
            continue
        b = int(summary[bytes_key])
        cyc = int(summary[cyc_key])
        py = mbps(b, cyc, ns)
        sv = float(summary[mbps_key])
        if abs(py - sv) > args.tol_mbps:
            print(f"MISMATCH {key}: python={py:.6f} verilog={sv:.6f}")
            ok = False
        else:
            print(f"OK {key}={py:.6f}")
        csv_mbps = float(rows[key]["payload_mbps"])
        if abs(csv_mbps - py) > args.tol_mbps:
            print(f"MISMATCH CSV {key}: csv={csv_mbps:.6f} python={py:.6f}")
            ok = False

    steady = float(summary["steady_rx_mbps"])
    if steady < args.min_mbps - args.tol_mbps:
        print(f"FAIL: steady_rx_mbps={steady:.6f} < {args.min_mbps}")
        ok = False
    else:
        print(f"OK steady_rx_mbps>={args.min_mbps}")

    expect_steady = 2 * nvl * plen
    if int(summary["steady_rx_bytes"]) != expect_steady:
        print(
            f"FAIL: steady_rx_bytes {summary['steady_rx_bytes']} "
            f"!= 2*nvl*plen {expect_steady}"
        )
        ok = False

    if ok:
        print("T94_METRICS_CHECK PASS")
        return 0
    print("T94_METRICS_CHECK FAIL", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
