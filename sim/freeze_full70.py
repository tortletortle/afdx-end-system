#!/usr/bin/env python3
"""Bind sim/out/full 70/70 logs to current RTL/TB/manifest bytes.

This is a directory-level source+log index for the 2026-10-03 local full
run. It is not the 2026-09-29 128-input freeze, not STA, not gate-level.
"""
from __future__ import annotations

import csv
import hashlib
import json
import re
from pathlib import Path

SIM = Path(__file__).resolve().parent
ROOT = SIM.parent
RUN = SIM / "out" / "full"


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest().upper()


def rel(path: Path) -> str:
    return path.resolve().relative_to(ROOT.resolve()).as_posix()


def main() -> None:
    csv_path = RUN / "regress.csv"
    manifest = [
        line.split()
        for line in (SIM / "tests.manifest").read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]
    with csv_path.open(encoding="utf-8-sig", newline="") as f:
        rows = list(csv.DictReader(f))
    expected = [(t[0], t[2] if len(t) > 2 else "default", t[1]) for t in manifest]
    actual = [(t["test_id"], t["config"], t["tb"]) for t in rows]
    if actual != expected or not rows or any(t["result"] != "PASS" for t in rows):
        raise SystemExit("CSV is not an all-PASS exact ordered match of current manifest")

    runner = (SIM / "run_regress.ps1").read_text(encoding="utf-8")
    rtl = re.findall(r"'(\.\./rtl/[^']+\.v)'", runner)
    alias = dict(re.findall(r"'(tb_[^']+)'\s*=\s*'(tb_[^']+)'", runner))

    inputs = {SIM / name for name in rtl}
    extra = ROOT / "rtl" / "top" / "host_if.v"
    if extra.is_file():
        inputs.add(extra)
    inputs.update(SIM / "tb" / (alias.get(t[1], t[1]) + ".v") for t in manifest)
    for name in (
        "sim/tests.manifest",
        "sim/run_regress.ps1",
        "sim/compile.tcl",
        "sim/run_one.tcl",
        "sim/regress_verdict.ps1",
        "sim/freeze_full70.py",
        "AFDX端系统_总体设计书.md",
        "doc/regs.yaml",
    ):
        inputs.add(ROOT / name)
    inputs.update((SIM / "vec").glob("*.hex"))

    missing_in = sorted(str(p) for p in inputs if not p.is_file())
    if missing_in:
        raise SystemExit("missing inputs: " + ", ".join(missing_in))

    outputs = {csv_path, RUN / "compile_console.txt"}
    outputs.update(RUN / (row["test_id"] + "_console.txt") for row in rows)
    missing_out = sorted(str(p) for p in outputs if not p.is_file())
    if missing_out:
        raise SystemExit("missing logs: " + ", ".join(missing_out))

    data = {
        "scope": "Questa RTL full run in sim/out/full; source+log SHA-256 bind only",
        "not_a_claim": [
            "not 2026-09-29 128-input freeze",
            "not gate-level / SDF / post-fit STA / 125 MHz",
            "not peer-closed SNMP/TFTP",
            "not freeze_regress.py mutant/lint bundle",
        ],
        "tests": len(rows),
        "passing": len(rows),
        "ordered_test_ids": [r["test_id"] for r in rows],
        "csv_sha256": sha(csv_path),
        "source_sha256": {rel(p): sha(p) for p in sorted(inputs, key=lambda x: rel(x))},
        "evidence_sha256": {rel(p): sha(p) for p in sorted(outputs, key=lambda x: rel(x))},
    }
    out_path = RUN / "regress_evidence.json"
    out_path.write_text(json.dumps(data, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(
        "FULL70 BIND %d/%d PASS inputs=%d logs=%d csv=%s -> %s"
        % (len(rows), len(manifest), len(inputs), len(outputs), sha(csv_path), out_path)
    )


if __name__ == "__main__":
    main()
