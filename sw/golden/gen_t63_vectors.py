#!/usr/bin/env python3
"""T63: 615A LUR 宿主观测读路径 逐字节验证 的 GMII 级向量（P05 集成测试）。

TB 只做两件事：
  1) 下行一帧 LUR 清单（UDP 载荷 → 管理 SAP → lur_rx 解析）；
  2) 经宿主 0xAC88/0xAC89/0xAC8A/0xAC8B 逐字节读回名字。

清单含 3 个文件，覆盖三种长度形态：
  0: "A.BIN"          (6  = 5 + NUL)
  1: "LONGNAME.BIN"   (13 = 12 + NUL)
  2: "C.DE"           (5  = 4 + NUL)

LUR 载荷格式（与 a615a_lur_rx 对齐）：
  [declared_total:u32 BE][version:u16 BE][file_count:u16 BE]
  之后每个文件两段（各 = [len:u8][bytes...][NUL]）：name 段 + part 段。

同时输出：
  vec/t63_lur_hostrd.hex        帧向量（与 T62 同布局）
  vec/t63_lur_hostrd.vh         `define T63_WORDS
  vec/t63_lur_hostrd_meta.hex   哈希表 meta 两个字
  vec/t63_lur_hostrd_img.hex    RX VLID 哈希映像 8192 字
"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "sw" / "golden"))
from afdx_model import build_frame, parse_frame  # noqa: E402

OUT = ROOT / "sim" / "vec"

FILES = [(b"A.BIN", b"P1"), (b"LONGNAME.BIN", b"P2"), (b"C.DE", b"P3")]


def lur_payload():
    body = bytearray()
    for name, part in FILES:
        body += bytes([len(name) + 1]) + name + b"\x00"
        body += bytes([len(part) + 1]) + part + b"\x00"
    head = bytearray()
    total = 4 + 2 + 2 + len(body)
    head += total.to_bytes(4, "big")
    head += (0x4131).to_bytes(2, "big")
    head += len(FILES).to_bytes(2, "big")
    return bytes(head + body)


def response(payload, sn, net=0):
    """下行响应帧：server 10.0.0.2:40100 -> 10.0.0.1:0x3001，VLID 0x100。"""
    data, _ = build_frame(0x100, 0x172D, net + 1, net + 1,
                          "10.0.0.2", "10.0.0.1", 40100, 0x3001,
                          payload, sn, ident=0, tos=0, ttl=255)
    return data


def hash_image():
    """VLID 0x100 → 索引 256 的哈希映像（8192 字，宽度按 GBIT 掩码）。"""
    img = [0] * 8192
    idx = 256
    img[(idx * 2 + 0) % 8192] = 1 << (idx % 32)
    return img


def main():
    lur = lur_payload()
    frames = [response(lur, 1)]

    words = [len(frames)]
    for f in frames:
        d = parse_frame(f)
        assert d["fcs_ok"] and d["udp_csum_ok"], "frame self-check failed"
        words.append(len(f))
        words.extend(int.from_bytes(f[i:i + 4].ljust(4, b"\0"), "big")
                     for i in range(0, len(f), 4))

    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "t63_lur_hostrd.hex").write_text(
        "".join(f"{w:08x}\n" for w in words), encoding="ascii")
    (OUT / "t63_lur_hostrd.vh").write_text(
        f"`define T63_WORDS {len(words)}\n", encoding="ascii")
    # 哈希 meta 两个字（与 T62 configure 的写入顺序一致：seed0/seed1）
    (OUT / "t63_lur_hostrd_meta.hex").write_text("00000000\n00000000\n", encoding="ascii")
    (OUT / "t63_lur_hostrd_img.hex").write_text(
        "".join(f"{w:08x}\n" for w in hash_image()), encoding="ascii")

    names = [n.decode() for n, _ in FILES]
    print(f"T63 vectors: {len(frames)} frame, {len(words)} words, lur={len(lur)}B")
    print(f"  names: {names}  lens(incl NUL)={[len(n)+1 for n,_ in FILES]}")


if __name__ == "__main__":
    main()
