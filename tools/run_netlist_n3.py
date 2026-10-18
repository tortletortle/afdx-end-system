"""N3 frozen-candidate per-module ABC mapping and independent whole CHECK.

This diagnostic never edits production RTL and never claims functional or VQM
acceptance. Historical helpers are hash-pinned, copied into the run, and used
only for IL indexing, interface comparison and byte-range assembly.
"""
from __future__ import annotations

import argparse
import collections
import datetime as dt
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time


def find_root():
    for parent in Path(__file__).resolve().parents:
        if (parent / "rtl/top/AFDX_top.v").is_file() and (parent / "tools").is_dir():
            return parent
    raise RuntimeError("Cannot locate workspace from runner path")


ROOT = find_root()
CANDIDATE = ROOT / "out/production_repairs_native_hierarchy_default_20261013_r1/candidate.json"
CANDIDATE_SHA = "7337fb46f5c7deb2e6360cb882c9a906e8543ef84627431c5c9a06ab4c74158e"
SOURCE = ROOT / "out/netlist_n2_preabc_declared_cout_reload_20261014_r1/diagnostic_declared_cout.il"
SOURCE_SHA = "d97a1d368a637e692b434904b50583c927489ef7609dc521885a4bce2e718aeb"
COUT_AUDIT = SOURCE.parent / "cout_audit.json"
COUT_AUDIT_SHA = "6162787e63c9a78bed28a18cabe8834df4d4733426eb0b9d9d715690fa3579de"
HELPERS = ROOT / "out/c4_fresh_process_mapping_all_20261012_r2/runner_snapshot.py"
HELPERS_SHA = "1869d033eeed840575034b896b4b6d401c9a09df60bccd4288f2529d2dcabfb9"
MEMORY_HELPER = ROOT / "tools/run_netlist_n2_reload.py"
MEMORY_HELPER_SHA = "b5ceb1cda3e30d7c566295e3b43d9c9c8ba84f3f9662cffd6405e2de488de682"
TFTP = r"$paramod$3eec85f513867eb67bf2c18df61a999b8a6e24d5\a615a_tftp"


def now():
    return dt.datetime.now().astimezone().isoformat()


