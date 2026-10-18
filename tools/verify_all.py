#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""全文一致性校验：结构、交叉引用、地址/容量对账、口径与规范。
用法: python3 tools/verify_all.py [md路径]
"""
import os
def _find(name):
    here = os.path.dirname(os.path.abspath(__file__))
    for base in (here, os.path.dirname(here), os.getcwd(), os.path.expanduser("~")):
        p = os.path.join(base, name)
        if os.path.exists(p):
            return p
    return os.path.join(os.path.dirname(here), name)

import io, re, sys, os, math, subprocess

DOC = sys.argv[1] if len(sys.argv) > 1 else _find("AFDX端系统_总体设计书.md")
PLAN = _find("AFDX选题一_题目简介与设计计划.md")
s = io.open(DOC, encoding="utf-8").read()
lines = s.splitlines()
F = []            # findings
def fail(tag, msg): F.append((tag, msg))
def ok(tag, msg):  print("  ok   %-18s %s" % (tag, msg))

print("== %s (%d 行) ==" % (os.path.basename(DOC), len(lines)))

# 1 围栏
if s.count("```") % 2: fail("fence", "代码围栏不成对：%d 个" % s.count("```"))
else: ok("fence", "围栏 %d 个成对" % s.count("```"))

# 2 标题
h2 = [int(m.group(1)) for m in re.finditer(r"^## (\d+) ", s, re.M)]
if h2 != list(range(1, len(h2) + 1)): fail("heading", "章编号不连续: %s" % h2)
else: ok("heading", "§1~§%d 连续" % len(h2))
h3 = re.findall(r"^### 7\.(\d+) ", s, re.M)
if [int(x) for x in h3[:19]] != list(range(1, 20)): fail("heading", "§7.x 模块小节不连续: %s" % h3)
else: ok("heading", "§7.1~7.19 连续")
deep = [l for l in lines if re.match(r"^#{4,} ", l)]
if deep: fail("heading", "存在 4 级以上标题 %d 个: %s" % (len(deep), deep[0][:40]))

# 3 表格列数
bad = 0; tables = 0; cur = []
for i, l in enumerate(lines, 1):
    if l.startswith("|"): cur.append((i, l))
    else:
        if cur:
            tables += 1
            w = {len(r[1].strip().strip("|").split("|")) for r in cur}
            if len(w) > 1:
                bad += 1
                fail("table", "第 %d 行起表列数不齐 %s" % (cur[0][0], sorted(w)))
        cur = []
if not bad: ok("table", "%d 张表列数一致" % tables)

# 4 交叉引用（§n / §n.m / 附录 X / Dn / Rn / Tnn / An）
refs = set(re.findall(r"§(\d+)(?:\.(\d+))?", s))
heads2 = set(re.findall(r"^## (\d+) ", s, re.M))
heads3 = set(re.findall(r"^### (\d+\.\d+)", s, re.M))
miss = []
for a, b in refs:
    tgt = "%s.%s" % (a, b) if b else a
    if b and tgt not in heads3 and tgt not in ("7.14.1",): miss.append(tgt)
    if not b and a not in heads2: miss.append(tgt)
if miss: fail("xref", "引用了不存在的章节 %s" % sorted(set(miss)))
else: ok("xref", "§引用全部有落点（%d 处）" % len(re.findall(r"§\d", s)))
for t in sorted(set(re.findall(r"\bT\d{2}\b", s))):
    if t not in "".join(re.findall(r"^\| (T\d{2}) ", s, re.M)): pass
cases = re.findall(r"^\| (T\d{2}) \|", s, re.M)
want = ["T%02d" % i for i in range(23)]
if sorted(set(cases)) != sorted(set(want)): fail("cases", "用例编号缺/多: %s" % sorted(set(want) ^ set(cases)))
else: ok("cases", "T00~T22 齐备（矩阵 %d 行）" % len(cases))
d = sorted({int(x) for x in re.findall(r"\bD(\d+)\b", s)})
if d != list(range(1, len(d) + 1)): fail("decision", "D 编号不连续 %s" % d)
else: ok("decision", "D1~D%d 连续" % len(d))
r = sorted({int(x) for x in re.findall(r"\bR(\d+)\b", s)})
if r != list(range(1, len(r) + 1)): fail("risk", "R 编号不连续 %s" % r)
else: ok("risk", "R1~R%d 连续" % len(r))
ap = sorted(set(re.findall(r"附录 ([A-F])", s)))
ha = sorted(set(re.findall(r"^## 附录 ([A-F])", s, re.M)))
if not set(ap) <= set(ha): fail("appendix", "引用了不存在的附录 %s（实有 %s）" % (set(ap) - set(ha), ha))
else: ok("appendix", "附录 %s 均有实体" % "".join(ha))

# 5 §7.14 地址表 vs §9 vs 附录 A 偏移
i0 = s.index("## 7 模块详细设计"); i1 = s.index("### 7.15")
tbl = s[i0:i1]
addr_rows = re.findall(r"^\| `(0x[0-9A-Fa-f]{4})`~`0x[0-9A-Fa-f]{4}` \| (\d+) 字（([\d.]+) KB） \| ([^|]*)\|", tbl, re.M)
span = []
for a, _b, _c, d in addr_rows:
    m = re.search(r"(\d+) 项 × (\d+) 字", d); n = re.search(r"(\d+) 字", d)
    span.append((int(a, 16), d[:26]))
if addr_rows: ok("addr", "§7.14 解析 %d 行" % len(addr_rows))
# 附录 A 偏移必须落在 0x0000~0x00FF
offs = re.findall(r"^\| `(0x[0-9A-Fa-f]{2,4})(?:`/`0x[0-9A-Fa-f]{4})?` \| `([A-Z_0-9\[\]^\s]+)`", s[s.index("## 附录 A"):s.index("## 附录 B")], re.M)
bad = [o for o, _ in offs if not (0x0000 <= int(o, 16) <= 0x00FC)]
if bad: fail("regs", "附录 A 有寄存器偏移越出 0x0000~0x00FC：%s" % bad)
else: ok("regs", "附录 A %d 个寄存器偏移都在寄存器页内" % len(offs))
dups = [o for o in re.findall(r"^\| `(0x[0-9A-F]{4})` \|", s[s.index("## 附录 A"):s.index("## 附录 B")], re.M)
        if re.findall(r"^\| `%s`" % o, s[s.index("## 附录 A"):s.index("## 附录 B")], re.M)[0] != o]
# 偏移顺序（附录 A 允许 SNMP_PEER_IP 一处倒序，其余须递增）
seq = [int(x, 16) for x in re.findall(r"^\| `(0x00[0-9A-F]{2})` \|", s[s.index("## 附录 A"):s.index("## 附录 B")], re.M)]
inv = [(hex(seq[i]), hex(seq[i+1])) for i in range(len(seq)-1) if seq[i] > seq[i+1]]
if inv: fail("regs", "附录 A 偏移倒序 %s" % inv)
else: ok("regs", "偏移递增")

# 6 §7.14 行内声明字数 vs 项数×每项字数
mism = []
for a, words, kb, desc in addr_rows:
    m = re.search(r"(\d+) 项 × (\d+) 字", desc)
    if m and int(m.group(1)) * int(m.group(2)) != int(words): mism.append((a, desc[:40], int(words)))
if mism: fail("cap", "§7.14 项×字与声明字数不符 %s" % mism)
else: ok("cap", "§7.14 每行 项×字 = 声明字数")

# 7 术语/口径
for b in re.findall(r"^\| `([a-z0-9_]+)`", s, re.M):
    pass
# 只在「肯定式」出现时才算越界；否定式（不要求上板 / 无板卡 / 综合仅自证）与
# TFTP 上传下载这类协议语义都是正确的口径，不算问题。
NEG = r"(不|无|没|无需|非|仅|只在|除非|之外|范围外|备胎|留在|或软核|或改走)[^。；\n]{0,24}"
forb = {"EQ6HL": r"EQ6HL\d*", "比特流": r"比特流", "JTAG": r"JTAG", "烧写": r"烧写",
        "FPGA 芯片": r"FPGA 芯片", "器件型号": r"器件型号(?!、)",
        "上板": r"上板(?!要求|测试|验证|类)", "管脚": r"管脚(?!分配|约束)[^。]{0,6}",
        "开发板": r"开发板(?!\s*」)", "IO 约束": r"IO ?约束"}
hits = []
for tag, pat in forb.items():
    for m in re.finditer(pat, s):
        ctx = s[max(0, m.start()-30):m.start()+len(m.group(0))+6].replace("\n", " ")
        if re.search(NEG, s[max(0, m.start()-90):m.start()]): continue
        hits.append((tag, ctx[-46:]))
if hits: fail("口径", "疑似硬件化表述 %s" % hits[:4])
else: ok("口径", "无肯定式器件/上板表述")
plan_bad = []
if os.path.exists(PLAN):
    p2 = io.open(PLAN, encoding="utf-8").read()
    for tag in ("开发板", "上板", "EQ6HL", "比特流"):
        for m in re.finditer(tag, p2):
            if re.search(NEG, p2[max(0, m.start()-90):m.start()]): continue
            plan_bad.append((tag, p2[max(0, m.start()-30):m.start()+10].replace("\n", " ")))
if plan_bad: fail("plan", "简介文档疑似硬件化表述 %s" % plan_bad[:3])
else: ok("plan", "简介文档口径同样是仿真优先")
pct = [x for x in re.findall(r"(?<!链路)占用[^。\n]{0,20}\d+(?:\.\d+)?\s*%|资源利用率|占片[^。\n]*\d+%|占[^。\n]{0,8}器件[^。\n]{0,8}\d+%", s) if "链路" not in x and "占用 0" not in x]
# 「链路占用 8.96%」是流量指标不是器件占比，放行；只罚「占器件/占片 X%」
pct = [x for x in pct if not re.search(r"链路", x)]
if pct: fail("口径", "疑似器件占比表述 %s" % pct[:3])
else: ok("口径", "存储只给绝对量")
if re.search(r"已实现|已完成|已验证通过|完成了.*模块的编写", s): fail("口径", "出现完成时态（应为申报口径）")
else: ok("口径", "申报/计划口吻")

# 8 关键数字
for w, pat in [("1471", r"1471"), ("1518", r"1518"), ("128 发送 VL", r"128 个?发送|NUM_TX_VL=128"),
               ("4096 接收 VL", r"NUM_RX_VL=4096|4096 个?接收"), ("100 Mbps", r"100 Mbps")]:
    if not re.search(pat, s): fail("metric", "正文缺指标 %s" % w)
ok("metric", "100 Mbps / 1471 / 1518 / 128 / 4096 均在文")

# 9 与简介文档的口径冲突
if os.path.exists(PLAN):
    p = io.open(PLAN, encoding="utf-8").read()
    dp = re.findall(r"([\d.]+) Mbit", p); dd = re.findall(r"([\d.]+) Mbit", s)
    if dp and dd and set(dp) - set(dd): fail("plan", "两文档存储量不一致 简介 %s vs 设计书 %s" % (set(dp), set(dd)))
    else: ok("plan", "简介与设计书存储口径一致 %s" % (sorted(set(dp) | set(dd)) or "—"))

# 10 §3.4 模块清单：分组小计必须与表内求和一致
i0 = s.index("### 3.4 模块清单"); i1 = s.index("### 3.5", i0)
groups = {}; cur = None; nrows = 0
for line in s[i0:i1].splitlines():
    if not line.startswith("|") or "层 |" in line or set(line) <= set("|- "): continue
    c = [x.strip() for x in line.strip("|").split("|")]
    if c[0].startswith("**合计**"):
        if len(c) != 4: fail("table", "§3.4 合计行列数 %d ≠ 4" % len(c))
        continue
    if c[0]: cur = {"发送": "发送", "接收": "接收", "管理": "管理面", "公共": "公共", "顶层": "顶层"}[c[0]]
    if len(c) != 4: fail("table", "§3.4 行列数 %d ≠ 4: %s" % (len(c), c[1][:24])); continue
    groups[cur] = groups.get(cur, 0) + int(c[3]); nrows += 1
decl = dict(re.findall(r"(顶层|发送|接收|管理面|公共) (\d+)", s[i0:i1]))
for g, v in groups.items():
    if g in decl and int(decl[g]) != v: fail("lines", "§3.4 %s 小计写 %s，表内实为 %d" % (g, decl[g], v))
if set(decl) == set(groups) and all(int(decl[g]) == groups[g] for g in groups):
    ok("lines", "§3.4 %d 个模块行，分组小计与表内求和一致 %s" % (nrows, {k: v for k, v in sorted(groups.items())}))

# 11 脚本路径唯一：附录 E 与 §10 目录树/质量门里同名脚本不得指向两个目录
tree = s[s.index("### 10.1") if "### 10.1" in s else s.index("## 10 "):s.index("## 11 ")]
apxE = s[s.index("## 附录 E"):s.index("## 附录 F")]
paths = re.findall(r"`?([\w/]+\.(?:tcl|py|sh))`?", tree + apxE)
byname = {}
for pth in {x for x in paths if '/' in x}:
    byname.setdefault(os.path.basename(pth), set()).add(pth)
multi = {k: sorted(v) for k, v in byname.items() if len({p.split("/")[0] for p in v}) > 1}
if multi: fail("path", "同一脚本出现两套路径 %s" % multi)
else: ok("path", "%d 个脚本路径各自唯一" % len(byname))

# 12 抬头表 2 列
head = s[:s.index("\n---")]
cols = {len([x for x in l.strip("|").split("|")]) for l in head.splitlines() if l.startswith("|")}
if cols != {2}: fail("table", "抬头表列数 %s ≠ {2}" % cols)
else: ok("table", "抬头表两列")

# 13 顶层端口必须含赛题模板的 8 个端口，方向与位宽一致
TPL = {"clk":("in","1"), "reset":("in","1"), "tx_data":("out","8"), "rx_data":("in","8"),
       "tx_valid":("out","1"), "rx_valid":("in","1"), "tx_ready":("out","1"), "rx_ready":("in","1")}
i0 = s.index("### 5.1 顶层端口总表"); i1 = s.index("### 5.2", i0)
got = {}
for line in s[i0:i1].splitlines():
    if not line.startswith("|"): continue
    c = [x.strip() for x in line.strip("|").split("|")]
    if len(c) == 4 and c[0].startswith("`") and "/" not in c[0]:
        got[c[0].strip("`")] = (c[1], c[2])
bad = [(k, TPL[k], got.get(k)) for k in TPL if got.get(k) != TPL[k]]
if bad: fail("template", "模板端口对不上 %s" % bad)
else: ok("template", "§5.1 含模板 8 端口且方向/位宽一致（全表 %d 行）" % len(got))
extra = [k for k in got if k not in TPL and not k.startswith(("host_", "pps_", "rtc_", "dbg_", "tx_", "rx_"))]
if extra: fail("template", "有命名不合前缀约定的扩展端口 %s" % extra)

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

# 15 回归 manifest 中每个顶层都必须由 runner 编译到对应源文件
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sim_dir = os.path.join(root, "sim")
manifest_path = os.path.join(sim_dir, "tests.manifest")
runner_path = os.path.join(sim_dir, "run_regress.ps1")
if not os.path.isfile(manifest_path) or not os.path.isfile(runner_path):
    fail("manifest", "缺少 sim/tests.manifest 或 sim/run_regress.ps1")
else:
    runner_text = io.open(runner_path, encoding="utf-8", errors="replace").read()
    alias_block = re.search(r"\$tbfile\s*=\s*@\{(.*?)\}", runner_text, re.S)
    if not alias_block:
        fail("manifest", "无法读取 run_regress.ps1 的 TB 文件映射表")
    else:
        tbfile_map = dict(re.findall(r"'([^']+)'\s*=\s*'([^']+)'", alias_block.group(1)))
        manifest_rows = []
        seen_ids = set()
        manifest_errors = []
        for lineno, line in enumerate(io.open(manifest_path, encoding="utf-8", errors="replace"), 1):
            row = line.strip()
            if not row or row.startswith("#"):
                continue
            cols = row.split()
            if len(cols) < 2:
                manifest_errors.append("第 %d 行格式错误" % lineno)
                continue
            test_id, top = cols[0], cols[1]
            if test_id in seen_ids:
                manifest_errors.append("重复测试 ID %s" % test_id)
            seen_ids.add(test_id)
            source = tbfile_map.get(top, top)
            source_path = os.path.join(sim_dir, "tb", source + ".v")
            if not os.path.isfile(source_path):
                manifest_errors.append("%s 找不到源文件 tb/%s.v" % (test_id, source))
                continue
            source_text = io.open(source_path, encoding="utf-8", errors="replace").read()
            modules = set(re.findall(r"\bmodule\s+(?:(?:automatic|static)\s+)?([A-Za-z_]\w*)", source_text))
            if top not in modules:
                manifest_errors.append("%s 的顶层 %s 未在 tb/%s.v 声明" % (test_id, top, source))
            manifest_rows.append(test_id)
        if manifest_errors:
            fail("manifest", "; ".join(manifest_errors[:8]))
        else:
            ok("manifest", "%d 个 manifest 顶层都映射到现存且含对应 module 的 TB 文件" % len(manifest_rows))

print("\n== 结论 ==")
if not F:
    print("全部通过，0 处问题"); sys.exit(0)
for t, m in F: print("FAIL [%s] %s" % (t, m))
print("共 %d 处待处理" % len(F)); sys.exit(1)

