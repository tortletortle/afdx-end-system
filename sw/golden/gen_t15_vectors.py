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
from afdx_model import build_frame, ones_comp16, IFID_A, IFID_B

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

def frame(payload, sn, src_ip="10.0.0.1", sport=49152):
    body, _ = build_frame(0x0100, 0x1234, 1, 1,
                          src_ip, "224.0.0.1", sport, 5000,
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
    if inst is False:
        return o
    return o + bytes([0 if inst is True else inst & 0xFF])

def vb(grp, leaf, inst=True, val=b"\x05\x00"):
    return tlv(0x30, tlv(0x06, oid(grp, leaf, inst)) + val)

# Indexed VL objects use the final OID sub-identifier as a real VL index;
# keep this non-zero smoke set beside the encoder so future vector additions
# cannot silently regress to the old scalar-only instance 0 convention.
INDEXED_OIDS = tuple(oid(1, leaf, inst=5) for leaf in range(5, 10))
assert all(len(x) == 11 and x[-1] == 5 for x in INDEXED_OIDS)

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

def tftp_error(code):
    return bytes([0, 5, (code >> 8) & 0xFF, code & 0xFF]) + b"TFTP ERR\x00"

D1 = bytes((i * 7 + 0x21) & 0xFF for i in range(512))   # 满块：RFC1350 非末块
D2 = bytes(((i + 32) * 7 + 0x21) & 0xFF for i in range(8))
D512_2 = bytes((i * 11 + 0x63) & 0xFF for i in range(512))
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
    # RFC 1350 ACK 是 4 B UDP 载荷；Ethernet 最小帧填充由 build_frame
    # 放在 UDP 数据之后、AFDX SN 之前，不计入 UDP 长度或校验和。
    (8,  0, bytes([0, 4, 0, 1]),                     8, 0),          # ACK(1)
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
    # ---- indexed VL objects（非零 instance，覆盖 .5~.9 与 .5 SET）----
    (22, 1, snmp(GET,  0x00000080, [vb(1, 5, inst=5)]),              12, 0),
    (23, 1, snmp(GET,  0x00000081, [vb(1, 6, inst=5)]),              13, 0),
    (24, 1, snmp(NEXT, 0x00000082, [vb(1, 5, inst=5)]),              14, 0),
    (25, 1, snmp(SET,  0x00000083, [vb(1, 5, inst=5, val=tlv(0x02, ber_int(0x123456)))]), 15, 0),
    (26, 1, snmp(GET,  0x00000084, [vb(1, 9, inst=5)]),              16, 0),
    # ---- 核查 20260928 A01 顶层路径（上线 SN 接 B 段的 0..11 → 12, 13）----
    # 27: 原子性——VB1 可写 ctl:=0x5678，VB2 只读 uptime → readOnly(4)/idx 2，一个都不写
    (27, 1, snmp(SET,  0x00000085, [vb(1, 11, val=tlv(0x02, ber_int(0x5678))),
                                    vb(1, 2,  val=tlv(0x02, ber_int(5)))]),  12, 0),
    # 28: 两 VarBind 成功——BAG[5]:=0x000321 与 ctl:=0x0567 都须落到顶层
    (28, 1, snmp(SET,  0x00000086, [vb(1, 5, inst=5, val=tlv(0x02, ber_int(0x000321))),
                                    vb(1, 11, val=tlv(0x02, ber_int(0x0567)))]), 13, 0),
    # 29: BAG 侧原子性——VB1 BAG[5]:=0x000777，VB2 不存在的 leaf 99 → noSuchName(2)/idx 2，BAG 保持 0x000321
    (29, 1, snmp(SET,  0x00000087, [vb(1, 5, inst=5, val=tlv(0x02, ber_int(0x000777))),
                                    vb(1, 99, val=tlv(0x02, ber_int(1)))]),     14, 0),
    # 30..32: A02 顶层忙时——响应未取走时连发三个 GET：30 待取、31 暂存、32 整包拒绝并计数
    (30, 1, snmp(GET,  0x00000088, [vb(1, 11)]),                     15, 0),
    (31, 1, snmp(GET,  0x00000089, [vb(1, 11)]),                     16, 0),
    (32, 1, snmp(GET,  0x0000008A, [vb(1, 11)]),                     17, 0),
    # ---- step3 20260928：顶层卸载（T16 C8b），TFTP 上线 SN 接 9 → 10..12 ----
    # 33: RRQ "UPLOAD" → DATA(1) = D1（512 B，经 11 位 0xAC1A/0xAC27 读 516 B）
    (33, 0, tftp_rq(1, b"UPLOAD"),                 10, CRC_ALL),
    # 34: ACK(1)（4 B）→ DATA(2) = D2（8 B，末块）
    (34, 0, bytes([0, 4, 0, 1]),                    11, 0),
    # 35: ACK(2) → 卸载会话结束，不再有响应
    (35, 0, bytes([0, 4, 0, 2]),                    12, 0),
    # ---- 管理 TX 独立整帧 oracle：固定 MIB 标量 GET，避免动态计数值 ----
    (36, 1, snmp(GET,  0x00001234, [vb(1, 3)]),      1, 0),
    # ---- 顶层 TFTP 自动发送卸载数据：RX SN 连续，TX DATA SN=4/5 ----
    (37, 0, tftp_rq(1, b"UPLOAD"),                  3, 0),
    (38, 0, bytes([0, 4, 0, 1]),                     4, 0),
    # 39: 第二个 peer 的 WRQ；T25 在 TX 暂停时与 case0 同时排队，验证 peer 元数据隔离。
    (39, 0, tftp_rq(2, b"UPLOAD"),                  1, 0),
    # 40: ACK(2) closes the T37 multi-block unload after the final short DATA block.
    (40, 0, bytes([0, 4, 0, 2]),                     5, 0),
    # ---- T37/T40 network edge coverage; each stream has its own contiguous AFDX SNs ----
    (41, 0, tftp_data(1, D1),                         1, 0),  # foreign TID; source IP/port changed below
    (42, 0, tftp_data(1, D1),                         2, 0),  # original peer recovers
    (43, 0, tftp_data(1, D1),                         3, 0),  # duplicate DATA must not recommit bytes
    (44, 0, tftp_data(2, D2),                         4, CRC_ALL),
    (45, 0, tftp_rq(1, b"UPLOAD"),                    5, 0),
    (46, 0, bytes([0, 4, 0, 1]),                      6, 0),
    (47, 0, bytes([0, 4, 0, 2]),                      7, 0),
    (48, 0, tftp_rq(2, b"UPLOAD"),                    8, 0),
    (49, 0, tftp_data(1, D1),                         9, CRC_D1),
    (50, 0, tftp_data(2, b""),                       10, CRC_D1),  # zero-byte terminal block
    (51, 0, tftp_rq(1, b"UPLOAD"),                   11, 0),  # retry-exhaustion session
    (52, 0, tftp_data(2, D512_2),                      2, 0),  # T40 small configured load area
    (53, 0, tftp_data(3, b"\xE7"),                    3, 0),  # exact-capacity + 1 byte
]

