#!/usr/bin/env python3
"""Read-only audit of the current AFDX closeout claims and their frozen evidence.

This checks provenance and scope. It never starts HDL tools and cannot establish
protocol conformance, successful synthesis, or final contest acceptance.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
from pathlib import Path
import sys


ROOT = Path(__file__).resolve().parents[1]
STATE = ROOT / "out/project_closeout_control_20261013_r2/CURRENT_STATE.json"
PIPELINE = ROOT / "out/production_repairs_validation_pipeline_20261013_r1/pipeline_status.json"
FREEZE = PIPELINE.parent / "full_evidence.json"
FRONTEND = ROOT / "out/production_repairs_frontend_20261013_r1/frontend_metadata.json"
GENERATED = ROOT / "out/generated_runtime_inputs_current140_20261013_r1/GENERATED_INPUT_REVIEW.json"
SYNTH_STATUS = ROOT / "out/production_repairs_native_hierarchy_default_20261013_r1/synthesis_status.json"
MAPPED_STATUS = ROOT / "out/production_repairs_hierarchical_mapped_20261013_r1/pipeline_status.json"
P11_REVIEW = ROOT / "out/p11_gate1_review_20261013_r2/REVIEW.json"
EXPECTED_AUDITS = {
    "full_tx_audit", "full_init_audit", "full_coexist_audit",
    "full_file_hold_audit", "full_scale_audit", "full_public_audit",
}
RUNTIME_FILES = {
    "sim/tests.manifest", "sim/compile.tcl", "sim/run_regress.ps1", "sim/run_one.tcl",
}


def sha(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def load(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8-sig"))


def below(base: Path, relative: str) -> Path:
    path = (base / relative).resolve()
    if not path.is_relative_to(base.resolve()):
        raise ValueError(f"path escapes evidence directory: {relative}")
    return path


def manifest_rows(path: Path) -> list[dict[str, str]]:
    rows = []
    for raw in path.read_text(encoding="utf-8-sig").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        fields = line.split()
        rows.append({"id": fields[0], "tb": fields[1],
                     "config": fields[2] if len(fields) > 2 else "default"})
    return rows


def audit() -> dict:
    errors: list[str] = []
    counts: dict[str, int] = {}

    def check(condition: bool, description: str) -> None:
        if not condition:
            errors.append(description)

    state = load(STATE)
    check(state.get("states", {}).get("final_acceptance") == "NOT_READY",
          "state must not claim final acceptance")
    check(state.get("states", {}).get("P11_synthesis") == "BLOCKED_BY_SYNTHESIS_FAILURE",
          "P11 synthesis must remain blocked")
    run = below(ROOT, state["evidence"]["full140_metadata"]).parent
    meta = load(run / "run_metadata.json")
    freeze = load(FREEZE)
    pipeline = load(PIPELINE)
    with (run / "regress.csv").open(encoding="utf-8-sig", newline="") as handle:
        csv_rows = list(csv.DictReader(handle))
    recorded = [{"id": row["id"], "tb": row["tb"], "config": row["config"]}
                for row in meta["tests"]]
    actual = [{"id": row["test_id"], "tb": row["tb"], "config": row["config"]}
              for row in csv_rows]
    snapshot_manifest = manifest_rows(run / "workspace/sim/tests.manifest")
    check(recorded == actual == snapshot_manifest, "CSV, metadata and frozen manifest differ")
    check(len(actual) == len(set(row["id"] for row in actual)) == 140,
          "full regression does not have 140 unique tests")
    check(meta.get("compile_result") == "PASS" and meta.get("compile_rc") == 0
          and meta.get("vlog_errors") == 0, "Questa compilation is not clean")
    check(meta.get("regression_result") == "PASS" and meta.get("return_code") == 0
          and meta.get("pass_count") == meta.get("test_count") == 140
          and meta.get("tests_completed") == 140, "full regression metadata is not 140/140 PASS")
    check(len(meta.get("test_results", [])) == 140 and
          all(row.get("result") == "PASS" and row.get("simulator_exit_code") == 0
              for row in meta["test_results"]), "one or more per-test results failed")
    check(all(row.get("result") == "PASS" for row in csv_rows), "CSV has a non-PASS row")
    check(freeze.get("run_id") == meta.get("run_id") and
          freeze.get("scope") == "complete manifest" and
          freeze.get("test_count") == freeze.get("passing") == 140 and
          freeze.get("ordered_test_ids") == [row["id"] for row in actual],
          "frozen evidence does not correspond to the full run")
    counts["tests"] = len(actual)

    source_map = meta["source_sha256"]
    for relative, expected in freeze["source_sha256"].items():
        path = below(run / "workspace", relative)
        check(path.is_file() and sha(path) == expected == source_map.get(relative),
              f"frozen input missing or changed: {relative}")
    counts["frozen_inputs"] = len(freeze["source_sha256"])
    for relative, expected in freeze["evidence_sha256"].items():
        path = below(run, relative)
        check(path.is_file() and sha(path) == expected,
              f"raw run evidence missing or changed: {relative}")
    counts["raw_evidence_files"] = len(freeze["evidence_sha256"])

    generated = load(GENERATED)
    generated_files = generated.get("generated_sha256", {})
    check(generated.get("status") == "PASS" and len(generated_files) == 6,
          "six generated runtime inputs have not been reconstructed")
    for relative, expected in generated_files.items():
        rebuilt = below(GENERATED.parent / "workspace", relative)
        check(rebuilt.is_file() and sha(rebuilt) == expected == source_map.get(relative),
              f"generated input does not match frozen run: {relative}")
    check(all(step.get("exit_code") == 0 for step in generated.get("steps", [])),
          "a vector generator failed")
    counts["regenerated_inputs"] = len(generated_files)

    runtime = [relative for relative in source_map
               if (relative.startswith("rtl/") and Path(relative).suffix.lower() in {".v", ".sv", ".vh"})
               or relative.startswith(("sim/tb/", "sim/vec/", "sw/golden/"))
               or relative in RUNTIME_FILES]
    for relative in runtime:
        if relative in generated_files:
            continue
        path = below(ROOT, relative)
        check(path.is_file() and sha(path) == source_map[relative],
              f"current runtime input differs from frozen run: {relative}")
    counts["current_runtime_inputs_checked"] = len(runtime) - len(generated_files)
    post_freeze_documents = [relative for relative in source_map
                             if relative.startswith("rtl/") and Path(relative).suffix.lower() == ".md"
                             and below(ROOT, relative).is_file()
                             and sha(below(ROOT, relative)) != source_map[relative]]
    counts["post_freeze_document_changes"] = len(post_freeze_documents)

    stages = {step["name"]: step for step in pipeline["stages"]}
    check(EXPECTED_AUDITS <= stages.keys(), "one or more independent audits are absent")
    check(pipeline.get("status") == "RTL_AND_FRONTEND_PASS_SYNTHESIS_PENDING",
          "RTL pipeline status is not the expected scoped pass")
    for name, step in stages.items():
        log = PIPELINE.parent / f"{name}.log"
        check(step.get("status") == "PASS" and step.get("exit_code") == 0 and
              log.is_file() and sha(log) == step.get("log_sha256"),
              f"pipeline stage failed or log changed: {name}")
    counts["pipeline_stages"] = len(stages)
    frontend = load(FRONTEND)
    check(frontend.get("verdict") == "PASS" and len(frontend.get("stages", [])) == 5,
          "frontend five-stage verdict is not PASS")
    directed_run = Path(pipeline["directed"]).resolve()
    check(frontend.get("regression_metadata_sha256") == sha(directed_run / "run_metadata.json"),
          "frontend refers to different directed regression metadata")
    check(len(frontend.get("rtl_sha256", {})) == 50,
          "frontend did not bind 50 production RTL sources")
    for relative, expected in frontend.get("rtl_sha256", {}).items():
        check(expected == source_map.get(relative),
              f"frontend RTL hash differs from full regression: {relative}")
    for step in frontend.get("stages", []):
        log = FRONTEND.parent / f"{step['label']}.log"
        check(step.get("verdict") == "PASS" and step.get("exit_code") == 0
              and not step.get("timed_out") and log.is_file()
              and sha(log) == step.get("log_sha256"),
              f"frontend stage failed or log changed: {step['label']}")
    counts["frontend_stages"] = len(frontend.get("stages", []))

    synthesis = load(SYNTH_STATUS)
    synthesis_log = SYNTH_STATUS.parent / "synthesis.log"
    mapped = load(MAPPED_STATUS)
    check(below(ROOT, state["evidence"]["synthesis_status"]) == SYNTH_STATUS,
          "current state refers to a different synthesis status")
    check(synthesis.get("status") == "FAIL" and synthesis.get("exit_code") == 1
          and synthesis_log.is_file() and sha(synthesis_log) == synthesis.get("log_sha256"),
          "current full synthesis failure evidence is missing or changed")
    check(mapped.get("status") == "FAIL_STOP_NO_RETRY" and
          mapped.get("current_stage") == "full_synthesis_default",
          "mapped pipeline does not stop at full synthesis failure")

    p11 = load(P11_REVIEW)
    check(p11.get("status") == "PASS_SCOPED_EVIDENCE_REVIEW" and
          p11.get("decision") == "STOP_NO_EXPLAINED_RTL_REPAIR_CANDIDATE" and
          p11.get("synthesis") == "FAIL" and
          p11.get("probe_result_sha256") == sha(ROOT / state["evidence"]["p11_probe_result"]) and
          p11.get("top_status_sha256") == sha(SYNTH_STATUS) and
          state["states"].get("P11_gate2_candidate_validation") == "NOT_STARTED_NO_CANDIDATE" and
          state["states"].get("P11_gate3_new_synthesis") == "NOT_STARTED_NO_CANDIDATE",
          "P11 stopped diagnosis is missing or overstated")

    return {"status": "PASS_SCOPED_EVIDENCE_AUDIT" if not errors else "FAIL",
            "run_id": meta.get("run_id"), "counts": counts,
            "post_freeze_document_changes": post_freeze_documents,
            "synthesis": "FAIL", "final_acceptance": "NOT_READY",
            "generated_input_review": str(GENERATED.relative_to(ROOT)).replace("\\", "/"),
            "errors": errors}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, help="new JSON report path; existing files are never overwritten")
    args = parser.parse_args()
    try:
        report = audit()
    except (OSError, KeyError, ValueError, TypeError, json.JSONDecodeError) as exc:
        report = {"status": "FAIL", "errors": [str(exc)]}
    serialized = json.dumps(report, ensure_ascii=False, indent=2) + "\n"
    if args.out:
        target = args.out.resolve()
        if target.exists() or not target.is_relative_to((ROOT / "out").resolve()):
            raise SystemExit("--out must be a new path inside the project out directory")
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(serialized, encoding="utf-8")
    print(serialized, end="")
    return 0 if report["status"] == "PASS_SCOPED_EVIDENCE_AUDIT" else 1


if __name__ == "__main__":
    sys.exit(main())
