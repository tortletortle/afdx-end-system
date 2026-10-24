#!/usr/bin/env python3
"""Independent recompute of T90 metrics (C1 r5: 128 TX / 126 RX).

Reads t90_metrics.csv + t90_verilog_summary.json from an outdir.

r5 口径：
  TX 128 VL（口 16..143），CTL 0x051F；RX 仅 VL0..125（126 口，避开 6/7 与 TX）。
  VL126/127 不配 RX → DROP_CNT_K unconf@0x0040 增量 == 2*ROUNDS*2。
  TX：每网每 VL 恰好 ROUNDS；BAG；CFG_ERR=0（summary errors/cfg）。
  RX：deliver == 126*ROUNDS；抖动仅对 126 RX VL。
  吞吐：TX 按 128、RX 去重按 126，各自 ≥100 Mbps。
  抖动：J=min(40+Σ(20+Lmax)·8/Nbw,500)；Σ 按 128 TX 全配置；节拍周期一致。
"""
from __future__ import annotations

import argparse
import csv
import json
import sys
from collections import defaultdict
from pathlib import Path

Q20 = 2**20
OH = 20
HDR_OH = 47
BAG_US_DEFAULT = 1000
BAG_CYC = 125_000  # 1000 us @ 125 MHz
LINK_NORM_MBPS = 1000
MIN_MBPS = 100
ES_TOTAL_MAX_NS = 2_000_000
NVL_TX = 128
NVL_RX = 126
EXPECT_UNCONF = 2 * 3 * 2  # VL126/127 × ROUNDS × A/B；ROUNDS 以 summary 为准再核

# 4×32 VL（与 tb_t90 / 卡一致）；TX 全配，RX 仅前 126
GROUPS = [
    (0, 31, 17, 705),
    (32, 63, 256, 2710),
    (64, 95, 1024, 9152),
    (96, 127, 1471, 12902),
]
EXPECT_CFG_SUM = sum(32 * s for _, _, _, s in GROUPS)  # 815008


def share_q20(lmax: int, bag_us: int, link_mbps: int = LINK_NORM_MBPS) -> int:
    n = (lmax + OH) * 8 * Q20
    den = bag_us * link_mbps
    return (n + den - 1) // den


def expected_shares(bag_us: int = BAG_US_DEFAULT) -> int:
    total = 0
    for lo, hi, plen, _ in GROUPS:
        lmax = plen + HDR_OH
        s = share_q20(lmax, bag_us, LINK_NORM_MBPS)
        total += (hi - lo + 1) * s
    return total


def design_payload_mbps(nvl: int, bag_us: int = BAG_US_DEFAULT) -> float:
    """有效载荷设计吞吐：前 nvl 条 VL 的 Σ n·plen·8/BAG。"""
    total = 0.0
    for lo, hi, plen, _ in GROUPS:
        for vl in range(lo, hi + 1):
            if vl < nvl:
                total += plen * 8 / bag_us
    return total


def jitter_bound_us(nbw_mbps: int = LINK_NORM_MBPS) -> float:
    """J = min(40 + Σ_j (20+Lmax_j)·8/Nbw , 500) μs；Σ 按 128 TX 全配置。"""
    sigma = 0.0
    for lo, hi, plen, _ in GROUPS:
        lmax = plen + HDR_OH
        n = hi - lo + 1
        sigma += n * (20 + lmax) * 8 / nbw_mbps
    return min(500.0, 40.0 + sigma)


def sigma_bytescale() -> int:
    return sum((hi - lo + 1) * (20 + plen + HDR_OH) for lo, hi, plen, _ in GROUPS)


