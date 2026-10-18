"""Recheck saved N2 evidence without running synthesis or editing RTL.

PASS_EVIDENCE_INTEGRITY means recorded artifacts still match their manifests.
It never means the production netlist, simulation or project has passed.
"""
from __future__ import annotations

import collections
import datetime as dt
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EVIDENCE = ROOT / "out/netlist_n2_instrumented_20261014_r1"
LOCKS = {
    "evidence_analysis_v2.json": "7b52fd7e031881e642b38c4546507fd201ae2ac2feef4029d6dd662b0dd4b974",
    "evidence_analysis_v3.json": "2c426c165fbd727cb0c8e21c1b2387ce71efa295bb7029fece5642c2422a2a5f",
    "structure_audit_v2.json": "f0ab902c20f3dce4f231ffef084525cde236d93df397fe69d59cacd3c62df7d7",
    "AFDX_top_preabc.il": "3293803e19b300999ce0ebbd75649429b5e2b8998ce78d61e44d3671013e1368",
    "AFDX_top_postabc.il": "da1c5b9acf49799413202b248662f998b7f0ba4dc474b4911aa38524da46c173",
    "n2_synthesis.log": "4cd88f035cdbbdf5450ce85e6a77f088d25df93896e4eeade0de989c9e4271b9",
    "N2_REPORT_v1_20261014_1332.md": "0958a9aa87b8caaf5c35d5d5d518a962cbf6047d5dd79b9b3479bfa9f40a8837",
}


