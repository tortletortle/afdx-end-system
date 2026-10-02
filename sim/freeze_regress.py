#!/usr/bin/env python3
"""Bind a passing regression CSV to its *uncommitted* source and log bytes.

This is an evidence index, not a signed artifact, simulator-version lock, STA
report, or proof that tests cover unimplemented end-to-end functionality.
Run only after the final full regression; never freeze a stitched subset.
"""
import argparse
import csv
import hashlib
import json
from pathlib import Path
import re

SIM = Path(__file__).resolve().parent
ROOT = SIM.parent


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest().upper()


def relative(path):
    return path.resolve().relative_to(ROOT.resolve()).as_posix()


def freeze(csv_path, out_path):
    manifest = [line.split() for line in (SIM / "tests.manifest").read_text(encoding="utf-8").splitlines()
                if line.strip() and not line.lstrip().startswith("#")]
    with csv_path.open(encoding="utf-8-sig", newline="") as f:
        rows = list(csv.DictReader(f))
    expected = [(t[0], t[2] if len(t) > 2 else "default", t[1]) for t in manifest]
    actual = [(t["test_id"], t["config"], t["tb"]) for t in rows]
    if actual != expected or not rows or any(t["result"] != "PASS" for t in rows):
        raise RuntimeError("CSV is not an all-PASS exact ordered match of current manifest")

    runner = (SIM / "run_regress.ps1").read_text(encoding="utf-8")
    # Discover the *actual* RTL list and multi-top TB aliases used by the runner.
    rtl = re.findall(r"'(\.\./rtl/[^']+\.v)'", runner)
    if len(rtl) < 15:
        raise RuntimeError("runner RTL file-list parse incomplete")
    alias = dict(re.findall(r"'(tb_[^']+)'\s*=\s*'(tb_[^']+)'", runner))
    inputs = {SIM / name for name in rtl}
    inputs.update(SIM / "tb" / (alias.get(t[1], t[1]) + ".v") for t in manifest)
    inputs.update(ROOT / name for name in (
        "README.md", "AFDX端系统_总体设计书.md", "sim/tests.manifest", "sim/run_regress.ps1",
        "sim/freeze_regress.py",
        "sim/compile.tcl", "sim/run_one.tcl",
        "sim/regress_verdict.ps1", "sim/test_regress_verdict.ps1",
        "sim/test_t09_mutants.py", "sim/test_t12_mutants.py",
        "sim/test_t12_top_mutants.py", "sim/test_t08c_mutants.py", "tools_lint.ps1",
        "sim/test_t08e_mutants.py", "sim/test_t10_mutants.py", "sim/test_t11_mutants.py",
        "doc/regs.yaml", "doc/regs_pkg.svh", "tools/gen_regs.py",
        "doc/当前进度_20260923.md", "doc/README.md", "doc/后续计划.md",
        "tools/selfcheck_claims.py",
        "sw/golden/hash_seed.py", "sw/golden/gen_t12_vectors.py",
        "sw/golden/afdx_model.py",
        "sw/golden/gen_t09_vectors.py", "sw/golden/gen_t08a_vectors.py",
        "sw/golden/gen_t03_vectors.py", "elinx/prj/rx_ic_probe.ys",
        "elinx/prj/rx_ic_smoke.ys", "elinx/prj/rx_lookup_probe.ys",
        "elinx/prj/rx_lookup_smoke.ys"))
    inputs.update((SIM / "vec").glob("*.hex"))
    inputs.update((SIM / "vec").glob("t12_*.manifest.json"))
    outputs = {csv_path,
               SIM / "out" / "compile_console.txt",
               SIM / "out" / "T09_mutants_report.txt",
               SIM / "out" / "tools_lint_24_20260923.log",
               ROOT / "elinx" / "prj" / "rx_ic_probe.log",
               ROOT / "elinx" / "prj" / "rx_ic_smoke.log"}
    outputs.update((SIM / "out" / "T12_mutants_report.txt",
                    SIM / "out" / "T12_top_mutants_report.txt",
                     SIM / "out" / "T08c_mutants_report.txt",
                    SIM / "out" / "T08e_mutants_report.txt",
                    SIM / "out" / "T10_mutants_report.txt",
                    SIM / "out" / "T11_mutants_report.txt",
                    ROOT / "elinx" / "prj" / "rx_lookup_probe.log",
                    ROOT / "elinx" / "prj" / "rx_lookup_smoke.log"))
    outputs.update(SIM / "out" / (row["test_id"] + "_console.txt") for row in rows)
    outputs.update((SIM / "out").glob("T09mut_*.txt"))
    outputs.update((SIM / "out").glob("T12mut_*.txt"))
    outputs.update((SIM / "out").glob("T12topmut_*.txt"))
    outputs.update((SIM / "out").glob("T08cmut_*.txt"))
    outputs.update((SIM / "out").glob("T08emut_*.txt"))
    outputs.update((SIM / "out").glob("T10mut_*.txt"))
    outputs.update((SIM / "out").glob("T11mut_*.txt"))
    missing = [str(p) for p in inputs | outputs if not p.is_file()]
    if missing:
        raise RuntimeError("cannot bind missing inputs/logs: " + ", ".join(sorted(missing)))
    data = {
        "scope": "exact manifest-matching Questa regression; unit/local slices, NOT full system acceptance",
        "tests": len(rows), "passing": len(rows),
        "ordered_test_ids": [r["test_id"] for r in rows],
        "source_sha256": {relative(p): sha(p) for p in sorted(inputs, key=str)},
        "evidence_sha256": {relative(p): sha(p) for p in sorted(outputs, key=str)},
        "known_missing": ["top RX FLT/IC/RM/port delivery after lookup",
                          "hardware full-image SHA/manifest verification (host responsibility)",
                          "end-to-end T08/T22",
                          "sustained host/RX arbitration latency bound and mixed host reads",
                          "T05b full-load jitter", "top-level resources and 125 MHz STA"],
    }
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(data, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
                        encoding="utf-8")
    print("REGRESS EVIDENCE: %d/%d PASS, %d input and %d evidence hashes, CSV SHA-256=%s -> %s" %
          (len(rows), len(manifest), len(inputs), len(outputs), sha(csv_path), out_path))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--csv", type=Path, default=SIM / "out" / "regress.csv")
    parser.add_argument("--out", type=Path, default=SIM / "out" / "regress_evidence.json")
    args = parser.parse_args()
    freeze(args.csv.resolve(), args.out.resolve())