def mbps(bytes_: int, window_cycles: int, ns_per_cyc: float = 8.0) -> float:
    if window_cycles <= 0:
        return 0.0
    return bytes_ * 8.0 / (window_cycles * ns_per_cyc * 1e-3)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("outdir", type=Path, help="dir with t90_metrics.csv + summary json")
    ap.add_argument("--tol-mbps", type=float, default=0.05)
    args = ap.parse_args()

    csv_path = args.outdir / "t90_metrics.csv"
    js_path = args.outdir / "t90_verilog_summary.json"
    if not csv_path.is_file() or not js_path.is_file():
        print(f"FAIL: missing {csv_path.name} or {js_path.name}", file=sys.stderr)
        return 2

    summary = json.loads(js_path.read_text(encoding="utf-8").strip().splitlines()[0])
    rows = list(csv.DictReader(csv_path.open(encoding="utf-8")))
    required = {
        "vl",
        "frame",
        "len",
        "t_commit",
        "t_tx_sfd",
        "t_tx_eof",
        "t_rx_sfd",
        "t_rx_host",
        "tx_commit2sfd_ns",
        "rx_sfd2host_ns",
        "sfd2sfd_ns",
        "net",
    }
    if not rows or not required.issubset(rows[0].keys()):
        print(
            f"FAIL: CSV columns; have={sorted(rows[0].keys()) if rows else []}",
            file=sys.stderr,
        )
        return 2

    ok = True
    rounds = int(summary.get("rounds", 3))
    nvl_tx = int(summary.get("nvl_tx", summary.get("nvl", NVL_TX)))
    nvl_rx = int(summary.get("nvl_rx", NVL_RX))
    if nvl_tx != NVL_TX or nvl_rx != NVL_RX:
        print(f"FAIL: nvl_tx/rx expect {NVL_TX}/{NVL_RX}, got {nvl_tx}/{nvl_rx}")
        ok = False

    expect_unconf = 2 * rounds * 2
    unconf_delta = int(summary.get("unconf_delta", -1))
    if unconf_delta != expect_unconf:
        print(
            f"FAIL: unconf_delta={unconf_delta} != 2*ROUNDS*2={expect_unconf} "
            f"(host DROP_CNT_K @0x0040)"
        )
        ok = False
    else:
        print(f"OK unconf_delta={unconf_delta} (== 2*{rounds}*2)")

    rx_deliver = int(summary.get("rx_deliver", -1))
    expect_rx = nvl_rx * rounds
    if rx_deliver != expect_rx:
        print(f"FAIL: rx_deliver={rx_deliver} != {nvl_rx}*{rounds}={expect_rx}")
        ok = False
    else:
        print(f"OK rx_deliver={rx_deliver} (== {nvl_rx}*{rounds})")

    py_cfg = expected_shares()
    cfg_rd = int(summary.get("cfg_sum", -1))
    if py_cfg != EXPECT_CFG_SUM:
        print(f"FAIL: python Σ={py_cfg} != EXPECT_CFG_SUM={EXPECT_CFG_SUM}")
        ok = False
    if cfg_rd != py_cfg:
        print(f"FAIL: cfg_sum readback={cfg_rd} != python Σ={py_cfg}")
        ok = False
    else:
        print(f"OK cfg_sum_rd={cfg_rd} == python Σ={py_cfg} (<= {Q20})")

    design_tx = design_payload_mbps(nvl_tx)
    design_rx = design_payload_mbps(nvl_rx)
    print(
        f"INFO design_payload TX({nvl_tx})={design_tx:.3f} RX({nvl_rx})={design_rx:.3f} "
        f"Mbps (Σ n·plen·8/BAG_us; BAG={BAG_US_DEFAULT}us)"
    )
    if design_tx < MIN_MBPS or design_rx < MIN_MBPS:
        print(f"FAIL: design payload TX/RX < {MIN_MBPS}")
        ok = False

    bound_us = jitter_bound_us()
    bound_cyc = int(bound_us * 125)
    print(
        f"INFO jitter_bound_us={bound_us:.3f} "
        f"(min(40+Σ(20+Lmax)·8/{LINK_NORM_MBPS},500); Σ_bytescale={sigma_bytescale()}; "
        f"period-aligned BAG={BAG_US_DEFAULT}us)"
    )
    if "bound_40sig_us" in summary and abs(int(summary["bound_40sig_us"]) - int(bound_us)) > 0:
        print(
            f"MISMATCH bound_40sig_us: python={int(bound_us)} "
            f"verilog={summary['bound_40sig_us']}"
        )
        ok = False

    window = int(summary.get("window_cycles", 0))
    tx_a = int(summary.get("tx_bytes_a", 0))
    tx_b = int(summary.get("tx_bytes_b", 0))
    rx_d = int(summary.get("rx_dedup_bytes", 0))
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
        if py_v < MIN_MBPS - args.tol_mbps:
            print(f"FAIL: {name} {py_v:.6f} < {MIN_MBPS} Mbps")
            ok = False

    check_mbps("rx_dedup_mbps", py_rx, "rx_dedup_mbps")
    check_mbps("tx_mbps_a", py_tx_a, "tx_mbps_a")
    check_mbps("tx_mbps_b", py_tx_b, "tx_mbps_b")

    frames_a: dict[int, int] = defaultdict(int)
    frames_b: dict[int, int] = defaultdict(int)
    max_c2s = 0
    max_s2h = 0
    commit: dict[int, dict[int, int]] = defaultdict(dict)
    tx_sfd: dict[int, dict[int, int]] = defaultdict(dict)
    rx_host: dict[int, dict[int, int]] = defaultdict(dict)

    for r in rows:
        vl = int(r["vl"])
        fr = int(r["frame"])
        net = r["net"].strip().upper()
        if net == "A":
            frames_a[vl] += 1
            c2s = int(r["tx_commit2sfd_ns"])
            s2h = int(r["rx_sfd2host_ns"])
            sfd = int(r["sfd2sfd_ns"])
            t_c = int(r["t_commit"] or 0)
            t_tx = int(r["t_tx_sfd"] or 0)
            t_rxs = int(r["t_rx_sfd"] or 0)
            # CSV may carry -1 for VL≥NVL_RX
            try:
                t_rh = int(r["t_rx_host"])
            except ValueError:
                t_rh = -1
            commit[vl][fr] = t_c
            tx_sfd[vl][fr] = t_tx
            if t_rh > 0:
                rx_host[vl][fr] = t_rh
            if t_rxs < 0:
                t_rxs = 0
            if c2s >= 0 and t_c and t_tx:
                recon = abs(t_tx - t_c) * 8
                if abs(recon - c2s) > 16:
                    print(f"MISMATCH tx_commit2sfd vl={vl}: csv={c2s} recon={recon}")
                    ok = False
                if c2s > max_c2s:
                    max_c2s = c2s
            if s2h >= 0 and t_rxs > 0 and t_rh > 0:
                recon = abs(t_rh - t_rxs) * 8
                if abs(recon - s2h) > 16:
                    print(f"MISMATCH rx_sfd2host vl={vl}: csv={s2h} recon={recon}")
                    ok = False
                if s2h > max_s2h:
                    max_s2h = s2h
            if sfd not in (0, -1):
                print(f"INFO sfd2sfd_ns={sfd} on A (expected 0 by construction)")
        elif net == "B":
            frames_b[vl] += 1

    es_total = max_c2s + max_s2h
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
            print(f"OK {key}={py_v}")
    if es_total > ES_TOTAL_MAX_NS:
        print(f"FAIL: es_total_max_ns={es_total} > 2ms")
        ok = False

    short_a = [v for v in range(nvl_tx) if frames_a.get(v, 0) != rounds]
    short_b = [v for v in range(nvl_tx) if frames_b.get(v, 0) != rounds]
    if short_a or short_b:
        print(
            f"FAIL: frame count != {rounds}: A_bad={short_a[:8]} B_bad={short_b[:8]}"
        )
        ok = False
    else:
        print(f"OK frames_per_vl=={rounds} for {nvl_tx} TX VL × A/B")

    # e2e 抖动仅对 RX 配表的 126 VL；VL126/127 无 host
    max_jit_cyc = 0
    for vl in range(nvl_rx):
        lats = []
        for fr in range(rounds):
            if fr not in commit[vl] or fr not in rx_host[vl]:
                print(f"FAIL: missing commit/host vl={vl} frame={fr}")
                ok = False
                continue
            if commit[vl][fr] == 0 or rx_host[vl][fr] == 0:
                print(f"FAIL: zero commit/host vl={vl} frame={fr}")
                ok = False
                continue
            lats.append(abs(rx_host[vl][fr] - commit[vl][fr]))
        if len(lats) == rounds:
            jit = max(lats) - min(lats)
            if jit > max_jit_cyc:
                max_jit_cyc = jit
            if jit > bound_cyc:
                print(
                    f"FAIL: e2e jitter vl={vl} {jit} cyc > bound {bound_cyc} "
                    f"({bound_us:.3f} us)"
                )
                ok = False
    for vl in range(nvl_tx):
        for fr in range(1, rounds):
            if fr not in tx_sfd[vl] or (fr - 1) not in tx_sfd[vl]:
                print(f"FAIL: missing tx_sfd vl={vl} frame={fr}")
                ok = False
                continue
            gap = tx_sfd[vl][fr] - tx_sfd[vl][fr - 1]
            if gap < BAG_CYC:
                print(
                    f"FAIL: TX SFD BAG vl={vl} frames {fr - 1}->{fr} "
                    f"gap={gap} < {BAG_CYC}"
                )
                ok = False
    print(f"OK e2e_jitter max_min_cyc={max_jit_cyc} bound_cyc={bound_cyc} (nvl_rx={nvl_rx})")
    if "max_e2e_jit_cyc" in summary:
        if abs(int(summary["max_e2e_jit_cyc"]) - max_jit_cyc) > 2:
            print(
                f"MISMATCH max_e2e_jit_cyc: python={max_jit_cyc} "
                f"verilog={summary['max_e2e_jit_cyc']}"
            )
            ok = False
        else:
            print(f"OK max_e2e_jit_cyc={max_jit_cyc}")
    print("OK TX SFD adjacent gaps ≥ BAG for all TX VL")

    if int(summary.get("errors", 1)) != 0:
        print("FAIL: verilog summary errors!=0")
        ok = False

    if "host_ack_wait_max" in summary:
        haw = int(summary["host_ack_wait_max"])
        hat = int(summary.get("host_ack_timeout", 1000))
        print(f"OK host_ack_wait_max={haw} (timeout={hat}; contract L93)")
        if haw > hat:
            print(f"FAIL: host_ack_wait_max {haw} > timeout {hat}")
            ok = False
    else:
        print("FAIL: summary missing host_ack_wait_max")
        ok = False

    print(
        "NOTE: sfd2sfd wire loopback, no network segment, value=0 by construction; "
        "not a pass criterion"
    )
    print(
        "NOTE: r6 CTL=0x051F SAP on; port budget 256=128 TX+126 RX+2 SAP; "
        "jitter period-aligned; host_ack<=1000"
    )

    if ok:
        print("T90_METRICS_CHECK PASS")
        return 0
    print("T90_METRICS_CHECK FAIL")
    return 1


if __name__ == "__main__":
    sys.exit(main())
