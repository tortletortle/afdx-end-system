"""Byte-preserving RTL diff against continue3/backup; replay with git apply."""
from pathlib import Path
import hashlib
import shutil
import subprocess

root = Path("C:/Workspace/diansai")
out = root / "out/arena-debug/continue3"
names = ["rtl/common/rst_sync.v", "rtl/top/AFDX_top.v"]
pieces = []
records = []
for name in names:
    old_rel = "out/arena-debug/continue3/backup/" + name
    result = subprocess.run(
        ["git", "diff", "--no-index", "--binary", "--", old_rel, name],
        cwd=root, capture_output=True,
    )
    if result.returncode != 1:
        raise RuntimeError(f"git diff {name}: rc={result.returncode}: {result.stderr[:500]!r}")
    old_header = ("a/" + old_rel).encode("ascii")
    new_header = ("a/" + name).encode("ascii")
    lines = result.stdout.splitlines(keepends=True)
    for i, line in enumerate(lines):
        if line.startswith((b"diff --git ", b"--- ")):
            lines[i] = line.replace(old_header, new_header, 1)
    part = b"".join(lines)
    if not part.startswith(("diff --git a/" + name + " b/" + name).encode("ascii")):
        raise RuntimeError(f"Unexpected git diff header for {name}")
    pieces.append(part)
    records.append(f"DIFF {name}: {len(part)} bytes")
patch = out / "fixes.patch"
patch.write_bytes(b"".join(pieces))

replay = out / "replay"
if replay.exists():
    raise RuntimeError("Replay directory already exists; refusing overwrite")
for name in names:
    p = replay / name
    p.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(out / "backup" / name, p)
cmd = ["git", "apply", "--directory=out/arena-debug/continue3/replay"]
for mode in (["--check"], []):
    args = cmd + mode + [str(patch)]
    result = subprocess.run(args, cwd=root, capture_output=True)
    records.append(f"{' '.join(args)} rc={result.returncode} stderr={result.stderr.decode('utf-8', errors='replace')}")
    if result.returncode:
        (out / "raw/patch_verify.log").write_text("\n".join(records), encoding="utf-8")
        raise RuntimeError("Patch replay failed; see raw/patch_verify.log")
for name in names:
    original = (root / name).read_bytes()
    reconstructed = (replay / name).read_bytes()
    if reconstructed != original:
        raise RuntimeError(f"Patch replay mismatch: {name}")
    records.append(f"BYTE_IDENTICAL {name} sha256={hashlib.sha256(original).hexdigest()}")
(out / "raw/patch_verify.log").write_text("\n".join(records) + "\n", encoding="utf-8")
print("Patch replay: check rc=0, apply rc=0, byte-identical 2/2")
