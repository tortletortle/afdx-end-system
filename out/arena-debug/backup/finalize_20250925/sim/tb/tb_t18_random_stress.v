`timescale 1ns/1ps

module tb_t18_core #(parameter integer IF_MODE = 0);

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

  localparam integer NUM_TEST_PORTS = 4;
  localparam integer NUM_ROUNDS = 25; // 25 rounds * 4 ports = 100 frames

  reg [31:0] err_count = 0;
  reg [31:0] test_count = 0;
  // Reproducible RNG: override with +T18_SEED=<hex> in a direct vsim run.
  reg [31:0] initial_seed;
  integer rng_seed;
  reg [31:0] rng_first;
  integer min_plen=1471, max_plen=17, stalled_frames=0, spaced_frames=0;
  integer extra_gap=0, stall_cycles=0, skew_a=0, skew_b=0, payload_salt=0;
  integer idle_cycles, bp_wait;
  function integer draw(input integer count);
    reg [31:0] bits;
    // Questa's $urandom(seed) RESEEDS on every call; seed only once below.
    begin bits=$urandom(); draw=bits % count; end
  endfunction

  task bad;
    input [255:0] msg;
    begin
      $display("  [err] T18 t=%0t: %0s", $time, msg);
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

  always @(posedge clk) if (!reset) begin
    if (tx_valid && (IF_MODE != 0 || tx_ready)) begin
      ca[na] = tx_data;
      na = na + 1;
    end
    if (tx_valid_b && (IF_MODE != 0 || tx_ready_b)) begin
      cb[nb] = tx_data_b;
      nb = nb + 1;
    end
  end

  task replay_a(input integer start_skew);
    integer b;
    begin
      repeat (start_skew) @(negedge clk);
      for (b = 0; b < nrx_a; b = b + 1) begin
        @(negedge clk); rx_ready = 1; rx_valid = 1; rx_data = rxbuf_a[b];
        if (IF_MODE == 0) begin @(negedge clk); rx_valid = 0; repeat (8+extra_gap) @(negedge clk); end
      end
      @(negedge clk); rx_ready = 0; rx_valid = 0;
      repeat (4) @(negedge clk); rx_ready = 1;
    end
  endtask

  task replay_b(input integer start_skew);
    integer b;
    begin
      repeat (start_skew) @(negedge clk);
      for (b = 0; b < nrx_b; b = b + 1) begin
        @(negedge clk); rx_ready_b = 1; rx_valid_b = 1; rx_data_b = rxbuf_b[b];
        if (IF_MODE == 0) begin @(negedge clk); rx_valid_b = 0; repeat (8+extra_gap) @(negedge clk); end
      end
      @(negedge clk); rx_ready_b = 0; rx_valid_b = 0;
      repeat (4) @(negedge clk); rx_ready_b = 1;
    end
  endtask

  integer r, p, i, k, waitc, blk, prev_deliv;
  reg [31:0] rd, w;
  reg [15:0] word_addr;
  reg [7:0]  actual_byte, exp_byte;
  reg [10:0] cur_plen;
  integer expected_wire_bytes;
  integer tx_p, rx_p;

  initial begin
    initial_seed=32'h51C0_FFEE;
    if ($value$plusargs("T18_SEED=%h", initial_seed))
      $display("  [T18 INFO] user seed=%08h", initial_seed);
    rng_seed=initial_seed;
    rng_first=$urandom(rng_seed); // initialize the calling process's RNG once
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

    // Configure 4 TX Ports (0..3) and 4 RX Ports (16..19)
    for (p = 0; p < NUM_TEST_PORTS; p = p + 1) begin
      tx_p = p;
      rx_p = 16 + p;

      // TX Port
      host_write(16'h7D80 + 4*tx_p + 3, 32'h0000_0001); // depth 1
      host_write(16'h7D80 + 4*tx_p + 0, 32'h8000_C000 | tx_p); // valid, sampling, sport 49152+tx_p

      // TX VL
      host_write(16'h0200 + 5*tx_p + 4, (tx_p << 16)); // port_base=tx_p
      host_write(16'h0200 + 5*tx_p + 3, 32'hE000_0001 + tx_p); // dst_ip
      host_write(16'h0200 + 5*tx_p + 2, ((16'd5000 + tx_p) << 16) | (16'd49152 + tx_p)); // dp, sp
      host_write(16'h0200 + 5*tx_p + 1, 32'h0000_0100); // small BAG
      host_write(16'h0480 + tx_p, 32'd15949);            // Q20 share
      host_write(16'h0200 + 5*tx_p + 0, 32'h8000_0003 | (1518 << 12)); // valid, Lmax=1518, net A+B

      // RX Hash table
      host_write(16'h0078, 32'h172D);
      host_write(16'h007C, 32'hAB61);
      host_write(hash_addr(16'h0100 + tx_p, 16'h172D, 1'b0, 1'b0), {3'd0, 1'b1, 16'h0100 + tx_p[15:0], 12'h100 + tx_p[11:0]});

      // RX VL table
      host_write(16'h1D80 + 2*(12'h100 + tx_p), 32'hF500_0000 | (rx_p << 12) | 32'd1518);
      host_write(16'h1D80 + 2*(12'h100 + tx_p) + 1, {16'd0, 16'h0100 + tx_p[15:0]});

      // RX Port table
      host_write(16'h7D80 + 4*rx_p + 0, 32'h8004_0000);
      host_write(16'h7D80 + 4*rx_p + 1, (16'd5000 + tx_p)); // dp
      host_write(16'h7D80 + 4*rx_p + 2, 32'd0);
      host_write(16'h7D80 + 4*rx_p + 3, 32'd1);
    end

    host_write(16'h0080, 32'h1); // commit hash mirror

    // Run mode (CTL: TX_EN, RX_EN, IC_EN, RM_EN, CFG_MODE=0 -> 0x051F)
    host_write(16'h0008, 32'h051F);
    @(negedge clk);

    #1000;

    // Serial message ownership/readback with randomized sizes, TX idle gaps,
    // A/B skew, MII inter-byte gaps and true parser->port ready backpressure.
    for (r = 0; r < NUM_ROUNDS; r = r + 1) begin
      for (p = 0; p < NUM_TEST_PORTS; p = p + 1) begin
        test_count = test_count + 1;
        tx_p = p;
        rx_p = 16 + p;
        case (draw(8))
          0: cur_plen = 17;
          1: cur_plen = 1471;
          default: cur_plen = 17 + draw(1455);
        endcase
        if (cur_plen < min_plen) min_plen=cur_plen;
        if (cur_plen > max_plen) max_plen=cur_plen;
        idle_cycles=draw(81);
        if (idle_cycles>0) spaced_frames=spaced_frames+1;
        repeat(idle_cycles) @(negedge clk);
        skew_a=draw(17); skew_b=draw(17);
        extra_gap=draw(5); // IF_MODE=1 requires contiguous rx_valid
        stall_cycles=draw(31);
        if (stall_cycles>0) stalled_frames=stalled_frames+1;
        payload_salt=draw(256);
        expected_wire_bytes = (cur_plen < 17) ? 64 : (42 + cur_plen + 1 + 4);
        prev_deliv = dut.u_rxpb.deliver_cnt;

        // 1. Host allocates open TX block
        waitc = 0;
        host_read(16'h0074, rd);
        while (!rd[4] && waitc < 50000) begin
          @(negedge clk); waitc = waitc + 1;
          host_read(16'h0074, rd);
        end
        if (!rd[4]) bad("No free TX PMEM block available");
        blk = rd[3:0];

        // Write per-frame seeded payload pattern
        for (i = 0; i < (cur_plen + 3) / 4; i = i + 1) begin
          w = { (8'(((payload_salt + 4*i + 0) & 255))),
                (8'(((payload_salt + 4*i + 1) & 255))),
                (8'(((payload_salt + 4*i + 2) & 255))),
                (8'(((payload_salt + 4*i + 3) & 255))) };
          host_write(16'h8800 + (blk << 9) + i, w);
        end

        // Reset capture state
        na = 0; nb = 0;

        // 2. Commit message via MSG_WR
        host_write(16'h8280 + tx_p, cur_plen);

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

        if (stall_cycles>0) force dut.u_rxpb.in_ready = 1'b0;
        fork
          replay_a(skew_a);
          replay_b(skew_b);
          begin
            if (stall_cycles>0) begin
              bp_wait=0;
              while (dut.prs_out_vld !== 1'b1 && bp_wait<250000) begin
                @(negedge clk); bp_wait=bp_wait+1;
              end
              if (bp_wait>=250000) bad("Parser did not reach randomized backpressure");
              else repeat(stall_cycles) @(negedge clk);
              release dut.u_rxpb.in_ready;
            end
          end
        join

        // Wait for RX delivery to port buffer
        waitc = 0;
        while (dut.u_rxpb.deliver_cnt <= prev_deliv && waitc < 250000) begin
          @(negedge clk); waitc = waitc + 1;
        end
        if (dut.u_rxpb.deliver_cnt <= prev_deliv) begin
          bad("Timeout waiting for frame delivery");
        end
        // Drain both A and B through RM before checking exact single delivery.
        repeat(96) @(negedge clk);
        if (dut.u_rxpb.deliver_cnt !== prev_deliv + 1 ||
            dut.u_rxpb.deliver_cnt !== test_count) bad("A/B dedup: delivery count not exactly +1");

        // 4. Host readback from rx_p
        host_read(16'h8480 + rx_p, rd); // MSG_CNT
        if (rd !== 32'd1) bad("MSG_CNT must equal exactly one before MSG_RD");
        host_read(16'h8180 + rx_p, rd); // PORT_DESC
        if (rd[31] !== 1'b1 || rd[10:0] !== cur_plen) bad("PORT_DESC mismatch");
        blk = rd[23:20];

        // Verify payload bytes in RX PMEM
        for (i = 10; i < (42 + cur_plen + 3) / 4; i = i + 1) begin
          word_addr = 16'h8800 + (blk << 9) + i;
          host_read(word_addr, w);
          for (k = 0; k < 4; k = k + 1) begin
            if (4*i + k >= 42 && 4*i + k < 42 + cur_plen) begin
              actual_byte = w[31 - 8*k -: 8];
              exp_byte = (payload_salt + (4*i + k - 42)) & 255;
              if (actual_byte !== exp_byte) begin
                bad("Payload byte mismatch in PMEM");
              end
            end
          end
        end

        // Free RX block
        host_write(16'h8380 + rx_p, 32'd0);
        host_read(16'h8480 + rx_p, rd);
        if (rd !== 32'd0) bad("MSG_CNT must be zero after MSG_RD");
      end
    end

    #1000;
    $display("  [T18 INFO] seed=%08h first=%08h min=%0d max=%0d stalled=%0d spaced=%0d",
             initial_seed, rng_first, min_plen, max_plen, stalled_frames, spaced_frames);
    if (min_plen>17 || max_plen<1471 || stalled_frames==0 || spaced_frames==0)
      bad("Random length/spacing/backpressure coverage missing");
    if (err_count == 0) begin
      $display("T18 RANDOM STRESS PASS (IF_MODE=%0d rounds=%0d frames=%0d seed=%08h min=%0d max=%0d stalls=%0d spaced=%0d)",
               IF_MODE, NUM_ROUNDS, test_count, initial_seed, min_plen, max_plen, stalled_frames, spaced_frames);
    end else begin
      $display("T18 RANDOM STRESS FAIL (IF_MODE=%0d errors=%0d seed=%08h)", IF_MODE, err_count, initial_seed);
    end
    $finish;
  end

  initial begin
    #180_000_000;
    $display("T18 RANDOM STRESS FAIL (IF_MODE=%0d watchdog seed=%08h)", IF_MODE, initial_seed);
    $finish;
  end
endmodule

module tb_t18_random_stress;  tb_t18_core #(.IF_MODE(0)) core(); endmodule
module tb_t18g_random_stress; tb_t18_core #(.IF_MODE(1)) core(); endmodule
