#!/usr/bin/env python3
"""Run the pinned native post-ABC tail on a frozen N3 assembly, then reload IL.

This creates a diagnostic post-map candidate from N3's 70-declaration COUT
closure. It does not rerun RTL synthesis or claim full equivalence/business PASS.
"""
from __future__ import annotations

import argparse
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time


ROOT = Path(__file__).resolve().parents[1]
N3 = ROOT / "out/netlist_n3_fresh_process_mapping_20261014_r1"
CANDIDATE_DIR = ROOT / "out/production_repairs_native_hierarchy_default_20261013_r1"
CANDIDATE = CANDIDATE_DIR / "candidate.json"
NATIVE_SCRIPT = CANDIDATE_DIR / "AFDX_top_native.ys"
CEC = ROOT / "out/netlist_eqv_n3_20261014_r1/mapped_il_cec_20261015_r3/run_status.json"
PRESERVATION = ROOT / "out/netlist_eqv_n3_20261014_r1/mapping_preservation_review_20261015_r1.json"
TOOL_SHA256 = "b022eb9361b9847d0042b234fb6ee1b584836be4c0174e94addb6d2f1d236a23"
EXPECTED_SELECTED = {13, 41, 44}


def sha(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def read_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8-sig"))


def write_json(path: Path, data: dict) -> None:
    temp = path.with_suffix(path.suffix + ".tmp")
    temp.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temp.replace(path)


def ys_path(path: Path) -> str:
    value = path.resolve().as_posix()
    if any(char in value for char in ('"', "\n", "\r")):
        raise ValueError(f"Unsafe path for eLinx script: {path}")
    return f'"{value}"'


def verify_frozen_inputs(state: dict, candidate: dict, n3_il: Path) -> tuple[Path, Path]:
    if state.get("status") != "PASS_N3_STRUCTURE_ONLY":
        raise ValueError(f"N3 structure gate is not PASS: {state.get('status')}")
    if any(state.get(key) != "PASS" for key in ("mapping", "assembly", "whole_check")):
        raise ValueError("N3 mapping, assembly, or whole-design CHECK did not pass")
    if sha(CANDIDATE) != state.get("candidate_sha256"):
        raise ValueError("N3 candidate manifest hash drift")
    if sha(n3_il) != state.get("whole_il_sha256"):
        raise ValueError("N3 whole_postabc.il hash drift")
    if candidate.get("top") != "AFDX_top":
        raise ValueError("Frozen candidate top is not AFDX_top")
    for relative, expected in candidate.get("input_sha256", {}).items():
        frozen = CANDIDATE_DIR / relative
        if not frozen.is_file() or sha(frozen) != expected:
            raise ValueError(f"Frozen candidate input changed or missing: {relative}")
    for relative in candidate.get("rtl_sources", []):
        key = "input/" + relative.replace("\\", "/")
        if sha(ROOT / relative) != candidate["input_sha256"][key]:
            raise ValueError(f"Workspace RTL differs from frozen candidate: {relative}")
    native_digest = sha(NATIVE_SCRIPT)
    if candidate.get("input_sha256", {}).get("AFDX_top_native.ys") != native_digest:
        raise ValueError("Frozen native synthesis script hash differs from candidate lock")
    tool = Path(candidate["synthesis_executable"])
    if sha(tool) != TOOL_SHA256 or candidate.get("synthesis_executable_sha256") != TOOL_SHA256:
        raise ValueError("eLinx executable hash mismatch")
    if state.get("tool_sha256") != TOOL_SHA256:
        raise ValueError("N3 synthesis tool provenance mismatch")

    integrity = read_json(N3 / "integrity_audit.json")
    if (integrity.get("status") != "PASS_EVIDENCE_INTEGRITY" or
            integrity.get("whole_il_sha256") != state.get("whole_il_sha256") or
            integrity.get("candidate_sha256") != state.get("candidate_sha256")):
        raise ValueError("N3 integrity audit does not bind to this frozen candidate")
    cec = read_json(CEC)
    rows = cec.get("results", [])
    if (cec.get("status") != "PASS_SELECTED_MAPPED_IL_CONE_CEC" or
            set(cec.get("selected_indices") or []) != EXPECTED_SELECTED or
            {row.get("index") for row in rows if row.get("classification") == "PASS_COMBINATIONAL"} != EXPECTED_SELECTED or
            cec.get("candidate_sha256") != state.get("candidate_sha256") or
            cec.get("whole_il_sha256") != state.get("whole_il_sha256")):
        raise ValueError("Preselected mapped-IL CEC evidence is incomplete or mismatched")
    preservation = read_json(PRESERVATION)
    if (preservation.get("status") !=
            "PASS_50_MODULE_NON_LUT_PRESERVATION; PASS_8_NO_OUTPUT_MODULES_EXACT_CELLS_AND_CONNECTIONS" or
            preservation.get("n3_whole_il_sha256") != state.get("whole_il_sha256")):
        raise ValueError("N3 mapping-preservation review does not bind to this frozen IL")
    return tool, Path(candidate["abc_executable"])


def postmap_script(whole_il: Path, output_dir: Path) -> str:
    lines = NATIVE_SCRIPT.read_text(encoding="utf-8-sig").splitlines()
    abc_positions = [i for i, line in enumerate(lines) if line.strip().startswith("abc ")]
    if len(abc_positions) != 1:
        raise ValueError("Expected exactly one pinned ABC stage in native script")
    abc_index = abc_positions[0]
    clean_index = next((i for i in range(abc_index + 1, len(lines))
                        if lines[i].strip() == "clean"), None)
    if clean_index is None:
        raise ValueError("Pinned native script has no post-ABC clean boundary")
    tail = [line.rstrip() for line in lines[clean_index:] if line.strip()]
    if any(line.strip().startswith(prefix) for line in tail
           for prefix in ("read_verilog ", "abc ", "synth_stratix ")):
        raise ValueError("Post-ABC native tail unexpectedly includes RTL or ABC resynthesis")
    required = (
        "clean", "opt_rmdff", "techmap -map +/stratix/cells_map.v", "iopadmap -bits",
        "techmap -autoproc -map +/stratix/common/io_map.v", "dffinit -highlow -ff dffeas q power_up",
        "chtype -set __preserve_dffeas t:dffeas", "merge2lcell",
        "chtype -set dffeas t:__preserve_dffeas", "handle_init_reg", "wreduce",
        "write_verilog ", "write_ilang ",
    )
    position = 0
    for expected in required:
        found = next((i for i in range(position, len(tail)
                                      ) if tail[i].strip().startswith(expected)), None)
        if found is None:
            raise ValueError(f"Pinned native tail is missing or reorders {expected}")
        position = found + 1

    generated = [f"read_ilang {ys_path(whole_il)}", "select *", "check -assert -noinit"]
    for line in tail:
        stripped = line.strip()
        if stripped.startswith(("techmap -map +/stratix/cells_map.v",
                                "techmap -autoproc -map +/stratix/common/io_map.v")):
            generated.extend((line, "check -assert -noinit"))
        elif stripped == "iopadmap -bits":
            generated.extend((line, "check -assert -noinit"))
        elif stripped == "chtype -set __preserve_dffeas t:dffeas":
            generated.extend(("check -assert -noinit", line))
        elif stripped == "chtype -set dffeas t:__preserve_dffeas":
            generated.extend((line, "check -assert -noinit"))
        elif stripped == "handle_init_reg":
            generated.extend((line, "check -assert -noinit"))
        elif stripped.startswith("write_verilog "):
            match = re.match(r'^(write_verilog\s+.*?\s+)"[^"]+"\s*$', stripped)
            if not match:
                raise ValueError(f"Cannot safely rewrite native VQM output path: {line}")
            generated.append(f"write_ilang {ys_path(output_dir / 'AFDX_top_preexport.il')}")
            generated.append(f"{match.group(1)}{ys_path(output_dir / 'AFDX_top_native.vqm')}")
        elif stripped.startswith("write_ilang "):
            name = "AFDX_top_before_merge.il" if "before_merge" in stripped else "AFDX_top_mapped.il"
            generated.append(f"write_ilang {ys_path(output_dir / name)}")
        elif stripped == "check -assert -noinit":
            generated.append(line)
        else:
            generated.append(line)
    commands = [line.strip() for line in generated]
    preserve = commands.index("chtype -set __preserve_dffeas t:dffeas")
    merge = commands.index("merge2lcell")
    restore = commands.index("chtype -set dffeas t:__preserve_dffeas")
    if not (preserve < merge < restore):
        raise ValueError("Native DFF preserve/merge/restore sequence changed")
    if commands[preserve - 1] != "check -assert -noinit" or commands[restore + 1] != "check -assert -noinit":
        raise ValueError("Stable DFF boundary checks are not adjacent to preserve/restore")
    if any(line == "check -assert -noinit" for line in commands[preserve + 1:restore]):
        raise ValueError("Cannot check the temporarily renamed DFF type")
    if commands.count("check -assert -noinit") < 8:
        raise ValueError("Postmap script is missing stage CHECK gates")
    return "\n".join(generated) + "\n"


def run_stage(state: dict, out: Path, name: str, script: Path,
              tool: Path, timeout: int) -> dict:
    stage_dir = out / name
    stage_dir.mkdir()
    log = stage_dir / "synthesis.log"
    stdout = stage_dir / "stdout.log"
    stderr = stage_dir / "stderr.log"
    record = {"status": "RUNNING", "script": str(script), "script_sha256": sha(script),
              "tool_sha256": sha(tool), "timeout_seconds": timeout, "started_local": datetime.now().astimezone().isoformat()}
    state["stages"][name] = record
    write_json(out / "postmap_status.json", state)
    argv = [str(tool), "-Q", "-T", "-s", str(script), "-l", str(log)]
    record["argv"] = argv
    start = time.monotonic()
    flags = getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0) if os.name == "nt" else 0
    with stdout.open("xb") as out_stream, stderr.open("xb") as err_stream:
        process = subprocess.Popen(argv, cwd=stage_dir, stdout=out_stream, stderr=err_stream,
                                   creationflags=flags)
        record["owned_pid"] = process.pid
        write_json(out / "postmap_status.json", state)
        try:
            record["exit_code"] = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            record["timed_out"] = True
            if os.name == "nt":
                killed = subprocess.run(["taskkill", "/PID", str(process.pid), "/T", "/F"],
                                        capture_output=True, timeout=15, check=False)
                record["timeout_cleanup"] = {"exit_code": killed.returncode,
                                             "output": killed.stdout.decode("utf-8", errors="replace") +
                                                       killed.stderr.decode("utf-8", errors="replace")}
            else:
                process.kill()
            process.wait(timeout=15)
            record["exit_code"] = process.returncode
    record["wall_seconds"] = round(time.monotonic() - start, 3)
    record["ended_local"] = datetime.now().astimezone().isoformat()
    log_text = "\n".join(p.read_text(encoding="utf-8", errors="replace")
                         for p in (stdout, stderr, log) if p.exists())
    warnings = re.findall(r"(?i)\bwarning\b", log_text)
    errors = re.findall(r"(?i)\berror\b", log_text)
    record.update({"log_sha256": sha(log) if log.exists() else None,
                   "stdout_sha256": sha(stdout), "stderr_sha256": sha(stderr),
                   "warning_count": len(warnings), "error_count": len(errors),
                   "success_marker": "Yosys execute success!" in log_text})
    record["status"] = ("PASS" if record["exit_code"] == 0 and not record.get("timed_out")
                        and not warnings and not errors and record["success_marker"] else "FAIL")
    write_json(out / "postmap_status.json", state)
    return record


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True,
                        help="new output directory under the repository out directory")
    args = parser.parse_args()
    out = (args.out if args.out.is_absolute() else ROOT / args.out).resolve()
    out_root = (ROOT / "out").resolve()
    if out == out_root or not out.is_relative_to(out_root) or out.exists():
        raise SystemExit("--out must be a new, non-existing child of the repository out directory")
    state = read_json(N3 / "run_status.json")
    candidate = read_json(CANDIDATE)
    n3_il = N3 / "whole_postabc.il"
    tool, abc = verify_frozen_inputs(state, candidate, n3_il)
    if sha(abc) != state.get("abc_sha256"):
        raise SystemExit("Frozen ABC executable hash mismatch")
    out.mkdir(parents=True)
    runner_snapshot = out / "runner_snapshot.py"
    runner_snapshot.write_bytes(Path(__file__).read_bytes())
    script = postmap_script(n3_il, out)
    post_script = out / "AFDX_top_n3_postmap.ys"
    post_script.write_text(script, encoding="ascii")
    reload_script = out / "AFDX_top_mapped_il_reload.ys"
    reload_script.write_text(f"read_ilang {ys_path(out / 'AFDX_top_mapped.il')}\nselect *\ncheck -assert -noinit\n",
                             encoding="ascii")
    whole_check = N3 / "whole_postabc_check.ys"
    if sha(whole_check) != state.get("whole_check_result", {}).get("script_sha256"):
        raise SystemExit("N3 whole-design CHECK script hash mismatch")
    run_status = {
        "schema": "netlist-n3-native-postmap-v1", "status": "RUNNING",
        "started_local": datetime.now().astimezone().isoformat(),
        "scope": "Diagnostic eLinx native post-ABC mapping/export from N3 whole_postabc.il (70 unused-COUT declaration closure); includes whole CHECK, native VQM export, and fresh-process mapped-IL reload CHECK. Not full equivalence or business acceptance.",
        "n3_run_status_sha256": sha(N3 / "run_status.json"),
        "n3_integrity_audit_sha256": sha(N3 / "integrity_audit.json"),
        "n3_whole_il_sha256": sha(n3_il), "candidate_sha256": sha(CANDIDATE),
        "native_script_sha256": sha(NATIVE_SCRIPT), "runner_sha256": sha(Path(__file__)),
        "runner_snapshot_sha256": sha(runner_snapshot), "tool_path": str(tool),
        "tool_sha256": sha(tool), "abc_path": str(abc), "abc_sha256": sha(abc),
        "preselected_cec_status_sha256": sha(CEC),
        "mapping_preservation_status_sha256": sha(PRESERVATION),
        "postmap_script_sha256": sha(post_script), "il_reload_script_sha256": sha(reload_script),
        "stages": {}, "artifacts": {},
    }
    write_json(out / "postmap_status.json", run_status)
    try:
        stages = [
            run_stage(run_status, out, "whole_check", whole_check, tool, 120),
            run_stage(run_status, out, "native_postmap", post_script, tool, 900),
        ]
        for stage in stages:
            if stage["status"] != "PASS":
                raise RuntimeError(f"Stage {stage['script']} failed; see its exact log and status")
        for filename in ("AFDX_top_native.vqm", "AFDX_top_mapped.il", "AFDX_top_preexport.il"):
            artifact = out / filename
            if not artifact.is_file() or artifact.stat().st_size == 0:
                raise RuntimeError(f"Postmap did not produce non-empty {filename}")
            run_status["artifacts"][filename] = {"bytes": artifact.stat().st_size, "sha256": sha(artifact)}
        reload_record = run_stage(run_status, out, "fresh_il_reload", reload_script, tool, 180)
        if reload_record["status"] != "PASS":
            raise RuntimeError("Fresh-process mapped IL reload/CHECK failed")
        run_status.update({"status": "PASS_N3_DIAGNOSTIC_VQM_EXPORTED_AND_IL_RELOADED",
                           "business_verdict": None,
                           "scope_note": "All results are bound to the N3 diagnostic COUT-closure input. Three selected combinational cones passed; eight modules had no ABC output and whole-design sequential/RAM/initialization equivalence remains unproved."})
    except Exception as exc:
        run_status.update({"status": "FAILED_STOP", "error": str(exc)})
    finally:
        run_status["ended_local"] = datetime.now().astimezone().isoformat()
        write_json(out / "postmap_status.json", run_status)
    print(json.dumps({"status": run_status["status"], "path": str(out),
                      "artifacts": run_status.get("artifacts"),
                      "stages": {name: row.get("status") for name, row in run_status["stages"].items()}},
                     ensure_ascii=False))
    return 0 if run_status["status"] == "PASS_N3_DIAGNOSTIC_VQM_EXPORTED_AND_IL_RELOADED" else 1


if __name__ == "__main__":
    raise SystemExit(main())
