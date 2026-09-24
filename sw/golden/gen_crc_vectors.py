#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""sw/golden/gen_crc_vectors.py — T00 CRC32 测试向量生成器（黄金模型单一来源）

用法: python sw/golden/gen_crc_vectors.py
输出: tb_t00_common.v 所需全部向量的期望 CRC32。模式向量
      byte[i] = (i*mult + add) & 0xFF 由 TB 现场重生成字节，本脚本只提供
      期望值；另输出一个真实 AFDX 帧（build_frame，L=8 最小载荷）的
      hex 与 FCS，闭合"RTL CRC == 黄金模型 CRC"。
改动向量后须同步 tb_t00_common.v 并重跑回归（sim/run_regress.ps1）。
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import afdx_model as m

# (name, len, mult, add)
PATTERNS = [
    ("p_empty",   0,    7, 0x00),
    ("p_std",     9,    1, 0x31),   # "123456789" -> 0xCBF43926
    ("p_one_00",  1,    0, 0x00),
    ("p_one_ff",  1,    0, 0xFF),
    ("p_odd17",  17,    7, 0x03),
    ("p_len64",  64,   13, 0x05),
    ("p_len60",  60,   11, 0x09),
    ("p_max",  1518,   31, 0x11),
]


def main():
    assert m.crc32(b"123456789") == 0xCBF43926, "黄金模型 CRC 常数漂移"
    for name, n, mult, add in PATTERNS:
        b = bytes([(i * mult + add) & 0xFF for i in range(n)])
        print("VEC %-9s len=%-4d mult=%-3d add=%-3d crc=0x%08X"
              % (name, n, mult, add, m.crc32(b)))
    frame, fcs = m.build_frame(vlid=0x0102, udi=0x33, ifid=5, net_id=0xA,
                               src_ip="10.0.1.1", dst_ip="10.0.2.2",
                               sport=5001, dport=5002,
                               payload=bytes(range(8)), sn=7)
    body = frame[:-4]
    assert int.from_bytes(frame[-4:], "little") == fcs == m.crc32(body)
    print("FRAME len=%d fcs=0x%08X" % (len(body), fcs))
    print("HEX " + body.hex())
    return 0


if __name__ == "__main__":
    sys.exit(main())
