#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""按 §8.2 的判决式算配置带宽和（CFG_SUM）、抖动上界与构建器吞吐。

  python3 tools/bag_budget.py                      # 读设计书 §8.2 的用例块并复核
  python3 tools/bag_budget.py --n 32 --lmax 303 --bag-us 8000      # 自拟一组（Lmax = 以太帧长含 FCS）
  python3 tools/bag_budget.py --saturate 32 303    # 反算把链路压到 99.84% 所需 BAG
设计书 §8.2 的数字都出自这里，不许手填。
"""
import os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bag_model as bm


def show(label, n, frame_bytes, bag_us):
    m = bm.metrics(n, frame_bytes, bag_us)
    print("  %-14s N=%3d Lmax %4d B（线上 %4d B） BAG=%9.1f μs ⇒ 占用 %.4f（%.2f Mbps）  %s"
          % (label, n, frame_bytes - bm.OH, frame_bytes, bag_us, m["util"], m["mbps"], "合法" if m["legal"] else "超限→ERR.BAG_OVF"))
    print("     CFG_SUM Q20=%d（逐 VL ceil 后求和，判决线 %d）｜单帧线上时间 %.2f μs（非抖动上界）｜帧率 %.0f fps｜等效线上需求 %.1f MB/s（100 Mbps 上限 12.5）%s"
          % (m["q20"], bm.Q20, m["t_frame_us"], m["fps_total"], m["builder_MBps"],
             "" if m["builder_MBps"] <= bm.LINK_BPS / 8 / 1e6 else "  ← 超链路线速，必须先被 CFG_ERR 拒掉"))
    return m


def main():
    argv = sys.argv[1:]
    if "--saturate" in argv:
        i = argv.index("--saturate")
        n, lmax = int(argv[i + 1]), int(argv[i + 2])
        bag = bm.sat_bag(n, lmax + bm.OH)
        print("== 反算：N=%d、Lmax %d B 时把链路压到 99.84%% 需要 BAG=%.1f μs ==" % (n, lmax, bag))
        show("饱和组", n, lmax + bm.OH, bag)
        return 0
    if "--n" in argv:
        g = lambda k, d: float(argv[argv.index(k) + 1]) if k in argv else d
        show("自拟", int(g("--n", 32)), int(g("--lmax", 303)) + bm.OH, g("--bag-us", 8000.0))
        return 0
    doc = bm.doc_text(bm.find_doc())
    cs = bm.cases(doc)
    if not cs:
        print("§8.2 里没解析到 T05 用例；用 --n/--lmax/--bag-us 自拟一组，或先跑 check_doc_numbers.py 看格式问题")
        return 1
    print("== 设计书 §8.2 用例（现算复核）==")
    for name, n, lmax, frame, bag_us, _blk in cs:
        if frame is None:
            print("  %-5s 行里缺「Lmax=X B / BAG=Y」，跳过" % name)
            continue
        show(name, n, frame, bag_us)
    print("\n== 参考：几个规模档位把链路压到 ~99.84% 所需的 BAG ==")
    for n, lmax in ((32, 303), (128, 303), (128, 1518), (16, 1518)):
        print("  N=%3d Lmax %4d B（载荷 %4d B）⇒ BAG = %9.1f μs（%.2f ms）" % (n, lmax, bm.payload_of(lmax),
              bm.sat_bag(n, lmax + bm.OH), bm.sat_bag(n, lmax + bm.OH) / 1000))
    return 0


if __name__ == "__main__":
    sys.exit(main())

