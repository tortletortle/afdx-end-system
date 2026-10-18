#!/usr/bin/env python3
"""Generate independent AFDX/IPv4 fragmentation vectors for T60.

The UDP datagram is constructed and checksummed before it is split into IP
fragments. Fragment offsets count IP payload bytes (including the UDP header
in fragment zero); application offsets are tracked separately.
"""
import struct
import zlib
from pathlib import Path

from afdx_model import dmac_of, smac_of, ET_IPV4

ROOT = Path(__file__).resolve().parents[2]
VEC = ROOT / "sim" / "vec"
VLID, UDI, IFID = 5, 5, 1
SRC_IP, DST_IP = "10.0.0.153", "10.0.0.2"
SPORT, DPORT = 12345, 5000
MSG_LEN = 636


def ip_bytes(ip):
    return bytes(int(x) for x in ip.split("."))


def checksum(data):
    if len(data) & 1:
        data += b"\0"
    acc = sum((data[i] << 8) | data[i + 1] for i in range(0, len(data), 2))
    while acc >> 16:
        acc = (acc & 0xFFFF) + (acc >> 16)
    return (~acc) & 0xFFFF


def app_payload(offset, length):
    return bytes(((i * 7 + (i // 8) * 13 + 0x5A) & 0xFF)
                 for i in range(offset, offset + length))


def ip_header(total_len, ident, mf, offset_bytes):
    assert offset_bytes % 8 == 0
    flags_offset = (0x2000 if mf else 0) | (offset_bytes // 8)
    h = struct.pack("!BBHHHBBH4s4s", 0x45, 0, total_len, ident,
                    flags_offset, 64, 17, 0, ip_bytes(SRC_IP), ip_bytes(DST_IP))
    return h[:10] + struct.pack("!H", checksum(h)) + h[12:]


def make_udp_datagram(app_len=MSG_LEN):
    udp_len = app_len + 8
    pseudo = ip_bytes(SRC_IP) + ip_bytes(DST_IP) + struct.pack("!BBH", 0, 17, udp_len)
    udp0 = struct.pack("!HHHH", SPORT, DPORT, udp_len, 0)
    app = app_payload(0, app_len)
    csum = checksum(pseudo + udp0 + app) or 0xFFFF
    return struct.pack("!HHHH", SPORT, DPORT, udp_len, csum) + app


def make_frame(ident, mf, ip_offset, ip_payload, sn):
    ip = ip_header(20 + len(ip_payload), ident, mf, ip_offset)
    core = dmac_of(VLID) + smac_of(UDI, IFID) + struct.pack("!H", ET_IPV4) + ip + ip_payload
    # AFDX SN is the final MAC payload octet immediately before FCS.
    # Pad short Ethernet frames before the AFDX SN; the IP total length keeps
    # the padding outside the IPv4 payload and the SN remains immediately
    # before FCS.
    pad_len = max(0, 60 - (len(core) + 1))
    no_fcs = core + (b"\0" * pad_len) + bytes([sn])
    fcs = zlib.crc32(no_fcs) & 0xFFFFFFFF
    return no_fcs + struct.pack("<I", fcs)


def frame_for_piece(ident, mf, ip_offset, app_offset, app_len, sn, datagram):
    if ip_offset == 0:
        payload = datagram[:8] + datagram[8 + app_offset:8 + app_offset + app_len]
    else:
        payload = datagram[8 + app_offset:8 + app_offset + app_len]
    return make_frame(ident, mf, ip_offset, payload, sn)


def preamble(frame):
    return b"\x55" * 7 + b"\xD5" + frame


def emit(f, frames):
    f.write(f"{len(frames):08X}\n")
    for frame in frames:
        f.write(f"{len(frame):08X}\n")  # MAC frame length, includes FCS, excludes preamble
        wire = preamble(frame)
        wire += b"\0" * ((-len(wire)) % 4)
        for i in range(0, len(wire), 4):
            f.write(f"{int.from_bytes(wire[i:i+4], 'big'):08X}\n")


def verify_frame(frame):
    assert len(frame) >= 64
    assert (zlib.crc32(frame[:-4]) & 0xFFFFFFFF) == int.from_bytes(frame[-4:], "little")
    assert frame[12:14] == b"\x08\x00"
    ip = frame[14:34]
    assert checksum(ip) == 0
    total_len = int.from_bytes(ip[2:4], "big")
    assert len(frame) == max(64, 14 + total_len + 1 + 4)
    assert frame[14 + total_len:-5] == bytes(max(0, 59 - (14 + total_len)))
    assert frame[-5] != 0  # each generated AFDX frame carries a nonzero SN
    offset = (int.from_bytes(ip[6:8], "big") & 0x1FFF) * 8
    data = frame[34:14 + total_len]
    return offset, bool(int.from_bytes(ip[6:8], "big") & 0x2000), data


def verify_case(frames, expected, require_udp=True):
    pieces = sorted((verify_frame(fr) for fr in frames), key=lambda p: p[0])
    cursor, assembled = 0, bytearray()
    for offset, mf, data in pieces:
        assert offset == cursor, ("gap/overlap", offset, cursor)
        if mf:
            assert len(data) % 8 == 0
        assembled.extend(data)
        cursor += len(data)
    if require_udp:
        assert len(assembled) == len(expected) + 8
        udp = bytes(assembled[:8])
        udp_len = int.from_bytes(udp[4:6], "big")
        assert udp_len == len(assembled)
        pseudo = ip_bytes(SRC_IP) + ip_bytes(DST_IP) + struct.pack("!BBH", 0, 17, udp_len)
        assert checksum(pseudo + assembled) == 0
        assert bytes(assembled[8:]) == expected
    return bytes(assembled)


def main():
    VEC.mkdir(parents=True, exist_ok=True)
    datagram = make_udp_datagram()
    assert len(datagram) == MSG_LEN + 8
    app = datagram[8:]
    sn = 1
    cases = []

    def piece(ident, mf, ip_offset, app_offset, app_len, udp_data=None):
        nonlocal sn
        frame = frame_for_piece(ident, mf, ip_offset, app_offset, app_len, sn,
                                datagram if udp_data is None else udp_data)
        sn = sn % 255 + 1
        return frame

    # IP offsets: first fragment has UDP header + 600 application bytes.
    cases.append(("in-order", [piece(0x2222, 1, 0, 0, 600),
                               piece(0x2222, 0, 608, 600, 36)]))
    cases.append(("delayed-tail", [piece(0x5555, 1, 0, 0, 600),
                                   piece(0x5555, 0, 608, 600, 36)]))
    cases.append(("out-of-order", [piece(0x7777, 0, 608, 600, 36),
                                   piece(0x7777, 1, 0, 0, 600)]))
    # Deliberately malformed overlap is a negative control, not a valid UDP case.
    cases.append(("overlap", [piece(0x8888, 1, 0, 0, 600),
                              piece(0x8888, 1, 512, 512, 104)]))
    # Three fragments: 408 IP payload bytes, then 200, then 36.
    cases.append(("three-frag", [piece(0x9999, 1, 0, 0, 400),
                                 piece(0x9999, 1, 408, 400, 200),
                                 piece(0x9999, 0, 608, 600, 36)]))
    # Exercise the COPY_ENABLE source table beyond MAX_FRAGS=16. The first
    # fragment contains 8 app bytes; sixteen later 32-byte fragments are
    # copied and reclaimed one by one, then a 116-byte tail closes the UDP
    # datagram. Every non-final IP payload remains 8-byte aligned.
    reuse = [piece(0xA1A1, 1, 0, 0, 8)]
    for i in range(16):
        reuse.append(piece(0xA1A1, 1, 16 + 32 * i, 8 + 32 * i, 32))
    reuse.append(piece(0xA1A1, 0, 528, 520, 116))
    cases.append(("slot-reuse", reuse))

    # Every fragment below has valid IPv4 checksum and Ethernet FCS. Only the
    # reassembled UDP datagram carries the deliberate fault.
    bad = bytearray(datagram)
    bad[-1] ^= 1
    zero = bytearray(datagram)
    zero[6:8] = b"\0\0"
    wrong_len = bytearray(datagram)
    wrong_len[4:6] = struct.pack("!H", len(datagram) + 1)
    odd = make_udp_datagram(635)
    for name, ident, data in (("bad-udp", 0xB101, bad),
                              ("zero-udp", 0xB102, zero),
                              ("bad-udp-length", 0xB103, wrong_len),
                              ("odd-valid", 0xB104, odd),
                              ("disabled-bad-udp", 0xB105, bad),
                              ("disabled-bad-length", 0xB106, wrong_len)):
        cases.append((name, [piece(ident, 1, 0, 0, 600, data),
                             piece(ident, 0, 608, 600, len(data)-608, data)]))

    assert verify_case(cases[0][1], app) == datagram
    assert verify_case(cases[1][1], app) == datagram
    assert verify_case(cases[2][1], app) == datagram
    assert verify_case(cases[4][1], app) == datagram
    assert verify_case(cases[5][1], app) == datagram
    assert verify_case(cases[9][1], app_payload(0, 635)) == odd
    for case_index, expected in ((6, bad), (7, zero), (8, wrong_len),
                                 (10, bad), (11, wrong_len)):
        assembled = verify_case(cases[case_index][1], app, require_udp=False)
        assert assembled == expected
        pseudo = ip_bytes(SRC_IP) + ip_bytes(DST_IP) + struct.pack("!BBH", 0, 17, len(assembled))
        assert checksum(pseudo + assembled) != 0
    # Negative control: corrupt a byte in the complete datagram; checksum/content validator must reject.
    mutant = bytearray(datagram)
    mutant[-1] ^= 1
    pseudo = ip_bytes(SRC_IP) + ip_bytes(DST_IP) + struct.pack("!BBH", 0, 17, len(mutant))
    assert checksum(pseudo + mutant) != 0

    with (VEC / "t60_reasm.hex").open("w", encoding="ascii", newline="\n") as f:
        f.write(f"{len(cases):08X}\n")
        for _, frames in cases:
            emit(f, frames)
    (VEC / "t60_reasm.names").write_text("\n".join(n for n, _ in cases) + "\n", encoding="ascii")
    print("T60 GOLDEN PASS: 12 cases; full UDP, delayed tail, 18-fragment reuse, odd length, bad/zero checksum and length-policy controls; all fragment IP/FCS verified")


if __name__ == "__main__":
    main()
