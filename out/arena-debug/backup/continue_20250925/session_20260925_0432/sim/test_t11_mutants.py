#!/usr/bin/env python3
"""Isolated negative controls for the top-level RX parse/port delivery (T11).

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
TB = SIM / "tb" / "tb_t11_top_port.v"
TB_TOP = "tb_t11_top_port"
OUT = SIM / "out"
VSIM_CANDIDATES = (
    Path(r"C:\altera_pro\26.1.1\questa_fse\win64\vsim.exe"),
    Path(r"C:\altera_pro\26.1.1\modelsim_ase\win32aloem\vsim.exe"),
    Path(r"C:\altera_pro\26.1.1\modelsim_ae\win32aloem\vsim.exe"),
)
# Single, precisely matched RTL faults (file, name, needle, replacement).
# A compile failure or timeout is not a detected functional fault.
PARSE = ROOT / "rtl" / "rx" / "rx_ip_udp_parse.v"
PB = ROOT / "rtl" / "rx" / "rx_port_buf.v"
MUTATIONS = (
    (PB, "fresh_not_read_cleared",
     "      p_fresh[hop_port] <= 1'b0;\n      p_ovf[hop_port]   <= 1'b0;",
     "      p_ovf[hop_port]   <= 1'b0;"),
    (PB, "seen_overwrite_not_pinned",
     "p_pin[in_port] <= 1'b1; p_pinb[in_port] <= e_head;",
     "free0 <= 1'b1; free0_id <= e_head;"),
    (PB, "older_pin_leaked",
     "if (e_pin) begin free0 <= 1'b1; free0_id <= e_pinb; end",
     ""),
    (PB, "queue_depth_ignored",
     "end else if (e_cnt >= in_depth) begin",
     "end else if (1'b0) begin"),
    (PB, "queue_pop_keeps_head",
     "p_head[hop_port]  <= b_nxt[h_head];",
     "p_head[hop_port]  <= h_head;"),
    (PB, "init_sweep_keeps_count",
     "p_cnt[init_addr[7:0]] <= 4'd0;",
     ""),
    (PARSE, "dport_check_missing",
     "else if (port_w1[15:0] != in_desc[15:0]) rsn = R_DPORT;",
     ""),
    (PARSE, "direction_check_missing",
     "else if (!port_w0[18])             rsn = R_DIR;",
     ""),
    (PARSE, "plen_from_frame_len",
     "out_plen   <= in_desc[173:163];",
     "out_plen   <= in_desc[158:148];"),
    (TOP, "desc_read_returns_post_clear",
     "desc_rd_d ? (desc_rx_d ? rdata_r :",
     "desc_rd_d ? (desc_rx_d ? rxpb_desc_word :"),
    (TOP, "port_drop_missing_from_total",
     "{31'd0,pb_ev_drop};",
     "32'd0;"),
    (TOP, "runtime_rx_pmem_read_missing",
     "!ctl_r[0] && !fb_busy) || (host_rx_rd && !fb_rd_en_a);",
     "!ctl_r[0] && !fb_busy);"),
    (TOP, "msg_rd_accepts_non_rx_port",
     "wire msg_rd_ok = msg_rd_hit && init_done && hop_is_rx;",
     "wire msg_rd_ok = msg_rd_hit && init_done;"),
)


def run():
    vsim = next((p for p in VSIM_CANDIDATES if p.is_file()), None)
    if vsim is None:
        raise RuntimeError("Questa vsim.exe not found; cannot skip negative gate")
    OUT.mkdir(exist_ok=True)
    originals = {p: hashlib.sha256(p.read_bytes()).hexdigest().upper() for p in (TOP, PARSE, PB)}
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
    report = ["T11 isolated RTL faults: compile, then FAIL (a pass is MISSED)"] + \
             ["original %s SHA-256: %s" % (p.relative_to(ROOT).as_posix(), h)
              for p, h in originals.items()]
    detected = 0
    for target, name, needle, replacement in MUTATIONS:
        source = target.read_text(encoding="utf-8")
        if source.count(needle) != 1:
            raise RuntimeError("unexpected RTL shape for mutant " + name)
        with tempfile.TemporaryDirectory(prefix="t11_mut_", dir=str(OUT)) as tmp:
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
        (OUT / ("T11mut_" + name + ".txt")).write_text(output, encoding="utf-8")
        compiled = "T08E_MUTANT_COMPILED" in output and "Errors: 0" in output
        failed = re.search(r"T11 TOP PORT FAIL \(IF_MODE=0 errors=([1-9][0-9]*)\)", output)
        passed = "T11 TOP PORT PASS" in output
        caught = compiled and bool(failed) and not passed and proc is not None
        detected += int(caught)
        line = "%s %s (compiled=%s, TB_FAIL=%s, rc=%s)" % (
            name, "DETECTED" if caught else "MISSED", compiled, bool(failed),
            "timeout" if proc is None else proc.returncode)
        print(line, flush=True)
        report.append(line)
    for p, h in originals.items():
        assert hashlib.sha256(p.read_bytes()).hexdigest().upper() == h, "production RTL changed!"
    report.append("T11 MUTATION SUMMARY: %d/%d detected" % (detected, len(MUTATIONS)))
    (OUT / "T11_mutants_report.txt").write_text("\n".join(report) + "\n", encoding="utf-8")
    print(report[-1], flush=True)
    return 0 if detected == len(MUTATIONS) else 1


if __name__ == "__main__":
    try:
        sys.exit(run())
    except Exception as exc:
        print("T11 MUTATION GATE FAIL: %s" % exc, flush=True)
        sys.exit(1)
