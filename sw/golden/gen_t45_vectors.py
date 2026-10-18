#!/usr/bin/env python3
"""T45 top-level TFTP timeout/backpressure contract vectors (P02).

Scenario (all frames are independent constructions; nothing is derived from
DUT output):
  R0  WRQ "UPLOAD" from TID 49152      -> ACK(0)
  R1..R5 DATA(1..5), 512 B patterns    -> ACK(k)
  R6  DATA(6) 513 B (over-long)        -> ERROR(4) and session close
  R7  DATA(7) 8 B, no session          -> ERROR(5)
  R8  malformed 5-byte ACK, no session -> ERROR(5)
  R9  WRQ2 from TID 49153              -> ACK(0)
  R10 DATA2(1) 512 B                   -> ACK(1)
  R11 DATA2(2) 8 B final               -> ACK(2)

Response candidate table: ACK(0..5), ERROR(4), ERROR(5), event SN 1..28,
for both session TIDs (49152, 49153) and both networks (A ifid=1, B ifid=2).
Layout (hex words, big-endian):
  [0]=45 [1]=NT [2]=MAXS [3]=NR [4]=crc1 [5]=crc2 [6]=len1 [7]=len2
  [8]=IDX_BASE [9]=REQ_BASE
  [10 .. IDX_BASE-1]  request index pairs: (len, abs word offset)
  [IDX_BASE .. REQ_BASE-1]  response index: 2(TID)*NT*2(net)*MAXS offsets,
      row key = ((tid_index*NT + type)*2 + net), entry s-1 = event index
  [REQ_BASE ..]       records: [len][packed frame bytes ...]
"""
import json
import sys
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "sw" / "golden"))
from afdx_model import build_frame, parse_frame  # noqa: E402

OUT = ROOT / "sim" / "vec"

NT = 8
MAXS = 28
NR = 12

P512 = [bytes((i * 7 + (k + 1) * 0x21) & 0xFF for i in range(512)) for k in range(6)]
F8 = bytes((i * 13 + 0x5A) & 0xFF for i in range(8))
Q1 = bytes((i * 11 + 0x63) & 0xFF for i in range(512))
Q2 = bytes((i * 17 + 0x2D) & 0xFF for i in range(8))

IMAGE1 = b"".join(P512[0:5])
IMAGE2 = Q1 + Q2
CRC1 = zlib.crc32(IMAGE1) & 0xFFFF_FFFF
CRC2 = zlib.crc32(IMAGE2) & 0xFFFF_FFFF


def tftp_rq(op, name, mode=b"octet"):
    return bytes([0, op]) + name + b"\x00" + mode + b"\x00"


def tftp_data(blk, payload):
    return bytes([0, 3, (blk >> 8) & 0xFF, blk & 0xFF]) + bytes(payload)


def ack(blk):
    return bytes([0, 4, (blk >> 8) & 0xFF, blk & 0xFF])


def error_payload(code):
    return bytes([0, 5, (code >> 8) & 0xFF, code & 0xFF]) + b"TFTP ERR\x00"


def request(payload, sn, sport=49152):
    data, _ = build_frame(0x100, 0x1234, 1, 1, "10.0.0.1", "224.0.0.1",
                          sport, 5000, payload, 1, ident=7)
    data = data[:-5] + bytes((sn,))
    return data + zlib.crc32(data).to_bytes(4, "little")


def response(payload, sn, net, dport=49152):
    data, _ = build_frame(0x100, 0x172D, net + 1, net + 1,
                          "10.0.0.2", "10.0.0.1", 5000, dport,
                          payload, sn, ident=0, tos=0, ttl=255)
    return data


TIDS = (49152, 49153)   # dimension 0: WRQ1/DATA/…, dimension 1: WRQ2/DATA2


def pack_record(frame):
    words = [len(frame)]
    words.extend(int.from_bytes(frame[i:i + 4].ljust(4, b"\0"), "big")
                 for i in range(0, len(frame), 4))
    return words


