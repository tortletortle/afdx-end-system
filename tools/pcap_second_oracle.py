#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""第二观察者：不读 afdx_model / 不读 TB 期望值。

把线上字节写成 pcap，再用标准以太网 CRC、RFC 791/768 字段核对。
不能替代 T00–T22；只证明发出的帧能被独立解码。无 scapy/tshark 时用标准库。
"""
from __future__ import annotations
import argparse, struct, sys, zlib
from pathlib import Path

RESIDUE = 0x2144DF1C  # IEEE 802.3 / zlib.crc32 含 FCS 的好帧残数


def write_pcap(path: Path, frames: list[bytes], ts0: float = 0.0) -> None:
    # LINKTYPE_ETHERNET = 1
    gh = struct.pack("<IHHiIII", 0xA1B2C3D4, 2, 4, 0, 0, 65535, 1)
    body = [gh]
    for i, fr in enumerate(frames):
        usec = int((ts0 + i * 0.001) * 1e6)
        sec, uc = divmod(usec, 1_000_000)
        body.append(struct.pack("<IIII", sec, uc, len(fr), len(fr)))
        body.append(fr)
    path.write_bytes(b"".join(body))


def ip_checksum(hdr: bytes) -> int:
    if len(hdr) % 2:
        hdr += b"\x00"
    s = 0
    for i in range(0, len(hdr), 2):
        s += (hdr[i] << 8) | hdr[i + 1]
    while s >> 16:
        s = (s & 0xFFFF) + (s >> 16)
    return (~s) & 0xFFFF


def decode_afdx_eth(frame: bytes, name: str) -> list[str]:
    err = []
    if len(frame) < 64 or len(frame) > 1518:
        err.append("%s 帧长 %d 不在 64..1518" % (name, len(frame)))
        return err
    if zlib.crc32(frame) & 0xFFFFFFFF != RESIDUE:
        err.append("%s FCS 残数不是 0x2144DF1C（独立 zlib.crc32）" % name)
    body, fcs = frame[:-4], frame[-4:]
    da, sa, et = body[0:6], body[6:12], body[12:14]
    if et != b"\x08\x00":
        err.append("%s EtherType=%s 不是 IPv4" % (name, et.hex()))
        return err
    ip = body[14:]
    vihl, proto = ip[0], ip[9]
    ihl = (vihl & 0x0F) * 4
    if vihl != 0x45:
        err.append("%s IPv4 ver/IHL=%02x" % (name, vihl))
    if proto != 17:
        err.append("%s protocol=%d 不是 UDP" % (name, proto))
    tot = (ip[2] << 8) | ip[3]
    pad = len(frame) - 14 - tot - 1 - 4
    if pad < 0:
        err.append("%s IP tot=%d 与帧长 %d 对不上" % (name, tot, len(frame)))
    ip_hdr = bytearray(ip[:ihl])
    saved = (ip_hdr[10] << 8) | ip_hdr[11]
    ip_hdr[10] = ip_hdr[11] = 0
    calc = ip_checksum(bytes(ip_hdr))
    if calc != saved:
        err.append("%s IPv4 checksum 线=%04x 算=%04x" % (name, saved, calc))
    udp = ip[ihl:]
    ulen = (udp[4] << 8) | udp[5]
    sn = body[-1]
    payload = udp[8:ulen]
    # pad then SN then FCS already stripped from body[-1]==SN
    if ulen < 8 or ulen > len(udp) - 1:
        # udp region in body includes pad+SN after UDP length
        if ulen < 8:
            err.append("%s UDP Length=%d" % (name, ulen))
    vlid = (da[4] << 8) | da[5]
    print("%s len=%d pad=%d DA=%s SA=%s VLID=0x%04x IPtot=%d UDPlen=%d SN=%d payload=%d FCS=%s"
          % (name, len(frame), pad, da.hex(), sa.hex(), vlid, tot, ulen, sn, max(0, ulen-8), fcs.hex()))
    return err


def load_hex(path: Path) -> bytes:
    text = path.read_text(encoding="utf-8", errors="replace")
    hs = "".join(c for c in text if c in "0123456789abcdefABCDEF")
    if len(hs) % 2:
        raise ValueError("odd hex in %s" % path)
    return bytes.fromhex(hs)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("hex", nargs="+", help="每文件一帧十六进制（可含空白）")
    ap.add_argument("-o", "--pcap", default="sim/out/second_oracle.pcap")
    args = ap.parse_args()
    frames = []
    errs = []
    for i, p in enumerate(args.hex):
        path = Path(p)
        fr = load_hex(path)
        frames.append(fr)
        errs.extend(decode_afdx_eth(fr, path.name))
    out = Path(args.pcap)
    out.parent.mkdir(parents=True, exist_ok=True)
    write_pcap(out, frames)
    print("pcap %s  %d 帧  %d B" % (out.as_posix(), len(frames), out.stat().st_size))
    if errs:
        for e in errs:
            print("FAIL", e)
        return 1
    print("SECOND ORACLE PASS（独立 FCS/IPv4；不是 T00–T22，不是 Wireshark 插件）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
