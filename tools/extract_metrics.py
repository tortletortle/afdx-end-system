#!/usr/bin/env python3
"""Extract metrics.json from FREEZE.json (+ pointed consoles) or a dry-run regress dir.

Dry-run (--dry-run DIR): parse a completed regress OutDir (e.g. post_fix4).
Output must NOT be treated as P8 evidence when --dry-run is used.

Normal mode: read FREEZE.json, follow its step dirs, emit metrics with sha256.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import re
import sys
from pathlib import Path
from typing import Any


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def metric(
    key: str,
    value: Any,
    unit: str,
    src: Path | None,
    line: int | None = None,
    note: str = "",
    grade: str = "P",
) -> dict:
    m: dict[str, Any] = {
        "key": key,
        "value": value,
        "unit": unit,
        "grade": grade,
        "source_file": str(src).replace("\\", "/") if src else "",
        "source_line": line,
        "file_sha256": sha256_file(src) if src and src.is_file() else "",
    }
    if note:
        m["note"] = note
    return m


def find_line(text: str, pattern: str) -> tuple[int | None, re.Match[str] | None]:
    rx = re.compile(pattern)
    for i, line in enumerate(text.splitlines(), 1):
        m = rx.search(line)
        if m:
            return i, m
    return None, None


def load_console(outdir: Path, test_id: str) -> tuple[Path | None, str]:
    p = outdir / f"{test_id}_console.txt"
    if not p.is_file():
        return None, ""
    return p, p.read_text(encoding="utf-8", errors="replace")


def from_regress_dir(outdir: Path, label: str) -> list[dict]:
    """Parse one regress OutDir into metric rows (dry-run or P8 full)."""
    rows: list[dict] = []
    csv_path = outdir / "regress.csv"
    if not csv_path.is_file():
        raise FileNotFoundError(f"missing {csv_path}")
    tests = list(csv.DictReader(csv_path.open(encoding="utf-8")))
    n = len(tests)
    n_pass = sum(1 for t in tests if t.get("result") == "PASS")
    rows.append(metric("full_n", n, "count", csv_path, 1, note=label))
    rows.append(metric("full_pass", n_pass, "count", csv_path, 1, note=label))
    rows.append(
        metric(
            "full_all_pass",
            n_pass == n and n > 0,
            "bool",
            csv_path,
            1,
            note=label,
        )
    )

    # T13 worst total ns
    p, txt = load_console(outdir, "T13")
    ln, m = find_line(txt, r"worst_total=(\d+)ns")
    if m:
        rows.append(metric("t13_worst_total_ns", int(m.group(1)), "ns", p, ln))
    ln, m = find_line(txt, r"Total=(\d+)ns")
    # also case-3 total from T13METRIC
    ln, m = find_line(txt, r"T13METRIC.*case=3.*total_ns=(\d+)")
    if m:
        rows.append(metric("t13_case3_total_ns", int(m.group(1)), "ns", p, ln))

    p, txt = load_console(outdir, "T13w")
    ln, m = find_line(txt, r"worst_total=(\d+)ns")
    if m:
        rows.append(metric("t13w_worst_total_ns", int(m.group(1)), "ns", p, ln))

    p, txt = load_console(outdir, "T05b")
    ln, m = find_line(txt, r"startup_jitter=(\d+)us\s+steady_max_jitter=(\d+)us")
    if m:
        rows.append(metric("t05b_startup_jitter_us", int(m.group(1)), "us", p, ln))
        rows.append(metric("t05b_steady_max_jitter_us", int(m.group(2)), "us", p, ln))

    p, txt = load_console(outdir, "T42")
    ln, m = find_line(txt, r"tx_commit_to_gmii_eof_max_us=([0-9.]+)")
    if m:
        rows.append(metric("t42_tx_commit_to_eof_max_us", float(m.group(1)), "us", p, ln))
    ln, m = find_line(txt, r"rx_gmii_sof_to_verified_host_max_us=([0-9.]+)")
    if m:
        rows.append(metric("t42_rx_sof_to_host_max_us", float(m.group(1)), "us", p, ln))
    ln, m = find_line(txt, r"T42_JITTER.*max_us=([0-9.]+)")
    if m:
        rows.append(metric("t42_jitter_max_us", float(m.group(1)), "us", p, ln))

    p, txt = load_console(outdir, "T89")
    ln, m = find_line(txt, r"max_tx_ns=(\d+)\s+max_rx_ns=(\d+)\s+max_jit_ns=(\d+)")
    if m:
        rows.append(metric("t89_max_tx_ns", int(m.group(1)), "ns", p, ln))
        rows.append(metric("t89_max_rx_ns", int(m.group(2)), "ns", p, ln))
        rows.append(metric("t89_max_jit_ns", int(m.group(3)), "ns", p, ln))
    else:
        # older us-only PASS line
        ln, m = find_line(txt, r"max_tx_us=(\d+).*max_rx_us=(\d+).*max_jit_us=(\d+)")
        if m:
            rows.append(
                metric(
                    "t89_max_tx_ns",
                    int(m.group(1)) * 1000,
                    "ns",
                    p,
                    ln,
                    note="derived from us display",
                )
            )
    ln, m = find_line(txt, r"bound_40sig_us=(\d+)")
    if m:
        rows.append(metric("t89_bound_40sig_us", int(m.group(1)), "us", p, ln))
    js = outdir / "t89_verilog_summary.json"
    if js.is_file():
        summary = json.loads(js.read_text(encoding="utf-8").strip().splitlines()[0])
        for k in ("max_tx_ns", "max_rx_ns", "max_jit_ns", "frames_per_vl"):
            if k in summary:
                rows.append(
                    metric(
                        f"t89_{k}",
                        summary[k],
                        "ns" if k.endswith("_ns") else "count",
                        js,
                        1,
                    )
                )

    p, txt = load_console(outdir, "T09")
    ln, m = find_line(txt, r"accept=(\d+)\s+reject=(\d+)")
    if m:
        rows.append(metric("t09_accept", int(m.group(1)), "count", p, ln))
        rows.append(metric("t09_reject", int(m.group(2)), "count", p, ln))

    p, txt = load_console(outdir, "T10")
    ln, m = find_line(txt, r"fwd=(\d+)\s+dup=(\d+)\s+skew=(\d+)")
    if m:
        rows.append(metric("t10_fwd", int(m.group(1)), "count", p, ln))
        rows.append(metric("t10_dup", int(m.group(2)), "count", p, ln))
        rows.append(metric("t10_skew", int(m.group(3)), "count", p, ln))

    p, txt = load_console(outdir, "T16a")
    ln, m = find_line(txt, r"T16a FLL STRICT PASS")
    if m:
        rows.append(metric("t16a_pass", True, "bool", p, ln))

    p, txt = load_console(outdir, "T27")
    ln, m = find_line(txt, r"T27.*PASS")
    if m:
        rows.append(metric("t27_pass", True, "bool", p, ln))

    for tid in ("T34p", "T35p"):
        p, txt = load_console(outdir, tid)
        ln, m = find_line(txt, rf"{tid}.*PASS|{tid[0:3]}.*PASS")
        if m or (txt and "PASS" in txt and "FAIL" not in txt.split("PASS")[0][-20:]):
            # softer: any PASS verdict line
            ln2, m2 = find_line(txt, r"\bPASS\b")
            if m2:
                rows.append(metric(f"{tid.lower()}_pass", True, "bool", p, ln2))

    return rows


def from_freeze(freeze_path: Path) -> dict:
    freeze = json.loads(freeze_path.read_text(encoding="utf-8-sig"))
    metrics: list[dict] = []
    metrics.append(
        metric(
            "freeze_commit",
            freeze.get("commit", ""),
            "git",
            freeze_path,
            1,
        )
    )
    full_dir = freeze.get("steps", {}).get("full_regress", {}).get("outdir")
    if full_dir:
        metrics.extend(from_regress_dir(Path(full_dir), "p8_full"))
    # optional fields from FREEZE itself
    for key, unit, grade in (
        ("cells", "count", "P"),
        ("altsyncram", "count", "P"),
        ("fmax_mhz", "MHz", "I"),
        ("setup_ns", "ns", "I"),
        ("gate_vo_sha256", "sha256", "P"),
        ("mutants_detected", "count", "P"),
        ("mutants_total", "count", "P"),
        ("lint_error", "count", "P"),
    ):
        if key in freeze:
            metrics.append(
                metric(key, freeze[key], unit, freeze_path, 1, grade=grade)
            )
    gate = freeze.get("steps", {}).get("gate_t88b", {})
    for s in ("S1", "S2", "S3"):
        if s in gate:
            metrics.append(
                metric(f"gate_t88b_{s.lower()}", gate[s], "result", freeze_path, 1)
            )
    return {
        "freeze": str(freeze_path).replace("\\", "/"),
        "commit": freeze.get("commit", ""),
        "metrics": {m["key"]: m for m in metrics},
        "metric_list": metrics,
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--freeze",
        type=Path,
        default=None,
        help="path to FREEZE.json (normal mode)",
    )
    ap.add_argument(
        "--dry-run",
        type=Path,
        default=None,
        help="regress OutDir for dry-run (NOT P8 evidence)",
    )
    ap.add_argument(
        "-o",
        "--output",
        type=Path,
        required=True,
        help="output metrics.json path",
    )
    args = ap.parse_args()
    if args.dry_run:
        data = {
            "mode": "dry_run",
            "note": "NOT P8 evidence; dry-run only",
            "source_outdir": str(args.dry_run).replace("\\", "/"),
            "metrics": {},
            "metric_list": [],
        }
        lst = from_regress_dir(args.dry_run, "dry_run")
        data["metric_list"] = lst
        data["metrics"] = {m["key"]: m for m in lst}
    elif args.freeze:
        if not args.freeze.is_file():
            print(f"FAIL: missing FREEZE.json {args.freeze}", file=sys.stderr)
            return 2
        data = from_freeze(args.freeze)
        data["mode"] = "freeze"
    else:
        print("need --freeze or --dry-run", file=sys.stderr)
        return 2

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    print(f"Wrote {args.output} metrics={len(data['metric_list'])} mode={data.get('mode')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
