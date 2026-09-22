# -*- coding: utf-8 -*-
"""Rebuild the §7.14 host address map so that every region's declared size equals
项数 × 每项字数, regions are laid out back-to-back, and the whole thing fits in
the 16-bit word address space. Then verify with tools/check_addr.py."""
import os
def _find(name):
    here = os.path.dirname(os.path.abspath(__file__))
    for base in (here, os.path.dirname(here), os.getcwd(), os.path.expanduser("~")):
        p = os.path.join(base, name)
        if os.path.exists(p):
            return p
    return os.path.join(os.path.dirname(here), name)

import os, sys
_HERE = os.path.dirname(os.path.abspath(__file__))
def _find(name):
    for base in (os.path.dirname(_HERE), os.path.expanduser("~")):
        p = os.path.join(base, name)
        if os.path.exists(p):
            return p
    return os.path.join(os.path.dirname(_HERE), name)
import io, re

P = _find("AFDX端系统_总体设计书.md")
s = io.open(P, encoding="utf-8").read()

# (words, capacity-label, content, access)
LAYOUT = [
    (256,  "全局寄存器：`ID`、`REV`、`CTL`、`STATUS`、`ERR`、`INT_*`、`DROP_CNT[0..11]`、`TB_CNT`、`CFG_SUM`、`CFG_ERR`、`SMAC_CFG`、`IP_CFG`、`UDP_CFG`、`BURST_*`、`DBG_CTRL`", "R/W"),
    (256,  "全局统计：帧/字节/丢弃计数、抖动最大/均值、前 8 VL 直方图", "R / W1C"),
    (128 * 5, "TX VL 表：128 项 × 5 字", "R/W（`CFG_MODE=1`）"),
    (4096 * 2, "RX VL 配置表：4096 项 × 2 字", "R/W（`CFG_MODE=1`）"),
    (16384, "RX 哈希表：8192 表项（4096 槽 × 2 way），每 way 1 字：`{valid, vlid[15:0], idx[11:0]}` + 3 bit 填充（槽基址 + way×4096）", "W（`CFG_MODE=1`）"),
    (256 * 4, "端口表：256 项 × 4 字", "R/W（`CFG_MODE=1`）"),
    (256, "端口描述符：256 项 × 1 字", "R"),
    (768, "端口消息操作：`MSG_WR[256]`、`MSG_RD[256]`、`MSG_CNT[256]`", "R/W"),
    (8192, "PMEM：32 KB = 16 块 × 2 KB（TX 6 / RX 6 / 公共 4），块基址 = PMEM 行起始 + blk×0x400", "R/W（数据段仅 `mac_rx_if` 与主机可写）"),
    (16, "IC/RM 状态窗口：`DBG_SEL`（页 + 项偏移）/ `DBG_RDATA` / `DBG_WDATA`", "R / W（`DEBUG_EN`）"),
    (128 * 8, "每 VL 统计：128 项 × 8 字", "R"),
    (16, "管理面窗口：`MGMT_SEL` / `MGMT_WIN`，RTC、SNMP、TFTP 的寄存器映射在窗口内", "R/W"),
    (8192, "保留：IP 分片表（P2）、子 VL 表（P2）", "—"),
    (8192, "TFTP 加载区：32 KB，`a615a_tftp` 独占", "R/W"),
]

STARTS = [0x0000, 0x0100, 0x2000]
rows = []
cur = 0x2000
for i, (words, content, access) in enumerate(LAYOUT):
    if i == 0:
        lo = 0x0000
    elif i == 1:
        lo = 0x0100
    else:
        lo = cur
        if "PMEM：" in content:                    # PMEM 必须 2 KB（0x400 字）对齐
            lo = (lo + 0x3FF) & ~0x3FF
            assert lo % 0x400 == 0
    hi = lo + words - 1
    assert hi <= 0xFFFF, "address space overflow at " + content[:20]
    kb = words * 4 / 1024.0
    cap = ("%d 字（%g KB）" % (words, round(kb, 2))) if kb >= 0.1 else ("%d 字（%d B）" % (words, words * 4))
    rows.append("| `0x%04X`~`0x%04X` | %s | %s | %s |" % (lo, hi, cap, content, access))
    cur = (0x2000 - LAYOUT[2][0]) if i == 2 else hi + 1

tbl = "\n".join(rows)
used = cur - 0x2000 + 512
i0 = s.index("地址空间按 32 bit 字组织")
i1 = s.index("两条约束记在这里")
new_intro = ("地址空间按 32 bit 字组织，`host_addr[15:0]` 是字地址，可寻址范围 64 K 字 = 256 KB。"
             "满配各表容量加起来是 %d 字（%.0f KB），约占一半，剩下的留给 P2 与将来。"
             "下表按「项数 × 每项字数」连续排布，`tools/check_addr.py` 会逐行复核容量声明并检查重叠：\n\n"
             "| 区间（字地址） | 容量 | 内容 | 访问 |\n|---|---|---|---|\n" % (used, used * 4 / 1024.0))
s = s[:i0] + new_intro + tbl + "\n\n" + s[i1:]

# PMEM base address now 0x6400

# ---- propagate the PMEM base into the prose/pool tables ----
base = None
for lo, hi, words, kb, nm in []:
    pass
mm = re.search(r"PMEM：32 KB = 16 块 × 2 KB（TX 6 / RX 6 / 公共 4）", s)
start = None
for m in re.finditer(r"^\| `0x([0-9A-Fa-f]{4})`~`0x[0-9A-Fa-f]{4}` \| 8192 字（32 KB） \| PMEM", s, re.M):
    start = int(m.group(1), 16); break
assert start is not None, "PMEM row not found"
def blk(k):
    return start + k * 0x400
def rng(a, b):
    return "`0x%04X~0x%04X`" % (blk(a), blk(b + 1) - 1)
edits = [
    ("块基址 = `0x6400 + blk×0x400`", "块基址 = `0x%04X + blk×0x400`" % start),
    ("| TX | `0x6400~0x6BFF` | 6 |", "| TX | %s | 6 |" % rng(0, 5)),
    ("| RX | `0x6C00~0x73FF` | 6 |", "| RX | %s | 6 |" % rng(6, 11)),
    ("| 公共 | `0x7400~0x77FF` | 4 |", "| 公共 | %s | 4 |" % rng(12, 15)),
    ("| TX 池 | `0x6400~0x6BFF` | 2 KB ×6 |", "| TX 池 | %s | 2 KB ×6 |" % rng(0, 5)),
    ("| RX 池 | `0x6C00~0x73FF` | 2 KB ×6 |", "| RX 池 | %s | 2 KB ×6 |" % rng(6, 11)),
    ("| 公共池 | `0x7400~0x77FF` | 2 KB ×4 |", "| 公共池 | %s | 2 KB ×4 |" % rng(12, 15)),
    ("起始 `0x6C00`（字地址 = 字节地址/4，一块占 `0x800` 个字地址）",
     "起始 `0x%04X`（字地址 = 字节地址/4，一块 2 KB 即 `0x400` 个字地址）" % start),
]
import re
for a, b in edits:
    if a in s:
        s = s.replace(a, b, 1)
    else:
        print("skip:", a[:44])

io.open(P, "w", encoding="utf-8").write(s)
print("map rebuilt, used words:", used, "| TX VL 表容量 KB:", LAYOUT[2][0]*4/1024)

