#!/usr/bin/env python3
"""Generate independent byte vectors consumed directly by tb_t64_rx_udp_checksum."""
import struct
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "sim" / "vec" / "t64_udp_checksum.hex"
SRC = bytes.fromhex("0a000099")
DST = bytes.fromhex("0a000002")
LENGTHS = (0, 1, 2, 35, 36, 635, 636, 2005, 2006)
STRIDE = 2022  # 7 metadata bytes + max 2014-byte UDP record + one pad byte


def payload(n: int, salt: int = 0) -> bytes:
    return bytes(((i * 73 + (i // 7) * 29 + 0x3D + salt) & 0xFF)
                 for i in range(n))


def fold(data: bytes) -> int:
    if len(data) & 1:
        data += b"\0"
    acc = sum((data[i] << 8) | data[i + 1]
              for i in range(0, len(data), 2))
    while acc >> 16:
        acc = (acc & 0xFFFF) + (acc >> 16)
    return acc


def checksum(data: bytes) -> int:
    return (~fold(data)) & 0xFFFF


def make_case(app_len: int, *, bad_payload=False, zero_checksum=False,
              bad_length=False, check_en=True):
    app_for_sum = payload(app_len)
    udp_len = app_len + 8
    field_len = udp_len + int(bad_length)
    pseudo = SRC + DST + struct.pack("!BBH", 0, 17, udp_len)
    udp0 = struct.pack("!HHHH", 12001, 5000, field_len, 0)
    csum = checksum(pseudo + udp0 + app_for_sum) or 0xFFFF
    if zero_checksum:
        csum = 0
    app = bytearray(app_for_sum)
    if bad_payload and app:
        app[-1] ^= 0x80  # preserve the checksum from the uncorrupted datagram
    udp = struct.pack("!HHHH", 12001, 5000, field_len, csum) + app
    reason = 1 if bad_length else (2 if check_en and (zero_checksum or bad_payload) else 0)
    return {
        "app_len": app_len, "check_en": int(check_en),
        "good": int(reason == 0), "reason": reason, "udp": udp,
    }


def serialize(case) -> list[int]:
    app_len = case["app_len"]
    udp = case["udp"]
    hdr = [app_len >> 8, app_len & 0xFF, case["check_en"], case["good"],
           case["reason"], len(udp) >> 8, len(udp) & 0xFF]
    record = hdr + list(udp)
    assert len(record) <= STRIDE
    return record + [0] * (STRIDE - len(record))


def main():
    cases = [make_case(n) for n in LENGTHS]
    cases += [
        make_case(35, bad_length=True),
        make_case(36, bad_payload=True),
        make_case(1, zero_checksum=True),
        make_case(35, bad_payload=True, check_en=False),
        {"app_len": 2007, "check_en": 1, "good": 0, "reason": 3, "udp": b""},
        make_case(1, zero_checksum=True, check_en=False),
        make_case(35, bad_length=True, check_en=False),
    ]
    OUT.parent.mkdir(parents=True, exist_ok=True)
    with OUT.open("w", encoding="ascii", newline="\n") as f:
        f.writelines(f"{b:02X}\n" for case in cases for b in serialize(case))
    # Independently validate every positive, checksum-enabled record.
    for case in cases:
        if case["good"] and case["check_en"]:
            udp = case["udp"]
            pseudo = SRC + DST + struct.pack("!BBH", 0, 17, case["app_len"] + 8)
            assert fold(pseudo + udp) == 0xFFFF
    print(f"T64 vectors PASS: {len(cases)} records, {STRIDE} bytes/record -> {OUT}")


if __name__ == "__main__":
    main()
