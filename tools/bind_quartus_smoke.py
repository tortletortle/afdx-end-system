#!/usr/bin/env python3
"""Bind a current-source Quartus post-map functional smoke to a frozen candidate."""
from __future__ import annotations

import argparse
import hashlib
import json
import shutil
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def sha(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def require(path: Path) -> Path:
    if not path.is_file():
        raise SystemExit(f"Required evidence file is missing: {path}")
    return path


def bind(candidate_dir: Path, quartus_dir: Path, regress_dir: Path) -> None:
    candidate_dir = candidate_dir.resolve()
    quartus_dir = quartus_dir.resolve()
    regress_dir = regress_dir.resolve()
    smoke_dir = candidate_dir / "gate_smoke"
    if smoke_dir.exists():
        raise SystemExit(f"Refusing to overwrite existing smoke evidence: {smoke_dir}")

    run_meta = json.loads(require(regress_dir / "run_metadata.json").read_text(encoding="utf-8-sig"))
    if run_meta.get("regression_result") != "PASS" or run_meta.get("compile_result") != "PASS":
        raise SystemExit("The full RTL run is not a clean PASS.")
    manifest = json.loads(require(candidate_dir / "candidate_manifest.json").read_text(encoding="utf-8"))
    candidate_rtl = {
        item["path"].replace("\\", "/").split("/source/", 1)[-1]: item["sha256"]
        for item in manifest.get("records", []) if item.get("kind") == "rtl"
    }
    run_hashes = run_meta.get("source_sha256", {})
    for rel, digest in candidate_rtl.items():
        frozen = candidate_dir / "source" / Path(*rel.split("/"))
        workspace = ROOT / Path(*rel.split("/"))
        if not frozen.is_file() or sha(frozen) != digest:
            raise SystemExit(f"Frozen candidate RTL hash mismatch: {rel}")
        if not workspace.is_file() or sha(workspace) != digest:
            raise SystemExit(f"Workspace RTL hash differs from candidate: {rel}")
        if run_hashes.get(rel) != digest:
            raise SystemExit(f"Full regression RTL hash differs from candidate: {rel}")

    map_status_path = require(quartus_dir / "map_status.json")
    map_status = json.loads(map_status_path.read_text(encoding="utf-8"))
    if map_status.get("status") != "completed_await_sim":
        raise SystemExit("Quartus map and functional VO export are not complete.")
    steps = map_status.get("steps", [])
    if [item.get("name") for item in steps] != ["map", "eda_functional"] or any(item.get("rc") != 0 for item in steps):
        raise SystemExit("Quartus map/export steps are incomplete or failed.")
    for item, filename in zip(steps, ("map.log", "eda_functional_export.log"), strict=True):
        if sha(require(quartus_dir / filename)) != item.get("log_sha256"):
            raise SystemExit(f"Quartus {item['name']} log hash differs from map status.")
    source_manifest = require(quartus_dir / "SOURCE_SHA256.json")
    if sha(source_manifest) != map_status.get("source_sha256_file"):
        raise SystemExit("Quartus source hash manifest is not bound to map status.")
    mapped_sources = json.loads(source_manifest.read_text(encoding="utf-8"))
    mapped_rtl = {rel: digest for rel, digest in mapped_sources.items() if rel.startswith("rtl/")}
    for rel, digest in mapped_sources.items():
        workspace_source = ROOT / Path(*rel.split("/"))
        if not workspace_source.is_file() or sha(workspace_source) != digest:
            raise SystemExit(f"Quartus source no longer matches the current workspace: {rel}")
    for rel, digest in mapped_rtl.items():
        if run_hashes.get(rel) != digest or candidate_rtl.get(rel) != digest:
            raise SystemExit(f"Quartus-mapped RTL differs from the current regression/candidate: {rel}")
    inactive = sorted(set(candidate_rtl) - set(mapped_rtl))
    if inactive != ["rtl/top/host_if.v"]:
        raise SystemExit(f"Unexpected RTL omitted from Quartus project source list: {inactive}")

    vo_info = steps[-1].get("vo")
    if not vo_info:
        raise SystemExit("Quartus EDA export did not record a functional VO.")
    vo = quartus_dir / "map_project" / Path(*vo_info["path"].replace("\\", "/").split("/"))
    require(vo)
    if sha(vo) != vo_info.get("sha256") or vo.stat().st_size != vo_info.get("bytes"):
        raise SystemExit("Quartus functional VO hash/size does not match map status.")

    source_smoke = quartus_dir / "gate_smoke_v3"
    old_smoke_path = require(source_smoke / "simulation_status.json")
    smoke_meta = json.loads(old_smoke_path.read_text(encoding="utf-8"))
    if smoke_meta.get("status") != "smoke_pass":
        raise SystemExit("Questa functional post-map smoke is not PASS.")
    sim_log = require(source_smoke / "vsim.log").read_text(encoding="utf-8", errors="replace")
    if "PSTSYN TOP SMOKE PASS" not in sim_log or "PSTSYN FAIL" in sim_log or "# Errors: 0" not in sim_log:
        raise SystemExit("Questa simulation log does not contain a clean smoke PASS.")
    compile_logs = [require(source_smoke / name).read_text(encoding="utf-8", errors="replace")
                    for name in ("vlog_vo.log", "vlog_tb.log")]
    if any("Errors: 0" not in log for log in compile_logs):
        raise SystemExit("Questa compile logs do not explicitly show Errors: 0.")
    if any(item.get("rc") != 0 for item in smoke_meta.get("steps", [])):
        raise SystemExit("One or more Questa smoke steps did not return zero.")
    smoke_log_names = {
        "vlib": "vlib.log",
        "vlog_vo": "vlog_vo.log",
        "vlog_tb": "vlog_tb.log",
        "vsim": "vsim.log",
    }
    for item in smoke_meta.get("steps", []):
        log_name = smoke_log_names.get(item.get("step"))
        if not log_name or sha(require(source_smoke / log_name)) != item.get("log_sha256"):
            raise SystemExit(f"Questa {item.get('step')} log hash differs from smoke status.")

    smoke_dir.mkdir()
    copies = {
        vo: smoke_dir / "AFDX_top_postmap.vo",
        source_manifest: smoke_dir / "SOURCE_SHA256.json",
        map_status_path: smoke_dir / "map_status.json",
        old_smoke_path: smoke_dir / "smoke_tool_status.json",
        quartus_dir / "map_project" / "AFDX_top.qsf": smoke_dir / "AFDX_top.qsf",
        quartus_dir / "map_project" / "AFDX_top.qpf": smoke_dir / "AFDX_top.qpf",
        quartus_dir / "map.log": smoke_dir / "map.log",
        quartus_dir / "eda_functional_export.log": smoke_dir / "eda_functional_export.log",
        quartus_dir / "run_postsyn_closeout.py": smoke_dir / "run_postsyn_closeout.py",
    }
    for name in ("modelsim.ini", "tb_elinx_postsynth_smoke.v", "vlib.log", "vlog_vo.log",
                 "vlog_tb.log", "vsim.log", "transcript"):
        copies[source_smoke / name] = smoke_dir / name
    for src, dst in copies.items():
        shutil.copy2(require(src), dst)

    record = {
        "status": "PASS_ZERO_DELAY_QUARTUS_POSTMAP_TOP_SMOKE",
        "created_local": datetime.now().astimezone().isoformat(timespec="seconds"),
        "candidate": manifest.get("candidate"),
        "candidate_manifest_sha256": sha(candidate_dir / "candidate_manifest.json"),
        "rtl_regression_run_id": run_meta.get("run_id"),
        "rtl_regression_metadata_sha256": sha(regress_dir / "run_metadata.json"),
        "rtl_candidate_sha256": candidate_rtl,
        "quartus_project_source_sha256": mapped_sources,
        "quartus_source_manifest_sha256": sha(source_manifest),
        "inactive_candidate_rtl_not_in_qsf": {
            rel: "empty host_if shell; not instantiated by AFDX_top and not listed in the Quartus project"
            for rel in inactive
        },
        "map_status_sha256": sha(map_status_path),
        "quartus_qsf_sha256": sha(quartus_dir / "map_project" / "AFDX_top.qsf"),
        "quartus_qpf_sha256": sha(quartus_dir / "map_project" / "AFDX_top.qpf"),
        "postmap_vo_sha256": sha(vo),
        "postmap_vo_bytes": vo.stat().st_size,
        "testbench_sha256": sha(source_smoke / "tb_elinx_postsynth_smoke.v"),
        "questa_version": "Questa Altera Starter FPGA Edition 2025.3",
        "questa_steps": smoke_meta.get("steps", []),
        "observed_checks": [line.strip("# ") for line in sim_log.splitlines()
                            if "PSTSYN CHECK " in line or "PSTSYN WRITE " in line or "PSTSYN TOP SMOKE PASS" in line],
        "scope": "Zero-delay post-map top host-register and RTC behavioral assertions on the current source. Not full traffic, SDF, post-fit signoff, or board operation.",
    }
    record_path = smoke_dir / "simulation_status.json"
    record_path.write_text(json.dumps(record, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    run_status_path = candidate_dir / "run_status.json"
    status = json.loads(require(run_status_path).read_text(encoding="utf-8"))
    status["simulation"] = {
        "status": record["status"],
        "record": str(record_path),
        "record_sha256": sha(record_path),
        "postmap_vo_sha256": record["postmap_vo_sha256"],
        "source_binding": "Quartus map project active RTL hashes match current full RTL regression and frozen eLinx candidate",
        "eLinx_yosys_intermediate_functional_smoke": "NOT_CLAIMED; Questa cannot parse this intermediate export dialect",
    }
    status["quartus_postmap"] = {
        "status": "PASS_MAP_AND_FUNCTIONAL_VO_EXPORT",
        "map_status_sha256": sha(map_status_path),
        "vo_sha256": record["postmap_vo_sha256"],
        "source_sha256_file_sha256": record["quartus_source_manifest_sha256"],
    }
    status["overall"] = "SYNTHESIS_AND_QUARTUS_POSTMAP_SMOKE_COMPLETE"
    status["updated_local"] = datetime.now().astimezone().isoformat(timespec="seconds")
    run_status_path.write_text(json.dumps(status, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"BOUND_SMOKE={record['status']}")
    print(f"VO_SHA256={record['postmap_vo_sha256']}")
    print(f"RECORD={record_path}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate-dir", type=Path, required=True)
    parser.add_argument("--quartus-dir", type=Path, required=True)
    parser.add_argument("--regress-dir", type=Path, required=True)
    args = parser.parse_args()
    bind(args.candidate_dir, args.quartus_dir, args.regress_dir)


if __name__ == "__main__":
    main()
