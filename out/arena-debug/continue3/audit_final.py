"""Audit the retained STA-script improvement, not overall FPGA closure."""
from pathlib import Path
import hashlib
import json
import re

root = Path("C:/Workspace/diansai")
out = root / "out/arena-debug/continue3"
raw = out / "raw"
attempt = json.loads((out / "RESULTS-timing-attempt.json").read_text(encoding="utf-8"))

def text(path):
    return path.read_text(encoding="utf-8", errors="replace")

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

rtl_paths = ["rtl/common/rst_sync.v", "rtl/top/AFDX_top.v"]
script = root / "elinx/prj/quartus/sta_post_map.tcl"
helper = root / "elinx/prj/quartus/check_sdc_8ns.tcl"
script_backup = out / "backup/elinx/prj/quartus/sta_post_map.tcl"
script_body = text(script)
good = text(raw / "guarded/post_map_sdc.rpt")
bad = text(root / "out/arena-debug/continue2/sta/default_1ns_no_sdc/post_map_sdc.rpt")
patch_body = text(out / "fixes.patch")
patch_log = text(raw / "final_patch_verify.log")
rollback_log = text(raw / "live_rollback.log")

checks = {
    "timing_attempt_13_checks_recorded": len(attempt["checks"]) == 13 and all(attempt["checks"].values()),
    "timing_attempt_worse_and_125_mhz_unmet": attempt["change"]["fmax_delta_mhz"] < 0 and
        attempt["change"]["wns_delta_ns"] < 0 and not attempt["change"]["meets_125_mhz"],
    "rtl_restored_to_prechange_backups": all((root / p).read_bytes() == (out / "backup" / p).read_bytes()
        for p in rtl_paths) and rollback_log.count("ROLLED_BACK_BYTE_IDENTICAL ") == 2,
    "sta_script_backup_matches_before_change": digest(script_backup) ==
        "a630b96074817e607b14fda0c678eea397d58c82b9567a83ec8f627903124a00",
    "tested_sta_guard_script_unchanged": digest(script) ==
        "76ef6b49b817701e832b6d436e3fc15a17f6d6b50a7faa270c8b8227b7a89460" and
        digest(helper) == "3ae3ec3173caaddc196b6b08d63de2611aae7211d78adb6cf46076ce4d23b2f9",
    "report_sdc_and_guard_before_setup_fmax": script_body.index("report_sdc -file") <
        script_body.index("check_sdc_8ns $out/post_map_sdc.rpt") <
        script_body.index("report_timing -setup") < script_body.index("report_clock_fmax_summary"),
    "official_script_positive_timequest_rc0": text(raw / "sta_guard.rc").strip() == "0" and
        "SDC_GUARD_OK: clk=8.000 ns" in text(raw / "sta_guard.stdout.log") and
        "POST_MAP_STA_DONE" in text(raw / "sta_guard.stdout.log"),
    "positive_report_contains_8ns_clk": bool(re.search(
        r"; create_clock\s*; clk\s*; 8\.000\s*;", good)),
    "negative_fixture_contains_default_1ns_clk": bool(re.search(
        r"; create_clock\s*; clk\s*; 1\.000\s*;", bad)),
    "production_helper_rejects_1ns_in_selftest": text(raw / "guard_selftest.rc").strip() == "0" and
        "SDC_GUARD_SELFTEST_PASS good_8ns=accepted bad_1ns=rejected" in text(raw / "guard_selftest.stdout.log"),
    "final_patch_only_sta_sources": "diff --git a/elinx/prj/quartus/sta_post_map.tcl" in patch_body and
        "diff --git a/elinx/prj/quartus/check_sdc_8ns.tcl" in patch_body and
        "diff --git a/rtl/" not in patch_body,
    "patch_forward_reverse_byte_identical": patch_log.count("FORWARD_BYTE_IDENTICAL ") == 2 and
        "REVERSE_BYTE_IDENTICAL sta_post_map.tcl" in patch_log,
    "map_reports_retained_after_db_cleanup": (raw / "AFDX_top.map.rpt").is_file() and
        (raw / "AFDX_top.map.summary").is_file() and not (out / "project/db").exists(),
}

result = {
    "final_change": "STA evidence gap: fail closed unless actual report_sdc clk period is 8.000 ns",
    "source_files_changed_after_rollback": ["elinx/prj/quartus/sta_post_map.tcl",
                                            "elinx/prj/quartus/check_sdc_8ns.tcl"],
    "candidate_timing_experiment": {
        "baseline_post_map": attempt["baseline"], "rejected_candidate_post_map": attempt["continue3"],
        "delta": attempt["change"], "rolled_back_byte_identical": checks["rtl_restored_to_prechange_backups"],
        "tests_and_netlist_belong_to": "rejected RTL candidate, not final live RTL",
    },
    "official_guard_verification": {
        "timequest_positive_rc": 0 if checks["official_script_positive_timequest_rc0"] else None,
        "negative_fixture_rc": 0 if checks["production_helper_rejects_1ns_in_selftest"] else None,
        "report_period_ns": 8 if checks["positive_report_contains_8ns_clk"] else None,
        "netlist": "rejected-candidate post-map snapshot; reused before RTL rollback",
    },
    "artifact_integrity_checks": checks,
    "artifact_integrity_checks_all_passed": all(checks.values()),
    "limits": "125 MHz not achieved. Post-map is not post-fit; IO delays are incomplete. "
              "No whole-system 50-test regression or post-rollback resynthesis/STA was run.",
}
(out / "RESULTS.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(json.dumps({"artifact_integrity_checks": checks, "all_passed": all(checks.values())},
                 ensure_ascii=False))
if not all(checks.values()):
    raise SystemExit("Final artifact audit failed; see RESULTS.json")
