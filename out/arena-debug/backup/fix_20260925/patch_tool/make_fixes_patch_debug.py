#!/usr/bin/env python3
"""Generate a reversible git-format patch *relative to pre-fix backups*.

The repository already had unrelated staged/untracked changes before this job,
so plain `git diff` of HEAD would conflate those with our repairs. We stage
only pre-fix and current versions at identical relative paths and run git diff
--no-index. No working-tree files are reset or staged.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[3]
B = "out/arena-debug/backup/fix_20260925"
FILES = {
    "rtl/common/sync_fifo.v": f"{B}/B2/sync_fifo.v",
    "sim/tb/tb_t05b_jitter.v": f"{B}/B3/tb_t05b_jitter.v",
    "doc/当前进度_20260923.md": f"{B}/B3/当前进度_20260923.md",
    "rtl/top/AFDX_top.v": f"{B}/B5/rtl_top_AFDX_top.v",
    "rtl/rx/rx_block_pool.v": f"{B}/B5/rtl_rx_rx_block_pool.v",
    "sim/tb/tb_t23_sap_min.v": f"{B}/B5/sim_tb_tb_t23_sap_min.v",
    "sim/tb/tb_t18_random_stress.v": f"{B}/B67/tb_t18_random_stress.v",
    "tools/selfcheck_claims.py": f"{B}/B8_B11/selfcheck_claims.py",
    "tools/gen_synth_table.py": None,
    "out/arena-debug/DIANSAI-REPORT.md": f"{B}/B8_B11/DIANSAI-REPORT_before.md",
}
PATCH = ROOT / "out/arena-debug/fixes.patch"


def git(*args, cwd=ROOT, ok=(0,)):
    p = subprocess.run(["git", "-c", "core.quotepath=false", *args], cwd=cwd,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if p.returncode not in ok:
        raise RuntimeError(f"git rc={p.returncode}: {args}\n" +
                           p.stderr.decode("utf-8", errors="replace"))
    return p.stdout


def main():
    # Keep staging inside the workspace so git emits stable relative a/b paths.
    with tempfile.TemporaryDirectory(prefix="_patch_stage_",
                                     dir=ROOT / "out/arena-debug/checks") as tmp:
        old = Path(tmp) / "old"
        new = Path(tmp) / "new"
        old.mkdir()
        new.mkdir()
        for rel, backup in FILES.items():
            target = ROOT / rel
            assert target.is_file(), rel
            new_path = new / rel
            new_path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(target, new_path)
            if backup is not None:
                old_path = old / rel
                old_path.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(ROOT / backup, old_path)
        old_prefix = "a/" + old.relative_to(ROOT).as_posix() + "/"
        new_prefix = "b/" + new.relative_to(ROOT).as_posix() + "/"
        original = git("diff", "--no-index", "--no-ext-diff", "--no-renames",
                       "--binary", "--", old.relative_to(ROOT).as_posix(),
                       new.relative_to(ROOT).as_posix(), ok=(1,))
        # Replace only file header prefixes, never hunk content. Git's binary
        # patch payload (if present) is ASCII and safe to leave unchanged.
        output = []
        for line in original.splitlines(keepends=True):
            if line.startswith((b"diff --git ", b"--- ", b"+++ ", b"Binary files ")):
                line = line.replace(old_prefix.encode(), b"a/").replace(new_prefix.encode(), b"b/")
            output.append(line)
        PATCH.write_bytes(b"".join(output))
        assert PATCH.stat().st_size > 0
        # Check and actually apply each direction on isolated copies, then
        # compare bytes. Also check reverse directly against the live tree.
        git("apply", "-R", "--check", str(PATCH), cwd=ROOT)
        git("apply", "--check", str(PATCH), cwd=old)
        git("apply", str(PATCH), cwd=old)
        git("apply", "-R", str(PATCH), cwd=new)
        for rel, backup in FILES.items():
            expected = (ROOT / rel).read_bytes()
            actual = (old / rel).read_bytes()
            if actual != expected:
                i = next((i for i, (a, b) in enumerate(zip(actual, expected)) if a != b),
                         min(len(actual), len(expected)))
                raise AssertionError(f"forward {rel}: actual={len(actual)} expected={len(expected)}, "
                                     f"first_diff={i}, actual_excerpt={actual[max(0,i-30):i+80]!r}, "
                                     f"expected_excerpt={expected[max(0,i-30):i+80]!r}")
            if backup is None:
                assert not (new / rel).exists(), rel
            else:
                assert (new / rel).read_bytes() == (ROOT / backup).read_bytes(), rel
    print(f"git patch OK: {len(FILES)} paths, {PATCH.stat().st_size} bytes;"
          " forward/reverse byte-verified and live git apply -R --check passed")


if __name__ == "__main__":
    main()
