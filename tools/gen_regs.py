#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从 doc/regs.yaml 生成寄存器相关内容，并核对设计书附录 A / A.1~A.3 与 RTL localparam 头。

只用标准库：赛题环境（eLinx + ModelSim + Python3）不保证有 PyYAML，所以这里自带一个
受限 YAML 子集解析器（`key: value`、两级缩进列表、`- {k: v, ...}` 行内字典）。

用法：
  python3 tools/gen_regs.py            # 校验：YAML vs 设计书正文，报告差异（默认不写文件）
  python3 tools/gen_regs.py --emit     # 另外打印生成的 RTL 头 doc/regs_pkg.svh
  python3 tools/gen_regs.py --write    # 用 YAML 覆盖设计书附录 A 的三张位域表 + 生成 RTL 头
"""
import io, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)


def _find(name):
    """设计书位置不固定：脚本同级、上一级、当前目录、家目录都找一遍（平铺或 tools/ 子目录都能跑）。"""
    for base in (HERE, ROOT, os.getcwd(), os.path.expanduser("~")):
        p = os.path.join(base, name)
        if os.path.exists(p):
            return p
    return os.path.join(ROOT, name)


def _find_yaml():
    for c in (os.path.join(ROOT, "doc", "regs.yaml"), os.path.join(ROOT, "doc_regs.yaml"),
              os.path.join(HERE, "doc_regs.yaml"), os.path.join(os.getcwd(), "doc_regs.yaml"),
              os.path.join(os.getcwd(), "doc", "regs.yaml")):
        if os.path.exists(c):
            return c
    return os.path.join(ROOT, "doc", "regs.yaml")


YAML = _find_yaml()
DOC = _find("AFDX端系统_总体设计书.md")
PKG = (os.path.join(os.path.dirname(YAML), "regs_pkg.svh") if os.path.basename(os.path.dirname(YAML)) == "doc"
       else os.path.join(ROOT, "doc_regs_pkg.svh"))


# ---------- 受限 YAML 子集 ----------
def _scalar(v):
    v = v.strip()
    if v.startswith('"') and v.endswith('"'):
        return v[1:-1]
    if re.fullmatch(r"0x[0-9A-Fa-f_]+", v):
        return int(v.replace("_", ""), 16)
    if re.fullmatch(r"-?\d+", v):
        return int(v)
    return v


def _inline(s):
    """解析 `{k: v, k2: v2}`。"""
    out = {}
    for part in re.findall(r"(\w+):\s*([^,}]+)", s.strip().lstrip("{").rstrip("}")):
        out[part[0]] = _scalar(part[1])
    return out


def parse_yaml(path):
    root = {}
    stack = [(-1, root)]          # (indent, container)
    pending_list = None
    for raw in io.open(path, encoding="utf-8").read().splitlines():
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        indent = len(raw) - len(raw.lstrip(" "))
        line = raw.strip()
        while stack and indent <= stack[-1][0]:
            stack.pop()
        container = stack[-1][1]
        if line.startswith("- "):
            if not isinstance(container, list):
                raise ValueError("列表项出现在非列表容器: %s" % line)
            body = line[2:].strip()
            if body.startswith("{"):
                container.append(_inline(body)); continue
            d = {}
            k, v = body.split(":", 1)
            d[k.strip()] = _scalar(v)
            container.append(d)
            stack.append((indent, d))      # 同级后续键属于这一项
            continue
        if ":" in line:
            k, v = line.split(":", 1)
            k = k.strip(); v = v.strip()
            if v == "":
                container[k] = []
                stack.append((indent, container[k]))
            else:
                if isinstance(container, list):        # 列表项的后续键
                    k2, v2 = k, v
                    container[-1][k2] = _scalar(v2)
                else:
                    container[k] = _scalar(v)
    return root


# ---------- 生成 ----------
def rows(regs):
    out = ["| 地址 | 名称 | 位域 |", "|---|---|---|"]
    for r in regs:
        addr = "`0x%04X`" % r["addr"]
        if r.get("span", 1) > 1:
            addr = "%s~`0x%04X`" % (addr, r["addr"] + (r["span"] - 1) * 4)
        if r["name"] == "STATS_BLOCK":
            addr = "`0x0100`~`0x01FF`"
        out.append("| %s | %s | %s |" % (addr, "`%s`" % r["name"], r["desc"]))
    return "\n".join(out)


def bit_table(items, cols):
    head = "| bit | 名称 | %s |" % "| ".join(c for c, _ in cols[1:])
    sep = "|" + "---|" * (len(cols))
    lines = [head, sep]
    for it in items:
        cells = [it.get(c, "") for c, _ in cols[1:]]
        cells = ["%s" % (dflt_fmt(v) if isinstance(v, int) else v) for v, (_, dflt_fmt) in zip(cells, cols[1:])]
        lines.append("| %s | `%s` | %s |" % (it["bit"], it["name"], " | ".join(cells)))
    return "\n".join(lines)


def ctl_table(bits):
    lines = ["| bit | 名称 | 默认 | 含义 |", "|---|---|---|---|"]
    for b in bits:
        lines.append("| %d | `%s` | %d | %s |" % (b["bit"], b["name"], b["dflt"], b["desc"]))
    return "\n".join(lines)


def simple_table(bits, third):
    lines = ["| bit | 名称 | %s |" % third, "|---|---|---|"]
    for b in bits:
        lines.append("| %s | `%s` | %s |" % (b["bit"], b["name"], b["desc"]))
    return "\n".join(lines)


def reset_from_bits(bits):
    v = 0
    for b in bits:
        if b["dflt"]:
            v |= 1 << b["bit"]
    return v


def emit_pkg(regs, width=32):
    L = ["// 由 tools/gen_regs.py 从 doc/regs.yaml 生成，请勿手改。", "`define REG_WIDTH %d" % width, ""]
    for r in regs:
        L.append("localparam int ADDR_%-14s = 16'h%04X;   // %s" % (r["name"], r["addr"], r["access"]))
    L.append("")
    L.append("// 访问属性位图（host_if 译码用）：bit0=可写, bit1=可读, bit2=W1C")
    for r in regs:
        w = 1 if r["access"] in ("rw", "wo", "w1c") else 0
        rd = 0 if r["access"] == "wo" else 1
        w1c = 1 if r["access"] == "w1c" else 0
        L.append("localparam bit [2:0] ACC_%-14s = 3'b%d%d%d;" % (r["name"], w1c, rd, w))
    L.append("")
    L.append("localparam logic [31:0] CTL_RESET = 32'h%08X;" % CTL_RST)
    L.append("localparam logic [31:0] UDP_CFG_RESET = 32'h%08X;" % UDP_RST)
    return "\n".join(L) + "\n"


def extract_doc_block(s, start_marker, stop_regex):
    i = s.index(start_marker)
    j = re.search(stop_regex, s[i:])
    return s[i:i + j.start()], i, i + j.start()


def norm_tbl(text):
    rows = []
    for l in text.splitlines():
        if not l.startswith("|") or set(l) <= set("|- "):
            continue
        c = [x.strip().strip("`") for x in l.strip().strip("|").split("|")]
        rows.append(c)
    return rows


def diff_rows(a, b, what):
    out = []
    if len(a) != len(b):
        out.append("%s 行数不同：YAML %d 行，文档 %d 行" % (what, len(a), len(b)))
    for i in range(min(len(a), len(b))):
        if a[i] != b[i]:
            out.append("%s 第 %d 行 YAML=%s 文档=%s" % (what, i, " | ".join(a[i])[:110], " | ".join(b[i])[:110]))
    for i in range(len(b), len(a)):
        out.append("%s 文档缺第 %d 行 %s" % (what, i, " | ".join(a[i])[:110]))
    return out


if __name__ == "__main__":
    y = parse_yaml(YAML)
    regs = y["registers"]
    CTL_RST = reset_from_bits(y["ctl_bits"])
    UDP_RST = _scalar("0x%08X" % regs[[r["name"] for r in regs].index("UDP_CFG")]["reset"])
    print("解析 %s：%d 个寄存器、CTL %d 位、STATUS %d 位、ERR %d 位"
          % (os.path.relpath(YAML, ROOT), len(regs), len(y["ctl_bits"]), len(y["status_bits"]), len(y["err_bits"])))

    # YAML 自检
    probs = []
    addrs = [r["addr"] for r in regs if not r.get("no_addr")]
    if addrs != sorted(addrs):
        probs.append("寄存器偏移未递增: %s" % [hex(a) for a in addrs])
    if len(set(addrs)) != len(addrs):
        probs.append("偏移重复")
    for r in regs:
        if r.get("no_addr"):
            continue
        if not (0x0000 <= r["addr"] <= 0x00FC):
            probs.append("%s 越出寄存器页 0x0000~0x00FC" % r["name"])
        if r["addr"] % 4:
            probs.append("%s 偏移不是 4 字节对齐" % r["name"])
        if r["access"] not in ("ro", "wo", "rw", "w1c", "rc"):
            probs.append("%s access 取值非法 %s" % (r["name"], r["access"]))
    exp = reset_from_bits(y["ctl_bits"])
    got = regs[[r["name"] for r in regs].index("CTL")]["reset"]
    if exp != got:
        probs.append("CTL reset 与 ctl_bits 默认值不一致：ctl_bits 推得 0x%04X，YAML 写 0x%04X" % (exp, got))
    print("YAML 自检：%s" % ("通过" if not probs else probs))

    doc = io.open(DOC, encoding="utf-8").read()
    # 附录 A 主表
    a0 = doc.index("## 附录 A")
    a1 = doc.index("### A.1", a0)
    # 只比「地址 + 名称」两列，位域列的措辞两边允许不同。
    # 文档里 DROP_CNT[0..11]、BURST_* 是合并行（一行代表多个寄存器），按组名展开成 YAML 的名字。
    GROUP = {"DROP_CNT_K": ["DROP_CNT_K"],
             "BURST_ADDR/BURST_LEN/BURST_DATA": ["BURST_ADDR", "BURST_LEN", "BURST_DATA"],
             "STATS_*": ["STATS_BLOCK"]}
    def canon(cell):
        return cell.strip().strip("`").strip()
    dd = []
    for l in doc[a0:a1].splitlines():
        if not l.startswith("|"):
            continue
        c = [x for x in l.strip().strip("|").split("|")]
        if len(c) != 3 or c[1].strip() in ("名称", "---") or "位域" in c[2] or set(c[1]) <= set("-: "):
            continue
        raw_addr = canon(c[0]).replace("`", "")
        a_cell = raw_addr if raw_addr.endswith("~") else raw_addr.split("~")[0]
        n_cell = c[1].replace("`", "").strip()
        if n_cell in GROUP:
            dd += [(a_cell, g) for g in GROUP[n_cell]]
        else:
            dd.append((a_cell, n_cell))
    yy = [("0x0100~0x01FF" if r.get("no_addr") else "0x%04X" % r["addr"], r["name"]) for r in regs]
    dd = [(a.split("~")[0], n) for a, n in dd]
    yy = [(a.split("~")[0], n) for a, n in yy]
    probs2 = []
    dname = dict((n, a) for a, n in dd)
    for a, r in zip([x[0] for x in yy], regs):
        if r["name"] not in dname:
            probs2.append("文档附录 A 缺 %s" % r["name"])
        elif dname[r["name"]] != a:
            probs2.append("%s 地址不一致：YAML %s，文档 %s" % (r["name"], a, dname[r["name"]]))
    unknown = [n for _, n in dd if n not in {r["name"] for r in regs}]
    if unknown:
        probs2.append("文档有 YAML 里没有的寄存器名 %s" % unknown)
    if [n for _, n in dd] != [n for _, n in yy]:
        probs2.append("顺序/行数不一致：文档 %s vs YAML %s" % ([n for _, n in dd], [n for _, n in yy]))
    print("附录 A 主表对账：%s" % ("一致（%d 个寄存器，偏移递增且 4 字节对齐）" % len(yy) if not probs2 else probs2))

    # 三张位域表
    ctl_doc = norm_tbl(doc[doc.index("### A.1"):doc.index("### A.2")])
    ctl_yaml = norm_tbl(ctl_table(y["ctl_bits"]))
    st_doc = norm_tbl(doc[doc.index("### A.2"):doc.index("### A.3")])
    st_yaml = norm_tbl(simple_table(y["status_bits"], "含义"))
    er_doc = norm_tbl(doc[doc.index("### A.3"):doc.index("## 附录 B")])
    er_yaml = norm_tbl(simple_table(y["err_bits"], "触发条件"))
    d = diff_rows(ctl_yaml, ctl_doc, "A.1 CTL") + diff_rows(st_yaml, st_doc, "A.2 STATUS") + diff_rows(er_yaml, er_doc, "A.3 ERR")
    print("位域表对账：%s" % ("一致" if not d else "\n  - ".join([""] + d)))
    probs = probs + probs2
    if "--emit" in sys.argv or "--write" in sys.argv:
        io.open(PKG, "w", encoding="utf-8").write(emit_pkg(regs))
        print("已写出 %s（%d 行）" % (os.path.relpath(PKG, ROOT), emit_pkg(regs).count("\n")))
    if "--write" in sys.argv:
        seg = doc[doc.index("### A.1"):doc.index("## 附录 B")]
        new = ("### A.1 `CTL`（`0x0008`）位域\n\n%s\n\n### A.2 `STATUS`（`0x000C`）位域\n\n%s\n\n"
               "### A.3 `ERR`（`0x0010`）位域（W1C）\n\n%s\n\n") % (ctl_table(y["ctl_bits"]),
                   simple_table(y["status_bits"], "含义"), simple_table(y["err_bits"], "触发条件"))
        head = seg[:seg.index("\n\n") + 2]
        doc = doc.replace(seg, head + new + "\n", 1)
        io.open(DOC, "w", encoding="utf-8").write(doc)
        print("已回写附录 A.1~A.3")
    sys.exit(1 if (probs or probs2 or d) else 0)


