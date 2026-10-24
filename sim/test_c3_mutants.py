#!/usr/bin/env python3
"""C3 isolated negative controls for seven modules (≥4 mutants each).

Run serially, never alongside run_regress.ps1 (it kills active vsim tasks).
Each mutant is compiled in its own temporary work library.  No production
RTL, normal work library, test vectors, or regression CSV are modified.
A compile error / timeout / passing test counts as MISSED, not detected.

Killers: T05b (scheduler), T41 (mac_tx / gmii_rx_strip), T15 (snmp),
T16 (tftp), T59 (reassembly), T16a (rtc).
"""
from __future__ import annotations

import hashlib
import os
import re
import subprocess
import sys
import tempfile
from datetime import datetime
from pathlib import Path

SIM = Path(__file__).resolve().parent
ROOT = SIM.parent
OUT = SIM / "out"
VSIM_CANDIDATES = (
    Path(r"C:\altera_pro\26.1.1\questa_fse\win64\vsim.exe"),
    Path(r"C:\altera_pro\26.1.1\modelsim_ase\win32aloem\vsim.exe"),
    Path(r"C:\altera_pro\26.1.1\modelsim_ae\win32aloem\vsim.exe"),
)

SCH = ROOT / "rtl" / "tx" / "tx_vl_scheduler.v"
MACT = ROOT / "rtl" / "tx" / "mac_tx_if.v"
STRIP = ROOT / "rtl" / "rx" / "gmii_rx_strip.v"
SNMP = ROOT / "rtl" / "mgmt" / "snmp_lite.v"
TFTP = ROOT / "rtl" / "mgmt" / "a615a_tftp.v"
REASM = ROOT / "rtl" / "rx" / "rx_reassembly.v"
RTC = ROOT / "rtl" / "mgmt" / "rtc_sync.v"

