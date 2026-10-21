#!/usr/bin/env python3
"""Prepare out/p2_gate_vo_<ts>/: copy baseline quartus_project, refresh RTL from
current workspace via AFDX_top_sources.f, re-run map + functional EDA VO.

Does NOT overwrite the baseline evidence directory.
"""
from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

ROOT = Path(r"C:\Workspace\diansai")
BIN = Path(r"C:\Program Files (x86)\eHiWay\eLinx3.0\bin\Passkey\bin")
BASE = ROOT / "out/baseline_full140_fit_sta_20261018_223600"
SOURCES_F = ROOT / "elinx/AFDX_top_sources.f"
DEVICE = "EP4SGX530KF43C2"
FAMILY = "Stratix IV"


def sha(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def parse_sources() -> list[str]:
    out = []
    for raw in SOURCES_F.read_text(encoding="utf-8").splitlines():
        s = raw.strip()
        if not s or s.startswith("#"):
            continue
        out.append(s.replace("\\", "/"))
    return out


def ensure_no_quartus() -> None:
    r = subprocess.run(
        [
            "powershell",
            "-NoProfile",
            "-Command",
            "Get-Process -Name quartus_map,quartus_fit,quartus_sta,quartus_eda,quartus "
            "-ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id",
        ],
        capture_output=True,
        text=True,
    )
    ids = [x.strip() for x in (r.stdout or "").splitlines() if x.strip()]
    if ids:
        raise SystemExit(f"other Quartus processes running: {ids}")


def run_cmd(out: Path, name: str, args: list[str], cwd: Path, timeout: int) -> dict:
    log = out / "logs" / f"{name}.log"
    log.parent.mkdir(parents=True, exist_ok=True)
    t0 = time.time()
    env = os.environ.copy()
    with log.open("w", encoding="utf-8", errors="replace") as stream:
        child = subprocess.Popen(args, cwd=str(cwd), env=env, stdout=stream, stderr=subprocess.STDOUT)
        try:
            rc = child.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            subprocess.run(["taskkill", "/PID", str(child.pid), "/T", "/F"], capture_output=True)
            rc = -1
    return {
        "name": name,
        "rc": rc,
        "wall_s": round(time.time() - t0, 1),
        "log": str(log.relative_to(out)).replace("\\", "/"),
        "args": args,
    }


def main() -> int:
    ensure_no_quartus()
    if not (BIN / "quartus_map.EXE").is_file():
        raise SystemExit(f"missing quartus_map at {BIN}")
    if not (BASE / "quartus_project/AFDX_top.qpf").is_file():
        raise SystemExit(f"missing baseline project under {BASE}")

    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    out = ROOT / f"out/p2_gate_vo_{ts}"
    proj = out / "quartus_project"
    src_dir = out / "source"
    out.mkdir(parents=True, exist_ok=True)
    (out / "logs").mkdir(exist_ok=True)

    # Copy project skeleton (skip huge db/incremental to force clean map from new QSF)
    print(f"OUT={out}")
    shutil.copytree(
        BASE / "quartus_project",
        proj,
        ignore=shutil.ignore_patterns("db", "incremental_db", "output_files", "*.rpt", "*.summary"),
    )
    # Keep SDC from baseline parent if referenced
    sdc_src = BASE / "AFDX_top.sdc"
    if sdc_src.is_file():
        shutil.copy2(sdc_src, out / "AFDX_top.sdc")

    rels = parse_sources()
    manifest = []
    for rel in rels:
        work = ROOT / Path(*rel.split("/"))
        if not work.is_file():
            raise SystemExit(f"missing {rel}")
        dest = src_dir / Path(*rel.split("/"))
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(work, dest)
        manifest.append({"path": rel, "sha256": sha(dest), "bytes": dest.stat().st_size})

    # Rewrite QSF: header + current sources under out/source + SDC
    qsf_lines = [
        f'set_global_assignment -name FAMILY "{FAMILY}"',
        f"set_global_assignment -name DEVICE {DEVICE}",
        "set_global_assignment -name TOP_LEVEL_ENTITY AFDX_top",
        "set_global_assignment -name VERILOG_INPUT_VERSION VERILOG_2001",
        "set_global_assignment -name PROJECT_OUTPUT_DIRECTORY output_files",
        "set_global_assignment -name NUM_PARALLEL_PROCESSORS 4",
    ]
    for rel in rels:
        abs_v = (src_dir / Path(*rel.split("/"))).as_posix()
        # Quartus on Windows prefers forward slashes in QSF historically used here
        qsf_lines.append(f'set_global_assignment -name VERILOG_FILE "{abs_v}"')
    sdc_abs = (out / "AFDX_top.sdc").as_posix()
    qsf_lines.append(f'set_global_assignment -name SDC_FILE "{sdc_abs}"')
    qsf_lines.append("")
    qsf_lines.append('set_global_assignment -name LAST_QUARTUS_VERSION "13.0 SP1"')
    (proj / "AFDX_top.qsf").write_text("\n".join(qsf_lines) + "\n", encoding="ascii", newline="\n")

    (out / "candidate_manifest.json").write_text(
        json.dumps(
            {
                "created_local": datetime.now().astimezone().isoformat(timespec="seconds"),
                "sources_f": "elinx/AFDX_top_sources.f",
                "count": len(manifest),
                "files": manifest,
                "baseline_copied_from": str(BASE / "quartus_project"),
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )

    steps = {}
    map_exe = str(BIN / "quartus_map.EXE")
    eda_exe = str(BIN / "quartus_eda.EXE")
    steps["map"] = run_cmd(out, "map", [map_exe, "AFDX_top", "-c", "AFDX_top"], proj, 21600)
    print("map", steps["map"])
    if steps["map"]["rc"] != 0:
        (out / "run_status.json").write_text(json.dumps({"status": "FAIL", "steps": steps}, indent=2) + "\n", encoding="utf-8")
        return 1

    eda_out = proj / "simulation" / "modelsim_functional"
    eda_out.mkdir(parents=True, exist_ok=True)
    steps["eda"] = run_cmd(
        out,
        "eda",
        [
            eda_exe,
            "AFDX_top",
            "-c",
            "AFDX_top",
            "--simulation=on",
            "--format=verilog",
            "--tool=modelsim",
            "--functional=on",
            f"--output_directory={eda_out.as_posix()}",
        ],
        proj,
        7200,
    )
    print("eda", steps["eda"])

    vo_candidates = list(eda_out.glob("*.vo")) + list(proj.glob("**/AFDX_top.vo"))
    vo = None
    for c in vo_candidates:
        if c.is_file():
            vo = c
            break
    status = {
        "status": "PASS" if steps["eda"]["rc"] == 0 and vo else "FAIL",
        "steps": steps,
        "vo": str(vo) if vo else None,
        "vo_sha256": sha(vo) if vo else None,
        "vo_bytes": vo.stat().st_size if vo else None,
    }
    (out / "run_status.json").write_text(json.dumps(status, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(status, indent=2))
    return 0 if status["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
