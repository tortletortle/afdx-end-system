#!/usr/bin/env python3
"""Isolated negative controls for the top-level RX RM integration (T10).

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
RM = ROOT / "rtl" / "rx" / "rx_rm.v"
TB = SIM / "tb" / "tb_t10_top_rm.v"
TB_TOP = "tb_t10_top_rm"   # IF_MODE=0: includes the earlier-ts late-copy case
OUT = SIM / "out"
VSIM_CANDIDATES = (
    Path(r"C:\altera_pro\26.1.1\questa_fse\win64\vsim.exe"),
    Path(r"C:\altera_pro\26.1.1\modelsim_ase\win32aloem\vsim.exe"),
    Path(r"C:\altera_pro\26.1.1\modelsim_ae\win32aloem\vsim.exe"),
)
# Single, precisely matched RTL faults (file, name, needle, replacement).
# A compile failure or timeout is not a detected functional fault.
MUTATIONS = (
    (RM, "dup_never_dropped",
     "fwd_q     <= !(active_q && seen_q && same_sn && in_win);",
     "fwd_q     <= 1'b1;"),
    (RM, "one_sided_skew_window",
     "wire [23:0] dts_ab = dts[23] ? (~dts + 24'd1) : dts;",
     "wire [23:0] dts_ab = dts;"),
    (RM, "seen_bit_ignored",
     "wire seen_q  = st_q[32];",
     "wire seen_q  = 1'b1;"),
    (RM, "dup_rewrites_state",
     "active_q && fwd_q;",
     "active_q;"),
    (TOP, "rm_glb_en_ignored",
     ".rm_glb_en(ctl_r[3]),",
     ".rm_glb_en(1'b1),"),
    (TOP, "ic_bypass_skips_rm",
     "assign rm_in_vld  = ic_to_rm || (flt_out_vld && flt_to_rm && !ic_out_vld);",
     "assign rm_in_vld  = ic_to_rm;"),
    (TOP, "rm_drop_missing_from_total",
     "if (flt_free || ic_rej_fire || (rm_out_vld && !rm_out_fwd))",
     "if (flt_free || ic_rej_fire)"),
)


def run():
    vsim = next((p for p in VSIM_CANDIDATES if p.is_file()), None)
    if vsim is None:
        raise RuntimeError("Questa vsim.exe not found; cannot skip negative gate")
    OUT.mkdir(exist_ok=True)
    originals = {p: hashlib.sha256(p.read_bytes()).hexdigest().upper() for p in (TOP, RM)}
    runner = (SIM / "run_regress.ps1").read_text(encoding="utf-8")
    rtl_list = re.findall(r"'(\.\./rtl/[^']+\.v)'", runner)
    if len(rtl_list) < 15 or rtl_list.count("../rtl/top/AFDX_top.v") != 1:
        raise RuntimeError("runner RTL list parse incomplete")
    rtl_files = [(SIM / name).resolve() for name in rtl_list]
    env = os.environ.copy()
    if not env.get("SALT_LICENSE_SERVER"):
        import winreg
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, "Environment") as key:
            env["SALT_LICENSE_SERVER"], _ = winreg.QueryValueEx(key, "SALT_LICENSE_SERVER")
    report = ["T10 isolated RTL faults: compile, then FAIL (a pass is MISSED)"] + \
             ["original %s SHA-256: %s" % (p.relative_to(ROOT).as_posix(), h)
              for p, h in originals.items()]
    detected = 0
    for target, name, needle, replacement in MUTATIONS:
        source = target.read_text(encoding="utf-8")
        if source.count(needle) != 1:
            raise RuntimeError("unexpected RTL shape for mutant " + name)
        with tempfile.TemporaryDirectory(prefix="t10_mut_", dir=str(OUT)) as tmp:
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
        (OUT / ("T10mut_" + name + ".txt")).write_text(output, encoding="utf-8")
        compiled = "T08E_MUTANT_COMPILED" in output and "Errors: 0" in output
        failed = re.search(r"T10 TOP RM FAIL \(IF_MODE=0 errors=([1-9][0-9]*)\)", output)
        passed = "T10 TOP RM PASS" in output
        caught = compiled and bool(failed) and not passed and proc is not None
        detected += int(caught)
        line = "%s %s (compiled=%s, TB_FAIL=%s, rc=%s)" % (
            name, "DETECTED" if caught else "MISSED", compiled, bool(failed),
            "timeout" if proc is None else proc.returncode)
        print(line, flush=True)
        report.append(line)
    for p, h in originals.items():
        assert hashlib.sha256(p.read_bytes()).hexdigest().upper() == h, "production RTL changed!"
    report.append("T10 MUTATION SUMMARY: %d/%d detected" % (detected, len(MUTATIONS)))
    (OUT / "T10_mutants_report.txt").write_text("\n".join(report) + "\n", encoding="utf-8")
    print(report[-1], flush=True)
    return 0 if detected == len(MUTATIONS) else 1


if __name__ == "__main__":
    try:
        sys.exit(run())
    except Exception as exc:
        print("T10 MUTATION GATE FAIL: %s" % exc, flush=True)
        sys.exit(1)
