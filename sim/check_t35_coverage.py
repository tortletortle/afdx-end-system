#!/usr/bin/env python3
"""Independent T35 public-host delivery and 4096-bit coverage audit."""
import argparse
import csv
import hashlib
import json
import re
import struct
import zlib
from pathlib import Path

N = 4096
PORT = 5
COOKIE_BASE = 0x35C00000
COOKIE_STEP = 0x9E3779B1


def valid_checksum(data):
    if len(data) & 1:
        data += b"\0"
    total = sum(int.from_bytes(data[i:i + 2], "big")
                for i in range(0, len(data), 2))
    while total >> 16:
        total = (total & 0xFFFF) + (total >> 16)
    return total == 0xFFFF


def check_frame(frame, idx, net, expected_payload):
    if len(frame) != 64:
        return "frame is not exactly 64 bytes"
    if frame[:4] != b"\x03\x00\x00\x00" or int.from_bytes(frame[4:6], "big") != idx:
        return "destination MAC/VLID does not match index"
    expected_smac = bytes.fromhex("0200001234") + bytes((0x20 if net == 0 else 0x40,))
    if frame[6:12] != expected_smac or frame[12:14] != b"\x08\x00":
        return "source MAC or EtherType mismatch"
    if frame[14] != 0x45 or frame[23] != 17 or int.from_bytes(frame[16:18], "big") != 36:
        return "IPv4 version/protocol/length mismatch"
    if not valid_checksum(frame[14:34]):
        return "IPv4 header checksum invalid"
    if frame[26:34] != bytes((10, 0, 0, 1, 224, 0, 0, 1)):
        return "IPv4 source/destination mismatch"
    udp = frame[34:50]
    if int.from_bytes(udp[0:2], "big") != 49152 or int.from_bytes(udp[2:4], "big") != 5000:
        return "UDP source/destination port mismatch"
    if int.from_bytes(udp[4:6], "big") != 16 or udp[8:16] != expected_payload:
        return "UDP length/payload mismatch"
    pseudo = frame[26:34] + bytes((0, 17)) + struct.pack("!H", len(udp))
    if not valid_checksum(pseudo + udp):
        return "UDP checksum invalid"
    if frame[59] != 1:
        return "sequence number is not 1"
    if (zlib.crc32(frame[:60]) & 0xFFFFFFFF) != int.from_bytes(frame[60:64], "little"):
        return "Ethernet FCS invalid"
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("console", type=Path)
    ap.add_argument("--mapping", type=Path, required=True)
    ap.add_argument("--frames-hash", type=Path, required=True)
    ap.add_argument("--frames", type=Path, required=True)
    ap.add_argument("--out-dir", type=Path, required=True)
    ap.add_argument("--phy-a", type=Path)
    ap.add_argument("--phy-b", type=Path)
    ap.add_argument("--cycles-a", type=Path)
    ap.add_argument("--cycles-b", type=Path)
    args = ap.parse_args()
    lines = args.console.read_text(encoding="utf-8", errors="replace").splitlines()
    with args.mapping.open(encoding="ascii", newline="") as mf:
        mapping = list(csv.DictReader(mf))
    if len(mapping) != N or [int(x["index"]) for x in mapping] != list(range(N)):
        raise SystemExit("T35 mapping is not a complete ordered 4096-index map")
    for idx, row in enumerate(mapping):
        cookie = COOKIE_BASE ^ ((idx * COOKIE_STEP) & 0xFFFFFFFF)
        payload = idx.to_bytes(2, "big") + cookie.to_bytes(4, "big") + (0xA55A ^ idx).to_bytes(2, "big")
        if (int(row["vlid"], 0) != idx or int(row["port"]) != PORT or
                int(row["cookie"], 0) != cookie or row["payload_hex"].upper() != payload.hex().upper()):
            raise SystemExit(f"T35 mapping row {idx} does not match the independent stimulus formula")

    vector_lines = args.frames.read_text(encoding="ascii").splitlines()
    try:
        words = [int(line.strip(), 16) for line in vector_lines
                 if line.strip() and not line.lstrip().startswith("//")]
    except ValueError as exc:
        raise SystemExit(f"T35 vector contains a malformed word: {exc}")
    words_per_record = 1 + 2 * 20
    if len(words) != 1 + N * words_per_record or words[0] != N:
        raise SystemExit("T35 vector does not contain exactly 4096 complete A/B records")
    vector_digest = hashlib.sha256()
    for idx, row in enumerate(mapping):
        base = 1 + idx * words_per_record
        if words[base] != 64:
            raise SystemExit(f"T35 vector index {idx} has a non-64-byte frame length")
        expected_payload = bytes.fromhex(row["payload_hex"])
        for net in (0, 1):
            first = base + 1 + net * 20
            frame = b"".join(word.to_bytes(4, "big") for word in words[first:first + 16])
            problem = check_frame(frame, idx, net, expected_payload)
            if problem:
                raise SystemExit(f"T35 vector index {idx} network {net}: {problem}")
            vector_digest.update(frame)
    hash_record = args.frames_hash.read_text(encoding="ascii").strip()
    if not hash_record.startswith(vector_digest.hexdigest() + "  "):
        raise SystemExit("T35 raw-frame SHA256 does not match the simulator vector contents")

    records = []
    for line in lines:
        m = re.search(r"T35_DELIVERY index=(\d+) cookie=([0-9A-Fa-f]{8}) port=(\d+) payload=([0-9A-Fa-f]+)", line)
        if m:
            records.append((int(m[1]), int(m[2], 16), int(m[3]), m[4].upper()))
    verdicts = [re.search(r"^#?\s*T35 RX4096 PASS IF_MODE=(\d+) requested=(\d+) covered=(\d+) inputA=(\d+) inputB=(\d+) unique=(\d+) duplicate=(\d+) drops=(\d+)\s*$", x) for x in lines]
    verdicts = [x for x in verdicts if x]
    if len(verdicts) != 1:
        raise SystemExit(f"expected one T35 summary, found {len(verdicts)}")
    mode, requested, covered, ina, inb, unique, dup, drops = map(int, verdicts[0].groups())
    if mode not in (0,1,2):
        raise SystemExit("unsupported interface mode")
    phy_evidence={}
    if mode==2:
        for net,(capture,timing) in enumerate(((args.phy_a,args.cycles_a),(args.phy_b,args.cycles_b))):
            if capture is None or timing is None:
                raise SystemExit("PHY mode requires actual A/B input and cycle captures")
            actual=[bytes.fromhex(row) for row in capture.read_text(encoding='ascii').splitlines()]
            cycles=[tuple(map(int,row.split())) for row in timing.read_text(encoding='ascii').splitlines()]
            if len(actual)!=requested or len(cycles)!=requested:
                raise SystemExit("PHY capture does not contain every selected index")
            last_end=None
            for idx,(raw,ends) in enumerate(zip(actual,cycles)):
                first=2+idx*words_per_record+net*20
                golden=b''.join(word.to_bytes(4,'big') for word in words[first:first+16])
                if raw!=b'\x55'*7+b'\xd5'+golden:
                    raise SystemExit(f"PHY actual index{idx} net{net} bytes/order mismatch")
                if len(ends)!=2 or ends[1]-ends[0]+1!=72 or (last_end is not None and ends[0]-last_end-1<12):
                    raise SystemExit(f"PHY actual index{idx} net{net} continuity/IFG mismatch")
                last_end=ends[1]
            phy_evidence[str(net)]={'frames':len(actual),'bytes':sum(map(len,actual)),
                                    'capture_sha256':hashlib.sha256(capture.read_bytes()).hexdigest(),
                                    'cycles_sha256':hashlib.sha256(timing.read_bytes()).hexdigest()}
    if requested not in (16, 256, N):
        raise SystemExit(f"unsupported requested coverage {requested}")
    consistency_errors = []
    if len(records) != requested or covered != requested or unique != requested:
        consistency_errors.append("delivery record count does not match requested coverage")
    seen = [0] * 4096
    out = args.out_dir
    out.mkdir(parents=True, exist_ok=True)
    observed = {}
    errors = consistency_errors
    for idx, cookie, port, payload in records:
        observed.setdefault(idx, []).append((cookie, port, payload))
        if idx >= requested:
            errors.append(f"out-of-range delivery index {idx}")
    with (out / "deliveries.csv").open("w", newline="", encoding="ascii") as f:
        w = csv.writer(f, lineterminator="\n")
        w.writerow(("index", "expected_count", "observed_count", "expected_cookie", "observed_cookie", "port", "expected_payload_hex", "observed_payload_hex", "result"))
        for idx, expected in enumerate(mapping):
            exp_count = 1 if idx < requested else 0
            got = observed.get(idx, [])
            seen[idx] = 1 if got else 0
            expected_cookie = int(expected["cookie"], 16)
            expected_payload = expected["payload_hex"].upper()
            good = len(got) == exp_count
            obs_cookie = got[0][0] if got else ""
            obs_port = got[0][1] if got else ""
            obs_payload = got[0][2] if got else ""
            if exp_count and got and (obs_cookie != expected_cookie or obs_port != int(expected["port"]) or obs_payload != expected_payload):
                good = False
            if not good:
                errors.append(f"index {idx}: expected_count={exp_count} observed_count={len(got)}")
            w.writerow((idx, exp_count, len(got), f"0x{expected_cookie:08X}",
                        f"0x{obs_cookie:08X}" if obs_cookie != "" else "", obs_port,
                        expected_payload, obs_payload, "PASS" if good else "FAIL"))
    if seen[:requested] != [1] * requested or seen[requested:] != [0] * (4096-requested):
        errors.append("4096-index coverage bitmap does not match selected run")
    if ina != requested or inb != requested or dup != requested or drops != 0:
        errors.append("A/B frame totals, expected duplicate count, or unexplained drops are inconsistent")
    bitmap = bytes(sum((seen[b+i] << i) for i in range(8)) for b in range(0, 4096, 8))
    (out / "coverage_bitmap.bin").write_bytes(bitmap)
    # Mapping supplied to the simulator is retained beside the audited records.
    (out / "mapping.csv").write_bytes(args.mapping.read_bytes())
    report = {
        "test": "T35", "if_mode": mode, "requested": requested,
        "covered": covered, "input_frames_a": ina, "input_frames_b": inb,
        "unique_deliveries": unique, "duplicate_deliveries": dup,
        "drops": drops, "coverage_bits": sum(seen),
        "coverage_bitmap_sha256": hashlib.sha256(bitmap).hexdigest(),
        "frames_sha256_record": hash_record,
        "frames_vector_sha256": hashlib.sha256(args.frames.read_bytes()).hexdigest(),
        "mapping_sha256": hashlib.sha256(args.mapping.read_bytes()).hexdigest(),
        "console_sha256": hashlib.sha256(args.console.read_bytes()).hexdigest(),
        "phy_input": phy_evidence,
    }
    (out / "coverage_check.json").write_text(json.dumps(report, indent=2)+"\n", encoding="utf-8")
    if errors:
        raise SystemExit("T35 coverage audit failed: " + "; ".join(errors[:12]))
    print(f"T35_COVERAGE_AUDIT ok=1 covered={requested}/4096 A={ina} B={inb} bitmap_sha256={report['coverage_bitmap_sha256']}")


if __name__ == "__main__":
    main()
