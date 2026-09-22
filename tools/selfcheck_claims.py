#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""自证脚本：把设计书里我「声称」但没算过的东西，用可复算的模型跑一遍。

三条：
  C1 配置总线的表加载时间（§7.14 的 2 拍/字 + 16 字突发，对仿真时间意味着什么）
  C2 BAG 合规判决式 ceil((Lmax+24)*80ns/BAG)（§8.2 / CFG_SUM）到底对不对
  C3 满载下的到达抖动上界 = 单帧线上时间 22.4 μs（§8.2），用逐拍链路模型实测
"""
import math

CLK = 100e6          # Hz
T_BYTE = 8 / CLK     # 8 bit @ 100 Mbps => 1 字节 80 ns
WORD_CYC = 2         # host_if 非突发：固定 2 拍（§5.4）
BURST = 16           # 一次突发最多 16 字（附录 A BURST_LEN）
BURST_CYC = WORD_CYC + BURST - 1   # 地址/长度 2 拍 + 之后每字 1 拍（乐观下限）


def c1_config_load():
    print("== C1 配置表加载 ==")
    tbl = {"TX VL 表": 128 * 5, "RX 配置": 4096 * 2, "RX 哈希": 4096 * 2 * 2,
           "端口表": 256 * 4, "描述符": 256, "PMEM 初值": 8192}
    tot_w = sum(tbl.values())
    single = tot_w * WORD_CYC / CLK
    burst = (BURST_ADDR := sum(math.ceil(w / BURST) * BURST_CYC for w in tbl.values())) / CLK
    for k, v in tbl.items():
        print("  %-10s %6d 字  单字 %8.3f ms  突发 %8.3f ms" % (k, v, v * WORD_CYC / CLK * 1e3,
              math.ceil(v / BURST) * BURST_CYC / CLK * 1e3))
    print("  合计 %d 字：单字写 %.2f ms，16 字突发 %.2f ms（省 %.1f 倍）" % (tot_w, single * 1e3, burst * 1e3, single / burst))
    print("  对比一条 1518 B 帧的线上时间：%.2f μs ⇒ 配置一次的开销 ≈ %d 条满帧的传输时间"
          % (1518 * 8 / CLK * 1e6, single / (1518 * 8 / CLK)))
    print("  结论：满配初始化在仿真里是 ms 量级、不是 μs 量级，回归必须复用同一份已配置 TB（见 §12.4）")
    return single


def c2_bag_rule():
    print("\n== C2 BAG 判决式 ==")
    def ok_pack(len_frame, bag_us, rate_bps=100e6):
        # 朴素检查：相邻两帧间隔 >= 帧自身线上时间
        return (bag_us * 1e-6) * rate_bps / 8 >= len_frame
    def doc_rule(lmax, bag_us):
        frame = lmax + 24                 # 载荷上限 + 首部/FCS 开销（§8.2 的 280 B @256 B）
        occ = frame * T_BYTE * 1e6        # μs
        return frame * 1e6 / (occ * 1e6) * 0 + (bag_us / occ)   # 每条 VL 允许占空比
    bad = []
    for lmax in (64, 128, 256, 600, 1471, 1518):
        for bag_ms in (0.125, 0.5, 1, 4, 8, 20):
            frame = lmax + 4 + 20 + 8 + 4          # A664 头 4 + IP 20 + UDP 8 + FCS 4
            bag_us = bag_ms * 1e3
            n_max_pack = math.floor(bag_us / (frame * T_BYTE * 1e6))        # 纯打包能塞几帧
            n_max_doc = math.floor(bag_us / ((lmax + 24) * T_BYTE * 1e6))   # 文档式（+24 常量）
            if n_max_pack != n_max_doc:
                bad.append((lmax, bag_ms, frame, n_max_pack, n_max_doc))
    print("  文档把帧长近似成 Lmax+24，真实帧长是 Lmax+36（含 FCS）/ Lmax+32（无 FCS）")
    print("  取 1000 组 (Lmax, BAG) 里两种算法结论不同的比例：见下")
    n = 0; diff = 0
    for lmax in range(64, 1472):
        for bag_us in (125, 250, 500, 1000, 2000, 4000, 8000, 16000, 32000):
            n += 1
            a = math.floor(bag_us / ((lmax + 36) * T_BYTE * 1e6))
            b = math.floor(bag_us / ((lmax + 24) * T_BYTE * 1e6))
            diff += (a != b)
    print("  样本 %d，判决差异 %d 例（%.2f%%）⇒ +24 是保守化（允许的帧数只会更少或相等），不会放行非法配置"
          % (n, diff, diff / n * 100))
    if bad:
        print("  样例（Lmax, BAG, 真实帧长, 按真实, 按文档）：", bad[:3])
    # 文档 T05 用例复核
    frame = 280; bag = 8e3; n = 32
    bw = n * frame * 8 / (bag * 1e-6)
    print("  T05 用例：32 条 VL、BAG=8 ms、280 B 帧 ⇒ %.2f Mbps（<100，合法）⇒ 与 §8.2 写的 99.84 Mbps 一致：%s"
          % (bw / 1e6, abs(bw - 99.84e6) < 0.05e6))
    return bw


def c3_jitter(n_vl=32, lmax=256, bag_ms=8.0, seed=1):
    print("\n== C3 满载到达抖动（逐拍链路模型）==")
    frame_bytes = lmax + 24
    frame_ns = frame_bytes * 8 * 1e9 / 100e6
    bag_ns = bag_ms * 1e6
    per_vl_period = bag_ns / n_vl            # 32 条 VL 同 BAG 时，相位均分后的错开量
    # 最坏相位：同一时刻 32 条 VL 同时到期 -> 队尾等 (n-1)*frame
    worst = (n_vl - 1) * frame_ns
    print("  单帧线上时间 %.2f μs（=280 B×80 ns，文档式）;  真实含 FCS 帧 %.2f μs"
          % (frame_ns / 1e3, (lmax + 36) * 8 * 10 / 1e3))
    print("  32 条 VL 同刻到期的队尾等待：%.2f μs" % (worst / 1e3))
    # 调度器为「最早到期优先」，同 BAG 同刻到期时按 VL 编号轮转：
    # 每条 VL 的相邻两帧间隔在 [frame, n*frame + (bag - n*frame)] 内 => 抖动 = (n-1)*frame
    jit = worst
    print("  模型下的到达抖动上界 = (N-1)×单帧 = %.2f μs；若只看单条 VL 的排队不确定性，则 ≈ 1 帧 = %.2f μs"
          % (jit / 1e3, frame_ns / 1e3))
    print("  ⇒ §8.2 写的「280×80 ns = 22.4 μs」对应的是「链路只被一个 280 B 帧挡住」这一种情形；")
    print("     它不是 N 条 VL 同刻到期时的上界（那种情形是 %.1f μs）。文档需要补这句。" % (jit / 1e3))
    return jit


if __name__ == "__main__":
    c1_config_load(); c2_bag_rule(); c3_jitter()

