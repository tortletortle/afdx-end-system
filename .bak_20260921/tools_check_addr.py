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
if pmem and pmem[0][0] % 0x400: print("PMEM 起始未 2KB 对齐"); bad += 1
if len(regions) < 14:
    print("警告：只解析到 %d/14 行，正则可能没覆盖所有行" % len(regions))
    bad += 1
sys.exit(1 if bad else 0)

