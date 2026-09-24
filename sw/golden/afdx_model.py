#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""sw/golden/afdx_model.py — AFDX 帧级黄金模型（设计书 §6 的参考实现）

用途：T02~T05（发送路径）及 T03（FCS/校验和）的裁判。不读 RTL 常数；
帧格式以设计书 §6.1~§6.6 为唯一口径；BAG 判决复用根目录 tools_bag_model.py
（单一算法源，§8.2 判决式）。IC 的 PSN 判决供 T09 向量生成；RM 待 T10 补入。

自检：python sw/golden/afdx_model.py   （0 = 全过）
"""
import struct, sys, os, zlib

# ---------------- §6.1 帧常量 ----------------
ETH_HDR = 14          # DMAC6 + SMAC6 + EtherType2
IP_HDR  = 20
UDP_HDR = 8
SN_LEN  = 1
FCS_LEN = 4
PAYLOAD_MIN = 17      # A664P7/XAPP1130 图 3：UDP 数据区不足 17 B 时补 0~16 B pad（O-02）
FRAME_MIN = 60        # DMAC 起算、不含 FCS 的最小总长 = 42+17+1
FRAME_MAX = 1514      # DMAC 起算、不含 FCS 的最大总长（1518-4）
IFID_A, IFID_B = 1, 2 # SMAC 3 bit Interface ID：A=001, B=010（§6.2，O-03）
ET_IPV4 = 0x0800

# ---------------- CRC32（IEEE 802.3, reflected, init/xorout 0xFFFFFFFF） ----------------
def crc32(data):
    return zlib.crc32(bytes(data)) & 0xFFFFFFFF

# ---------------- 反码和（§6.5：32 位累加 + 折叠） ----------------
def ones_comp16(data):
    if len(data) % 2:
        data = bytes(data) + b"\x00"
    s = 0
    for i in range(0, len(data), 2):
        s += (data[i] << 8) | data[i+1]
    while s >> 16:
        s = (s & 0xFFFF) + (s >> 16)
    return (~s) & 0xFFFF

# ---------------- IPv4 首部（§6.3：固定无选项，DF=1，proto=17） ----------------
def ip_header(src_ip, dst_ip, total_len, ident, ttl=255, tos=0):
    """ip: 'IHHBBBBHHH' = ver_ihl,tos,total_len,ident,flags_frag,ttl,proto,csum,src,dst"""
    def b(ip):
        return tuple(int(x) for x in ip.split("."))
    hdr = struct.pack("!BBHHHBBH4s4s",
                      0x45, tos, total_len, ident & 0xFFFF,
                      0x4000, ttl, 17, 0,
                      bytes(b(src_ip)), bytes(b(dst_ip)))
    return hdr[:10] + struct.pack("!H", ones_comp16(hdr)) + hdr[12:]

# ---------------- UDP 首部（§6.4） ----------------
def udp_header(sport, dport, udp_len, seg, src_ip, dst_ip, csum_mode=1):
    """seg = UDP 数据 = payload（不含 pad/SN，O-02）；奇数长度补 0 到偶数只进校验和；csum_mode=0 置 0"""
    def b(ip):
        return tuple(int(x) for x in ip.split("."))
    pseudo = bytes(b(src_ip)) + bytes(b(dst_ip)) + struct.pack("!BBH", 0, 17, udp_len)
    u = struct.pack("!HHHH", sport, dport, udp_len, 0)
    body = u + bytes(seg)
    if len(body) % 2:
        body += b"\x00"
    cs = ones_comp16(pseudo + body) if csum_mode else 0
    return u[:6] + struct.pack("!H", cs)

# ---------------- 帧构建（§6.1/§6.2） ----------------
def dmac_of(vlid):
    return bytes([0x03, 0x00, 0x00, 0x00, (vlid >> 8) & 0xFF, vlid & 0xFF])

def smac_of(udi, ifid):
    """A664P7 / XAPP1130 图 5（O-03）：02:00:00 + UDI[15:8] + UDI[7:0] + {IFID[2:0], 5'b0}。
    A 网 ifid=1 → 末字节 0x20，B 网 ifid=2 → 0x40。"""
    return bytes([0x02, 0x00, 0x00, (udi >> 8) & 0xFF, udi & 0xFF, (ifid & 0x7) << 5])

def build_frame(vlid, udi, ifid, net_id, src_ip, dst_ip, sport, dport,
                payload, sn, ident=0, tos=0, ttl=255, fcs_mode=2, udp_csum_mode=1):
    """返回 (frame, fcs)。frame 含 FCS（fcs_mode>=1）或不含（fcs_mode=0）。
    参数 net_id 仅作兼容保留（1=A/2=B）；ifid 直接给 3 bit Interface ID（A=1，B=2）。
    帧布局（§6.1，O-02）：ETH14 IP20 UDP8 | payload L | pad P=max(0,17-L) | SN | FCS
      IP Total Length = 28 + L，UDP Length = 8 + L；pad 与 SN 不计入长度字段、不进 UDP 校验和。"""
    L = len(payload)
    assert 8 <= L <= 1471, "payload 长度须 8..1471（§6.1）"
    assert 1 <= sn <= 255, "SN 永不使用 0（§6.6）"
    ip_total = IP_HDR + UDP_HDR + L
    udp_len  = UDP_HDR + L
    core = dmac_of(vlid) + smac_of(udi, ifid) + struct.pack("!H", ET_IPV4) \
           + ip_header(src_ip, dst_ip, ip_total, ident, ttl, tos)
    seg = bytes(payload)                       # UDP 数据 = 载荷本身
    pad = max(0, PAYLOAD_MIN - L)              # 0~16 B，位于载荷与 SN 之间
    udp = udp_header(sport, dport, udp_len, seg, src_ip, dst_ip, udp_csum_mode)
    frame = core + udp + seg + b"\x00" * pad + bytes([sn])
    assert FRAME_MIN <= len(frame) <= FRAME_MAX
    if fcs_mode >= 1:
        f = crc32(frame)
        return frame + struct.pack("<I", f), f  # IEEE 802.3 线上低字节先发（mac_tx_if）
    return frame, None

# ---------------- 帧解析（RX 侧 golden） ----------------
def parse_frame(frame, check_fcs=True, udp_csum_mode=1):
    out = {}
    if check_fcs and len(frame) >= 4:
        body, fcs = frame[:-4], struct.unpack("<I", frame[-4:])[0]
        out["fcs_ok"] = (crc32(body) == fcs)
    else:
        body = frame
    out["vlid"]  = (body[4] << 8) | body[5]
    out["dmac_prefix_ok"] = body[:4] == b"\x03\x00\x00\x00"
    out["etype"] = struct.unpack("!H", body[12:14])[0]
    ver_ihl, tos, ip_total, ident, ff, ttl, proto, csum = struct.unpack("!BBHHHBBH", body[14:26])
    src_ip = ".".join(str(x) for x in body[26:30]); dst_ip = ".".join(str(x) for x in body[30:34])
    out.update(ver_ihl=ver_ihl, tos=tos, ip_total=ip_total, ident=ident,
               df=bool(ff & 0x4000), ttl=ttl, proto=proto, src_ip=src_ip, dst_ip=dst_ip)
    sport, dport, udp_len, ucs = struct.unpack("!HHHH", body[34:42])
    out.update(sport=sport, dport=dport, udp_len=udp_len)
    if udp_csum_mode:
        pseudo = body[26:34] + struct.pack("!BBH", 0, 17, udp_len)
        ubody = body[34:34+udp_len]
        if len(ubody) % 2:
            ubody += b"\x00"
        out["udp_csum_ok"] = (ones_comp16(pseudo + ubody) == 0)
    L = udp_len - UDP_HDR
    pad = max(0, PAYLOAD_MIN - L)
    out["payload"] = body[42:42+L]
    out["pad_zero"] = body[42+L:42+L+pad] == b"\x00" * pad
    out["sn"] = body[42+L+pad]                        # = 14 + Total Length + pad（§6.1）
    out["sn_pos_ok"] = (42 + L + pad) == len(body) - 1  # 亦须为 FCS 前 1 字节（§7.12 P2）
    out["ifid"] = body[11] >> 5
    out["udi"] = (body[9] << 8) | body[10]
    out["frame_len"] = len(body)
    return out

# ---------------- SN 规则（§6.6） ----------------
def sn_next(sn_cur):
    return 1 if sn_cur == 255 else sn_cur + 1

def sn_tx(sn_cur):
    return 1 if sn_cur == 0 else sn_cur

# ---------------- RX IC / PSN（§7.10；T09 黄金向量） ----------------
IC_OK, IC_RESET, IC_LOST_ONE = 0, 1, 2
IC_FIRST_ANY, IC_FIRST_FAIL, IC_OUT_OF_ORDER, IC_BAD_VL = 3, 4, 5, 6

def ic_decide(prev_psn, sn, first_any=False):
    """单网单 VL 判决，返回 (接纳?, 写回 PSN, 原因)。

    只处理已通过 FCS/IP/UDP 与 VL 查表的帧；未知 VL 在 RTL 由 BAD_VL
    拒绝，不调用本函数。每个网络/VL 的 prev_psn 由调用方分别维护。
    """
    if not (0 <= prev_psn <= 255 and 0 <= sn <= 255):
        raise ValueError("PSN 与 SN 必须是 0..255")
    if sn == 0:
        return True, 0, IC_RESET
    if prev_psn == 0:
        if sn == 1:
            return True, 1, IC_OK
        if first_any:
            return True, sn, IC_FIRST_ANY
        return False, 0, IC_FIRST_FAIL
    # 有效 SN 环 1..255；最多跨过一个缺失的 SN，不把 0 当环内值。
    if sn == (prev_psn % 255) + 1:
        return True, sn, IC_OK
    if sn == ((prev_psn + 1) % 255) + 1:
        return True, sn, IC_LOST_ONE
    return False, prev_psn, IC_OUT_OF_ORDER

# ---------------- BAG 判决（复用 §8.2 单一算法源） ----------------
def bag_metrics(n, frame_bytes, bag_us):
    here = os.path.dirname(os.path.abspath(__file__))
    for base in (os.path.abspath(os.path.join(here, "..", "..")), os.getcwd()):
        sys.path.insert(0, base)
    try:
        from tools_bag_model import metrics
        return metrics(n, frame_bytes, bag_us)
    except ImportError:
        u = n * frame_bytes * 8 / (bag_us * 1e-6 * 100e6)
        return {"util": u, "q20": int(round(u * 2**20)), "legal": u <= 1.0}

# ---------------- 自检 ----------------
def main():
    errs = 0
    def ck(cond, msg):
        nonlocal errs
        if cond: print("  [ok]", msg)
        else:
            print("  [err]", msg); errs += 1

    ck(crc32(b"123456789") == 0xCBF43926, "crc32(123456789)=0xCBF43926")

    f, c = build_frame(0x1000, 0x1234, IFID_A, 1, "10.0.0.1", "10.0.0.2",
                       49152, 49152, b"P" * 1471, 1, ident=7)
    ck(len(f) == 1518, "1471B 载荷帧含 FCS 总长 1518 (got %d)" % len(f))
    ck(f[6:12] == bytes([2,0,0,0x12,0x34,0x20]), "SMAC = 02:00:00:12:34:20（A 网，O-03）")
    fb, _ = build_frame(0x1000, 0x1234, IFID_B, 2, "10.0.0.1", "10.0.0.2", 49152, 49152, b"P" * 1471, 1, ident=7)
    ck(fb[11] == 0x40 and fb[:11] == f[:11] and fb[12:-4] == f[12:-4], "B 网仅 SMAC 第 6 字节 0x40 不同")
    f2, c2 = build_frame(1, 0x11, IFID_A, 1, "10.0.0.1", "10.0.0.2",
                         49152, 49152, b"Q" * 8, 1)
    ck(len(f2) == 64, "8B 载荷帧含 FCS 总长 64 (got %d)" % len(f2))
    p2 = parse_frame(f2)
    ck(p2["ip_total"] == 36 and p2["udp_len"] == 16, "L=8：Total Length 36 / UDP Length 16（不含 pad/SN）")
    ck(f2[42:50] == b"Q" * 8 and f2[50:59] == b"\x00" * 9 and f2[59] == 1, "L=8：payload → 9 B pad → SN → FCS（XAPP1130 图 3）")
    ck(p2["sn"] == 1 and p2["sn_pos_ok"] and p2["pad_zero"] and p2["udp_csum_ok"], "L=8 解析：SN 位置/零 pad/UDP 校验和")
    for Lx in (16, 17, 18):
        fx, _ = build_frame(1, 0x11, IFID_A, 1, "10.0.0.1", "10.0.0.2", 49152, 49152, b"R" * Lx, 5)
        ck(len(fx) - 4 == 42 + max(Lx, 17) + 1, "L=%d：帧长(不含 FCS)=%d" % (Lx, len(fx) - 4))

    p = parse_frame(f)
    ck(p["fcs_ok"] is True, "FCS 解析回环")
    ck(f[-4:] == c.to_bytes(4, "little") and zlib.crc32(f) == 0x2144DF1C,
       "FCS 线上低字节先发，完整帧 CRC 余数 0x2144DF1C")
    ck(p["vlid"] == 0x1000 and p["dmac_prefix_ok"], "DMAC/VLID 回环")
    ck(p["payload"] == b"P" * 1471 and p["sn"] == 1, "payload/SN 回环")
    ck(p["ip_total"] == 20+8+1471 and p["udp_len"] == 8+1471, "IP/UDP 长度字段（O-02：不含 SN）")
    ck(p["sn_pos_ok"] and p["ifid"] == IFID_A and p["udi"] == 0x1234, "SN 位置 = FCS 前 1 字节；SMAC 解析")
    ck(p["df"] and p["ttl"] == 255 and p["proto"] == 17, "DF/TTL/proto")
    ck(p["udp_csum_ok"] is True, "UDP 校验和回环")
    bad = bytearray(f); bad[-1] ^= 0xFF
    ck(parse_frame(bytes(bad))["fcs_ok"] is False, "FCS 错误检出")

    ck(sn_next(255) == 1 and sn_next(1) == 2 and sn_tx(0) == 1, "SN 规则（255→1，首帧 0→1）")
    ic_cases = [((0, 0, False), (True, 0, IC_RESET)),
                ((0, 2, False), (False, 0, IC_FIRST_FAIL)),
                ((0, 2, True), (True, 2, IC_FIRST_ANY)),
                ((1, 3, False), (True, 3, IC_LOST_ONE)),
                ((1, 4, False), (False, 1, IC_OUT_OF_ORDER)),
                ((254, 1, False), (True, 1, IC_LOST_ONE)),
                ((255, 1, False), (True, 1, IC_OK)),
                ((255, 2, False), (True, 2, IC_LOST_ONE))]
    ck(all(ic_decide(*inputs) == expected for inputs, expected in ic_cases),
       "RX IC 首帧/复位/丢一帧/254-255 回绕及拒绝不写回")

    m = bag_metrics(4, 1495, 1000.0)
    ck(m["legal"] is True and 0 < m["util"] < 1, "BAG 判决（4VL×1495B/1ms，util=%.4f）" % m["util"])
    m2 = bag_metrics(4096, 1495, 1000.0)
    ck(m2["legal"] is False, "BAG 超限判拒（4096VL）")

    print("AFDX MODEL %s: %d errors" % ("PASS" if errs == 0 else "FAIL", errs))
    return errs

if __name__ == "__main__":
    sys.exit(main())
