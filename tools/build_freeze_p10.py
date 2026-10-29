#!/usr/bin/env python3
"""Build FREEZE.json + metrics.json (+ diff vs the previous freeze) for the p10 final freeze.

Re-measured from this run's consoles: regress counts, T13/T13w/T05b/T42/T89/T90/T09/T10/T16a/T88 keys,
gate T88b result, optional ModelSim SE comparison, and (through add_app_metrics.py) T92-T95 and the
afdx_app_top synthesis keys.  Everything else (coverage, mutants, BMC, lint, Fmax/Setup, core cells)
is carried from the base metrics and tagged `carried_from`, so it is never presented as re-measured.

Exit 0: written and every overlapping core key equals the base value.  Exit 1: written, but at least
one overlapping key differs (report, do not paper over).  Exit 2: missing input.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import re
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TZ = timezone(timedelta(hours=8))


def sha256(p: Path) -> str:
    h = hashlib.sha256()
    with p.open("rb") as f:
        for c in iter(lambda: f.read(1 << 20), b""):
            h.update(c)
    return h.hexdigest()


def rel(p: Path) -> str:
    try:
        return p.resolve().relative_to(ROOT.resolve()).as_posix()
    except ValueError:
        return p.resolve().as_posix()


def read_lines(p: Path) -> list[str]:
    return p.read_text(encoding="utf-8", errors="replace").splitlines()


def find_line(p: Path, pattern: str) -> tuple[int, str]:
    rx = re.compile(pattern)
    for i, ln in enumerate(read_lines(p), 1):
        if rx.search(ln):
            return i, ln
    raise KeyError(f"{p.name}: no match for {pattern}")


def metric(key, value, unit, grade, src: Path, line: int, note: str = "") -> dict:
    m = {
        "key": key,
        "value": value,
        "unit": unit,
        "grade": grade,
        "source_file": rel(src),
        "source_line": line,
        "file_sha256": sha256(src),
    }
    if note:
        m["note"] = note
    return m


def num(s: str):
    return int(s) if re.fullmatch(r"-?\d+", s) else float(s)


def remeasure(q: Path) -> dict[str, dict]:
    """Same extraction rules as the p9 rebuild script, from this run's consoles."""
    cat: dict[str, dict] = {}

    def put(key, value, unit, src, ln, note=""):
        cat[key] = metric(key, value, unit, "P", src, ln, note)

    t42 = q / "T42_console.txt"
    ln, L = find_line(t42, r"T42_METRIC")
    m = re.search(
        r"tx_a_payload_mbps=([\d.]+).*tx_b_payload_mbps=([\d.]+).*rx_verified_payload_mbps=([\d.]+)"
        r".*tx_commit_to_gmii_eof_max_us=([\d.]+).*rx_gmii_sof_to_verified_host_max_us=([\d.]+)",
        L,
    )
    assert m, "T42_METRIC"
    for i, (k, u) in enumerate(
        (("t42_tx_a_mbps", "Mbps"), ("t42_tx_b_mbps", "Mbps"), ("t42_rx_verified_mbps", "Mbps"),
         ("t42_tx_commit_to_eof_max_us", "us"), ("t42_rx_sof_to_host_max_us", "us")), 1):
        put(k, num(m.group(i)), u, t42, ln)
    ln, L = find_line(t42, r"T42_JITTER")
    put("t42_jitter_max_us", num(re.search(r"max_us=([\d.]+)", L).group(1)), "us", t42, ln)

    t13 = q / "T13_console.txt"
    ln, L = find_line(t13, r"worst_total=")
    put("t13_worst_total_ns", int(re.search(r"worst_total=(\d+)ns", L).group(1)), "ns", t13, ln)
    ln, L = find_line(t13, r"T13METRIC if_mode=0 case=3")
    put("t13_case3_total_ns", int(re.search(r"total_ns=(\d+)", L).group(1)), "ns", t13, ln)
    t13w = q / "T13w_console.txt"
    ln, L = find_line(t13w, r"T13w WORST-CASE LATENCY PASS")
    m = re.search(r"worst_total=(\d+)ns worst_queue=(\d+)ns", L)
    put("t13w_worst_total_ns", int(m.group(1)), "ns", t13w, ln)
    put("t13w_worst_queue_ns", int(m.group(2)), "ns", t13w, ln)
    t05b = q / "T05b_console.txt"
    ln, L = find_line(t05b, r"T05b SATURATED JITTER PASS")
    m = re.search(r"startup_jitter=(\d+)us steady_max_jitter=(\d+)us", L)
    put("t05b_startup_jitter_us", int(m.group(1)), "us", t05b, ln)
    put("t05b_steady_max_jitter_us", int(m.group(2)), "us", t05b, ln)

    t89 = q / "T89_console.txt"
    ln, L = find_line(t89, r"T89_ES_LATENCY")
    m = re.search(r"max_tx_commit2sfd_ns=(\d+).*max_rx_sfd2host_ns=(\d+).*es_total_max_ns=(\d+)", L)
    put("t89_tx_commit2sfd_max_ns", int(m.group(1)), "ns", t89, ln)
    put("t89_rx_sfd2host_max_ns", int(m.group(2)), "ns", t89, ln)
    put("t89_es_total_max_ns", int(m.group(3)), "ns", t89, ln)
    ln, L = find_line(t89, r"T89_JITTER")
    m = re.search(r"max_ns=(\d+).*bound_40sig_us=(\d+).*frames_per_vl=(\d+)", L)
    put("t89_jitter_ns", int(m.group(1)), "ns", t89, ln, "alias t89_max_jit_ns")
    put("t89_max_jit_ns", int(m.group(1)), "ns", t89, ln)
    put("t89_bound_40sig_us", int(m.group(2)), "us", t89, ln)
    put("t89_frames_per_vl", int(m.group(3)), "count", t89, ln)
    ln, L = find_line(t89, r"T89 GMII METRICS PASS")
    m = re.search(r"max_tx_ns=(\d+).*max_rx_ns=(\d+)", L)
    put("t89_max_tx_ns", int(m.group(1)), "ns", t89, ln)
    put("t89_max_rx_ns", int(m.group(2)), "ns", t89, ln)

    t90 = q / "T90_console.txt"
    ln, L = find_line(t90, r"T90_METRIC")
    m = re.search(r"tx_a=([\d.]+).*tx_b=([\d.]+).*rx_dedup=([\d.]+)", L)
    put("t90_tx_a_mbps", num(m.group(1)), "Mbps", t90, ln)
    put("t90_tx_b_mbps", num(m.group(2)), "Mbps", t90, ln)
    put("t90_rx_dedup_mbps", num(m.group(3)), "Mbps", t90, ln)
    ln, L = find_line(t90, r"T90_ES_LATENCY")
    put("t90_es_total_max_ns", int(re.search(r"es_total_max_ns=(\d+)", L).group(1)), "ns", t90, ln)
    ln, L = find_line(t90, r"T90_JITTER")
    m = re.search(r"ns=(\d+).*bound_40sig_us=(\d+)", L)
    put("t90_jitter_ns", int(m.group(1)), "ns", t90, ln)
    put("t90_bound_us", int(m.group(2)), "us", t90, ln)
    ln, L = find_line(t90, r"T90_UNCONF")
    put("t90_unconf_drop", int(re.search(r"delta=(\d+)", L).group(1)), "count", t90, ln)
    ln, L = find_line(t90, r"T90_HOST_ACK_WAIT_MAX")
    put("t90_host_ack_wait_max", int(re.search(r"cycles=(\d+)", L).group(1)), "cycles", t90, ln)
    ln, _ = find_line(t90, r"T90 VL128 THROUGHPUT PASS")
    put("t90_pass", True, "bool", t90, ln)

    t09 = q / "T09_console.txt"
    ln, L = find_line(t09, r"T09 RX-IC PASS")
    m = re.search(r"accept=(\d+) reject=(\d+)", L)
    put("t09_accept", int(m.group(1)), "count", t09, ln)
    put("t09_reject", int(m.group(2)), "count", t09, ln)
    t10 = q / "T10_console.txt"
    ln, L = find_line(t10, r"T10 TOP RM PASS")
    m = re.search(r"fwd=(\d+) dup=(\d+) skew=(\d+)", L)
    put("t10_fwd", int(m.group(1)), "count", t10, ln)
    put("t10_dup", int(m.group(2)), "count", t10, ln)
    put("t10_skew", int(m.group(3)), "count", t10, ln)

    t16a = q / "T16a_console.txt"
    errs = []
    for i, ln_ in enumerate(read_lines(t16a), 1):
        mm = re.search(r"FLL_METRIC case=.*steady_pps_max_abs_err_us=(\d+)", ln_)
        if mm:
            errs.append((i, int(mm.group(1))))
    assert errs, "FLL_METRIC"
    mx = max(e for _, e in errs)
    put("t16a_fll_max_abs_err_us", mx, "us", t16a, max(i for i, e in errs if e == mx), "max over FLL_METRIC cases A-E")
    ln, _ = find_line(t16a, r"T16a FLL STRICT PASS")
    put("t16a_pass", True, "bool", t16a, ln)

    t88 = q / "T88_console.txt"
    ln, L = find_line(t88, r"T88 DEMO PASS")
    put("t88_steps_ok", int(re.search(r"steps_ok=(\d+)", L).group(1)), "count", t88, ln)
    put("t88_pass", True, "bool", t88, ln)
    return cat


