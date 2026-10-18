#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""批量提取 PDF 正文文本（供 AFDX 文献正文解析）。

用途：把下载夹里的论文 PDF 逐页抽出文本，输出到 out/lit_extract_<日期>/。
输出格式沿用既有约定：
    pages=<N>
    ===== PAGE 1 =====
    ...
判定「可读性」用的指标：
    chars  —— 抽出的可见字符数
    cjk    —— 中日韩字符数（中文论文的关键指标）
    ratio  —— cjk / pages，用于区分「真文本层」与「扫描件（近 0）」

不修改任何原文件；只读 + 写 out/。
"""
import os
import re
import json
import sys
import pymupdf

DL = r'C:\Users\tortl\Downloads'
OUT = r'C:\Workspace\diansai\out\lit_extract_20261015'
SKIP = ('智能小车_Schematic', '智能小车PCB_PCB', '选题指南', '产品手册')

CJK = re.compile(r'[\u4e00-\u9fff]')


def extract(path):
    doc = pymupdf.open(path)
    pages = []
    for page in doc:
        pages.append(page.get_text("text"))
    doc.close()
    return pages


def main():
    os.makedirs(OUT, exist_ok=True)
    files = sorted(f for f in os.listdir(DL)
                   if f.lower().endswith('.pdf') and not any(k in f for k in SKIP))

    report = []
    for f in files:
        src = os.path.join(DL, f)
        try:
            pages = extract(src)
        except Exception as e:
            report.append({"file": f, "error": f"{type(e).__name__}: {e}"})
            print(f"  !! {f}  ->  {type(e).__name__}: {e}")
            continue

        text = "\n".join(pages)
        n = len(pages)
        cjk = len(CJK.findall(text))
        visible = len(re.sub(r'\s', '', text))
        per_page = round(cjk / n, 1) if n else 0.0

        # 可读性粗判（供人工复核，不直接当结论）
        if per_page >= 300:
            grade = 'A?'          # 像真文本层
        elif per_page >= 60:
            grade = 'B?'          # 有文本但稀疏（可能半扫描 / 版式复杂）
        elif cjk > 200:
            grade = 'C?'
        else:
            grade = 'D?'          # 基本无文本层 = 扫描件

        stem = os.path.splitext(f)[0]
        dst = os.path.join(OUT, stem + '.txt')
        with open(dst, 'w', encoding='utf-8') as fh:
            fh.write(f"pages={n}\n")
            for i, p in enumerate(pages, 1):
                fh.write(f"\n===== PAGE {i} =====\n")
                fh.write(p)

        report.append({"file": f, "pages": n, "cjk": cjk,
                       "visible": visible, "cjk_per_page": per_page,
                       "auto_grade": grade, "out": os.path.relpath(dst, r'C:\Workspace\diansai')})
        print(f"  {grade}  {n:>3}p  cjk={cjk:>7}  {f}")

    with open(os.path.join(OUT, '_report.json'), 'w', encoding='utf-8') as fh:
        json.dump(report, fh, ensure_ascii=False, indent=1)

    ok = [r for r in report if 'error' not in r]
    print(f"\n合计 {len(files)} 份；成功 {len(ok)}；失败 {len(report)-len(ok)}")
    from collections import Counter
    print("自动分级分布:", dict(Counter(r['auto_grade'] for r in ok)))
    print("输出目录:", OUT)


if __name__ == '__main__':
    main()
