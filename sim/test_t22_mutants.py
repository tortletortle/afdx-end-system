#!/usr/bin/env python3
"""Isolated negative controls for the T22 TX->RX loopback path (v0.5.17).

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
MACR = ROOT / "rtl" / "rx" / "mac_rx_if.v"
MACT = ROOT / "rtl" / "tx" / "mac_tx_if.v"
LOOK = ROOT / "rtl" / "rx" / "rx_vl_lookup.v"
PARSE = ROOT / "rtl" / "rx" / "rx_ip_udp_parse.v"
TB = SIM / "tb" / "tb_t22_top_loopback.v"
TB_TOP = "tb_t22_top_loopback"
OUT = SIM / "out"
VSIM_CANDIDATES = (
    Path(r"C:\altera_pro\26.1.1\questa_fse\win64\vsim.exe"),
    Path(r"C:\altera_pro\26.1.1\modelsim_ase\win32aloem\vsim.exe"),
    Path(r"C:\altera_pro\26.1.1\modelsim_ae\win32aloem\vsim.exe"),
)
# Single, precisely matched RTL faults (file, name, needle, replacement).
MUTATIONS = (
    (TOP, "dup_blocks_never_released",
     "  assign rm_dup_fire  = rm_out_vld && !rm_out_fwd;",
     "  assign rm_dup_fire  = 1'b0;"),
    (LOOK, "lookup_hit_never_asserted",
     "          out_hit <= m00 || m01 || m10 || m11;",
     "          out_hit <= 1'b0;"),
    (PARSE, "plen_from_frame_length",
     "      out_plen   <= in_desc[173:163];",
     "      out_plen   <= in_desc[158:148];"),
    (IC, "psn_not_written_back",
     "    if (mem_we) psn_mem[mem_addr] <= wr_data;",
     "    if (mem_we) psn_mem[mem_addr] <= psn_mem[mem_addr];"),
    (MACT, "tx_fcs_not_appended",
     "  wire fcs_en   = (FCS_MODE != 0);",
     "  wire fcs_en   = 1'b0;"),
    (MACR, "rx_payload_word_shifted",
     "                pmem_wr_en <= 1'b1;\n                pmem_wr_addr <= {blk_q,count[10:2]};\n                pmem_wr_data <= {pack[31:8],rx_data};",
     "                pmem_wr_en <= 1'b1;\n                pmem_wr_addr <= {blk_q,count[10:2]+11'd1};\n                pmem_wr_data <= {pack[31:8],rx_data};"),
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
    targets = (TOP, LOOK, PARSE, IC, MACT, MACR)
    originals = {p: hashlib.sha256(p.read_bytes()).hexdigest().upper() for p in targets}
    from mutant_compile_list import regress_compile_files
    rtl_files = regress_compile_files(SIM)
    env = os.environ.copy()
    if not env.get("SALT_LICENSE_SERVER"):
        import winreg
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, "Environment") as key:
            env["SALT_LICENSE_SERVER"], _ = winreg.QueryValueEx(key, "SALT_LICENSE_SERVER")
    report = ["T22 isolated RTL faults: compile, then FAIL (a pass is MISSED)"] + \
             ["original %s SHA-256: %s" % (p.relative_to(ROOT).as_posix(), h)
              for p, h in originals.items()]
    detected = 0
    for target, name, needle, replacement in MUTATIONS:
        source = target.read_text(encoding="utf-8")
        if source.count(needle) != 1:
            raise RuntimeError("unexpected RTL shape for mutant " + name)
        with tempfile.TemporaryDirectory(prefix="t22_mut_", dir=str(OUT)) as tmp:
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
                                      stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, timeout=1200, check=False)
                output = proc.stdout.decode("utf-8", errors="replace")
            except subprocess.TimeoutExpired as exc:
                output = (exc.stdout or b"").decode("utf-8", errors="replace") + "\nMUTANT TIMEOUT\n"
                proc = None
        (OUT / ("T22mut_" + name + ".txt")).write_text(output, encoding="utf-8")
        compiled = "T08E_MUTANT_COMPILED" in output and "Errors: 0" in output
        failed = re.search(r"T22 TOP LOOPBACK FAIL \(IF_MODE=0 errors=([1-9][0-9]*)\)", output)
        passed = "T22 TOP LOOPBACK PASS (IF_MODE=0" in output
        caught = compiled and bool(failed) and not passed and proc is not None
        detected += int(caught)
        line = "%s %s (compiled=%s, TB_FAIL=%s, rc=%s)" % (
            name, "DETECTED" if caught else "MISSED", compiled, bool(failed),
            "timeout" if proc is None else proc.returncode)
        print(line, flush=True)
        report.append(line)
    for p, h in originals.items():
        assert hashlib.sha256(p.read_bytes()).hexdigest().upper() == h, "production RTL changed!"
    report.append("T22 MUTATION SUMMARY: %d/%d detected" % (detected, len(MUTATIONS)))
    (OUT / "T22_mutants_report.txt").write_text("\n".join(report) + "\n", encoding="utf-8")
    print(report[-1], flush=True)
    return 0 if detected == len(MUTATIONS) else 1


if __name__ == "__main__":
    try:
        sys.exit(run())
    except Exception as exc:
        print("T22 MUTATION GATE FAIL: %s" % exc, flush=True)
        sys.exit(1)
