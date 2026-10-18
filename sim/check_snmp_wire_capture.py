#!/usr/bin/env python3
"""Independently validate the full SNMP response frames captured by T31/T31g."""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import struct
import sys
import zlib
from pathlib import Path

PFX = bytes.fromhex("2b06010401a25c01")
EXPECTED = {
    10: {"request_id": 0x11223344, "oid": PFX + bytes((1, 2, 0)), "tag": 0x43},
    11: {"request_id": 0x55, "oid": PFX + bytes((2, 0, 0)), "tag": 0x41},
    12: {"request_id": 0xA5A5, "oid": PFX + bytes((1, 11, 0)), "tag": 0x02},
}
FRAME_RE = re.compile(r"T31_FRAME case=(\d+) net=(\d+) len=(\d+) hex=([0-9a-fA-F]+)")
VALUE_RE = re.compile(r"T31_EXPECT case=(\d+) value=([0-9a-fA-F]{8})")


def fail(message: str) -> None:
    raise ValueError(message)


def one_sum(data: bytes) -> int:
    if len(data) & 1:
        data += b"\x00"
    total = sum((data[i] << 8) | data[i + 1] for i in range(0, len(data), 2))
    while total >> 16:
        total = (total & 0xFFFF) + (total >> 16)
    return total


def read_tlv(data: bytes, pos: int, parent_end: int) -> tuple[int, bytes, int]:
    if pos < 0 or pos + 2 > parent_end or parent_end > len(data):
        fail("truncated TLV header")
    tag = data[pos]
    first = data[pos + 1]
    if first < 0x80:
        length, value_pos = first, pos + 2
    else:
        nlen = first & 0x7F
        if nlen == 0 or nlen > 4 or pos + 2 + nlen > parent_end:
            fail("invalid or unsupported BER length")
        if data[pos + 2] == 0:
            fail("non-minimal BER long length")
        length = int.from_bytes(data[pos + 2 : pos + 2 + nlen], "big")
        if length < 0x80:
            fail("non-minimal BER long length")
        value_pos = pos + 2 + nlen
    end = value_pos + length
    if end > parent_end:
        fail("TLV crosses parent boundary")
    return tag, data[value_pos:end], end


def integer_value(raw: bytes) -> int:
    if not raw:
        fail("empty BER INTEGER")
    return int.from_bytes(raw, "big", signed=True)


def check_snmp_payload(payload: bytes, case_id: int, expected_value: int) -> dict:
    exp = EXPECTED[case_id]
    tag, message, end = read_tlv(payload, 0, len(payload))
    if tag != 0x30 or end != len(payload):
        fail("SNMP message is not one complete SEQUENCE")
    p = 0
    tag, raw, p = read_tlv(message, p, len(message))
    if tag != 0x02 or integer_value(raw) != 0:
        fail("SNMP version is not v1")
    tag, community, p = read_tlv(message, p, len(message))
    if tag != 0x04 or community != b"public":
        fail("community is not the configured public value")
    tag, pdu, p = read_tlv(message, p, len(message))
    if tag != 0xA2 or p != len(message):
        fail("PDU is not one complete GetResponse")

    q = 0
    tag, raw, q = read_tlv(pdu, q, len(pdu))
    if tag != 0x02 or integer_value(raw) != exp["request_id"]:
        fail("request-id does not match the originating request")
    tag, raw, q = read_tlv(pdu, q, len(pdu))
    if tag != 0x02 or integer_value(raw) != 0:
        fail("error-status is not zero")
    tag, raw, q = read_tlv(pdu, q, len(pdu))
    if tag != 0x02 or integer_value(raw) != 0:
        fail("error-index is not zero")
    tag, vbl, q = read_tlv(pdu, q, len(pdu))
    if tag != 0x30 or q != len(pdu):
        fail("VarBindList is missing or malformed")

    tag, vb, vbl_end = read_tlv(vbl, 0, len(vbl))
    if tag != 0x30 or vbl_end != len(vbl):
        fail("expected exactly one complete VarBind")
    tag, oid, r = read_tlv(vb, 0, len(vb))
    if tag != 0x06 or oid != exp["oid"]:
        fail("VarBind OID does not match the requested MIB object")
    tag, raw, r = read_tlv(vb, r, len(vb))
    if tag != exp["tag"] or r != len(vb):
        fail("VarBind syntax tag or boundary is incorrect")
    value = integer_value(raw)
    if value != expected_value:
        fail(f"VarBind value mismatch: got {value}, expected {expected_value}")
    return {
        "request_id": exp["request_id"],
        "error_status": 0,
        "error_index": 0,
        "oid_hex": oid.hex(),
        "value_tag": tag,
        "value": value,
    }


