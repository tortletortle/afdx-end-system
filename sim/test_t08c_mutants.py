#!/usr/bin/env python3
"""Isolated negative controls for the host/RX PMEM arbitration contract.

Run serially, never alongside run_regress.ps1 (it kills active vsim tasks).
Each mutant is compiled in its own temporary work library.  No production
RTL, normal work library, test vectors, or regression CSV are modified.
A compile error / timeout / passing test counts as MISSED, not detected.
"""
import hashlib
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

SIM = Path(__file__).resolve().parent
ROOT = SIM.parent
RTL = ROOT / "rtl" / "top" / "AFDX_top.v"
TB = SIM / "tb" / "tb_t08c_host_arb.v"
OUT = SIM / "out"
VSIM_CANDIDATES = (
    Path(r"C:\altera_pro\26.1.1\questa_fse\win64\vsim.exe"),
    Path(r"C:\altera_pro\26.1.1\modelsim_ase\win32aloem\vsim.exe"),
    Path(r"C:\altera_pro\26.1.1\modelsim_ae\win32aloem\vsim.exe"),
)
# Single, precisely matched top RTL faults: early ACK, lost data, wrong address.
# A compile failure or timeout is not a detected functional fault.
# Split note (2026-10-22): former combined "acks_before_write_port_available"
# dropped both !rx_pmem_busy and !copy_wr_turn. Split retest: dropping only
# !copy_wr_turn is MISSED under T08c (equivalent — TB never contends copy_wr_turn
# against host PMEM commit). Keep the rx_pmem_busy-only fault (DETECTED).
MUTATIONS = (
    ("acks_ignores_rx_pmem_busy",
     "assign host_commit_pending = host_pmem_pending && !rx_pmem_busy && !copy_wr_turn;",
     "assign host_commit_pending = host_pmem_pending && !copy_wr_turn;"),
    ("pending_write_data_not_latched",
     "host_pmem_pending_data <= host_wdata;",
     "host_pmem_pending_data <= 32'd0;"),
    ("pending_write_addr_not_latched",
     "host_pmem_pending_addr <= host_pmem_addr;",
     "host_pmem_pending_addr <= 13'd0;"),
)


def run():
    vsim = next((p for p in VSIM_CANDIDATES if p.is_file()), None)
    if vsim is None:
        raise RuntimeError("Questa vsim.exe not found; cannot skip negative gate")
    OUT.mkdir(exist_ok=True)
    source = RTL.read_text(encoding="utf-8")
    original = hashlib.sha256(RTL.read_bytes()).hexdigest().upper()
    from mutant_compile_list import regress_compile_files
    rtl_files = regress_compile_files(SIM)
    env = os.environ.copy()
    if not env.get("SALT_LICENSE_SERVER"):
        import winreg
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, "Environment") as key:
            env["SALT_LICENSE_SERVER"], _ = winreg.QueryValueEx(key, "SALT_LICENSE_SERVER")
    report = ["T08c isolated top RTL faults: compile, then FAIL (a pass is MISSED)",
              "original top RTL SHA-256: " + original]
    detected = 0
    for name, needle, replacement in MUTATIONS:
        if source.count(needle) != 1:
            raise RuntimeError("unexpected RTL shape for mutant " + name)
        with tempfile.TemporaryDirectory(prefix="t08c_mut_", dir=str(OUT)) as tmp:
            work = Path(tmp)
            mutant = work / "AFDX_top.v"
            mutant.write_text(source.replace(needle, replacement, 1), encoding="utf-8")
            library = work / "lib"
            tcl = work / "run.tcl"
            sources = [mutant if p == RTL.resolve() else p for p in rtl_files]
            sources.append(TB)
            tcl.write_text(
                "onerror { quit -f -code 1 }\n"
                "vlib {%s}\n" % library.as_posix() +
                "vlog -sv +notimingcheck -work {%s} %s\n" %
                (library.as_posix(), " ".join("{%s}" % p.as_posix() for p in sources)) +
                "puts {T08C_MUTANT_COMPILED}\n"
                "vsim -lib {%s} tb_t08c_host_arb\n" % library.as_posix() +
                "run -all\n"
                "quit -f\n", encoding="utf-8")
            try:
                proc = subprocess.run([str(vsim), "-c", "-do", "source {%s}" % tcl.as_posix()],
                                      cwd=str(SIM), env=env, stdout=subprocess.PIPE,
                                      stderr=subprocess.STDOUT, timeout=120, check=False)
                output = proc.stdout.decode("utf-8", errors="replace")
            except subprocess.TimeoutExpired as exc:
                output = (exc.stdout or b"").decode("utf-8", errors="replace") + "\nMUTANT TIMEOUT\n"
                proc = None
        (OUT / ("T08cmut_" + name + ".txt")).write_text(output, encoding="utf-8")
        compiled = "T08C_MUTANT_COMPILED" in output and "Errors: 0" in output
        failed = re.search(r"T08c HOST-ARBITRATION FAIL \(IF_MODE=0 errors=([1-9][0-9]*)\)", output)
        passed = "T08c HOST-ARBITRATION PASS" in output
        caught = compiled and bool(failed) and not passed and proc is not None
        detected += int(caught)
        line = "%s %s (compiled=%s, TB_FAIL=%s, rc=%s)" % (
            name, "DETECTED" if caught else "MISSED", compiled, bool(failed),
            "timeout" if proc is None else proc.returncode)
        print(line, flush=True)
        report.append(line)
    assert hashlib.sha256(RTL.read_bytes()).hexdigest().upper() == original, "production RTL changed!"
    report.append("T08c MUTATION SUMMARY: %d/%d detected" % (detected, len(MUTATIONS)))
    (OUT / "T08c_mutants_report.txt").write_text("\n".join(report) + "\n", encoding="utf-8")
    print(report[-1], flush=True)
    return 0 if detected == len(MUTATIONS) else 1


if __name__ == "__main__":
    try:
        sys.exit(run())
    except Exception as exc:
        print("T08c MUTATION GATE FAIL: %s" % exc, flush=True)
        sys.exit(1)
