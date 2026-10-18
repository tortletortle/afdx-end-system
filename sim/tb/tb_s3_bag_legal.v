// T27 / S3 — official BAG table 1..128 ms on the TX wire through net_model.
// Scheduler stores BAG deadlines in exact clk cycles (TICK_US is not a BAG accelerator).
// Each slot: 3 SOF, two gaps, min = bag_us*125 (same floor as T04),
// A664P7 3.2.4.3, one 79-byte VL at 100 Mbps: max jitter is
// 40 us + (79+20)*8/100 Mbps = 47.92 us = 5990 testbench clock cycles.
`timescale 1 ns / 1 ps
module tb_s3_bag_legal_core #(parameter integer IF_MODE = 0);
  localparam integer DELAY_US = 10;
  localparam integer P_RX = 5;
  localparam integer P_TX = 0;
  localparam [11:0]  VL_RX = 12'h100;
  localparam [15:0]  PT_RX = 16'h7D80 + 4*P_RX;
  localparam [15:0]  VLID_TX = 16'h0100;
  localparam integer PLEN = 32;
  localparam integer WIRE_B = 79;
  localparam integer CYCLES_PER_US = 125; // independent 8 ns testbench clock contract
  localparam integer GAP_SLACK = 40 * CYCLES_PER_US + (WIRE_B + 20) * 10;
  localparam integer PROGRESS_CYCLES = 8000 * CYCLES_PER_US;

  reg clk = 0, reset = 1;
  always #4 clk = ~clk;

  wire        host_cs, host_we;
  wire [15:0] host_addr;
  wire [31:0] host_wdata;
  wire [31:0] host_rdata;
  wire        host_ack, host_irq;
  wire [7:0] tx_data, tx_data_b, rx_data, rx_data_b;
  wire       tx_valid, tx_valid_b, tx_ready, tx_ready_b;
  wire       rx_valid, rx_valid_b, rx_ready, rx_ready_b;
  wire [31:0] fwd_a, fwd_b;
  reg        mon_clr;

  AFDX_top #(.IF_MODE(IF_MODE), .FCS_MODE(2)) dut (
    .rx_error(1'b0), .rx_error_b(1'b0),
    .clk(clk), .reset(reset),
    .tx_data(tx_data), .rx_data(rx_data),
    .tx_valid(tx_valid), .rx_valid(rx_valid),
    .tx_ready(tx_ready), .rx_ready(rx_ready),
    .tx_data_b(tx_data_b), .tx_valid_b(tx_valid_b), .tx_ready_b(tx_ready_b),
    .rx_data_b(rx_data_b), .rx_valid_b(rx_valid_b), .rx_ready_b(rx_ready_b),
    .host_cs(host_cs), .host_we(host_we), .host_addr(host_addr),
    .host_wdata(host_wdata), .host_rdata(host_rdata), .host_ack(host_ack),
    .host_irq(host_irq),
    .pps_in(1'b0), .pps_out(), .rtc_time_us(), .dbg_frame_event());

  afdx_host_bfm u_host (
    .clk(clk), .cs(host_cs), .we(host_we), .addr(host_addr), .wdata(host_wdata),
    .rdata(host_rdata), .ack(host_ack));

  afdx_net_model #(.IF_MODE(IF_MODE), .DELAY_US(DELAY_US)) u_net (
    .clk(clk), .rst(reset),
    .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready),
    .tx_data_b(tx_data_b), .tx_valid_b(tx_valid_b), .tx_ready_b(tx_ready_b),
    .corrupt_a(1'b0), .corrupt_b(1'b0),
    .rx_data(rx_data), .rx_valid(rx_valid), .rx_ready(rx_ready),
    .rx_data_b(rx_data_b), .rx_valid_b(rx_valid_b), .rx_ready_b(rx_ready_b),
    .fwd_a(fwd_a), .fwd_b(fwd_b));

  afdx_timing_mon #(.IF_MODE(IF_MODE), .MAX_SOF(8)) u_mon (
    .clk(clk), .rst(reset), .clr(mon_clr),
    .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready));

  afdx_chk_mac #(.IF_MODE(IF_MODE)) u_chk (
    .clk(clk), .rst(reset),
    .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready));

  reg [23:0] bag_hold;
  afdx_chk_bag #(.IF_MODE(IF_MODE)) u_bag (
    .clk(clk), .rst(reset), .clr(mon_clr),
    .bag_us(bag_hold),
    .tx_valid(tx_valid), .tx_ready(tx_ready));

  integer errors, waitc, i, exp, bag_us, q20, min_gap, min_exp, max_exp;
  integer deliveries, gap, lim;
  reg [31:0] rd;
  integer blk, base_addr, pat;

  always @(posedge clk) if (!reset) begin
    if (dut.prs_out_vld && dut.pb_in_ready && !dut.prs_out_drop)
      deliveries = deliveries + 1;
  end

  task bad;
    input [8*96-1:0] reason;
    begin
      if (errors < 25) $display("  [err] T27 t=%0t: %0s", $time, reason);
      errors = errors + 1;
    end
  endtask

  function [10:0] mix_bucket;
    input [15:0] vlid, seed;
    input table_id;
    reg [15:0] x;
    begin
      x = vlid + seed + (table_id ? 16'h1F5B : 16'h9E37);
      x = x ^ (x >> 7);
      x = x * (table_id ? 16'h45D9 : 16'h9E37);
      x = x ^ (x >> 9);
      mix_bucket = x & 11'h7FF;
    end
  endfunction

  function [15:0] hash_addr;
    input [15:0] vlid, seed;
    input table_id, way;
    begin
      hash_addr = 16'h3D80 + ({4'd0, table_id} << 12) +
                  (mix_bucket(vlid, seed, table_id) << 1) + way;
    end
  endfunction

  function integer q20_of;
    input integer lmax;
    input integer bus;
    integer num, den;
    begin
      num = (lmax + 20) * 8 * 1048576;
      den = bus * 100;
      q20_of = (num + den - 1) / den;
    end
  endfunction

  task wait_sof;
    input integer need;
    input integer bag;
    integer report_at;
    begin
      lim = bag * 200 + 200000;
      waitc = 0;
      report_at = PROGRESS_CYCLES;
      $display("T27_PROGRESS event=wait_sof bag_us=%0d target=%0d observed=%0d sim_us=%0d",
               bag, need, u_mon.nsof, $time / 1000);
      while (u_mon.nsof < need && waitc < lim) begin
        @(negedge clk); waitc = waitc + 1;
        if (waitc >= report_at) begin
          $display("T27_PROGRESS event=waiting bag_us=%0d target=%0d observed=%0d waited_cycles=%0d sim_us=%0d",
                   bag, need, u_mon.nsof, waitc, $time / 1000);
          report_at = report_at + PROGRESS_CYCLES;
        end
      end
      if (u_mon.nsof < need) bad("SOF timeout on wire");
      $display("T27_PROGRESS event=wait_done bag_us=%0d target=%0d observed=%0d waited_cycles=%0d sim_us=%0d",
               bag, need, u_mon.nsof, waitc, $time / 1000);
    end
  endtask

  task drain_rx;
    begin
      waitc = 0;
      while (deliveries < u_mon.nsof && waitc < 400000) begin
        @(negedge clk); waitc = waitc + 1;
      end
      u_host.rd(16'h8180 + P_RX, rd);
      if (rd[31] === 1'b1)
        u_host.wr(16'h8380 + P_RX, 32'd0);
    end
  endtask

  task send_payload;
    begin
      u_host.rd(16'h0074, rd);
      waitc = 0;
      while (!rd[4] && waitc < 50000) begin
        @(negedge clk); waitc = waitc + 1;
        u_host.rd(16'h0074, rd);
      end
      if (!rd[4]) bad("no open TX block");
      blk = rd[3:0];
      base_addr = 16'h8800 + (blk << 9);
      @(negedge clk);
      u_host.cs = 1'b1; u_host.we = 1'b1;
      for (i = 0; i < 8; i = i + 1)
        u_host.wr_burst_word(base_addr + i, 32'hA0B0_C0D0 + pat + i);
      u_host.cs = 1'b0; u_host.we = 1'b0;
      u_host.wr(16'h8280 + P_TX, PLEN);
      pat = pat + 32'h0100_0000;
    end
  endtask

  task apply_bag;
    input integer e;
    begin
      bag_us = 1000 << e;
      bag_hold = bag_us[23:0];
      q20 = q20_of(WIRE_B, bag_us);
      if (e == 0) q20 = 8305;
      // CTL[13] is dropped while fb_busy (cfg_open_conflict). Table writes
      // then silently miss, and bag_arr stays at the previous slot.
      waitc = 0;
      while ((dut.fb_busy || dut.mac_a_busy || dut.mac_b_busy) && waitc < 200000) begin
        @(negedge clk); waitc = waitc + 1;
      end
      if (dut.fb_busy || dut.mac_a_busy || dut.mac_b_busy)
        bad("builder/MAC busy, cannot enter CFG_MODE");
      u_host.wr(16'h0008, 32'h2000);
      u_host.rd(16'h0008, rd);
      if (rd[13] !== 1'b1 || rd[1:0] !== 2'b00)
        bad("CTL did not enter CFG_MODE with TX/RX off");
      u_host.wr(16'h0204, 32'h0000_0000);
      u_host.wr(16'h0203, 32'hE000_0001);
      u_host.wr(16'h0202, 32'h1388_C000);
      u_host.wr(16'h0201, bag_us << 8);
      u_host.wr(16'h0480, q20);
      u_host.wr(16'h0200, 32'h8004_F000 | (e << 4) | 32'd3);
      repeat (16) @(negedge clk);
      u_host.rd(16'h0201, rd);
      if (rd[31:8] !== bag_us[23:0]) bad("w1 bag_us did not commit");
      if (dut.u_sched.bag_arr[0] !== (bag_us * CYCLES_PER_US)) bad("scheduler bag_arr did not commit");
      $display("T27_PROGRESS event=configured bag_us=%0d scheduler_bag_cycles=%0d expected_cycles=%0d sim_us=%0d",
               bag_us, dut.u_sched.bag_arr[0], bag_us * CYCLES_PER_US, $time / 1000);
      u_host.rd(16'h005C, rd);
      if (rd !== 32'd0) bad("CFG_ERR on official BAG slot");
      u_host.wr(16'h0008, 32'h051F);
    end
  endtask

  task check_gaps;
    input integer bag;
    integer g;
    begin
      min_gap = bag * CYCLES_PER_US;
      if (u_mon.nsof < 3) bad("need 3 SOF per BAG slot");
      for (g = 1; g < 3; g = g + 1) begin
        gap = u_mon.sof_cyc[g] - u_mon.sof_cyc[g-1];
        $display("  [bag] %0d us gap%0d=%0d cyc (min %0d max %0d)",
                 bag, g, gap, min_gap, min_gap + GAP_SLACK);
        if (gap < min_gap) bad("BAG early on wire");
        if (gap > min_gap + GAP_SLACK) bad("BAG late on wire");
      end
    end
  endtask

  initial begin
    errors = 0; deliveries = 0; mon_clr = 0; pat = 0; bag_hold = 24'd0;
    min_exp = 0;
    max_exp = 7;
    if ($value$plusargs("T27_MIN_EXP=%d", min_exp)) ;
    if ($value$plusargs("T27_MAX_EXP=%d", max_exp)) ;
    if (min_exp < 0) min_exp = 0;
    if (max_exp > 7) max_exp = 7;
    if (min_exp > max_exp) min_exp = max_exp;
    repeat (7) @(negedge clk); reset = 0;
    waitc = 0;
    while (dut.init_done !== 1 && waitc < 27000) begin @(negedge clk); waitc = waitc + 1; end
    if (waitc >= 27000) bad("INIT_DONE timeout");
    begin : csv_hdr
      integer fd;
      fd = $fopen("out/metrics/t27_bag.csv", "w");
      if (fd != 0) begin
        $fdisplay(fd, "bag_us,gap_i,gap_cyc,min_cyc");
        $fclose(fd);
      end
    end

    u_host.wr(16'h0008, 32'h2000);
    u_host.wr(16'h0060, 32'h1234_2001);
    u_host.wr(16'h0064, 32'h0A00_0001);
    u_host.wr(16'h0070, 32'h0000_0142);
    u_host.wr(16'h7D83, 32'h0000_0001);
    u_host.wr(16'h7D80, 32'h8000_C000);
    u_host.wr(16'h0078, 32'h172D);
    u_host.wr(16'h007C, 32'hAB61);
    u_host.wr(hash_addr(VLID_TX, 16'h172D, 1'b0, 1'b0), {3'd0, 1'b1, VLID_TX, VL_RX});
    u_host.wr(16'h0080, 32'h1);
    u_host.wr(16'h1F80, 32'hF500_0000 | (P_RX << 12) | 32'd79);
    u_host.wr(16'h1F81, {16'd0, VLID_TX});
    u_host.wr(PT_RX, 32'h8004_0000);
    u_host.wr(PT_RX + 1, 32'h0000_1388);
    u_host.wr(PT_RX + 2, 32'd0);
    u_host.wr(PT_RX + 3, 32'd1);

    for (exp = min_exp; exp <= max_exp; exp = exp + 1) begin
      $display("T27_PROGRESS event=slot_begin bag_us=%0d sim_us=%0d", 1000 << exp, $time / 1000);
      apply_bag(exp);
      mon_clr = 1'b1; @(negedge clk); mon_clr = 1'b0;
      send_payload(); wait_sof(1, bag_us); drain_rx;
      send_payload(); wait_sof(2, bag_us); drain_rx;
      send_payload(); wait_sof(3, bag_us); drain_rx;
      check_gaps(bag_us);
      u_mon.dump_csv("out/metrics/t27_bag.csv", bag_us);
      $display("T27_PROGRESS event=slot_complete bag_us=%0d sof=%0d errors=%0d sim_us=%0d",
               bag_us, u_mon.nsof, errors + u_host.errors + u_chk.errors + u_bag.errors, $time / 1000);
    end

    errors = errors + u_host.errors + u_chk.errors + u_bag.errors;
    if (errors == 0)
      $display("T27 BAG LEGAL PASS (IF_MODE=%0d slots %0d..%0d ms on wire)",
               IF_MODE, (1000 << min_exp) / 1000, (1000 << max_exp) / 1000);
    else
      $display("T27 BAG LEGAL FAIL (IF_MODE=%0d errors=%0d)", IF_MODE, errors);
    $finish;
  end

  initial begin
    #2_000_000_000;
    $display("T27 BAG LEGAL FAIL: timeout IF_MODE=%0d", IF_MODE);
    $finish;
  end
endmodule

module tb_s3_bag_legal;
  tb_s3_bag_legal_core #(.IF_MODE(0)) core();
endmodule
