// T39/T39g: public-host-bus RTC control on the AFDX_top integration.
// This is a control-path regression with a deliberately shortened RTC second;
// it is not evidence for default 1 Hz PPS accuracy or asynchronous-input
// CDC signoff.
//
// Checks use only the public host bus, pps_in/pps_out, and rtc_time_us ports:
//   * CTL[10] RTC_EN clear stops PPS discipline while the clock continues to
//     advance; the current correction offset is retained and local pps_out
//     continues to be generated from the local timebase.
//   * Re-enable, inject an external PPS at a non-zero phase, and observe a
//     discipline counter event plus a corrected timestamp different from the
//     raw timebase register. Clearing RTC_EN again must retain that offset,
//     ignore further discipline events, and leave the clock free-running.
//   * CTL[11] RTC_HOLD freezes rtc_time_us and local pps_out; release resumes.
//   * reset restores CTL defaults, clears RTC status/counters, and restarts the
//     externally visible RTC near zero.
//
// RTC_EN is a synchronization enable, not a source mux: rtc_sync keeps the
// accumulated offset/frequency bias when disabled. The shortened second is
// for control-path coverage only, not default 1 Hz accuracy evidence.
`timescale 1 ns / 1 ps
module tb_t39_rtc_top #(parameter integer IF_MODE = 0);
  reg clk = 1'b0;
  always #4 clk = ~clk;

  reg reset = 1'b1;
  reg host_cs = 1'b0, host_we = 1'b0;
  reg [15:0] host_addr = 16'd0;
  reg [31:0] host_wdata = 32'd0;
  reg pps_in = 1'b0;
  wire [31:0] host_rdata;
  wire host_ack, pps_out;
  wire [63:0] rtc_time_us;
  integer errors = 0;
  integer pps_out_count = 0;
  integer guard;
  reg [31:0] rd, status, jumps0, steps0, pps0, corrected_lo, raw_lo;
  reg signed [31:0] correction_delta;
  reg [63:0] stamp0, held_stamp;
  reg signed [63:0] offset_before_disable, offset_after_disable;
  integer held_pps_count;

  localparam [31:0] CTL_DEFAULT = 32'h0000_051C;
  localparam [31:0] CTL_RTC_OFF = 32'h0000_011C;
  localparam [31:0] CTL_HOLD    = 32'h0000_0D1C;

  AFDX_top #(
    .IF_MODE(IF_MODE), .FCS_MODE(2), .TICK_US(1),
    .RTC_US_PER_SEC(64), .RTC_SYNC_TO_US(128)
  ) dut (
    .rx_error(1'b0), .rx_error_b(1'b0),
    .clk(clk), .reset(reset),
    .tx_data(), .rx_data(8'd0), .tx_valid(), .rx_valid(1'b0),
    .tx_ready(), .rx_ready(),
    .tx_data_b(), .tx_valid_b(), .tx_ready_b(),
    .rx_data_b(8'd0), .rx_valid_b(1'b0), .rx_ready_b(),
    .host_cs(host_cs), .host_we(host_we), .host_addr(host_addr),
    .host_wdata(host_wdata), .host_rdata(host_rdata), .host_ack(host_ack),
    .host_irq(), .pps_in(pps_in), .pps_out(pps_out),
    .rtc_time_us(rtc_time_us), .dbg_frame_event()
  );

  always @(posedge clk)
    if (!reset && pps_out === 1'b1) pps_out_count = pps_out_count + 1;

  task bad(input [8*112-1:0] msg);
    begin
      errors = errors + 1;
      if (errors <= 20) $display("T39%0d ERROR t=%0t: %0s", IF_MODE, $time, msg);
    end
  endtask

  task host_write(input [15:0] addr, input [31:0] data);
    begin
      @(negedge clk);
      host_cs = 1'b1; host_we = 1'b1; host_addr = addr; host_wdata = data;
      @(negedge clk);
      if (host_ack !== 1'b1) bad("host write ACK missing");
      host_cs = 1'b0; host_we = 1'b0;
      repeat (2) @(negedge clk);
    end
  endtask

  task host_read(input [15:0] addr, output [31:0] data);
    begin
      @(negedge clk);
      host_cs = 1'b1; host_we = 1'b0; host_addr = addr;
      @(negedge clk);
      if (host_ack !== 1'b1) bad("host read ACK missing");
      data = host_rdata;
      host_cs = 1'b0;
      repeat (1) @(negedge clk);
    end
  endtask

  // Raw, free-running timebase is exposed at 0x50/0x54. Reading both words
  // spans only a few clk cycles, so allow a one-microsecond boundary race.
  task read_raw_time(output [63:0] raw);
    reg [31:0] hi, lo;
    begin
      host_read(16'h0054, hi);
      host_read(16'h0050, lo);
      raw = {hi, lo};
    end
  endtask

  task inject_pps;
    begin
      @(negedge clk); pps_in = 1'b1;
      repeat (8) @(negedge clk);
      pps_in = 1'b0;
      repeat (8) @(negedge clk);
    end
  endtask

  initial begin
    // Global reset is held long enough for rst_sync. The shortened second is
    // 64 nominal RTC ticks; with the default 125 MHz timebase this is about
    // 8,000 clk cycles per local second. It accelerates control tests only.
    repeat (8) @(negedge clk);
    reset = 1'b0;
    repeat (8) @(negedge clk);

    host_read(16'h0008, rd);
    if (rd !== CTL_DEFAULT) bad("reset CTL must default RTC_EN=1 and HOLD=0");

    // Disable synchronization before any external PPS discipline. The public
    // RTC still advances and the local PPS output remains driven by timebase.
    host_write(16'h0008, CTL_RTC_OFF);
    host_read(16'h0008, rd);
    if (rd !== CTL_RTC_OFF) bad("CTL[10] RTC_EN clear did not read back");
    host_read(16'hAC32, jumps0);
    host_read(16'hAC33, steps0);
    inject_pps();
    host_read(16'hAC32, rd);
    host_read(16'hAC33, status);
    if (rd !== jumps0 || status !== steps0)
      bad("RTC_EN=0 accepted PPS discipline while disabled");
    stamp0 = rtc_time_us;
    guard = pps_out_count;
    repeat (9000) @(negedge clk);
    if (rtc_time_us <= stamp0) bad("RTC_EN=0 stopped the public RTC clock");
    if (pps_out_count <= guard) bad("RTC_EN=0 suppressed the local pps_out pulse");

    // Enable sync and wait until a safely non-zero local phase. Poll only the
    // public RTC phase register so this remains an interface-level test.
    host_write(16'h0008, CTL_DEFAULT);
    guard = 0;
    begin : wait_phase
      reg phase_reached;
      phase_reached = 1'b0;
      while (!phase_reached && guard < 4000) begin
        host_read(16'hAC35, rd);
        if (rd >= 32'd20) phase_reached = 1'b1;
        else guard = guard + 1;
      end
      if (!phase_reached) bad("timed out waiting for non-zero RTC phase");
    end
    host_read(16'hAC32, jumps0);
    host_read(16'hAC33, steps0);
    inject_pps();
    host_read(16'hAC32, rd);
    host_read(16'hAC33, status);
    if (rd == jumps0 && status == steps0)
      bad("enabled external PPS produced no jump/step event");
    host_read(16'hAC30, status);
    if (status[1] !== 1'b0) bad("SYNC_LOSS did not clear after external PPS");
    host_read(16'hAC36, corrected_lo);
    host_read(16'h0050, raw_lo);
    correction_delta = $signed(corrected_lo - raw_lo);
    if (correction_delta >= -1 && correction_delta <= 1)
      bad("enabled PPS did not alter the public corrected RTC");
    read_raw_time(stamp0);
    offset_before_disable = $signed(rtc_time_us - stamp0);
    if (offset_before_disable >= -1 && offset_before_disable <= 1)
      bad("corrected timestamp offset is not observable on rtc_time_us");

    // Clearing RTC_EN stops future PPS corrections but preserves the last
    // correction. Compare the estimate before/after; each public-port/raw-reg
    // sample can straddle one tick, so a two-microsecond delta is tolerated.
    host_write(16'h0008, CTL_RTC_OFF);
    host_read(16'hAC32, jumps0);
    host_read(16'hAC33, steps0);
    inject_pps();
    host_read(16'hAC32, rd);
    host_read(16'hAC33, status);
    if (rd !== jumps0 || status !== steps0)
      bad("RTC_EN=0 changed PPS discipline counters");
    read_raw_time(stamp0);
    offset_after_disable = $signed(rtc_time_us - stamp0);
    if (offset_after_disable - offset_before_disable > 64'sd2 ||
        offset_before_disable - offset_after_disable > 64'sd2)
      bad("RTC_EN=0 did not retain the accumulated correction offset");
    stamp0 = rtc_time_us;
    repeat (500) @(negedge clk);
    if (rtc_time_us <= stamp0) bad("RTC_EN=0 did not keep the local clock advancing");

    // HOLD freezes both the base clock and sync phase/output. Keep RTC enabled
    // and avoid external PPS during this window.
    host_write(16'h0008, CTL_HOLD);
    held_stamp = rtc_time_us;
    held_pps_count = pps_out_count;
    repeat (500) @(negedge clk);
    if (rtc_time_us !== held_stamp) bad("RTC_HOLD failed to freeze rtc_time_us");
    if (pps_out_count != held_pps_count) bad("RTC_HOLD failed to stop local pps_out");
    host_write(16'h0008, CTL_DEFAULT);
    repeat (500) @(negedge clk);
    if (rtc_time_us <= held_stamp) bad("RTC clock did not resume after HOLD release");

    // Reset after non-default control and correction activity. Public control,
    // synchronization counters/status, and externally visible time restart.
    reset = 1'b1;
    repeat (8) @(negedge clk);
    reset = 1'b0;
    repeat (8) @(negedge clk);
    host_read(16'h0008, rd);
    if (rd !== CTL_DEFAULT) bad("reset did not restore RTC control defaults");
    host_read(16'hAC30, status);
    if (status[2:0] !== 3'b000) bad("reset did not clear RTC lock/loss/PPS status");
    host_read(16'hAC32, jumps0);
    host_read(16'hAC33, steps0);
    host_read(16'hAC34, pps0);
    if (jumps0 !== 32'd0 || steps0 !== 32'd0 || pps0 !== 32'd0)
      bad("reset did not clear RTC event counters");
    if (rtc_time_us > 64'd1) bad("reset did not restart the public RTC near zero");

    if (errors == 0)
      $display("T39 RTC TOP CONTROL PASS (IF_MODE=%0d public CTL RTC_EN/HOLD, offset retention, PPS correction gating, hold/release, reset; shortened US_PER_SEC=64; no CDC/board claim)", IF_MODE);
    else
      $display("T39 RTC TOP CONTROL FAIL (IF_MODE=%0d errors=%0d)", IF_MODE, errors);
    $finish;
  end

  initial begin
    #20_000_000;
    bad("watchdog timeout");
    $finish;
  end
endmodule

module tb_t39g_rtc_top;
  tb_t39_rtc_top #(.IF_MODE(1)) u_tb();
endmodule
