#!/usr/bin/env python3
"""Isolated negative controls for the top-level RX event interrupts (T11i, v0.5.17).

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
PB = ROOT / "rtl" / "rx" / "rx_port_buf.v"
TB = SIM / "tb" / "tb_t11i_top_int.v"
TB_TOP = "tb_t11i_top_int"
OUT = SIM / "out"
VSIM_CANDIDATES = (
    Path(r"C:\altera_pro\26.1.1\questa_fse\win64\vsim.exe"),
    Path(r"C:\altera_pro\26.1.1\modelsim_ase\win32aloem\vsim.exe"),
    Path(r"C:\altera_pro\26.1.1\modelsim_ae\win32aloem\vsim.exe"),
)
# Single, precisely matched RTL faults (file, name, needle, replacement).
# A compile failure or timeout is not a detected functional fault.
MUTATIONS = (
    (TOP, "int_bit0_never_set",
     "{28'd0, (rx_crc_err_a | rx_crc_err_b), pb_ev_ovf, pb_ev_queue, pb_ev_sample};",
     "{28'd0, (rx_crc_err_a | rx_crc_err_b), pb_ev_ovf, pb_ev_queue, 1'b0};"),
    (TOP, "int_bit1_bit2_swapped",
     "{28'd0, (rx_crc_err_a | rx_crc_err_b), pb_ev_ovf, pb_ev_queue, pb_ev_sample};",
     "{28'd0, (rx_crc_err_a | rx_crc_err_b), pb_ev_queue, pb_ev_ovf, pb_ev_sample};"),
    (TOP, "int_crc_bit_net_a_only",
     "{28'd0, (rx_crc_err_a | rx_crc_err_b), pb_ev_ovf, pb_ev_queue, pb_ev_sample};",
     "{28'd0, rx_crc_err_a, pb_ev_ovf, pb_ev_queue, pb_ev_sample};"),
    (TOP, "int_w1c_wins_over_event",
     "      int_st_r <= (w1c_int ? (int_st_r & ~host_wdata) : int_st_r) |\n"
     "                  {28'd0, (rx_crc_err_a | rx_crc_err_b), pb_ev_ovf, pb_ev_queue, pb_ev_sample};",
     "      int_st_r <= ((w1c_int ? (int_st_r & ~host_wdata) : int_st_r) |\n"
     "                  {28'd0, (rx_crc_err_a | rx_crc_err_b), pb_ev_ovf, pb_ev_queue, pb_ev_sample})\n"
     "                  & (w1c_int ? ~host_wdata : 32'hFFFF_FFFF);"),
    (TOP, "int_enable_not_masked",
     "          8'h14: int_en_r <= host_wdata & 32'hFF;",
     "          8'h14: int_en_r <= host_wdata;"),
    (TOP, "irq_ignores_int_enable",
     "  assign host_irq = ctl_r[14] | |(int_st_r & int_en_r);",
     "  assign host_irq = ctl_r[14] | |int_st_r;"),
    (TOP, "irq_ignores_sw_bit",
     "  assign host_irq = ctl_r[14] | |(int_st_r & int_en_r);",
     "  assign host_irq = |(int_st_r & int_en_r);"),
    (PB, "sample_event_sticky",
     "    ev_sample <= 1'b0; ev_queue <= 1'b0; ev_ovf <= 1'b0;",
     "    ev_queue <= 1'b0; ev_ovf <= 1'b0;"),
    (PB, "queue_overflow_no_event",
     "        qovf_cnt <= qovf_cnt + 32'd1; ev_ovf <= 1'b1;",
     "        qovf_cnt <= qovf_cnt + 32'd1;"),
)


def run():
    vsim = next((p for p in VSIM_CANDIDATES if p.is_file()), None)
    if vsim is None:
        raise RuntimeError("Questa vsim.exe not found; cannot skip negative gate")
    # Questa Starter allows one seat: leftover vish/vlm/vsim from an interrupted
    # run block the next checkout and the new session then sits at its prompt.
    for pn in ("vsim", "vish", "vlm", "vlog", "vopt", "vlib"):
        subprocess.run(["taskkill", "/F", "/IM", pn + ".exe"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    OUT.mkdir(exist_ok=True)
    originals = {p: hashlib.sha256(p.read_bytes()).hexdigest().upper() for p in (TOP, PB)}
    runner = (SIM / "run_regress.ps1").read_text(encoding="utf-8")
    rtl_list = re.findall(r"'(\../rtl/[^']+\.v)'", runner)
    if len(rtl_list) < 15 or rtl_list.count("../rtl/top/AFDX_top.v") != 1:
        raise RuntimeError("runner RTL list parse incomplete")
    rtl_files = [(SIM / name).resolve() for name in rtl_list]
    env = os.environ.copy()
    if not env.get("SALT_LICENSE_SERVER"):
        import winreg
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, "Environment") as key:
            env["SALT_LICENSE_SERVER"], _ = winreg.QueryValueEx(key, "SALT_LICENSE_SERVER")
    report = ["T11i isolated RTL faults: compile, then FAIL (a pass is MISSED)"] + \
             ["original %s SHA-256: %s" % (p.relative_to(ROOT).as_posix(), h)
              for p, h in originals.items()]
    detected = 0
    for target, name, needle, replacement in MUTATIONS:
        source = target.read_text(encoding="utf-8")
        if source.count(needle) != 1:
            raise RuntimeError("unexpected RTL shape for mutant " + name)
        with tempfile.TemporaryDirectory(prefix="t11i_mut_", dir=str(OUT)) as tmp:
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
                                      stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, timeout=900, check=False)
                output = proc.stdout.decode("utf-8", errors="replace")
            except subprocess.TimeoutExpired as exc:
                output = (exc.stdout or b"").decode("utf-8", errors="replace") + "\nMUTANT TIMEOUT\n"
                proc = None
        (OUT / ("T11imut_" + name + ".txt")).write_text(output, encoding="utf-8")
        compiled = "T08E_MUTANT_COMPILED" in output and "Errors: 0" in output
        failed = re.search(r"T11i TOP INT FAIL: ([1-9][0-9]*) errors", output)
        passed = "T11i TOP INT PASS" in output
        caught = compiled and bool(failed) and not passed and proc is not None
        detected += int(caught)
        line = "%s %s (compiled=%s, TB_FAIL=%s, rc=%s)" % (
            name, "DETECTED" if caught else "MISSED", compiled, bool(failed),
            "timeout" if proc is None else proc.returncode)
        print(line, flush=True)
        report.append(line)
    for p, h in originals.items():
        assert hashlib.sha256(p.read_bytes()).hexdigest().upper() == h, "production RTL changed!"
    report.append("T11i MUTATION SUMMARY: %d/%d detected" % (detected, len(MUTATIONS)))
    (OUT / "T11i_mutants_report.txt").write_text("\n".join(report) + "\n", encoding="utf-8")
    print(report[-1], flush=True)
    return 0 if detected == len(MUTATIONS) else 1


if __name__ == "__main__":
    try:
        sys.exit(run())
    except Exception as exc:
        print("T11i MUTATION GATE FAIL: %s" % exc, flush=True)
        sys.exit(1)
