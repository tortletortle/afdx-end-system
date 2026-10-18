#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""AFDX 配置预算的唯一算法：从设计书 §8.2 的用例块解析配置，再按判决式算。

判决式（与 RTL 的 Q20 累加器同式，§8.2；O-01 口径，v0.5.5 起）：
    Lmax        = A664P7 定义的以太帧长（DMAC 起算、含 FCS），64 ≤ Lmax ≤ 1518
    载荷 L      = Lmax − 47（14 ETH + 20 IP + 8 UDP + 1 SN + 4 FCS）
    wire_bytes  = Lmax + 20（7 前导 + 1 SFD + 12 IFG 的线上固定开销）
    util_j      = wire_bytes × 8 / (BAG_j × 12.5 MB/s)
    CFG_SUM     = Σ_j util_j ≤ 1.0
`tools/bag_budget.py` 与 `tools/check_doc_numbers.py` 都从这里取数，避免两份实现飘开。
"""
import os, re, math
from fractions import Fraction

LINK_BPS = 100e6
OH = 20          # 线上固定开销：前导 7 + SFD 1 + IFG 12（O-01）
HDR_OH = 47      # Lmax − 载荷：ETH 14 + IP 20 + UDP 8 + SN 1 + FCS 4
Q20 = 2 ** 20
NAME = "AFDX端系统_总体设计书.md"


def find_doc(start=None):
    here = os.path.dirname(os.path.abspath(__file__))
    for base in [here, os.path.dirname(here), os.getcwd(), os.path.expanduser("~")]:
        p = os.path.join(base, NAME)
        if os.path.exists(p):
            return p
    raise SystemExit("找不到 %s（脚本要放在仓库的 tools/ 下）" % NAME)


def doc_text(path=None):
    import io
    return io.open(path or find_doc(), encoding="utf-8").read()


def section(doc, head="### 8.2"):
    i0 = doc.index(head)
    m = re.search(r"^### 8\.\d", doc[i0 + len(head):], re.M)
    return doc[i0:i0 + len(head) + (m.start() if m else 4000)]


HDR = re.compile(r"^(T05[abc]).*?(\d+)\s*条?\s*VL.*?Lmax\s*=\s*([\d ]+)\s*B")
BAG = re.compile(r"BAG\s*=\s*([\d.]+)\s*(ms|μs|us)")


def cases(doc=None):
    """解析 §8.2 的用例块 → [(名字, N, Lmax 帧长B, 线上字节B, BAG_us, 该用例两行原文)]。"""
    doc = doc if doc is not None else doc_text()
    seg = section(doc)
    out = []
    lines = seg.splitlines()
    for i, l in enumerate(lines):
        m = HDR.match(l.strip())
        if not m:
            continue
        name, n, lmax = m.group(1), int(m.group(2)), int(m.group(3).replace(" ", ""))
        blk = l + "\n" + (lines[i + 1] if i + 1 < len(lines) else "")
        k = BAG.search(blk)
        if not k:
            out.append((name, n, lmax, None, None, blk)); continue
        bag_us = float(k.group(1)) * (1000 if k.group(2) == "ms" else 1)
        out.append((name, n, lmax, lmax + OH, bag_us, blk))
    return out


def util(n, frame_bytes, bag_us, link_bps=LINK_BPS):
    if link_bps <= 0:
        raise ValueError("link_bps must be positive")
    return n * frame_bytes * 8 / (bag_us * 1e-6 * link_bps)


def metrics(n, frame_bytes, bag_us, link_bps=LINK_BPS):
    u = util(n, frame_bytes, bag_us, link_bps)
    # 每 VL 的 Q20 份额必须先向上取整，再累加；不能对整个浮点总和四舍五入。
    # Fraction 避免恰好整除时浮点误差把 ceil 错加 1。
    bits_per_us = Fraction(str(link_bps)) / 1000000
    per_vl = math.ceil(Fraction(frame_bytes * 8 * Q20, 1) /
                       (Fraction(str(bag_us)) * bits_per_us))
    q20 = n * per_vl
    return {
        "util": u, "mbps": u * link_bps / 1e6, "q20": q20, "q20_per_vl": per_vl,
        "link_bps": link_bps,
        "t_frame_us": frame_bytes * 8 / link_bps * 1e6,
        "fps_total": n / (bag_us * 1e-6),
        # 旧字段名保留兼容：这里按 wire_bytes 算的是等效线上需求，不是 builder 的 RTL 吞吐实测。
        "builder_MBps": n * frame_bytes / (bag_us * 1e-6) / 1e6,
        "legal": q20 <= Q20,
    }


def payload_of(lmax):
    return lmax - HDR_OH


def lmax_of(payload):
    return payload + HDR_OH


def sat_bag(n, frame_bytes, target=0.9984):
    return n * frame_bytes * 8 / (target * LINK_BPS) * 1e6


def parse_stated(block):
    """从用例块里读出文中写的数字。"""
    def num(pat):
        m = re.search(pat, block)
        return float(m.group(1).replace(" ", "").replace("_", "")) if m else None
    return {
        "mbps": num(r"⇒\s*([\d .]+)\s*Mbps"),
        "util_pct": num(r"占用\s*([\d .]+)\s*%"),
        "util_x": num(r"占用\s*([\d .]+)\s*倍"),
        "cfg_sum": num(r"CFG_SUM=([\d _]+(?:\.\d+)?)/2\^20"),
        "t_frame": num(r"单帧\s*([\d.]+)\s*μs"),
        "legal": "合法" in block, "reject": "ERR.BAG_OVF" in block or "超限" in block,
    }

