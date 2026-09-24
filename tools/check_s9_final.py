import os
def _find(name):
    here = os.path.dirname(os.path.abspath(__file__))
    for base in (here, os.path.dirname(here), os.getcwd(), os.path.expanduser("~")):
        p = os.path.join(base, name)
        if os.path.exists(p):
            return p
    return os.path.join(os.path.dirname(here), name)

import re, math, io, sys
d = _find("AFDX端系统_总体设计书.md")
s = io.open(d, encoding="utf-8").read()
i0 = s.index("## 9 存储开销预算"); i1 = s.index("口径说明", i0)
tbl = s[i0:i1]
B = 18 * 1024
rows = []
for line in tbl.splitlines():
    c = [x.strip() for x in line.strip().strip("|").split("|")]
    if len(c) != 6 or c[0] not in ("配置","查找","状态","缓冲","统计","加载"): continue
    if "项×位" in c[2]: continue
    m = re.match(r"(\d+) × (\d+)", c[2])
    kb = re.search(r"(\d+) KB", c[2])
    bits = int(m.group(1)) * int(m.group(2)) if m else int(kb.group(1)) * 8 * 1024
    rows.append((c[1], bits, float(c[3]), c[4]))
bad = 0; tot = 0.0; blk = 0; ptot = 0.0; pblk = 0
for name, bits, dec, nb in rows:
    calc = bits / 1024
    if abs(calc - dec) > 0.06: print("KBIT 不符", name, "声明", dec, "实算", round(calc,1)); bad += 1
    need = max(1, math.ceil(bits / B))
    if nb != "—" and int(nb) != need: print("BLK 不符", name, "声明", nb, "实算", need); bad += 1
    add = 0 if nb == "—" else int(nb)
    if "P2" in name: ptot += calc; pblk += add
    else: tot += calc; blk += add
print("行数 %d | 不含 P2 %.0f Kbit = %.2f Mbit / %d 块 | 含 P2 %.0f Kbit = %.2f Mbit / %d 块 | 错误 %d"
      % (len(rows), tot, tot/1024, blk, tot+ptot, (tot+ptot)/1024, blk+pblk, bad))
base_rows = sum(1 for name, _bits, _dec, _nb in rows if "P2" not in name)
for want in ["| **合计** | 不含 P2（%d 行） | | **%.2f Mbit**（%.0f Kbit） | **%d**" % (base_rows,tot/1024,tot,blk),
             "%.2f Mbit / %d 块" % ((tot+ptot)/1024, blk+pblk)]:
    print(("ok   合计行含 " if want in s else "MISS 合计行缺 ") + want)
    if want not in s: bad += 1
sys.exit(1 if bad else 0)

