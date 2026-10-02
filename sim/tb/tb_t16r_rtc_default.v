// =====================================================================
// T16r -- rtc_sync with its DEFAULT parameters under a real 1 Hz PPS
// (audit 20260928 "RTC default PPS / sync-loss contract").
//
// The top level ties sync_vld to 0, so PPS is the only discipline source.
// With the old default SYNC_TIMEOUT=4000 us the watchdog fired ~4 ms after
// every PPS: SYNC_LOSS was 1 for 996 ms of each second and smoothing /
// lock were disabled.  This TB instantiates rtc_sync WITHOUT parameter
// overrides (US_PER_SEC = 1e6) and drives tick_us every clock, so one
// simulated second is 1e6 cycles (8 ms of sim time).
//
// P1  8 PPS pulses on an exact 1 s cycle grid, 0.3 s off the local second
//     (first pulse -> one jump):
//     after the first PPS, SYNC_LOSS must never assert; locked=1 by the end;
//     |last_err| <= 1 us on the final PPS
// P2  PPS stops: SYNC_LOSS still 0 at +2.4 s, asserted by +2.6 s
//     (default timeout 2.5 s = two missed PPS); locked drops with it
// P3  PPS resumes: SYNC_LOSS clears on the first pulse, re-locks
// Verdict: "T16r RTC DEFAULT PASS (...)" / "T16r RTC DEFAULT FAIL (...)"
// =====================================================================
`timescale 1ns/1ps
module tb_t16r_rtc_default;
  reg clk = 0; always #4 clk = ~clk;
  reg rst = 1, pps = 0;
  reg [63:0] free_us = 0;
  wire [63:0] rtc_us;
  wire pps_out, sync_loss, locked;
  wire [31:0] last_err, jump_cnt, step_cnt, pps_cnt, sec_phase;

  rtc_sync dut (                       // NO parameter overrides on purpose
    .clk(clk), .rst_sync(rst), .en(1'b1), .hold(1'b0), .tick_us(!rst),
    .rtc_free_us(free_us), .pps_in(pps),
    .sync_vld(1'b0), .sync_master_ts(64'd0), .path_est_us(16'd0),
    .th_jump_us(8'd50), .log2_avg(4'd6),
    .rtc_time_us(rtc_us), .pps_out(pps_out), .sync_loss(sync_loss), .locked(locked),
    .last_err_us(last_err), .jump_cnt(jump_cnt), .step_cnt(step_cnt),
    .pps_cnt(pps_cnt), .sec_phase(sec_phase));

  always @(posedge clk) if (!rst) free_us <= free_us + 64'd1;

  // PPS generator on an exact 1 s grid of clock cycles (tick_us every clock).
  // Grid is 0.3 s off the local second so the first pulse forces a jump.
  integer cyc = 0;
  always @(posedge clk) cyc <= cyc + 1;
  reg pps_en = 0;
  integer last_rise = 0;
  always @(negedge clk) begin
    pps <= pps_en && (((cyc + 300000) % 1000000) < 10);
    if (pps_en && ((cyc + 300000) % 1000000) == 0) last_rise = cyc;
  end

  integer errors = 0, checks = 0, e;
  reg watch = 0;                       // SYNC_LOSS must stay 0 while set
  integer loss_cycles = 0;
  always @(posedge clk) if (watch && sync_loss) loss_cycles = loss_cycles + 1;

  task bad; input [8*48-1:0] msg; begin errors = errors + 1; $display("  [err] T16r t=%0t: %0s", $time, msg); end endtask
  task chk; input c; input [8*48-1:0] msg; begin checks = checks + 1; if (!c) bad(msg); end endtask
  task wait_cyc; input integer target; begin while (cyc < target) @(negedge clk); end endtask

  initial begin
    repeat (5) @(negedge clk); rst = 0;
    // ---------- P1: 8 pulses at cyc 0.7e6, 1.7e6 ... 7.7e6 ----------
    pps_en = 1;
    wait_cyc(700000 + 100); watch = 1;         // after the first (jump) pulse
    wait_cyc(7700000 + 100);
    pps_en = 0;
    chk(loss_cycles == 0, "P1 SYNC_LOSS asserted between 1 Hz PPS");
    chk(locked === 1'b1, "P1 not locked after 8 PPS");
    e = $signed(last_err);
    chk(e >= -1 && e <= 1, "P1 final |err| > 1 us");
    chk(jump_cnt == 1, "P1 expected exactly one jump");
    chk(pps_cnt >= 7, "P1 local pps_out not running");
    $display("T16rMETRIC phase=P1 pps_in=8 jumps=%0d steps=%0d last_err_us=%0d locked=%0d loss_cycles=%0d",
             jump_cnt, step_cnt, e, locked, loss_cycles);
    watch = 0;
    // ---------- P2: no PPS; last rise at 7.7e6 ----------
    wait_cyc(last_rise + 2400000);
    chk(sync_loss === 1'b0, "P2 SYNC_LOSS early (< 2.4 s)");
    wait_cyc(last_rise + 2600000);
    chk(sync_loss === 1'b1, "P2 SYNC_LOSS missing (> 2.6 s)");
    chk(locked === 1'b0, "P2 locked must drop with SYNC_LOSS");
    // ---------- P3: resume on the same grid (next rise 10.7e6) ----------
    pps_en = 1;
    wait_cyc(10700000 + 100);
    chk(sync_loss === 1'b0, "P3 SYNC_LOSS not cleared by PPS");
    watch = 1; loss_cycles = 0;
    wait_cyc(15700000 + 100);
    chk(loss_cycles == 0, "P3 SYNC_LOSS after resume");
    chk(locked === 1'b1, "P3 not locked after resume");
    e = $signed(last_err);
    $display("T16rMETRIC phase=P3 pps_in=6 jumps=%0d steps=%0d last_err_us=%0d locked=%0d",
             jump_cnt, step_cnt, e, locked);
    if (errors == 0)
      $display("T16r RTC DEFAULT PASS (default US_PER_SEC=1e6 SYNC_TIMEOUT=2.5e6: 1 Hz PPS no false loss, lock, loss at 2.5 s, recovery; %0d checks)", checks);
    else
      $display("T16r RTC DEFAULT FAIL (errors=%0d of %0d checks)", errors, checks);
    $finish;
  end
endmodule
