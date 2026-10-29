#!/usr/bin/env python3
"""Whitelist packer for AFDX ES submission (E / §10.1, tightened).

Default deliverable is RAR via WinRAR Rar.exe (≤200 MB, no .git).
ZIP is written only as AFDX_ES_<commit>.internal.zip for local use.
Also writes PACKAGE_MANIFEST.json + PACK_SIZE.md + ABS_PATHS.md.
Skips DO_NOT_CITE trees, pack_exclude.txt, debug scripts, unrelated tools.
VO not packed. Consoles: key T only.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import subprocess
import sys
import zipfile
from collections import defaultdict
from datetime import datetime, timezone, timedelta
from pathlib import Path

COMMIT7 = "098efc9"
FREEZE_DIR_REL = "out/p9_freeze_dfac58a"
QUESTA_REL = (
    "out/p9_clean_20261025_133746/sim/out/p9_questa_full_20261025_134051"
)

# Consoles kept in evidence (plus gate log).
KEY_CONSOLES = {
    "T13_console.txt",
    "T13w_console.txt",
    "T05b_console.txt",
    "T42_console.txt",
    "T88_console.txt",
    "T89_console.txt",
    "T90_console.txt",
    "T10_console.txt",
    "T16a_console.txt",
}

TOOLS_ALLOW = {
    "run_all.py",
    "verify_all.py",
    "check_addr.py",
    "check_s9_final.py",
    "gen_regs.py",
    "check_doc_numbers.py",
    "check_doc_metrics.py",
    "render_doc_metrics.py",
    "selfcheck_claims.py",
    "check_packaged_regress.py",
    "pack_submission.py",
    "pack_exclude.txt",
    "README.md",
}
# Also allow bag_* / gen_* used by selfcheck / docs
TOOLS_PREFIX_ALLOW = ("bag_", "check_", "gen_regs", "gen_")

SIM_SKIP_NAMES = {
    "run_bg.ps1",
    "transcript",
    "vish_stacktrace.vstf",
    "vsim_stacktrace.vstf",
    "out_final66_launch.log",
}
SIM_SKIP_PREFIX = ("_dbg_",)
SIM_SKIP_SUFFIX_MUTANT = ()  # keep mutant runners out of pack — not needed for REPLAY
SIM_SKIP_CONTAINS = ("mutants",)  # test_*_mutants.py, mutant_compile_list.py

ABS_PATTERNS = (
    r"C:\\Workspace",
    r"C:/Workspace",
    r"C:\\altera_pro",
    r"C:/altera_pro",
    r"C:\\modeltech",
    r"C:/modeltech",
    r"C:\\intelFPGA",
    r"C:/intelFPGA",
)


def sha256_file(p: Path) -> str:
    h = hashlib.sha256()
    with p.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def load_excludes(root: Path) -> list[str]:
    p = root / "tools" / "pack_exclude.txt"
    out: list[str] = []
    if p.is_file():
        for line in p.read_text(encoding="utf-8").splitlines():
            s = line.split("#", 1)[0].strip().replace("\\", "/")
            if s:
                out.append(s.rstrip("/") + "/")
    return out


def has_do_not_cite(path: Path) -> bool:
    if path.is_file():
        return path.name == "DO_NOT_CITE.md"
    return (path / "DO_NOT_CITE.md").is_file()


def is_excluded(root: Path, rel: Path, excludes: list[str]) -> bool:
    posix = rel.as_posix().replace("\\", "/")
    posix_dir = posix if posix.endswith("/") else posix + "/"
    for ex in excludes:
        if posix_dir.startswith(ex) or posix.startswith(ex.rstrip("/")):
            return True
    cur = root / rel
    for parent in [cur, *cur.parents]:
        if parent == root:
            break
        if has_do_not_cite(parent):
            return True
    return False


def copy_file(src: Path, dst: Path) -> None:
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)


def copy_tree_filtered(
    src: Path,
    dst: Path,
    root: Path,
    excludes: list[str],
    skip_names: set[str] | None = None,
) -> None:
    skip_names = skip_names or set()
    if not src.exists():
        return
    for p in src.rglob("*"):
        if not p.is_file():
            continue
        if p.name in skip_names:
            continue
        if "legacy" in p.parts:
            continue
        if p.name.startswith("_dbg_"):
            continue
        rel_repo = p.relative_to(root)
        if is_excluded(root, rel_repo, excludes):
            continue
        copy_file(p, dst / p.relative_to(src))


def tool_allowed(name: str) -> bool:
    if name in TOOLS_ALLOW:
        return True
    if name.startswith("_") or name.startswith("pdf_") or "ocr" in name or "lit_" in name:
        return False
    if name.startswith(TOOLS_PREFIX_ALLOW):
        # gen_* except heavy one-offs already filtered by underscore prefix
        if name.startswith("gen_") and name not in {
            "gen_regs.py",
        }:
            # allow gen_regs only from exact; other gen_* for docs ok if check/bag
            if not name.startswith("bag_"):
                return name in {"gen_regs.py"}
        return True
    return False


def sim_file_allowed(name: str) -> bool:
    if name in SIM_SKIP_NAMES:
        return False
    if any(name.startswith(p) for p in SIM_SKIP_PREFIX):
        return False
    low = name.lower()
    if any(s in low for s in SIM_SKIP_CONTAINS):
        return False
    return True


def rewrite_abs_workspace(text: str, root_name: str = "diansai") -> str:
    """Rewrite C:/Workspace/diansai/... → relative from package root."""
    text = text.replace("C:/Workspace/diansai/", "")
    text = text.replace("C:\\Workspace\\diansai\\", "")
    text = text.replace("C:/Workspace/diansai", ".")
    text = text.replace("C:\\Workspace\\diansai", ".")
    return text


def stage_evidence(root: Path, stage: Path) -> None:
    ev = stage / "evidence" / COMMIT7
    freeze = root / FREEZE_DIR_REL
    questa = root / QUESTA_REL

    for name in (
        "FREEZE.json",
        "metrics.json",
        "metrics_diff_vs_C.csv",
        "metrics_diff_vs_C.md",
        "dual_sim_compare.csv",
        "waves_manifest.csv",
        "rtl_empty_vs_225cd91.txt",
        "coverage_report_du_AFDX_top.txt",
        "coverage_summary_all145.txt",
        "coverage_summary_afdx_top_all145.txt",
        "coverage_by_du.md",
        "coverage_by_du.json",
        "coverage_hotspots_top20.md",
        "STATUS.md",
        "ACCEPTANCE_D.md",
        "ACCEPTANCE_E.md",
    ):
        src = freeze / name
        if src.is_file():
            copy_file(src, ev / name)

    gate = freeze / "gate_t88b"
    for name in ("vsim.log", "simulation_status.json"):
        src = gate / name
        if src.is_file():
            copy_file(src, ev / "gate_t88b" / name)
    (ev / "gate_vo_NOTE.txt").write_text(
        "VO not packed.\n"
        "gate_vo_sha256=2801113d07f7f72cf8d9d3a6c737fc0d1fea3669effa1a53551058c85165fb46\n",
        encoding="utf-8",
    )

    wp = freeze / "wave_png"
    if wp.is_dir():
        for p in list(wp.glob("*_signals.png")) + list(wp.glob("*_signals.sha256.txt")):
            copy_file(p, ev / "wave_png" / p.name)

    if questa.is_dir():
        for name in KEY_CONSOLES:
            src = questa / name
            if src.is_file():
                copy_file(src, ev / "questa_consoles" / name)
        for name in ("regress.csv", "run_metadata.json"):
            src = questa / name
            if src.is_file():
                copy_file(src, ev / name)

    lint = root / "out/p4_lint_20261022_182034"
    for name in ("lint_triage.md", "lint_console.txt"):
        src = lint / name
        if src.is_file():
            copy_file(src, ev / "lint" / name)

    mut = root / "sim/out/p_c3_merged_20261025/MUTANTS_SUMMARY.md"
    if mut.is_file():
        copy_file(mut, ev / "mutants" / "MUTANTS_SUMMARY.md")

    env = root / "formal" / "ENV_STATUS.md"
    if env.is_file():
        copy_file(env, ev / "formal" / "ENV_STATUS.md")

    for name in ("elinx_sources.png", "elinx_modelsim_path.png"):
        src = root / "shots" / name
        if src.is_file():
            copy_file(src, ev / "elinx_gui" / name)
    tr = root / "out/p3_elinx_gui_20261023/transcript"
    if tr.is_file():
        copy_file(tr, ev / "elinx_gui" / "transcript")

    (ev / "SYNTH_NOTE.txt").write_text(
        "eLinx synth cells/altsyncram cited from C (rtl empty vs 225cd91); see metrics.json.\n"
        "No Fit/STA / Fmax / Setup in submission pack (not a contest requirement).\n",
        encoding="utf-8",
    )


def build_stage(root: Path, stage: Path, excludes: list[str]) -> None:
    if stage.exists():
        shutil.rmtree(stage)
    stage.mkdir(parents=True)

    copy_tree_filtered(root / "rtl", stage / "rtl", root, excludes)

    for sub in ("tb", "env", "chk", "vec", "bfm"):
        copy_tree_filtered(root / "sim" / sub, stage / "sim" / sub, root, excludes)

    for p in (root / "sim").iterdir():
        if not p.is_file():
            continue
        if not sim_file_allowed(p.name):
            continue
        if p.suffix.lower() in {".ps1", ".py", ".tcl", ".tsv", ".json", ".md", ".manifest"}:
            copy_file(p, stage / "sim" / p.name)
        elif p.name == "tests.manifest":
            copy_file(p, stage / "sim" / p.name)

    copy_tree_filtered(
        root / "sw" / "golden",
        stage / "sw" / "golden",
        root,
        excludes,
        skip_names={".pyc"},
    )
    # drop any __pycache__ that slipped
    for p in list((stage / "sw" / "golden").rglob("__pycache__")) if (stage / "sw" / "golden").exists() else []:
        shutil.rmtree(p, ignore_errors=True)
    for p in list((stage / "sw" / "golden").rglob("*.pyc")) if (stage / "sw" / "golden").exists() else []:
        p.unlink(missing_ok=True)
    copy_tree_filtered(root / "sw" / "report", stage / "sw" / "report", root, excludes)
    swr = root / "sw" / "README.md"
    if swr.is_file():
        copy_file(swr, stage / "sw" / "README.md")

    tools_dst = stage / "tools"
    for p in (root / "tools").iterdir():
        if p.is_file() and tool_allowed(p.name):
            copy_file(p, tools_dst / p.name)

    # elinx: sources.f + sdc + thin GUI project only (no quartus db / runs / sim dumps)
    elinx = root / "elinx"
    if elinx.is_dir():
        keep_top = {
            "AFDX_top_sources.f",
            "AFDX_615A_prepare_sources.f",
            "AFDX_fragment_prepare_sources.f",
            "README.txt",
        }
        for name in keep_top:
            src = elinx / name
            if src.is_file():
                copy_file(src, stage / "elinx" / name)
        sdc = elinx / "sdc"
        if sdc.is_dir():
            copy_tree_filtered(sdc, stage / "elinx" / "sdc", root, excludes)
        gui = elinx / "gui_afdx"
        if gui.is_dir():
            for p in gui.iterdir():
                if not p.is_file():
                    continue
                if p.suffix.lower() not in {".epr", ".qpf", ".qsf", ".property", ".xml"}:
                    continue
                try:
                    raw = p.read_text(encoding="utf-8", errors="replace")
                except OSError:
                    copy_file(p, stage / "elinx" / "gui_afdx" / p.name)
                    continue
                dst = stage / "elinx" / "gui_afdx" / p.name
                dst.parent.mkdir(parents=True, exist_ok=True)
                dst.write_text(rewrite_abs_workspace(raw), encoding="utf-8")
            # constraints only
            constr = gui / "AFDX_top.srcs" / "constrs_1" / "new"
            if constr.is_dir():
                for p in constr.rglob("*"):
                    if p.is_file() and p.suffix.lower() in {".edc", ".sdc"}:
                        rel = p.relative_to(gui)
                        copy_file(p, stage / "elinx" / "gui_afdx" / rel)

    formal = root / "formal"
    if formal.is_dir():
        for p in formal.rglob("*"):
            if not p.is_file():
                continue
            if "workdir" in p.parts or "work_" in p.name:
                continue
            if "__pycache__" in p.parts or p.suffix == ".pyc":
                continue
            # skip tool logfiles with host abs paths; keep ENV_STATUS / .sby / wrappers
            if p.name in {"logfile.txt", "engine_yosys.log", "logfile"}:
                continue
            if p.suffix in {".sby", ".sv", ".v", ".md"} or p.name.endswith(".sby"):
                copy_file(p, stage / "formal" / p.relative_to(formal))
            elif p.name == "ENV_STATUS.md" or p.suffix == ".txt" and "bmc" not in str(p.parent).lower():
                copy_file(p, stage / "formal" / p.relative_to(formal))

    copy_tree_filtered(root / "doc" / "submit", stage / "doc" / "submit", root, excludes)
    figs = root / "doc" / "figs"
    if figs.is_dir():
        copy_tree_filtered(figs, stage / "doc" / "figs", root, excludes)
    for name in (
        "regs.yaml",
        "赛方答疑原文_20261009.txt",
        "01_AI工具使用声明.md",
        "验收尺子.md",
    ):
        src = root / "doc" / name
        if src.is_file():
            copy_file(src, stage / "doc" / name)

    copy_file(root / "README.md", stage / "README.md")
    for name in ("AFDX端系统_总体设计书.md", "README_tools.md", "_project.md"):
        src = root / name
        if src.is_file():
            copy_file(src, stage / name)

    for name in ("elinx_sources.png", "elinx_modelsim_path.png"):
        src = root / "shots" / name
        if src.is_file():
            copy_file(src, stage / "shots" / name)

    stage_evidence(root, stage)

    freeze_alias = stage / FREEZE_DIR_REL
    freeze_alias.mkdir(parents=True, exist_ok=True)
    for name in ("metrics.json", "FREEZE.json", "coverage_by_du.md"):
        src = stage / "evidence" / COMMIT7 / name
        if src.is_file():
            copy_file(src, freeze_alias / name)


def scan_abs_paths(stage: Path) -> list[dict]:
    hits = []
    cre = re.compile("|".join(ABS_PATTERNS))
    for p in stage.rglob("*"):
        if not p.is_file():
            continue
        if p.suffix.lower() in {".png", ".jpg", ".zip", ".ucdb", ".woff", ".pdf"}:
            continue
        if p.stat().st_size > 5_000_000:
            continue
        try:
            text = p.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        if cre.search(text):
            kinds = sorted({m.group(0) for m in cre.finditer(text)})
            hits.append({"path": p.relative_to(stage).as_posix(), "patterns": kinds})
    return hits


def size_report(stage: Path) -> str:
    dir_bytes: dict[str, int] = defaultdict(int)
    files: list[tuple[int, str]] = []
    total = 0
    for p in stage.rglob("*"):
        if not p.is_file():
            continue
        n = p.stat().st_size
        total += n
        rel = p.relative_to(stage).as_posix()
        files.append((n, rel))
        top = rel.split("/", 1)[0]
        dir_bytes[top] += n
    lines = [
        "# PACK_SIZE",
        "",
        f"total_bytes={total}",
        f"total_miB={total/1024/1024:.2f}",
        "",
        "## Top directories",
        "",
    ]
    for k, v in sorted(dir_bytes.items(), key=lambda x: -x[1])[:10]:
        lines.append(f"- `{k}/` {v/1024/1024:.2f} MiB")
    lines += ["", "## Top 10 files", ""]
    for n, rel in sorted(files, key=lambda x: -x[0])[:10]:
        lines.append(f"- `{rel}` {n/1024/1024:.2f} MiB")
    return "\n".join(lines) + "\n", total


def write_manifest(stage: Path, manifest_path: Path, zip_path: Path, rar_path: Path | None = None) -> dict:
    members = []
    for p in sorted(stage.rglob("*")):
        if not p.is_file():
            continue
        rel = p.relative_to(stage).as_posix()
        members.append({"path": rel, "bytes": p.stat().st_size, "sha256": sha256_file(p)})
    data = {
        "commit7": COMMIT7,
        "freeze": FREEZE_DIR_REL,
        "created_local": datetime.now(timezone(timedelta(hours=8))).strftime(
            "%Y-%m-%dT%H:%M:%S%z"
        ),
        "rar": rar_path.name if rar_path else "",
        "zip_internal": zip_path.name,
        "member_count": len(members),
        "members": members,
    }
    manifest_path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return data


RAR_EXE = Path(r"C:\Program Files\WinRAR\Rar.exe")
RAR_MAX_BYTES = 200 * 1024 * 1024


def rar_listing_has_git(archive: Path) -> bool:
    out = subprocess.check_output(
        [str(RAR_EXE), "lb", str(archive)],
        text=True,
        errors="replace",
    )
    for line in out.splitlines():
        parts = line.replace("\\", "/").strip("/").split("/")
        if any(p == ".git" or p.endswith(".git") for p in parts):
            return True
    return False


def rar_stage(stage: Path, rar_path: Path) -> None:
    if not RAR_EXE.is_file():
        print(f"FAIL missing {RAR_EXE}", file=sys.stderr)
        raise SystemExit(1)
    if rar_path.exists():
        rar_path.unlink()
    cmd = [
        str(RAR_EXE),
        "a",
        "-r",
        "-m5",
        "-ep1",
        "-idq",
        "-y",
        "-x.git",
        "-x.git\\",
        "-x*\\.git\\*",
        str(rar_path),
        str(stage / "*"),
    ]
    subprocess.check_call(cmd)
    if rar_listing_has_git(rar_path):
        print("FAIL .git inside RAR", file=sys.stderr)
        raise SystemExit(1)
    size = rar_path.stat().st_size
    if size > RAR_MAX_BYTES:
        print(f"FAIL RAR {size} bytes > 200 MB", file=sys.stderr)
        raise SystemExit(1)


def zip_stage(stage: Path, zip_path: Path) -> None:
    if zip_path.exists():
        zip_path.unlink()
    with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        for p in stage.rglob("*"):
            if p.is_file():
                zf.write(p, p.relative_to(stage).as_posix())


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    ap.add_argument("--out-dir", type=Path, default=None)
    ap.add_argument("--check-exclude", action="store_true")
    args = ap.parse_args()
    root = args.root.resolve()
    excludes = load_excludes(root)

    if args.check_exclude:
        target = Path("sim/out/p_c1_t90_se_20261024_174911")
        ok = is_excluded(root, target, excludes)
        cite = root / target / "DO_NOT_CITE.md"
        print(f"exclude_list_has_174911={any('174911' in e for e in excludes)}")
        print(f"path_excluded={ok}")
        print(f"DO_NOT_CITE_exists={cite.is_file()}")
        if ok and cite.is_file():
            print("PACK_EXCLUDE_CHECK PASS")
            return 0
        print("PACK_EXCLUDE_CHECK FAIL", file=sys.stderr)
        return 1

    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    out_dir = (args.out_dir or (root / "out" / f"submission_{COMMIT7}_{ts}")).resolve()
    stage = out_dir / "stage"
    print(f"STAGE → {stage}", flush=True)
    build_stage(root, stage, excludes)

    if list(stage.rglob("DO_NOT_CITE.md")):
        print("FAIL DO_NOT_CITE leaked", file=sys.stderr)
        return 1
    if any("174911" in p.as_posix() for p in stage.rglob("*")):
        print("FAIL 174911 in stage", file=sys.stderr)
        return 1
    if any("_discard" in p.parts for p in stage.rglob("*")):
        print("FAIL _discard in stage", file=sys.stderr)
        return 1
    if any(p.name.startswith("_dbg_") for p in stage.rglob("*") if p.is_file()):
        print("FAIL _dbg_ leaked", file=sys.stderr)
        return 1
    if (stage / "sim" / "run_bg.ps1").exists():
        print("FAIL run_bg.ps1 leaked", file=sys.stderr)
        return 1
    if (stage / "tools" / "pdf_extract.py").exists():
        print("FAIL pdf_extract.py leaked", file=sys.stderr)
        return 1

    abs_hits = scan_abs_paths(stage)
    abs_md = out_dir / "ABS_PATHS.md"
    lines = [
        "# Absolute path residues in stage",
        "",
        f"count={len(abs_hits)}",
        "",
        "Must-keep candidates (sim runner fallbacks) are listed in `doc/submit/00_先读.md`「需按本机修改」。",
        "Workspace paths in elinx project files should have been rewritten to relative.",
        "",
    ]
    for h in abs_hits:
        lines.append(f"- `{h['path']}` — {', '.join(h['patterns'])}")
    abs_md.write_text("\n".join(lines) + "\n", encoding="utf-8")
    # also copy into stage for pack consumers
    copy_file(abs_md, stage / "ABS_PATHS.md")

    size_txt, total = size_report(stage)
    (out_dir / "PACK_SIZE.md").write_text(size_txt, encoding="utf-8")
    (stage / "PACK_SIZE.md").write_text(size_txt, encoding="utf-8")

    rar_path = out_dir / f"AFDX_ES_{COMMIT7}.rar"
    print(f"RAR → {rar_path}", flush=True)
    rar_stage(stage, rar_path)
    zip_path = out_dir / f"AFDX_ES_{COMMIT7}.internal.zip"
    print(f"ZIP internal → {zip_path}", flush=True)
    zip_stage(stage, zip_path)
    manifest_path = out_dir / "PACKAGE_MANIFEST.json"
    data = write_manifest(stage, manifest_path, zip_path, rar_path)
    data["rar_sha256"] = sha256_file(rar_path)
    data["rar_bytes"] = rar_path.stat().st_size
    data["zip_internal_sha256"] = sha256_file(zip_path)
    data["zip_internal_bytes"] = zip_path.stat().st_size
    data["abs_path_residue_count"] = len(abs_hits)
    data["stage_bytes"] = total
    manifest_path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(
        f"PACK_OK members={data['member_count']} rar_MiB={data['rar_bytes']/1024/1024:.2f} "
        f"zip_internal_MiB={data['zip_internal_bytes']/1024/1024:.2f} "
        f"abs_residue={len(abs_hits)} sha256={data['rar_sha256'][:16]}…"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
