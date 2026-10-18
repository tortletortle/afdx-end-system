"""Verify the saved N3 run and distinguish structure PASS from signoff."""
from __future__ import annotations

import collections
import datetime as dt
import hashlib
import importlib.util
import json
from pathlib import Path


def workspace_root():
    for parent in Path(__file__).resolve().parents:
        if (parent / "rtl/top/AFDX_top.v").is_file():
            return parent
    raise RuntimeError("Cannot locate workspace")


ROOT = workspace_root()
RUN = ROOT / "out/netlist_n3_fresh_process_mapping_20261014_r1"
RUNNER = ROOT / "tools/run_netlist_n3.py"
CANDIDATE = ROOT / "out/production_repairs_native_hierarchy_default_20261013_r1/candidate.json"
COUT_SOURCE = ROOT / "out/netlist_n2_preabc_declared_cout_reload_20261014_r1/diagnostic_declared_cout.il"
LEGACY = ROOT / "out/c4_fresh_process_mapping_all_20261012_r2/runner_snapshot.py"
MEMORY = ROOT / "tools/run_netlist_n2_reload.py"


def sha(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_json(path):
    return json.loads(Path(path).read_text(encoding="utf-8-sig"))


def load_helper(path):
    spec = importlib.util.spec_from_file_location("n3_audit_legacy", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def blif_duplicate_count(path):
    outputs = collections.Counter()
    for line in Path(path).open(encoding="utf-8"):
        fields = line.split()
        if fields and fields[0] == ".names":
            if len(fields) < 2 or fields[-1] == "\\":
                raise ValueError(f"Unsupported BLIF line in {path}")
            outputs[fields[-1]] += 1
    return sum(count > 1 for count in outputs.values())


def lut_output_audit(path):
    outputs = collections.defaultdict(collections.Counter)
    module = None
    in_lut = False
    for line in Path(path).open(encoding="utf-8"):
        if line.startswith("module "):
            module = line[7:].strip()
        elif line.startswith("  cell "):
            in_lut = line.split()[1] == "$lut"
        elif line.startswith("  end"):
            in_lut = False
        elif in_lut and line.startswith("    connect \\Y "):
            expr = line.split(maxsplit=2)[2].strip()
            if len(expr.split()) != 1 or expr.startswith("{"):
                raise ValueError(f"Unsupported LUT output expression {expr}")
            outputs[module][expr] += 1
    return {"lut_count": sum(sum(v.values()) for v in outputs.values()),
            "duplicate_output_nets": sum(sum(n > 1 for n in v.values()) for v in outputs.values())}


def main():
    failures = []
    checked = {}

    def verify(path, expected, label=None):
        path = Path(path)
        name = label or str(path)
        if not path.is_file():
            failures.append({"path": name, "error": "missing"})
            return None
        actual = sha(path)
        checked[name] = {"sha256": actual, "bytes": path.stat().st_size}
        if expected and actual != expected:
            failures.append({"path": name, "expected_sha256": expected, "actual_sha256": actual})
        return actual

    state = load_json(RUN / "run_status.json")
    candidate = load_json(CANDIDATE)
    if state.get("status") != "PASS_N3_STRUCTURE_ONLY":
        failures.append({"error": "N3 state is not PASS_N3_STRUCTURE_ONLY", "status": state.get("status")})
    if state.get("mapping") != "PASS" or state.get("assembly") != "PASS" or state.get("whole_check") != "PASS":
        failures.append({"error": "One or more N3 execution stages did not pass"})
    if state.get("functional_equivalence") != "NOT_VERIFIED" or state.get("native_vqm") != "NOT_RUN":
        failures.append({"error": "Scope boundary metadata changed unexpectedly"})
    verify(RUNNER, state.get("runner_sha256"), "workspace N3 runner")
    verify(RUN / "inputs/runner_snapshot.py", state.get("runner_sha256"), "run-local N3 runner")
    verify(LEGACY, state.get("legacy_helpers_sha256"), "legacy IL helper")
    verify(MEMORY, state.get("memory_helper_sha256"), "memory helper")
    verify(RUN / "inputs/legacy_helpers.py", state.get("legacy_helpers_sha256"), "run-local legacy helper")
    verify(RUN / "inputs/memory_helper.py", state.get("memory_helper_sha256"), "run-local memory helper")
    verify(CANDIDATE, state.get("candidate_sha256"), "candidate manifest")
    verify(COUT_SOURCE, state.get("input_sha256"), "diagnostic N3 input")
    for rel, expected in candidate["input_sha256"].items():
        verify(CANDIDATE.parent / rel, expected, "candidate input/" + rel)
    for rel in candidate["rtl_sources"]:
        key = "input/" + rel.replace("\\", "/")
        verify(ROOT / rel, candidate["input_sha256"][key], "workspace RTL/" + rel)
    verify(Path(candidate["synthesis_executable"]), candidate["synthesis_executable_sha256"], "eLinx executable")
    verify(Path(candidate["abc_executable"]), candidate["abc_executable_sha256"], "ABC executable")

    helper = load_helper(RUN / "inputs/legacy_helpers.py")
    source_records, source_autoidx = helper.scan_ilang(COUT_SOURCE)
    whole = RUN / "whole_postabc.il"
    whole_records, whole_autoidx = helper.scan_ilang(whole)
    if [(r.name, r.blackbox) for r in source_records] != [(r.name, r.blackbox) for r in whole_records]:
        failures.append({"error": "Whole IL module/blackbox inventory differs from frozen source"})
    if len(source_records) != 61 or sum(r.blackbox for r in source_records) != 11:
        failures.append({"error": "Frozen source inventory is not 61 modules / 11 blackboxes"})
    if whole_autoidx < source_autoidx:
        failures.append({"error": "Assembled IL autoidx is lower than frozen source"})
    for before, after in zip(source_records, whole_records):
        if helper.module_interface(COUT_SOURCE, before) != helper.module_interface(whole, after):
            failures.append({"error": "Whole module interface changed", "module": before.name})
        if before.blackbox:
            with COUT_SOURCE.open("rb") as a, whole.open("rb") as b:
                a.seek(before.start); b.seek(after.start)
                if a.read(before.end-before.start) != b.read(after.end-after.start):
                    failures.append({"error": "Blackbox body changed", "module": before.name})

    inventory = load_json(RUN / "module_inventory.json")
    expected_logic = {r.name for r in source_records if not r.blackbox}
    if {row["module"] for row in inventory if not row["blackbox"]} != expected_logic:
        failures.append({"error": "Saved module inventory differs from source"})
    metadata_files = sorted((RUN / "modules").glob("*/module_metadata.json"))
    modules = []
    all_blifs = []
    max_private = 0
    wall_seconds = []
    for metadata_path in metadata_files:
        item = load_json(metadata_path)
        name = item["module"]
        process = item["process"]
        if name not in expected_logic:
            failures.append({"error": "Unexpected mapped module", "module": name})
        if process.get("status") != "PASS" or process.get("exit_code") != 0 or process.get("timed_out"):
            failures.append({"error": "Module process did not pass", "module": name, "process": process})
        if process.get("warning_count") or process.get("error_count") or process.get("check_pass_count", 0) < 2:
            failures.append({"error": "Module log does not meet check criteria", "module": name})
        module_dir = metadata_path.parent
        raw = module_dir / "mapped_module.il"
        exported = Path(item["output_path"])
        verify(raw, item.get("raw_output_sha256"), f"raw output {name}")
        verify(exported, item.get("output_sha256"), f"mapped output {name}")
        verify(module_dir / "run.ys", process.get("script_sha256"), f"run script {name}")
        verify(module_dir / "synthesis.log", process.get("log_sha256"), f"synthesis log {name}")
        output_records, _ = helper.scan_ilang(exported)
        if len(output_records) != 1 or output_records[0].name != name:
            failures.append({"error": "Mapped output identity mismatch", "module": name})
        elif helper.module_interface(COUT_SOURCE, next(r for r in source_records if r.name == name)) != helper.module_interface(exported, output_records[0]):
            failures.append({"error": "Mapped output interface differs", "module": name})
        lut = lut_output_audit(exported)
        if lut["duplicate_output_nets"] != item["structure"]["duplicate_lut_output_nets"] or lut["duplicate_output_nets"]:
            failures.append({"error": "Mapped output LUT audit mismatch/failure", "module": name, "audit": lut})
        for blif in item["blif_files"]:
            path = Path(blif["path"])
            verify(path, blif.get("sha256"), f"BLIF {name}/{path.name}")
            duplicate_names = blif_duplicate_count(path)
            all_blifs.append({"module": name, "path": str(path), "duplicate_names_outputs": duplicate_names})
            if duplicate_names != blif.get("duplicate_names_outputs") or duplicate_names:
                failures.append({"error": "BLIF names audit mismatch/failure", "module": name, "path": str(path)})
        max_private = max(max_private, process.get("peak_private_bytes") or 0)
        wall_seconds.append(process.get("wall_seconds", 0))
        modules.append(name)
    if len(modules) != 50 or set(modules) != expected_logic or len(set(modules)) != 50:
        failures.append({"error": "Expected exactly 50 unique mapped modules", "actual": len(modules)})
    if len(state.get("completed_modules", [])) != 50 or set(state["completed_modules"]) != expected_logic:
        failures.append({"error": "Run state does not list all 50 mapped modules"})

    whole_hash = verify(whole, state.get("whole_il_sha256"), "assembled whole IL")
    structure = load_json(RUN / "whole_structure_audit.json")
    actual_structure = lut_output_audit(whole)
    if structure.get("sha256") != whole_hash or structure.get("lut_count") != actual_structure["lut_count"] or actual_structure["duplicate_output_nets"]:
        failures.append({"error": "Whole static LUT audit mismatch/failure", "actual": actual_structure})
    check_result = state.get("whole_check_result", {})
    check_dir = RUN / "whole_check"
    verify(RUN / "whole_postabc_check.ys", check_result.get("script_sha256"), "whole-check script")
    verify(check_dir / "synthesis.log", check_result.get("log_sha256"), "whole-check log")
    log_lines = (check_dir / "synthesis.log").read_text(encoding="utf-8", errors="replace").splitlines()
    actual_warnings = sum(line.startswith("Warning:") for line in log_lines)
    actual_errors = sum(line.startswith("ERROR:") for line in log_lines)
    if check_result.get("status") != "PASS" or check_result.get("exit_code") != 0 or check_result.get("timed_out"):
        failures.append({"error": "Full-design CHECK did not pass", "result": check_result})
    if actual_warnings or actual_errors or not any("Executing CHECK pass" in line for line in log_lines) or not any("Yosys execute success!" in line for line in log_lines):
        failures.append({"error": "Full-design CHECK log does not meet criteria", "warnings": actual_warnings, "errors": actual_errors})
    if actual_warnings != check_result.get("warning_count") or actual_errors != check_result.get("error_count"):
        failures.append({"error": "Full-check log counts differ from process result"})

    for name in ("whole_postabc_check.ys", "module_inventory.json", "cout_closure_audit.json"):
        path = RUN / name
        if not path.is_file():
            failures.append({"path": str(path), "error": "missing"})

    result = {
        "schema": "netlist-n3-integrity-audit-v1", "created_local": dt.datetime.now().astimezone().isoformat(),
        "status": "PASS_EVIDENCE_INTEGRITY" if not failures else "FAIL_EVIDENCE_INTEGRITY",
        "scope": "Artifact integrity only. N3 structure check is not functional equivalence, native VQM or project acceptance.",
        "n3_status": state.get("status"), "n3_runner_sha256": state.get("runner_sha256"),
        "candidate_sha256": state.get("candidate_sha256"), "input_sha256": state.get("input_sha256"),
        "module_count": len(whole_records), "blackbox_count": sum(r.blackbox for r in whole_records),
        "mapped_module_count": len(modules), "module_metadata_count": len(metadata_files),
        "saved_blif_count": len(all_blifs), "saved_blif_duplicate_output_names": sum(x["duplicate_names_outputs"] for x in all_blifs),
        "whole_il_sha256": whole_hash, "whole_lut_count": actual_structure["lut_count"],
        "whole_duplicate_lut_output_nets": actual_structure["duplicate_output_nets"],
        "whole_check_exit_code": check_result.get("exit_code"), "whole_check_warning_count": actual_warnings,
        "whole_check_error_count": actual_errors, "whole_check_private_peak_bytes": check_result.get("peak_private_bytes"),
        "maximum_individual_module_private_peak_bytes": max_private,
        "mapping_wall_seconds_sum": round(sum(wall_seconds), 3), "failures": failures, "checked_files": checked,
        "not_covered": ["functional equivalence", "native mapped IL/VQM export", "netlist simulation", "timing/PPA", "615A/665 and 2 ms signoff"],
    }
    output = RUN / "integrity_audit.json"
    output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({k: result[k] for k in ("status", "n3_status", "module_count", "blackbox_count", "mapped_module_count", "saved_blif_count", "whole_il_sha256", "whole_lut_count", "whole_duplicate_lut_output_nets", "whole_check_exit_code", "whole_check_warning_count", "whole_check_error_count", "failures")}, ensure_ascii=False))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
