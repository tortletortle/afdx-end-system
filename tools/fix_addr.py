# -*- coding: utf-8 -*-
# Rebuild the §7.14 host address map so that every region's declared size equals
# 项数 × 每项字数, regions are laid out back-to-back (the intentional gap
# 0x0480~0x1D7F is reserved for later tables), and the whole thing fits in the
# 16-bit word address space. Then verify with tools/check_addr.py.
#
# Idempotent: re-running on an already-correct document leaves it unchanged.
# 要改地址就只改下面的 LAYOUT，不要手打区间。
import io, os, re

_HERE = os.path.dirname(os.path.abspath(__file__))

def _find(name):
    for base in (_HERE, os.path.dirname(_HERE), os.getcwd(), os.path.expanduser("~")):
        p = os.path.join(base, name)
        if os.path.exists(p):
            return p
    return os.path.join(os.path.dirname(_HERE), name)

P = _find("AFDX端系统_总体设计书.md")
s = io.open(P, encoding="utf-8").read()

# (字数, 内容, 访问) —— 地址表唯一真值源
LAYOUT = [
    (256, "全局寄存器：`ID`、`REV`、`CTL`、`STATUS`、`ERR`、`INT_*`、`DROP_CNT[0..11]`、`TB_CNT`、`CFG_SUM`、`CFG_ERR`、`SMAC_CFG`、`IP_CFG`、`UDP_CFG`、`BURST_*`、`DBG_CTRL`", "R/W"),
    (256, "全局统计：帧/字节/丢弃计数、抖动最大/均值、前 8 VL 直方图", "R / W1C"),
    (128 * 5, "TX VL 表：128 项 × 5 字（附录 B 的 w0~w4 静态配置；动态三项不在这张表里，见附录 B 说明）", "R/W（`CFG_MODE=1`）"),
    (4096 * 2, "RX VL 配置表：4096 项 × 2 字", "R/W（`CFG_MODE=1`）"),
    (16384, "RX 哈希表：4096 槽 × 2 way = 8192 表项，每 way 1 字：`{valid, vlid[15:0], idx[11:0]}` + 3 bit 填充（地址 = 槽基址 + way×4096）", "W（`CFG_MODE=1`）"),
    (256 * 4, "端口表：256 项 × 4 字", "R/W（`CFG_MODE=1`）"),
    (256, "端口描述符：256 项 × 1 字", "R"),
    (768, "端口消息操作：`MSG_WR[256]`、`MSG_RD[256]`、`MSG_CNT[256]`", "R/W"),
    (8192, "PMEM：32 KB = 16 块 × 2 KB（TX 6 / RX 6 / 公共 4），块基址 = PMEM 行起始 + blk×0x200", "R/W（数据段仅 `mac_rx_if` 与主机可写）"),
    (16, "IC/RM 状态窗口：`DBG_SEL`（页 + 项偏移）/ `DBG_RDATA` / `DBG_WDATA`", "R / W（`DEBUG_EN`）"),
    (128 * 8, "每 VL 统计：128 项 × 8 字", "R"),
    (16, "管理面窗口：`MGMT_SEL` / `MGMT_WIN`，RTC、SNMP、TFTP 的寄存器映射在窗口内", "R/W"),
    (8192, "保留：IP 分片表（P2）、子 VL 表（P2）", "—"),
    (8192, "TFTP 加载区：32 KB，`a615a_tftp` 独占", "R/W"),
]

# 排布规则：前 3 行固定 0x0000/0x0100/0x0200；0x0480~0x1D7F 为故意留的空洞（放后来
# 追加的表项）；第 4 行起连续排布；PMEM 固定 0x8800（2 KB 对齐且 16 KB 边界，v0.3.1 定案）；
# 若 PMEM 无锚点则自动 2 KB（= 0x200 字）对齐。
ANCHORS = {0: 0x0000, 1: 0x0100, 2: 0x0200, 3: 0x1D80, 8: 0x8800}
rows = []
prev_hi = -1
for i, (words, content, access) in enumerate(LAYOUT):
    lo = ANCHORS.get(i, prev_hi + 1)
    if content.startswith("PMEM"):
        if i not in ANCHORS:
            lo = (lo + 0x1FF) & ~0x1FF
        assert lo % 0x200 == 0, "PMEM start not 2KB(0x200 words) aligned: %x" % lo
    hi = lo + words - 1
    assert hi <= 0xFFFF, "address space overflow at " + content[:20]
    kb = words * 4 / 1024.0
    cap = ("%d 字（%g KB）" % (words, round(kb, 2))) if kb >= 0.1 else ("%d 字（%d B）" % (words, words * 4))
    rows.append("| `0x%04X`~`0x%04X` | %s | %s | %s |" % (lo, hi, cap, content, access))
    prev_hi = hi
