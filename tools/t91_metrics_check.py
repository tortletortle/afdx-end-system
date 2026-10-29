#!/usr/bin/env python3
"""Independent recompute of T91 gate/RTL public-port throughput metrics.

Reads t91_metrics.csv + t91_verilog_summary.json (cwd / OutDir style like T90).

Default TB: NVL=16, ROUNDS=1, PLEN=1024, equal Q20 shares, BAG=1000us.
Pass: tx_a / tx_b / rx_dedup Mbps all >= 100; deliver counts match.
"""
from __future__ import annotations

import argparse
import csv
import json
import sys
from pathlib import Path

MIN_MBPS = 100.0
NS_PER_CYC = 8.0


def mbps(bytes_: int, window_cycles: int, ns_per_cyc: float = NS_PER_CYC) -> float:
    if window_cycles <= 0:
        return 0.0
    return bytes_ * 8.0 / (window_cycles * ns_per_cyc * 1e-3)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--csv",
        type=Path,
        default=None,
        help="path to t91_metrics.csv (default: <outdir>/t91_metrics.csv)",
    )
    ap.add_argument(
        "--summary",
        type=Path,
        default=None,
        help="path to t91_verilog_summary.json",
    )
    ap.add_argument(
        "outdir",
        nargs="?",
        type=Path,
        default=Path("."),
        help="dir containing csv+summary when --csv/--summary omitted",
    )
    ap.add_argument("--tol-mbps", type=float, default=0.05)
    ap.add_argument("--min-mbps", type=float, default=MIN_MBPS)
    args = ap.parse_args()

    csv_path = args.csv or (args.outdir / "t91_metrics.csv")
    js_path = args.summary or (args.outdir / "t91_verilog_summary.json")
    if not csv_path.is_file() or not js_path.is_file():
        print(f"FAIL: missing {csv_path} or {js_path}", file=sys.stderr)
        return 2

    summary = json.loads(js_path.read_text(encoding="utf-8").strip().splitlines()[0])
    rows = list(csv.DictReader(csv_path.open(encoding="utf-8")))
    required = {
        "direction",
        "verified_payload_bytes",
        "window_cycles",
        "clock_period_ns",
        "payload_mbps",
    }
    if not rows or not required.issubset(rows[0].keys()):
        print(
            f"FAIL: CSV columns; have={sorted(rows[0].keys()) if rows else []}",
            file=sys.stderr,
        )
        return 2

    ok = True
    window = int(summary.get("window_cycles", 0))
    tx_a = int(summary.get("tx_bytes_a", 0))
    tx_b = int(summary.get("tx_bytes_b", 0))
    rx_d = int(summary.get("rx_dedup_bytes", 0))
    nvl = int(summary.get("nvl", -1))
    rounds = int(summary.get("rounds", -1))
    expect_rx = int(summary.get("expect_rx", nvl * rounds))
    rx_deliver = int(summary.get("rx_deliver", -1))

    if window <= 0:
        print("FAIL: window_cycles <= 0")
        ok = False

    py_tx_a = mbps(tx_a, window)
    py_tx_b = mbps(tx_b, window)
    py_rx = mbps(rx_d, window)

    def check_mbps(name: str, py_v: float, key: str) -> None:
        nonlocal ok
        sv = float(summary.get(key, -1))
        if abs(py_v - sv) > args.tol_mbps:
            print(f"MISMATCH {name}: python={py_v:.6f} verilog={sv:.6f}")
            ok = False
        else:
            print(f"OK {name}={py_v:.6f}")
        if py_v < args.min_mbps - args.tol_mbps:
            print(f"FAIL: {name} {py_v:.6f} < {args.min_mbps} Mbps")
            ok = False

    check_mbps("tx_mbps_a", py_tx_a, "tx_mbps_a")
    check_mbps("tx_mbps_b", py_tx_b, "tx_mbps_b")
    check_mbps("rx_dedup_mbps", py_rx, "rx_dedup_mbps")

    by_dir = {r["direction"].strip(): r for r in rows}
    for key, py_v, bytes_ in (
        ("tx_a", py_tx_a, tx_a),
        ("tx_b", py_tx_b, tx_b),
        ("rx_dedup", py_rx, rx_d),
    ):
        if key not in by_dir:
            print(f"FAIL: CSV missing direction={key}")
            ok = False
            continue
        row = by_dir[key]
        if int(row["verified_payload_bytes"]) != bytes_:
            print(
                f"MISMATCH CSV bytes {key}: "
                f"csv={row['verified_payload_bytes']} summary={bytes_}"
            )
            ok = False
        if int(row["window_cycles"]) != window:
            print(
                f"MISMATCH CSV window {key}: "
                f"csv={row['window_cycles']} summary={window}"
            )
            ok = False
        csv_mbps = float(row["payload_mbps"])
        if abs(csv_mbps - py_v) > args.tol_mbps:
            print(f"MISMATCH CSV mbps {key}: csv={csv_mbps:.6f} python={py_v:.6f}")
            ok = False

    # 交付数必须精确 == NVL×ROUNDS（整场，含暖机轮）
    if rx_deliver != expect_rx:
        print(f"FAIL: rx_deliver={rx_deliver} != expect_rx={expect_rx} (NVL*ROUNDS)")
        ok = False
    else:
        print(f"OK rx_deliver={rx_deliver} (== {nvl}*{rounds})")

    if int(summary.get("errors", 1)) != 0:
        print("FAIL: verilog summary errors!=0")
        ok = False

    plen = int(summary.get("plen", 1024))
    claim = str(summary.get("claim_mode", "steady" if rounds >= 2 else "probe"))
    # 稳态：吞吐字节只计第 2..ROUNDS 轮；探速 ROUNDS=1：整场
    steady_rounds = (rounds - 1) if (rounds >= 2 and claim != "probe") else rounds
    expect_bytes = nvl * steady_rounds * plen
    if tx_a != expect_bytes or tx_b != expect_bytes or rx_d != expect_bytes:
        print(
            f"FAIL: steady payload bytes expect {expect_bytes} "
            f"(nvl*{steady_rounds}*plen) got tx_a={tx_a} tx_b={tx_b} rx_dedup={rx_d}"
        )
        ok = False
    else:
        print(
            f"OK steady_payload_bytes={expect_bytes} "
            f"(nvl*{steady_rounds}*plen claim={claim})"
        )

    # 独立复算：首字节应与 gen_t91_payload_vec 公式一致
    try:
        from gen_t91_payload_vec import payload_byte as golden_byte
    except ImportError:
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        from gen_t91_payload_vec import payload_byte as golden_byte
    sample = golden_byte(0, 0, 0)
    if sample != ((0 * 17 + 0 * 29 + 0 * 13 + 0x53) & 0xFF):
        print("FAIL: golden formula sanity")
        ok = False
    else:
        print(f"OK golden_byte(0,0,0)=0x{sample:02X} (gen_t91_payload_vec)")

    w_start = int(summary.get("window_start", -1))
    w_stop = int(summary.get("window_stop", -1))
    print(
        f"INFO nvl={nvl} rounds={rounds} window_cycles={window} "
        f"window_start={w_start} window_stop={w_stop} "
        f"min_mbps={args.min_mbps} claim={claim}"
    )

    if ok:
        print("T91_METRICS_CHECK PASS")
        return 0
    print("T91_METRICS_CHECK FAIL")
    return 1


if __name__ == "__main__":
    sys.exit(main())
