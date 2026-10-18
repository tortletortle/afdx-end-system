// T30 / S6 — e2e latency through net_model (10 us store-and-forward).
// Does not change T13's TB-fork oracles. Bounds: total < 2 ms (guide),
// TX pipe < 150 us, switch path >= DELAY_US.
`timescale 1 ns / 1 ps
module tb_s6_latency_core #(
  parameter integer IF_MODE = 0,
  parameter integer DELAY_US = 10,
  parameter integer TOTAL_MAX_US = 2000
);
  localparam integer P_RX = 5;
  localparam integer P_TX = 0;
  localparam [11:0]  VL_RX = 12'h100;
  localparam [15:0]  PT_RX = 16'h7D80 + 4*P_RX;
  localparam [15:0]  VLID_TX = 16'h0100;
  localparam integer PLEN = 32;
  localparam integer NFR = 4;
  localparam integer BAG_US = 1000;
  localparam integer TOTAL_MAX = TOTAL_MAX_US * 125;
  localparam integer TX_MAX = 150 * 125;
  localparam integer SW_MIN = DELAY_US * 125;

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

  afdx_chk_mac #(.IF_MODE(IF_MODE)) u_chk (
    .clk(clk), .rst(reset),
    .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready));

  integer errors, waitc, i, n, current_cycle, deliveries, nsof;
  integer t_wr, t_sof, t_del, txp, swp, tot;
  integer tot_min, tot_max, tot_sum;
  integer tx_min, tx_max, sw_min, sw_max;
  integer sof_cyc [0:7];
  integer del_cyc [0:7];
  reg in_frm;
  reg [31:0] rd;
  integer blk, base_addr;
  wire take = tx_valid && ((IF_MODE != 0) || tx_ready);

  always @(posedge clk) if (!reset) begin
    current_cycle = current_cycle + 1;
    if (dut.prs_out_vld && dut.pb_in_ready && !dut.prs_out_drop) begin
      if (deliveries < 8) del_cyc[deliveries] = current_cycle;
      deliveries = deliveries + 1;
    end
    if (take) begin
      if (!in_frm) begin
        in_frm <= 1'b1;
        if (nsof < 8) sof_cyc[nsof] = current_cycle;
        nsof = nsof + 1;
      end
    end else if (in_frm && !(tx_valid && ((IF_MODE != 0) || tx_ready))) begin
      if (IF_MODE == 0 && !tx_ready) in_frm <= 1'b0;
      if (IF_MODE != 0 && !tx_valid) in_frm <= 1'b0;
    end
  end

  task bad;
    input [8*96-1:0] reason;
    begin
      if (errors < 25) $display("  [err] T30 t=%0t: %0s", $time, reason);
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
        u_host.wr_burst_word(base_addr + i, 32'hA0B0_C0D0 + i);
      u_host.cs = 1'b0; u_host.we = 1'b0;
      t_wr = current_cycle;
      u_host.wr(16'h8280 + P_TX, PLEN);
    end
  endtask

  initial begin
    errors = 0; deliveries = 0; nsof = 0; current_cycle = 0; in_frm = 0;
    tot_min = 32'h7fff_ffff; tot_max = 0; tot_sum = 0;
    tx_min = 32'h7fff_ffff; tx_max = 0;
    sw_min = 32'h7fff_ffff; sw_max = 0;
    repeat (7) @(negedge clk); reset = 0;
    waitc = 0;
    while (dut.init_done !== 1 && waitc < 27000) begin @(negedge clk); waitc = waitc + 1; end
    if (waitc >= 27000) bad("INIT_DONE timeout");

    u_host.wr(16'h0008, 32'h2000);
    u_host.wr(16'h0060, 32'h1234_2001);
    u_host.wr(16'h0064, 32'h0A00_0001);
    u_host.wr(16'h0070, 32'h0000_0142);
    u_host.wr(16'h7D83, 32'h0000_0001);
    u_host.wr(16'h7D80, 32'h8000_C000);
    u_host.wr(16'h0204, 32'h0000_0000);
    u_host.wr(16'h0203, 32'hE000_0001);
    u_host.wr(16'h0202, 32'h1388_C000);
    u_host.wr(16'h0201, 32'h0003_E800);
    u_host.wr(16'h0480, 32'd8305);
    u_host.wr(16'h0200, 32'h8004_F003);
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
    u_host.wr(16'h0008, 32'h051F);

    for (n = 0; n < NFR; n = n + 1) begin
      send_payload();
      waitc = 0;
      while (deliveries < n + 1 && waitc < 400000) begin
        @(negedge clk); waitc = waitc + 1;
      end
      if (deliveries < n + 1) bad("delivery timeout");
      t_sof = sof_cyc[n];
      t_del = del_cyc[n];
      txp = t_sof - t_wr;
      swp = t_del - t_sof;
      tot = t_del - t_wr;
      $display("  [s6] f%0d tx=%0dus sw=%0dus tot=%0dus",
               n, (txp + 124) / 125, (swp + 124) / 125, (tot + 124) / 125);
      if (n == 0 && (txp < 0 || txp > TX_MAX)) bad("TX pipe out of bound");
      if (swp < SW_MIN) bad("switch path shorter than DELAY_US");
      // Internal acceptance rule for this declared 1 ms BAG scenario:
      // every measured t_wr-to-delivery total must be strictly below the
      // configured total bound. Keep BAG wait visible in this measurement.
      // Keep BAG wait visible in the total; do not grant later frames an
      // extra BAG of latency.
      if (tot >= TOTAL_MAX) bad("e2e is not strictly below 2 ms");
      if (tot < tot_min) tot_min = tot;
      if (tot > tot_max) tot_max = tot;
      tot_sum = tot_sum + tot;
      if (txp < tx_min) tx_min = txp;
      if (txp > tx_max) tx_max = txp;
      if (swp < sw_min) sw_min = swp;
      if (swp > sw_max) sw_max = swp;
      u_host.wr(16'h8380 + P_RX, 32'd0);
    end

    errors = errors + u_host.errors + u_chk.errors;
    if (errors == 0)
      $display("T30 LATENCY PASS (IF_MODE=%0d DELAY_US=%0d tot %0d..%0d us avg %0d us)",
               IF_MODE, DELAY_US, (tot_min + 124) / 125, (tot_max + 124) / 125,
               ((tot_sum / NFR) + 124) / 125);
    else
      $display("T30 LATENCY FAIL (IF_MODE=%0d errors=%0d)", IF_MODE, errors);
    $finish;
  end

  initial begin
    #40_000_000;
    $display("T30 LATENCY FAIL: timeout IF_MODE=%0d", IF_MODE);
    $finish;
  end
endmodule

module tb_s6_latency;
  tb_s6_latency_core #(.IF_MODE(0)) core();
endmodule

// Intentional negative control: the network delay alone exceeds the 2 ms
// end-to-end bound, so the ordinary T30 verdict must be FAIL.
module tb_s6_latency_negative;
  tb_s6_latency_core #(.IF_MODE(0), .DELAY_US(2100), .TOTAL_MAX_US(2000)) core();
endmodule