def main():
    requests = [
        (0, "wrq1", tftp_rq(2, b"UPLOAD"), 49152),
        (1, "data1", tftp_data(1, P512[0]), 49152),
        (2, "data2", tftp_data(2, P512[1]), 49152),
        (3, "data3", tftp_data(3, P512[2]), 49152),
        (4, "data4", tftp_data(4, P512[3]), 49152),
        (5, "data5", tftp_data(5, P512[4]), 49152),
        (6, "data6_513", tftp_data(6, P512[5] + b"\xEE"), 49152),
        (7, "data7_nosess", tftp_data(7, F8), 49152),
        (8, "ack_malformed", ack(5) + b"\x00", 49152),
        (9, "wrq2", tftp_rq(2, b"UPLOAD"), 49153),
        (10, "data2_1", tftp_data(1, Q1), 49153),
        (11, "data2_2", tftp_data(2, Q2), 49153),
    ]
    assert len(requests) == NR

    types = [ack(0), ack(1), ack(2), ack(3), ack(4), ack(5),
             error_payload(4), error_payload(5)]

    idx_base = 10 + 2 * NR                      # 34
    req_base = idx_base + 2 * NT * 2 * MAXS     # 34 + 896 = 930

    # request records with frames built (SN 1..NR)
    req_frames = []
    for rid, _name, payload, sport in requests:
        frame = request(payload, rid + 1, sport)
        decoded = parse_frame(frame)
        assert decoded["fcs_ok"] and decoded["udp_csum_ok"], rid
        req_frames.append(frame)

    out = [45, NT, MAXS, NR, CRC1, CRC2, len(IMAGE1), len(IMAGE2),
           idx_base, req_base]
    out += [0] * (idx_base - len(out))     # placeholder for req index pairs

    cursor = req_base
    index_pairs = []
    for frame in req_frames:
        index_pairs.append((len(frame), cursor))
        cursor += 1 + (len(frame) + 3) // 4

    resp_frames = []
    resp_flat = []
    for tid in TIDS:
        for t in range(NT):
            for net in range(2):
                for s in range(1, MAXS + 1):
                    frame = response(types[t], s, net, dport=tid)
                    decoded = parse_frame(frame)
                    assert decoded["fcs_ok"] and decoded["udp_csum_ok"], (tid, t, net, s)
                    resp_flat.append(cursor)
                    cursor += 1 + (len(frame) + 3) // 4
                    resp_frames.append(frame)

    # fill request index pairs
    for i, pair in enumerate(index_pairs):
        out[10 + 2 * i] = pair[0]
        out[10 + 2 * i + 1] = pair[1]
    assert len(out) == idx_base
    out += resp_flat
    assert len(out) == req_base
    for frame in req_frames:
        out += pack_record(frame)
    for frame in resp_frames:
        out += pack_record(frame)

    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "t45_contract.hex").write_text(
        "".join(f"{w:08x}\n" for w in out), encoding="ascii")
    (OUT / "t45_contract.vh").write_text(
        f"`define T45_WORDS {len(out)}\n"
        f"`define T45_NT {NT}\n"
        f"`define T45_MAXS {MAXS}\n"
        f"`define T45_NR {NR}\n"
        f"`define T45_IDX_BASE {idx_base}\n"
        f"`define T45_REQ_BASE {req_base}\n", encoding="ascii")
    meta = {
        "requests": [{"id": rid, "name": name, "bytes": len(f)}
                     for (rid, name, _p, _s), f in zip(requests, req_frames)],
        "nt": NT, "maxs": MAXS, "words": len(out),
        "image1_len": len(IMAGE1), "image1_crc": f"{CRC1:08x}",
        "image2_len": len(IMAGE2), "image2_crc": f"{CRC2:08x}",
    }
    (OUT / "t45_contract.json").write_text(
        json.dumps(meta, indent=2) + "\n", encoding="utf-8")
    print(f"T45 vectors: {NR} requests, {NT}x{MAXS} response candidates, "
          f"{len(out)} words; crc1={CRC1:08x} crc2={CRC2:08x}")


if __name__ == "__main__":
    main()
