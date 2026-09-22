#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""AFDX 配置预算的唯一算法：从设计书 §8.2 的用例块解析配置，再按判决式算。

判决式（与 RTL 的 Q20 累加器同式，§8.2）：
    frame_bytes = 载荷 Lmax + 24（4 A664 + 20 IP + 8 UDP + 4 FCS 的近似）
    util_j      = frame_bytes × 8 / (BAG_j × 12.5 MB/s)
    CFG_SUM     = Σ_j util_j ≤ 1.0
`tools/bag_budget.py` 与 `tools/check_doc_numbers.py` 都从这里取数，避免两份实现飘开。
"""
import os, re, math

LINK_BPS = 100e6
OH = 24
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
    """解析 §8.2 的用例块 → [(名字, N, Lmax 载荷B, 帧长B, BAG_us, 该用例两行原文)]。"""
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


def util(n, frame_bytes, bag_us):
    return n * frame_bytes * 8 / (bag_us * 1e-6 * LINK_BPS)


def metrics(n, frame_bytes, bag_us):
    u = util(n, frame_bytes, bag_us)
    return {
        "util": u, "mbps": u * LINK_BPS / 1e6, "q20": int(round(u * Q20)),
        "t_frame_us": frame_bytes * 8 / LINK_BPS * 1e6,
        "fps_total": n / (bag_us * 1e-6), "builder_MBps": n * frame_bytes / (bag_us * 1e-6) / 1e6,
        "legal": u <= 1.0,
    }


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