def sha(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def locked(path, expected):
    if sha(path) != expected:
        raise RuntimeError(f"Frozen SHA mismatch: {path}")


def load_helper(path, expected, name):
    locked(path, expected)
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def candidate_check(candidate):
    locked(CANDIDATE, CANDIDATE_SHA)
    for rel, expected in candidate["input_sha256"].items():
        locked(CANDIDATE.parent / rel, expected)
    for rel in candidate["rtl_sources"]:
        locked(ROOT / rel, candidate["input_sha256"]["input/" + rel.replace("\\", "/")])
    if len(candidate["rtl_sources"]) != 50:
        raise RuntimeError("Expected 50 frozen RTL sources")
    for key in ("synthesis_executable", "abc_executable"):
        locked(Path(candidate[key]), candidate[key + "_sha256"])


def verify_cout_closure():
    locked(COUT_AUDIT, COUT_AUDIT_SHA)
    audit = json.loads(COUT_AUDIT.read_text(encoding="utf-8-sig"))
    rows = [row for values in audit.values() for row in values]
    if len(rows) != 70 or len(audit) != 18 or any(row["total_signal_references"] != 1 for row in rows):
        raise RuntimeError("COUT diagnostic closure audit inventory is unexpected")
    original = ROOT / "out/netlist_n2_preabc_live_check_20261014_r1/AFDX_top_preabc_checked.il"
    metadata = json.loads((SOURCE.parent / "metadata.json").read_text(encoding="utf-8-sig"))
    if sha(original) != "bc562086294861d0d4559307ab7c318718b5695199176739f2fb3d05719616f5":
        raise RuntimeError("Frozen pre-ABC source hash changed")
    if metadata.get("source_sha256") != sha(original) or metadata.get("load_input_sha256") != SOURCE_SHA:
        raise RuntimeError("COUT closure metadata does not bind the frozen source and derivative")
    with original.open("rb") as source, SOURCE.open("rb") as derivative:
        for raw in source:
            if derivative.readline() != raw:
                raise RuntimeError("Diagnostic IL differs beyond COUT declaration insertions")
            if raw.startswith(b"module "):
                module = raw.decode("utf-8")[7:].strip()
                for row in audit.get(module, []):
                    if derivative.readline() != ("  wire " + row["net"] + "\n").encode("utf-8"):
                        raise RuntimeError("COUT declaration insertion differs from audit")
        if derivative.read(1):
            raise RuntimeError("Diagnostic IL has unexpected trailing bytes")
    return {"inserted_declarations": len(rows), "affected_modules": len(audit),
            "source_sha256": sha(original), "derivative_sha256": sha(SOURCE),
            "insertion_only_verified": True}


def run_tool(tool, script, directory, timeout, memory, required_checks):
    argv = [str(tool), "-Q", "-T", "-s", str(script), "-l", str(directory / "synthesis.log")]
    start = time.monotonic()
    timed_out = False
    kill = None
    peak = 0
    samples = 0
    with (directory / "stdout.log").open("wb") as stdout, (directory / "stderr.log").open("wb") as stderr:
        proc = subprocess.Popen(argv, cwd=directory, stdout=stdout, stderr=stderr,
                                creationflags=subprocess.CREATE_NO_WINDOW | subprocess.CREATE_NEW_PROCESS_GROUP)
        write_json(directory / "process.json", {"pid": proc.pid, "started_local": now(), "argv": argv})
        with (directory / "resource_samples.jsonl").open("w", encoding="utf-8") as resource:
            while True:
                row = memory.sample(proc)
                row["elapsed_seconds"] = round(time.monotonic() - start, 3)
                resource.write(json.dumps(row) + "\n")
                resource.flush()
                samples += 1
                peak = max(peak, row.get("peak_private_bytes") or 0)
                try:
                    proc.wait(timeout=1)
                    break
                except subprocess.TimeoutExpired:
                    if time.monotonic() - start >= timeout:
                        timed_out = True
                        try:
                            killer = subprocess.run(["taskkill", "/PID", str(proc.pid), "/T", "/F"],
                                                    capture_output=True, timeout=15,
                                                    creationflags=subprocess.CREATE_NO_WINDOW)
                            kill = {"method": "taskkill_owned_tree", "return_code": killer.returncode,
                                    "output": killer.stdout.decode(errors="replace")[-1000:]}
                        except subprocess.TimeoutExpired:
                            kill = {"method": "taskkill_owned_tree", "helper_timed_out": True}
                        if proc.poll() is None:
                            proc.kill()
                        proc.wait(timeout=15)
                        break
            row = memory.sample(proc)
            peak = max(peak, row.get("peak_private_bytes") or 0)
            resource.write(json.dumps(row) + "\n")
    log = directory / "synthesis.log"
    lines = log.read_text(encoding="utf-8", errors="replace").splitlines() if log.exists() else []
    warnings = [line for line in lines if line.startswith("Warning:")]
    errors = [line for line in lines if line.startswith("ERROR:")]
    checks = sum("Executing CHECK pass" in line for line in lines)
    success = any("Yosys execute success!" in line for line in lines)
    result = {"started_argv": argv, "exit_code": proc.returncode, "timed_out": timed_out,
              "wall_seconds": round(time.monotonic() - start, 3), "pid": proc.pid,
              "check_pass_count": checks, "success_marker": success,
              "warning_count": len(warnings), "error_count": len(errors),
              "conflicting_driver_count": sum("multiple conflicting drivers" in line for line in warnings),
              "logic_loop_count": sum("found logic loop" in line for line in warnings),
              "errors": errors, "warning_examples": warnings[:5], "peak_private_bytes": peak,
              "resource_sample_count": samples + 1, "timeout_cleanup": kill,
              "log_sha256": sha(log) if log.exists() else None, "script_sha256": sha(script),
              "status": "PASS" if proc.returncode == 0 and not timed_out and success and
                  checks >= required_checks and not warnings and not errors else "FAIL"}
    write_json(directory / "process_result.json", result)
    return result


def declare_unused_cout(source, directory, memory):
    audit = memory.audit_cout(source)
    rows = [row for values in audit.values() for row in values]
    write_json(directory / "cout_export_audit.json", audit)
    if not rows:
        return source, 0
    if any(row["total_signal_references"] != 1 for row in rows):
        raise RuntimeError(f"Export contains consumed/ambiguous undeclared COUT: {source}")
    closed = directory / "mapped_module_declared_cout.il"
    with source.open("rb") as original, closed.open("wb") as derivative:
        for raw in original:
            derivative.write(raw)
            if raw.startswith(b"module "):
                module = raw.decode("utf-8")[7:].strip()
                for row in audit.get(module, []):
                    derivative.write(("  wire " + row["net"] + "\n").encode("utf-8"))
    with source.open("rb") as original, closed.open("rb") as derivative:
        for raw in original:
            if derivative.readline() != raw:
                raise RuntimeError("Export closure differs beyond inserted declaration")
            if raw.startswith(b"module "):
                module = raw.decode("utf-8")[7:].strip()
                for row in audit.get(module, []):
                    if derivative.readline() != ("  wire " + row["net"] + "\n").encode("utf-8"):
                        raise RuntimeError("Export closure declaration mismatch")
        if derivative.read(1):
            raise RuntimeError("Export closure has unexpected trailing bytes")
    return closed, len(rows)


def lut_audit(path):
    module = None
    lut = False
    outputs = collections.defaultdict(collections.Counter)
    for line in path.open(encoding="utf-8"):
        if line.startswith("module "):
            module = line[7:].strip()
        elif line.startswith("  cell "):
            lut = line.split()[1] == "$lut"
        elif line.startswith("  end"):
            lut = False
        elif lut and line.startswith("    connect \\Y "):
            expr = line.split(maxsplit=2)[2].strip()
            if len(expr.split()) != 1 or expr.startswith("{"):
                raise RuntimeError(f"Unsupported LUT output expression: {expr}")
            outputs[module][expr] += 1
    return {"path": str(path), "sha256": sha(path),
            "lut_count": sum(sum(values.values()) for values in outputs.values()),
            "duplicate_lut_output_nets": sum(sum(count > 1 for count in values.values()) for values in outputs.values()),
            "per_module": {name: {"lut_count": sum(values.values()),
                                    "duplicate_output_nets": sum(count > 1 for count in values.values())}
                           for name, values in outputs.items()}}


def blif_audit(directory):
    files = []
    for path in sorted(directory.glob("_tmp_yosys-abc-*/*.blif")):
        names = collections.Counter()
        for line in path.open(encoding="utf-8"):
            fields = line.split()
            if fields and fields[0] == ".names":
                if len(fields) < 2 or fields[-1] == "\\":
                    raise RuntimeError(f"Unsupported BLIF directive: {path}")
                names[fields[-1]] += 1
        files.append({"path": str(path), "sha256": sha(path), "bytes": path.stat().st_size,
                      "names_count": sum(names.values()), "duplicate_names_outputs": sum(n > 1 for n in names.values())})
    return files


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--module-timeout", type=int, default=300)
    parser.add_argument("--whole-timeout", type=int, default=600)
    args = parser.parse_args()
    out = args.out.resolve()
    if not out.is_relative_to(ROOT / "out") or out == ROOT / "out" or out.exists():
        raise RuntimeError("Output must be a new directory strictly below workspace/out")
    if min(args.module_timeout, args.whole_timeout) < 1:
        raise RuntimeError("Timeouts must be positive")
    legacy = load_helper(HELPERS, HELPERS_SHA, "n3_frozen_il_helpers")
    memory = load_helper(MEMORY_HELPER, MEMORY_HELPER_SHA, "n3_frozen_memory_helper")
    legacy.validate_module_interface_parser()
    locked(SOURCE, SOURCE_SHA)
    cout_closure = verify_cout_closure()
    candidate = json.loads(CANDIDATE.read_text(encoding="utf-8-sig"))
    candidate_check(candidate)
    records, source_autoidx = legacy.scan_ilang(SOURCE)
    if len(records) != 61 or sum(record.blackbox for record in records) != 11:
        raise RuntimeError("Expected current 61-module, 11-blackbox candidate")
    by_name = {record.name: record for record in records}
    ordered = [by_name[TFTP]] + [record for record in records if not record.blackbox and record.name != TFTP]
    out.mkdir(parents=True)
    inputs = out / "inputs"
    inputs.mkdir()
    for source, name in ((SOURCE, "closed.il"), (COUT_AUDIT, "cout_audit.json"),
                         (CANDIDATE, "candidate.json"), (HELPERS, "legacy_helpers.py"),
                         (MEMORY_HELPER, "memory_helper.py"), (Path(__file__), "runner_snapshot.py")):
        shutil.copy2(source, inputs / name)
    source_il = inputs / "closed.il"
    legacy.CLOSED_IL = source_il
    runner_sha = sha(inputs / "runner_snapshot.py")
    state = {"schema": "netlist-n3-fresh-process-v1", "started_local": now(), "status": "RUNNING",
             "phase": "MODULE_MAPPING", "mapping": "RUNNING", "assembly": "NOT_RUN", "whole_check": "NOT_RUN",
             "functional_equivalence": "NOT_VERIFIED", "native_vqm": "NOT_RUN",
             "production_rtl_edited": False, "candidate_sha256": CANDIDATE_SHA, "input_sha256": SOURCE_SHA,
             "runner_sha256": runner_sha, "legacy_helpers_sha256": HELPERS_SHA, "memory_helper_sha256": MEMORY_HELPER_SHA,
             "tool_sha256": candidate["synthesis_executable_sha256"], "abc_sha256": candidate["abc_executable_sha256"],
             "diagnostic_cout_closure": cout_closure,
             "source_module_count": 61, "blackbox_count": 11, "nonblackbox_count": 50,
             "module_order": [record.name for record in ordered], "completed_modules": [],
             "scope": "Diagnostic structure acceptance only; not functional equivalence, production VQM or project completion."}
    write_json(out / "run_status.json", state)
    shutil.copy2(COUT_AUDIT, out / "cout_closure_audit.json")
    write_json(out / "module_inventory.json", [{"module": record.name, "blackbox": record.blackbox,
        "interface": legacy.module_interface(source_il, record), "attributes": legacy.module_prefix_attrs(source_il, record)} for record in records])
    mapped = {}
    tool = Path(candidate["synthesis_executable"])
    abc = Path(candidate["abc_executable"])
    started = time.monotonic()
    try:
        for index, record in enumerate(ordered, 1):
            state["current_module"] = record.name
            write_json(out / "run_status.json", state)
            locked(source_il, SOURCE_SHA)
            directory = out / "modules" / legacy.safe_leaf(index, record.name)
            directory.mkdir(parents=True)
            raw = directory / "mapped_module.il"
            script = directory / "run.ys"
            script.write_text(legacy.module_script(source_il, record.name, abc, raw).replace("check -assert\n", "check -assert -noinit\n"), encoding="utf-8")
            result = run_tool(tool, script, directory, args.module_timeout, memory, 2)
            item = {"module": record.name, "index": index, "process": result,
                    "input_sha256": SOURCE_SHA, "runner_sha256": runner_sha}
            write_json(directory / "module_metadata.json", item)
            if result["status"] != "PASS" or not raw.is_file():
                raise RuntimeError(f"Module mapping/check/export failed: {record.name}")
            exported, added = declare_unused_cout(raw, directory, memory)
            output_records, _ = legacy.scan_ilang(exported)
            if len(output_records) != 1 or output_records[0].name != record.name or output_records[0].blackbox:
                raise RuntimeError(f"Export module identity mismatch: {record.name}")
            output_record = output_records[0]
            if legacy.module_interface(source_il, record) != legacy.module_interface(exported, output_record):
                raise RuntimeError(f"Export interface changed: {record.name}")
            if sorted(legacy.module_prefix_attrs(source_il, record)) != sorted(legacy.module_prefix_attrs(exported, output_record)):
                raise RuntimeError(f"Export module attributes changed: {record.name}")
            structure = lut_audit(exported)
            blifs = blif_audit(directory)
            item.update({"output_path": str(exported), "output_sha256": sha(exported),
                         "raw_output_sha256": sha(raw), "added_unused_cout_declarations": added,
                         "interface_unchanged": True, "module_attributes_unchanged": True,
                         "structure": structure, "blif_files": blifs})
            write_json(directory / "module_metadata.json", item)
            if structure["duplicate_lut_output_nets"] or any(row["duplicate_names_outputs"] for row in blifs):
                raise RuntimeError(f"Duplicate mapped LUT/BLIF output: {record.name}")
            if index == 1:
                state["phase"] = "TFTP_EXPORT_RELOAD"
                write_json(out / "run_status.json", state)
                reload_dir = out / "tftp_export_reload"
                reload_dir.mkdir()
                reload_script = reload_dir / "run.ys"
                reload_script.write_text(f'read_ilang "{source_il.as_posix()}"\nread_ilang -overwrite "{exported.as_posix()}"\nselect -module {record.name}\ncheck -assert -noinit\n', encoding="utf-8")
                reloaded = run_tool(tool, reload_script, reload_dir, args.module_timeout, memory, 1)
                state["tftp_export_reload"] = reloaded
                write_json(out / "run_status.json", state)
                if reloaded["status"] != "PASS":
                    raise RuntimeError("TFTP export independent reload/check failed")
                state["phase"] = "MODULE_MAPPING"
            mapped[record.name] = exported
            state["completed_modules"].append(record.name)
            write_json(out / "run_status.json", state)
            print(json.dumps({"phase": "mapped", "completed": index, "total": 50, "module": record.name,
                              "lut_count": structure["lut_count"], "seconds": result["wall_seconds"]}), flush=True)
        state.update({"mapping": "PASS", "phase": "ASSEMBLY", "assembly": "RUNNING"})
        write_json(out / "run_status.json", state)
        whole, check_script = legacy.assemble_whole(out, records, mapped, source_autoidx)
        assembled, _ = legacy.scan_ilang(whole)
        if [(r.name, r.blackbox) for r in assembled] != [(r.name, r.blackbox) for r in records]:
            raise RuntimeError("Whole assembly module inventory mismatch")
        for before, after in zip(records, assembled):
            if legacy.module_interface(source_il, before) != legacy.module_interface(whole, after):
                raise RuntimeError(f"Whole assembly interface mismatch: {before.name}")
        structure = lut_audit(whole)
        write_json(out / "whole_structure_audit.json", structure)
        if structure["duplicate_lut_output_nets"]:
            raise RuntimeError("Whole assembly has duplicate LUT outputs")
        state.update({"assembly": "PASS", "phase": "WHOLE_CHECK", "whole_check": "RUNNING",
                      "whole_il": str(whole), "whole_il_sha256": sha(whole)})
        write_json(out / "run_status.json", state)
        check_dir = out / "whole_check"
        check_dir.mkdir()
        result = run_tool(tool, check_script, check_dir, args.whole_timeout, memory, 1)
        state["whole_check_result"] = result
        state["whole_check"] = result["status"]
        if result["status"] != "PASS":
            raise RuntimeError("Independent full-design CHECK failed")
        candidate_check(candidate)
        state.update({"status": "PASS_N3_STRUCTURE_ONLY", "phase": "COMPLETE",
                      "frozen_and_workspace_rtl_unchanged": True})
    except Exception as error:
        state.update({"status": "FAIL_N3", "failure_phase": state["phase"], "error": str(error),
                      "not_run_modules": [record.name for record in ordered if record.name not in mapped]})
        for field in ("mapping", "assembly", "whole_check"):
            if state[field] == "RUNNING":
                state[field] = "FAIL"
    state.update({"ended_local": now(), "wall_seconds": round(time.monotonic() - started, 3)})
    write_json(out / "run_status.json", state)
    print(json.dumps({key: state.get(key) for key in ("status", "failure_phase", "error", "mapping", "assembly", "whole_check", "wall_seconds")}, ensure_ascii=False), flush=True)
    return 0 if state["status"] == "PASS_N3_STRUCTURE_ONLY" else 1


if __name__ == "__main__":
    raise SystemExit(main())