def check_frame(frame: bytes, case_id: int, expected_value: int) -> dict:
    if len(frame) < 64:
        fail("frame shorter than Ethernet minimum including FCS")
    if frame[:4] != bytes.fromhex("03000000") or frame[4:6] != bytes.fromhex("0100"):
        fail("AFDX destination prefix or VLID is incorrect")
    if frame[12:14] != b"\x08\x00":
        fail("EtherType is not IPv4")
    ip = frame[14:]
    if ip[0] != 0x45 or ip[9] != 17:
        fail("expected IPv4 with a 20-byte header and UDP payload")
    ip_total = int.from_bytes(ip[2:4], "big")
    frag = int.from_bytes(ip[6:8], "big")
    if frag & 0x3FFF:
        fail("fragmented IPv4 response")
    if ip_total < 28 or 14 + ip_total + 1 + 4 > len(frame):
        fail("IPv4 total length exceeds the captured frame")
    ip_header = frame[14:34]
    if one_sum(ip_header) != 0xFFFF:
        fail("IPv4 header checksum mismatch")
    src_ip, dst_ip = frame[26:30], frame[30:34]
    if src_ip != bytes((10, 0, 0, 2)) or dst_ip != bytes((10, 0, 0, 1)):
        fail("response IP peer tuple is not reversed correctly")

    sport, dport, udp_len, udp_csum = struct.unpack("!HHHH", frame[34:42])
    if (sport, dport) != (5000, 49152):
        fail("response UDP peer tuple is not reversed correctly")
    if udp_len < 8 or ip_total != 20 + udp_len:
        fail("IPv4/UDP lengths are inconsistent")
    udp = frame[34 : 34 + udp_len]
    pseudo = src_ip + dst_ip + b"\x00\x11" + struct.pack("!H", udp_len)
    if udp_csum == 0 or one_sum(pseudo + udp) != 0xFFFF:
        fail("UDP checksum mismatch")

    snmp_len = udp_len - 8
    pad_len = max(0, 17 - snmp_len)
    sn_pos = 42 + snmp_len + pad_len
    if sn_pos + 1 + 4 != len(frame) or frame[42 + snmp_len : sn_pos] != b"\x00" * pad_len:
        fail("Ethernet pad, AFDX sequence number, and FCS boundaries are inconsistent")
    expected_fcs = struct.pack("<I", zlib.crc32(frame[:-4]) & 0xFFFFFFFF)
    if frame[-4:] != expected_fcs:
        fail("Ethernet FCS mismatch")

    ber = check_snmp_payload(frame[42 : 42 + snmp_len], case_id, expected_value)
    ber.update(
        {
            "case": case_id,
            "frame_length": len(frame),
            "src_ip": ".".join(map(str, src_ip)),
            "dst_ip": ".".join(map(str, dst_ip)),
            "udp_sport": sport,
            "udp_dport": dport,
            "sn": frame[sn_pos],
            "fcs_ok": True,
        }
    )
    return ber


def parse_v1_response(payload: bytes) -> dict:
    """Decode a complete response without assuming the normal T31 response."""
    tag, msg, end = read_tlv(payload, 0, len(payload))
    if tag != 0x30 or end != len(payload): fail("SNMP message is not one complete SEQUENCE")
    p = 0
    tag, raw, p = read_tlv(msg, p, len(msg))
    if tag != 0x02 or integer_value(raw) != 0: fail("SNMP version is not v1")
    tag, comm, p = read_tlv(msg, p, len(msg))
    if tag != 0x04 or comm != b"public": fail("community is not public")
    tag, pdu, p = read_tlv(msg, p, len(msg))
    if tag != 0xA2 or p != len(msg): fail("PDU is not one complete GetResponse")
    q = 0
    tag, raw, q = read_tlv(pdu, q, len(pdu)); rid = integer_value(raw)
    tag, raw, q = read_tlv(pdu, q, len(pdu)); err = integer_value(raw)
    tag, raw, q = read_tlv(pdu, q, len(pdu)); idx = integer_value(raw)
    tag, vbl, q = read_tlv(pdu, q, len(pdu))
    if tag != 0x30 or q != len(pdu): fail("response VarBindList malformed")
    vbs = []
    pos = 0
    while pos < len(vbl):
        tag, vb, pos = read_tlv(vbl, pos, len(vbl))
        if tag != 0x30: fail("VarBind is not a SEQUENCE")
        x = 0
        tag, oid, x = read_tlv(vb, x, len(vb))
        if tag != 0x06: fail("VarBind OID missing")
        tag, value, x = read_tlv(vb, x, len(vb))
        if x != len(vb): fail("trailing VarBind bytes")
        vbs.append({"oid_hex": oid.hex(), "value_tag": tag,
                    "value_hex": value.hex(),
                    "value": integer_value(value) if tag in (0x02,0x41,0x42,0x43) else None})
    return {"request_id": rid, "error_status": err, "error_index": idx, "varbinds": vbs}


