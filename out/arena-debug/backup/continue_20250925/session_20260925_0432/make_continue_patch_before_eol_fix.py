"""Create a reversible *finalize-only* patch against preserved pre-edit copies.

The existing checkout has earlier unrelated edits; never diff against HEAD.
Run after the final docs are written. No commit, reset, or source edit occurs.
"""
from __future__ import annotations

import hashlib
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path('C:/Workspace/diansai')
BASE = ROOT / "out/arena-debug/continue/session_20260925_0432"
BACKUP_REL = "out/arena-debug/backup/continue_20250925/session_20260925_0432/"
PATCH = ROOT / "out/arena-debug/fixes.patch"
EXISTING = ["doc/当前进度_20260923.md", "doc/后续计划.md", "out/arena-debug/DIANSAI-REPORT.md"]
ADDED = [p.relative_to(ROOT).as_posix() for p in sorted(BASE.iterdir())
         if p.suffix in ('.py','.ps1','.tcl','.ys','.md')]
ADDED += ['out/arena-debug/finalize/CONTINUE-20260925.md']



def run(*args: str, cwd: Path = ROOT) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(args, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


pieces: list[bytes] = []
for rel in EXISTING:
    old = ROOT / (BACKUP_REL + rel)
    cur = ROOT / rel
    if not old.is_file() or not cur.is_file():
        raise SystemExit(f"missing pre-edit backup/current: {rel}")
    res = run("git", "diff", "--no-index", "--", BACKUP_REL + rel, rel)
    if res.returncode not in (0, 1):
        raise SystemExit(f"git diff failed {rel}: {res.stderr.decode(errors='replace')}")
    if res.returncode == 1:
        pieces.append(res.stdout.replace(b"a/" + BACKUP_REL.encode(), b"a/"))
for rel in ADDED:
    if not (ROOT / rel).is_file():
        raise SystemExit(f"missing new file: {rel}")
    res = run("git", "diff", "--no-index", "--", "/dev/null", rel)
    if res.returncode != 1:
        raise SystemExit(f"git new-file diff failed {rel}: rc={res.returncode} {res.stderr.decode(errors='replace')}")
    pieces.append(res.stdout)
PATCH.write_bytes(b"".join(pieces))

log = [f"COMMAND: python {Path(__file__).relative_to(ROOT).as_posix()}",
       f"PATCH: {PATCH.relative_to(ROOT).as_posix()} bytes={PATCH.stat().st_size}"]
rev = run("git", "apply", "-R", "--check", PATCH.as_posix())
log.append(f"git apply -R --check rc={rev.returncode}")
log.append(rev.stdout.decode(errors="replace") + rev.stderr.decode(errors="replace"))
if rev.returncode:
    (BASE / "patch_verify.log").write_text("\n".join(log), encoding="utf-8")
    raise SystemExit("reverse check FAILED; see patch_verify.log")
with tempfile.TemporaryDirectory(prefix="diansai_continue_patch_") as d:
    stage = Path(d)
    for rel in EXISTING:
        dest = stage / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / (BACKUP_REL + rel), dest)
    check = run("git", "apply", "--check", PATCH.as_posix(), cwd=stage)
    log.append(f"isolated backup git apply --check rc={check.returncode}")
    log.append(check.stdout.decode(errors="replace") + check.stderr.decode(errors="replace"))
    if check.returncode:
        (BASE / "patch_verify.log").write_text("\n".join(log), encoding="utf-8")
        raise SystemExit("forward check FAILED; see patch_verify.log")
    applied = run("git", "apply", PATCH.as_posix(), cwd=stage)
    log.append(f"isolated backup git apply rc={applied.returncode}")
    log.append(applied.stdout.decode(errors="replace") + applied.stderr.decode(errors="replace"))
    different = [rel for rel in EXISTING + ADDED if
                 not (stage / rel).exists() or sha(stage / rel) != sha(ROOT / rel)]
    log.append(f"byte-for-byte staged file mismatches: {different}")
    if different or applied.returncode:
        (BASE / "patch_verify.log").write_text("\n".join(log), encoding="utf-8")
        raise SystemExit("staged patch differs; see patch_verify.log")
(BASE / "patch_verify.log").write_text("\n".join(log) + "\n", encoding="utf-8")
print(f"PATCH PASS: reverse/forward/byte-equality, {len(EXISTING)} old + {len(ADDED)} new")
