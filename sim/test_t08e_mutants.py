#!/usr/bin/env python3
"""Isolated negative controls for the top-level RX IC integration (T08e).

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
TOP = ROOT / "rtl" / "top" / "AFDX_top.v"
IC = ROOT / "rtl" / "rx" / "rx_ic.v"
TB = SIM / "tb" / "tb_t08e_top_ic.v"
TB_TOP = "tb_t08eg_top_ic"   # IF_MODE=1: same checks, shortest wall time
OUT = SIM / "out"
VSIM_CANDIDATES = (
    Path(r"C:\altera_pro\26.1.1\questa_fse\win64\vsim.exe"),
    Path(r"C:\altera_pro\26.1.1\modelsim_ase\win32aloem\vsim.exe"),
    Path(r"C:\altera_pro\26.1.1\modelsim_ae\win32aloem\vsim.exe"),
)
# Single, precisely matched RTL faults (file, name, needle, replacement):
# reject writes PSN, A/B PSN aliasing, IC_EN ignored, IC drop missing from
# DROP_CNT, lost-one disabled.
# v0.5.16: the two former free-port collision mutants (FLT reject / drain vs RM
# output) were removed.  Since RM forward frames no longer release through
# free_pipe, the collision is reachable only on an RM *duplicate* output
# cycle; T08e runs with RM inactive (no duplicates), and neither T08e nor T10
# drive a FLT reject into that exact cycle (both mutants MISSED locally).  The
# per-cycle exclusivity monitor in T08e/T10/T11 remains, but that
# dup-vs-FLT/drain collision has no stimulus coverage (residual gap).
# A compile failure or timeout is not a detected functional fault.
MUTATIONS = (
    (TOP, "ic_en_ignored",
     "wire flt_to_ic = flt_out_pass && ic_en;",
     "wire flt_to_ic = flt_out_pass;"),
    (TOP, "ic_drop_missing_from_total",
     "{31'd0,(flt_free || ic_rej_fire || rm_dup_fire)} +",
     "{31'd0,(flt_free || rm_dup_fire)} +"),
    (IC, "reject_writes_psn",
     "(state == ST_WRITE) && accept_q;",
     "(state == ST_WRITE);"),
    (IC, "net_b_aliases_net_a_psn",
     "(in_desc[99] ? NUM_RX_VL : 0) + in_vl",
     "in_vl"),
    (IC, "lost_one_rejected",
     "end else if (sn_q == exp2) begin",
     "end else if (1'b0) begin"),
)


def run():
    vsim = next((p for p in VSIM_CANDIDATES if p.is_file()), None)
    if vsim is None:
        raise RuntimeError("Questa vsim.exe not found; cannot skip negative gate")
    OUT.mkdir(exist_ok=True)
    originals = {p: hashlib.sha256(p.read_bytes()).hexdigest().upper() for p in (TOP, IC)}
    from mutant_compile_list import regress_compile_files
    rtl_files = regress_compile_files(SIM)
    env = os.environ.copy()
    if not env.get("SALT_LICENSE_SERVER"):
        import winreg
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, "Environment") as key:
            env["SALT_LICENSE_SERVER"], _ = winreg.QueryValueEx(key, "SALT_LICENSE_SERVER")
    report = ["T08e isolated RTL faults: compile, then FAIL (a pass is MISSED)"] + \
             ["original %s SHA-256: %s" % (p.relative_to(ROOT).as_posix(), h)
              for p, h in originals.items()]
    detected = 0
    for target, name, needle, replacement in MUTATIONS:
        source = target.read_text(encoding="utf-8")
        if source.count(needle) != 1:
            raise RuntimeError("unexpected RTL shape for mutant " + name)
        with tempfile.TemporaryDirectory(prefix="t08e_mut_", dir=str(OUT)) as tmp:
            work = Path(tmp)
            mutant = work / target.name
            mutant.write_text(source.replace(needle, replacement, 1), encoding="utf-8")
            library = work / "lib"
            tcl = work / "run.tcl"
            sources = [mutant if p == target.resolve() else p for p in rtl_files]
            sources.append(TB)
            tcl.write_text(
                "onerror { quit -f -code 1 }\n"
                "vlib {%s}\n" % library.as_posix() +
                "vlog -sv +notimingcheck -work {%s} %s\n" %
                (library.as_posix(), " ".join("{%s}" % p.as_posix() for p in sources)) +
                "puts {T08E_MUTANT_COMPILED}\n"
                "vsim -lib {%s} %s\n" % (library.as_posix(), TB_TOP) +
                "run -all\n"
                "quit -f\n", encoding="utf-8")
            try:
                proc = subprocess.run([str(vsim), "-c", "-do", "source {%s}" % tcl.as_posix()],
                                      cwd=str(SIM), env=env, stdout=subprocess.PIPE,
                                      stderr=subprocess.STDOUT, timeout=600, check=False)
                output = proc.stdout.decode("utf-8", errors="replace")
            except subprocess.TimeoutExpired as exc:
                output = (exc.stdout or b"").decode("utf-8", errors="replace") + "\nMUTANT TIMEOUT\n"
                proc = None
        (OUT / ("T08emut_" + name + ".txt")).write_text(output, encoding="utf-8")
        compiled = "T08E_MUTANT_COMPILED" in output and "Errors: 0" in output
        failed = re.search(r"T08e TOP IC FAIL \(IF_MODE=1 errors=([1-9][0-9]*)\)", output)
        passed = "T08e TOP IC PASS" in output
        caught = compiled and bool(failed) and not passed and proc is not None
        detected += int(caught)
        line = "%s %s (compiled=%s, TB_FAIL=%s, rc=%s)" % (
            name, "DETECTED" if caught else "MISSED", compiled, bool(failed),
            "timeout" if proc is None else proc.returncode)
        print(line, flush=True)
        report.append(line)
    for p, h in originals.items():
        assert hashlib.sha256(p.read_bytes()).hexdigest().upper() == h, "production RTL changed!"
    report.append("T08e MUTATION SUMMARY: %d/%d detected" % (detected, len(MUTATIONS)))
    (OUT / "T08e_mutants_report.txt").write_text("\n".join(report) + "\n", encoding="utf-8")
    print(report[-1], flush=True)
    return 0 if detected == len(MUTATIONS) else 1


if __name__ == "__main__":
    try:
        sys.exit(run())
    except Exception as exc:
        print("T08e MUTATION GATE FAIL: %s" % exc, flush=True)
        sys.exit(1)