def validate_expected(decoded: dict, exp: dict, case_id: int) -> None:
    for field in ("request_id", "error_status", "error_index"):
        if decoded[field] != exp[field]: fail(f"case {case_id}: {field}={decoded[field]} expected {exp[field]}")
    expected_vbs = exp.get("varbinds", [])
    if len(decoded["varbinds"]) != len(expected_vbs): fail(f"case {case_id}: VarBind count mismatch")
    for i, (got, expected) in enumerate(zip(decoded["varbinds"], expected_vbs), 1):
        for field in ("oid_hex", "value_tag", "value", "value_hex"):
            if field in expected and got[field] != expected[field]:
                fail(f"case {case_id} VarBind {i}: {field}={got[field]} expected {expected[field]}")


def validate_peer_tuple(actual: tuple, expected: dict) -> None:
    as_ip = lambda s: bytes(map(int, s.split(".")))
    want = (as_ip(expected.get("src_ip", "10.0.0.2")), as_ip(expected.get("dst_ip", "10.0.0.1")),
            int(expected.get("src_port", 5000)), int(expected.get("dst_port", 49152)))
    if actual != want: fail("response peer tuple mismatch")


def check_frame_spec(frame: bytes, case_id: int, spec: dict) -> dict:
    """Check all link/IP/UDP/BER semantics using one explicit case contract."""
    if len(frame) < 64: fail("frame shorter than Ethernet minimum including FCS")
    if frame[:6] != bytes.fromhex("030000000100") or frame[12:14] != b"\x08\x00":
        fail("AFDX destination/VLID/EtherType mismatch")
    ip = frame[14:]
    if ip[0] != 0x45 or ip[9] != 17: fail("expected IPv4/UDP")
    ip_total = int.from_bytes(ip[2:4], "big")
    if ip_total < 28 or 14 + ip_total + 1 + 4 > len(frame): fail("bad IPv4 length")
    if one_sum(frame[14:34]) != 0xFFFF: fail("IPv4 checksum mismatch")
    src_ip, dst_ip = frame[26:30], frame[30:34]
    udp_src, udp_dst, udp_len, udp_csum = struct.unpack("!HHHH", frame[34:42])
    validate_peer_tuple((src_ip, dst_ip, udp_src, udp_dst), spec.get("peer", {}))
    if udp_len < 8 or ip_total != 20 + udp_len: fail("IPv4/UDP lengths inconsistent")
    udp = frame[34:34+udp_len]
    pseudo = src_ip + dst_ip + b"\x00\x11" + struct.pack("!H", udp_len)
    if udp_csum == 0 or one_sum(pseudo + udp) != 0xFFFF: fail("UDP checksum mismatch")
    snmp_len = udp_len - 8
    pad_len = max(0, 17 - snmp_len)
    sn_pos = 42 + snmp_len + pad_len
    if sn_pos + 5 != len(frame) or frame[42+snmp_len:sn_pos] != b"\x00"*pad_len:
        fail("pad/SN/FCS boundaries inconsistent")
    if frame[-4:] != struct.pack("<I", zlib.crc32(frame[:-4]) & 0xFFFFFFFF): fail("FCS mismatch")
    decoded = parse_v1_response(frame[42:42+snmp_len])
    validate_expected(decoded, spec["response"], case_id)
    decoded.update({"case":case_id,"frame_length":len(frame),"net_integrity":"PASS","fcs_ok":True})
    return decoded


