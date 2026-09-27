"""Hash the final evidence plus only this finalize round's edited inputs.

Run from any cwd: python out/arena-debug/finalize/write_sha256.py
Verify: python out/arena-debug/finalize/write_sha256.py --verify
The manifest deliberately excludes itself to avoid a hash cycle.
"""
from __future__ import annotations

import hashlib
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
BASE = ROOT / "out/arena-debug/finalize"
MANIFEST = BASE / "SHA256SUMS.txt"
EDITED = [
    "rtl/tx/tx_rm.v",
    "sim/tb/tb_t18_random_stress.v",
    "sim/tb/tb_t23_sap_min.v",
    "elinx/sdc/AFDX_top.edc",
    "README.md",
    "doc/当前进度_20260923.md",
    "doc/后续计划.md",
    "out/arena-debug/DIANSAI-REPORT.md",
    "out/arena-debug/fixes.patch",
    "sim/tests.manifest",
]


def digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fd:
        for block in iter(lambda: fd.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest().upper()


def relpath(path: Path) -> str:
    return path.relative_to(ROOT).as_posix()


if __name__ == "__main__":
    if sys.argv[1:] == ["--verify"]:
        rows = [line.split("  ", 1) for line in MANIFEST.read_text(encoding="utf-8").splitlines()]
        mismatches = [name for old, name in rows if digest(ROOT / name) != old]
        print(f"SHA256 VERIFY: {len(rows)-len(mismatches)}/{len(rows)} match")
        for name in mismatches:
            print("MISMATCH:", name)
        sys.exit(1 if mismatches else 0)
    if len(sys.argv) != 1:
        sys.exit("usage: write_sha256.py [--verify]")
    files = {ROOT / name for name in EDITED}
    files.update(p for p in BASE.rglob("*") if p.is_file() and p != MANIFEST)
    missing = [str(p) for p in files if not p.exists()]
    if missing:
        sys.exit("missing: " + ", ".join(missing))
    rows = [f"{digest(path)}  {relpath(path)}" for path in sorted(files, key=relpath)]
    MANIFEST.write_text("\n".join(rows) + "\n", encoding="utf-8")
    print(f"SHA256 WRITTEN: {len(rows)} files, {relpath(MANIFEST)}")
