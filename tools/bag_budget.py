#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""按 §8.2 的判决式算配置带宽和（CFG_SUM）、抖动上界与构建器吞吐。

  python3 tools/bag_budget.py                      # 读设计书 §8.2 的用例块并复核
  python3 tools/bag_budget.py --n 32 --lmax 240 --bag-us 8000      # 自拟一组
  python3 tools/bag_budget.py --saturate 32 240    # 反算把链路压到 99.84% 所需 BAG
设计书 §8.2 的数字都出自这里，不许手填。
"""
import os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bag_model as bm


def show(label, n, frame_bytes, bag_us):
    m = bm.metrics(n, frame_bytes, bag_us)
    print("  %-14s N=%3d 帧长 %4d B  BAG=%9.1f μs ⇒ 占用 %.4f（%.2f Mbps）  %s"
          % (label, n, frame_bytes, bag_us, m["util"], m["mbps"], "合法" if m["legal"] else "超限→ERR.BAG_OVF"))
    print("     CFG_SUM Q20=%d（判决线 %d）｜单帧线上时间 %.2f μs ⇒ 饱和时抖动上界取 1 帧｜帧率 %.0f fps｜构建器 %.1f MB/s（上限 100）%s"
          % (m["q20"], bm.Q20, m["t_frame_us"], m["fps_total"], m["builder_MBps"],
             "" if m["builder_MBps"] <= 100 else "  ← 超构建器能力，必须先被 CFG_ERR 拒掉"))
    return m


def main():
    argv = sys.argv[1:]
    if "--saturate" in argv:
        i = argv.index("--saturate")
        n, payload = int(argv[i + 1]), int(argv[i + 2])
        bag = bm.sat_bag(n, payload + bm.OH)
        print("== 反算：N=%d、载荷 %d B 时把链路压到 99.84%% 需要 BAG=%.1f μs ==" % (n, payload, bag))
        show("饱和组", n, payload + bm.OH, bag)
        return 0
    if "--n" in argv:
        g = lambda k, d: float(argv[argv.index(k) + 1]) if k in argv else d
        show("自拟", int(g("--n", 32)), int(g("--lmax", 240)) + bm.OH, g("--bag-us", 8000.0))
        return 0
    doc = bm.doc_text(bm.find_doc())
    cs = bm.cases(doc)
    if not cs:
        print("§8.2 里没解析到 T05 用例；用 --n/--lmax/--bag-us 自拟一组，或先跑 check_doc_numbers.py 看格式问题")
        return 1
    print("== 设计书 §8.2 用例（现算复核）==")
    for name, n, payload, frame, bag_us, _blk in cs:
        if frame is None:
            print("  %-5s 行里缺「载荷 X B（帧长 Y B）」，跳过" % name)
            continue
        show(name, n, frame, bag_us)
    print("\n== 参考：几个规模档位把链路压到 ~99.84% 所需的 BAG ==")
    for n, payload in ((32, 240), (128, 240), (128, 1471), (16, 1471)):
        print("  N=%3d 载荷 %4d B ⇒ BAG = %9.1f μs（%.2f ms）" % (n, payload, bm.sat_bag(n, payload + bm.OH),
              bm.sat_bag(n, payload + bm.OH) / 1000))
    return 0


if __name__ == "__main__":
    sys.exit(main())

