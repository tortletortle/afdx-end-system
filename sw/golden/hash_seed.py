#!/usr/bin/env python3
"""Offline two-table/two-way cuckoo RX VLID image builder (§7.9, O-13).

The device only does two synchronous bucket reads plus four comparisons: no
runtime eviction/probe. Failed placement raises and writes NO new image. The
caller must check the exit code and manifest before enabling RX; hardware host
seed registers/frontdoor integration are not yet implemented.
"""
import argparse
from collections import deque
import csv
import hashlib
import json
import os
from pathlib import Path

BASE_SEED0, BASE_SEED1 = 0x172D, 0xAB61


class PlacementError(ValueError):
    """Input is invalid or bounded offline placement could not complete."""


def check_buckets(buckets):
    if not (16 <= buckets <= 2048 and buckets & (buckets - 1) == 0):
        raise ValueError("buckets per table must be a power of two in [16, 2048]")


def bucket(vlid, seed, table, buckets=2048):
    """Bit-for-bit equivalent to mix_bucket in rtl/rx/rx_vl_lookup.v.

    Addition before the nonlinear carry/multiply/xorshift mixing means that
    changing the seed changes *which keys collide*, not merely bucket labels.
    """
    check_buckets(buckets)
    if not (0 <= vlid < 65536 and 0 <= seed < 65536 and table in (0, 1)):
        raise ValueError("VLID/seed must be 16 bit and table must be 0 or 1")
    x = (vlid + seed + (0x1F5B if table else 0x9E37)) & 0xFFFF
    x ^= x >> 7
    x = (x * (0x45D9 if table else 0x9E37)) & 0xFFFF
    x ^= x >> 9
    return x & (buckets - 1)


def positions(vlid, seeds, buckets):
    a = bucket(vlid, seeds[0], 0, buckets) * 2
    b = 2 * buckets + bucket(vlid, seeds[1], 1, buckets) * 2
    return (a, a + 1, b, b + 1)


def validate_entries(entries, num_rx_vl, buckets):
    check_buckets(buckets)
    if not 1 <= num_rx_vl <= 4096:
        raise PlacementError("NUM_RX_VL must be 1..4096")
    if len(entries) > min(num_rx_vl, 4 * buckets):
        raise PlacementError("more distinct VLs than configured indices or table slots")
    vlids, indices = set(), set()
    for idx, vlid in entries:
        if not isinstance(idx, int) or not 0 <= idx < num_rx_vl:
            raise PlacementError("invalid RX VL index: %r" % (idx,))
        if not isinstance(vlid, int) or not 0 <= vlid < 65536:
            raise PlacementError("invalid VLID: %r" % (vlid,))
        if vlid in vlids or idx in indices:
            raise PlacementError("duplicate VLID or index: idx=%d VLID=0x%04X" % (idx, vlid))
        vlids.add(vlid)
        indices.add(idx)


def _try_place(entries, buckets, seeds, max_nodes):
    """Bounded augmenting-path cuckoo insertion; never returns partial maps."""
    slots = [None] * (4 * buckets)
    moves = max_depth = 0
    for idx, vlid in entries:
        parent = {vlid: None}
        queue = deque([(vlid, 0)])
        placed = False
        while queue and not placed:
            current, depth = queue.popleft()
            for pos in positions(current, seeds, buckets):
                displaced = slots[pos]
                if displaced is None:
                    # Follow parents backwards from the empty way. Each moved
                    # key owns exactly one slot after reconstruction.
                    dest, moving = pos, current
                    while parent[moving] is not None:
                        slots[dest] = moving
                        moving, dest = parent[moving]
                        moves += 1
                    slots[dest] = moving
                    max_depth = max(max_depth, depth)
                    placed = True
                    break
                if displaced not in parent and len(parent) < max_nodes:
                    parent[displaced] = (current, pos)
                    queue.append((displaced, depth + 1))
        if not placed:
            return None, (idx, vlid, tuple(list(parent)[:8]))
    return (slots, moves, max_depth), None


