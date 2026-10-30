#!/usr/bin/env python3
"""Export a post-synthesis Verilog netlist for afdx_app_top.

Same 53 sources and the same eLinx memory_bram flow as
out/app_top_synth_bram3/afdx_app_top_synth.ys, then write_verilog.
Does not modify elinx/gui_afdx.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import subprocess
import sys
from datetime import datetime
from pathlib import Path

ROOT = Path(r"C:\Workspace\diansai")
TOOL = Path(r"C:\Program Files (x86)\eHiWay\eLinx3.0\bin\shell\bin\eLinx_synthesis.exe")
MAPDIR = Path(r"C:\Program Files (x86)\eHiWay\eLinx3.0\bin\shell\share\stratix\common")
SOURCES_F = ROOT / "elinx" / "AFDX_top_sources.f"
BASELINE_YS = ROOT / "out" / "app_top_synth_bram3" / "afdx_app_top_synth.ys"
TOP = "afdx_app_top"


def sha(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def load_rels() -> list[str]:
    rels = []
    for raw in SOURCES_F.read_text(encoding="utf-8").splitlines():
        s = raw.strip()
        if s and not s.startswith("#"):
            rels.append(s.replace("\\", "/"))
    return rels


def baseline_rels() -> list[str]:
    text = BASELINE_YS.read_text(encoding="utf-8")
    found = re.findall(r"source/([^\s\\]+)", text)
    # paths in the ys are source/rtl/...
    return [p.replace("\\", "/") for p in found]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument(
        "--clean-ids",
        action="store_true",
        help="flatten then rename -enumerate before write_verilog",
    )
    args = ap.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)

    rels = load_rels()
    base = baseline_rels()
    if rels != base:
        raise SystemExit(
            f"source list mismatch: file={len(rels)} baseline_ys={len(base)}"
        )
    if len(rels) != 53:
        raise SystemExit(f"expected 53 sources, got {len(rels)}")

    src_dir = out / "source"
    for rel in rels:
        src = ROOT / Path(*rel.split("/"))
        if not src.is_file():
            raise SystemExit(f"missing {rel}")
        dst = src_dir / Path(*rel.split("/"))
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)

    out_posix = str(out).replace("\\", "/")
    brams = str(MAPDIR / "brams.txt").replace("\\", "/")
    brams_map = str(MAPDIR / "brams_map.v").replace("\\", "/")
    reads = " \\\n  ".join(f"{out_posix}/source/{r}" for r in rels)
    vo_path = out / "afdx_app_top.vo"
    vo_posix = str(vo_path).replace("\\", "/")
    ys = out / "afdx_app_top_vo.ys"
    tail = (
        "flatten\nselect -module afdx_app_top\nrename -enumerate\nstat\n"
        if args.clean_ids
        else "stat\n"
    )
    ys.write_text(
        f"# afdx_app_top post-synth VO export\n"
        f"# sources match out/app_top_synth_bram3 ({len(rels)} files)\n"
        f"# clean_ids={args.clean_ids}\n"
        f"read_verilog \\\n  {reads}\n"
        f"hierarchy -top {TOP}\nproc\nopt\nmemory_dff\nopt_clean\n"
        f'memory_collect\nmemory_bram -rules "{brams}"\n'
        f'techmap -map "{brams_map}"\nmemory_map\nopt\n'
        f"{tail}"
        f'write_verilog -noattr "{vo_posix}"\n',
        encoding="utf-8",
        newline="\n",
    )

    if not TOOL.is_file():
        raise SystemExit(f"missing tool: {TOOL}")

    log = out / "synth.log"
    t0 = datetime.now().astimezone()
    proc = subprocess.run(
        [str(TOOL), "-s", str(ys), "-l", str(log)],
        cwd=str(out),
        capture_output=True,
        text=True,
    )
    t1 = datetime.now().astimezone()
    (out / "synth_stdout.txt").write_text(proc.stdout or "", encoding="utf-8")
    (out / "synth_stderr.txt").write_text(proc.stderr or "", encoding="utf-8")
    vo_ok = vo_path.is_file() and vo_path.stat().st_size > 0
    status = {
        "schema": "afdx-app-top-vo-export-v1",
        "created_local": t0.isoformat(timespec="seconds"),
        "finished_local": t1.isoformat(timespec="seconds"),
        "top": TOP,
        "source_count": len(rels),
        "clean_ids": bool(args.clean_ids),
        "exit_code": proc.returncode,
        "wall_seconds": (t1 - t0).total_seconds(),
        "vo": str(vo_path),
        "vo_bytes": vo_path.stat().st_size if vo_ok else 0,
        "vo_sha256": sha(vo_path) if vo_ok else None,
        "log": str(log),
        "overall": "VO_EXPORT_PASS" if proc.returncode == 0 and vo_ok else "VO_EXPORT_FAIL",
    }
    (out / "vo_export_status.json").write_text(
        json.dumps(status, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    print(json.dumps(status, ensure_ascii=False, indent=2))
    return 0 if status["overall"] == "VO_EXPORT_PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
