#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""以 §7.10 Python 黄金判决生成 T09 IC 接收/拒绝向量。

每 32 bit 字含 {prev_psn[7:0], sn[7:0], first_any[0],
accept[0], reason[2:0], next_psn[7:0]}；首字为后续向量数。
测试台先调试写入 prev_psn，再核对 RTL 的 accept/reason 与真实写回。
首先用另一种模 255 差值算法对全部 2×256×256 种判决交叉自检；
RTL 部分覆盖所有 256 个前序值的相邻/越界 SN 与固定种子随机值。
不依赖 RTL 常数，随机样本使用固定种子可重现。
"""
import pathlib
import random
from afdx_model import ic_decide

ROOT = pathlib.Path(__file__).resolve().parents[2]
OUT = ROOT / "sim" / "vec" / "t09_ic_cases.hex"


def ring_spec(prev, sn, first):
    """Independent specification using distance on the nonzero SN ring."""
    if sn == 0:
        return True, 0, 1
    if prev == 0:
        if sn == 1:
            return True, 1, 0
        return (True, sn, 3) if first else (False, 0, 4)
    gap = (sn - prev - 1) % 255
    if gap == 0:
        return True, sn, 0
    if gap == 1:
        return True, sn, 2
    return False, prev, 5


def generate():
    # Exhaustive software oracle audit: both first-frame modes, every
    # previous PSN, and every possible incoming SN (131072 combinations).
    for first in (0, 1):
        for prev in range(256):
            for sn in range(256):
                got = ic_decide(prev, sn, bool(first))
                want = ring_spec(prev, sn, bool(first))
                assert got == want, (first, prev, sn, got, want)
    # RTL vectors: force all 256 previous values through the interesting
    # boundaries; random cases fill the spaces between them.
    triples = [(prev, sn, first)
               for first in (0, 1)
                for prev in range(256)
                for sn in (0, 1, 2, prev, (prev - 1) & 255,
                           (prev % 255) + 1, ((prev + 1) % 255) + 1,
                           ((prev + 2) % 255) + 1, 254, 255)]
    rng = random.Random(0xA664)
    triples.extend((rng.randrange(256), rng.randrange(256), rng.randrange(2))
                   for _ in range(512))
    assert len(triples) == 5632
    lines = [f"{len(triples):08X}"]
    for prev, sn, first in triples:
        accepted, new_psn, reason = ic_decide(prev, sn, bool(first))
        assert (accepted and new_psn == sn) or (not accepted and new_psn == prev)
        word = (prev << 21) | (sn << 13) | (first << 12) | \
               (int(accepted) << 11) | (reason << 8) | new_psn
        lines.append(f"{word:08X}")
    OUT.write_text("\n".join(lines) + "\n", encoding="ascii")
    print(f"T09 Python golden: 131072 oracle checks, {len(triples)} RTL vectors -> {OUT}")


if __name__ == "__main__":
    generate()
