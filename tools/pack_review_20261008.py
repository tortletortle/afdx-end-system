#!/usr/bin/env python3
"""Build a versioned, evidence-bound AFDX review package (2026-10-08)."""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import shutil
import zipfile
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUTPUT = ROOT / "out" / "submission_20261008_final"
DOCS = [
    "doc/00_先读_提交范围与汇报口径.md",
    "doc/01_AI工具使用声明.md",
    "doc/进一步优化与赛题要求补全计划_20261008.md",
    "doc/计划执行记录_20261008.md",
    "doc/当前问题完整整改计划_20261007.md",
    "doc/整改执行记录_20261008.md",
    "doc/交卷对照完成清单_20261007.md",
    "doc/AFDX端系统_测试仿真报告.md",
    "doc/结构告警分阶段审查记录_20261008.md",
    "doc/AFDX端系统_现行架构图.html",
    "doc/验收尺子.md",
]


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def require_file(path: Path) -> Path:
    if not path.is_file():
        raise SystemExit(f"Required evidence file is missing: {path}")
    return path


def validate_evidence(regress_dir: Path, synth_dir: Path) -> tuple[dict, dict, list[dict]]:
    manifest_path = ROOT / "sim" / "tests.manifest"
    manifest = []
    for raw in manifest_path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if line and not line.startswith("#"):
            fields = line.split()
            manifest.append((fields[0], fields[1]))

    csv_path = require_file(regress_dir / "regress.csv")
    with csv_path.open(encoding="utf-8-sig", newline="") as stream:
        rows = list(csv.DictReader(stream))
    observed = [(row["test_id"], row["tb"]) for row in rows]
    if observed != manifest:
        raise SystemExit("Regression CSV does not match the current full manifest, in order.")
    failed = [row["test_id"] for row in rows if row.get("result") != "PASS"]
    if failed:
        raise SystemExit("Regression is not all PASS: " + ", ".join(failed))

    meta_path = require_file(regress_dir / "run_metadata.json")
    # run_regress.ps1 is run under Windows PowerShell and writes UTF-8 with a
    # BOM; accept both BOM and plain UTF-8 JSON for frozen/replayed runs.
    regress_meta = json.loads(meta_path.read_text(encoding="utf-8-sig"))
    if regress_meta.get("compile_result") != "PASS":
        raise SystemExit("Regression metadata does not report successful compilation.")
    if regress_meta.get("regression_result") != "PASS":
        raise SystemExit("Regression metadata does not report PASS.")
    if regress_meta.get("pass_count") != len(manifest) or regress_meta.get("test_count") != len(manifest):
        raise SystemExit("Regression metadata count differs from the current manifest.")
    compile_log = require_file(regress_dir / "compile_console.txt").read_text(encoding="utf-8", errors="replace")
    if "Errors: 0" not in compile_log:
        raise SystemExit("Compile console is missing the explicit 'Errors: 0' result.")

    status_path = require_file(synth_dir / "run_status.json")
    synth_meta = json.loads(status_path.read_text(encoding="utf-8"))
    accepted_overall = {
        "SYNTHESIS_NETLIST_AND_SMOKE_COMPLETE",
        "SYNTHESIS_AND_QUARTUS_POSTMAP_SMOKE_COMPLETE",
    }
    if synth_meta.get("overall") not in accepted_overall:
        raise SystemExit("Synthesis and a current-source post-map smoke must be complete before packaging.")
    simulation = synth_meta.get("simulation", {})
    smoke_status = simulation.get("status")
    if smoke_status not in {
        "PASS_ZERO_DELAY_SYNTH_NETLIST_TOP_SMOKE",
        "PASS_ZERO_DELAY_QUARTUS_POSTMAP_TOP_SMOKE",
    }:
        raise SystemExit("A current-source post-map smoke is not recorded as PASS.")

    candidate_manifest_path = require_file(synth_dir / "candidate_manifest.json")
    candidate = json.loads(candidate_manifest_path.read_text(encoding="utf-8"))
    if synth_meta.get("manifest_sha256") != sha256(candidate_manifest_path):
        raise SystemExit("Synthesis run status does not bind to candidate_manifest.json.")
    rtl_records = [item for item in candidate.get("records", []) if item.get("kind") == "rtl"]
    if len(rtl_records) != candidate.get("rtl_count") or not rtl_records:
        raise SystemExit("Candidate manifest RTL inventory is incomplete.")
    source_hashes = regress_meta.get("source_sha256", {})
    for item in rtl_records:
        source_copy = Path(item["path"])
        if not source_copy.is_file() or sha256(source_copy) != item["sha256"]:
            raise SystemExit(f"Frozen synthesis RTL hash mismatch: {item['path']}")
        try:
            relative = source_copy.relative_to(synth_dir / "source").as_posix()
        except ValueError as exc:
            raise SystemExit(f"Candidate RTL path escapes frozen source tree: {source_copy}") from exc
        workspace_file = ROOT / relative
        if not workspace_file.is_file() or sha256(workspace_file) != item["sha256"]:
            raise SystemExit(f"Synthesis RTL no longer matches current workspace: {relative}")
        run_hash = source_hashes.get(relative.replace("\\", "/"))
        if run_hash != item["sha256"]:
            raise SystemExit(f"Regression and synthesis RTL inputs differ: {relative}")

    netlist = require_file(synth_dir / "AFDX_top_synth.v")
    if smoke_status == "PASS_ZERO_DELAY_SYNTH_NETLIST_TOP_SMOKE":
        if simulation.get("netlist_sha256") != sha256(netlist):
            raise SystemExit("Smoke record does not bind to the candidate netlist hash.")
    else:
        smoke_dir = synth_dir / "gate_smoke"
        smoke_record_path = require_file(smoke_dir / "simulation_status.json")
        smoke_record = json.loads(smoke_record_path.read_text(encoding="utf-8"))
        if sha256(smoke_record_path) != simulation.get("record_sha256"):
            raise SystemExit("Quartus post-map smoke record hash differs from run_status.json.")
        if smoke_record.get("status") != smoke_status:
            raise SystemExit("Quartus post-map smoke record is not PASS.")
        if smoke_record.get("candidate_manifest_sha256") != sha256(candidate_manifest_path):
            raise SystemExit("Quartus post-map smoke is bound to a different frozen RTL candidate.")
        if smoke_record.get("rtl_regression_metadata_sha256") != sha256(meta_path):
            raise SystemExit("Quartus post-map smoke is bound to a different full RTL regression.")
        vo = require_file(smoke_dir / "AFDX_top_postmap.vo")
        if sha256(vo) != smoke_record.get("postmap_vo_sha256"):
            raise SystemExit("Quartus post-map VO hash does not match the smoke record.")
        if simulation.get("postmap_vo_sha256") != sha256(vo):
            raise SystemExit("run_status.json does not bind to the Quartus post-map VO.")
        if "PSTSYN TOP SMOKE PASS" not in require_file(smoke_dir / "vsim.log").read_text(
                encoding="utf-8", errors="replace"):
            raise SystemExit("Packaged post-map simulation log is missing its PASS marker.")
        mapped_sources = smoke_record.get("quartus_project_source_sha256", {})
        if not mapped_sources:
            raise SystemExit("Quartus post-map smoke record contains no input source hashes.")
        for rel, digest in mapped_sources.items():
            source = ROOT / Path(*rel.split("/"))
            if not source.is_file() or sha256(source) != digest:
                raise SystemExit(f"Quartus post-map source differs from the current workspace: {rel}")
            if rel.startswith("rtl/") and source_hashes.get(rel) != digest:
                raise SystemExit(f"Quartus post-map RTL differs from the full RTL regression: {rel}")
        if smoke_record.get("inactive_candidate_rtl_not_in_qsf") != {
                "rtl/top/host_if.v": "empty host_if shell; not instantiated by AFDX_top and not listed in the Quartus project"}:
            raise SystemExit("Quartus project source scope exception is missing or unexpected.")
    return regress_meta, synth_meta, rows


