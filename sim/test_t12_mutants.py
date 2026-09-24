#!/usr/bin/env python3
"""Negative control: four isolated lookup faults must be detected by T12s.

Run serially, never beside run_regress.ps1 (which kills existing vsim tasks).
Mutant Verilog/work libraries live in temporary sim/out directories; the
production RTL and the regression work library are never edited.
"""
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile

SIM = Path(__file__).resolve().parent
ROOT = SIM.parent
RTL = ROOT / "rtl" / "rx" / "rx_vl_lookup.v"
TB = SIM / "tb" / "tb_t12_rx_lookup.v"
OUT = SIM / "out"
VSIM_CANDIDATES = (
    Path(r"C:\altera_pro\26.1.1\questa_fse\win64\vsim.exe"),
    Path(r"C:\altera_pro\26.1.1\modelsim_ase\win32aloem\vsim.exe"),
    Path(r"C:\altera_pro\26.1.1\modelsim_ae\win32aloem\vsim.exe"),
)
MUTATIONS = (
    ("wrong_hash_multiplier",
     "x = x * (table_id ? 16'h45D9 : 16'h9E37);",
     "x = x * (table_id ? 16'h45D9 : 16'h9E35);"),
    ("missing_table1_way0",
     "wire m10 = valid_match(q10,vlid_q);",
     "wire m10 = 1'b0;"),
    ("missing_config_way11",
     "wire cfg11 = cfg_write && cfg_table && cfg_way;",
     "wire cfg11 = 1'b0;"),
    ("drops_output_on_backpressure",
     "OUTPUT: if (out_ready) begin",
     "OUTPUT: if (1'b1) begin"),
)


def run():
    vsim = next((p for p in VSIM_CANDIDATES if p.is_file()), None)
    if vsim is None:
        raise RuntimeError("Questa vsim.exe not found; cannot skip negative gate")
    OUT.mkdir(exist_ok=True)
    source = RTL.read_text(encoding="utf-8")
    original = hashlib.sha256(RTL.read_bytes()).hexdigest().upper()
    env = os.environ.copy()
    if not env.get("SALT_LICENSE_SERVER"):
        import winreg
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, "Environment") as key:
            env["SALT_LICENSE_SERVER"], _ = winreg.QueryValueEx(key, "SALT_LICENSE_SERVER")
    report = ["T12s four isolated RTL mutants (must compile then FAIL)",
              "original RTL SHA-256: " + original]
    detected = 0
    for name, needle, replacement in MUTATIONS:
        if source.count(needle) != 1:
            raise RuntimeError("unexpected RTL shape for mutant " + name)
        with tempfile.TemporaryDirectory(prefix="t12_mut_", dir=str(OUT)) as tmp:
            work = Path(tmp)
            mutant = work / "rx_vl_lookup.v"
            mutant.write_text(source.replace(needle, replacement, 1), encoding="utf-8")
            library = work / "lib"
            tcl = work / "run.tcl"
            tcl.write_text(
                "onerror { quit -f -code 1 }\n"
                "vlib {%s}\n" % library.as_posix() +
                "vlog -sv +notimingcheck -work {%s} {%s} {%s}\n" %
                (library.as_posix(), mutant.as_posix(), TB.as_posix()) +
                "puts {T12_MUTANT_COMPILED}\n"
                "vsim -lib {%s} tb_t12s_lookup\n" % library.as_posix() +
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
        (OUT / ("T12mut_" + name + ".txt")).write_text(output, encoding="utf-8")
        compiled = "T12_MUTANT_COMPILED" in output and "Errors: 0" in output
        failed = "T12 LOOKUP FAIL (case=2 errors=" in output
        passed = "T12 LOOKUP PASS" in output
        caught = compiled and failed and not passed and p is not None
        detected += int(caught)
        line = "%s %s (compiled=%s, TB_FAIL=%s, rc=%s)" % (
            name, "DETECTED" if caught else "MISSED", compiled, failed,
            "timeout" if p is None else p.returncode)
        print(line, flush=True)
        report.append(line)
    assert hashlib.sha256(RTL.read_bytes()).hexdigest().upper() == original, "production RTL changed!"
    report.append("T12 MUTATION SUMMARY: %d/%d detected" % (detected, len(MUTATIONS)))
    (OUT / "T12_mutants_report.txt").write_text("\n".join(report) + "\n", encoding="utf-8")
    print(report[-1])
    return 0 if detected == len(MUTATIONS) else 1


if __name__ == "__main__":
    try:
        sys.exit(run())
    except Exception as exc:
        print("T12 MUTATION GATE FAIL: %s" % exc)
        sys.exit(1)
