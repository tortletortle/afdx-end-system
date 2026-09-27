#!/usr/bin/env python3
"""Negative-control test: isolated Questa RTL mutants must fail T09ps.

Runs in temporary sim/out libraries and NEVER edits rtl/rx/rx_ic.v or sim/work.
Run serially, NOT alongside run_regress.ps1 (its startup kills old vsim tasks).
The mutation report is only a measure of these three injected faults; it does
not replace coverage, top-level RX testing, synthesis, or timing closure.
"""
from __future__ import print_function

import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

SIM = Path(__file__).resolve().parent
ROOT = SIM.parent
RTL = ROOT / "rtl" / "rx" / "rx_ic.v"
TB = SIM / "tb" / "tb_t09p_rx_ic.v"
OUT = SIM / "out"
VSIM_CANDIDATES = (
    Path(r"C:\altera_pro\26.1.1\questa_fse\win64\vsim.exe"),
    Path(r"C:\altera_pro\26.1.1\modelsim_ase\win32aloem\vsim.exe"),
    Path(r"C:\altera_pro\26.1.1\modelsim_ae\win32aloem\vsim.exe"),
)
MUTATIONS = (
    ("no_lost_one",
     "wire [7:0] exp2 = (psn_q >= 8'd254) ? psn_q - 8'd253 : psn_q + 8'd2;",
     "wire [7:0] exp2 = exp1;"),
    ("commit_only_rejects",
     "(state == ST_WRITE) && accept_q;",
     "(state == ST_WRITE) && !accept_q;"),
    ("missing_b_bank",
     "wire [12:0] rd_addr = (in_desc[99] ? NUM_RX_VL : 0) + in_vl;",
     "wire [12:0] rd_addr = in_vl;"),
)


def run():
    vsim = next((p for p in VSIM_CANDIDATES if p.is_file()), None)
    if vsim is None:
        raise RuntimeError("Questa vsim.exe not found; cannot skip mutation gate")
    OUT.mkdir(exist_ok=True)
    source = RTL.read_text(encoding="utf-8")
    initial_hash = hashlib.sha256(RTL.read_bytes()).hexdigest()
    env = os.environ.copy()
    if not env.get("SALT_LICENSE_SERVER"):
        # Mirrors sim/run_regress.ps1's user-scoped license fallback.
        import winreg
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, "Environment") as key:
            env["SALT_LICENSE_SERVER"], _ = winreg.QueryValueEx(key, "SALT_LICENSE_SERVER")
    report = ["T09ps isolated RTL mutants (each must FAIL; original RTL untouched)",
              "original RTL SHA-256: " + initial_hash]
    detected = 0
    for name, needle, replacement in MUTATIONS:
        if source.count(needle) != 1:
            raise RuntimeError("unexpected RTL shape for mutant " + name)
        with tempfile.TemporaryDirectory(prefix="t09_mut_", dir=str(OUT)) as tmp:
            work = Path(tmp)
            mutant = work / "rx_ic.v"
            mutant.write_text(source.replace(needle, replacement, 1), encoding="utf-8")
            library = work / "lib"
            tcl = work / "run.tcl"
            tcl.write_text(
                "onerror { quit -f -code 1 }\n"
                "vlib {%s}\n" % library.as_posix() +
                "vlog -sv +notimingcheck -work {%s} {%s} {%s}\n" %
                (library.as_posix(), mutant.as_posix(), TB.as_posix()) +
                "puts {T09_MUTANT_COMPILED}\n"
                "vsim -lib {%s} tb_t09ps_rx_ic\n" % library.as_posix() +
                "run -all\n"
                "quit -f\n", encoding="utf-8")
            try:
                p = subprocess.run([str(vsim), "-c", "-do", "source {%s}" % tcl.as_posix()],
                                   cwd=str(SIM), env=env, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, timeout=120, check=False)
                output = p.stdout.decode("utf-8", errors="replace")
            except subprocess.TimeoutExpired as exc:
                output = (exc.stdout or b"").decode("utf-8", errors="replace") + "\nMUTANT TIMEOUT\n"
                p = None
        (OUT / ("T09mut_" + name + ".txt")).write_text(output, encoding="utf-8")
        compiled = "T09_MUTANT_COMPILED" in output
        failed = "T09p RX-IC PRESSURE FAIL (N=16 errors=" in output
        passed = "T09p RX-IC PRESSURE PASS" in output
        caught = compiled and failed and not passed and p is not None
        detected += int(caught)
        line = "%s %s (compiled=%s, TB_FAIL=%s, rc=%s)" % (
            name, "DETECTED" if caught else "MISSED", compiled, failed,
            "timeout" if p is None else p.returncode)
        print(line)
        report.append(line)
    assert hashlib.sha256(RTL.read_bytes()).hexdigest() == initial_hash, "production RTL modified!"
    report.append("T09 MUTATION SUMMARY: %d/%d detected" % (detected, len(MUTATIONS)))
    (OUT / "T09_mutants_report.txt").write_text("\n".join(report) + "\n", encoding="utf-8")
    print(report[-1])
    return 0 if detected == len(MUTATIONS) else 1


if __name__ == "__main__":
    try:
        sys.exit(run())
    except Exception as exc:
        print("T09 MUTATION GATE FAIL: %s" % exc)
        sys.exit(1)