def validate_replay(replay_dir: Path) -> tuple[dict, list[dict]]:
    expected_ids = ["T13", "T13g", "T25", "T25g"]
    csv_path = require_file(replay_dir / "regress.csv")
    with csv_path.open(encoding="utf-8-sig", newline="") as stream:
        rows = list(csv.DictReader(stream))
    if [row.get("test_id") for row in rows] != expected_ids:
        raise SystemExit("Clean-extraction replay must contain T13/T13g/T25/T25g in manifest order.")
    if any(row.get("result") != "PASS" for row in rows):
        raise SystemExit("Clean-extraction replay contains a failed test.")
    meta_path = require_file(replay_dir / "run_metadata.json")
    meta = json.loads(meta_path.read_text(encoding="utf-8-sig"))
    if meta.get("compile_result") != "PASS" or meta.get("regression_result") != "PASS":
        raise SystemExit("Clean-extraction replay metadata is not PASS.")
    if meta.get("test_count") != len(expected_ids) or meta.get("pass_count") != len(expected_ids):
        raise SystemExit("Clean-extraction replay test count does not match its expected subset.")
    compile_log = require_file(replay_dir / "compile_console.txt").read_text(encoding="utf-8", errors="replace")
    if "Errors: 0" not in compile_log:
        raise SystemExit("Clean-extraction replay compile log is missing 'Errors: 0'.")
    for test_id in expected_ids:
        console = require_file(replay_dir / f"{test_id}_console.txt").read_text(encoding="utf-8", errors="replace")
        if "PASS" not in console or "FAIL" in console:
            raise SystemExit(f"Clean-extraction replay console is not a strict PASS: {test_id}")
    source_hashes = meta.get("source_sha256", {})
    rtl_hashes = {rel: digest for rel, digest in source_hashes.items() if rel.startswith("rtl/")}
    if not rtl_hashes:
        raise SystemExit("Clean-extraction replay metadata contains no RTL input hashes.")
    for rel, digest in rtl_hashes.items():
        frozen = replay_dir / "workspace" / Path(*rel.split("/"))
        current = ROOT / Path(*rel.split("/"))
        if not frozen.is_file() or sha256(frozen) != digest:
            raise SystemExit(f"Replay frozen RTL hash mismatch: {rel}")
        if not current.is_file() or sha256(current) != digest:
            raise SystemExit(f"Replay source differs from the current workspace: {rel}")
    return meta, rows


