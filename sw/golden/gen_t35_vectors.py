#!/usr/bin/env python3
"""Generate deterministic real Ethernet frames for T35 full RX-index exercise."""
import csv
import hashlib
import sys
from pathlib import Path

from afdx_model import build_frame

ROOT = Path(__file__).resolve().parents[2]
VEC = ROOT / "sim" / "vec"
N = 4096
PORT = 5
COOKIE_BASE = 0x35C00000


def generate():
    VEC.mkdir(parents=True, exist_ok=True)
    image = VEC / "t12_top.img.hex"
    meta = VEC / "t12_top.meta.hex"
    if not image.is_file() or not meta.is_file():
        raise SystemExit("T35 requires gen_t12_vectors.py outputs t12_top image/meta")
    words = [int(x, 16) for x in image.read_text(encoding="ascii").splitlines()
             if x and not x.startswith("//")]
    if len(words) != 8192:
        raise SystemExit("T35 hash image must contain 8192 words")
    # Index and VLID are deliberately identical: the independently generated
    # full image maps every VLID 0..4095 to exactly one physical RX index.
    out = VEC / "t35_frames.hex"
    mapping = VEC / "t35_mapping.csv"
    digest = hashlib.sha256()
    with mapping.open("w", newline="", encoding="ascii") as mf, out.open("w", encoding="ascii", newline="\n") as vf:
        wr = csv.writer(mf, lineterminator="\n")
        wr.writerow(("index", "vlid", "port", "cookie", "payload_hex"))
        vf.write("// T35 record: frame byte length, then 20 big endian words for A and 20 for B\n")
        vf.write("00001000\n")
        for idx in range(N):
            cookie = COOKIE_BASE ^ ((idx * 0x9E3779B1) & 0xFFFFFFFF)
            sentinel = 0xA55A ^ idx
            payload = idx.to_bytes(2, "big") + cookie.to_bytes(4, "big") + sentinel.to_bytes(2, "big")
            wr.writerow((idx, f"0x{idx:04X}", PORT, f"0x{cookie:08X}", payload.hex()))
            frames = []
            for ifid in (1, 2):
                frame, _ = build_frame(idx, 0x1234, ifid, ifid,
                    "10.0.0.1", "224.0.0.1", 49152, 5000, payload,
                    1, ident=idx + 1, fcs_mode=2, udp_csum_mode=1)
                assert len(frame) == 64
                # Parse independently to ensure both protocol checksums and FCS.
                from afdx_model import parse_frame
                parsed = parse_frame(frame)
                from afdx_model import ones_comp16
                assert parsed["fcs_ok"] and ones_comp16(frame[14:34]) == 0 and parsed["udp_csum_ok"]
                frames.append(frame)
            vf.write("00000040\n")
            for frame in frames:
                digest.update(frame)
                padded = frame.ljust(80, b"\0")
                for off in range(0, 80, 4):
                    vf.write(f"{int.from_bytes(padded[off:off+4], 'big'):08X}\n")
    frame_sha = digest.hexdigest()
    (VEC / "t35_frames.sha256").write_text(frame_sha + "  t35_frames(A+B)\n", encoding="ascii")
    print(f"T35 VECTOR PASS: rx_vl=4096 frames=8192 frame_sha256={frame_sha}")


if __name__ == "__main__":
    generate()
