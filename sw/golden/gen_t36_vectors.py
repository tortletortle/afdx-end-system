#!/usr/bin/env python3
"""Generate the deliberately truncated, but Ethernet/IP/UDP-valid, T36 SET frame."""
from pathlib import Path
import sys
import struct
import zlib

from afdx_model import build_frame, ones_comp16

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "sim" / "vec" / "t36_malformed.hex"
MGMT_OUT = ROOT / "sim" / "vec" / "t36_mgmt.hex"
PFX = bytes.fromhex("2b06010401a25c01")


def tlv(tag: int, value: bytes) -> bytes:
    if len(value) >= 128:
        raise ValueError("unexpected long BER value")
    return bytes((tag, len(value))) + value


def integer(value: int) -> bytes:
    raw = value.to_bytes(max(1, (value.bit_length() + 7) // 8), "big")
    if raw[0] & 0x80:
        raw = b"\x00" + raw
    return tlv(0x02, raw)


def snmp_set() -> bytes:
    oid = tlv(0x06, PFX + bytes((1, 11, 0)))
    vb = tlv(0x30, oid + integer(0x2222))
    pdu = integer(0x3690) + integer(0) + integer(0) + tlv(0x30, vb)
    message = tlv(0x30, integer(0) + tlv(0x04, b"public") + tlv(0xA3, pdu))
    # Keep every enclosing BER length from the original SET, but remove the
    # final INTEGER content byte. Outer UDP/IP lengths and checksums below are
    # recomputed, so the malformed BER reaches snmp_lite through the real RX path.
    return message[:-1]


def snmp_request(pdu: int, request_id: int, oid_bytes: bytes, value: bytes) -> bytes:
    vb = tlv(0x30, tlv(0x06, oid_bytes) + value)
    pdu_body = integer(request_id) + integer(0) + integer(0) + tlv(0x30, vb)
    return tlv(0x30, integer(0) + tlv(0x04, b"public") + tlv(pdu, pdu_body))


def main() -> None:
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from gen_t15_vectors import cases, frame
    selected_ids = (28,31,27,30,29,22,14,15,19,25,54,55,57,12,13,11,56,21,18)
    selected = {cid:(svc,payload,aux) for cid,svc,payload,_sn,aux in cases if cid in selected_ids}
    selected[54] = (1, snmp_request(0xA3,0x3691,PFX+bytes((1,5,5)),integer(0x01000000)),0)
    selected[55] = (1, snmp_request(0xA0,0x3692,PFX+bytes((1,5,5)),tlv(0x05,b"")),0)
    selected[56] = (1, snmp_request(0xA0,0x3693,PFX+bytes((2,47,0)),tlv(0x05,b"")),0)
    selected[57] = (1, snmp_request(0xA0,0x3694,PFX+bytes((1,11,0)),tlv(0x05,b"")),0)
    words = [len(selected_ids)]
    for ordinal, cid in enumerate(selected_ids, start=1):
        svc, payload, aux = selected[cid]
        sn = ordinal if ordinal <= 12 else ordinal + 1
        data = frame(payload, sn)
        words += [(cid << 24) | (svc << 20) | (5 << 16) | len(data), len(payload), aux]
        words += [int.from_bytes(data[i:i+4].ljust(4,b"\x00"),"big") for i in range(0,len(data),4)]
    MGMT_OUT.parent.mkdir(parents=True,exist_ok=True)
    MGMT_OUT.write_text("// T36 selected SNMP requests; AFDX SN is contiguous in injection order\n"+
                        "".join(f"{w:08x}\n" for w in words),encoding="ascii")
    payload = snmp_set()
    body, _ = build_frame(0x0100, 0x1234, 1, 1, "10.0.0.1", "224.0.0.1",
                          49152, 5000, payload, 13, ident=7, fcs_mode=0,
                          udp_csum_mode=1)
    body = body[:-1] + bytes((13,))
    assert ones_comp16(body[14:34]) == 0
    assert ones_comp16(body[26:34] + b"\x00\x11" + body[38:40] + body[34:42+len(payload)]) == 0
    frame = body + (zlib.crc32(body) & 0xFFFFFFFF).to_bytes(4, "little")
    raw = [len(frame)] + [int.from_bytes(frame[i:i+4].ljust(4, b"\x00"), "big")
                          for i in range(0, len(frame), 4)]
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text("\n".join(f"{x:08x}" for x in raw) + "\n", encoding="ascii")
    print(f"T36 vectors: {len(selected_ids)} selected SNMP cases with sequential SN + malformed BER {len(frame)} B")


if __name__ == "__main__":
    main()
