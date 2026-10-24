#!/usr/bin/env python3
"""Independent recompute of T89 metrics CSV vs Verilog summary JSON.

C0 口径：sfd2sfd_ns 保留（wire loopback 构造为 0）；
主对口判据为 ES 贡献：
  tx_commit2sfd_ns = (t_tx_sfd - t_commit)*8
  rx_sfd2host_ns   = (t_rx_ready - t_rx_sfd)*8
  es_total_max_ns  = max(tx_commit2sfd) + max(rx_sfd2host)  ≤ 2_000_000
"""
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
    required = {
        "phase",
        "vl",
        "frame",
        "t_commit",
        "t_sof",
        "t_eof",
        "t_rx_ready",
        "t_tx_sfd",
        "t_rx_sfd",
        "sfd2sfd_ns",
        "tx_commit2sfd_ns",
        "rx_sfd2host_ns",
    }
    if rows and not required.issubset(rows[0].keys()):
        print(f"FAIL: CSV missing columns; have={sorted(rows[0].keys())}", file=sys.stderr)
        return 2

    max_tx = 0
    max_rx = 0
    max_sfd2sfd = 0
    max_c2s = 0
    max_s2h = 0
    vmin: dict[int, int] = {}
    vmax: dict[int, int] = {}
    vcount: dict[int, int] = {}
    sfd_min: dict[int, int] = {}
    sfd_max: dict[int, int] = {}
    e2e_min: dict[int, int] = {}
    e2e_max: dict[int, int] = {}
    sfd_pairs = 0
    es_pairs = 0

    for r in rows:
        phase = r["phase"]
        t_commit = int(r["t_commit"])
        t_eof = int(r["t_eof"])
        t_rx = int(r["t_rx_ready"] or 0)
        t_tx_sfd = int(r["t_tx_sfd"] or 0)
        t_rx_sfd = int(r["t_rx_sfd"] or 0)
        sfd_ns = int(r["sfd2sfd_ns"])
        c2s_ns = int(r["tx_commit2sfd_ns"])
        s2h_ns = int(r["rx_sfd2host_ns"])

        if phase.startswith("tx") or phase == "jit32" or phase in ("rx_lat", "e2e_sfd"):
            lat = t_eof - t_commit
            if lat > max_tx:
                max_tx = lat
        if phase == "jit32":
            vl = int(r["vl"])
            lat = t_eof - t_commit
            vmin[vl] = lat if vl not in vmin else min(vmin[vl], lat)
            vmax[vl] = lat if vl not in vmax else max(vmax[vl], lat)
            vcount[vl] = vcount.get(vl, 0) + 1
        if phase in ("rx_lat", "e2e_sfd") and t_rx and t_eof:
            lat = t_rx - t_eof
            if lat > max_rx:
                max_rx = lat

        if t_tx_sfd and t_rx_sfd and sfd_ns >= 0:
            sfd_pairs += 1
            if sfd_ns > 2_000_000:
                print(f"FAIL: sfd2sfd_ns={sfd_ns} > 2ms phase={phase}")
                return 1
            if sfd_ns > max_sfd2sfd:
                max_sfd2sfd = sfd_ns
            recon = abs(t_rx_sfd - t_tx_sfd) * 8
            if abs(recon - sfd_ns) > 16:
                print(f"MISMATCH sfd2sfd_ns csv={sfd_ns} recompute={recon}")
                return 1

        if t_tx_sfd and t_commit and c2s_ns >= 0:
            recon_c2s = abs(t_tx_sfd - t_commit) * 8
            if abs(recon_c2s - c2s_ns) > 16:
                print(f"MISMATCH tx_commit2sfd_ns csv={c2s_ns} recompute={recon_c2s}")
                return 1
            if c2s_ns > max_c2s:
                max_c2s = c2s_ns
        if t_rx and t_rx_sfd and s2h_ns >= 0:
            recon_s2h = abs(t_rx - t_rx_sfd) * 8
            if abs(recon_s2h - s2h_ns) > 16:
                print(f"MISMATCH rx_sfd2host_ns csv={s2h_ns} recompute={recon_s2h}")
                return 1
            if s2h_ns > max_s2h:
                max_s2h = s2h_ns
            es_pairs += 1

        if phase == "e2e_sfd":
            vl = int(r["vl"])
            if sfd_ns >= 0:
                cyc = sfd_ns // 8
                sfd_min[vl] = cyc if vl not in sfd_min else min(sfd_min[vl], cyc)
                sfd_max[vl] = cyc if vl not in sfd_max else max(sfd_max[vl], cyc)
            if t_rx and t_commit:
                elat = t_rx - t_commit
                e2e_min[vl] = elat if vl not in e2e_min else min(e2e_min[vl], elat)
                e2e_max[vl] = elat if vl not in e2e_max else max(e2e_max[vl], elat)

    max_jit = 0
    for vl in vmin:
        max_jit = max(max_jit, vmax[vl] - vmin[vl])
    max_jit_sfd = 0
    for vl in sfd_min:
        max_jit_sfd = max(max_jit_sfd, sfd_max[vl] - sfd_min[vl])
    max_jit_e2e = 0
    for vl in e2e_min:
        max_jit_e2e = max(max_jit_e2e, e2e_max[vl] - e2e_min[vl])

    es_total = max_c2s + max_s2h

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
        if abs(py_v - sv_v) > 2:
            print(f"MISMATCH {name}: python={py_v} verilog={sv_v}")
            ok = False
        else:
            print(f"OK {name}: {py_v}")

    if "max_sfd2sfd_ns" in summary:
        if abs(max_sfd2sfd - int(summary["max_sfd2sfd_ns"])) > 16:
            print(
                f"MISMATCH max_sfd2sfd_ns: python={max_sfd2sfd} "
                f"verilog={summary['max_sfd2sfd_ns']}"
            )
            ok = False
        else:
            print(f"OK max_sfd2sfd_ns: {max_sfd2sfd} (wire loopback, value=0 by construction)")

    for key, py_v in (
        ("max_tx_commit2sfd_ns", max_c2s),
        ("max_rx_sfd2host_ns", max_s2h),
        ("es_total_max_ns", es_total),
    ):
        if key not in summary:
            print(f"FAIL: summary missing {key}")
            ok = False
            continue
        if abs(py_v - int(summary[key])) > 16:
            print(f"MISMATCH {key}: python={py_v} verilog={summary[key]}")
            ok = False
        else:
            print(f"OK {key}: {py_v}")

    if "max_jit_sfd_cyc" in summary:
        if abs(max_jit_sfd - int(summary["max_jit_sfd_cyc"])) > 2:
            print(
                f"MISMATCH max_jit_sfd_cyc: python={max_jit_sfd} "
                f"verilog={summary['max_jit_sfd_cyc']}"
            )
            ok = False
        else:
            print(f"OK max_jit_sfd_cyc: {max_jit_sfd}")
    if "max_jit_e2e_cyc" in summary:
        if abs(max_jit_e2e - int(summary["max_jit_e2e_cyc"])) > 2:
            print(
                f"MISMATCH max_jit_e2e_cyc: python={max_jit_e2e} "
                f"verilog={summary['max_jit_e2e_cyc']}"
            )
            ok = False
        else:
            print(f"OK max_jit_e2e_cyc: {max_jit_e2e}")

    if sfd_pairs < 1:
        print("FAIL: no SFD→SFD pairs in CSV")
        ok = False
    else:
        print(f"OK sfd_pairs={sfd_pairs}")
    if es_pairs < 1:
        print("FAIL: no ES RX sfd2host samples")
        ok = False
    else:
        print(f"OK es_rx_pairs={es_pairs}")

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
    if max_sfd2sfd > 2_000_000:
        print("FAIL: max_sfd2sfd_ns exceeds 2ms")
        ok = False
    if es_total > 2_000_000:
        print(f"FAIL: es_total_max_ns={es_total} > 2ms")
        ok = False
    if us(max_jit) > bound_40 + args.tol_us:
        print(f"FAIL: jitter {us(max_jit):.3f}us > 40+Sigma {bound_40}us")
        ok = False
    if us(max_jit_sfd) > bound_40 + args.tol_us:
        print(f"FAIL: sfd jitter {us(max_jit_sfd):.3f}us > 40+Sigma")
        ok = False
    if us(max_jit_e2e) > bound_40 + args.tol_us:
        print(f"FAIL: e2e jitter {us(max_jit_e2e):.3f}us > 40+Sigma")
        ok = False

    print(
        f"SUMMARY max_tx_ns={ns(max_tx)} max_rx_ns={ns(max_rx)} max_jit_ns={ns(max_jit)} "
        f"max_sfd2sfd_ns={max_sfd2sfd} max_tx_commit2sfd_ns={max_c2s} "
        f"max_rx_sfd2host_ns={max_s2h} es_total_max_ns={es_total} "
        f"jit_sfd_ns={ns(max_jit_sfd)} jit_e2e_ns={ns(max_jit_e2e)} "
        f"bound_40sig_us={bound_40}"
    )
    print("NOTE: sfd2sfd wire loopback, no network segment, value=0 by construction")
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
