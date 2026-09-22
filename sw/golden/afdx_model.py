#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""sw/golden/afdx_model.py — AFDX 帧级黄金模型（设计书 §6 的参考实现）

用途：T02~T05（发送路径）及 T03（FCS/校验和）的裁判。不读 RTL 常数；
帧格式以设计书 §6.1~§6.6 为唯一口径；BAG 判决复用根目录 tools_bag_model.py
（单一算法源，§8.2 判决式）。IC/RM 判决模型第 4 周（T09/T10 前）补入。

自检：python sw/golden/afdx_model.py   （0 = 全过）
"""
import struct, sys, os, zlib

# ---------------- §6.1 帧常量 ----------------
ETH_HDR = 14          # DMAC6 + SMAC6 + EtherType2
IP_HDR  = 20
UDP_HDR = 8
SN_LEN  = 1
FCS_LEN = 4
FRAME_MIN = 60        # DMAC 起算、不含 FCS 的最小总长（§6.1 填充约束）
FRAME_MAX = 1514      # DMAC 起算、不含 FCS 的最大总长（1518-4）
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
    """seg = UDP 载荷（payload + SN + pad 至偶数）；csum_mode=0 置 0"""
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

def smac_of(udi, ifid, net_id):
    """02 00 00 UDI (IFID[3:0]<<4|net_id) 00；MAC 固定 6 字节（§6.1）。
    注：设计书 §6.2 文字“末 2 字节 0”按 6 字节 MAC 应为“末 1 字节 0”，已记问题清单。"""
    return bytes([0x02, 0x00, 0x00, udi & 0xFF, ((ifid & 0xF) << 4) | (net_id & 0xF), 0x00])

def build_frame(vlid, udi, ifid, net_id, src_ip, dst_ip, sport, dport,
                payload, sn, ident=0, tos=0, ttl=255, fcs_mode=2, udp_csum_mode=1):
    """返回 (frame, fcs)。frame 含 FCS（fcs_mode>=1）或不含（fcs_mode=0）。"""
    L = len(payload)
    assert 8 <= L <= 1471, "payload 长度须 8..1471（§6.1）"
    assert 1 <= sn <= 255, "SN 永不使用 0（§6.6）"
    ip_total = IP_HDR + UDP_HDR + L + SN_LEN
    udp_len  = UDP_HDR + L + SN_LEN
    core = dmac_of(vlid) + smac_of(udi, ifid, net_id) + struct.pack("!H", ET_IPV4) \
           + ip_header(src_ip, dst_ip, ip_total, ident, ttl, tos)
    seg = b""  # UDP 载荷 = payload + SN（+ 偶数 pad 在校验和域内，pad 在帧内补足）
    seg = bytes(payload) + bytes([sn])
    # pad 至 FRAME_MIN（不含 FCS）；pad 计入 UDP 校验和域（§6.5：零填充到偶数字节——
    # 帧级 pad 在 SN 之后，校验和域 = UDP 首..SN + 偶数补齐；此处 pad 为 0 字节）
    pad = max(0, FRAME_MIN - (ETH_HDR + IP_HDR + UDP_HDR + L + SN_LEN))
    udp = udp_header(sport, dport, udp_len, seg, src_ip, dst_ip, udp_csum_mode)
    frame = core + udp + seg + b"\x00" * pad
    assert FRAME_MIN <= len(frame) <= FRAME_MAX
    if fcs_mode >= 1:
        f = crc32(frame)
        return frame + struct.pack("!I", f), f
    return frame, None

# ---------------- 帧解析（RX 侧 golden） ----------------
def parse_frame(frame, check_fcs=True, udp_csum_mode=1):
    out = {}
    if check_fcs and len(frame) >= 4:
        body, fcs = frame[:-4], struct.unpack("!I", frame[-4:])[0]
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
    out["payload"] = body[42:42+udp_len-UDP_HDR-SN_LEN]
    out["sn"] = body[42+udp_len-UDP_HDR-SN_LEN]
    out["frame_len"] = len(body)
    return out

# ---------------- SN 规则（§6.6） ----------------
def sn_next(sn_cur):
    return 1 if sn_cur == 255 else sn_cur + 1

def sn_tx(sn_cur):
    return 1 if sn_cur == 0 else sn_cur

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

    f, c = build_frame(0x1000, 0x11, 0x0, 1, "10.0.0.1", "10.0.0.2",
                       49152, 49152, b"P" * 1471, 1, ident=7)
    ck(len(f) == 1518, "1471B 载荷帧含 FCS 总长 1518 (got %d)" % len(f))
    f2, c2 = build_frame(1, 0x11, 0x0, 1, "10.0.0.1", "10.0.0.2",
                         49152, 49152, b"Q" * 8, 1)
    ck(len(f2) == 64, "8B 载荷帧含 FCS 总长 64 (got %d)" % len(f2))

    p = parse_frame(f)
    ck(p["fcs_ok"] is True, "FCS 解析回环")
    ck(p["vlid"] == 0x1000 and p["dmac_prefix_ok"], "DMAC/VLID 回环")
    ck(p["payload"] == b"P" * 1471 and p["sn"] == 1, "payload/SN 回环")
    ck(p["ip_total"] == 20+8+1471+1 and p["udp_len"] == 8+1471+1, "IP/UDP 长度字段")
    ck(p["df"] and p["ttl"] == 255 and p["proto"] == 17, "DF/TTL/proto")
    ck(p["udp_csum_ok"] is True, "UDP 校验和回环")
    bad = bytearray(f); bad[-1] ^= 0xFF
    ck(parse_frame(bytes(bad))["fcs_ok"] is False, "FCS 错误检出")

    ck(sn_next(255) == 1 and sn_next(1) == 2 and sn_tx(0) == 1, "SN 规则（255→1，首帧 0→1）")

    m = bag_metrics(4, 1495, 1000.0)
    ck(m["legal"] is True and 0 < m["util"] < 1, "BAG 判决（4VL×1495B/1ms，util=%.4f）" % m["util"])
    m2 = bag_metrics(4096, 1495, 1000.0)
    ck(m2["legal"] is False, "BAG 超限判拒（4096VL）")

    print("AFDX MODEL %s: %d errors" % ("PASS" if errs == 0 else "FAIL", errs))
    return errs

if __name__ == "__main__":
    sys.exit(main())