def check_case_specs(log_path: Path, spec_path: Path, json_out: Path | None) -> int:
    raw = log_path.read_bytes(); log = raw.decode("utf-8", errors="replace")
    specs = json.loads(spec_path.read_text(encoding="utf-8-sig"))["cases"]
    frames = {}
    for m in re.finditer(r"T36_FRAME case=(\d+) net=(\d+) len=(\d+) hex=([0-9a-fA-F]+)", log):
        c,n,l = map(int,m.group(1,2,3)); b=bytes.fromhex(m.group(4))
        if len(b)!=l: fail(f"case {c} net {n}: printed length mismatch")
        if (c,n) in frames: fail(f"duplicate frame for case {c} net {n}")
        frames[(c,n)] = b
    drops = {}
    for m in re.finditer(r"T36_DROP case=(\d+) no_response=1 drop_delta=(\d+) tx_delta=(-?\d+) cfg_before=([0-9a-fA-F]+) cfg_after=([0-9a-fA-F]+)", log):
        cid, delta, txdelta = map(int, m.group(1,2,3))
        if cid in drops: fail(f"duplicate drop observation for case {cid}")
        if delta < 1 or txdelta != 0 or int(m.group(4),16) != int(m.group(5),16):
            fail(f"case {cid}: drop evidence does not prove counted drop, no response, and unchanged ctl")
        drops[cid] = {"drop_delta":delta,"tx_delta":txdelta,"ctl_before":m.group(4),"ctl_after":m.group(5)}
    reports=[]; errors=[]
    for sid, spec in specs.items():
        cid=int(sid)
        if spec["outcome"] == "drop":
            if cid not in drops: errors.append(f"case {cid}: missing explicit no-response/drop observation")
            if any(c==cid for c,n in frames): errors.append(f"case {cid}: unexpected response frame")
            continue
        if cid in drops: errors.append(f"case {cid}: unexpected drop marker")
        if {(cid,0),(cid,1)} - frames.keys():
            errors.append(f"case {cid}: expected both A/B responses")
            continue
        for n in (0,1):
            try:
                r=check_frame_spec(frames[(cid,n)],cid,spec); r["net"]="A" if n==0 else "B"; reports.append(r)
            except ValueError as exc:
                errors.append(f"case {cid} net {'A' if n==0 else 'B'}: {exc}")
    expected_drops={int(c) for c,s in specs.items() if s["outcome"]=="drop"}
    if set(drops) != expected_drops: errors.append(f"drop evidence cases mismatch: expected {sorted(expected_drops)}, got {sorted(drops)}")
    expected_keys={(int(c),n) for c,s in specs.items() if s["outcome"]=="response" for n in (0,1)}
    if set(frames)!=expected_keys: errors.append("unexpected or missing response frame keys")
    result={"status":"FAIL" if errors else "PASS","log":str(log_path.resolve()),"log_sha256":hashlib.sha256(raw).hexdigest(),
            "case_specs":str(spec_path.resolve()),"responses":reports,"drops":drops,"errors":errors}
    if json_out: json_out.parent.mkdir(parents=True,exist_ok=True); json_out.write_text(json.dumps(result,indent=2)+"\n",encoding="utf-8")
    if errors:
        print(f"SNMP case-spec semantic FAIL: {len(errors)} mismatches; {len(reports)} A/B frames passed full checks")
        for err in errors: print(f"  {err}")
        return 1
    print(f"SNMP case-spec semantic PASS: {len(reports)} A/B responses and {len(drops)} strict drop observations")
    return 0


def tlv(tag: int, value: bytes) -> bytes:
    if len(value) >= 128:
        raise ValueError("self-test helper only creates short lengths")
    return bytes((tag, len(value))) + value


