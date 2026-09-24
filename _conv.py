# -*- coding: utf-8 -*-
"""一次性转换脚本（用户授权：只把 xlsx / rar 变成可读文本，不装东西、不删东西、不联网）。

产物全部落在工作区：
  问题汇总_sheetN.csv   每页一份 CSV（UTF-8 BOM，Excel 直接可开）
  _conv_report.txt      给对面读的纯文本报告：xlsx 结构 + 全表内容 + rar 解压清单与文本文件内容
"""
import csv, os, re, subprocess, sys, zipfile
import xml.etree.ElementTree as ET

WS = os.path.dirname(os.path.abspath(__file__))
os.chdir(WS)
NS = "{http://schemas.openxmlformats.org/spreadsheetml/2006/main}"
RPT = os.path.join(WS, "_conv_report.txt")
_report = []


def say(s=""):
    _report.append(str(s))


def col_idx(ref):
    m = re.match(r"([A-Z]+)", ref or "A1")
    n = 0
    for ch in (m.group(1) if m else "A"):
        n = n * 26 + (ord(ch) - 64)
    return n - 1


def clean(v):
    return re.sub(r"\s*\n\s*", " ⏎ ", (v or "").strip())


def sheet_names(xlsx):
    z = zipfile.ZipFile(xlsx)
    out = []
    try:
        wb = ET.fromstring(z.read("xl/workbook.xml"))
        rels = ET.fromstring(z.read("xl/_rels/workbook.xml.rels"))
        rid = {r.get("Id"): r.get("Target") for r in rels}
        RNS = "{http://schemas.openxmlformats.org/officeDocument/2006/relationships}"
        for sh in wb.iter(NS + "sheet"):
            tgt = rid.get(sh.get(RNS + "id"), "")
            out.append((sh.get("name"), "xl/" + tgt.lstrip("/").replace("xl/", "", 1) if tgt.startswith("/xl/") else ("xl/" + tgt if tgt else "")))
    except Exception as e:
        say("workbook.xml 解析失败：%s" % e)
    if not out:
        out = [("sheet%d" % (i + 1), m) for i, m in enumerate(
            sorted(n for n in z.namelist() if re.match(r"xl/worksheets/sheet\d+\.xml$", n)))]
    return out


def rows_of(xlsx, member):
    z = zipfile.ZipFile(xlsx)
    shared = []
    if "xl/sharedStrings.xml" in z.namelist():
        for si in ET.fromstring(z.read("xl/sharedStrings.xml")).findall(NS + "si"):
            shared.append("".join(t.text or "" for t in si.iter(NS + "t")))
    body = z.read(member)
    if isinstance(body, bytes):
        body = body.decode("utf-8", "replace")
    rows = []
    for row in ET.fromstring(body).iter(NS + "row"):
        cells = {}
        for c in row.findall(NS + "c"):
            t, v = c.get("t"), c.find(NS + "v")
            if t == "inlineStr":
                el = c.find(NS + "is")
                val = "".join(x.text or "" for x in el.iter(NS + "t")) if el is not None else ""
            elif v is None:
                val = ""
            elif t == "s":
                try:
                    val = shared[int(v.text)]
                except Exception:
                    val = ""
            else:
                val = v.text or ""
            cells[col_idx(c.get("r"))] = val
        if cells:
            w = max(cells) + 1
            rows.append([clean(cells.get(i, "")) for i in range(w)])
    return rows


def do_xlsx():
    xs = [f for f in os.listdir(WS) if f.lower().endswith(".xlsx") and not f.startswith("~$")]
    if not xs:
        say("没找到 xlsx"); return
    xlsx = xs[0]
    say("=== XLSX: %s (%d B) ===" % (xlsx, os.path.getsize(xlsx)))
    z = zipfile.ZipFile(xlsx)
    say("zip 成员: " + ", ".join(n for n in z.namelist() if n.endswith(".xml")))
    total = 0
    for i, (name, mem) in enumerate(sheet_names(xlsx)):
        if not mem or mem not in z.namelist():
            say("跳过 %s（成员 %r 不存在）" % (name, mem)); continue
        rows = rows_of(xlsx, mem)
        w = max((len(r) for r in rows), default=0)
        rows = [r + [""] * (w - len(r)) for r in rows]
        out = "问题汇总_%02d.csv" % (i + 1)
        with open(out, "w", encoding="utf-8-sig", newline="") as f:
            csv.writer(f).writerows(rows)
        say("\n--- 页 %d「%s」%d 行 × %d 列 → %s ---" % (i + 1, name, len(rows), w, out))
        for r in rows:
            say(" | ".join(x for x in r if x))
            total += 1
    say("\n共导出 %d 行" % total)


def do_rar():
    rs = [f for f in os.listdir(WS) if f.lower().endswith(".rar")]
    if not rs:
        say("没找到 rar"); return
    rar = rs[0]
    seven = r"C:\Program Files\7-Zip\7z.exe"
    say("\n=== RAR: %s (%d B) ===" % (rar, os.path.getsize(rar)))
    if not os.path.exists(seven):
        say("7z 不存在，跳过解压"); return
    before = {os.path.relpath(os.path.join(r, f), WS)
              for r, _, fs in os.walk(WS) for f in fs}
    lst = subprocess.run([seven, "l", "-ba", "-slt", rar], capture_output=True, text=True, errors="replace")
    say("归档清单:\n" + (lst.stdout or lst.stderr or "").strip()[:2000])
    ex = subprocess.run([seven, "x", "-y", "-o" + WS, rar], capture_output=True, text=True, errors="replace")
    say("解压 exit=%s" % ex.returncode)
    say("\n".join((ex.stdout or "").strip().splitlines()[-6:]))
    after = {os.path.relpath(os.path.join(r, f), WS)
             for r, _, fs in os.walk(WS) for f in fs}
    fresh = sorted(after - before)
    say("解压新增 %d 个文件:\n%s" % (len(fresh), "\n".join(fresh)))
    TXT = (".v", ".sv", ".vh", ".svh", ".ucf", ".xdc", ".tcl", ".do", ".sdc", ".qsf", ".qdc",
           ".md", ".txt", ".py", ".mif", ".hex", ".ini", ".cfg", ".csv", ".json", ".yaml",
           ".vhd", ".vmem", ".log", ".prj", ".bat")
    say("\n=== 解压出来的文本文件内容 ===")
    for rel in fresh:
        p = os.path.join(WS, rel)
        if not rel.lower().endswith(TXT):
            say("\n--- %s (%d B) 非文本，只列名 ---" % (rel, os.path.getsize(p))); continue
        if os.path.getsize(p) > 300000:
            say("\n--- %s 过大 %d B，只列名 ---" % (rel, os.path.getsize(p))); continue
        say("\n----- BEGIN %s -----" % rel)
        say(open(p, encoding="utf-8", errors="replace").read())
        say("----- END %s -----" % rel)


def main():
    say("工作区: %s" % WS)
    say("python: %s" % sys.version.split()[0])
    try:
        do_xlsx()
    except Exception as e:
        say("xlsx 失败: %r" % e)
    try:
        do_rar()
    except Exception as e:
        say("rar 失败: %r" % e)
    with open(RPT, "w", encoding="utf-8") as f:
        f.write("\n".join(_report) + "\n")
    print("report lines=%d bytes=%d" % (len(_report), os.path.getsize(RPT)))


if __name__ == "__main__":
    main()
