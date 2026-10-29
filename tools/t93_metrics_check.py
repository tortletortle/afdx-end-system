#!/usr/bin/env python3
"""Independent recompute of T93 afdx_app_top latency/jitter metrics."""
from __future__ import annotations

import argparse
import csv
import json
import re
import sys
from pathlib import Path

LAT_MAX_NS = 2_000_000
CLK_NS = 8


def bag_us_from_rtl() -> int:
    """BAG_US 独立来源：afdx_app_init.v 的参数默认值；找不到则回退 1000 并提示。"""
    p = Path(__file__).resolve().parent.parent / "rtl" / "top" / "afdx_app_init.v"
    if p.is_file():
        m = re.search(r"parameter\s+integer\s+BAG_US\s*=\s*(\d+)", p.read_text(encoding="utf-8"))
        if m:
            return int(m.group(1))
    print("WARN: afdx_app_init.v BAG_US not found, fallback 1000")
    return 1000


def check_vl_bag(outdir: Path, rows: list, summary: dict) -> bool:
    """按 VL 的相邻帧 TX SFD 间隔（GMII）：从原始 SFD 事件独立复算，min ≥ BAG。"""
    ev_path = outdir / "t93_gmii_sfd.csv"
    gap_path = outdir / "t93_vl_gap.csv"
    if not ev_path.is_file() or not gap_path.is_file():
        print(f"FAIL: missing {ev_path} or {gap_path}")
        return False
    ok = True
    bag_us = bag_us_from_rtl()
    bag_cyc = bag_us * 1000 // CLK_NS
    for key, want in (("bag_us", bag_us), ("bag_cyc", bag_cyc)):
        if int(summary.get(key, -1)) != want:
            print(f"MISMATCH {key}: python={want} verilog={summary.get(key)}")
            ok = False
    for old in ("bag_gap_max_cyc", "bag_gap_min_cyc"):
        if old in summary:
            print(f"FAIL: legacy key {old} present (renamed gmii_frame_gap_*)")
            ok = False

    events: dict[tuple[int, int], list[tuple[int, int]]] = {}
    for r in csv.DictReader(ev_path.open(encoding="utf-8")):
        events.setdefault((int(r["net"]), int(r["vl"])), []).append((int(r["seq"]), int(r["t_sfd"])))
    for k, v in events.items():
        v.sort()
        if [s for s, _ in v] != list(range(len(v))):
            print(f"FAIL: net{k[0]} vl{k[1]} seq not contiguous")
            ok = False

    # 每个 VL 的 A 网事件数 = 激励帧数；第 n 个事件落在该 VL 第 n 帧 [t_tx, t_rx] 内
    sent: dict[int, list[tuple[int, int]]] = {}
    for r in rows:
        sent.setdefault(int(r["vl"]), []).append((int(r["t_tx_first"]), int(r["t_rx_first"])))
    for vl, frames in sent.items():
        evs = events.get((0, vl), [])
        if len(evs) != len(frames):
            print(f"MISMATCH net0 vl{vl}: sfd events={len(evs)} frames sent={len(frames)}")
            ok = False
            continue
        for n, ((t_tx, t_rx), (_, t_sfd)) in enumerate(zip(frames, evs)):
            if not (t_tx <= t_sfd <= t_rx):
                print(f"FAIL net0 vl{vl} frame{n}: t_sfd={t_sfd} outside [{t_tx},{t_rx}]")
                ok = False
    for (net, vl), evs in events.items():
        if net == 0 and vl not in sent:
            print(f"FAIL: net0 SFD events for vl{vl} not sent by TB")
            ok = False

    py_gap: dict[tuple[int, int], tuple[int, int, int, int]] = {}
    for (net, vl), evs in events.items():
        ts = [t for _, t in evs]
        gaps = [b - a for a, b in zip(ts, ts[1:])]
        if gaps:
            py_gap[(net, vl)] = (len(ts), min(gaps), max(gaps), max(gaps) - min(gaps))
    tb_gap: dict[tuple[int, int], tuple[int, int, int, int]] = {}
    for r in csv.DictReader(gap_path.open(encoding="utf-8")):
        if r["gap_min_cyc"] != "":
            tb_gap[(int(r["net"]), int(r["vl"]))] = (
                int(r["frames"]), int(r["gap_min_cyc"]), int(r["gap_max_cyc"]), int(r["gap_range_cyc"]),
            )
    if py_gap != tb_gap:
        print(f"MISMATCH per-VL gap table: python={py_gap} tb={tb_gap}")
        ok = False
    if not py_gap:
        print("FAIL: no VL with >=2 frames")
        ok = False
    for (net, vl), (n, gmin, gmax, grng) in sorted(py_gap.items()):
        flag = "OK" if gmin >= bag_cyc else "FAIL"
        print(f"{flag} net{net} vl{vl} frames={n} gap_min={gmin} gap_max={gmax} range={grng} cyc (BAG={bag_cyc})")
        if gmin < bag_cyc:
            ok = False
    if py_gap:
        s_min = min(v[1] for v in py_gap.values())
        s_max = max(v[2] for v in py_gap.values())
        if int(summary.get("vl_gap_min_cyc", -1)) != s_min or int(summary.get("vl_gap_max_cyc", -1)) != s_max:
            print(f"MISMATCH vl_gap summary: python=({s_min},{s_max}) verilog=({summary.get('vl_gap_min_cyc')},{summary.get('vl_gap_max_cyc')})")
            ok = False
    for net_key, net in (("sfd_frames_a", 0), ("sfd_frames_b", 1)):
        n = sum(len(v) for (nn, _), v in events.items() if nn == net)
        if int(summary.get(net_key, -1)) != n:
            print(f"MISMATCH {net_key}: python={n} verilog={summary.get(net_key)}")
            ok = False
    if int(summary.get("vl_bag_viol", -1)) != 0:
        print(f"FAIL: vl_bag_viol={summary.get('vl_bag_viol')}")
        ok = False
    return ok


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("outdir", nargs="?", type=Path, default=Path("."))
    ap.add_argument("--tol-ns", type=int, default=8)
    args = ap.parse_args()

    csv_path = args.outdir / "t93_metrics.csv"
    js_path = args.outdir / "t93_verilog_summary.json"
    if not csv_path.is_file() or not js_path.is_file():
        print(f"FAIL: missing {csv_path} or {js_path}", file=sys.stderr)
        return 2

    summary = json.loads(js_path.read_text(encoding="utf-8").strip().splitlines()[0])
    rows = list(csv.DictReader(csv_path.open(encoding="utf-8")))
    ok = True

    a_lats: list[int] = []
    b_lats: list[int] = []
    for r in rows:
        t_tx = int(r["t_tx_first"])
        t_rx = int(r["t_rx_first"])
        lat_cyc = int(r["lat_cyc"])
        lat_ns = int(r["lat_ns"])
        py_cyc = t_rx - t_tx
        if py_cyc < 0:
            py_cyc = 0
        py_ns = py_cyc * CLK_NS
        if abs(py_cyc - lat_cyc) > 1 or abs(py_ns - lat_ns) > args.tol_ns:
            print(
                f"MISMATCH row phase={r['phase']} vl={r['vl']} fr={r['frame']}: "
                f"py={py_ns} csv={lat_ns}"
            )
            ok = False
        if lat_ns > LAT_MAX_NS:
            print(f"FAIL lat_ns={lat_ns} > {LAT_MAX_NS}")
            ok = False
        if r["phase"] == "A":
            a_lats.append(lat_ns)
        else:
            b_lats.append(lat_ns)

    if not a_lats or not b_lats:
        print("FAIL: missing phase A/B rows")
        ok = False
    else:
        py_a_max, py_a_min = max(a_lats), min(a_lats)
        py_a_jit = py_a_max - py_a_min
        py_b_max, py_b_min = max(b_lats), min(b_lats)
        py_b_jit = py_b_max - py_b_min
        for name, py_v, key in (
            ("phaseA_max_ns", py_a_max, "phaseA_max_ns"),
            ("phaseA_min_ns", py_a_min, "phaseA_min_ns"),
            ("phaseA_jit_ns", py_a_jit, "phaseA_jit_ns"),
            ("phaseB_max_ns", py_b_max, "phaseB_max_ns"),
            ("phaseB_min_ns", py_b_min, "phaseB_min_ns"),
            ("phaseB_jit_ns", py_b_jit, "phaseB_jit_ns"),
        ):
            sv = int(summary[key])
            if abs(py_v - sv) > args.tol_ns:
                print(f"MISMATCH {name}: python={py_v} verilog={sv}")
                ok = False
            else:
                print(f"OK {name}={py_v}")

    if int(summary.get("lat_max_ns", LAT_MAX_NS)) != LAT_MAX_NS:
        print("FAIL: summary lat_max_ns != 2000000")
        ok = False

    ok = check_vl_bag(args.outdir, rows, summary) and ok

    if ok:
        print("T93_METRICS_CHECK PASS")
        return 0
    print("T93_METRICS_CHECK FAIL", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
