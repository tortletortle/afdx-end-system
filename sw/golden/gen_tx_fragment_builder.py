"""Independent Ethernet/IPv4/UDP/GMII oracle for the new TX fragment builder."""
import argparse
import json
from pathlib import Path
import struct
import zlib


def checksum(data):
    if len(data) % 2:
        data += b"\0"
    value = sum(struct.unpack(f"!{len(data)//2}H", data))
    while value >> 16:
        value = (value & 65535) + (value >> 16)
    return ~value & 65535


def wire(body):
    return b"\x55" * 7 + b"\xd5" + body + struct.pack("<I", zlib.crc32(body))


def generate(directory):
    assert not directory.exists(), "Preserve existing vectors"
    directory.mkdir(parents=True)
    cases = []
    records = []
    src = bytes([192, 168, 1, 1])
    dst = bytes([192, 168, 1, 2])
    message = 0
    for length in (1, 2, 8, 17, 1471, 1472, 2007, 2048, 2049, 2943, 2944, 4096, 6144, 8191, 8192):
        for enabled in (0, 1):
            data = bytes((j * 37 + message * 17 + 3) & 255 for j in range(length))
            udp = struct.pack("!HHHH", 0x1234, 0x5678, length + 8, 0)
            pseudo = src + dst + struct.pack("!BBH", 0, 17, length + 8)
            if length == 2 and enabled:
                # A computed zero checksum must be encoded as 0xffff (RFC 768).
                data = struct.pack("!H", checksum(pseudo + udp))
                assert checksum(pseudo + udp + data) == 0
            udp_cs = (checksum(pseudo + udp + data) or 65535) if enabled else 0
            udp = udp[:6] + struct.pack("!H", udp_cs)
            datagram = udp + data
            assert not enabled or checksum(pseudo + datagram) == 0
            offset = 0
            fragment = 0
            while offset < len(datagram):
                remaining = len(datagram) - offset
                more = remaining > 1479
                payload_length = 1472 if more else remaining
                flags = (0x2000 if more else 0) | (offset // 8)
                ident = 0x1200 + message
                sn = (0x91 + fragment) & 255
                ip = struct.pack("!BBHHHBBH4s4s", 0x45, 0x2c, 20 + payload_length,
                                 ident, flags, 64, 17, 0, src, dst)
                ip = ip[:10] + struct.pack("!H", checksum(ip)) + ip[12:]
                assert checksum(ip) == 0
                # The checker rejects a known corrupted header.
                corrupt = bytearray(ip)
                corrupt[8] ^= 1
                assert checksum(bytes(corrupt)) != 0
                ethernet = bytes.fromhex("0300000001050200001234200800")
                body = ethernet + ip + datagram[offset:offset+payload_length]
                body += bytes(max(0, 59-len(body))) + bytes([sn])
                other = body[:11] + bytes([0x40]) + body[12:]
                wire_a, wire_b = wire(body), wire(other)
                count = (length + 2047) // 2048
                values = [length, count, 0x0351, offset, enabled, ident, sn,
                          len(body), int(not more), offset+payload_length,
                          payload_length, len(wire_a)]
                records.extend(values)
                records.extend(data)
                records.extend(body)
                records.extend(wire_a)
                records.extend(wire_b)
                cases.append(dict(message=message, length=length, checksum=enabled,
                                  offset=offset, fragment_length=payload_length,
                                  last=not more, body_bytes=len(body), wire_bytes=len(wire_a)))
                offset += payload_length
                fragment += 1
            assert offset == len(datagram)
            message += 1
    vector = directory / "cases.hex"
    vector.write_text("\n".join(f"{word:08x}" for word in [len(cases)] + records) + "\n", encoding="ascii")
    (directory / "manifest.json").write_text(json.dumps({"scope": "Standalone TX fragment builder; not production-top TX8KiB",
                                                        "messages": message, "cases": cases,
                                                        "case_count": len(cases)}, indent=2) + "\n", encoding="utf-8")
    print(f"TX FRAGMENT GOLDEN PASS messages={message} fragments={len(cases)}", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", required=True, type=Path)
    generate(parser.parse_args().out)
