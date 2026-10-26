#!/usr/bin/env python3
"""Generate independent T91 payload golden (hex mem for TB $readmemh).

Formula lives ONLY here (and is reimported by t91_metrics_check).
TB must not invent the expected bytes; it loads sim/vec/t91_payload.hex.

Layout: for vl in 0..NVL_MAX-1, round in 0..ROUNDS_MAX-1, off in 0..PLEN-1
  linear = ((vl * ROUNDS_MAX) + round) * PLEN + off
  packed little-endian into 32-bit words (Verilog $readmemh style: one word/line).
"""
from __future__ import annotations

import argparse
from pathlib import Path

NVL_MAX = 16
ROUNDS_MAX = 8
PLEN = 1024


def payload_byte(vl: int, round_: int, off: int) -> int:
    return (vl * 17 + round_ * 29 + off * 13 + 0x53) & 0xFF


def linear_index(vl: int, round_: int, off: int) -> int:
    return ((vl * ROUNDS_MAX) + round_) * PLEN + off


def expected_bytes(nvl: int, rounds: int) -> bytes:
    out = bytearray(NVL_MAX * ROUNDS_MAX * PLEN)
    for vl in range(nvl):
        for r in range(rounds):
            for off in range(PLEN):
                out[linear_index(vl, r, off)] = payload_byte(vl, r, off)
    return bytes(out)


def write_hex(path: Path, blob: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = []
    # pad to word
    if len(blob) % 4:
        blob = blob + bytes(4 - (len(blob) % 4))
    for i in range(0, len(blob), 4):
        w = (
            (blob[i] << 24)
            | (blob[i + 1] << 16)
            | (blob[i + 2] << 8)
            | blob[i + 3]
        )
        lines.append(f"{w:08X}")
    path.write_text("\n".join(lines) + "\n", encoding="ascii")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--out",
        type=Path,
        default=Path("sim/vec/t91_payload.hex"),
        help="hex mem path (default sim/vec/t91_payload.hex)",
    )
    ap.add_argument("--nvl", type=int, default=NVL_MAX)
    ap.add_argument("--rounds", type=int, default=ROUNDS_MAX)
    args = ap.parse_args()
    blob = expected_bytes(args.nvl, args.rounds)
    write_hex(args.out, blob)
    print(f"WROTE {args.out} bytes={len(blob)} nvl={args.nvl} rounds_cap={args.rounds}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
