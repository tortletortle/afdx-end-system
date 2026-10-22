#!/usr/bin/env python3
"""Reproduce eLinx memory_bram+stat synthesis on baseline-full140 RTL.

Pins inputs to git tag baseline-full140 (commit e32ad0a…), freezes a local
source tree, runs eLinx_synthesis, and records cells/altsyncram.

Does NOT claim Fit/STA/GUI LUT / netlist business / area improvement.
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
TAG = "baseline-full140"
EXPECTED_COMMIT = "e32ad0a811f00b2d71aef02ef13d0bfbca174e46"


def sha(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def git(*args: str) -> str:
    return subprocess.check_output(["git", *args], cwd=ROOT, text=True).strip()


def write_json(path: Path, data: dict) -> None:
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def parse_sources() -> list[str]:
    lines = []
    for raw in SOURCES_F.read_text(encoding="utf-8").splitlines():
        s = raw.strip()
        if not s or s.startswith("#"):
            continue
        lines.append(s.replace("\\", "/"))
    return lines


def peel_tag() -> str:
    return git("rev-parse", f"{TAG}^{{commit}}")


def blob_sha_at(commit: str, rel: str) -> str:
    # git hash-object style: blob id, not content SHA256
    return git("rev-parse", f"{commit}:{rel}")


def prepare(out: Path) -> dict:
    commit = peel_tag()
    if commit != EXPECTED_COMMIT:
        raise SystemExit(f"tag {TAG} peels to {commit}, expected {EXPECTED_COMMIT}")

    src_dir = out / "source"
    src_dir.mkdir(parents=True, exist_ok=True)
    rels = parse_sources()
    records = []
    mismatches = []

    for rel in rels:
        work = ROOT / Path(*rel.split("/"))
        if not work.is_file():
            raise SystemExit(f"missing workspace file: {rel}")
        # content must match baseline commit blob
        work_blob = git("hash-object", "--", str(work))
        base_blob = blob_sha_at(commit, rel)
        if work_blob != base_blob:
            mismatches.append({"path": rel, "work_blob": work_blob, "baseline_blob": base_blob})
        target = src_dir / Path(*rel.split("/"))
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(work, target)
        records.append(
            {
                "kind": "rtl",
                "rel": rel,
                "path": str(target),
                "sha256": sha(target),
                "git_blob": work_blob,
                "bytes": target.stat().st_size,
            }
        )

    if mismatches:
        write_json(out / "baseline_mismatch.json", {"mismatches": mismatches})
        raise SystemExit(f"workspace RTL differs from {TAG}: {len(mismatches)} files (see baseline_mismatch.json)")

    out_posix = str(out).replace("\\", "/")
    brams = str(MAPDIR / "brams.txt").replace("\\", "/")
    brams_map = str(MAPDIR / "brams_map.v").replace("\\", "/")
    reads = " \\\n  ".join(f"{out_posix}/source/{r}" for r in rels)
    ys_body = f"""# Auto-generated for {TAG} ({commit})
# Flow: memory_bram + techmap + memory_map + stat (no write_verilog, no ABC)
read_verilog \\
  {reads}
