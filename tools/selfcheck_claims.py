#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""设计口径自查（不代替 RTL/仿真）：按现行 v0.5.11 的数字独立核算。

C1 低半哈希有效区的前门配置量 + 上电清零扫描量（两者不是同一过程）；
C2 T05 的 Lmax+20 线上帧长、逐 VL ceil 的 CFG_SUM 整数判决；
C3 同相启动时的最小排队等待，提醒它不是稳态「一帧」目标。
"""
import math

import bag_model as bm

CLK_HZ = 125_000_000


def c1_config_load():
    print("== C1 配置字数与初始化写拍（125 MHz，仅理论下界）==")
    tbl = {"TX VL": 128 * 5, "TX Q20 份额": 128, "RX 配置": 4096 * 2,
           "RX 哈希有效低半": 2 * 2048 * 2,
           "端口表": 256 * 4, "描述符": 256, "PMEM 初值": 8192}
    active = sum(tbl.values())
    reserved = 2 * 2048 * 2  # high half: unmapped, write must fail with ERR.ACC
    readback = 2 * 2048 * 2  # low half: mandatory host comparison to manifest
    with_hash_verify = active + readback
    sweep = {"PSN": 8192, "RM": 4096, "哈希 valid": 8192, "RX VL valid": 4096,
             "TX VL valid + share.loaded": 128, "端口 valid": 256, "RX 描述符": 256, "VL 统计": 128}
    init_writes = sum(sweep.values())
    assert (active, reserved, with_hash_verify, init_writes) == (26_624, 8192, 34_816, 25_344)
    for name, words in tbl.items():
        print("  %-18s %6d 字" % (name, words))
    print("  前门仅有效区 %d 字：单字 1 拍下界 %.3f μs，若 2 拍/字则 %.3f μs" %
          (active, active / CLK_HZ * 1e6, 2 * active / CLK_HZ * 1e6))
    print("  哈希低半区读回 %d 字：单字 1 拍下界 %.3f μs；高半区 %d 字保留且禁止写入" %
          (readback, readback / CLK_HZ * 1e6, reserved))
    print("  有效区写入+哈希读回 %d 拍：理论下界 %.3f μs（不含种子/提交/CFG_MODE）" %
          (with_hash_verify, with_hash_verify / CLK_HZ * 1e6))
    print("  复位初始化 %d 写拍：扫描下界 %.3f μs，另加控制开销" %
          (init_writes, init_writes / CLK_HZ * 1e6))
    print("  初始化+写入+哈希读回串行下界 %.3f μs；T22 须实测寄存器/协议开销" %
          ((with_hash_verify + init_writes) / CLK_HZ * 1e6))
    return active / CLK_HZ


def c2_bag_rule():
    print("\n== C2 T05 连续带宽与逐 VL Q20 判决 ==")
    cases = bm.cases()
    assert {c[0] for c in cases} == {"T05a", "T05b", "T05c"}, "§8.2 T05 用例缺失"
    expected = {"T05a": (108_384, True), "T05b": (1_047_168, True),
                "T05c": (2_064_384, False)}
    for name, n, lmax, wire, bag_us, block in cases:
        assert wire == lmax + 20 and bag_us == int(bag_us), "用例字节/BAG 口径已变，请更新自查"
        capacity_bits = int(bag_us) * 100  # 100 Mbps = 每 μs 100 bit
        each = (wire * 8 * bm.Q20 + capacity_bits - 1) // capacity_bits
        q20 = n * each
        m = bm.metrics(n, wire, bag_us)
        assert (q20, q20 <= bm.Q20) == expected[name]
        assert m["q20"] == q20 and m["legal"] == (q20 <= bm.Q20)
        asserted_q20 = bm.parse_stated(block)["cfg_sum"]
        assert asserted_q20 is not None and int(asserted_q20) == q20, "文档 CFG_SUM 与整数式不一致"
        print("  %-4s N=%3d Lmax=%4d B / 线上=%4d B / BAG=%4d μs → %6.2f Mbps, Q20=%d/%d, %s" %
              (name, n, lmax, wire, int(bag_us), m["mbps"], q20, bm.Q20,
               "合法" if m["legal"] else "拒绝"))
    return cases


def c3_jitter(n_vl=32, lmax=303):
    print("\n== C3 同相启动排队（解析模型，不是 RTL 测值或完整抖动上界）==")
    wire = lmax + bm.OH
    frame_us = wire * 8 / bm.LINK_BPS * 1e6
    tail_wait_us = (n_vl - 1) * frame_us
    print("  %d 条 VL 同相起发，单帧 %d B（含前导/IFG）=%.2f μs" %
          (n_vl, wire, frame_us))
    print("  末条仅排队至少 (%d-1)×%.2f=%.2f μs（未计扫描/握手），%s 500 μs 合规线" %
          (n_vl, frame_us, tail_wait_us, "超过" if tail_wait_us > 500 else "未超过"))
    assert tail_wait_us > 500, "同步启动风险样例变了，需重估 T05"
    print("  这是旧同相起发的解析风险样例；当前 T05b/T05bg 已按每 VL 错相提交并以 500 μs 为硬判据，")
    print("  其周期级实测见对应 Questa 日志；本模型不读取仿真结果，也不证明 STA/标准认证。")
    return tail_wait_us


if __name__ == "__main__":
    c1_config_load()
    c2_bag_rule()
    c3_jitter()
    print("\n自查通过：模型/文档相符；T05b/T05bg、T22/T22g 已有 RTL 用例，")
    print("每次是否 PASS 应查看对应回归 CSV/Questa 日志；本脚本仅验算理论与文档，不替代 RTL 仿真或 STA。")
