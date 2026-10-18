#!/usr/bin/env python3
"""Retired 2026-10-03 review packer. Refuses to overwrite its fixed output."""
from __future__ import annotations

import hashlib
import json
import shutil
import zipfile
from datetime import datetime, timezone, timedelta
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
STAMP = "20261003"
OUT_DIR = ROOT / "out" / f"submission_{STAMP}_report"
STAGE = OUT_DIR / "tree"
ZIP_PATH = OUT_DIR / f"AFDX_选题一_评阅源与仿真_{STAMP}.zip"

SKIP_DIR_NAMES = {
    "__pycache__", ".git", "work", "work_iso", "transcripts",
    "历史", "out",
}


def copy_tree(src: Path, dst: Path, *, skip_suffixes=(), extra_skip_dirs=()):
    skip_dirs = SKIP_DIR_NAMES | set(extra_skip_dirs)
    dst.mkdir(parents=True, exist_ok=True)
    for p in src.rglob("*"):
        if any(part in skip_dirs for part in p.relative_to(src).parts):
            continue
        if p.is_dir():
            continue
        if p.suffix.lower() in skip_suffixes:
            continue
        if p.name.endswith(".pyc"):
            continue
        rel = p.relative_to(src)
        target = dst / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(p, target)


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    if OUT_DIR.exists() or STAGE.exists() or ZIP_PATH.exists():
        raise SystemExit(
            f"Refusing to overwrite historical package artifacts under {OUT_DIR}. "
            "Use a new versioned output path for a new package."
        )
    STAGE.mkdir(parents=True, exist_ok=True)

    copy_tree(ROOT / "rtl", STAGE / "rtl")
    copy_tree(ROOT / "sim" / "tb", STAGE / "sim" / "tb")
    copy_tree(ROOT / "sim" / "vec", STAGE / "sim" / "vec")
    copy_tree(ROOT / "sim" / "bfm", STAGE / "sim" / "bfm")
    copy_tree(ROOT / "sim" / "chk", STAGE / "sim" / "chk")
    copy_tree(ROOT / "sw" / "golden", STAGE / "sw" / "golden")
    copy_tree(
        ROOT / "elinx",
        STAGE / "elinx",
        skip_suffixes={".v", ".vo", ".sof", ".pof", ".ddb", ".tdb", ".cdb", ".idb",
                       ".rcfdb", ".dat", ".kpt", ".hdb", ".hbdb"},
        extra_skip_dirs={"db", "incremental_db", "output_files", "simulation", "runs"},
    )
    copy_tree(ROOT / "tools", STAGE / "tools")

    doc_skip = {
        "评阅扣分底稿_20261003.md",
        "赛题一冲高分工程收口计划书_20261001.md",
    }
    doc_dst = STAGE / "doc"
    doc_dst.mkdir(parents=True, exist_ok=True)
    for p in (ROOT / "doc").iterdir():
        if not p.is_file():
            continue
        if p.name in doc_skip:
            continue
        if p.suffix.lower() in {".md", ".yaml", ".svh", ".csv"}:
            shutil.copy2(p, doc_dst / p.name)

    root_files = [
        "README_tools.md",
        "目录导览_20261001.md",
        "AFDX端系统_总体设计书.md",
        "sim/README.md",
        "sim/tests.manifest",
        "sim/run_regress.ps1",
        "sim/regress_verdict.ps1",
        "sim/compile.tcl",
        "sim/run_one.tcl",
        "sim/freeze_regress.py",
        "sim/freeze_full70.py",
        "rtl/README.md",
        "elinx/README.txt",
        "tools_lint.ps1",
    ]
    for rel in root_files:
        src = ROOT / rel
        if src.is_file():
            dst = STAGE / rel
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dst)

    ev = STAGE / "evidence" / "rtl_regress_70"
    ev.mkdir(parents=True, exist_ok=True)
    full = ROOT / "sim" / "out" / "full"
    for name in ("regress.csv", "compile_console.txt"):
        src = full / name
        if src.is_file():
            shutil.copy2(src, ev / name)
    for src in sorted(full.glob("T*_console.txt")):
        shutil.copy2(src, ev / src.name)
    ev_json = full / "regress_evidence.json"
    if ev_json.is_file():
        shutil.copy2(ev_json, ev / "regress_evidence.json")

    waves_src = ROOT / "evidence" / "waves"
    if waves_src.is_dir():
        copy_tree(waves_src, STAGE / "evidence" / "waves")

    for name in ("00_先读_提交范围与汇报口径.md", "01_AI工具使用声明.md"):
        src = ROOT / "doc" / name
        if not src.is_file():
            src = OUT_DIR / name
        if src.is_file():
            shutil.copy2(src, STAGE / name)
            if name.startswith("00_"):
                shutil.copy2(src, STAGE / "README.md")

    files = [p for p in STAGE.rglob("*") if p.is_file()]
    lines = []
    for p in sorted(files, key=lambda x: x.relative_to(STAGE).as_posix().lower()):
        rel = p.relative_to(STAGE).as_posix()
        lines.append(f"{sha256_file(p)}  {p.stat().st_size:12d}  {rel}")
    (STAGE / "FILELIST_SHA256.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")

    tz = timezone(timedelta(hours=8))
    meta = {
        "package": ZIP_PATH.name,
        "created_utc8": datetime.now(tz).isoformat(timespec="seconds"),
        "source_root": str(ROOT),
        "file_count": len(files) + 1,
        "not_included": [
            "out/arena-debug (diagnostics, netlists, VCD archives)",
            "sim/out except copied 70/70 consoles",
            "doc/历史",
            ".git",
            "post-map VO / SDF / Fit databases",
            "root README Continue12 snapshot (ZIP README is 00_先读)",
        ],
        "claim_limit": "Questa RTL 70/70 + in-ZIP BRAM synth log + evidence/waves PNG; not gate-level frame; not 125 MHz STA",
        "regress_csv_sha256": sha256_file(full / "regress.csv") if (full / "regress.csv").is_file() else None,
    }
    (STAGE / "PACKAGE_META.json").write_text(json.dumps(meta, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    with zipfile.ZipFile(ZIP_PATH, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
        for p in sorted(STAGE.rglob("*"), key=lambda x: x.as_posix().lower()):
            if p.is_file():
                zf.write(p, arcname=p.relative_to(STAGE).as_posix())

    zip_sha = sha256_file(ZIP_PATH)
    (OUT_DIR / "ZIP_SHA256.txt").write_text(
        f"{zip_sha}  {ZIP_PATH.stat().st_size}  {ZIP_PATH.name}\n",
        encoding="utf-8",
    )
    print(f"ZIP={ZIP_PATH}")
    print(f"bytes={ZIP_PATH.stat().st_size}")
    print(f"sha256={zip_sha}")
    print(f"files_in_tree={len(files)+2}")


if __name__ == "__main__":
    main()