def write_tftp_tx_expected():
    """独立生成 T25/T32 的完整应答帧：4B UDP ACK + pad + SN + FCS。"""
    words = [6]
    for block, sn in ((0, 1), (1, 2), (2, 3)):
        payload = bytes([0, 4, (block >> 8) & 0xFF, block & 0xFF])
        for ifid in (IFID_A, IFID_B):
            frame_bytes, _ = build_frame(
                0x0100, 0x172D, ifid, 1 if ifid == IFID_A else 2,
                "10.0.0.2", "10.0.0.1", 5000, 49152, payload, sn,
                ident=0, tos=0, ttl=255, fcs_mode=2, udp_csum_mode=1)
            words.append(len(frame_bytes))
            words.extend(int.from_bytes(frame_bytes[i:i+4].ljust(4, b"\x00"), "big")
                         for i in range(0, len(frame_bytes), 4))
    out = ROOT / "sim" / "vec" / "tftp_tx_expected.hex"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text("// generated independent full-frame TFTP TX expectations; count, then len + packed frame\n" +
                   "".join(f"{word:08x}\n" for word in words), encoding="ascii")

def write_tftp_error_expected():
    """Independent A/B frame oracle for network TFTP ERROR(5), ERROR(4), and ERROR(3)."""
    words = [6]
    cases = ((5, 2, "10.0.0.99", 40000),
             (4, 16, "10.0.0.1", 49152),
             (3, 4, "10.0.0.1", 49152))
    for code, sn, dst_ip, dport in cases:
        payload = tftp_error(code)
        for ifid in (IFID_A, IFID_B):
            frame_bytes, _ = build_frame(
                0x0100, 0x172D, ifid, 1 if ifid == IFID_A else 2,
                "10.0.0.2", dst_ip, 5000, dport, payload, sn,
                ident=0, tos=0, ttl=255, fcs_mode=2, udp_csum_mode=1)
            words.append(len(frame_bytes))
            words.extend(int.from_bytes(frame_bytes[i:i+4].ljust(4, b"\x00"), "big")
                         for i in range(0, len(frame_bytes), 4))
    out = ROOT / "sim" / "vec" / "tftp_error_expected.hex"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text("// generated independent full-frame TFTP ERROR expectations\n" +
                   "".join(f"{word:08x}\n" for word in words), encoding="ascii")

