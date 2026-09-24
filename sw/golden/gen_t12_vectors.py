#!/usr/bin/env python3
"""Deterministic T12 lookup images, independent keys and fail-closed checks.

T12c: 4096 consecutive IDs; T12r: 4096 distinct random IDs; T12s: small
32-bucket table including four keys sharing the same bucket pair. T12h
includes a fifth key in that pair, forcing a second seed pair to succeed;
another four-key cluster under the new seeds fills all four RAM ways.
"""
from collections import defaultdict
from pathlib import Path
import random
import subprocess
import sys
import tempfile

from hash_seed import (BASE_SEED0, BASE_SEED1, PlacementError, bucket, place,
                       write_image, verify)

ROOT = Path(__file__).resolve().parents[2]
VEC = ROOT / "sim" / "vec"


def collision_group(buckets, count=5):
    groups = defaultdict(list)
    for vlid in range(65536):
        pair = (bucket(vlid, BASE_SEED0, 0, buckets),
                bucket(vlid, BASE_SEED1, 1, buckets))
        groups[pair].append(vlid)
        if len(groups[pair]) == count:
            return groups[pair], pair
    raise AssertionError("not enough colliding VLIDs")


def generate():
    VEC.mkdir(exist_ok=True)
    group, pair = collision_group(32)
    impossible = [(idx, vlid) for idx, vlid in enumerate(group)]
    try:
        place(impossible, num_rx_vl=16, buckets=32, attempts=1)
    except PlacementError as exc:
        assert "VLID=0x" in str(exc)
    else:
        raise AssertionError("5 keys in only four ways must be rejected")
    recovered = place(impossible, num_rx_vl=16, buckets=32, attempts=2)
    assert recovered["attempt"] == 1, "seed must change collision relationships"
    # Exercise the real CLI's failure boundary, not merely a library exception.
    with tempfile.TemporaryDirectory(prefix="t12_bad_config_") as tmp:
        cfg = Path(tmp) / "colliding.csv"
        cfg.write_text("idx,vlid\n" + "".join("%d,0x%04X\n" % (i, v)
                       for i, v in impossible), encoding="ascii")
        prefix = Path(tmp) / "cannot_enable_rx"
        proc = subprocess.run([sys.executable, str(Path(__file__).with_name("hash_seed.py")),
                               "--csv", str(cfg), "--prefix", str(prefix),
                               "--num-rx-vl", "16", "--buckets", "32",
                               "--attempts", "1"], stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, timeout=15, check=False)
        assert proc.returncode != 0 and b"HASH IMAGE REJECTED" in proc.stdout
        assert not list(Path(tmp).glob("cannot_enable_rx*")), "failed config created image"
    # Invalid input must never be silently de-duplicated or indexed outside N.
    for broken in ([(0, 7), (1, 7)], [(0, 7), (0, 8)], [(16, 7)]):
        try:
            place(broken, num_rx_vl=16, buckets=32)
        except PlacementError:
            pass
        else:
            raise AssertionError("invalid offline RX config accepted: %r" % broken)

    used = set(group)
    small = impossible[:4]
    rng = random.Random(0x125EED)
    while len(small) < 16:
        vlid = rng.randrange(65536)
        if vlid in used:
            continue
        if (bucket(vlid, BASE_SEED0, 0, 32),
                bucket(vlid, BASE_SEED1, 1, 32)) == pair:
            continue
        used.add(vlid)
        small.append((len(small), vlid))
    # Force the *rehash image too* to exercise both tables and both ways.
    # These four new keys share a candidate pair only under the rescued seeds;
    # choose buckets disjoint from the original five under those new seeds.
    new0, new1 = recovered["seed0"], recovered["seed1"]
    old0 = {bucket(v, new0, 0, 32) for _, v in impossible}
    old1 = {bucket(v, new1, 1, 32) for _, v in impossible}
    old_ids = {v for _, v in impossible}
    alternate = defaultdict(list)
    new_pair = None
    for vlid in range(65536):
        if vlid in old_ids:
            continue
        pair = (bucket(vlid, new0, 0, 32), bucket(vlid, new1, 1, 32))
        if pair[0] in old0 or pair[1] in old1:
            continue
        alternate[pair].append(vlid)
        if len(alternate[pair]) == 4:
            new_pair = pair
            break
    assert new_pair is not None
    rehash = impossible + [(idx, v) for idx, v in enumerate(alternate[new_pair], 5)]
    used_ids = old_ids | set(alternate[new_pair])
    occupied0, occupied1 = old0 | {new_pair[0]}, old1 | {new_pair[1]}
    rng = random.Random(0x55ADD)
    while len(rehash) < 16:
        vlid = rng.randrange(65536)
        b0, b1 = bucket(vlid, new0, 0, 32), bucket(vlid, new1, 1, 32)
        if vlid in used_ids or b0 in occupied0 or b1 in occupied1:
            continue
        rehash.append((len(rehash), vlid))
        used_ids.add(vlid)
        occupied0.add(b0)
        occupied1.add(b1)
    rehashed = place(rehash, 16, 32, 2)
    assert rehashed["attempt"] == 1
    assert {((pos // 64) * 2 + pos % 2) for pos, word in
            enumerate(rehashed["image"]) if word & (1 << 28)} == {0, 1, 2, 3}

    samples = (
        ("t12_contig", [(idx, 0x2000 + idx) for idx in range(4096)], 4096, 2048, 64),
        # Full physical top image including the known-good real Ethernet frame
        # VLID 0x0100; the standalone contig set intentionally starts at 0x2000.
        ("t12_top", [(idx, idx) for idx in range(4096)], 4096, 2048, 64),
        ("t12_random", [(idx, vlid) for idx, vlid in enumerate(
            random.Random(0xA664).sample(range(65536), 4096))], 4096, 2048, 64),
        ("t12_small", small, 16, 32, 1),
        ("t12_rehash", rehash, 16, 32, 2),
    )
    for label, entries, n, buckets, trials in samples:
        build = place(entries, n, buckets, trials)
        verify(build)
        if label == "t12_small":
            hot = [w for w in build["image"] if (w >> 28) & 1 and
                   ((w >> 12) & 0xFFFF) in set(group[:4])]
            assert len(hot) == 4
            assert all(group[idx] in [((w >> 12) & 0xFFFF) for w in hot]
                       for idx in range(4))
        info = write_image(build, VEC / label, overwrite=True)
        print("T12 IMAGE PASS: %s keys=%d ways=%d seed=%04X/%04X rehash=%d moves=%d sha=%s" %
              (label, info["count"], 4 * info["buckets"], *info["seeds"],
               info["attempt"], info["moves"], info["image_sha256"]))
    # Use the independent golden frame generator + zlib wire-order FCS to
    # exercise the actual A/B RX ingress -> lookup path, not a forced descriptor.
    from gen_t08a_vectors import frame, fcs
    a_hit, b_hit = frame(32, ifid=1), frame(32, ifid=2)
    miss_body = bytearray(a_hit[:-4])
    miss_body[4:6] = b"\x80\x00"  # VLID outside 0x0000..0x0FFF
    a_miss = fcs(miss_body)
    b_bad_crc = b_hit[:-1] + bytes([b_hit[-1] ^ 1])
    frames = ((a_hit, 1, 0), (b_hit, 1, 1), (a_miss, 0, 0),
              (b_bad_crc, 2, 1))  # 2 = no lookup descriptor at all
    words = [len(frames)]
    for data, hit, net in frames:
        assert len(data) == 79
        words += [len(data), hit, net]
        words += [int.from_bytes(data[k:k+4].ljust(4, b"\x00"), "big")
                  for k in range(0, len(data), 4)]
    (VEC / "t12_top_frames.hex").write_text(
        "// 4 real A/B RX frames: two hits, unknown VLID, bad FCS\n" +
        "".join("%08X\n" % w for w in words), encoding="ascii")
    print("T12 TOP FRAMES PASS: A/B hits (0x0100), A miss (0x8000), B bad FCS; zlib wire-order FCS")
    print("T12 OFFLINE PASS: consecutive/random/full, hot-four/small and hot-four/rehash-seeds; forced-five CLI rejected without output")


if __name__ == "__main__":
    generate()
