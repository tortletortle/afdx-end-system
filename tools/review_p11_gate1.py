"""Read-only, scope-limited review of the single P11 synthesis probe."""

import hashlib
import json
import argparse
from datetime import datetime
from pathlib import Path
import sys


ROOT = Path(__file__).resolve().parents[1]
PROBE = ROOT / "out/p11_rbuf_one_shot_20261013_r1"
TOP = ROOT / "out/production_repairs_native_hierarchy_default_20261013_r1"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main(out_relative):
    out = (ROOT / out_relative).resolve()
    if not out.is_relative_to(ROOT / "out"):
        raise ValueError("Review output must be inside workspace out/")
    if out.exists():
        raise RuntimeError(f"Refusing to overwrite review: {out}")
    result = json.loads((PROBE / "RESULT.json").read_text(encoding="utf-8"))
    top_status = json.loads((TOP / "synthesis_status.json").read_text(encoding="utf-8"))
    probe_log = (PROBE / "probe.log").read_text(encoding="utf-8", errors="replace")
    top_log = (TOP / "synthesis.log").read_text(encoding="utf-8", errors="replace")
    probe_script = (PROBE / "probe.ys").read_text(encoding="ascii")
    top_script = (TOP / "AFDX_top_native.ys").read_text(encoding="utf-8")

    checks = {}
    for relative, expected in result["source_sha256"].items():
        checks[f"source:{relative}"] = digest(ROOT / relative) == expected
    checks["source_matches_top_snapshot"] = all(
        digest(ROOT / relative) == digest(TOP / "input" / relative)
        for relative in result["source_sha256"]
    )
    for field, path in {
        "tool_sha256": Path(result["command"][0]),
        "script_sha256": PROBE / "probe.ys",
        "runner_sha256": PROBE / "run.py",
        "log_sha256": PROBE / "probe.log",
        "stdout_sha256": PROBE / "stdout.txt",
        "stderr_sha256": PROBE / "stderr.txt",
    }.items():
        checks[field] = digest(path) == result[field]
    command = result["command"]
    checks["probe_command_bound"] = (
        len(command) == 7
        and command[1:4] == ["-Q", "-T", "-s"]
        and Path(command[4]).resolve() == (PROBE / "probe.ys").resolve()
        and command[5] == "-l"
        and Path(command[6]).resolve() == (PROBE / "probe.log").resolve()
    )
    checks["probe_success_recorded_and_logged"] = (
        result["exit_code"] == 0
        and result["timed_out"] is False
        and "Yosys execute success!" in probe_log
        and "ERROR:" not in probe_log
        and digest(PROBE / "stdout.txt") == digest(PROBE / "probe.log")
    )
    checks["probe_exact_parameter_binding"] = (
        "hierarchy -check -top a615a_tftp -chparam LOAD_WORDS 8192 "
        "-chparam RETRY_MAX 3 -chparam TIMEOUT_US 5000 "
        "-chparam BIND_PEER_IP 1 -chparam CONTROL_FILENAME_LEN 10"
        in probe_script
    )
    checks["probe_is_pre_abc_only"] = (
        "synth_stratix -top a615a_tftp -family eHiChip6 -noflatten -run begin:map_luts"
        in probe_script
        and not any(line.lstrip().startswith("abc ") for line in probe_script.splitlines())
    )
    checks["top_reaches_abc"] = (
        "abc -exe " in top_script and "Executing ABC pass" in top_log
    )
    checks["top_failed"] = (
        top_status["status"] == "FAIL"
        and top_status["exit_code"] == 1
        and "ERROR: bad allocation" in top_log
    )

    probe_diagnostics = {
        "unrecognized_bram": probe_log.count("Cell type not recognized: bram_1w1r"),
        "rbw_no_driver": sum("\\rbw" in line and "no driver" in line for line in probe_log.splitlines()),
        "conflicting_drivers": probe_log.count("multiple conflicting drivers"),
        "logic_loops": probe_log.count("found logic loop"),
        "bad_allocation": probe_log.count("ERROR: bad allocation"),
    }
    top_diagnostics = {
        "conflicting_drivers": top_log.count("multiple conflicting drivers"),
        "logic_loops": top_log.count("found logic loop"),
        "bad_allocation": top_log.count("ERROR: bad allocation"),
    }
    checks["probe_diagnostics_match_runner"] = (
        probe_diagnostics["unrecognized_bram"] == result["unrecognized_bram_warnings"]
        and probe_diagnostics["rbw_no_driver"] == result["rbw_no_driver_warnings"]
        and probe_diagnostics["conflicting_drivers"] == result["conflicting_driver_warnings"]
        and probe_diagnostics["logic_loops"] == result["logic_loop_warnings"]
        and probe_diagnostics["bad_allocation"] == result["bad_allocation_errors"]
    )

    passed = all(checks.values())
    review = {
        "status": "PASS_SCOPED_EVIDENCE_REVIEW" if passed else "FAIL_EVIDENCE_REVIEW",
        "observed_local": datetime.now().astimezone().isoformat(),
        "probe_result_sha256": digest(PROBE / "RESULT.json"),
        "top_status_sha256": digest(TOP / "synthesis_status.json"),
        "top_log_sha256": digest(TOP / "synthesis.log"),
        "checks": checks,
        "probe_diagnostics": probe_diagnostics,
        "top_diagnostics": top_diagnostics,
        "probe_scope": "standalone a615a_tftp through pre-ABC map_luts and check",
        "top_scope": "AFDX_top through ABC, failed before netlist completion",
        "decision": "STOP_NO_EXPLAINED_RTL_REPAIR_CANDIDATE" if passed else "STOP_REVIEW_FAILED",
        "synthesis": "FAIL" if passed else "UNKNOWN",
        "final_acceptance": "NOT_READY",
    }
    out.mkdir(parents=True)
    (out / "REVIEW.json").write_text(json.dumps(review, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(review, ensure_ascii=False, indent=2))
    return 0 if passed else 1


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", required=True, help="New review directory inside workspace out/")
    args = parser.parse_args()
    sys.exit(main(args.out))