def write_tftp_unload_expected():
    """独立生成顶层 RRQ UPLOAD 的 DATA(1)/DATA(2) A/B 完整帧。"""
    words = [4]
    for block, payload, sn in ((1, D1, 4), (2, D2, 5)):
        response = tftp_data(block, payload)
        for ifid in (IFID_A, IFID_B):
            frame_bytes, _ = build_frame(
                0x0100, 0x172D, ifid, 1 if ifid == IFID_A else 2,
                "10.0.0.2", "10.0.0.1", 5000, 49152, response, sn,
                ident=0, tos=0, ttl=255, fcs_mode=2, udp_csum_mode=1)
            words.append(len(frame_bytes))
            words.extend(int.from_bytes(frame_bytes[i:i+4].ljust(4, b"\x00"), "big")
                         for i in range(0, len(frame_bytes), 4))
    out = ROOT / "sim" / "vec" / "tftp_unload_expected.hex"
    out.write_text("// generated independent full-frame RRQ UPLOAD DATA expectations\n" +
                   "".join(f"{word:08x}\n" for word in words), encoding="ascii")

def write_tftp_peer_expected():
    """独立生成两个待发 ACK(0)，其响应分别回到各自的 peer IP/TID。"""
    payload = bytes([0, 4, 0, 0])
    words = [4]
    for dst_ip, dport, sn in (("10.0.0.1", 49152, 1), ("10.0.0.99", 40000, 2)):
        for ifid in (IFID_A, IFID_B):
            frame_bytes, _ = build_frame(
                0x0100, 0x172D, ifid, 1 if ifid == IFID_A else 2,
                "10.0.0.2", dst_ip, 5000, dport, payload, sn,
                ident=0, tos=0, ttl=255, fcs_mode=2, udp_csum_mode=1)
            words.append(len(frame_bytes))
            words.extend(int.from_bytes(frame_bytes[i:i+4].ljust(4, b"\x00"), "big")
                         for i in range(0, len(frame_bytes), 4))
    out = ROOT / "sim" / "vec" / "tftp_peer_expected.hex"
    out.write_text("// generated independent full-frame peer-isolation ACK expectations\n" +
                   "".join(f"{word:08x}\n" for word in words), encoding="ascii")

def write_snmp_tx_expected():
    """固定 GET .1.3 的完整 A/B 帧；默认 NUM_TX_VL=128，独立编码 BER。"""
    response = snmp(0xA2, 0x00001234,
                    [vb(1, 3, val=tlv(0x02, ber_int(128)))])
    words = [2]
    for ifid in (IFID_A, IFID_B):
        frame_bytes, _ = build_frame(
            0x0100, 0x172D, ifid, 1 if ifid == IFID_A else 2,
            "10.0.0.2", "10.0.0.1", 5000, 49152, response, 1,
            ident=0, tos=0, ttl=255, fcs_mode=2, udp_csum_mode=1)
        words.append(len(frame_bytes))
        words.extend(int.from_bytes(frame_bytes[i:i+4].ljust(4, b"\x00"), "big")
                     for i in range(0, len(frame_bytes), 4))
    out = ROOT / "sim" / "vec" / "snmp_tx_expected.hex"
    out.write_text("// generated independent SNMP GET .1.3 full-frame expectations; count, then len + packed frame\n" +
                   "".join(f"{word:08x}\n" for word in words), encoding="ascii")

def main():
    write_tftp_tx_expected()
    write_tftp_error_expected()
    write_tftp_unload_expected()
    write_tftp_peer_expected()
    write_snmp_tx_expected()
    words = [len(cases)]
    maxb = 0
    for cid, svc, payload, sn, aux in cases:
        assert len(payload) >= 1, "空载荷"
        src_ip, sport = ("10.0.0.99", 40000) if cid in (39, 41) else ("10.0.0.1", 49152)
        data = frame(payload, sn, src_ip=src_ip, sport=sport)
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
