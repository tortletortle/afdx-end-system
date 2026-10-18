#!/usr/bin/env python3
"""Independent short-fragment Ethernet minimum-length vectors for T79."""
import struct
import zlib
from pathlib import Path

from afdx_model import dmac_of, smac_of

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "sim" / "vec" / "t79_rx_frag_minlen.hex"
SRC_IP = bytes((10, 0, 0, 1))
DST_IP = bytes((224, 0, 0, 1))
APP = bytes((i * 13 + 0x53) & 0xFF for i in range(41))


def checksum(data):
    if len(data) & 1:
        data += b"\0"
    acc = sum((data[i] << 8) | data[i + 1] for i in range(0, len(data), 2))
    while acc >> 16:
        acc = (acc & 0xFFFF) + (acc >> 16)
    return (~acc) & 0xFFFF


def udp_datagram(app):
    udp_len = 8 + len(app)
    pseudo = SRC_IP + DST_IP + struct.pack("!BBH", 0, 17, udp_len)
    udp0 = struct.pack("!HHHH", 49152, 5000, udp_len, 0)
    csum = checksum(pseudo + udp0 + app)
    return struct.pack("!HHHH", 49152, 5000, udp_len, csum) + app


UDP48 = udp_datagram(APP[:40])


def ip_header(ip_payload, ident, mf, offset):
    assert offset % 8 == 0
    flags_offset = (0x2000 if mf else 0) | (offset // 8)
    hdr = struct.pack("!BBHHHBBH4s4s", 0x45, 0, 20 + len(ip_payload), ident,
                      flags_offset, 64, 17, 0, SRC_IP, DST_IP)
    return hdr[:10] + struct.pack("!H", checksum(hdr)) + hdr[12:]


def frame(ip_payload, mf, offset, sn, pad_len):
    body = (dmac_of(0x0100) + smac_of(0x1234, 1) + struct.pack("!H", 0x0800)
            + ip_header(ip_payload, 0x7910 + offset, mf, offset) + ip_payload
            + bytes(pad_len) + bytes((sn,)))
    return body + struct.pack("<I", zlib.crc32(body) & 0xFFFFFFFF)


cases = []


def add(name, pkt, expected_drop, expected_plen, first, offset):
    assert len(pkt) in (63, 64), (name, len(pkt))
    assert zlib.crc32(pkt[:-4]) & 0xFFFFFFFF == int.from_bytes(pkt[-4:], "little")
    cases.append((name, pkt, expected_drop, expected_plen, 1, first, offset,
                  int(bool(pkt[20] & 0x20))))


# First fragment: its IP payload contains the 8-byte UDP header. Eight app
# bytes therefore need nine padding bytes to reach a 64-octet MAC frame.
first8 = UDP48[:8] + APP[:8]
add("first8-pad9", frame(first8, True, 0, 1, 9), 0, 8, 1, 0)

# The short legal final fragment carries 24 bytes, so it needs one pad byte.
add("last24-pad1", frame(APP[16:40], False, 24, 2, 1), 0, 24, 0, 3)

# 25 later-fragment bytes already reach the minimum and need no padding.
add("last25-no-pad", frame(APP[16:41], False, 24, 3, 0), 0, 25, 0, 3)

# Negative control: correct checksums but one octet below minimum frame size.
add("last24-no-pad-reject", frame(APP[16:40], False, 24, 4, 0), 0x10, 24, 0, 3)


def main():
    words = [len(cases)]
    for _, pkt, reason, plen, is_frag, first, offset, mf in cases:
        words.extend((len(pkt), reason, plen, (is_frag << 2) | (first << 1) | mf, offset))
        words.extend(int.from_bytes(pkt[i:i + 4].ljust(4, b"\0"), "big")
                     for i in range(0, len(pkt), 4))
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text("// T79 generated independently; per case: len/reason/plen/flags/offset, then frame words\n"
                   + "".join(f"{word:08x}\n" for word in words), encoding="ascii")
    print("T79 GOLDEN PASS: first-fragment and later-fragment minimum-length boundaries; short-frame negative control")


if __name__ == "__main__":
    main()