def regress_rows(d: Path) -> list[dict]:
    return list(csv.DictReader((d / "regress.csv").open(encoding="utf-8-sig")))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--commit", required=True, help="full 40-char commit of the frozen worktree")
    ap.add_argument("--freeze-dir", type=Path, required=True)
    ap.add_argument("--questa-dir", type=Path, required=True, help="Questa full regress OutDir (regress.csv + consoles)")
    ap.add_argument("--questa-json", type=Path, default=None, help="freeze_regress.py evidence json")
    ap.add_argument("--gate-dir", type=Path, required=True, help="T88b gate dir with simulation_status.json")
    ap.add_argument("--synth-dir", type=Path, required=True, help="out/app_top_synth_* with run_status.json")
    ap.add_argument("--base-metrics", type=Path, required=True, help="previous freeze metrics.json (carried + diff)")
    ap.add_argument("--se-dir", type=Path, default=None, help="optional ModelSim SE full regress OutDir")
    ap.add_argument("--core-rtl-diff", type=Path, default=None, help="text file proving core rtl identical to the base commit")
    args = ap.parse_args()

    commit7 = args.commit[:7]
    fd = args.freeze_dir
    fd.mkdir(parents=True, exist_ok=True)
    for need in (args.questa_dir / "regress.csv", args.gate_dir / "simulation_status.json",
                 args.synth_dir / "run_status.json", args.base_metrics):
        if not need.is_file():
            print(f"FAIL: missing {need}", file=sys.stderr)
            return 2

    base = json.loads(args.base_metrics.read_text(encoding="utf-8-sig"))
    base_cat = base["metrics"]
    rows = regress_rows(args.questa_dir)
    n, npass = len(rows), sum(1 for r in rows if r.get("result") == "PASS")
    q_csv = args.questa_dir / "regress.csv"

    cat: dict[str, dict] = {}
    cat.update(remeasure(args.questa_dir))
    cat["full_n"] = metric("full_n", n, "count", "P", q_csv, 1, "p10 questa full")
    cat["full_pass"] = metric("full_pass", npass, "count", "P", q_csv, 1, "p10 questa full")
    cat["full_all_pass"] = metric("full_all_pass", npass == n and n > 0, "bool", "P", q_csv, 1, "p10 questa full")
    wall = round(sum(float(r.get("wall_s") or 0) for r in rows), 1)
    cat["questa_wall_s"] = metric("questa_wall_s", wall, "s", "I", q_csv, 1, "sum of per-test wall_s in regress.csv")

    gs = args.gate_dir / "simulation_status.json"
    g = json.loads(gs.read_text(encoding="utf-8-sig"))
    for s in ("1", "2", "3"):
        cat[f"gate_t88b_s{s}"] = metric(f"gate_t88b_s{s}", g[f"gate_s{s}"], "result", "P", gs, 1)
    cat["gate_vo_sha256"] = metric("gate_vo_sha256", g["vo_sha256"], "sha256", "P", gs, 1)
    if args.core_rtl_diff and args.core_rtl_diff.is_file():
        cat["rtl_empty_vs_c"] = metric("rtl_empty_vs_c", True, "bool", "P", args.core_rtl_diff, 1,
                                       "core rtl identical to the VO source commit 098efc9")

    se_info = None
    if args.se_dir and (args.se_dir / "regress.csv").is_file():
        se_rows = regress_rows(args.se_dir)
        se_csv = args.se_dir / "regress.csv"
        se_pass = {r["test_id"] for r in se_rows if r.get("result") == "PASS"}
        q_pass = {r["test_id"] for r in rows if r.get("result") == "PASS"}
        both = sorted(se_pass & q_pass)
        cat["se_full_pass"] = metric("se_full_pass", len(se_pass), "count", "P", se_csv, 1, "p10 ModelSim SE full")
        cat["dual_sim_match"] = metric("dual_sim_match", len(both), "count", "P", se_csv, 1,
                                       f"tests PASS on both simulators; SE ran {len(se_rows)} of {n}")
        cat["se_wall_s"] = metric("se_wall_s", round(sum(float(r.get("wall_s") or 0) for r in se_rows), 1), "s", "I",
                                  se_csv, 1, "sum of per-test wall_s")
        se_info = {"outdir": rel(args.se_dir), "n_total": len(se_rows), "n_pass": len(se_pass), "dual_match": len(both)}

    # carry the rest from the base, tagged
    carried = []
    for k, v in base_cat.items():
        if k in cat:
            continue
        v = dict(v)
        v["carried_from"] = rel(args.base_metrics)
        v["note"] = ((v.get("note") + "; ") if v.get("note") else "") + "carried, not re-measured in p10"
        cat[k] = v
        carried.append(k)
    # SE keys are carried (p9 matrix) when the SE comparison was not run
    cat["freeze_commit"] = metric("freeze_commit", args.commit, "git", "P", fd / "FREEZE.json", 1) if (fd / "FREEZE.json").is_file() else {
        "key": "freeze_commit", "value": args.commit, "unit": "git", "grade": "P", "source_file": rel(fd / "FREEZE.json"),
        "source_line": 1, "file_sha256": ""}

    # diff vs base for overlapping core keys (expected identical: core rtl unchanged, same tests)
    compare = [k for k in cat if k in base_cat and k not in carried and k not in (
        "full_n", "full_pass", "full_all_pass", "questa_wall_s", "se_wall_s", "freeze_commit", "se_full_pass", "dual_sim_match")]
    diff_rows, mism = [], []
    for k in sorted(compare):
        a, b = base_cat[k]["value"], cat[k]["value"]
        ok = a == b
        if isinstance(a, float) or isinstance(b, float):
            try:
                ok = abs(float(a) - float(b)) < 1e-9
            except (TypeError, ValueError):
                ok = False
        diff_rows.append((k, a, b, "YES" if ok else "NO"))
        if not ok:
            mism.append(k)
    with (fd / "metrics_diff_vs_p9.csv").open("w", encoding="utf-8", newline="") as f:
        f.write("key,p9_value,p10_value,match\n")
        for r in diff_rows:
            f.write(",".join(str(x) for x in r) + "\n")
    md = ["# metrics p10 vs p9 (core rtl identical to 098efc9: expect match)", "", "| key | p9 | p10 | match |", "|---|---|---|---|"]
    md += [f"| `{k}` | {a} | {b} | {m} |" for k, a, b, m in diff_rows]
    md += ["", ("**MISMATCH keys:** " + ", ".join(mism)) if mism else "All overlapping re-measured keys match.", "",
           f"Carried (not re-measured): {len(carried)} keys: " + ", ".join(sorted(carried))]
    (fd / "metrics_diff_vs_p9.md").write_text("\n".join(md) + "\n", encoding="utf-8")

    # FREEZE.json
    synth = json.loads((args.synth_dir / "run_status.json").read_text(encoding="utf-8-sig"))
    freeze = {
        "schema": "p10-freeze-v1",
        "commit": args.commit,
        "commit7": commit7,
        "created_local": datetime.now(TZ).strftime("%Y-%m-%dT%H:%M:%S%z"),
        "N": n,
        "pass": npass,
        "gate_vo_sha256": g["vo_sha256"],
        "core_cells_carried": base_cat.get("cells", {}).get("value"),
        "core_altsyncram_carried": base_cat.get("altsyncram", {}).get("value"),
        "app_synth": {"dir": rel(args.synth_dir), "overall": synth.get("overall"), "cells": synth.get("cells"),
                      "altsyncram": synth.get("altsyncram"), "note": "RTL of afdx_app_* unchanged since this synthesis"},
        "steps": {
            "questa_full": {"outdir": rel(args.questa_dir), "n_total": n, "n_pass": npass, "wall_s_sum": wall},
            "freeze_regress_questa": {"require_full": True, "json": rel(args.questa_json) if args.questa_json else None},
            "gate_t88b": {"outdir": rel(args.gate_dir), "vo_sha256": g["vo_sha256"], "S1": g["gate_s1"], "S2": g["gate_s2"],
                          "S3": g["gate_s3"], "core_rtl_diff": rel(args.core_rtl_diff) if args.core_rtl_diff else None},
            "modelsim_se_full": se_info or {"status": "not run"},
        },
        "carried_keys": sorted(carried),
        "carried_from": rel(args.base_metrics),
        "not_run": ["coverage", "mutants", "BMC", "lint", "Fit/STA"] + ([] if se_info else ["ModelSim SE full"]),
    }
    (fd / "FREEZE.json").write_text(json.dumps(freeze, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    cat["freeze_commit"] = metric("freeze_commit", args.commit, "git", "P", fd / "FREEZE.json", 1)

    interim = fd / "metrics.interim.json"
    interim.write_text(json.dumps({"freeze": rel(fd / "FREEZE.json"), "commit": args.commit,
                                   "updated_local": datetime.now(TZ).strftime("%Y-%m-%dT%H:%M:%S%z"),
                                   "metrics": cat}, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    r = subprocess.run(
        [sys.executable, str(ROOT / "tools" / "add_app_metrics.py"), "--base", str(interim), "--out", str(fd / "metrics.json"),
         "--t92", str(args.questa_dir), "--t93", str(args.questa_dir), "--t94", str(args.questa_dir),
         "--t95", str(args.questa_dir), "--synth", str(args.synth_dir)],
        capture_output=True, text=True)
    print(r.stdout.strip())
    if r.returncode != 0:
        print(r.stderr, file=sys.stderr)
        return 2
    interim.unlink()
    print(f"WROTE {fd/'FREEZE.json'} and {fd/'metrics.json'}; re-measured={len(cat) - len(carried)} carried={len(carried)} mismatches={mism}")
    return 1 if mism else 0


if __name__ == "__main__":
    sys.exit(main())
