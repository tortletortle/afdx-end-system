#!/usr/bin/env python3
"""T57: 615A 取件引擎的 GMII 级装载端向量（P05 集成测试）。

TB 扮演装载端（server TID 40100，IP 10.0.0.2），仅需提供下行帧：
  f0: DATA(1) 512B（独立图案）
  f1: DATA(2) 8B 末块
  f2: ERROR(5) 文本（失败用例）
上行（DUT→TB）的 RRQ/ACK 在 TB 中按规范字段做结构化核对（opcode/端口/
块号/文件名常量），不依赖 Python 全帧金标。

布局（hex 词，大端）：
  [0]=3 [1]=len0 [bytes0...] [len1][bytes1...] [len2][bytes2...]
"""
import sys
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "sw" / "golden"))
from afdx_model import build_frame, parse_frame  # noqa: E402

OUT = ROOT / "sim" / "vec"

P512 = bytes((i * 7 + 0x21) & 0xFF for i in range(512))
P8 = bytes((i * 13 + 0x5A) & 0xFF for i in range(8))


def response(payload, sn, net):
    data, _ = build_frame(0x100, 0x172D, net + 1, net + 1,
                          "10.0.0.2", "10.0.0.1", 40100, 0x3001,
                          payload, sn, ident=0, tos=0, ttl=255)
    return data


def main():
    frames = [
        bytes([0, 3, 0, 1]) + P512,
        bytes([0, 3, 0, 2]) + P8,
        bytes([0, 5, 0, 5]) + b"LOADER ERR\x00",
    ]
    frames = [response(f, i + 1, 0) for i, f in enumerate(frames)]
    words = [len(frames)]
    for f in frames:
        d = parse_frame(f)
        assert d["fcs_ok"] and d["udp_csum_ok"]
        words.append(len(f))
        words.extend(int.from_bytes(f[i:i + 4].ljust(4, b"\0"), "big")
                     for i in range(0, len(f), 4))
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "t57_fetch.hex").write_text(
        "".join(f"{w:08x}\n" for w in words), encoding="ascii")
    (OUT / "t57_fetch.vh").write_text(
        f"`define T57_WORDS {len(words)}\n", encoding="ascii")
    print(f"T57 vectors: {len(frames)} frames, {len(words)} words")


if __name__ == "__main__":
    main()