def sha(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def read_json(path: Path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


def main() -> int:
    failures = []
    checked = {}

    def verify(path: Path, expected: str, size=None):
        key = str(path)
        if not path.is_file():
            failures.append({"path": key, "error": "missing"})
            return
        actual = checked.get(key, {}).get("sha256") or sha(path)
        checked[key] = {"sha256": actual, "bytes": path.stat().st_size}
        if actual != expected or (size is not None and size != path.stat().st_size):
            failures.append({"path": key, "expected_sha256": expected,
                             "actual_sha256": actual, "expected_bytes": size})

    for name, expected in LOCKS.items():
        verify(EVIDENCE / name, expected)
    v3 = read_json(EVIDENCE / "evidence_analysis_v3.json")
    v2 = read_json(EVIDENCE / "evidence_analysis_v2.json")
    candidate_path = ROOT / v3["candidate"] / "candidate.json"
    verify(candidate_path, "7337fb46f5c7deb2e6360cb882c9a906e8543ef84627431c5c9a06ab4c74158e")
    candidate = read_json(candidate_path)
    frozen_rtl = []
    for rel, expected in candidate["input_sha256"].items():
        verify(candidate_path.parent / rel, expected)
        if rel.replace("\\", "/").startswith("input/rtl/"):
            frozen_rtl.append(rel)
    workspace_rtl = []
    for rel in candidate["rtl_sources"]:
        frozen_key = "input/" + rel.replace("\\", "/")
        verify(ROOT / rel, candidate["input_sha256"][frozen_key])
        workspace_rtl.append(rel)

    run_log_counts = {}
    for rel, row in v3["runs"].items():
        directory = ROOT / rel
        for name, record in row["files"].items():
            verify(directory / name, record["sha256"], record["bytes"])
        for name in ("result", "metadata"):
            path = directory / (name + ".json")
            if name in row and path.exists() and read_json(path) != row[name]:
                failures.append({"path": str(path), "error": "manifest JSON content differs"})
        result = row.get("result", {})
        logs = [directory / name for name in row["files"] if name.endswith(".log")]
        if len(logs) == 1:
            lines = logs[0].read_text(encoding="utf-8", errors="replace").splitlines()
            warnings = sum(line.startswith("Warning:") for line in lines)
            errors = sum(line.startswith("ERROR:") for line in lines)
            counts = {"warning_count": warnings, "warning_lines": warnings,
                      "error_count": errors, "diagnostic_count": warnings + errors,
                      "conflicting_driver_count": sum(line.startswith("Warning:") and
                          "multiple conflicting drivers" in line for line in lines),
                      "logic_loop_count": sum(line.startswith("Warning:") and
                          "found logic loop" in line for line in lines)}
            run_log_counts[rel] = counts
            for field, actual in counts.items():
                if field in result and result[field] != actual:
                    failures.append({"path": str(logs[0]), "field": field,
                                     "recorded": result[field], "actual": actual})

    blif_inventory = []
    affected = set(v2["postabc_il"]["per_module"])
    covered = set()
    for row in v2["abc_blif_outputs"]["module_rows"]:
        path = ROOT / row["workdir"] / "output.blif"
        if path.exists() != row["output_blif_exists"]:
            failures.append({"path": str(path), "error": "BLIF presence changed"})
        if not path.exists():
            continue
        outputs = collections.Counter()
        for line in path.read_text(encoding="utf-8", errors="strict").splitlines():
            tokens = line.split()
            if tokens and tokens[0] == ".names":
                if len(tokens) < 2 or tokens[-1] == "\\":
                    raise ValueError(f"Unsupported BLIF directive: {path}")
                outputs[tokens[-1]] += 1
        duplicates = sum(count > 1 for count in outputs.values())
        if duplicates != row["duplicate_output_name_count"]:
            failures.append({"path": str(path), "error": "BLIF duplicate count changed"})
        if row["module"] in affected:
            covered.add(row["module"])
        blif_inventory.append({"path": str(path), "sha256": sha(path),
                               "module": row["module"], "duplicate_names_outputs": duplicates})

    structure = read_json(EVIDENCE / "structure_audit_v2.json")
    audit = structure["preabc"]["missing_cout_by_module"]
    cout_rows = [row for rows in audit.values() for row in rows]
    for item in cout_rows:
        if item["total_signal_references"] != 1:
            failures.append({"error": "COUT has additional references", "record": item})
    metadata = read_json(ROOT / "out/netlist_n2_preabc_declared_cout_reload_20261014_r1/metadata.json")
    with Path(metadata["source"]).open("rb") as original, Path(metadata["load_input"]).open("rb") as derivative:
        for raw in original:
            if derivative.readline() != raw:
                raise ValueError("COUT derivative differs beyond insertions")
            if raw.startswith(b"module "):
                module = raw.decode("utf-8")[7:].strip()
                for row in audit.get(module, []):
                    if derivative.readline() != ("  wire " + row["net"] + "\n").encode("utf-8"):
                        raise ValueError("COUT derivative insertion mismatch")
        if derivative.read(1):
            raise ValueError("Unexpected derivative trailing bytes")

    for path, expected in ((Path(candidate["synthesis_executable"]), candidate["synthesis_executable_sha256"]),
                           (Path(candidate["abc_executable"]), candidate["abc_executable_sha256"])):
        verify(path, expected)
    if len(frozen_rtl) != 50 or len(workspace_rtl) != 50 or len(cout_rows) != 70 or len(audit) != 18:
        failures.append({"error": "Frozen inventory counts differ"})
    if len(covered) != 27 or len(blif_inventory) != 42:
        failures.append({"error": "BLIF coverage inventory differs"})
    report = {
        "schema": "netlist-n2-closeout-audit-v1", "created_local": dt.datetime.now().astimezone().isoformat(),
        "status": "PASS_EVIDENCE_INTEGRITY" if not failures else "FAIL_EVIDENCE_INTEGRITY",
        "scope": "Saved evidence verification only; no synthesis or simulation executed; netlist acceptance remains FAIL/NOT_ACCEPTED.",
        "runner": str(Path(__file__).resolve()), "runner_sha256": sha(Path(__file__)),
        "candidate_input_files_checked": len(candidate["input_sha256"]),
        "frozen_rtl_files_checked": len(frozen_rtl), "workspace_rtl_files_checked": len(workspace_rtl),
        "run_manifest_count": len(v3["runs"]), "checked_files": checked,
        "log_counts": run_log_counts, "cout_count": len(cout_rows), "cout_module_count": len(audit),
        "preabc_cout_derivative_insertions_only_reverified": True,
        "saved_output_blif_count": len(blif_inventory), "affected_modules_with_saved_blif": len(covered),
        "blif_inventory": blif_inventory, "failures": failures,
        "known_evidence_issues": [
            "Original n2_status.json exit_code is null; no exit code has been reconstructed.",
            "Historical evidence_analysis.json records 76/6325 duplicates; current v2/v3 and bit-level audit record 75/6324. Old parser version cause is unresolved.",
            "Live-check metadata candidate_input_count is an array of 76 ones; candidate manifest has 76 input hashes including 50 RTL files.",
            "One adapter wildcard selection failed before ABC; it is retained as an invalid experiment.",
            "Legacy CEC claims have not been reverified from exact raw artifacts in this closeout.",
        ],
    }
    output = EVIDENCE / "closeout_audit.json"
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({key: report[key] for key in ("status", "candidate_input_files_checked", "frozen_rtl_files_checked", "workspace_rtl_files_checked", "run_manifest_count", "saved_output_blif_count", "affected_modules_with_saved_blif", "failures")}, ensure_ascii=False))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
