#!/usr/bin/env python3
"""eLinx memory_bram+stat synth for afdx_app_top (EQ6HL130 target class).

Uses elinx/AFDX_top_sources.f (includes afdx_app_*). hierarchy -top afdx_app_top.
PASS = Yosys success + cells/altsyncram recorded. Not Fit/STA/GUI LUT.
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
TOP = "afdx_app_top"


def sha(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def parse_stat(log_text: str) -> dict:
    success = "Yosys execute success" in log_text
    cells = None
    alts = None
    hier = list(re.finditer(r"=== design hierarchy ===", log_text))
    if hier:
        block = log_text[hier[-1].start() :]
        m = re.search(r"Number of cells:\s+(\d+)", block)
        a = re.search(r"^\s*altsyncram\s+(\d+)\s*$", block, re.M)
        if m:
            cells = int(m.group(1))
        if a:
            alts = int(a.group(1))
    top_cells = None
    tops = list(re.finditer(rf"=== {TOP} ===", log_text))
    if tops:
        start = tops[-1].start()
        nxt = re.search(r"\n=== ", log_text[start + 20 :])
        top_block = log_text[start : start + 20 + nxt.start()] if nxt else log_text[start:]
        m = re.search(r"Number of cells:\s+(\d+)", top_block)
        if m:
            top_cells = int(m.group(1))
    return {
        "yosys_execute_success": success,
        "design_hierarchy_number_of_cells": cells,
        "design_hierarchy_altsyncram": alts,
        "afdx_app_top_hierarchical_cells": top_cells,
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", type=Path, default=None)
    args = ap.parse_args()
    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    out = (args.out or (ROOT / "out" / f"app_top_synth_{ts}")).resolve()
    out.mkdir(parents=True, exist_ok=True)

    commit = subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True
    ).strip()
    rels = []
    for raw in SOURCES_F.read_text(encoding="utf-8").splitlines():
        s = raw.strip()
        if s and not s.startswith("#"):
            rels.append(s.replace("\\", "/"))

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
    ys = out / "afdx_app_top_synth.ys"
    ys.write_text(
        f"# afdx_app_top synth {commit}\n"
        f"# Device class: EQ6HL130 / CSG484_H (resource check only)\n"
        f"read_verilog \\\n  {reads}\n"
        f"hierarchy -top {TOP}\nproc\nopt\nmemory_dff\nopt_clean\n"
        f'memory_collect\nmemory_bram -rules "{brams}"\n'
        f'techmap -map "{brams_map}"\nmemory_map\nopt\nstat\n',
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
    log_text = log.read_text(encoding="utf-8", errors="replace") if log.is_file() else ""
    stats = parse_stat(log_text)
    ok = proc.returncode == 0 and stats["yosys_execute_success"]
    status = {
        "schema": "afdx-app-top-synth-v1",
        "created_local": t0.isoformat(timespec="seconds"),
        "commit": commit,
        "top": TOP,
        "device_note": "EQ6HL130/CSG484_H — hierarchy cells/RAM only; not Fit/GUI LUT",
        "overall": "SYNTHESIS_PASS" if ok else "SYNTHESIS_FAIL",
        "exit_code": proc.returncode,
        "wall_seconds": (t1 - t0).total_seconds(),
        "cells": stats.get("design_hierarchy_number_of_cells"),
        "altsyncram": stats.get("design_hierarchy_altsyncram"),
        "afdx_app_top_hierarchical_cells": stats.get("afdx_app_top_hierarchical_cells"),
        "baseline_core_reference": {"cells": 106241, "altsyncram": 507, "note": "AFDX_top prior"},
        "log": str(log),
        "log_sha256": sha(log) if log.is_file() else None,
        "claim_boundary": (
            "PASS = eLinx memory_bram+stat on afdx_app_top. "
            "Not Fit/STA/GUI LUT. Compare to core 106241/507 as I until same flow."
        ),
    }
    (out / "run_status.json").write_text(
        json.dumps(status, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    print(json.dumps(status, ensure_ascii=False, indent=2))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
