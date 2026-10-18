// T28 / S4 — 32 VL, official 1 ms BAG, jitter on the TX wire through net_model.
// A664P7 MaxJitter is 500 us. Does not reuse T05b's 828 us / 50 us saturated oracle.
`timescale 1 ns / 1 ps
module tb_s4_vl32_jitter_core #(parameter integer IF_MODE = 0);
  localparam integer DELAY_US = 10;
  localparam integer NVL = 32;
  localparam integer LMAX = 79;
  localparam integer PLEN = 32;
  localparam integer BAG_US = 1000;
  localparam integer SHARE = 8305;
  localparam integer NUM_ROUNDS = 3;
  localparam integer BAG_CYC = BAG_US * 125;
  localparam integer JIT_MAX = 500 * 125;

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

  afdx_net_model #(.IF_MODE(IF_MODE), .DELAY_US(DELAY_US), .DEPTH(64)) u_net (
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

  integer errors, waitc, i, r, current_cycle, frames_seen, byte_cnt, vl_id;
  integer f_start_cyc, interval_cyc, max_jit, nsteady;
  integer f_last [0:NVL-1], f_cnt [0:NVL-1];
  integer first_nom [0:NVL-1];
  integer t_start, startup_delay, startup_max_delay;
  reg in_frame;
  reg [7:0] frame_bytes [0:63];
  reg [31:0] rd;
  integer blk, j, target;

  always @(posedge clk) if (!reset) current_cycle <= current_cycle + 1;

  wire byte_strobe = (IF_MODE != 0) ? tx_valid : (tx_valid && tx_ready);
  wire frame_active = (IF_MODE != 0) ? tx_valid : tx_ready;

  always @(posedge clk) if (!reset) begin
    if (byte_strobe) begin
      if (!in_frame) begin
        in_frame <= 1'b1;
        f_start_cyc = current_cycle;
        byte_cnt = 0;
      end
      if (byte_cnt < 64) frame_bytes[byte_cnt] = tx_data;
      byte_cnt = byte_cnt + 1;
    end
    if (in_frame && !frame_active) begin
      in_frame <= 1'b0;
      frames_seen = frames_seen + 1;
      vl_id = frame_bytes[5];
      if (vl_id < NVL) begin
        if (f_cnt[vl_id] == 0) begin
          if (f_start_cyc < first_nom[vl_id])
            bad("first departure before VL phase");
          else if (f_start_cyc - first_nom[vl_id] > startup_max_delay)
            startup_max_delay = f_start_cyc - first_nom[vl_id];
        end else begin
          interval_cyc = f_start_cyc - f_last[vl_id];
          if (interval_cyc < BAG_CYC) bad("BAG early on wire");
          if (interval_cyc - BAG_CYC > max_jit) max_jit = interval_cyc - BAG_CYC;
          nsteady = nsteady + 1;
        end
        f_last[vl_id] = f_start_cyc;
        f_cnt[vl_id] = f_cnt[vl_id] + 1;
      end else bad("unexpected VLID on wire");
    end
  end

  task bad;
    input [8*96-1:0] reason;
    begin
      if (errors < 25) $display("  [err] T28 t=%0t: %0s", $time, reason);
      errors = errors + 1;
    end
  endtask

  task send_msg;
    input integer port_id;
    input integer tgt;
    begin
      u_host.rd(16'h0074, rd);
      waitc = 0;
      while (!rd[4] && waitc < 50000) begin
        @(negedge clk); waitc = waitc + 1;
        u_host.rd(16'h0074, rd);
      end
      if (!rd[4]) bad("no open TX block");
      blk = rd[3:0];
      @(negedge clk);
      u_host.cs = 1'b1; u_host.we = 1'b1;
      for (j = 0; j < 8; j = j + 1)
        u_host.wr_burst_word(16'h8800 + (blk << 9) + j, 32'hA500_0000 | (port_id << 16) | j);
      u_host.cs = 1'b0; u_host.we = 1'b0;
      while (current_cycle < tgt) @(negedge clk);
      u_host.wr(16'h8280 + port_id, PLEN);
    end
  endtask

  initial begin
    errors = 0; frames_seen = 0; current_cycle = 0; in_frame = 0;
    max_jit = 0; nsteady = 0; startup_max_delay = 0;
    for (i = 0; i < NVL; i = i + 1) begin
      f_last[i] = 0; f_cnt[i] = 0; first_nom[i] = 0;
    end
    repeat (7) @(negedge clk); reset = 0;
    waitc = 0;
    while (dut.init_done !== 1 && waitc < 27000) begin @(negedge clk); waitc = waitc + 1; end
    if (waitc >= 27000) bad("INIT_DONE timeout");

    u_host.wr(16'h0008, 32'h2000);
    u_host.wr(16'h0060, 32'h1234_2001);
    u_host.wr(16'h0064, 32'h0A00_0001);
    u_host.wr(16'h0070, 32'h0000_0142);
    for (i = 0; i < NVL; i = i + 1) begin
      u_host.wr(16'h7D80 + 4*i + 3, 32'd1);
      u_host.wr(16'h7D80 + 4*i, 32'h8000_C000 | (i & 255));
      u_host.wr(16'h0200 + 5*i + 4, (i << 16));
      u_host.wr(16'h0200 + 5*i + 3, 32'hE000_0001);
      u_host.wr(16'h0200 + 5*i + 2, (16'd5000 + i) | ((16'd49152 + i) << 16));
      u_host.wr(16'h0200 + 5*i + 1, BAG_US << 8);
      u_host.wr(16'h0480 + i, SHARE);
      u_host.wr(16'h0200 + 5*i, 32'h8000_0003 | (LMAX << 12));
    end
    u_host.rd(16'h0058, rd);
    if (rd !== NVL * SHARE) bad("CFG_SUM mismatch");
    u_host.rd(16'h005C, rd);
    if (rd !== 32'd0) bad("CFG_ERR set");

    u_host.wr(16'h0008, 32'h0001);
    @(negedge clk);
    t_start = current_cycle;
    for (r = 0; r < NUM_ROUNDS; r = r + 1) begin
      for (i = 0; i < NVL; i = i + 1) begin
        if (r == 0) first_nom[i] = t_start + i * BAG_CYC / NVL;
        send_msg(i, t_start + r * BAG_CYC + i * BAG_CYC / NVL);
      end
    end

    waitc = 0;
    while (frames_seen < NUM_ROUNDS * NVL && waitc < 800000) begin
      @(negedge clk); waitc = waitc + 1;
    end
    if (frames_seen < NUM_ROUNDS * NVL) bad("did not finish 32 VL rounds");
    for (i = 0; i < NVL; i = i + 1)
      if (f_cnt[i] != NUM_ROUNDS) bad("missing frame for a VL");
    waitc = 0;
    while (fwd_a < NUM_ROUNDS * NVL && waitc < 200000) begin
      @(negedge clk); waitc = waitc + 1;
    end
    $display("  [s4] frames_seen=%0d fwd A/B=%0d/%0d startup_cyc=%0d steady_cyc=%0d",
             frames_seen, fwd_a, fwd_b, startup_max_delay, max_jit);
    if (fwd_a < NUM_ROUNDS * NVL) bad("net_model did not forward the burst");
    if (startup_max_delay > JIT_MAX) bad("startup delay above 500 us");
    if (max_jit > JIT_MAX) bad("steady jitter above 500 us");

    errors = errors + u_host.errors + u_chk.errors;
    if (errors == 0)
      $display("T28 VL32 JITTER PASS (IF_MODE=%0d BAG=1ms N=32 startup=%0dus steady=%0dus via net_model)",
               IF_MODE, (startup_max_delay + 124) / 125, (max_jit + 124) / 125);
    else
      $display("T28 VL32 JITTER FAIL (IF_MODE=%0d errors=%0d)", IF_MODE, errors);
    $finish;
  end

  initial begin
    #80_000_000;
    $display("T28 VL32 JITTER FAIL: timeout IF_MODE=%0d frames=%0d", IF_MODE, frames_seen);
    $finish;
  end
endmodule

module tb_s4_vl32_jitter;
  tb_s4_vl32_jitter_core #(.IF_MODE(0)) core();
endmodule
