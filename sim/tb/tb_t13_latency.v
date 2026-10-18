`timescale 1ns/1ps
// ---------------------------------------------------------------------
// T13 end-to-end latency (host MSG_WR -> TX MAC -> TB loopback -> RX MAC
// -> port buffer delivery).  Audit 20260928 A03: the per-case limits used
// to be passed but never compared.  Now every case is ASSERTED against:
//   TOTAL   (MSG_WR -> RX port delivery, incl. 2x wire + TB turnaround)
//           <= T13_TOTAL_MAX_US   (default 1000 us: competition guide
//              "end-to-end latency < 1-2 ms", strict end taken)
//   TX_PIPE (MSG_WR -> first TX byte)          <= T13_TX_PIPE_MAX_US
//   RX_PIPE (last RX byte in -> port delivery) <= T13_RX_PIPE_MAX_US
//           (default 150 us each: ARINC 664 P7 ES technological latency
//              as restated by XAPP1130, doc L001)
// Limits can be tightened by plusargs for the negative run, e.g.
//   run_regress.ps1 -Tests T13 -KeepWork -OutDir out/neg_t13
//                   -PlusArgs '+T13_TOTAL_MAX_US=5'   -> must FAIL
// One machine-readable "T13METRIC ..." line per case feeds the report.
// ---------------------------------------------------------------------

module tb_t13_core #(parameter integer IF_MODE = 0);

  reg clk = 0;
  reg reset = 1;
  always #4 clk = ~clk;

  reg         host_cs = 0;
  reg         host_we = 0;
  reg  [15:0] host_addr = 0;
  reg  [31:0] host_wdata = 0;
  wire [31:0] host_rdata;
  wire        host_ack;
  wire        host_irq;

  reg        rx_valid = 0, rx_valid_b = 0;
  reg        rx_ready = 1, rx_ready_b = 1;
  reg  [7:0] rx_data = 0,  rx_data_b = 0;
  wire [7:0] tx_data,      tx_data_b;
  wire       tx_valid,     tx_valid_b;
  wire       tx_ready,     tx_ready_b;

  AFDX_top #(
    .IF_MODE(IF_MODE),
    .FCS_MODE(2)
  ) dut (
    .rx_error(1'b0), .rx_error_b(1'b0),
    .clk(clk),
    .reset(reset),
    .tx_data(tx_data),
    .rx_data(rx_data),
    .tx_valid(tx_valid),
    .rx_valid(rx_valid),
    .tx_ready(tx_ready),
    .rx_ready(rx_ready),
    .tx_data_b(tx_data_b),
    .tx_valid_b(tx_valid_b),
    .tx_ready_b(tx_ready_b),
    .rx_data_b(rx_data_b),
    .rx_valid_b(rx_valid_b),
    .rx_ready_b(rx_ready_b),
    .host_cs(host_cs),
    .host_we(host_we),
    .host_addr(host_addr),
    .host_wdata(host_wdata),
    .host_rdata(host_rdata),
    .host_ack(host_ack),
    .host_irq(host_irq),
    .pps_in(1'b0),
    .pps_out(),
    .rtc_time_us(),
    .dbg_frame_event()
  );

  localparam integer P_TX = 0;
  localparam integer P_RX = 5;
  localparam [11:0]  VL_RX = 12'h100;
  localparam [15:0]  PT_RX = 16'h7D80 + 4*P_RX;
  localparam [15:0]  VLID_TX = 16'h0100;

  reg [31:0] err_count = 0;
  reg [31:0] test_count = 0;

  // ---- latency limits (see header); plusargs override for negative runs
  integer total_max_us   = 1000;
  integer tx_pipe_max_us = 150;
  integer rx_pipe_max_us = 150;
  reg [63:0] worst_total_ns = 0;
  initial begin
    if ($value$plusargs("T13_TOTAL_MAX_US=%d", total_max_us)) ;
    if ($value$plusargs("T13_TX_PIPE_MAX_US=%d", tx_pipe_max_us)) ;
    if ($value$plusargs("T13_RX_PIPE_MAX_US=%d", rx_pipe_max_us)) ;
  end

  task bad;
    input [255:0] msg;
    begin
      $display("  [err] T13 t=%0t: %0s", $time, msg);
      err_count = err_count + 1;
    end
  endtask

  task host_write;
    input [15:0] addr;
    input [31:0] data;
    begin
      @(negedge clk);
      host_cs = 1; host_we = 1; host_addr = addr; host_wdata = data;
      @(negedge clk);
      if (host_ack !== 1'b1) bad("host write ACK missing");
      host_cs = 0; host_we = 0;
    end
  endtask

  task host_read;
    input [15:0] addr;
    output [31:0] data;
    begin
      @(negedge clk);
      host_cs = 1; host_we = 0; host_addr = addr;
      @(negedge clk);
      if (host_ack !== 1'b1) bad("host read ACK missing");
      data = host_rdata;
      host_cs = 0;
    end
  endtask

  function [10:0] mix_bucket(input [15:0] vlid, input [15:0] seed, input table_id);
    reg [15:0] x;
    begin
      x = vlid + seed + (table_id ? 16'h1F5B : 16'h9E37);
      x = x ^ (x >> 7);
      x = x * (table_id ? 16'h45D9 : 16'h9E37);
      x = x ^ (x >> 9);
      mix_bucket = x & 11'h7FF;
    end
  endfunction
  function [15:0] hash_addr(input [15:0] vlid, input [15:0] seed, input table_id, input way);
    begin hash_addr = 16'h3D80 + ({4'd0,table_id} << 12) + (mix_bucket(vlid,seed,table_id) << 1) + way; end
  endfunction

  reg [7:0] ca [0:2047], cb [0:2047];
  integer na = 0, nb = 0;
  reg [7:0] rxbuf_a [0:2047], rxbuf_b [0:2047];
  integer nrx_a = 0, nrx_b = 0;
  integer deliveries = 0;

  reg [63:0] current_cycle;
  always @(posedge clk) begin
    if (reset) current_cycle <= 0;
    else current_cycle <= current_cycle + 1;
  end

  reg [63:0] t_commit, t_tx_first, t_tx_last, t_port_ready;
  reg [63:0] t_rxa_first, t_rxa_last, t_rxb_first, t_rxb_last;
  reg tx_active;

  always @(posedge clk) if (!reset) begin
    if (tx_valid && (IF_MODE != 0 || tx_ready)) begin
      if (!tx_active) begin
        tx_active <= 1'b1;
        t_tx_first <= current_cycle;
      end
      t_tx_last <= current_cycle;
      ca[na] = tx_data;
      na = na + 1;
    end
    if (tx_valid_b && (IF_MODE != 0 || tx_ready_b)) begin
      cb[nb] = tx_data_b;
      nb = nb + 1;
    end
    if (dut.prs_out_vld && dut.pb_in_ready && !dut.prs_out_drop) begin
      deliveries <= deliveries + 1;
    end
  end

  task replay_a;
    integer b;
    begin
      repeat (2) @(negedge clk);
      for (b = 0; b < nrx_a; b = b + 1) begin
        @(negedge clk); rx_ready = 1; rx_valid = 1; rx_data = rxbuf_a[b];
        if (b == 0) t_rxa_first = current_cycle;
        t_rxa_last = current_cycle;
        if (IF_MODE == 0) begin @(negedge clk); rx_valid = 0; repeat (8) @(negedge clk); end
      end
      @(negedge clk); rx_ready = 0; rx_valid = 0;
      repeat (4) @(negedge clk); rx_ready = 1;
    end
  endtask

  task replay_b;
    integer b;
    begin
      repeat (8) @(negedge clk);
      for (b = 0; b < nrx_b; b = b + 1) begin
        @(negedge clk); rx_ready_b = 1; rx_valid_b = 1; rx_data_b = rxbuf_b[b];
        if (b == 0) t_rxb_first = current_cycle;
        t_rxb_last = current_cycle;
        if (IF_MODE == 0) begin @(negedge clk); rx_valid_b = 0; repeat (8) @(negedge clk); end
      end
      @(negedge clk); rx_ready_b = 0; rx_valid_b = 0;
      repeat (4) @(negedge clk); rx_ready_b = 1;
    end
  endtask

  task measure_frame_case;
    input [31:0] test_id;
    input [10:0] plen;
    input [31:0] expected_wire_bytes;

    integer i, k, waitc, blk, prev_deliv;
    reg [31:0] rd, w;
    reg [15:0] word_addr;
    reg [7:0]  actual_byte, exp_byte;
    reg [63:0] rx_first, rx_last;
    reg [63:0] tx_pipe_ns, tx_wire_ns, tb_gap_ns, rx_wire_ns, rx_pipe_ns, total_ns, es_ns;
    begin
      test_count = test_count + 1;
      prev_deliv = deliveries;

      // 1. Host allocates open TX block
      waitc = 0;
      host_read(16'h0074, rd);
      while (!rd[4] && waitc < 50000) begin
        @(negedge clk); waitc = waitc + 1;
        host_read(16'h0074, rd);
      end
      if (!rd[4]) bad("No free TX PMEM block available");
      blk = rd[3:0];

      // Write payload pattern: byte j = (test_id*17 + j) & 255
      for (i = 0; i < (plen + 3) / 4; i = i + 1) begin
        w = { (8'((test_id*17 + 4*i + 0) & 255)),
              (8'((test_id*17 + 4*i + 1) & 255)),
              (8'((test_id*17 + 4*i + 2) & 255)),
              (8'((test_id*17 + 4*i + 3) & 255)) };
        host_write(16'h8800 + (blk << 9) + i, w);
      end

      // Reset capture state
      na = 0; nb = 0;
      tx_active = 0;
      t_commit = 0;
      t_tx_first = 0;
      t_tx_last = 0;
      t_rxa_first = 0; t_rxa_last = 0; t_rxb_first = 0; t_rxb_last = 0;

      // 2. Commit message via MSG_WR
      @(negedge clk);
      t_commit = current_cycle;
      host_write(16'h8280 + P_TX, plen);

      // Wait for transmission to finish on both MACs
      waitc = 0;
      while ((na < expected_wire_bytes || nb < expected_wire_bytes) && waitc < 500000) begin
        @(negedge clk); waitc = waitc + 1;
      end
      if (na < expected_wire_bytes || nb < expected_wire_bytes) begin
        bad("Timeout waiting for MAC TX capture");
      end

      // 3. Replay captured frame into RX MAC
      nrx_a = na;
      nrx_b = nb;
      for (i = 0; i < na; i = i + 1) rxbuf_a[i] = ca[i];
      for (i = 0; i < nb; i = i + 1) rxbuf_b[i] = cb[i];

      fork
        replay_a;
        replay_b;
      join

      // Wait for RX delivery to port buffer
      waitc = 0;
      while (dut.u_rxpb.deliver_cnt <= prev_deliv && waitc < 250000) begin
        @(negedge clk); waitc = waitc + 1;
      end
      if (dut.u_rxpb.deliver_cnt <= prev_deliv) begin
        bad("Timeout waiting for frame delivery");
      end
      t_port_ready = current_cycle;

      // 4. Host readback from P_RX
      host_read(16'h8480 + P_RX, rd); // MSG_CNT
      if (rd == 0) bad("MSG_CNT is zero after delivery");
      host_read(16'h8180 + P_RX, rd); // PORT_DESC
      if (rd[31] !== 1'b1 || rd[10:0] !== plen) bad("PORT_DESC mismatch");
      blk = rd[23:20];

      // Verify payload bytes in RX PMEM
      for (i = 10; i < 10 + (plen + 3) / 4; i = i + 1) begin
        word_addr = 16'h8800 + (blk << 9) + i;
        host_read(word_addr, w);
        for (k = 0; k < 4; k = k + 1) begin
          if (4*i + k >= 42 && 4*i + k < 42 + plen) begin
            actual_byte = w[31 - 8*k -: 8];
            exp_byte = (test_id*17 + (4*i + k - 42)) & 255;
            if (actual_byte !== exp_byte) begin
              bad("Payload byte mismatch in PMEM");
            end
          end
        end
      end

      // Free RX block
      host_write(16'h8380 + P_RX, 32'd0);

      // Latency decomposition (clk = 125 MHz -> 8 ns per cycle).
      // The copy that finishes first (net A, replayed first) is the one RM
      // forwards, so RX_PIPE is measured from the earliest RX completion.
      rx_first = (t_rxb_first != 0 && t_rxb_first < t_rxa_first) ? t_rxb_first : t_rxa_first;
      rx_last  = (t_rxb_last  != 0 && t_rxb_last  < t_rxa_last ) ? t_rxb_last  : t_rxa_last;
      if (!(t_commit < t_tx_first && t_tx_first <= t_tx_last && t_tx_last < rx_first &&
            rx_first <= rx_last && rx_last < t_port_ready)) begin
        bad("latency timestamps out of order");
        tx_pipe_ns = 0; tx_wire_ns = 0; tb_gap_ns = 0; rx_wire_ns = 0; rx_pipe_ns = 0;
        total_ns = 0; es_ns = 0;
      end else begin
        tx_pipe_ns = (t_tx_first - t_commit) * 8;
        tx_wire_ns = (t_tx_last - t_tx_first + 1) * 8;
        tb_gap_ns  = (rx_first - t_tx_last) * 8;       // TB turnaround, not DUT
        rx_wire_ns = (rx_last - rx_first + 1) * 8;
        rx_pipe_ns = (t_port_ready - rx_last) * 8;
        total_ns   = (t_port_ready - t_commit) * 8;
        es_ns      = total_ns - tb_gap_ns;             // DUT-only share
        if (total_ns > worst_total_ns) worst_total_ns = total_ns;
        if (total_ns   > total_max_us   * 64'd1000) bad("TOTAL latency over limit");
        if (tx_pipe_ns > tx_pipe_max_us * 64'd1000) bad("TX_PIPE latency over limit");
        if (rx_pipe_ns > rx_pipe_max_us * 64'd1000) bad("RX_PIPE latency over limit");
      end

      $display("  [T13 CASE %0d] Plen=%0dB (Frame=%0dB): TX_pipe=%0dns TX_wire=%0dns TB_gap=%0dns RX_wire=%0dns RX_pipe=%0dns ES(excl TB)=%0dns Total=%0dns (limits total/tx/rx=%0d/%0d/%0dus)",
               test_id, plen, expected_wire_bytes, tx_pipe_ns, tx_wire_ns, tb_gap_ns, rx_wire_ns,
               rx_pipe_ns, es_ns, total_ns, total_max_us, tx_pipe_max_us, rx_pipe_max_us);
      $display("T13METRIC if_mode=%0d case=%0d plen=%0d frame=%0d tx_pipe_ns=%0d tx_wire_ns=%0d tb_gap_ns=%0d rx_wire_ns=%0d rx_pipe_ns=%0d es_ns=%0d total_ns=%0d total_max_us=%0d tx_pipe_max_us=%0d rx_pipe_max_us=%0d",
               IF_MODE, test_id, plen, expected_wire_bytes, tx_pipe_ns, tx_wire_ns, tb_gap_ns,
               rx_wire_ns, rx_pipe_ns, es_ns, total_ns, total_max_us, tx_pipe_max_us, rx_pipe_max_us);
    end
  endtask

  integer waitc;
  reg [31:0] rd;

  initial begin
    repeat (7) @(negedge clk);
    reset = 0;

    // 0. Wait for init_done
    waitc = 0;
    while (dut.init_done !== 1 && waitc < 27000) begin
      @(negedge clk); waitc = waitc + 1;
    end
    if (waitc >= 27000) bad("INIT_DONE timeout");

    // 1. Enter CFG_MODE
    host_write(16'h0008, 32'h2000);

    host_write(16'h0060, 32'h1234_2001); // UDI=0x1234, IFID A=1/B=2
    host_write(16'h0064, 32'h0A00_0001); // SRC IP
    host_write(16'h0070, 32'h0000_0142); // UDP checksum

    // TX Port 0
    host_write(16'h7D83, 32'h0000_0001); // depth 1
    host_write(16'h7D80, 32'h8000_C000); // valid, sampling, sport 49152

    // TX VL0
    host_write(16'h0204, 32'h0000_0000); // port_base=0
    host_write(16'h0203, 32'hE000_0001); // dst_ip
    host_write(16'h0202, 32'h1388_C000); // dp=5000, sp=49152
    host_write(16'h0201, 32'h0000_0100); // small BAG for fast turnaround test
    host_write(16'h0480, 32'd15949);     // Q20 share
    host_write(16'h0200, 32'h8000_0003 | (1518 << 12)); // valid, Lmax=1518, net A+B

    // RX Hash table
    host_write(16'h0078, 32'h172D);
    host_write(16'h007C, 32'hAB61);
    host_write(hash_addr(VLID_TX, 16'h172D, 1'b0, 1'b0), {3'd0, 1'b1, VLID_TX, VL_RX});
    host_write(16'h0080, 32'h1); // commit hash mirror

    // RX VL table
    host_write(16'h1F80, 32'hF500_0000 | (P_RX << 12) | 32'd1518);
    host_write(16'h1F81, {16'd0, VLID_TX});

    // RX Port table
    host_write(PT_RX + 0, 32'h8004_0000);
    host_write(PT_RX + 1, 32'h0000_1388); // dp=5000
    host_write(PT_RX + 2, 32'd0);
    host_write(PT_RX + 3, 32'd1);

    // Run mode (CTL: TX_EN, RX_EN, IC_EN, RM_EN, CFG_MODE=0 -> 0x051F)
    host_write(16'h0008, 32'h051F);
    @(negedge clk);

    #1000;

    // Case 1: Minimum AFDX payload (Plen = 17 bytes, Frame = 64 bytes)
    measure_frame_case(1, 17, 64);

    // Case 2: Typical medium payload (Plen = 256 bytes, Frame = 303 bytes)
    measure_frame_case(2, 256, 303);

    // Case 3: Maximum Ethernet MTU payload (Plen = 1471 bytes, Frame = 1518 bytes)
    measure_frame_case(3, 1471, 1518);

    #1000;
    if (err_count == 0) begin
      $display("T13 END-TO-END LATENCY PASS (IF_MODE=%0d cases=%0d asserted total<=%0dus tx_pipe<=%0dus rx_pipe<=%0dus worst_total=%0dns)",
               IF_MODE, test_count, total_max_us, tx_pipe_max_us, rx_pipe_max_us, worst_total_ns);
    end else begin
      $display("T13 LATENCY FAIL (IF_MODE=%0d errors=%0d)", IF_MODE, err_count);
    end
    $finish;
  end

endmodule

module tb_t13_latency;  tb_t13_core #(.IF_MODE(0)) core(); endmodule
module tb_t13g_latency; tb_t13_core #(.IF_MODE(1)) core(); endmodule