# (module, target, name, needle, replacement, killer, tb_rel, tb_top, pass_sub, fail_re, timeout_s)
MUTATIONS = (
    # ---- tx_vl_scheduler / T05b ----
    ("tx_vl_scheduler", SCH, "bag_ge_to_gt",
     "              go_viol  <= better ? (scan_best_age >= {1'b0,scan_best_bag} + PREPARE_CYCLES) :\n"
     "                                  (best_age >= {1'b0,best_bag} + PREPARE_CYCLES);",
     "              go_viol  <= better ? (scan_best_age > {1'b0,scan_best_bag} + PREPARE_CYCLES) :\n"
     "                                  (best_age > {1'b0,best_bag} + PREPARE_CYCLES);",
     "T05b", "tb/tb_t05b_jitter.v", "tb_t05b_jitter",
     "T05b SATURATED JITTER PASS",
     r"T05b SATURATED JITTER FAIL",
     300),
    ("tx_vl_scheduler", SCH, "age_overflow_ignored",
     "            port_ready_by_num[port_arr[scan_addr]] && !scan_age[31] &&",
     "            port_ready_by_num[port_arr[scan_addr]] && 1'b1 &&",
     "T05b", "tb/tb_t05b_jitter.v", "tb_t05b_jitter",
     "T05b SATURATED JITTER PASS",
     r"T05b SATURATED JITTER FAIL",
     300),
    ("tx_vl_scheduler", SCH, "skip_scan_lanes",
     "    for (scan_lane = 0; scan_lane < SCAN_LANES; scan_lane = scan_lane + 1) begin",
     "    for (scan_lane = 0; scan_lane < 1; scan_lane = scan_lane + 1) begin",
     "T05b", "tb/tb_t05b_jitter.v", "tb_t05b_jitter",
     "T05b SATURATED JITTER PASS",
     r"T05b SATURATED JITTER FAIL",
     300),
    ("tx_vl_scheduler", SCH, "grant_no_next_release",
     "      next_tx[pop_vl]  <= cycle_count + {1'b0, bag_arr[pop_vl]};",
     "      next_tx[pop_vl]  <= next_tx[pop_vl];",
     "T05b", "tb/tb_t05b_jitter.v", "tb_t05b_jitter",
     "T05b SATURATED JITTER PASS",
     r"T05b SATURATED JITTER FAIL",
     300),
    # ---- mac_tx_if / T41 ----
    ("mac_tx_if", MACT, "fcs_endian_swap",
     "  wire [7:0] fcs_byte = (o_fcs_idx == 2'd0) ? crc_final[7:0]  :\n"
     "                        (o_fcs_idx == 2'd1) ? crc_final[15:8] :\n"
     "                        (o_fcs_idx == 2'd2) ? crc_final[23:16] : crc_final[31:24];",
     "  wire [7:0] fcs_byte = (o_fcs_idx == 2'd0) ? crc_final[31:24] :\n"
     "                        (o_fcs_idx == 2'd1) ? crc_final[23:16] :\n"
     "                        (o_fcs_idx == 2'd2) ? crc_final[15:8]  : crc_final[7:0];",
     "T41", "tb/tb_t41_gmii_phy.v", "tb_t41_gmii_phy",
     "T41 GMII PHY PASS",
     r"T41 GMII PHY FAIL",
     300),
    ("mac_tx_if", MACT, "ifg_minus_one",
     "            if (ifg_cnt >= IFG_BYTES[7:0] - 8'd1) st <= ST_IDLE;",
     "            if (ifg_cnt >= IFG_BYTES[7:0] - 8'd2) st <= ST_IDLE;",
     "T41", "tb/tb_t41_gmii_phy.v", "tb_t41_gmii_phy",
     "T41 GMII PHY PASS",
     r"T41 GMII PHY FAIL",
     300),
    ("mac_tx_if", MACT, "preamble_short",
     "            o_pre_byte <= (pre_cnt == 8'd7) ? 8'hD5 : 8'h55;\n"
     "            if (pre_cnt == 8'd7) st <= ST_DATA;",
     "            o_pre_byte <= (pre_cnt == 8'd5) ? 8'hD5 : 8'h55;\n"
     "            if (pre_cnt == 8'd5) st <= ST_DATA;",
     "T41", "tb/tb_t41_gmii_phy.v", "tb_t41_gmii_phy",
     "T41 GMII PHY PASS",
     r"T41 GMII PHY FAIL",
     300),
    ("mac_tx_if", MACT, "sfd_value_wrong",
     "            o_pre_byte <= (pre_cnt == 8'd7) ? 8'hD5 : 8'h55;",
     "            o_pre_byte <= (pre_cnt == 8'd7) ? 8'hD4 : 8'h55;",
     "T41", "tb/tb_t41_gmii_phy.v", "tb_t41_gmii_phy",
     "T41 GMII PHY PASS",
     r"T41 GMII PHY FAIL",
     300),
    # ---- gmii_rx_strip / T41 ----
    ("gmii_rx_strip", STRIP, "sfd_any_byte",
     "            else if (!rx_error && pre_count == 3'd7 && rx_data == 8'hD5)",
     "            else if (!rx_error && pre_count == 3'd7 && 1'b1)",
     "T41", "tb/tb_t41_gmii_phy.v", "tb_t41_gmii_phy",
     "T41 GMII PHY PASS",
     r"T41 GMII PHY FAIL",
     300),
    ("gmii_rx_strip", STRIP, "rx_er_ignored",
     "            frame_error <= frame_error | rx_error;",
     "            frame_error <= frame_error;",
     "T41", "tb/tb_t41_gmii_phy.v", "tb_t41_gmii_phy",
     "T41 GMII PHY PASS",
     r"T41 GMII PHY FAIL",
     300),
    ("gmii_rx_strip", STRIP, "preamble_count_short",
     "            if (!rx_error && pre_count < 3'd7 && rx_data == 8'h55)",
     "            if (!rx_error && pre_count < 3'd5 && rx_data == 8'h55)",
     "T41", "tb/tb_t41_gmii_phy.v", "tb_t41_gmii_phy",
     "T41 GMII PHY PASS",
     r"T41 GMII PHY FAIL",
     300),
    ("gmii_rx_strip", STRIP, "sfd_after_three",
     "            else if (!rx_error && pre_count == 3'd7 && rx_data == 8'hD5)",
     "            else if (!rx_error && pre_count == 3'd3 && rx_data == 8'hD5)",
     "T41", "tb/tb_t41_gmii_phy.v", "tb_t41_gmii_phy",
     "T41 GMII PHY PASS",
     r"T41 GMII PHY FAIL",
     300),
    # ---- snmp_lite / T15 ----
    ("snmp_lite", SNMP, "comm_len_unchecked",
     "            if (!(req_b == COMM_N[7:0] && tlv_end <= {1'b0,msg_end})) st <= P_DROP;",
     "            if (1'b0) st <= P_DROP;",
     "T15", "tb/tb_t15_snmp.v", "tb_t15_snmp",
     "T15 SNMP PASS",
     r"T15 SNMP FAIL",
     300),
    ("snmp_lite", SNMP, "community_always_ok",
     "          if (req_b != comm_ch(comm_i)) comm_ok <= 1'b0;",
     "          if (1'b0) comm_ok <= 1'b0;",
     "T15", "tb/tb_t15_snmp.v", "tb_t15_snmp",
     "T15 SNMP PASS",
     r"T15 SNMP FAIL",
     300),
    ("snmp_lite", SNMP, "pdu_tag_accept_all",
     "          else if (req_b != PDU_GET && req_b != PDU_NXT &&\n"
     "                   req_b != PDU_SET) st <= P_DROP;",
     "          else if (1'b0) st <= P_DROP;",
     "T15", "tb/tb_t15_snmp.v", "tb_t15_snmp",
     "T15 SNMP PASS",
     r"T15 SNMP FAIL",
     300),
    ("snmp_lite", SNMP, "request_id_zeroed",
     "      E_RIDB:  rsp_wd = req_b;",
     "      E_RIDB:  rsp_wd = 8'h00;",
     "T15", "tb/tb_t15_snmp.v", "tb_t15_snmp",
     "T15 SNMP PASS",
     r"T15 SNMP FAIL",
     300),
    # ---- a615a_tftp / T16 ----
    ("a615a_tftp", TFTP, "block_advance_skip",
     "                blk_expect <= blk_expect + 16'd1;",
     "                blk_expect <= blk_expect + 16'd2;",
     "T16", "tb/tb_t16_tftp_rtc.v", "tb_t16_tftp_rtc",
     "T16 TFTP/RTC PASS",
     r"T16 TFTP/RTC FAIL",
     360),
    ("a615a_tftp", TFTP, "dup_rewrites_payload",
     "                if (sess && same_session_ip && same_session_port && blk_num == blk_expect &&",
     "                if (sess && same_session_ip && same_session_port && "
     "(blk_num == blk_expect || blk_num == (blk_expect - 16'd1)) &&",
     "T16", "tb/tb_t16_tftp_rtc.v", "tb_t16_tftp_rtc",
     "T16 TFTP/RTC PASS",
     r"T16 TFTP/RTC FAIL",
     360),
    ("a615a_tftp", TFTP, "ack_block_plus_one",
     "              end else if (blk_now == blk_expect) begin\n"
     "                to_ctr <= 32'd0; retry_cnt <= 8'd0;\n"
     "                resp_kind <= K_ACK; resp_blk <= blk_now; resp_len <= 11'd4;",
     "              end else if (blk_now == blk_expect) begin\n"
     "                to_ctr <= 32'd0; retry_cnt <= 8'd0;\n"
     "                resp_kind <= K_ACK; resp_blk <= blk_now + 16'd1; resp_len <= 11'd4;",
     "T16", "tb/tb_t16_tftp_rtc.v", "tb_t16_tftp_rtc",
     "T16 TFTP/RTC PASS",
     r"T16 TFTP/RTC FAIL",
     360),
    ("a615a_tftp", TFTP, "retry_never_gives_up",
     "          if (retry_cnt >= RETRY_MAX[7:0]) begin",
     "          if (1'b0) begin",
     "T16", "tb/tb_t16_tftp_rtc.v", "tb_t16_tftp_rtc",
     "T16 TFTP/RTC PASS",
     r"T16 TFTP/RTC FAIL",
     360),
    # ---- rx_reassembly / T59 ----
    ("rx_reassembly", REASM, "offset_no_udp_adjust",
     "  wire [15:0] in_start_b = (in_isfr && !in_is_first) ? (in_foff_b - 16'd8) : in_foff_b;",
     "  wire [15:0] in_start_b = in_foff_b;",
     "T59", "tb/tb_t59_reassembly.v", "tb_t59_reassembly",
     "T59 REASSEMBLY PASS",
     r"T59 REASSEMBLY FAIL",
     300),
    ("rx_reassembly", REASM, "mf_forced_clear",
     "  wire        in_mf    = work_desc[B_MF];",
     "  wire        in_mf    = 1'b0;",
     "T59", "tb/tb_t59_reassembly.v", "tb_t59_reassembly",
     "T59 REASSEMBLY PASS",
     r"T59 REASSEMBLY FAIL",
     300),
    ("rx_reassembly", REASM, "timeout_disabled",
     "      if ((TIMEOUT_TICKS > 0) && !timeout_found && !timeout_blocked && slot_vld[tf_k] &&",
     "      if ((1'b0) && !timeout_found && !timeout_blocked && slot_vld[tf_k] &&",
     "T59", "tb/tb_t59_reassembly.v", "tb_t59_reassembly",
     "T59 REASSEMBLY PASS",
     r"T59 REASSEMBLY FAIL",
     300),
    ("rx_reassembly", REASM, "overlap_ignored",
     "        overlap_r = 1'b1;",
     "        overlap_r = 1'b0;",
     "T59", "tb/tb_t59_reassembly.v", "tb_t59_reassembly",
     "T59 REASSEMBLY PASS",
     r"T59 REASSEMBLY FAIL",
     300),
    # ---- rtc_sync / T16a ----
    ("rtc_sync", RTC, "phase_sign_flip",
     "  wire signed [32:0] err_new = disc_pps ? err_pps : err_msg;",
     "  wire signed [32:0] err_new = disc_pps ? -err_pps : err_msg;",
     "T16a", "tb/tb_t16a_rtc_drift.v", "tb_t16a_rtc_drift",
     "T16a FLL STRICT PASS",
     r"T16a FLL STRICT FAIL",
     600),
    ("rtc_sync", RTC, "fll_gain_zero",
     "                             err_now : (err_now >>> log2_avg);",
     "                             err_now : 33'sd0;",
     "T16a", "tb/tb_t16a_rtc_drift.v", "tb_t16a_rtc_drift",
     "T16a FLL STRICT PASS",
     r"T16a FLL STRICT FAIL",
     600),
    ("rtc_sync", RTC, "sync_loss_never",
     "            sync_loss <= 1'b1;",
     "            sync_loss <= 1'b0;",
     "T16a", "tb/tb_t16a_rtc_drift.v", "tb_t16a_rtc_drift",
     "T16a FLL STRICT PASS",
     r"T16a FLL STRICT FAIL",
     600),
    ("rtc_sync", RTC, "jump_never",
     "        if (big_jump) begin",
     "        if (1'b0) begin",
     "T16a", "tb/tb_t16a_rtc_drift.v", "tb_t16a_rtc_drift",
     "T16a FLL STRICT PASS",
     r"T16a FLL STRICT FAIL",
     600),
)


