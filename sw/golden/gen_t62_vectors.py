#!/usr/bin/env python3
"""T62: 615A LUR 顶层上传 → 逐文件取件 的 GMII 级向量（P05 集成测试）。

TB 扮演装载端（10.0.0.2:40100），通过 WRQ TARGET.LUR 和两个 DATA
块接收533B完整清单；f3..f8服务三个520B数据文件，f9先于f3注入，
检验控制末块重复。后续向量覆盖错误名称、部分中止、格式错误、替换
保护、恢复、错TID与管理复制碰撞。SN按实际注入顺序递增。

LUR 载荷格式（与 a615a_lur_rx 对齐，见 sim/tb/tb_t47_lur_rx.v build_valid2）：
  [declared_total:u32 BE][version:u16 BE][file_count:u16 BE]
  之后每个文件两段（各 = [len:u8][bytes...][NUL]）：
    name 段：文件名（含 NUL 计入 len）
    part 段：件号（含 NUL 计入 len）
  声明长度 = 实际字节数；version 取顶层当前明确绑定的0x4131。

布局（hex 词，大端）：
  [0]=帧数 [1]=len0 [bytes0...] [len1][bytes1...] ...
"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "sw" / "golden"))
from afdx_model import build_frame, parse_frame  # noqa: E402

OUT = ROOT / "sim" / "vec"

# 两个待取文件内容（与 TB 读回图案一致）
P512 = bytes((i * 7 + 0x21) & 0xFF for i in range(512))
P8 = bytes((i * 13 + 0x5A) & 0xFF for i in range(8))
P512_B = bytes((i * 11 + 0x93) & 0xFF for i in range(512))
P8_B = bytes((i * 17 + 0xC6) & 0xFF for i in range(8))


def lur_payload():
    """构造 LUR 清单载荷。"""
    body = bytearray()
    files = [(b"A.BIN", b"P"*254), (b"C.DE", b"Q"*254)]
    for name, part in files:
        body += bytes([len(name) + 1]) + name + b"\x00"
        body += bytes([len(part) + 1]) + part + b"\x00"
    head = bytearray()
    total = 4 + 2 + 2 + len(body)
    head += total.to_bytes(4, "big")
    head += (0x4131).to_bytes(2, "big")
    head += len(files).to_bytes(2, "big")
    return bytes(head + body)


def response(payload, sn, net=0, sport=40100):
    """下行响应帧：server 10.0.0.2:40100 -> 目标 10.0.0.1:0x3001，VLID 0x100。"""
    data, _ = build_frame(0x100, 0x172D, net + 1, net + 1,
                          "10.0.0.2", "10.0.0.1", sport, 0x3001,
                          payload, sn, ident=0, tos=0, ttl=255)
    return data


def main():
    lur = lur_payload()
    bad_lur = (len(lur)+1).to_bytes(4,'big') + lur[4:]
    payloads = [
        b"\x00\x02TARGET.LUR\x00octet\x00",  # f0: explicit control WRQ
        b"\x00\x03\x00\x01" + lur[:512],  # f1: full control block
        b"\x00\x03\x00\x02" + lur[512:],  # f2: short final control block
        bytes([0, 3, 0, 1]) + P512,   # f3: A.BIN DATA(1)
        bytes([0, 3, 0, 2]) + P8,     # f4: A.BIN DATA(2)
        bytes([0, 3, 0, 1]) + P512_B, # f5: C.DE DATA(1), distinct bytes
        bytes([0, 3, 0, 2]) + P8_B,   # f6: C.DE DATA(2)
        bytes([0, 3, 0, 1]) + P512,   # f7: restarted A.BIN DATA(1)
        bytes([0, 3, 0, 2]) + P8,     # f8: restarted A.BIN DATA(2)
        b"\x00\x03\x00\x02" + lur[512:],  # f9: final control retransmission
        b"\x00\x02OTHER.LUR\x00octet\x00", # f10: wrong endpoint name
        b"\x00\x02TARGET.LUR\x00octet\x00", # f11: start partial control
        b"\x00\x03\x00\x01" + lur[:512],  # f12: abort before final block
        b"\x00\x02TARGET.LUR\x00octet\x00", # f13: restart without reset
        b"\x00\x03\x00\x01" + bad_lur[:512], # f14: wrong declared file length
        b"\x00\x03\x00\x02" + bad_lur[512:], # f15: complete malformed file
        b"\x00\x02TARGET.LUR\x00octet\x00", # f16: cannot replace held result
        b"\x00\x02TARGET.LUR\x00octet\x00", # f17: restart after result ack
        b"\x00\x03\x00\x01" + lur[:512],  # f18: recovery control block1
        b"\x00\x03\x00\x02" + lur[512:],  # f19: recovery control block2
        b"\x00\x03\x00\x02" + lur[512:],  # f20: final DATA from wrong TID
        b"\x00\x02OTHER.LUR\x00octet\x00", # f21: abort during response copy
        b"\x00\x02TARGET.LUR\x00octet\x00", # f22: no stranded management source
    ]
    # f9 is injected immediately after f2. SN follows actual wire order,
    # rather than the storage index of each record.
    sns = [1,2,3,5,6,7,8,9,10,4]+list(range(11,24))
    assert len(sns)==len(payloads)
    frames = [response(p, sn, sport=40101 if i==20 else 40100)
              for i,(p,sn) in enumerate(zip(payloads,sns))]

    words = [len(frames)]
    for f in frames:
        d = parse_frame(f)
        assert d["fcs_ok"] and d["udp_csum_ok"], "frame self-check failed"
        words.append(len(f))
        words.extend(int.from_bytes(f[i:i + 4].ljust(4, b"\0"), "big")
                     for i in range(0, len(f), 4))

    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "t62_lur_top.hex").write_text(
        "".join(f"{w:08x}\n" for w in words), encoding="ascii")
    (OUT / "t62_lur_top.vh").write_text(
        f"`define T62_WORDS {len(words)}\n`define T62_FRAMES {len(frames)}\n"
        f"`define T62_LUR_BYTES {len(lur)}\n", encoding="ascii")
    (OUT / "t62_lur_expect.hex").write_text(
        f"lur_len {len(lur)}\nfiles 2\nname0 A.BIN\nname1 C.DE\n",
        encoding="ascii")
    print(f"T62 vectors: {len(frames)} frames, {len(words)} words, lur={len(lur)}B")


if __name__ == "__main__":
    main()
