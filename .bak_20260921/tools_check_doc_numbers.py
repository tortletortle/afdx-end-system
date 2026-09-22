#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把设计书 §8.2 写死的 T05 用例逐条重算，并与文中数字对账。

算法全部来自 `tools/bag_model.py`（与 `bag_budget.py` 同一个实现），所以这里既能发现
「文档写错」，也能发现「文档与工具不再同式」。用法：

    python3 tools/check_doc_numbers.py            # 只核对 §8.2
    python3 tools/check_doc_numbers.py --emit     # 顺带打印按现算重排好的用例块（可直接贴回文档）
"""
import os, re, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bag_model as bm

TOL = 0.02


def main():
    doc = bm.doc_text(bm.find_doc())
    cs = bm.cases(doc)
    if not cs:
        print("FAIL  §8.2 里没解析到 T05 用例（正文格式变了，本脚本要跟着改）")
        return 1
    bad = 0
    print("== §8.2 用例数字对账 ==")
    print("   判决式：util = N × 帧长 × 8 / (BAG × 12.5 MB/s)，帧长 = 载荷 + %d" % bm.OH)
    emitted = []
    for name, n, payload, frame, bag_us, block in cs:
        stated = bm.parse_stated(block)
        if frame is None:
            print("  %-5s 行里没写 Lmax/BAG，无法核对 → 需要补全" % name)
            bad += 1
            continue
        m = bm.metrics(n, frame, bag_us)
        emitted.append((name, n, payload, frame, bag_us, m))
        print("  %-5s N=%3d Lmax=%4d B 帧长 %4d B BAG=%9.1f μs ⇒ util=%.4f  %.2f Mbps  CFG_SUM=%d  单帧 %.2f μs"
              % (name, n, payload, frame, bag_us, m["util"], m["mbps"], m["q20"], m["t_frame_us"]))
        checks = [("占用%", stated["util_pct"], m["util"] * 100, "%"),
                  ("占用倍", stated["util_x"], m["util"], "×"),
                  ("Mbps", stated["mbps"], m["mbps"], "Mbps"),
                  ("CFG_SUM", stated["cfg_sum"], float(m["q20"]), ""),
                  ("单帧", stated["t_frame"], m["t_frame_us"], "μs")]
        for tag, got, want, unit in checks:
            if got is None:
                continue
            if abs(got - want) > max(TOL * want, 0.011):
                print("      ✗ 文中 %-7s 写 %s%s，重算 %s%s（差 %.1f%%）"
                      % (tag, ("%g" % got), unit, ("%g" % want), unit, abs(got - want) / max(want, 1e-9) * 100))
                bad += 1
            else:
                print("      ✓ 文中 %-7s %s%s 与重算一致" % (tag, ("%g" % got), unit))
        if m["legal"] and not stated["legal"]:
            print("      ✗ util=%.4f ≤ 1，文中没写「合法」" % m["util"]); bad += 1
        if (not m["legal"]) and not stated["reject"]:
            print("      ✗ util=%.4f > 1，文中没写「超限/ERR.BAG_OVF」" % m["util"]); bad += 1
        if m["builder_MBps"] > 100:
            print("      · 构建器需求 %.0f MB/s 超 1 B/拍上限（100 MB/s）——文档应说明这组必须被判决先拒掉"
                  % m["builder_MBps"])
    if "--emit" in sys.argv:
        print("\n== 现算重排的用例块（可直接替换 §8.2 那段）==\n```")
        for name, n, payload, frame, bag_us, m in emitted:
            v = ("判决：合法（非饱和）" if m["util"] < 0.9 else
                 "判决：合法" if m["legal"] else "判决：超限→ERR.BAG_OVF")
            occ = ("%.2f%%" % (m["util"] * 100)) if m["util"] < 20 else ("%.3f 倍" % m["util"])
            print("%s  %-12s %d VL / Lmax=%d B（帧 %d B）/ BAG=%s μs"
                  % (name, {"T05a": "轻载回归组", "T05b": "饱和组", "T05c": "超载判定组"}[name], n, payload, frame,
                     ("%g" % bag_us) if bag_us < 1000 else ("%.0f" % bag_us)))
            print("                  ⇒ %.2f Mbps，链路占用 %s，CFG_SUM=%s/2^20，单帧 %.2f μs，%s"
                  % (m["mbps"], occ, format(m["q20"], ",").replace(",", " "), m["t_frame_us"], v))
        print("```")
    print("\n== 结论 ==\n%s" % ("全部一致：文档里的 §8.2 数字都可由判决式复算" if not bad
                              else "有 %d 处对不上（改文档，或确认文档是对的再改 bag_model）" % bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())

