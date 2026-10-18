#!/usr/bin/env python3
"""Independent RX8K GMII vectors. No HDL tools or existing vector writes.

AFDX frame length excludes 8-byte GMII preamble/SFD and includes SN/FCS.
UDP checksum covers the complete datagram before IP fragmentation.
All generated files must be under the project out/ tree; existing evidence is never overwritten.
"""
import argparse
from dataclasses import dataclass, field
import hashlib
import json
from pathlib import Path
import struct
import zlib

DELIVERY = "rx8k_gmii_20261012_r1"
ROOT = Path(__file__).resolve().parents[2]
SRC = bytes((10, 0, 0, 153))
DST = bytes((10, 0, 0, 2))
MAGIC, SCHEMA, CHUNK, GAP = 0x5258384B, 1, 1400, 12000
LENGTHS = (2006, 2007, 8150, 8151, 8191, 8192)


def payload(n, salt):
    return bytes((i * 73 + (i // 7) * 29 + (i // 257) * 11 + 0x3D + salt) & 255
                 for i in range(n))


def checksum(data):
    data += bytes(len(data) & 1)
    acc = sum(int.from_bytes(data[i:i+2], "big") for i in range(0, len(data), 2))
    while acc >> 16:
        acc = (acc & 0xFFFF) + (acc >> 16)
    return (~acc) & 0xFFFF


def serial_sum(data):
    # Separate incremental implementation for the serialized-byte oracle.
    acc = 0
    for i in range(0, len(data), 2):
        acc += (data[i] << 8) | (data[i+1] if i+1 < len(data) else 0)
        acc = (acc & 65535) + (acc >> 16)
    return (acc & 65535) + (acc >> 16)


def udp(app, dport=5000):
    n = len(app) + 8
    pseudo = SRC + DST + struct.pack("!BBH", 0, 17, n)
    h = struct.pack("!HHHH", 12345, dport, n, 0)
    c = checksum(pseudo + h + app) or 0xFFFF
    return h[:6] + struct.pack("!H", c) + app


class Frames:
    def __init__(self):
        self.sn = {5: 0, 6: 0}

    def frame(self, data, ident, off, mf, vl=5):
        assert off % 8 == 0 and (not mf or len(data) % 8 == 0)
        self.sn[vl] = self.sn[vl] % 255 + 1
        h = struct.pack("!BBHHHBBH4s4s", 0x45, 0, 20+len(data), ident,
                        (0x2000 if mf else 0) | off//8, 64, 17, 0, SRC, DST)
        h = h[:10] + struct.pack("!H", checksum(h)) + h[12:]
        dmac = bytes((3, 0, 0, 0, 0, vl))
        smac = bytes((2, 0, 0, 0, vl, 0x20))
        body = dmac + smac + bytes.fromhex("0800") + h + data
        body += bytes(max(0, 59-len(body))) + bytes((self.sn[vl],))
        return body + struct.pack("<I", zlib.crc32(body) & 0xFFFFFFFF)

    def pieces(self, datagram, ident, order="in_order", vl=5):
        parts = [(off, datagram[off:off+CHUNK]) for off in range(0, len(datagram), CHUNK)]
        indices = list(range(len(parts)))
        if order == "tail_first":
            indices = [indices[-1]] + indices[:-1]
        elif order == "shuffled":
            indices = indices[1::2] + indices[::2]
        elif order != "in_order":
            raise ValueError(order)
        return [self.frame(parts[i][1], ident, parts[i][0], i != len(parts)-1, vl)
                for i in indices]


@dataclass
class Case:
    name: str
    kind: int
    app: bytes
    salt: int
    frames: list
    ident: int
    order: str = "in_order"
    port: int = 5
    vl: int = 5
    bg_apps: list = field(default_factory=list)
    note: str = "deliver through public host descriptor/aperture/PMEM"


def decode_frame(frame, ip_good=True):
    assert 64 <= len(frame) <= 1518
    assert int.from_bytes(frame[-4:], "little") == zlib.crc32(frame[:-4]) & 0xFFFFFFFF
    assert frame[12:14] == bytes.fromhex("0800")
    ip = frame[14:34]
    assert (serial_sum(ip) == 65535) == ip_good
    n = int.from_bytes(ip[2:4], "big")
    assert len(frame) == max(64, 14+n+5)
    pad = max(0, 59-(14+n))
    assert frame[14+n:14+n+pad] == bytes(pad)
    assert frame[14+n+pad] != 0
    flags = int.from_bytes(ip[6:8], "big")
    data = frame[34:14+n]
    if flags & 0x2000:
        assert len(data) % 8 == 0
    return (flags & 0x1FFF)*8, bool(flags & 0x2000), data


def verify_datagram(frames, app, good=True, zero=False):
    cursor, assembled = 0, bytearray()
    pieces = sorted(decode_frame(f) for f in frames)
    for off, mf, data in pieces:
        assert off == cursor
        assembled.extend(data)
        cursor += len(data)
        assert mf == (off + len(data) != len(app)+8)
    assert assembled[8:] == app and len(assembled) == len(app)+8
    assert int.from_bytes(assembled[4:6], "big") == len(assembled)
    pseudo = SRC + DST + struct.pack("!BBH", 0, 17, len(assembled))
    valid = serial_sum(pseudo + assembled) == 65535 and assembled[6:8] != bytes(2)
    assert valid == good
    if zero:
        assert assembled[6:8] == bytes(2)
    return bytes(assembled)


def build_cases(suite):
    f = Frames()
    cases = []
    def positive(n, order, salt):
        ident = 0x8000 + len(cases)
        app = payload(n, salt)
        frames = f.pieces(udp(app), ident, order)
        verify_datagram(frames, app)
        cases.append(Case(f"len_{n}_{order}", 0, app, salt, frames, ident, order))
    positive(8192, "in_order", 0)
    if suite == "full":
        for n in LENGTHS:
            for order in ("in_order", "tail_first", "shuffled"):
                if (n, order) != (8192, "in_order"):
                    positive(n, order, len(cases)*7)
        for kind, name in ((1, "bad_udp_checksum"), (2, "zero_udp_checksum"),
                           (10, "zero_checksum_policy_disabled")):
            app = payload(8192, 19 + kind)
            dgram = bytearray(udp(app))
            if kind == 1:
                c = int.from_bytes(dgram[6:8], "big") ^ 1
                dgram[6:8] = (c or 2).to_bytes(2, "big")
            else:
                dgram[6:8] = bytes(2)
            ident = 0x8000 + len(cases)
            frames = f.pieces(bytes(dgram), ident, "tail_first")
            verify_datagram(frames, app, good=False, zero=kind != 1)
            cases.append(Case(name, kind, app, 19 + kind, frames, ident, "tail_first",
                              note="reject with check enabled; kind 10 delivers with the explicit host checksum policy disabled"))
        app = payload(8192, 33)
        ident = 0x8000 + len(cases)
        dgram = udp(app)
        frames = [f.frame(dgram[:CHUNK], ident, 0, True),
                  f.frame(dgram[1392:2792], ident, 1392, True)]
        a, b = [decode_frame(x) for x in frames]
        assert a[0] + len(a[2]) > b[0] and b[0] == 1392
        cases.append(Case("overlap_reclaims_context", 3, app, 33, frames, ident,
                          note="second fragment overlaps by eight wire bytes; no descriptor, complete reclaim"))
        app = payload(8192, 44)
        ident = 0x8000 + len(cases)
        bg_apps = [payload(64, 90+i) for i in range(5)]
        frames = [f.frame(udp(a, 5001), 0x9000+i, 0, False, 6)
                  for i, a in enumerate(bg_apps)]
        for frame, a in zip(frames, bg_apps):
            verify_datagram([frame], a)
        frames.append(f.frame(udp(app)[:CHUNK], ident, 0, True))
        recovery = f.pieces(udp(app), ident+0x100, "shuffled")
        verify_datagram(recovery, app)
        frames += recovery
        cases.append(Case("atomic_pool_exhaustion_sparse_recovery", 4, app, 44, frames, ident,
                          "shuffled", bg_apps=bg_apps,
                          note="hold five queue singletons, reject five-block allocation, release two, deliver sparse chain while three heads remain live"))
        for kind, name, prefix_count in ((5, "disable_incomplete_context", 1),
                                         (6, "disable_accepted_copy", 1),
                                         (7, "disable_accepted_checker", 6),
                                         (8, "reset_accepted_copy", 1),
                                         (9, "reset_accepted_checker", 6)):
            app = payload(8192, 50+kind)
            ident = 0x8000 + len(cases)
            prefix = (f.pieces(udp(app), ident) if prefix_count == 6 else
                      [f.frame(udp(app)[:CHUNK], ident, 0, True)])
            recovery = f.pieces(udp(app), ident+0x100, "tail_first")
            verify_datagram(recovery, app)
            if prefix_count == 6:
                verify_datagram(prefix, app)
            cases.append(Case(name, kind, app, 50+kind, prefix+recovery, ident,
                              "tail_first", note="cancel/reset the indicated live phase; no partial delivery; recover by full GMII replay"))
    # Check the actual transmitted sequence, including deliberately incomplete
    # lifecycle datagrams. Generating then discarding frames would create an
    # unintended IC gap and prevent the intended recovery path from executing.
    last_sn = {}
    for case in cases:
        for frame in case.frames:
            vl, sn = frame[5], frame[-5]
            if vl in last_sn:
                assert sn == last_sn[vl] % 255 + 1, (case.name, vl, last_sn[vl], sn)
            last_sn[vl] = sn
    return cases


def hash_bucket(vlid, seed, table):
    x = (vlid + seed + (0x1F5B if table else 0x9E37)) & 65535
    x ^= x >> 7
    x = (x * (0x45D9 if table else 0x9E37)) & 65535
    x ^= x >> 9
    return x & 2047


def serialize(cases):
    words = [MAGIC, SCHEMA, len(cases), 0, 0]
    expected = bytearray()
    records = []
    for ci, case in enumerate(cases):
        app_base = len(expected)
        expected.extend(case.app)
        bg_base = len(expected)
        for app in case.bg_apps:
            expected.extend(app)
        bg_len = len(case.bg_apps[0]) if case.bg_apps else 0
        assert all(len(a) == bg_len for a in case.bg_apps)
        words += [case.kind, len(case.app), case.salt, len(case.frames), case.port,
                  case.vl, case.ident, app_base, bg_base, bg_len, len(case.bg_apps)]
        for frame in case.frames:
            wire = bytes.fromhex("55555555555555d5") + frame
            words += [len(frame), GAP]
            wire += bytes((-len(wire)) % 4)
            words += [int.from_bytes(wire[i:i+4], "big") for i in range(0, len(wire), 4)]
        records.append({"index": ci, "name": case.name, "kind": case.kind,
                        "app_length": len(case.app), "chain_count": (42+len(case.app)+2047)//2048,
                        "salt": case.salt, "ident": case.ident, "arrival": case.order,
                        "frame_count": len(case.frames), "expected_base": app_base,
                        "bg_base": bg_base, "bg_length": bg_len, "bg_count": len(case.bg_apps),
                        "frame_lengths": [len(x) for x in case.frames],
                        "frames_sha256": [hashlib.sha256(x).hexdigest() for x in case.frames],
                        "payload_sha256": hashlib.sha256(case.app).hexdigest(), "note": case.note})
    words[3], words[4] = len(words), len(expected)
    assert len(words) < 131072 and len(expected) < 524288
    return words, bytes(expected), records


def verify_serialized(words, expected, cases):
    assert words[:3] == [MAGIC, SCHEMA, len(cases)]
    assert words[3:] and words[3] == len(words) and words[4] == len(expected)
    pos = 5
    for case in cases:
        hdr = words[pos:pos+11]
        pos += 11
        assert hdr[0:4] == [case.kind, len(case.app), case.salt, len(case.frames)]
        assert expected[hdr[7]:hdr[7]+hdr[1]] == case.app
        for frame in case.frames:
            n, gap = words[pos:pos+2]
            pos += 2
            nw = (n+11)//4
            wire = b"".join(x.to_bytes(4, "big") for x in words[pos:pos+nw])
            pos += nw
            assert n == len(frame) and gap == GAP
            assert wire[:8] == bytes.fromhex("55555555555555d5")
            assert wire[8:8+n] == frame and wire[8+n:] == bytes(len(wire)-8-n)
    assert pos == len(words)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--suite", choices=("minimal", "full"), default="minimal")
    ap.add_argument("--out-dir", type=Path, default=ROOT / "out" / DELIVERY / "vectors" / "minimal")
    ap.add_argument("--verify-only", action="store_true")
    args = ap.parse_args()
    out = args.out_dir.resolve()
    if not out.is_relative_to((ROOT / "out").resolve()) or out == (ROOT / "out").resolve():
        ap.error("out-dir must stay in a child directory of the project out/ tree")
    cases = build_cases(args.suite)
    words, expected, records = serialize(cases)
    verify_serialized(words, expected, cases)
    image = [0]*8192
    for vl in (5, 6):
        slot = hash_bucket(vl, 0x172D, 0)*2
        assert not image[slot]
        image[slot] = (1 << 28) | (vl << 12) | vl
    files = {
        "rx8k_gmii.hex": "".join(f"{w:08X}\n" for w in words),
        "expected_app.hex": "".join(f"{b:02X}\n" for b in expected),
        "hash_img.hex": "".join(f"{w:08X}\n" for w in image),
        "hash_meta.hex": "0000172D\n0000AB61\n00001000\n00000800\n",
    }
    manifest = {"schema": SCHEMA, "suite": args.suite, "case_count": len(cases),
                "vector_words": len(words), "expected_bytes": len(expected),
                "fragment_ip_data_max": CHUNK, "inter_fragment_idle_cycles": GAP,
                "validation": "serialized IP/FCS/UDP/content and offset oracle; HDL NOT_RUN",
                "cases": records, "sha256": {n: hashlib.sha256(s.encode("ascii")).hexdigest()
                                              for n, s in files.items()}}
    files["manifest.json"] = json.dumps(manifest, indent=2) + "\n"
    if args.verify_only:
        for name, content in files.items():
            assert (out/name).read_bytes() == content.encode("ascii"), name
    else:
        out.mkdir(parents=True, exist_ok=True)
        for name in files:
            if (out/name).exists():
                ap.error("refusing to overwrite existing vector evidence: " + str(out/name))
        for name, content in files.items():
            (out/name).write_bytes(content.encode("ascii"))
    print(f"RX8K GOLDEN PASS suite={args.suite} cases={len(cases)} words={len(words)} bytes={len(expected)}; HDL NOT_RUN")


if __name__ == "__main__":
    main()