def self_test() -> int:
    oid = EXPECTED[12]["oid"]

    def make(pdu_tag=0xA2, rid=0xA5A5, err=0, err_idx=0, obj=oid, value_tag=0x02, value=0x1234):
        def encint(n: int) -> bytes:
            raw = n.to_bytes(max(1, (n.bit_length() + 7) // 8), "big")
            if raw[0] & 0x80:
                raw = b"\x00" + raw
            return tlv(0x02, raw)

        vb = tlv(0x30, tlv(0x06, obj) + tlv(value_tag, value.to_bytes(max(1, (value.bit_length() + 7) // 8), "big")))
        vbl = tlv(0x30, vb)
        pdu = tlv(pdu_tag, encint(rid) + encint(err) + encint(err_idx) + vbl)
        return tlv(0x30, encint(0) + tlv(0x04, b"public") + pdu)

    valid = make()
    check_snmp_payload(valid, 12, 0x1234)
    negatives = (
        make(rid=0xA5A4),
        make(pdu_tag=0xA0),
        make(err=4),
        make(err_idx=1),
        make(obj=PFX + bytes((1, 10, 0))),
        make(value_tag=0x05, value=0),
        make(value=0x1235),
        valid[:-1],
        valid + b"\x00",
    )
    for index, sample in enumerate(negatives):
        try:
            check_snmp_payload(sample, 12, 0x1234)
        except ValueError:
            continue
        raise AssertionError(f"negative semantic case {index} was incorrectly accepted")
    decoded = parse_v1_response(valid)
    expected = {"request_id":0xA5A5,"error_status":0,"error_index":0,
                "varbinds":[{"oid_hex":oid.hex(),"value_tag":2,"value":0x1234}]}
    validate_expected(decoded, expected, 999)
    semantic_mutations = []
    for field, value in (("error_status",4),("error_index",1)):
        bad = dict(decoded); bad[field] = value; semantic_mutations.append((bad, expected, "response"))
    for field, value in (("oid_hex","2b06010401a25c01010b01"),("value",0x1235)):
        bad = {**decoded,"varbinds":[dict(decoded["varbinds"][0])]}; bad["varbinds"][0][field]=value
        semantic_mutations.append((bad,expected,"response"))
    rejected=0
    for bad, exp, _ in semantic_mutations:
        try: validate_expected(bad, exp, 999)
        except ValueError: rejected += 1
        else: raise AssertionError("case-spec mutation was incorrectly accepted")
    try:
        validate_peer_tuple((bytes((10,0,0,2)),bytes((10,0,0,1)),5000,49153), {})
    except ValueError: rejected += 1
    else: raise AssertionError("peer mutation was incorrectly accepted")
    print(f"SNMP wire checker self-test PASS (1 valid + {len(negatives)} BER mutations + {rejected}/5 status/index/OID/value/peer mutations rejected)")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("log", nargs="?", type=Path)
    parser.add_argument("--json-out", type=Path)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--case-spec", type=Path, help="explicit JSON case oracle for T36/T36g")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    if not args.log or not args.log.is_file():
        parser.error("provide an existing simulator log or --self-test")
    if args.case_spec:
        return check_case_specs(args.log, args.case_spec, args.json_out)

    log_bytes = args.log.read_bytes()
    log = log_bytes.decode("utf-8", errors="replace")
    expected_values = {int(m.group(1)): int(m.group(2), 16) for m in VALUE_RE.finditer(log)}
    frames: dict[tuple[int, int], bytes] = {}
    for match in FRAME_RE.finditer(log):
        case_id, net_id, declared_len = map(int, match.group(1, 2, 3))
        raw = bytes.fromhex(match.group(4))
        if len(raw) != declared_len:
            fail(f"case {case_id} net {net_id}: printed length does not match hex bytes")
        key = (case_id, net_id)
        if key in frames:
            fail(f"duplicate captured response {key}")
        frames[key] = raw

    reports = []
    if set(frames) != {(case_id, net_id) for case_id in (10, 11, 12) for net_id in (0, 1)}:
        fail(f"expected six captured A/B responses, found keys {sorted(frames)}")
    for case_id in (10, 11, 12):
        if case_id in (10, 11) and case_id not in expected_values:
            fail(f"missing independent host-side value for case {case_id}")
        expected_value = expected_values.get(case_id, 0x1234)
        for net_id in (0, 1):
            report = check_frame(frames[(case_id, net_id)], case_id, expected_value)
            report["net"] = "A" if net_id == 0 else "B"
            reports.append(report)

    result = {
        "status": "PASS",
        "log": str(args.log.resolve()),
        "log_sha256": hashlib.sha256(log_bytes).hexdigest(),
        "responses": reports,
    }
    if args.json_out:
        args.json_out.parent.mkdir(parents=True, exist_ok=True)
        args.json_out.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(f"SNMP wire semantic PASS: {len(reports)} full responses; v1/community/PDU/request-id/error/VarBind/peer/IP+UDP checks passed")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AssertionError, ValueError, struct.error) as exc:
        print(f"SNMP wire semantic FAIL: {exc}", file=sys.stderr)
        raise SystemExit(1)
