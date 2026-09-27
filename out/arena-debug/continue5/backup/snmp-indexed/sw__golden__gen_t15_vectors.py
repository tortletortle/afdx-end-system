#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""T15/T16 管理面测试帧：真实 SAP 帧（ETH/IP/UDP + AFDX SN + 线序 FCS）携带
SNMP v1/v2c BER PDU 与 ARINC-615A TFTP 报文。

复用 sw/golden/afdx_model.build_frame 构帧、zlib.crc32 独立按线序追加 FCS，
与 gen_t08a_vectors.py 同一套黄金模型，因此 RX 完帧原始余数仍为 0xDEBB20E3。

向量文件布局（sim/vec/t15_mgmt.hex）：
  word0                = 用例数
  每个用例 3 个头字 + 帧字：
    hdr   = (case_id<<24) | (svc<<20) | (sap_port<<16) | 帧字节数
            svc: 0 = TFTP, 1 = SNMP
    plen  = UDP 载荷字节数（= 描述符 plen）
    aux   = 用例相关的期望值（TFTP 载荷 CRC32 / SNMP 期望响应长度，0 表示不用）
    帧字   = 大端打包，末字右侧补 0
"""
import pathlib, sys, zlib
from afdx_model import build_frame, ones_comp16

ROOT = pathlib.Path(__file__).resolve().parents[2]
OUT = ROOT / "sim" / "vec" / "t15_mgmt.hex"

def crc_raw(data):
    s = 0xFFFF_FFFF
    for b in data:
        s ^= b
        for _ in range(8):
            s = (s >> 1) ^ (0xEDB8_8320 if s & 1 else 0)
    return s

def fcs(body):
    frame = bytes(body) + zlib.crc32(body).to_bytes(4, "little")
    assert crc_raw(frame) == 0xDEBB_20E3
    return frame

def frame(payload, sn):
    body, _ = build_frame(0x0100, 0x1234, 1, 1,
                          "10.0.0.1", "224.0.0.1", 49152, 5000,
                          bytes(payload), 1, ident=7, fcs_mode=0, udp_csum_mode=1)
    body = body[:-1] + bytes([sn & 0xFF])
    assert ones_comp16(body[14:34]) == 0
    assert ones_comp16(body[26:34] + b"\x00\x11" + body[38:40] + body[34:42+len(payload)]) == 0
    return fcs(body)

# ---------------- BER 编码器 ----------------
def tlv(t, v):
    v = bytes(v)
    if len(v) < 128:
        return bytes([t, len(v)]) + v
    assert len(v) < 256, "本代理只支持 0x81 单字节长式"
    return bytes([t, 0x81, len(v)]) + v

def ber_int(v):
    if v == 0:
        return b"\x00"
    out = []
    x = v
    while x:
        out.insert(0, x & 0xFF)
        x >>= 8
    if out[0] & 0x80:
        out.insert(0, 0)
    return bytes(out)

PFX = bytes([0x2B, 0x06, 0x01, 0x04, 0x01, 0xA2, 0x5C, 0x01])

def oid(grp, leaf, inst=True):
    o = PFX + bytes([grp, leaf])
    return o + b"\x00" if inst else o

def vb(grp, leaf, inst=True, val=b"\x05\x00"):
    return tlv(0x30, tlv(0x06, oid(grp, leaf, inst)) + val)

def snmp(pdu, reqid, vbs, community=b"public", ver=0):
    p = tlv(0x02, ber_int(reqid)) + tlv(0x02, b"\x00") + tlv(0x02, b"\x00") + \
        tlv(0x30, b"".join(vbs))
    return tlv(0x30, tlv(0x02, ber_int(ver)) + tlv(0x04, community) + tlv(pdu, p))

GET, NEXT, SET = 0xA0, 0xA1, 0xA3

# ---------------- TFTP 报文 ----------------
def tftp_rq(op, name, mode=b"octet"):
    return bytes([0, op]) + name + b"\x00" + mode + b"\x00"

def tftp_data(blk, payload):
    return bytes([0, 3, (blk >> 8) & 0xFF, blk & 0xFF]) + bytes(payload)

D1 = bytes((i * 7 + 0x21) & 0xFF for i in range(512))   # 满块：RFC1350 非末块
D2 = bytes(((i + 32) * 7 + 0x21) & 0xFF for i in range(8))
CRC_ALL = zlib.crc32(D1 + D2) & 0xFFFF_FFFF
CRC_D1  = zlib.crc32(D1) & 0xFFFF_FFFF

# (case_id, svc, payload, sn, aux)
cases = [
    # ---- TFTP（svc=0），SN 从 0 递增 ----
    (0,  0, tftp_rq(2, b"UPLOAD"),                 0, 0),
    (1,  0, tftp_data(1, D1),                      1, CRC_D1),
    (2,  0, tftp_data(2, D2),                      2, CRC_ALL),
    (3,  0, tftp_data(1, D1),                      3, 0),          # 重复块
    (4,  0, tftp_data(9, D2),                      4, 0),          # 块号错
    (5,  0, tftp_rq(2, b"NOPE"),                   5, 0),          # 文件名不在白名单
    (6,  0, tftp_rq(2, b"UPLOAD", b"netascii"),    6, 0),          # mode 非 octet
    (7,  0, tftp_rq(1, b"STATUS"),                 7, 0),          # RRQ 状态文件
    # AFDX §6.1 要求 UDP 载荷 >= 8 B，裸 4 B 的 TFTP ACK 不能单独上线，
    # 这里补零到 8 B；引擎对 ACK/ERROR 只取前 4 B，尾部补零被忽略。
    (8,  0, bytes([0, 4, 0, 1]) + b"\x00" * 4,      8, 0),          # ACK(1)
    (9,  0, bytes([0, 6, 0, 0, 0, 0]) + b"\x00" * 2, 9, 0),         # OACK → 非法操作
    # ---- SNMP（svc=1），SN 从 0 递增 ----
    (10, 1, snmp(GET,  0x11223344, [vb(1, 2)]),                      0, 0),
    (11, 1, snmp(NEXT, 0x00000055, [vb(1, 13)]),                     1, 0),
    (12, 1, snmp(SET,  0x0000A5A5, [vb(1, 11, val=tlv(0x02, ber_int(0x1234)))]), 2, 0),
    (13, 1, snmp(GET,  0x0000A5A6, [vb(1, 11)]),                     3, 0),
    (14, 1, snmp(GET,  0x00000077, [vb(1, 99)]),                     4, 0),
    (15, 1, snmp(SET,  0x00000078, [vb(1, 12, val=tlv(0x02, ber_int(9)))]), 5, 0),
    (16, 1, snmp(GET,  0x00000079, [vb(1, 2)], community=b"secret"), 6, 0),
    (17, 1, snmp(GET,  0x0000007A, [vb(2, 4), vb(2, 7)]),            7, 0),
    (18, 1, snmp(GET,  0x0000007B, [vb(1, 1)]),                      8, 0),
    (19, 1, snmp(SET,  0x0000007C, [vb(1, 11, val=tlv(0x04, b"xy"))]), 9, 0),
    (20, 1, snmp(GET,  0x0000007D, [vb(1, 3), vb(1, 4), vb(1, 13)]), 10, 0),
    (21, 1, snmp(NEXT, 0x0000007E, [vb(2, 47)]),                     11, 0),  # 走到表尾
]

def main():
    words = [len(cases)]
    maxb = 0
    for cid, svc, payload, sn, aux in cases:
        assert len(payload) >= 1, "空载荷"
        data = frame(payload, sn)
        maxb = max(maxb, len(data))
        words += [(cid << 24) | (svc << 20) | (5 << 16) | len(data), len(payload), aux]
        words += [int.from_bytes(data[i:i+4].ljust(4, b"\x00"), "big")
                  for i in range(0, len(data), 4)]
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text("// T15/T16 generated by sw/golden/gen_t15_vectors.py; "
                   "word0=count; per case: hdr(id/svc/port/len) + plen + aux\n" +
                   "".join(f"{w:08x}\n" for w in words), encoding="ascii")
    print(f"T15/T16 mgmt vectors: {len(cases)} cases, {len(words)} words, "
          f"max {maxb} B, crcD1={CRC_D1:08X} crcAll={CRC_ALL:08X}")

if __name__ == "__main__":
    main()