def place(entries, num_rx_vl=4096, buckets=2048, attempts=64,
          seed0=BASE_SEED0, seed1=BASE_SEED1, max_nodes=512):
    entries = list(entries)
    validate_entries(entries, num_rx_vl, buckets)
    if not 1 <= attempts <= 1024 or not 1 <= max_nodes <= 8192:
        raise ValueError("invalid attempts/max_nodes bounds")
    max_nodes = min(max_nodes, 4 * buckets)
    if not (0 <= seed0 <= 65535 and 0 <= seed1 <= 65535):
        raise ValueError("seed values must be 16 bit")
    failure = None
    for trial in range(attempts):
        seeds = ((seed0 + trial * 0x9E37) & 0xFFFF,
                 (seed1 + trial * 0x45D9) & 0xFFFF)
        result, failure = _try_place(entries, buckets, seeds, max_nodes)
        if result is not None:
            slots, moves, max_depth = result
            idx_by_vlid = {vlid: idx for idx, vlid in entries}
            image = [0 if vlid is None else
                     (1 << 28) | (vlid << 12) | idx_by_vlid[vlid]
                     for vlid in slots]
            build = {"seed0": seeds[0], "seed1": seeds[1], "num_rx_vl": num_rx_vl,
                     "buckets": buckets, "attempt": trial, "moves": moves,
                     "max_depth": max_depth, "keys": entries, "image": image}
            verify(build)
            return build
    idx, vlid, conflicted = failure
    raise PlacementError("%d seed sets exhausted; failed idx=%d VLID=0x%04X; "
                         "conflicting VLIDs=%s" %
                         (attempts, idx, vlid,
                          ",".join("0x%04X" % key for key in conflicted)))


def lookup(image, vlid, seeds, buckets, num_rx_vl=4096):
    for pos in positions(vlid, seeds, buckets):
        word = image[pos]
        if not word >> 29 and (word >> 28) & 1 and ((word >> 12) & 0xFFFF) == vlid:
            idx = word & 0xFFF
            if idx < num_rx_vl:
                return idx
    return None


def verify(build):
    entries, image = build["keys"], build["image"]
    buckets = build["buckets"]
    if len(image) != 4 * buckets:
        raise AssertionError("image capacity mismatch")
    expected = {v: i for i, v in entries}
    actual = {}
    for slot, word in enumerate(image):
        if word >> 29:
            raise AssertionError("reserved hash word bits not zero")
        if not (word >> 28) & 1:
            if word != 0:
                raise AssertionError("empty hash slot must be zero")
            continue
        vlid = (word >> 12) & 0xFFFF
        idx = word & 0xFFF
        if slot not in positions(vlid, (build["seed0"], build["seed1"]), buckets):
            raise AssertionError("VLID outside both candidate buckets")
        if vlid in actual:
            raise AssertionError("same VLID in more than one way")
        actual[vlid] = idx
    if actual != expected:
        raise AssertionError("dropped or corrupt VLID during placement")
    for idx, vlid in entries:
        if lookup(image, vlid, (build["seed0"], build["seed1"]), buckets,
                  build["num_rx_vl"]) != idx:
            raise AssertionError("candidate lookup disagrees with config")


def from_csv(path):
    with Path(path).open(encoding="utf-8-sig", newline="") as f:
        reader = csv.DictReader(f)
        if reader.fieldnames is None or set(reader.fieldnames) != {"idx", "vlid"}:
            raise PlacementError("CSV columns must be exactly idx,vlid")
        rows = []
        for row in reader:
            try:
                def parse_num(text):
                    return int(text, 16 if text.lower().startswith("0x") else 10)
                rows.append((parse_num(row["idx"]), parse_num(row["vlid"])))
            except (ValueError, TypeError) as exc:
                raise PlacementError("invalid idx/VLID in config CSV: %s" % row) from exc
    return rows


