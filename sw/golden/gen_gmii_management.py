#!/usr/bin/env python3
"""Default-top PHY management vectors with independent full-frame replies.

This checks SNMP and RFC1350 transport. It is not an ARINC615A control
protocol implementation or a claim of complete protocol conformance.
"""
import json
from pathlib import Path
import zlib
from afdx_model import build_frame, parse_frame
from gen_t15_vectors import GET, NEXT, SET, snmp, vb, tlv, ber_int, tftp_rq, tftp_data, D1, D2

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "sim" / "vec"


def request(payload, sequence):
    data, _ = build_frame(0x100, 0x1234, 1, 1, "10.0.0.1", "224.0.0.1",
                          49152, 5000, payload, 1, ident=7)
    data = data[:-5] + bytes((sequence,))
    return data + zlib.crc32(data).to_bytes(4, "little")


def response(payload, sequence, net):
    data, _ = build_frame(0x100, 0x172D, net + 1, net + 1,
                          "10.0.0.2", "10.0.0.1", 5000, 49152,
                          payload, sequence, ident=0, tos=0, ttl=255)
    return data


def main():
    value = tlv(2, ber_int(0x1234))
    objects = [vb(1, 11, val=value)]
    scenarios = [
        (0, "snmp_set", snmp(SET, 0xA5A5, objects), snmp(0xA2, 0xA5A5, objects)),
        (0, "snmp_get_after_set", snmp(GET, 0xA5A6, [vb(1, 11)]), snmp(0xA2, 0xA5A6, objects)),
        (0, "snmp_getnext", snmp(NEXT, 0xA5A7, [vb(1, 10)]), snmp(0xA2, 0xA5A7, objects)),
        (0, "snmp_wrong_community", snmp(GET, 0xA5A8, [vb(1, 11)], community=b"secret"), None),
        (1, "tftp_wrq", tftp_rq(2, b"UPLOAD"), bytes.fromhex("00040000")),
        (1, "tftp_data_1", tftp_data(1, D1), bytes.fromhex("00040001")),
        (1, "tftp_data_2", tftp_data(2, D2), bytes.fromhex("00040002")),
        (1, "tftp_rrq_unload", tftp_rq(1, b"UPLOAD"), tftp_data(1, D1)),
        (1, "tftp_ack_1", bytes.fromhex("00040001"), tftp_data(2, D2)),
        (1, "tftp_ack_final", bytes.fromhex("00040002"), None),
    ]
    words = [len(scenarios)]
    records = []
    previous_phase = -1
    rx_sn = tx_sn = 0
    for case_id, (phase, name, req, rsp) in enumerate(scenarios):
        if phase != previous_phase:
            rx_sn = tx_sn = 0
        request_frame = request(req, rx_sn)
        rx_sn += 1
        replies = []
        if rsp is not None:
            tx_sn += 1
            replies = [response(rsp, tx_sn, net) for net in (0, 1)]
        word_offset = len(words)
        words.extend((phase, len(request_frame), len(replies[0]) if replies else 0))
        for packet in [request_frame] + replies:
            decoded = parse_frame(packet)
            assert decoded["fcs_ok"] and decoded["udp_csum_ok"]
            assert zlib.crc32(packet[:-4]) == int.from_bytes(packet[-4:], "little")
            words.extend(int.from_bytes(packet[i:i+4].ljust(4, b"\0"), "big")
                         for i in range(0, len(packet), 4))
        records.append({"case_id": case_id, "name": name, "phase": phase,
                        "request_bytes": len(request_frame), "response_bytes": len(replies[0]) if replies else 0,
                        "record_word": word_offset})
        previous_phase = phase
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "gmii_management.hex").write_text("".join(f"{w:08x}\n" for w in words), encoding="ascii")
    (OUT / "gmii_management.vh").write_text(f"`define GMII_MGMT_WORDS {len(words)}\n", encoding="ascii")
    (OUT / "gmii_management.json").write_text(json.dumps({"cases": records, "words": len(words)}, indent=2)+"\n", encoding="utf-8")
    print(f"GMII management: {len(records)} cases, {len(words)} words; SNMP and TFTP full-frame expectations")


if __name__ == "__main__":
    main()
