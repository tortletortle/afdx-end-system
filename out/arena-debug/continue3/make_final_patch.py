"""Create/replay the final STA guard patch; archive timing_attempt.patch separately."""
from pathlib import Path
import hashlib
import shutil
import subprocess

root = Path("C:/Workspace/diansai")
out = root / "out/arena-debug/continue3"
script = "elinx/prj/quartus/sta_post_map.tcl"
helper = "elinx/prj/quartus/check_sdc_8ns.tcl"
old_path = "out/arena-debug/continue3/backup/" + script
if not (out / "timing_attempt.patch").is_file():
    raise RuntimeError("Refusing to overwrite experiment patch before archival")
diff = subprocess.run(["git", "diff", "--no-index", "--binary", "--", old_path, script],
                      cwd=root, capture_output=True)
if diff.returncode != 1:
    raise RuntimeError(f"Unexpected git diff rc={diff.returncode}: {diff.stderr[:500]!r}")
lines = diff.stdout.splitlines(keepends=True)
for i, line in enumerate(lines):
    if line.startswith((b"diff --git ", b"--- ")):
        lines[i] = line.replace(("a/" + old_path).encode("ascii"), ("a/" + script).encode("ascii"), 1)
part1 = b"".join(lines)
if not part1.startswith(("diff --git a/" + script + " b/" + script).encode("ascii")):
    raise RuntimeError("Unexpected modified-script diff header")
added = (root / helper).read_bytes()
if not added.endswith(b"\n"):
    raise RuntimeError("New Tcl helper lacks final newline")
src_lines = added.splitlines(keepends=True)
head = (f"diff --git a/{helper} b/{helper}\nnew file mode 100644\n"
        f"--- /dev/null\n+++ b/{helper}\n@@ -0,0 +1,{len(src_lines)} @@\n").encode("ascii")
part2 = head + b"".join(b"+" + line for line in src_lines)
patch = out / "fixes.patch"
patch.write_bytes(part1 + part2)
log = [f"FINAL_PATCH_SHA256 {hashlib.sha256(patch.read_bytes()).hexdigest()}"]

replay = out / "replay_final"
replay_undo = out / "replay_final_undo"
for d in (replay, replay_undo):
    if d.exists():
        raise RuntimeError(f"Replay dir already exists: {d}")
target = replay / script
target.parent.mkdir(parents=True, exist_ok=True)
shutil.copyfile(out / "backup" / script, target)

def apply(directory, reverse):
    base = ["git", "apply", "--directory=" + directory.relative_to(root).as_posix()]
    for opts in (("--check", "--reverse") if reverse else ("--check",),
                 ("--reverse",) if reverse else ()):
        cmd = base + list(opts) + [str(patch)]
        result = subprocess.run(cmd, cwd=root, capture_output=True)
        log.append(f"{' '.join(cmd)} rc={result.returncode} stderr={result.stderr.decode('utf-8', errors='replace')}")
        if result.returncode:
            (out / "raw/final_patch_verify.log").write_text("\n".join(log) + "\n", encoding="utf-8")
            raise RuntimeError("Patch replay failed; see raw/final_patch_verify.log")

apply(replay, False)
for name in (script, helper):
    if (replay / name).read_bytes() != (root / name).read_bytes():
        raise RuntimeError(f"Forward replay mismatch: {name}")
    log.append(f"FORWARD_BYTE_IDENTICAL {name}")
shutil.copytree(replay, replay_undo)
apply(replay_undo, True)
if (replay_undo / script).read_bytes() != (out / "backup" / script).read_bytes():
    raise RuntimeError("Reverse replay differs from script backup")
if (replay_undo / helper).exists():
    raise RuntimeError("Reverse replay did not delete new helper")
log.append("REVERSE_BYTE_IDENTICAL sta_post_map.tcl; new check_sdc_8ns.tcl deleted")
(out / "raw/final_patch_verify.log").write_text("\n".join(log) + "\n", encoding="utf-8")
print("Final STA guard patch: forward/reverse check and replay rc=0, byte-identical")
