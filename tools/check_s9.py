# -*- coding: utf-8 -*-
"""Recompute §9 numbers straight from the table rows and patch stale totals."""
import io, re, math

p = __file__.replace("\\", "/").rsplit("/", 2)[0] + "/AFDX端系统_总体设计书.md"
s = io.open(p, encoding="utf-8").read()
B = 18 * 1024

def kbit(d, w):
    return d * w / 1024.0

rows = re.findall(r"^\| (?:配置|查找|状态|缓冲|统计|加载) \| ([^|]+?) \| (\d+) × (\d+)(?:（[^）]*）)? \| ([\d.]+) \| (\d+|—) \|", s, re.M)
tot_k = 0.0
tot_b = 0
for name, d, w, dec, nb in rows:
    bits = int(d) * int(w)
    tot_k += bits / 1024.0
    tot_b += 1 if nb == "—" else int(nb)
print("table sum: %.0f Kbit / %d blocks (incl. declared P2 rows)" % (tot_k, tot_b))
# exclude P2 rows from headline
p2k = sum(int(d) * int(w) / 1024.0 for name, d, w, dec, nb in rows if "P2" in name)
p2b = sum((1 if nb == "—" else int(nb)) for name, d, w, dec, nb in rows if "P2" in name)
print("excl P2: %.0f Kbit / %d blocks" % (tot_k - p2k, tot_b - p2b))
# RX state share (RM is 4096×41 in RTL, not 32)
rx_k = 256 + 256 + 64 + 164
print("rx config 256, hash 256, psn 64, rm 164 -> RX state %.0f Kbit = %.0f%% of excl-P2" % (
    rx_k, rx_k / (tot_k - p2k) * 100))

# 缩配档
small = {"端口描述符": 256 * 32, "TX VL 表": 128 * 160, "vl_stats": 0, "时间戳/抖动表": 0,
         "端口表": 256 * 128, "RX 哈希": 2048 * 29, "PSN": 2048 * 8, "RM 状态": 1024 * 32,
         "PMEM": 16 * 1024 * 8, "加载区": 16 * 1024 * 8, "RX 配置": 1024 * 64}
sk = sum(v / 1024.0 for v in small.values())
sb = sum(max(1, math.ceil(v / B)) for v in small.values() if v)
print("缩配: %.0f Kbit (%.2f Mbit) / %d blocks" % (sk, sk / 1024, sb))

