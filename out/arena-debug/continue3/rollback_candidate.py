"""Reverse the measured-worse RTL attempt, never git reset/commit/push."""
from pathlib import Path
import hashlib
import subprocess

root = Path("C:/Workspace/diansai")
out = root / "out/arena-debug/continue3"
names = ("rtl/common/rst_sync.v", "rtl/top/AFDX_top.v")
records = []
for name in names:
    if (root / name).read_bytes() != (out / "replay" / name).read_bytes():
        raise RuntimeError(f"Refusing reverse patch: live RTL changed after measured run: {name}")
patch = out / "timing_attempt.patch"
for options in (("--check", "--reverse"), ("--reverse",)):
    cmd = ["git", "apply", *options, str(patch)]
    result = subprocess.run(cmd, cwd=root, capture_output=True)
    records.append(" ".join(cmd) + f"\nrc={result.returncode}\n")
    records.append("stdout=" + result.stdout.decode("utf-8", errors="replace") +
                   "\nstderr=" + result.stderr.decode("utf-8", errors="replace") + "\n")
    if result.returncode != 0:
        (out / "raw/live_rollback.log").write_text("".join(records), encoding="utf-8")
        raise RuntimeError("RTL reverse patch failed; see raw/live_rollback.log")
for name in names:
    backup = (out / "backup" / name).read_bytes()
    live = (root / name).read_bytes()
    if live != backup:
        raise RuntimeError(f"Rollback byte mismatch: {name}")
    records.append(f"ROLLED_BACK_BYTE_IDENTICAL {name} sha256={hashlib.sha256(live).hexdigest()}\n")
(out / "raw/live_rollback.log").write_text("".join(records), encoding="utf-8")
print("Measured-worse RTL reverted via git apply --reverse; 2/2 backups byte-identical")