def write_image(build, prefix, overwrite=False):
    """Validate completely before staging any output; fail closed on errors."""
    verify(build)
    prefix = Path(prefix)
    image = "\n".join("%08X" % word for word in build["image"]) + "\n"
    keys = "%08X\n" % len(build["keys"]) + "".join(
        "%08X\n" % ((vlid << 12) | idx) for idx, vlid in build["keys"])
    meta = "".join("%08X\n" % value for value in (
        build["seed0"], build["seed1"], len(build["keys"]), build["buckets"]))
    manifest = {"valid": True, "version": 1, "word_base": "0x3D80",
                "word_formula": "base+table*(2*buckets)+bucket*2+way",
                "seeds": [build["seed0"], build["seed1"]],
                "buckets": build["buckets"], "num_rx_vl": build["num_rx_vl"],
                "count": len(build["keys"]), "attempt": build["attempt"],
                "moves": build["moves"], "max_depth": build["max_depth"],
                "image_sha256": hashlib.sha256(image.encode("ascii")).hexdigest().upper(),
                "keys_sha256": hashlib.sha256(keys.encode("ascii")).hexdigest().upper()}
    texts = {".img.hex": image, ".keys.hex": keys, ".meta.hex": meta,
             ".manifest.json": json.dumps(manifest, sort_keys=True, indent=2) + "\n"}
    paths = [(Path(str(prefix) + suffix), value) for suffix, value in texts.items()]
    if not overwrite and any(path.exists() for path, _ in paths):
        raise FileExistsError("refuse to overwrite image; pass --force to replace")
    prefix.parent.mkdir(parents=True, exist_ok=True)
    staged = []
    manifest_path = Path(str(prefix) + ".manifest.json")
    try:
        for path, text in paths:
            temp = Path(str(path) + ".tmp")
            temp.write_text(text, encoding="ascii")
            staged.append((temp, path))
        # Manifest is the only validity/commit marker. Never leave an old
        # valid manifest pointing to partly replaced bytes.
        if manifest_path.exists():
            manifest_path.unlink()
        for temp, path in staged:
            os.replace(temp, path)
    except OSError:
        if manifest_path.exists():
            manifest_path.unlink()
        raise
    finally:
        for temp, _ in staged:
            if temp.exists():
                temp.unlink()
    return manifest


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--csv", type=Path, required=True, help="CSV with idx,vlid (decimal or 0xhex)")
    ap.add_argument("--prefix", type=Path, required=True, help="output prefix; four files")
    ap.add_argument("--num-rx-vl", type=int, default=4096)
    ap.add_argument("--buckets", type=int, default=2048)
    ap.add_argument("--attempts", type=int, default=64)
    ap.add_argument("--seed0", type=lambda v: int(v, 0), default=BASE_SEED0)
    ap.add_argument("--seed1", type=lambda v: int(v, 0), default=BASE_SEED1)
    ap.add_argument("--force", action="store_true", help="replace prior successful outputs")
    args = ap.parse_args()
    try:
        build = place(from_csv(args.csv), args.num_rx_vl, args.buckets,
                      args.attempts, args.seed0, args.seed1)
        manifest = write_image(build, args.prefix, args.force)
    except (ValueError, FileExistsError) as exc:
        # --force means this prefix was being replaced: invalidate any old
        # manifest so a failed reconfiguration can never look successful.
        if args.force:
            marker = Path(str(args.prefix) + ".manifest.json")
            if marker.exists():
                marker.unlink()
        ap.exit(1, "HASH IMAGE REJECTED: %s\n" % exc)
    print("HASH IMAGE PASS: %d keys, %d buckets/table, seed=%04X/%04X, "
          "retry=%d relocations=%d, SHA-256=%s" %
          (manifest["count"], manifest["buckets"], *manifest["seeds"],
           manifest["attempt"], manifest["moves"], manifest["image_sha256"]))


if __name__ == "__main__":
    main()