def _kill_questa():
    for pn in ("vsim", "vish", "vlm", "vlog", "vopt", "vlib"):
        subprocess.run(["taskkill", "/F", "/IM", pn + ".exe"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def run(out_dir: Path | None = None) -> int:
    vsim = next((p for p in VSIM_CANDIDATES if p.is_file()), None)
    if vsim is None:
        raise RuntimeError("Questa vsim.exe not found; cannot skip negative gate")
    _kill_questa()
    OUT.mkdir(exist_ok=True)
    if out_dir is None:
        ts = datetime.now().strftime("%Y%m%d_%H%M%S")
        out_dir = OUT / ("p_c3_mutants_" + ts)
    out_dir.mkdir(parents=True, exist_ok=True)

    targets = sorted({m[1] for m in MUTATIONS}, key=lambda p: str(p))
    originals = {p: hashlib.sha256(p.read_bytes()).hexdigest().upper() for p in targets}
    from mutant_compile_list import regress_compile_files
    rtl_files = regress_compile_files(SIM)
    env = os.environ.copy()
    if not env.get("SALT_LICENSE_SERVER"):
        import winreg
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, "Environment") as key:
            env["SALT_LICENSE_SERVER"], _ = winreg.QueryValueEx(key, "SALT_LICENSE_SERVER")

    plan_lines = [
        "# C3 MUTANTS_PLAN",
        "",
        "| module | mutant | killer | needle theme |",
        "|---|---|---|---|",
    ]
    for mod, tgt, name, needle, _r, killer, *_rest in MUTATIONS:
        theme = needle.strip().split("\n")[0][:60].replace("|", "/")
        plan_lines.append("| %s | %s | %s | `%s` |" % (mod, name, killer, theme))
    (out_dir / "MUTANTS_PLAN.md").write_text("\n".join(plan_lines) + "\n", encoding="utf-8")

    report = [
        "C3 isolated RTL faults: compile, then FAIL (a pass is MISSED)",
        "out_dir: %s" % out_dir.as_posix(),
    ]
    for p, h in originals.items():
        report.append("original %s SHA-256: %s" % (p.relative_to(ROOT).as_posix(), h))

    rows = []
    detected = 0
    for mod, target, name, needle, replacement, killer, tb_rel, tb_top, pass_sub, fail_re, timeout_s in MUTATIONS:
        source = target.read_text(encoding="utf-8")
        if source.count(needle) != 1:
            raise RuntimeError("unexpected RTL shape for mutant %s.%s (count=%d)" %
                               (mod, name, source.count(needle)))
        tag = "%s__%s" % (mod, name)
        with tempfile.TemporaryDirectory(prefix="c3_mut_", dir=str(OUT)) as tmp:
            work = Path(tmp)
            mutant = work / target.name
            mutant.write_text(source.replace(needle, replacement, 1), encoding="utf-8")
            library = work / "lib"
            tcl = work / "run.tcl"
            tb = SIM / tb_rel
            sources = [mutant if p == target.resolve() else p for p in rtl_files]
            sources.append(tb)
            tcl.write_text(
                "onerror { quit -f -code 1 }\n"
                "vlib {%s}\n" % library.as_posix() +
                "vlog -sv +notimingcheck -work {%s} %s\n" %
                (library.as_posix(), " ".join("{%s}" % p.as_posix() for p in sources)) +
                "puts {C3_MUTANT_COMPILED}\n"
                "vsim -lib {%s} %s\n" % (library.as_posix(), tb_top) +
                "run -all\n"
                "quit -f\n", encoding="utf-8")
            try:
                proc = subprocess.run(
                    [str(vsim), "-c", "-do", "source {%s}" % tcl.as_posix()],
                    cwd=str(SIM), env=env, stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT, timeout=timeout_s, check=False)
                output = proc.stdout.decode("utf-8", errors="replace")
            except subprocess.TimeoutExpired as exc:
                output = (exc.stdout or b"").decode("utf-8", errors="replace") + "\nMUTANT TIMEOUT\n"
                proc = None
        log_path = out_dir / ("C3mut_" + tag + ".txt")
        log_path.write_text(output, encoding="utf-8")
        # also mirror under sim/out for quick grep like older scripts
        (OUT / ("C3mut_" + tag + ".txt")).write_text(output, encoding="utf-8")
        compiled = "C3_MUTANT_COMPILED" in output and "Errors: 0" in output
        failed = bool(re.search(fail_re, output))
        passed = pass_sub in output
        timed_out = proc is None or "MUTANT TIMEOUT" in output
        caught = compiled and failed and not passed and not timed_out
        detected += int(caught)
        status = "DETECTED" if caught else "MISSED"
        reason = []
        if not compiled:
            reason.append("compile")
        if timed_out:
            reason.append("timeout")
        if passed:
            reason.append("TB_PASS")
        if compiled and not failed and not passed and not timed_out:
            reason.append("no_FAIL_line")
        line = "%s %s killer=%s (compiled=%s, TB_FAIL=%s, TB_PASS=%s, rc=%s%s)" % (
            tag, status, killer, compiled, failed, passed,
            "timeout" if proc is None else proc.returncode,
            (", " + "+".join(reason)) if reason else "")
        print(line, flush=True)
        report.append(line)
        rows.append((mod, name, killer, status, compiled, failed, passed, timed_out, log_path.name))

    for p, h in originals.items():
        assert hashlib.sha256(p.read_bytes()).hexdigest().upper() == h, "production RTL changed!"

    summary = [
        "# C3 MUTANTS_SUMMARY",
        "",
        "generated: %s" % datetime.now().isoformat(timespec="seconds"),
        "result: **%d/%d detected** (compile-fail/timeout/PASS = MISSED)" % (detected, len(MUTATIONS)),
        "",
        "## Per-mutant",
        "",
        "| module | mutant | killer | status | compiled | FAIL | PASS | timeout | log |",
        "|---|---|---|---|---|---|---|---|---|",
    ]
    for mod, name, killer, status, compiled, failed, passed, timed_out, logn in rows:
        summary.append("| %s | %s | %s | %s | %s | %s | %s | %s | `%s` |" % (
            mod, name, killer, status, compiled, failed, passed, timed_out, logn))
    by_mod = {}
    for mod, name, killer, status, *_r in rows:
        by_mod.setdefault(mod, [0, 0])
        by_mod[mod][1] += 1
        by_mod[mod][0] += int(status == "DETECTED")
    summary += ["", "## By module", "", "| module | killed/total |", "|---|---|"]
    for mod in sorted(by_mod):
        k, t = by_mod[mod]
        summary.append("| %s | %d/%d |" % (mod, k, t))
    survivors = [r for r in rows if r[3] != "DETECTED"]
    summary += ["", "## Survivors (MISSED)", ""]
    if not survivors:
        summary.append("(none)")
    else:
        for mod, name, killer, status, compiled, failed, passed, timed_out, logn in survivors:
            why = "timeout" if timed_out else ("compile" if not compiled else (
                "equivalent_or_weak_oracle" if passed else "no_FAIL_line"))
            summary.append("- `%s.%s` killer=%s reason=%s log=`%s`" % (mod, name, killer, why, logn))
    summary += [
        "",
        "## Merge note vs historical 57",
        "",
        "Historical freeze cited 57/57 on T08c/e/T09–T12/T22 scripts only.",
        "This C3 batch adds %d new mutants on seven modules; do not overwrite the 57 figure — report both:" %
        len(MUTATIONS),
        "- prior: 57/57 (historical scripts)",
        "- C3 new: %d/%d" % (detected, len(MUTATIONS)),
        "- combined cited as %d/%d when both retained" % (57 + detected, 57 + len(MUTATIONS)),
        "",
    ]
    (out_dir / "MUTANTS_SUMMARY.md").write_text("\n".join(summary) + "\n", encoding="utf-8")
    report.append("C3 MUTATION SUMMARY: %d/%d detected" % (detected, len(MUTATIONS)))
    (out_dir / "C3_mutants_report.txt").write_text("\n".join(report) + "\n", encoding="utf-8")
    (OUT / "C3_mutants_report.txt").write_text("\n".join(report) + "\n", encoding="utf-8")
    print(report[-1], flush=True)
    print("SUMMARY written: %s" % (out_dir / "MUTANTS_SUMMARY.md").as_posix(), flush=True)
    return 0  # always 0 after run; kill rate is informational (no threshold)


if __name__ == "__main__":
    sys.exit(run())
