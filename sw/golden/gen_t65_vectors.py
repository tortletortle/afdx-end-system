#!/usr/bin/env python3
"""Generate independent T65 metadata-overlap GMII frames and verify them."""
import struct
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
VEC = ROOT / "sim" / "vec"
SRC_IP = bytes((10, 0, 0, 153))
DST_IP = bytes((10, 0, 0, 2))
UDP_SPORT = 12345


def fold16(data: bytes) -> int:
    if len(data) & 1:
        data += b"\0"
    acc = sum((data[i] << 8) | data[i + 1]
              for i in range(0, len(data), 2))
    while acc >> 16:
        acc = (acc & 0xFFFF) + (acc >> 16)
    return acc


def checksum(data: bytes) -> int:
    return (~fold16(data)) & 0xFFFF


def app5(n: int) -> bytes:
    return bytes(((i * 7 + (i // 8) * 13 + 0x5A) & 0xFF) for i in range(n))


def app6(n: int) -> bytes:
    return bytes(((i * 19 + 0xA7 + (i // 3) * 5) & 0xFF) for i in range(n))


def udp_datagram(dport: int, app: bytes) -> bytes:
    length = 8 + len(app)
    pseudo = SRC_IP + DST_IP + struct.pack("!BBH", 0, 17, length)
    header_zero = struct.pack("!HHHH", UDP_SPORT, dport, length, 0)
    csum = checksum(pseudo + header_zero + app) or 0xFFFF
    datagram = struct.pack("!HHHH", UDP_SPORT, dport, length, csum) + app
    assert fold16(pseudo + datagram) == 0xFFFF
    return datagram


def ip_header(total_len: int, ident: int, mf: bool, offset_bytes: int) -> bytes:
    assert offset_bytes % 8 == 0
    flags_offset = (0x2000 if mf else 0) | (offset_bytes // 8)
    h0 = struct.pack("!BBHHHBBH4s4s", 0x45, 0, total_len, ident,
                     flags_offset, 64, 17, 0, SRC_IP, DST_IP)
    return h0[:10] + struct.pack("!H", checksum(h0)) + h0[12:]


def ethernet_frame(vlid: int, udi: int, ident: int, mf: bool,
                   offset: int, ip_payload: bytes, sn: int) -> bytes:
    dmac = bytes((0x03, 0, 0, 0, (vlid >> 8) & 0xFF, vlid & 0xFF))
    smac = bytes((0x02, 0, 0, (udi >> 8) & 0xFF, udi & 0xFF, 0x20))
    ih = ip_header(20 + len(ip_payload), ident, mf, offset)
    core = dmac + smac + struct.pack("!H", 0x0800) + ih + ip_payload
    pad_len = max(0, 60 - (len(core) + 1))
    no_fcs = core + bytes(pad_len) + bytes((sn,))
    return no_fcs + struct.pack("<I", zlib.crc32(no_fcs) & 0xFFFFFFFF)


def make_t65_frames():
    dg5 = udp_datagram(5000, app5(636))
    assert len(dg5) == 644
    vl5_first = ethernet_frame(5, 5, 0x6505, True, 0, dg5[:608], 1)
    vl5_last = ethernet_frame(5, 5, 0x6505, False, 608, dg5[608:], 2)
    vl6 = ethernet_frame(6, 6, 0x6606, False, 0,
                         udp_datagram(5001, app6(12)), 1)
    frames = [vl5_first, vl5_last, vl6]
    assert verify_vl5(frames[:2], dg5) == app5(636)
    assert verify_single(frames[2], 6, 5001) == app6(12)
    return frames


def verify_one_frame(frame: bytes):
    assert len(frame) >= 64
    assert (zlib.crc32(frame[:-4]) & 0xFFFFFFFF) == int.from_bytes(frame[-4:], "little")
    assert frame[12:14] == b"\x08\x00"
    ip = frame[14:34]
    assert checksum(ip) == 0
    total_len = int.from_bytes(ip[2:4], "big")
    assert len(frame) == max(64, 14 + total_len + 1 + 4)
    pad_len = max(0, 60 - (14 + total_len + 1))
    assert frame[14 + total_len:14 + total_len + pad_len] == bytes(pad_len)
    assert frame[14 + total_len + pad_len] != 0
    ff = int.from_bytes(ip[6:8], "big")
    offset = (ff & 0x1FFF) * 8
    mf = bool(ff & 0x2000)
    data = frame[34:14 + total_len]
    if mf:
        assert len(data) % 8 == 0
    return frame[0:6], frame[6:12], offset, mf, data


def verify_vl5(frames, expected_udp):
    pieces = sorted((verify_one_frame(f) for f in frames), key=lambda p: p[2])
    cursor, assembled = 0, bytearray()
    for dmac, smac, offset, mf, part in pieces:
        assert dmac == b"\x03\x00\x00\x00\x00\x05"
        assert smac == bytes((2, 0, 0, 0, 5, 0x20))
        assert offset == cursor
        assembled.extend(part)
        cursor += len(part)
        if offset == 0:
            assert mf and len(part) == 608
        else:
            assert offset == 608 and not mf and len(part) == 36
    assembled = bytes(assembled)
    assert assembled == expected_udp
    udp_len = int.from_bytes(assembled[4:6], "big")
    pseudo = SRC_IP + DST_IP + struct.pack("!BBH", 0, 17, udp_len)
    assert udp_len == len(assembled) == 644
    assert fold16(pseudo + assembled) == 0xFFFF
    return assembled[8:]


def verify_single(frame, vlid, dport):
    dmac, smac, offset, mf, udp = verify_one_frame(frame)
    assert dmac == bytes((3, 0, 0, 0, 0, vlid))
    assert smac == bytes((2, 0, 0, 0, vlid, 0x20))
    assert offset == 0 and not mf
    assert int.from_bytes(udp[2:4], "big") == dport
    udp_len = int.from_bytes(udp[4:6], "big")
    assert udp_len == len(udp)
    pseudo = SRC_IP + DST_IP + struct.pack("!BBH", 0, 17, udp_len)
    assert fold16(pseudo + udp) == 0xFFFF
    return udp[8:]


def write_vectors(frames):
    words = [len(frames)]
    for frame in frames:
        wire = b"\x55" * 7 + b"\xD5" + frame
        words.append(len(frame))
        wire += bytes((-len(wire)) % 4)
        words.extend(int.from_bytes(wire[i:i + 4], "big")
                     for i in range(0, len(wire), 4))
    VEC.mkdir(parents=True, exist_ok=True)
    (VEC / "t65_metadata.hex").write_text(
        "".join(f"{word:08X}\n" for word in words), encoding="ascii")
    (VEC / "t65_metadata.names").write_text(
        "vl5-first-600-mf\nvl5-last-36-offset608\nvl6-single-12\n",
        encoding="ascii")


def main():
    frames = make_t65_frames()
    write_vectors(frames)
    print("T65 GOLDEN PASS: VL5 UDP/IP fragments reassembled and checksummed; "
          "VL6 12B UDP/IP and all three FCS values verified")


if __name__ == "__main__":
    main()
