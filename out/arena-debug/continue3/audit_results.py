"""Audit the measured, subsequently rejected RTL timing attempt."""
from pathlib import Path
import json
import re

ROOT = Path("C:/Workspace/diansai")
OUT = ROOT / "out/arena-debug/continue3"
RAW = OUT / "raw"
BASE = ROOT / "out/arena-debug/continue2/sta"
STAGES = ["lint_top", "lint_reset", "compile", "reset_tb", "t01", "t11", "t11g", "synth", "map", "sta"]


def text(path):
    return path.read_text(encoding="utf-8", errors="replace") if path.is_file() else ""


def value(pattern, data, cast=str):
    match = re.search(pattern, data, re.MULTILINE)
    return cast(match.group(1).strip()) if match else None


def timing(directory):
    fmax = text(directory / "post_map_fmax.rpt")
    summary = text(directory / "post_map_setup_summary.rpt")
    sdc = text(directory / "post_map_sdc.rpt")
    paths = text(directory / "post_map_setup.rpt")
    # The overview table contains column headers "From Node" / "To Node".
    # Parse only the first detailed path, not those header names.
    worst_path = paths.split("Path #1:", 1)[1] if "Path #1:" in paths else ""
    return {
        "device": "EP4SGX230HF35C2", "stage": "post-map; not post-fit/sign-off",
        "sdc_period_ns": value(r"; create_clock\s*; clk\s*;\s*([\d.]+)\s*;", sdc, float),
        "fmax_mhz": value(r";\s*([\d.]+) MHz\s*;\s*[\d.]+ MHz\s*; clk", fmax, float),
        "setup_wns_ns": value(r"; clk\s*;\s*(-?[\d.]+)\s*;\s*-?[\d.]+\s*;", summary, float),
        "setup_endpoint_tns_ns": value(r"; clk\s*;\s*-?[\d.]+\s*;\s*(-?[\d.]+)\s*;", summary, float),
        "worst_from": value(r"; From Node\s*;\s*([^;]+?)\s*;", worst_path),
        "worst_to": value(r"; To Node\s*;\s*([^;]+?)\s*;", worst_path),
        "worst_data_delay_ns": value(r"; Data Delay\s*;\s*([\d.]+)\s*;", worst_path, float),
        "paths_reported": value(r"Report Timing: Found (\d+) setup paths", paths, int),
    }


rc = {stage: value(r"^(-?\d+)\s*$", text(RAW / f"{stage}.rc"), int) for stage in STAGES}
checks = {}
checks["lint_top"] = rc["lint_top"] == 0 and "%Error" not in text(RAW / "lint_top.stderr.log")
checks["lint_reset_tb"] = rc["lint_reset"] == 0 and "%Error" not in text(RAW / "lint_reset.stderr.log")
compile_log = text(RAW / "compile.stdout.log")
checks["compile"] = rc["compile"] == 0 and "# Errors: 0, Warnings: 0" in compile_log
tb_patterns = {
    "reset_tb": r"# PASS reset copy identity cycles=\d+",
    "t01": r"# T01 INIT/REG PASS ",
    "t11": r"# T11 TOP PORT PASS \(IF_MODE=0 ",
    "t11g": r"# T11 TOP PORT PASS \(IF_MODE=1 ",
}
for stage, pattern in tb_patterns.items():
    log = text(RAW / f"{stage}.stdout.log")
    checks[stage] = rc[stage] == 0 and re.search(pattern, log) is not None and not re.search(r"\[err\]|\bFAIL\b", log)
synth = text(RAW / "synth.elinx.log")
checks["synth"] = rc["synth"] == 0 and "Yosys execute success!" in synth and not re.search(r"^(ERROR|Warning)", synth, re.MULTILINE)
checks["quartus_map"] = rc["map"] == 0 and (RAW / "map.stdout.log").is_file()
sta_console = text(RAW / "sta.stdout.log")
checks["sta_process"] = (rc["sta"] == 0 and "SDC_GUARD_OK: clk=8.000 ns" in sta_console
                         and "CONTINUE3_POST_MAP_STA_DONE" in sta_console)
baseline = timing(BASE)
current = timing(RAW)
checks["baseline_sdc_8ns"] = baseline["sdc_period_ns"] == 8.0
checks["current_sdc_8ns"] = current["sdc_period_ns"] == 8.0
checks["timing_numbers_present"] = all(current[k] is not None for k in ("fmax_mhz", "setup_wns_ns", "setup_endpoint_tns_ns", "worst_from", "worst_to"))
change = {}
if checks["sta_process"] and checks["current_sdc_8ns"] and checks["timing_numbers_present"] and baseline["fmax_mhz"] is not None:
    change = {
        "fmax_delta_mhz": round(current["fmax_mhz"] - baseline["fmax_mhz"], 2),
        "wns_delta_ns": round(current["setup_wns_ns"] - baseline["setup_wns_ns"], 3),
        "meets_125_mhz": current["setup_wns_ns"] >= 0,
    }
results = {"baseline": baseline, "continue3": current, "change": change,
           "process_rc": rc, "checks": checks,
           "lint_top_warnings": len(re.findall(r"%Warning-", text(RAW / "lint_top.stderr.log"))),
           "lint_reset_warnings": len(re.findall(r"%Warning-", text(RAW / "lint_reset.stderr.log")))}
(OUT / "RESULTS-timing-attempt.json").write_text(json.dumps(results, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print("Audited checks:", json.dumps(checks, ensure_ascii=False))
print("Measured timing:", json.dumps({"baseline": baseline, "continue3": current, "change": change}, ensure_ascii=False))