total = sum(w for w, _c, _a in LAYOUT)
tail = 0x10000 - (prev_hi + 1)

i0 = s.index("地址空间按 32 bit 字组织")
i1 = s.index("两条约束：加载区紧跟保留区")
new_intro = ("地址空间按 32 bit 字组织，`host_addr[15:0]` 是字地址，可寻址范围 64 K 字 = 256 KB。"
             "下表 14 行（含空洞外的全部区段）合计 %d 字 = %.0f KB，占 %.1f%%，其中空洞 `0x0480~0x1D7F` 另计；"
             "剩下 `0xEC20~0xFFFF`（%d 字）留给 P2 与将来。"
             "下表按「项数 × 每项字数」连续排布（`0x0480`~`0x1D7F` 是故意留的空洞，放后来追加的表项；PMEM 起始自动 2 KB 对齐），"
             "`tools/check_addr.py` 会逐行复核容量声明并检查重叠：\n\n"
             "| 区间（字地址） | 容量 | 内容 | 访问 |\n|---|---|---|---|\n"
             % (total, total * 4 / 1024.0, total / 65536 * 100, tail))
s = s[:i0] + new_intro + "\n".join(rows) + "\n\n" + s[i1:]

# ---- 把 PMEM 基址 / 池区间广播到正文（幂等：已正确则原样）----
mm = None
for m in re.finditer(r"^\| `0x([0-9A-Fa-f]{4})`~`0x[0-9A-Fa-f]{4}` \| 8192 字（32 KB） \| PMEM", s, re.M):
    mm = m
assert mm, "PMEM row not found in §7.14"
start = int(mm.group(1), 16)
assert start % 0x200 == 0, "PMEM start %x not 2KB(0x200 words) aligned" % start

def blk(k):
    return start + k * 0x200

def rng(a, b):
    return "`0x%04X~0x%04X`" % (blk(a), blk(b + 1) - 1)

edits = [
    (r"一块 2 KB = 512 字，但地址按字节口径折算，故一块跨 `0x400` 个字地址；块基址 = `0x[0-9A-Fa-f]{4} \+ blk×0x400`",
     "一块 2 KB = 512 字 = `0x200` 字地址；块基址 = `0x%04X + blk×0x200`" % start),
    (r"块基址 = `0x[0-9A-Fa-f]{4} \+ blk×0x400`", "块基址 = `0x%04X + blk×0x200`" % start),
    (r"块基址 = PMEM 行起始 \+ blk×0x400", "块基址 = PMEM 行起始 + blk×0x200"),
    (r"\| TX \| `0x[0-9A-Fa-f]{4}~0x[0-9A-Fa-f]{4}` \| 6 \|", "| TX | %s | 6 |" % rng(0, 5)),
    (r"\| RX \| `0x[0-9A-Fa-f]{4}~0x[0-9A-Fa-f]{4}` \| 6 \|", "| RX | %s | 6 |" % rng(6, 11)),
    (r"\| 公共 \| `0x[0-9A-Fa-f]{4}~0x[0-9A-Fa-f]{4}` \| 4 \|", "| 公共 | %s | 4 |" % rng(12, 15)),
    (r"\| TX 池 \| `0x[0-9A-Fa-f]{4}~0x[0-9A-Fa-f]{4}` \|", "| TX 池 | %s |" % rng(0, 5)),
    (r"\| RX 池 \| `0x[0-9A-Fa-f]{4}~0x[0-9A-Fa-f]{4}` \|", "| RX 池 | %s |" % rng(6, 11)),
    (r"\| 公共池 \| `0x[0-9A-Fa-f]{4}~0x[0-9A-Fa-f]{4}` \|", "| 公共池 | %s |" % rng(12, 15)),
]
for a, b in edits:
    s, n = re.subn(a, b, s)
    print(("propagate: %s (x%d)" % (a[:36], n)) if n else "已正确, skip: %s" % a[:36])

io.open(P, "w", encoding="utf-8").write(s)
print("map rebuilt: total %d words, PMEM base 0x%04X, step 0x200" % (total, start))
