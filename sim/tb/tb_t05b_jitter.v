// =====================================================================
// tb_t05b_jitter.v -- Saturated load jitter measurement (T05b / T05bg)
// 32 VLs configured with saturated load (Lmax=303B, payload=256B, BAG=828us,
// Q20 share = 32724 per VL, total = 1047168 / 2^20 = 99.86% load).
// Measures first-departure delay relative to EACH VL's staggered phase, plus
// steady-state inter-frame departure interval jitter against ARINC 664P7
// bound (MaxJitter <= 500 us) and engineering target (steady <= 30 us).
// =====================================================================
`timescale 1 ns / 1 ps
module tb_t05b_core #(parameter integer IF_MODE=0);
  localparam integer NVL = 32;
  localparam integer LMAX = 303;
  localparam integer PLEN = 256;
  localparam integer BAG_US = 828;
  localparam [31:0] SHARE_Q20 = 32'd32724;
  localparam integer NUM_ROUNDS = 3;

  reg clk = 0, reset = 1;
  always #4 clk = ~clk; // 125 MHz

  reg host_cs = 0, host_we = 0;
  reg [15:0] host_addr = 0;
  reg [31:0] host_wdata = 0;
  wire [31:0] host_rdata;
  wire host_ack, host_irq;

  wire [7:0] tx_data, tx_data_b;
  wire tx_valid, tx_valid_b, tx_ready, tx_ready_b;

  AFDX_top #(.IF_MODE(IF_MODE), .FCS_MODE(2)) dut (
    .rx_error(1'b0), .rx_error_b(1'b0),
    .clk(clk), .reset(reset),
    .tx_data(tx_data), .rx_data(8'd0), .tx_valid(tx_valid), .rx_valid(1'b0),
    .tx_ready(tx_ready), .rx_ready(1'b1),
    .tx_data_b(tx_data_b), .tx_valid_b(tx_valid_b), .tx_ready_b(tx_ready_b),
    .rx_data_b(8'd0), .rx_valid_b(1'b0), .rx_ready_b(1'b1),
    .host_cs(host_cs), .host_we(host_we), .host_addr(host_addr), .host_wdata(host_wdata),
    .host_rdata(host_rdata), .host_ack(host_ack), .host_irq(host_irq),
    .pps_in(1'b0), .pps_out(), .rtc_time_us(), .dbg_frame_event());

  integer errors = 0;
  integer frames_seen = 0;
  integer current_cycle = 0;
  always @(posedge clk) current_cycle <= current_cycle + 1;

  // Frame departure tracking per VL
  integer f_first_seen [0:NVL-1];
  integer f_last_seen [0:NVL-1];
  integer f_count [0:NVL-1];
  integer first_nominal_cyc [0:NVL-1];
  integer f_start_cyc;
  reg in_frame = 0;
  reg [7:0] frame_bytes [0:512];
  integer byte_cnt = 0;
  integer vl_id;

  // Jitter statistics
  integer startup_max_cyc = 0, startup_min_cyc = 0;
  integer startup_jitter_us = 0;
  integer startup_max_delay_cyc = 0;
  integer max_steady_jitter_cyc = 0;
  integer total_steady_jitter_cyc = 0;
  integer steady_intervals = 0;
  integer interval_cyc;
  integer expected_bag_cyc = BAG_US * 125; // 828 us * 125 cycles/us = 103500 cycles

  task bad(input [8*96-1:0] reason);
    begin
      if (errors < 20) $display("  [err] T05b t=%0t: %0s", $time, reason);
      errors = errors + 1;
    end
  endtask

  task host_write(input [15:0] addr, input [31:0] data);
    begin
      @(negedge clk); host_cs <= 1'b1; host_we <= 1'b1; host_addr <= addr; host_wdata <= data;
      @(negedge clk);
      if (host_ack !== 1'b1) bad("host write ACK missing");
      host_cs <= 1'b0; host_we <= 1'b0;
    end
  endtask

  task host_read(input [15:0] addr, output [31:0] data);
    begin
      @(negedge clk); host_cs <= 1'b1; host_we <= 1'b0; host_addr <= addr;
      @(negedge clk);
      if (host_ack !== 1'b1) bad("host read ACK missing");
      data = host_rdata; host_cs <= 1'b0;
    end
  endtask

  // Monitor wire transmission
  wire frame_active = (IF_MODE != 0) ? tx_valid : tx_ready;
  wire byte_strobe  = (IF_MODE != 0) ? tx_valid : (tx_valid && tx_ready);

  always @(posedge clk) if (!reset) begin
    if (byte_strobe) begin
      if (!in_frame) begin
        in_frame <= 1'b1;
        f_start_cyc = current_cycle;
        byte_cnt = 0;
      end
      if (byte_cnt < 512) frame_bytes[byte_cnt] = tx_data;
      byte_cnt = byte_cnt + 1;
    end

    if (in_frame && !frame_active) begin
      in_frame <= 1'b0;
      frames_seen = frames_seen + 1;
      vl_id = frame_bytes[5]; // DMAC low byte / VL ID
      if (vl_id < NVL) begin
        if (f_count[vl_id] == 0) begin
          f_first_seen[vl_id] = f_start_cyc;
          if (startup_min_cyc == 0 || f_start_cyc < startup_min_cyc) startup_min_cyc = f_start_cyc;
          if (f_start_cyc > startup_max_cyc) startup_max_cyc = f_start_cyc;
          if (f_start_cyc < first_nominal_cyc[vl_id])
            bad("First departure before this VL's scheduled phase");
          else if (f_start_cyc - first_nominal_cyc[vl_id] > startup_max_delay_cyc)
            startup_max_delay_cyc = f_start_cyc - first_nominal_cyc[vl_id];
        end else begin
          interval_cyc = f_start_cyc - f_last_seen[vl_id];
          if (interval_cyc < expected_bag_cyc - 20) begin
            bad("BAG violation: inter-frame interval below BAG");
          end
          if (interval_cyc >= expected_bag_cyc) begin
            if ((interval_cyc - expected_bag_cyc) > max_steady_jitter_cyc)
              max_steady_jitter_cyc = interval_cyc - expected_bag_cyc;
            total_steady_jitter_cyc = total_steady_jitter_cyc + (interval_cyc - expected_bag_cyc);
          end else begin
            if ((expected_bag_cyc - interval_cyc) > max_steady_jitter_cyc)
              max_steady_jitter_cyc = expected_bag_cyc - interval_cyc;
            total_steady_jitter_cyc = total_steady_jitter_cyc + (expected_bag_cyc - interval_cyc);
          end
          steady_intervals = steady_intervals + 1;
        end
        f_last_seen[vl_id] = f_start_cyc;
        f_count[vl_id] = f_count[vl_id] + 1;
      end else begin
        bad("Unexpected VL ID on wire");
      end
    end
  end

  task send_message(input integer port_id, input integer len, input integer target_cyc);
    integer j, waitc, blk;
    reg [31:0] rd;
    begin
      // Read open TX block
      waitc = 0;
      host_read(16'h0074, rd);
      while (!rd[4] && waitc < 50000) begin
        @(negedge clk); waitc = waitc + 1;
        host_read(16'h0074, rd);
      end
      if (!rd[4]) bad("No free TX PMEM block available");
      blk = rd[3:0];

      // Write payload into allocated TX PMEM block
      for (j = 0; j < (len + 3)/4; j = j + 1) begin
        host_write(16'h8800 + (blk << 9) + j, 32'hA500_0000 | (port_id << 16) | j);
      end

      // Stagger the actual MSG_WR, not just the start of payload preparation.
      while (current_cycle < target_cyc) @(negedge clk);
      // Commit via MSG_WR (0x8280 + port_id)
      host_write(16'h8280 + port_id, len);
    end
  endtask

  integer i, r, waitc, t_start_cyc;
  reg [31:0] rd;

  initial begin
    for (i = 0; i < NVL; i = i + 1) begin
      f_first_seen[i] = 0; f_last_seen[i] = 0; f_count[i] = 0;
      first_nominal_cyc[i] = 0;
    end

    repeat (7) @(negedge clk); reset <= 1'b0;
    waitc = 0;
    while (dut.init_done !== 1'b1 && waitc < 27000) begin @(negedge clk); waitc = waitc + 1; end
    if (waitc >= 27000) bad("INIT_DONE timeout");

    // Enter configuration mode
    host_write(16'h0008, 32'h2000); // CFG_MODE=1
    host_write(16'h0060, 32'h1234_2001); // UDI=0x1234, IFID A=1/B=2
    host_write(16'h0064, 32'h0A00_0001); // SRC IP
    host_write(16'h0070, 32'h0000_0142); // UDP CSUM EN

    // Configure 32 VLs and ports
    for (i = 0; i < NVL; i = i + 1) begin
      host_write(16'h7D80 + 4*i + 3, 32'h0000_0001); // port depth = 1
      host_write(16'h7D80 + 4*i, 32'h8000_C000 | (i & 255)); // valid, sampling, sport=49152+i
      host_write(16'h0200 + 5*i + 4, (i << 16)); // port_base = i in [23:16]
      host_write(16'h0200 + 5*i + 3, 32'hE000_0001); // dst_ip
      host_write(16'h0200 + 5*i + 2, (16'd5000 + i) | ((16'd49152 + i) << 16)); // sport/dport
      host_write(16'h0200 + 5*i + 1, BAG_US << 8); // BAG = 828 us
      host_write(16'h0480 + i, SHARE_Q20); // Q20 share = 32724
      host_write(16'h0200 + 5*i, 32'h8000_0003 | (LMAX << 12)); // valid, Lmax=303, net A+B (written LAST!)
    end

    host_read(16'h0058, rd);
    if (rd !== 32'd1047168) bad("CFG_SUM mismatch for 32 saturated VLs");
    host_read(16'h005C, rd);
    if (rd !== 32'd0) bad("CFG_ERR should be 0 for valid saturated configuration");

    // Enable transmission
    host_write(16'h0008, 32'h1); // TX_EN=1
    @(negedge clk);
    t_start_cyc = current_cycle;

    // Each VL has its own phase i*BAG/NVL, repeated every BAG. The initial
    // first-frame span includes these deliberate offsets: do NOT call it jitter.
    for (r = 0; r < NUM_ROUNDS; r = r + 1) begin
      for (i = 0; i < NVL; i = i + 1) begin
        if (r == 0) first_nominal_cyc[i] = t_start_cyc + i * expected_bag_cyc / NVL;
        send_message(i, PLEN, t_start_cyc + r * expected_bag_cyc +
                              i * expected_bag_cyc / NVL);
      end
    end

    // Wait for all frames to finish transmitting
    waitc = 0;
    while (frames_seen < NUM_ROUNDS * NVL && waitc < 500000) begin
      @(negedge clk); waitc = waitc + 1;
    end
    if (frames_seen < NUM_ROUNDS * NVL) bad("Did not complete all rounds");

    for (i = 0; i < NVL; i = i + 1)
      if (f_count[i] != NUM_ROUNDS) bad("Missing/extra frame for a VL");
    if (steady_intervals != (NUM_ROUNDS-1)*NVL) bad("Missing/extra steady interval");
    startup_jitter_us = (startup_max_delay_cyc + 124) / 125; // ceil for display
    $display("  [T05b INFO] Round 1: max per-VL phase-to-departure delay=%0d us (bound <= 500 us); raw first-departure span=%0d us (includes deliberate phase offsets)",
             startup_jitter_us, (startup_max_cyc - startup_min_cyc) / 125);

    if (startup_max_delay_cyc > 500*125) bad("Startup phase-to-departure delay exceeded 500 us");
    if (max_steady_jitter_cyc > 50*125) bad("Steady state jitter exceeded 50 us upper limit");

    if (errors == 0) begin
      $display("T05b SATURATED JITTER PASS (IF_MODE=%0d VLs=32 frames=%0d startup_jitter=%0dus steady_max_jitter=%0dus avg_steady_jitter=%0dus link_load=99.86%%)",
               IF_MODE, frames_seen, startup_jitter_us, max_steady_jitter_cyc / 125,
               steady_intervals > 0 ? (total_steady_jitter_cyc / steady_intervals) / 125 : 0);
    end else begin
      $display("T05b SATURATED JITTER FAIL (IF_MODE=%0d errors=%0d)", IF_MODE, errors);
    end
    $finish;
  end

  initial begin
    #180_000_000;
    $display("T05b TIMEOUT (IF_MODE=%0d frames_seen=%0d)", IF_MODE, frames_seen);
    $finish;
  end
endmodule

module tb_t05b_jitter;  tb_t05b_core #(.IF_MODE(0)) core(); endmodule
module tb_t05bg_jitter; tb_t05b_core #(.IF_MODE(1)) core(); endmodule