hierarchy -top AFDX_top
proc
opt
memory_dff
opt_clean
memory_collect
memory_bram -rules "{brams}"
techmap -map "{brams_map}"
memory_map
opt
stat
"""
    ys_path = out / "AFDX_top_synth_frozen.ys"
    ys_path.write_text(ys_body, encoding="utf-8", newline="\n")

    for name in ("brams.txt", "brams_map.v"):
        p = MAPDIR / name
        records.append({"kind": "technology_mapping", "path": str(p), "sha256": sha(p), "bytes": p.stat().st_size})
    records.append({"kind": "tool", "path": str(TOOL), "sha256": sha(TOOL), "bytes": TOOL.stat().st_size})
    records.append({"kind": "script", "path": str(ys_path), "sha256": sha(ys_path), "bytes": ys_path.stat().st_size})

    manifest = {
        "schema": "baseline-full140-synth-v1",
        "created_local": datetime.now().astimezone().isoformat(timespec="seconds"),
        "tag": TAG,
        "commit": commit,
        "top": "AFDX_top",
        "rtl_count": len(rels),
        "sources_f": str(SOURCES_F),
        "sources_f_sha256": sha(SOURCES_F),
        "records": records,
        "claim_boundary": (
            "PASS only means eLinx memory_bram+stat succeeded on this frozen input. "
            "Not Fit/STA/GUI LUT/netlist business. Do not write area improved vs r6 "
            "unless numbers are from this log."
        ),
    }
    write_json(out / "candidate_manifest.json", manifest)
    status = {
        "schema_version": 1,
        "created_local": manifest["created_local"],
        "tag": TAG,
        "commit": commit,
        "root": str(out),
        "rtl_count": len(rels),
        "manifest_sha256": sha(out / "candidate_manifest.json"),
        "synthesis": {"status": "NOT_RUN"},
        "overall": "PREPARED",
    }
    write_json(out / "run_status.json", status)
    return status


def parse_stat(log_text: str) -> dict:
    success = "Yosys execute success" in log_text
    # Prefer trailing "design hierarchy" dump (flattened cell/altsyncram).
    # Fallback: last "Number of cells" + last altsyncram in the log.
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
    if cells is None:
        matches = list(re.finditer(r"Number of cells:\s+(\d+)", log_text))
        if matches:
            cells = int(matches[-1].group(1))
    if alts is None:
        alts_matches = list(re.finditer(r"^\s*altsyncram\s+(\d+)\s*$", log_text, re.M))
        if alts_matches:
            alts = int(alts_matches[-1].group(1))
    # Hierarchical (non-flattened) AFDX_top line, for cross-check only
    hier_cells = None
    tops = list(re.finditer(r"=== AFDX_top ===", log_text))
    if tops:
        # stop at next === section
        start = tops[-1].start()
        nxt = re.search(r"\n=== ", log_text[start + 20 :])
        top_block = log_text[start : start + 20 + nxt.start()] if nxt else log_text[start:]
        m = re.search(r"Number of cells:\s+(\d+)", top_block)
        if m:
            hier_cells = int(m.group(1))
    return {
        "yosys_execute_success": success,
        "design_hierarchy_number_of_cells": cells,
        "design_hierarchy_altsyncram": alts,
        "afdx_top_hierarchical_cells": hier_cells,
        "number_of_cells_max": cells,
        "altsyncram_last": alts,
    }


def synth(out: Path) -> dict:
    if not TOOL.is_file():
        raise SystemExit(f"missing tool: {TOOL}")
    out = out.resolve()
    ys = (out / "AFDX_top_synth_frozen.ys").resolve()
    log = (out / "synth.log").resolve()
    stdout_path = out / "synth_stdout.txt"
    cmd = [str(TOOL), "-s", str(ys), "-l", str(log)]
    t0 = datetime.now().astimezone()
    proc = subprocess.run(cmd, cwd=str(out), capture_output=True, text=True)
    t1 = datetime.now().astimezone()
    stdout_path.write_text(proc.stdout or "", encoding="utf-8", errors="replace")
    (out / "synth_stderr.txt").write_text(proc.stderr or "", encoding="utf-8", errors="replace")
    log_text = log.read_text(encoding="utf-8", errors="replace") if log.is_file() else ""
    stats = parse_stat(log_text)
    ok = proc.returncode == 0 and stats["yosys_execute_success"]
    synthesis = {
        "status": "PASS" if ok else "FAIL",
        "exit_code": proc.returncode,
        "started_local": t0.isoformat(timespec="seconds"),
        "finished_local": t1.isoformat(timespec="seconds"),
        "wall_seconds": (t1 - t0).total_seconds(),
        "command": cmd,
        "log": str(log),
        "log_sha256": sha(log) if log.is_file() else None,
        "success_marker": "Yosys execute success" if stats["yosys_execute_success"] else "",
        **stats,
        "tool_path": str(TOOL),
        "tool_sha256": sha(TOOL),
        "script": str(ys),
        "notes": (
            "Area numbers are for this run only. Historical r6 = 39580 cells / 475 altsyncram; "
            "do not claim improvement without comparing these fields."
        ),
    }
    status = json.loads((out / "run_status.json").read_text(encoding="utf-8"))
    status["synthesis"] = synthesis
    status["overall"] = "SYNTHESIS_PASS" if ok else "SYNTHESIS_FAIL"
    status["updated_local"] = t1.isoformat(timespec="seconds")
    write_json(out / "run_status.json", status)
    return status


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("action", choices=["prepare", "synth", "all"])
    ap.add_argument(
        "--out",
        default="",
        help="evidence directory; default out/baseline_full140_synth_<timestamp>",
    )
    args = ap.parse_args()
    if args.out:
        out = Path(args.out)
    else:
        stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        out = ROOT / "out" / f"baseline_full140_synth_{stamp}"
    out.mkdir(parents=True, exist_ok=True)
    (out / "run_baseline_full140_synth.py").write_text(
        Path(__file__).read_text(encoding="utf-8"), encoding="utf-8"
    )

    if args.action in ("prepare", "all"):
        prepare(out)
        print(f"PREPARED {out}")
    if args.action in ("synth", "all"):
        if not (out / "AFDX_top_synth_frozen.ys").is_file():
            raise SystemExit("run prepare first")
        status = synth(out)
        print(json.dumps({
            "overall": status["overall"],
            "exit_code": status["synthesis"]["exit_code"],
            "cells_max": status["synthesis"].get("number_of_cells_max"),
            "altsyncram_last": status["synthesis"].get("altsyncram_last"),
            "out": str(out),
        }, ensure_ascii=False))
        return 0 if status["overall"] == "SYNTHESIS_PASS" else 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
