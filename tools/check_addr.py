import os
def _find(name):
    here = os.path.dirname(os.path.abspath(__file__))
    for base in (here, os.path.dirname(here), os.getcwd(), os.path.expanduser("~")):
        p = os.path.join(base, name)
        if os.path.exists(p):
            return p
    return os.path.join(os.path.dirname(here), name)

import re, io, sys
P = _find("AFDX端系统_总体设计书.md")
s = io.open(P, encoding="utf-8").read()

i0 = s.index("地址空间按 32 bit 字组织")
i1 = s.index("两条约束：加载区紧跟保留区")
tbl = s[i0:i1]
rows = re.findall(r"^\| `0x([0-9A-Fa-f]{4})`~`0x([0-9A-Fa-f]{4})` \| (\d+) 字（(\d+(?:\.\d+)?) (KB|B)） \| ([^|]+?) \|", tbl, re.M)
regions = []
for a, b, words, cap, unit, name in rows:
    kb = float(cap) if unit == "KB" else float(cap) / 1024.0
    regions.append((int(a, 16), int(b, 16), int(words), kb, name.strip()))
regions.sort()
print("%-8s %-8s %7s %7s  %s" % ("起", "止", "字", "KB", "内容"))
bad = 0
prev_hi = -1
tot = 0
for lo, hi, words, kb, name in regions:
    flags = []
    if hi - lo + 1 != words:
        flags.append("SPAN=%d!=DECL" % (hi - lo + 1)); bad += 1
    if abs(words * 4 / 1024.0 - kb) > 0.05:
        flags.append("KB!=DECL"); bad += 1
    if lo <= prev_hi:
        flags.append("OVERLAP"); bad += 1
    prev_hi = hi
    tot += words
    print("0x%04X 0x%04X %7d %7.1f  %-40s %s" % (lo, hi, words, kb, name[:40], " ".join(flags)))
print("\n校验到 %d 行；合计 %d 字（%.0f KB）/ 65536 字 = %.1f%%；错误 %d 处"
      % (len(regions), tot, tot * 4 / 1024.0, tot / 655.36, bad))
pmem=[r for r in regions if r[4].startswith("PMEM")]
if pmem and pmem[0][0] % 0x200: print("PMEM 起始未 2KB 对齐（0x200 字）"); bad += 1
if len(regions) < 15:
    print("警告：只解析到 %d/15 行，正则可能没覆盖所有行" % len(regions))
    bad += 1
# O-27: Q20 份额占原空洞首 128 字，原 TX/RX/PMEM 物理地址必须零位移。
shares = [r for r in regions if r[0] == 0x0480]
if len(shares) != 1 or shares[0][1] != 0x04FF or shares[0][2] != 128 or 'Q20' not in shares[0][4]:
    print("Q20 份额区缺失/位移，需为 0x0480~0x04FF 共 128 字")
    bad += 1
if tot != 53536:
    print("地址表合计应为 53536 字（原 53408 + 128）")
    bad += 1
# PMEM 池子区间（§8.6）必须在 PMEM 行内、互不重叠、字数 = 块数 × 0x200（2 KB）
m86 = re.search(r"### 8\.6.*?(?=^### |^## )", s, re.M | re.S)
pools = []
if m86:
    for ln in m86.group(0).splitlines():
        m2 = re.match(r"\|\s*(TX 池|RX 池|公共池)\s*\|\s*`0x([0-9A-Fa-f]{4})~0x([0-9A-Fa-f]{4})`\s*\|\s*2 KB ×(\d+)\s*\|", ln)
        if m2:
            pools.append((m2.group(1), int(m2.group(2), 16), int(m2.group(3), 16), int(m2.group(4))))
if pmem and pools:
    plo, phi = pmem[0][0], pmem[0][1]
    for nm, a, b, n in pools:
        if not (plo <= a and b <= phi):
            print("%s %s~%s 越出 PMEM 行 %s~%s" % (nm, hex(a), hex(b), hex(plo), hex(phi)))
            bad += 1
        if b - a + 1 != n * 0x200:
            print("%s 字数 %d ≠ %d 块 × 0x200 字（2 KB）" % (nm, b - a + 1, n))
            bad += 1
    for i in range(len(pools)):
        for j in range(i + 1, len(pools)):
            if pools[i][1] <= pools[j][2] and pools[j][1] <= pools[i][2]:
                print("%s 与 %s 重叠" % (pools[i][0], pools[j][0]))
                bad += 1
elif not pools:
    print("警告：§8.6 没解析到池子行（格式变了？）")
    bad += 1
sys.exit(1 if bad else 0)

