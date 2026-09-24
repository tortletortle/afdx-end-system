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
try:
    import bag_model as bm
except ImportError:
    import tools_bag_model as bm  # 平铺布局的文件名


TOL = 0.02


def main():
    doc = bm.doc_text(bm.find_doc())
    cs = bm.cases(doc)
    if not cs:
        print("FAIL  §8.2 里没解析到 T05 用例（正文格式变了，本脚本要跟着改）")
        return 1
    bad = 0
    print("== §8.2 用例数字对账 ==")
    print("   判决式：util = N × (Lmax + %d) × 8 / (BAG × 12.5 MB/s)，Lmax = 以太帧长含 FCS，载荷 = Lmax − %d" % (bm.OH, bm.HDR_OH))
    emitted = []
    for name, n, payload, frame, bag_us, block in cs:
        stated = bm.parse_stated(block)
        if frame is None:
            print("  %-5s 行里没写 Lmax/BAG，无法核对 → 需要补全" % name)
            bad += 1
            continue
        m = bm.metrics(n, frame, bag_us)
        emitted.append((name, n, payload, frame, bag_us, m))
        print("  %-5s N=%3d Lmax=%4d B（载荷 %4d B）线上 %4d B BAG=%9.1f μs ⇒ util=%.4f  %.2f Mbps  CFG_SUM=%d  单帧 %.2f μs"
              % (name, n, payload, bm.payload_of(payload), frame, bag_us, m["util"], m["mbps"], m["q20"], m["t_frame_us"]))
        # 文中括号里的「载荷 X B」必须等于 Lmax − 47
        mp = re.search(r"载荷\s*(\d+)\s*B", block)
        if mp and int(mp.group(1)) != bm.payload_of(payload):
            print("      ✗ 文中载荷 %s B 与 Lmax−%d=%d 不符" % (mp.group(1), bm.HDR_OH, bm.payload_of(payload))); bad += 1
        checks = [("占用%", stated["util_pct"], m["util"] * 100, "%"),
                  ("占用倍", stated["util_x"], m["util"], "×"),
                  ("Mbps", stated["mbps"], m["mbps"], "Mbps"),
                  ("CFG_SUM", stated["cfg_sum"], float(m["q20"]), ""),
                  ("单帧", stated["t_frame"], m["t_frame_us"], "μs")]
        for tag, got, want, unit in checks:
            if got is None:
                continue
            # CFG_SUM 是整数定点值，逐 VL ceil 的差异虽小也必须逐位一致。
            if abs(got - want) > (0 if tag == "CFG_SUM" else max(TOL * want, 0.011)):
                print("      ✗ 文中 %-7s 写 %s%s，重算 %s%s（差 %.1f%%）"
                      % (tag, ("%g" % got), unit, ("%g" % want), unit, abs(got - want) / max(want, 1e-9) * 100))
                bad += 1
            else:
                print("      ✓ 文中 %-7s %s%s 与重算一致" % (tag, ("%g" % got), unit))
        if m["legal"] and not stated["legal"]:
            print("      ✗ util=%.4f ≤ 1，文中没写「合法」" % m["util"]); bad += 1
        if (not m["legal"]) and not stated["reject"]:
            print("      ✗ util=%.4f > 1，文中没写「超限/ERR.BAG_OVF」" % m["util"]); bad += 1
        if m["builder_MBps"] > bm.LINK_BPS / 8 / 1e6:
            print("      · 等效线上需求 %.1f MB/s 超 100 Mbps 链路上限（12.5 MB/s）——配置必须先被拒掉"
                  % m["builder_MBps"])
    # 125 MHz 口径残留禁查（§4.1 换算表保留旧口径作记录，豁免；附录 F 版本记录为历史，豁免）
    body = doc[:doc.index("## 附录 F")]
    i41a, i41b = body.index("### 4.1"), body.index("### 4.2")
    rest = body[:i41a] + body[i41b:]
    for pat, why in (("100 MHz", "100 MHz 口径残留"), ("CLK_FREQ_HZ` | 100_000_000", "100 MHz 参数残留（§4.1 换算表豁免）"),
                     ("-period 10.000", "SDC 仍按 100 MHz"), ("blk×0x400", "PMEM 块步长应为 0x200"),
                     ("1 字节/8 拍", "每字节拍数应为 10"), ("每字节 8 拍", "每字节拍数应为 10"),
                     ("= 512 拍", "125 MHz 下最小帧间隔应为 640 拍"),
                     ("8 cycles per byte", "§5.3 波形图应为 10 拍/字节"), ("Lmax+24", "O-01 后线上开销应为 Lmax+20"),
                     ("帧长=Lmax+24", "O-01 后 Lmax 即帧长"), ("+ L + 1（含 SN）", "O-02 后 SN 不计入长度字段"),
                     ("L+9", "O-02 后 UDP 长度应为 L+8"), ("BURST_", "O-07 后无突发寄存器"),
                     ("20_000", "CFG_SUM 判决线应为 2^20")):
        for ln in rest.splitlines():
            if pat in ln:
                print("  ✗ 口径残留[%s]: %s" % (why, ln.strip()[:60]))
                bad += 1
    if "--emit" in sys.argv:
        print("\n== 现算重排的用例块（可直接替换 §8.2 那段）==\n```")
        for name, n, payload, frame, bag_us, m in emitted:
            v = ("判决：合法（非饱和）" if m["util"] < 0.9 else
                 "判决：合法" if m["legal"] else "判决：超限→ERR.BAG_OVF")
            occ = ("%.2f%%" % (m["util"] * 100)) if m["util"] < 20 else ("%.3f 倍" % m["util"])
            print("%s  %-12s %d VL / Lmax=%d B（载荷 %d B，线上 %d B）/ BAG=%s μs"
                  % (name, {"T05a": "轻载回归组", "T05b": "饱和组", "T05c": "超载判定组"}[name], n, payload, bm.payload_of(payload), frame,
                     ("%g" % bag_us) if bag_us < 1000 else ("%.0f" % bag_us)))
            print("                  ⇒ %.2f Mbps，链路占用 %s，CFG_SUM=%s/2^20，单帧 %.2f μs，%s"
                  % (m["mbps"], occ, format(m["q20"], ",").replace(",", " "), m["t_frame_us"], v))
        print("```")
    print("\n== 结论 ==\n%s" % ("全部一致：文档里的 §8.2 数字都可由判决式复算" if not bad
                              else "有 %d 处对不上（改文档，或确认文档是对的再改 bag_model）" % bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())

