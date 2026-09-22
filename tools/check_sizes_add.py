# -*- coding: utf-8 -*-
"""把「§7/§8 表规模必须与 §9 一致」这段检查追加进 verify_all.py（只做一次）。"""
import io

BLOCK = r'''
# 14 表规模对账：§7/§8 正文里写出的 per-VL 表尺寸必须与 §9 的「项 × 位」一致
i0 = s.index("## 9 存储开销预算"); i1 = s.index("口径说明", i0)
sizes = {}
for line in s[i0:i1].splitlines():
    c = [x.strip() for x in line.strip("|").split("|")]
    if len(c) == 6 and re.match(r"^\d+ × \d+", c[2]):
        d, w = re.match(r"^(\d+) × (\d+)", c[2]).groups()
        sizes[c[1]] = (int(d), int(w))
ALIAS = {"RX VL 配置": "rx_vl_cfg", "RX 哈希": "rx_hash", "PSN（2 网）": "psn",
         "RM 状态": "rm_state", "端口描述符": "描述符", "vl_stats": "vl_stats", "TX VL 表": "TX VL 表"}
bad = []
for row, (d, w) in sizes.items():
    key = ALIAS.get(row)
    if not key:
        continue
    body = s[s.index("## 7 模块详细设计"):s.index("## 9 存储开销预算")]
    pats = [r"%s（?\s*(\d+)\s*×\s*(\d+)\s*bit" % key, r"%s[^。\n]{0,12}?(\d+)\s*×\s*(\d+)" % re.escape(key)]
    hit = None
    for p in pats:
        m = re.search(p, body)
        if m:
            hit = (int(m.group(1)), int(m.group(2))); break
    if hit and hit != (d, w):
        bad.append((row, "正文 %d×%d" % hit, "§9 %d×%d" % (d, w)))
if bad:
    fail("size", "正文与 §9 的表规模不一致 %s" % bad)
else:
    ok("size", "§9 %d 张表与正文规模对账一致（§7/§8 无 ×29 bit 之类旧口径）" % len(sizes))
if re.search(r"×\s*29\s*bit|29 bit 表项|13 个 18 Kbit", s[:s.index("## 附录 F 版本记录")]):
    fail("stale", "仍残留哈希 29 bit / 13 块的旧口径")
else:
    ok("stale", "无 29 bit / 13 块旧口径")
# 只扫正文（附录 F 变更记录本来就该保留历史数字）
body = s[:s.index("## 附录 F 版本记录")]
for w in ("0x6580", "0x6C00", "0xE000", "0x6680", "0x6000", "1.61 Mbit", "1.78 Mbit"):
    if w in body:
        fail("stale", "正文残留旧字面量 %s" % w)
if not F or all(x[0] != "stale" for x in F):
    ok("stale", "正文无旧地址/旧容量字面量")

print("\n== 结论 ==")'''

p = "/home/user/tools/verify_all.py"
v = io.open(p, encoding="utf-8").read()
if "14 表规模对账" in v:
    print("already patched"); raise SystemExit
v = v.replace('\nprint("\\n== 结论 ==")', BLOCK, 1)
io.open(p, "w", encoding="utf-8").write(v)
print("checker patched")

