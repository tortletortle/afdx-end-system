"""Prove reverse patch on a disposable copy; never touch live RTL."""
from pathlib import Path
import hashlib
import shutil
import subprocess

root = Path("C:/Workspace/diansai")
out = root / "out/arena-debug/continue3"
names = ("rtl/common/rst_sync.v", "rtl/top/AFDX_top.v")
undo = out / "replay_undo"
if undo.exists():
    raise RuntimeError("Rollback verification copy already exists")
for name in names:
    path = undo / name
    path.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(out / "replay" / name, path)
lines = []
for option in (("--check", "--reverse"), ("--reverse",)):
    cmd = ["git", "apply", *option, "--directory=out/arena-debug/continue3/replay_undo", str(out / "fixes.patch")]
    p = subprocess.run(cmd, cwd=root, capture_output=True)
    lines.append(f"{' '.join(cmd)} rc={p.returncode} stderr={p.stderr.decode('utf-8', errors='replace')}")
    if p.returncode != 0:
        raise RuntimeError("Reverse patch failed in isolated copy")
for name in names:
    orig = (out / "backup" / name).read_bytes()
    actual = (undo / name).read_bytes()
    if actual != orig:
        raise RuntimeError(f"Rollback replay mismatch: {name}")
    lines.append(f"REVERSE_BYTE_IDENTICAL {name} sha256={hashlib.sha256(actual).hexdigest()}")
with (out / "raw/patch_verify.log").open("a", encoding="utf-8") as f:
    f.write("\n".join(lines) + "\n")
print("Reverse patch: check rc=0, apply rc=0, backup byte-identical 2/2")
