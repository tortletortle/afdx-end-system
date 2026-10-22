#!/usr/bin/env python3
"""Isolated Quartus map+fit+STA on baseline-full140 (commit e32ad0a).

Freezes RTL blobs matching tag baseline-full140 into an isolated project,
runs Passkey Quartus II 13.0.1 map → fit → sta (detail via sta_post_fit.tcl).

Proxy device: EP4SGX530KF43C2. NOT board signoff. NOT GUI LUT.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

ROOT = Path(r"C:\Workspace\diansai")
BIN = Path(r"C:\Program Files (x86)\eHiWay\eLinx3.0\bin\Passkey\bin")
SOURCES_F = ROOT / "elinx" / "AFDX_top_sources.f"
TAG = "baseline-full140"
EXPECTED_COMMIT = "e32ad0a811f00b2d71aef02ef13d0bfbca174e46"
DEVICE = "EP4SGX530KF43C2"
FAMILY = "Stratix IV"


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
    return git("rev-parse", f"{commit}:{rel}")


def ensure_no_other_quartus() -> None:
    names = {"quartus_map", "quartus_fit", "quartus_sta", "quartus_sh", "quartus"}
    out = subprocess.run(
        ["powershell", "-NoProfile", "-Command",
         "Get-Process -Name quartus_map,quartus_fit,quartus_sta,quartus_sh,quartus "
         "-ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id"],
        capture_output=True, text=True,
    )
    ids = [x.strip() for x in (out.stdout or "").splitlines() if x.strip()]
    if ids:
        raise SystemExit(f"other Quartus processes running: {ids}")


def prepare(out: Path) -> dict:
    commit = peel_tag()
    if commit != EXPECTED_COMMIT:
        raise SystemExit(f"tag {TAG} peels to {commit}, expected {EXPECTED_COMMIT}")

    proj = out / "quartus_project"
    src_dir = out / "source"
    sta_dir = out / "sta"
    for d in (proj, src_dir, sta_dir, out / "logs"):
        d.mkdir(parents=True, exist_ok=True)

    rels = parse_sources()
    records = []
    mismatches = []
    for rel in rels:
        work = ROOT / Path(*rel.split("/"))
        if not work.is_file():
            raise SystemExit(f"missing workspace file: {rel}")
        work_blob = git("hash-object", "--", str(work))
        base_blob = blob_sha_at(commit, rel)
        if work_blob != base_blob:
            mismatches.append({"path": rel, "work_blob": work_blob, "baseline_blob": base_blob})
        target = src_dir / Path(*rel.split("/"))
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(work, target)
        records.append({
            "kind": "rtl", "rel": rel, "path": str(target),
            "sha256": sha(target), "git_blob": work_blob, "bytes": target.stat().st_size,
        })
    if mismatches:
        write_json(out / "baseline_mismatch.json", {"mismatches": mismatches})
        if not getattr(prepare, "_allow_mismatch", False):
            raise SystemExit(f"workspace RTL differs from {TAG}: {len(mismatches)} files")
        # Timing-iteration mode: keep current workspace copies, record drift.

    sdc_src = ROOT / "elinx" / "sdc" / "AFDX_top.sdc"
    sdc_dst = out / "AFDX_top.sdc"
    shutil.copy2(sdc_src, sdc_dst)
    records.append({"kind": "sdc", "path": str(sdc_dst), "sha256": sha(sdc_dst), "bytes": sdc_dst.stat().st_size})

    # Copy STA helper scripts; rewrite default out path via env at runtime.
    for name in ("sta_post_fit.tcl", "check_sdc_8ns.tcl"):
        src = ROOT / "elinx" / "prj" / "quartus" / name
        if not src.is_file():
            raise SystemExit(f"missing {src}")
        dst = proj / name
        shutil.copy2(src, dst)
        records.append({"kind": "tcl", "path": str(dst), "sha256": sha(dst)})

    out_posix = str(out).replace("\\", "/")
    src_posix = str(src_dir).replace("\\", "/")
    qsf_lines = [
        f'set_global_assignment -name FAMILY "{FAMILY}"',
        f"set_global_assignment -name DEVICE {DEVICE}",
        "set_global_assignment -name TOP_LEVEL_ENTITY AFDX_top",
        "set_global_assignment -name VERILOG_INPUT_VERSION VERILOG_2001",
        "set_global_assignment -name PROJECT_OUTPUT_DIRECTORY output_files",
        "set_global_assignment -name NUM_PARALLEL_PROCESSORS 4",
    ]
    for rel in rels:
        qsf_lines.append(f'set_global_assignment -name VERILOG_FILE "{src_posix}/{rel}"')
    qsf_lines.append(f'set_global_assignment -name SDC_FILE "{out_posix}/AFDX_top.sdc"')
    qsf = proj / "AFDX_top.qsf"
    qsf.write_text("\n".join(qsf_lines) + "\n", encoding="utf-8", newline="\n")
    qpf = proj / "AFDX_top.qpf"
    qpf.write_text(
        "QUARTUS_VERSION = \"13.0\"\nPROJECT_REVISION = \"AFDX_top\"\n",
        encoding="utf-8", newline="\n",
    )
    records.append({"kind": "qsf", "path": str(qsf), "sha256": sha(qsf)})

    for exe in ("quartus_map.EXE", "quartus_fit.EXE", "quartus_sta.EXE"):
        p = BIN / exe
        if not p.is_file():
            raise SystemExit(f"missing tool: {p}")
        records.append({"kind": "tool", "name": exe, "path": str(p), "sha256": sha(p)})

    manifest = {
        "schema": "baseline-full140-fit-sta-v1",
        "created_local": datetime.now().astimezone().isoformat(timespec="seconds"),
        "tag": TAG,
        "commit": commit,
        "device": DEVICE,
        "family": FAMILY,
        "clock_period_ns": 8.0,
        "rtl_count": len(rels),
        "records": records,
        "claim_boundary": (
            "PASS means map+fit rc=0 and STA detail produced post_fit_summary for this "
            f"frozen {TAG} input on proxy {DEVICE}. Not board signoff, not SDF, not GUI LUT, "
            "not netlist business. Do not reuse historical Fmax 128.44 as this run."
        ),
    }
    write_json(out / "candidate_manifest.json", manifest)
    status = {
        "schema_version": 1,
        "created_local": manifest["created_local"],
        "tag": TAG,
        "commit": commit,
        "device": DEVICE,
        "root": str(out),
        "project": str(proj),
        "manifest_sha256": sha(out / "candidate_manifest.json"),
        "steps": {},
        "overall": "PREPARED",
        "signoff": "NOT_CLAIMED",
    }
    write_json(out / "run_status.json", status)
    return status


def run_step(out: Path, name: str, args: list[str], timeout_s: int, env_extra: dict | None = None) -> dict:
    logs = out / "logs"
    log = logs / f"{name}.log"
    if log.exists():
        raise RuntimeError(f"refusing overwrite: {log}")
    env = os.environ.copy()
    env["PATH"] = str(BIN) + os.pathsep + env.get("PATH", "")
    env["PYTHONIOENCODING"] = "utf-8"
    if env_extra:
        env.update(env_extra)
    proj = out / "quartus_project"
    t0 = time.monotonic()
    started = datetime.now().astimezone().isoformat(timespec="seconds")
    with log.open("xb") as stream:
        child = subprocess.Popen(args, cwd=str(proj), env=env, stdout=stream, stderr=subprocess.STDOUT)
        try:
            rc = child.wait(timeout=timeout_s)
        except subprocess.TimeoutExpired:
            subprocess.run(["taskkill", "/PID", str(child.pid), "/T", "/F"], capture_output=True)
            child.wait()
            rc = -1
    item = {
        "name": name,
        "command": args,
        "started_local": started,
        "finished_local": datetime.now().astimezone().isoformat(timespec="seconds"),
        "wall_seconds": round(time.monotonic() - t0, 2),
        "rc": rc,
        "status": "PASS" if rc == 0 else "FAIL",
        "log": str(log),
        "log_sha256": sha(log),
        "log_bytes": log.stat().st_size,
    }
    return item


def parse_summary(text: str) -> dict:
    out = {}
    for key in ("Fitter Status", "Mapper Status", "Logic utilization",
                "Combinational ALUTs", "Dedicated logic registers",
                "Total block memory bits", "Device"):
        m = re.search(rf"^{re.escape(key)}\s*:\s*(.+)$", text, re.M)
        if m:
            out[key] = m.group(1).strip()
    return out


def parse_sta_summary(path: Path) -> dict:
    if not path.is_file():
        return {}
    text = path.read_text(encoding="utf-8", errors="replace")
    setup = re.findall(r"SETUP clock=(\S+) slack=(\S+) tns=(\S+)", text)
    hold = re.findall(r"HOLD  clock=(\S+) slack=(\S+) tns=(\S+)", text)
    fmax = re.findall(r"FMAX  clock=(\S+) fmax_MHz=(\S+) restricted_MHz=(\S+)", text)
    return {
        "raw": text,
        "setup": [{"clock": a, "slack": b, "tns": c} for a, b, c in setup],
        "hold": [{"clock": a, "slack": b, "tns": c} for a, b, c in hold],
        "fmax": [{"clock": a, "fmax_MHz": b, "restricted_MHz": c} for a, b, c in fmax],
    }


def execute(out: Path) -> dict:
    ensure_no_other_quartus()
    status_path = out / "run_status.json"
    status = json.loads(status_path.read_text(encoding="utf-8"))
    status["overall"] = "RUNNING"
    write_json(status_path, status)

    map_exe = str(BIN / "quartus_map.EXE")
    fit_exe = str(BIN / "quartus_fit.EXE")
    sta_exe = str(BIN / "quartus_sta.EXE")

    steps = {}
    try:
        steps["map"] = run_step(out, "map", [map_exe, "AFDX_top", "-c", "AFDX_top"], 21600)
        if steps["map"]["rc"] != 0:
            raise RuntimeError("map failed")
        map_sum = out / "quartus_project" / "output_files" / "AFDX_top.map.summary"
        steps["map"]["summary"] = parse_summary(
            map_sum.read_text(encoding="utf-8", errors="replace") if map_sum.is_file() else ""
        )

        steps["fit"] = run_step(out, "fit", [fit_exe, "AFDX_top", "-c", "AFDX_top"], 21600)
        if steps["fit"]["rc"] != 0:
            raise RuntimeError("fit failed")
        fit_sum = out / "quartus_project" / "output_files" / "AFDX_top.fit.summary"
        steps["fit"]["summary"] = parse_summary(
            fit_sum.read_text(encoding="utf-8", errors="replace") if fit_sum.is_file() else ""
        )

        steps["sta_corners"] = run_step(
            out, "sta_corners", [sta_exe, "AFDX_top", "-c", "AFDX_top"], 7200
        )
        if steps["sta_corners"]["rc"] != 0:
            raise RuntimeError("sta_corners failed")

        sta_out = (out / "sta").resolve()
        steps["sta_detail"] = run_step(
            out, "sta_detail",
            [sta_exe, "-t", "sta_post_fit.tcl"],
            7200,
            {"DIANSAI_STA_OUT": sta_out.as_posix()},
        )
        detail_log = (out / "logs" / "sta_detail.log").read_text(encoding="utf-8", errors="replace")
        if "POST_FIT_STA_DONE" not in detail_log:
            raise RuntimeError("STA detail missing POST_FIT_STA_DONE")
        summary_txt = out / "sta" / "post_fit_summary.txt"
        if not summary_txt.is_file():
            raise RuntimeError("missing post_fit_summary.txt")
        steps["sta_detail"]["post_fit_summary"] = parse_sta_summary(summary_txt)
        # Copy key summaries next to sta/
        of = out / "quartus_project" / "output_files"
        for p in of.glob("*.summary"):
            shutil.copy2(p, out / "sta" / p.name)

        status["steps"] = steps
        status["overall"] = "FIT_STA_PASS_REQUIRES_REVIEW"
        status["signoff"] = (
            "NOT_CLAIMED: proxy EP4SGX530 post-fit internal paths only; "
            "no board IO delays; not eLinx target-device signoff"
        )
        status["finished_local"] = datetime.now().astimezone().isoformat(timespec="seconds")
        write_json(status_path, status)
        return status
    except Exception as exc:
        status["steps"] = steps
        status["overall"] = "FAIL_OR_INCOMPLETE"
        status["error"] = str(exc)
        status["finished_local"] = datetime.now().astimezone().isoformat(timespec="seconds")
        write_json(status_path, status)
        raise


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", type=Path, default=None)
    ap.add_argument("--prepare-only", action="store_true")
    ap.add_argument(
        "--allow-mismatch",
        action="store_true",
        help="Allow workspace RTL to differ from baseline-full140 (timing iteration)",
    )
    ap.add_argument(
        "--execute-prepared",
        action="store_true",
        help="Run map/fit/sta in an already prepared --out directory",
    )
    args = ap.parse_args()
    prepare._allow_mismatch = bool(args.allow_mismatch)
    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    out = args.out or (ROOT / "out" / f"baseline_full140_fit_sta_{stamp}")
    out = out.resolve()
    if args.execute_prepared:
        status_path = out / "run_status.json"
        if not status_path.is_file():
            raise SystemExit(f"missing prepared run_status.json under {out}")
        prior = json.loads(status_path.read_text(encoding="utf-8"))
        if prior.get("overall") not in ("PREPARED", "FAIL_OR_INCOMPLETE"):
            raise SystemExit(f"refuse execute: overall={prior.get('overall')}")
        if (out / "logs").exists() and any((out / "logs").iterdir()):
            raise SystemExit(f"logs already present under {out}; refusing overwrite")
        status = execute(out)
        print(f"OVERALL {status['overall']}", flush=True)
        print(
            json.dumps(
                status.get("steps", {}).get("sta_detail", {}).get("post_fit_summary", {}),
                indent=2,
            ),
            flush=True,
        )
        return 0 if status["overall"].startswith("FIT_STA_PASS") else 1
    if out.exists() and any(out.iterdir()):
        raise SystemExit(f"out dir not empty: {out}")
    out.mkdir(parents=True, exist_ok=True)
    prepare(out)
    print(f"PREPARED {out}", flush=True)
    if args.prepare_only:
        return 0
    status = execute(out)
    print(f"OVERALL {status['overall']}", flush=True)
    print(json.dumps(status.get("steps", {}).get("sta_detail", {}).get("post_fit_summary", {}), indent=2), flush=True)
    return 0 if status["overall"].startswith("FIT_STA_PASS") else 1


if __name__ == "__main__":
    sys.exit(main())