def copy_tree(src: Path, dst: Path, *, suffixes: set[str] | None = None,
              excluded_parts: set[str] | None = None) -> None:
    if not src.is_dir():
        return
    excluded_parts = excluded_parts or set()
    for item in src.rglob("*"):
        rel = item.relative_to(src)
        if any(part in excluded_parts for part in rel.parts):
            continue
        if not item.is_file() or item.name.endswith(".pyc"):
            continue
        if suffixes is not None and item.suffix.lower() not in suffixes:
            continue
        target = dst / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(item, target)


def copy_file(src: Path, dst: Path) -> None:
    require_file(src)
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)


def package(args: argparse.Namespace) -> None:
    regress_dir = args.regress_dir.resolve()
    synth_dir = args.synth_dir.resolve()
    out_dir = args.out_dir.resolve()
    if out_dir.exists():
        raise SystemExit(f"Refusing to overwrite existing output: {out_dir}")
    out_root = ROOT / "out"
    if out_dir == out_root or out_root not in out_dir.parents:
        raise SystemExit("Package output must be a new directory below the project out/ tree.")
    regress_meta, synth_meta, rows = validate_evidence(regress_dir, synth_dir)
    if args.replay_archive and not args.replay_dir:
        raise SystemExit("--replay-archive requires --replay-dir.")
    replay_meta = None
    replay_rows = None
    replay_archive = None
    if args.replay_dir:
        replay_dir = args.replay_dir.resolve()
        replay_meta, replay_rows = validate_replay(replay_dir)
        if args.replay_archive:
            replay_archive = require_file(args.replay_archive.resolve())

    stage = out_dir / "tree"
    stage.mkdir(parents=True)
    for name in ("rtl",):
        copy_tree(ROOT / name, stage / name)
    for name in ("tb", "bfm", "chk", "env", "vec"):
        copy_tree(ROOT / "sim" / name, stage / "sim" / name)
    copy_tree(ROOT / "sw" / "golden", stage / "sw" / "golden")
    copy_tree(ROOT / "sw" / "report", stage / "sw" / "report")
    copy_tree(ROOT / "elinx" / "prj", stage / "elinx" / "prj",
              suffixes={".ys", ".sdc", ".qsf", ".qpf", ".tcl", ".md", ".txt"},
              excluded_parts={"db", "incremental_db", "output_files", "simulation", "runs"})
    copy_file(ROOT / "elinx" / "README.txt", stage / "elinx" / "README.txt")

    sim_dst = stage / "sim"
    sim_dst.mkdir(parents=True, exist_ok=True)
    copy_file(ROOT / "sim" / "tests.manifest", sim_dst / "tests.manifest")
    copy_tree(ROOT / "sim", sim_dst,
              suffixes={".ps1", ".tcl", ".py", ".md", ".tsv", ".manifest"},
              excluded_parts={"tb", "bfm", "chk", "env", "vec", "out", "work", "work_iso"})
    copy_tree(ROOT / "tools", stage / "tools", suffixes={".py", ".md"},
              excluded_parts={"__pycache__"})
    (stage / "tools" / "pack_review_20261003.py").unlink(missing_ok=True)
    for rel in ("_project.md", "AFDX端系统_总体设计书.md"):
        src = ROOT / rel
        if src.is_file():
            copy_file(src, stage / rel)
    for rel in DOCS:
        copy_file(ROOT / rel, stage / rel)
    copy_file(ROOT / DOCS[0], stage / "README.md")
    copy_tree(ROOT / "evidence" / "waves", stage / "evidence" / "waves")

    ev_regress = stage / "evidence" / "final_rtl_regression"
    ev_regress.mkdir(parents=True)
    for src in [regress_dir / "regress.csv", regress_dir / "compile_console.txt",
                regress_dir / "run_metadata.json", *sorted(regress_dir.glob("T*_console.txt"))]:
        if src.is_file():
            copy_file(src, ev_regress / src.name)

    ev_synth = stage / "evidence" / "final_synthesis"
    ev_synth.mkdir(parents=True)
    for name in ("candidate_manifest.json", "run_status.json", "AFDX_top_synth.v",
                 "AFDX_top_synth_frozen.ys", "AFDX_top_netlist_frozen.ys",
                 "AFDX_top_check_frozen.ys", "AFDX_top_source_check_frozen.ys",
                 "synth.log", "structural_check.log", "source_check.log", "netlist_emit.log"):
        src = synth_dir / name
        if src.is_file():
            copy_file(src, ev_synth / name)
    triage_src = ROOT / "out" / "arena-debug" / "goal_completion_20261008" / "warning_triage_r2"
    triage_dst = ev_synth / "warning_triage"
    for name in (
        "triage_inputs.json", "warning_stage_summary.json", "warning_module_summary.json",
        "check_after_bram.ys", "check_after_bram.log", "check_after_bram.console.txt",
        "check_after_techmap.ys", "check_after_techmap.log", "check_after_techmap.console.txt",
        "check_tftp_addr_width.py", "tftp_addr_width_check.json",
    ):
        copy_file(triage_src / name, triage_dst / name)
    copy_tree(synth_dir / "source", ev_synth / "frozen_source")
    smoke_dir = synth_dir / "gate_smoke"
    if smoke_dir.is_dir():
        for src in smoke_dir.iterdir():
            if src.is_file() and (src.suffix.lower() in {".log", ".v", ".vo", ".json", ".ini", ".py", ".qsf", ".qpf"}):
                copy_file(src, ev_synth / "gate_smoke" / src.name)

    if replay_meta is not None and replay_rows is not None:
        replay_dst = stage / "evidence" / "clean_extraction_replay"
        replay_dst.mkdir(parents=True)
        for name in ("regress.csv", "compile_console.txt", "run_metadata.json",
                     "T13_console.txt", "T13g_console.txt", "T25_console.txt", "T25g_console.txt"):
            copy_file(args.replay_dir.resolve() / name, replay_dst / name)

    staged_files = sorted((p for p in stage.rglob("*") if p.is_file()),
                           key=lambda p: p.relative_to(stage).as_posix().lower())
    filelist = []
    for path in staged_files:
        rel = path.relative_to(stage).as_posix()
        filelist.append(f"{sha256(path)}  {path.stat().st_size:12d}  {rel}")
    (stage / "FILELIST_SHA256.txt").write_text(
        "# SHA-256 for package payload files; excludes this file and PACKAGE_META.json.\n"
        + "\n".join(filelist) + "\n", encoding="utf-8")

    netlist = synth_dir / "AFDX_top_synth.v"
    meta = {
        "package": out_dir.name,
        "created_local": datetime.now().astimezone().isoformat(timespec="seconds"),
        "rtl_regression": {
            "run_id": regress_meta.get("run_id"),
            "test_count": len(rows),
            "result": regress_meta.get("regression_result"),
            "csv_sha256": sha256(regress_dir / "regress.csv"),
            "source_hash_count": len(regress_meta.get("source_sha256", {})),
        },
        "synthesis": {
            "candidate": synth_meta.get("candidate"),
            "manifest_sha256": synth_meta.get("manifest_sha256"),
            "netlist_sha256": sha256(netlist),
            "netlist_bytes": netlist.stat().st_size,
            "simulation_status": synth_meta.get("simulation", {}).get("status"),
        },
        "clean_extraction_replay": None if replay_meta is None else {
            "source_run_id": replay_meta.get("run_id"),
            "test_ids": [row["test_id"] for row in replay_rows],
            "result": "PASS",
            "csv_sha256": sha256(args.replay_dir.resolve() / "regress.csv"),
            "compile_log_sha256": sha256(args.replay_dir.resolve() / "compile_console.txt"),
            "rtl_hash_count": sum(1 for rel in replay_meta.get("source_sha256", {}) if rel.startswith("rtl/")),
            "initial_archive_sha256": sha256(replay_archive) if replay_archive else None,
            "notes": "This replay was run from a clean extraction of the versioned staging archive; the final archive is independently re-extracted and replayed after packaging.",
        },
        "scope_limit": "Contest functional evidence only. No board operation, SDF, post-fit signoff, complete SNMP/ARINC 615A implementation, or real-peer interoperability is claimed.",
        "included_evidence": ["current full RTL regression", "final candidate synthesis", "current-source zero-delay post-map host-register/RTC smoke", "source and file hashes"],
    }
    (stage / "PACKAGE_META.json").write_text(json.dumps(meta, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    zip_path = out_dir / f"AFDX_选题一_评阅交付_20261008.zip"
    with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for path in sorted((p for p in stage.rglob("*") if p.is_file()), key=lambda p: p.as_posix().lower()):
            archive.write(path, arcname=path.relative_to(stage).as_posix())
    with zipfile.ZipFile(zip_path) as archive:
        bad_member = archive.testzip()
        if bad_member is not None:
            raise SystemExit(f"ZIP CRC verification failed: {bad_member}")
    (out_dir / "ZIP_SHA256.txt").write_text(
        f"{sha256(zip_path)}  {zip_path.stat().st_size}  {zip_path.name}\n", encoding="utf-8")
    print(f"ZIP={zip_path}")
    print(f"bytes={zip_path.stat().st_size}")
    print(f"sha256={sha256(zip_path)}")
    print(f"tests={len(rows)}/{len(rows)} PASS")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--regress-dir", type=Path, required=True,
                        help="isolated full-manifest run directory containing regress.csv and run_metadata.json")
    parser.add_argument("--synth-dir", type=Path, required=True,
                        help="frozen synthesis candidate directory with a completed gate_smoke/")
    parser.add_argument("--out-dir", type=Path, default=DEFAULT_OUTPUT,
                        help="new versioned package output directory")
    parser.add_argument("--replay-dir", type=Path,
                        help="optional clean-extraction replay directory with T13/T13g/T25/T25g PASS")
    parser.add_argument("--replay-archive", type=Path,
                        help="staging archive used for the clean-extraction replay; requires --replay-dir")
    package(parser.parse_args())


if __name__ == "__main__":
    main()
