`timescale 1ns/1ps
// =====================================================================
// T13w / T13wg -- worst-case end-to-end latency under a legal full burst
// (test-set completion 20260928; complements T13, which measures a single
// VL with no contention).
//
// WHY THIS SCENARIO IS THE WORST CASE THE DESIGN ADMITS
//   * The guide asks "end-to-end latency < 1-2 ms (worst case), jitter <=
//     tens of us".  In ARINC 664 P7 a latency bound only exists for a LEGAL
//     configuration: the ES output jitter bound
//         J = 40 us + sum_j (20 + Lmax_j) * 8 / 100 Mbps      must be <= 500 us.
//     (Without that constraint 128 max-size VLs released together queue
//      for 15.7 ms and no design can meet 1 ms.)
//   * The TX pool has TX_BLK_N = 6 PMEM blocks (AFDX_top u_txbuf), so at
//     most 6 messages can be pending at once -- queue depth is capped
//     structurally.
//   * Configuration used: 6 VLs = the whole TX pool, loaded right up to the
//     500 us jitter limit:
//         VL0..VL2  Lmax = 1518 B (payload 1471 B, max frame)
//         VL3..VL5  Lmax =  356 B (payload  309 B)
//         J = 40 + (3*1538 + 3*376) * 0.08 = 499.36 us  (<= 500 us)
//     BAG = 4 ms (legal power-of-two), Q20 shares computed from the same
//     formula and checked through CFG_SUM / CFG_ERR.
//   * Every round commits all six messages back to back (only the host
//     staging time separates them), so each frame waits behind every
//     other one -- the scheduler (EDF scan, single builder) decides order.
//     Round 0 commits big frames first, round 1 small frames first.
//
// LOOPBACK: live, registered wire loopback (no capture/replay), net B
// delayed by SKEW_B cycles; RM must deliver exactly one copy per frame.
//
// ASSERTED PER FRAME (plusargs tighten them for the negative runs):
//   TOTAL  = MSG_WR -> RX port delivery          <= T13W_TOTAL_MAX_US (1000)
//   QUEUE  = MSG_WR -> first TX byte on net A    <= T13W_QUEUE_MAX_US
//            (default = the ARINC bound J above, 499 us, rounded down)
//   RX_PIPE= last TX byte on A -> port delivery   <= T13W_RX_PIPE_MAX_US (150)
// plus: exactly one delivery per frame, payload intact in RX PMEM,
//       config accepted, and (IF_MODE=0 only) the burst really produced
//       contention: max QUEUE in a round >= T13W_CONTENTION_MIN_US (250).
//       The contention floor proves the test is not vacuous; it is not a
//       performance claim.  IF_MODE=1 runs bytes back to back (~1 Gbps), so
//       queues there are an order of magnitude shorter and only reported.
//
// Negative runs (must FAIL), e.g.
//   run_regress.ps1 -Tests T13w -KeepWork -OutDir out/neg_t13w_q
//                   -PlusArgs '+T13W_QUEUE_MAX_US=200'
//   run_regress.ps1 -Tests T13w -KeepWork -OutDir out/neg_t13w_t
//                   -PlusArgs '+T13W_TOTAL_MAX_US=300'
// One machine-readable "T13WMETRIC ..." line per frame feeds the report.
// =====================================================================

module tb_t13w_core #(parameter integer IF_MODE = 0);

  localparam integer NVL     = 6;
  localparam integer BAG_US  = 4000;
  localparam integer SKEW_B  = 16;          // net B lags net A by 16 cycles
  localparam integer NROUNDS = 2;

  reg clk = 0;
  reg reset = 1;
  always #4 clk = ~clk;                     // 125 MHz

  reg         host_cs = 0;
  reg         host_we = 0;
  reg  [15:0] host_addr = 0;
  reg  [31:0] host_wdata = 0;
  wire [31:0] host_rdata;
  wire        host_ack;
  wire        host_irq;

  reg        rx_valid = 0, rx_valid_b = 0;
  reg        rx_ready = 0, rx_ready_b = 0;
  reg  [7:0] rx_data = 0,  rx_data_b = 0;
  wire [7:0] tx_data,      tx_data_b;
  wire       tx_valid,     tx_valid_b;
  wire       tx_ready,     tx_ready_b;

  AFDX_top #(
    .IF_MODE(IF_MODE),
    .FCS_MODE(2)
  ) dut (
    .clk(clk), .reset(reset),
    .tx_data(tx_data), .rx_data(rx_data), .tx_valid(tx_valid), .rx_valid(rx_valid),
    .tx_ready(tx_ready), .rx_ready(rx_ready),
    .tx_data_b(tx_data_b), .tx_valid_b(tx_valid_b), .tx_ready_b(tx_ready_b),
    .rx_data_b(rx_data_b), .rx_valid_b(rx_valid_b), .rx_ready_b(rx_ready_b),
    .host_cs(host_cs), .host_we(host_we), .host_addr(host_addr), .host_wdata(host_wdata),
    .host_rdata(host_rdata), .host_ack(host_ack), .host_irq(host_irq),
    .pps_in(1'b0), .pps_out(), .rtc_time_us(), .dbg_frame_event()
  );

  // ---------------- per-VL configuration ----------------
  function integer lmax_of(input integer v); lmax_of = (v < 3) ? 1518 : 356; endfunction
  function integer plen_of(input integer v); plen_of = lmax_of(v) - 47;     endfunction
  // Q20 share = ceil((Lmax+20)*8 * 2^20 / (BAG_us * 100 bit/us))
  function [31:0] share_q20(input integer lmax);
    reg [63:0] num, den;
    begin
      num = (lmax + 20) * 64'd8 * 64'd1048576;
      den = BAG_US * 64'd100;
      share_q20 = (num + den - 64'd1) / den;
    end
  endfunction

  // ---------------- limits ----------------
  integer total_max_us    = 1000;
  integer rx_pipe_max_us  = 150;
  integer queue_max_us    = 0;              // 0 -> use ARINC bound (computed)
  integer contention_min_us = 250;
  reg [63:0] arinc_bound_ns;
  integer v0;
  initial begin
    arinc_bound_ns = 64'd40000;
    for (v0 = 0; v0 < NVL; v0 = v0 + 1) arinc_bound_ns = arinc_bound_ns + (lmax_of(v0) + 20) * 64'd80;
    if ($value$plusargs("T13W_TOTAL_MAX_US=%d", total_max_us)) ;
    if ($value$plusargs("T13W_RX_PIPE_MAX_US=%d", rx_pipe_max_us)) ;
    if ($value$plusargs("T13W_QUEUE_MAX_US=%d", queue_max_us)) ;
    if ($value$plusargs("T13W_CONTENTION_MIN_US=%d", contention_min_us)) ;
  end
  function [63:0] queue_lim_ns(input integer dummy);
    queue_lim_ns = (queue_max_us > 0) ? queue_max_us * 64'd1000 : arinc_bound_ns;
  endfunction

  integer err_count = 0;
  task bad(input [8*96-1:0] msg);
    begin
      if (err_count < 30) $display("  [err] T13w t=%0t: %0s", $time, msg);
      err_count = err_count + 1;
    end
  endtask

  // Host bus protocol (AFDX_top.v, ack_r): while RX owns the single PMEM
  // write port the DUT withholds ACK and the host must HOLD the request until
  // ACK. Legacy TBs drop CS after one cycle, which is only safe without RX
  // traffic; this TB stages payload while its own frames loop back, so it
  // must follow the hold-until-ACK rule. A missing ACK is still an error,
  // just after a bounded wait (HOST_ACK_TIMEOUT cycles), and the worst wait
  // observed is reported in the verdict line.
  localparam integer HOST_ACK_TIMEOUT = 1000;
  integer host_wait_max = 0;
  task host_write(input [15:0] addr, input [31:0] data);
    integer hw;
    begin
      @(negedge clk);
      host_cs = 1; host_we = 1; host_addr = addr; host_wdata = data;
      @(negedge clk);
      hw = 0;
      while (host_ack !== 1'b1 && hw < HOST_ACK_TIMEOUT) begin
        @(negedge clk); hw = hw + 1;
      end
      if (hw > host_wait_max) host_wait_max = hw;
      if (host_ack !== 1'b1) bad("host write ACK missing (timeout)");
      host_cs = 0; host_we = 0;
    end
  endtask
  task host_read(input [15:0] addr, output [31:0] data);
    integer hw;
    begin
      @(negedge clk);
      host_cs = 1; host_we = 0; host_addr = addr;
      @(negedge clk);
      hw = 0;
      while (host_ack !== 1'b1 && hw < HOST_ACK_TIMEOUT) begin
        @(negedge clk); hw = hw + 1;
      end
      if (hw > host_wait_max) host_wait_max = hw;
      if (host_ack !== 1'b1) bad("host read ACK missing (timeout)");
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
  // VLIDs 0x0100..0x0105 land in distinct table-0 buckets (665,159,1817,
  // 1363,440,39 for seed 0x172D), so way 0 is collision-free.
  function [15:0] hash_addr(input [15:0] vlid, input [15:0] seed, input table_id, input way);
    begin hash_addr = 16'h3D80 + ({4'd0,table_id} << 12) + (mix_bucket(vlid,seed,table_id) << 1) + way; end
  endfunction

  reg [63:0] current_cycle;
  always @(posedge clk) begin
    if (reset) current_cycle <= 0;
    else current_cycle <= current_cycle + 1;
  end

  // ---------------- live wire loopback ----------------
  // IF_MODE=0: tx_ready = frame envelope, tx_valid&tx_ready = byte strobe
  //            (mac_rx_if uses exactly the same convention on rx_*).
  // IF_MODE=1: tx_valid = DV, contiguous bytes; rx_ready is ignored.
  reg [9:0] pipe_b [0:SKEW_B-1];
  integer s;
  always @(posedge clk) begin
    if (reset) begin
      rx_ready <= 1'b0; rx_valid <= 1'b0; rx_data <= 8'd0;
      rx_ready_b <= 1'b0; rx_valid_b <= 1'b0; rx_data_b <= 8'd0;
      for (s = 0; s < SKEW_B; s = s + 1) pipe_b[s] <= 10'd0;
    end else begin
      if (IF_MODE == 0) begin
        rx_ready <= tx_ready; rx_valid <= tx_valid & tx_ready; rx_data <= tx_data;
        pipe_b[0] <= {tx_ready_b, tx_valid_b & tx_ready_b, tx_data_b};
      end else begin
        rx_ready <= 1'b1;     rx_valid <= tx_valid;            rx_data <= tx_data;
        pipe_b[0] <= {1'b1, tx_valid_b, tx_data_b};
      end
      for (s = 1; s < SKEW_B; s = s + 1) pipe_b[s] <= pipe_b[s-1];
      {rx_ready_b, rx_valid_b, rx_data_b} <= pipe_b[SKEW_B-1];
    end
  end

  // ---------------- TX monitor (net A) ----------------
  wire a_active = (IF_MODE != 0) ? tx_valid : tx_ready;
  wire a_strobe = (IF_MODE != 0) ? tx_valid : (tx_valid && tx_ready);
  reg        a_in = 0;
  integer    a_bytes = 0, a_vl = 255;
  reg [63:0] a_start, a_last;
  reg [63:0] t_commit [0:NVL-1];
  reg [63:0] t_txf    [0:NVL-1];
  reg [63:0] t_txl    [0:NVL-1];
  integer    commit_rank [0:NVL-1];
  integer    tx_order [0:63];
  integer    n_tx = 0;
  always @(posedge clk) if (!reset) begin
    if (a_strobe) begin
      if (!a_in) begin a_in <= 1'b1; a_start = current_cycle; a_bytes = 0; a_vl = 255; end
      if (a_bytes == 5) a_vl = tx_data;     // DMAC low byte = VLID low byte = VL index
      a_bytes = a_bytes + 1;
      a_last = current_cycle;
    end
    if (a_in && !a_active) begin
      a_in <= 1'b0;
      if (a_vl < NVL) begin
        t_txf[a_vl] = a_start; t_txl[a_vl] = a_last;
        if (n_tx < 64) tx_order[n_tx] = a_vl;
        n_tx = n_tx + 1;
      end else bad("unexpected VL on net A");
    end
  end

  // ---------------- RX delivery monitor ----------------
  reg [31:0] dc_q = 0;
  reg [63:0] t_del [0:63];
  integer    n_del = 0;
  always @(posedge clk) if (!reset) begin
    if (dut.u_rxpb.deliver_cnt != dc_q) begin
      dc_q <= dut.u_rxpb.deliver_cnt;
      if (n_del < 64) t_del[n_del] = current_cycle;
      n_del = n_del + 1;
    end
    if (dut.rx_ovf_a || dut.rx_ovf_b) bad("RX FIFO overflow during burst");
  end

  // ---------------- stats ----------------
  reg [63:0] worst_total_ns = 0, worst_queue_ns = 0, worst_rxp_ns = 0;
  integer    frames_ok = 0;

  // ---------------- stage one message and commit it ----------------
  task stage_commit(input integer v, input integer r, input integer rank);
    integer i, waitc, blk;
    reg [31:0] rd, w;
    begin
      waitc = 0;
      host_read(16'h0074, rd);
      while (!rd[4] && waitc < 50000) begin
        @(negedge clk); waitc = waitc + 1;
        host_read(16'h0074, rd);
      end
      if (!rd[4]) bad("no free TX PMEM block");
      blk = rd[3:0];
      for (i = 0; i < (plen_of(v) + 3) / 4; i = i + 1) begin
        w = { 8'((v*37 + r*11 + 4*i + 0) & 255), 8'((v*37 + r*11 + 4*i + 1) & 255),
              8'((v*37 + r*11 + 4*i + 2) & 255), 8'((v*37 + r*11 + 4*i + 3) & 255) };
        host_write(16'h8800 + (blk << 9) + i, w);
      end
      @(negedge clk);
      t_commit[v] = current_cycle;
      commit_rank[v] = rank;
      host_write(16'h8280 + v, plen_of(v));
    end
  endtask

  // ---------------- one burst round ----------------
  task run_round(input integer r);
    integer k, v, waitc, tx0, del0, p, i, j, blk, nbad;
    reg [31:0] rd, w;
    reg [63:0] q_ns, tot_ns, rxp_ns, max_q_round;
    reg [7:0]  exp_b;
    begin
      tx0 = n_tx; del0 = n_del;
      // commit order: round 0 = VL0..VL5 (big first), round 1 = VL5..VL0 (small first)
      for (k = 0; k < NVL; k = k + 1) begin
        v = (r == 0) ? k : (NVL - 1 - k);
        stage_commit(v, r, k);
      end
      waitc = 0;
      while ((n_tx - tx0 < NVL || n_del - del0 < NVL) && waitc < 400000) begin
        @(negedge clk); waitc = waitc + 1;
      end
      if (n_tx - tx0 != NVL) bad("not every committed message left on net A");
      if (n_del - del0 < NVL) bad("not every frame was delivered to its RX port");
      repeat (20000) @(negedge clk);          // late duplicates would show up here
      if (n_del - del0 != NVL) bad("delivery count != one per frame (RM duplicate leak or loss)");

      // latency decomposition: the RX pipeline is in order, so the k-th
      // delivery of this round belongs to the k-th frame seen on net A.
      max_q_round = 0;
      for (k = 0; k < NVL && k < n_del - del0; k = k + 1) begin
        v = tx_order[tx0 + k];
        if (!(t_commit[v] < t_txf[v] && t_txf[v] <= t_txl[v] && t_txl[v] < t_del[del0 + k])) begin
          bad("latency timestamps out of order");
        end else begin
          q_ns   = (t_txf[v] - t_commit[v]) * 8;
          tot_ns = (t_del[del0 + k] - t_commit[v]) * 8;
          rxp_ns = (t_del[del0 + k] - t_txl[v]) * 8;
          if (q_ns > max_q_round) max_q_round = q_ns;
          if (q_ns > worst_queue_ns) worst_queue_ns = q_ns;
          if (tot_ns > worst_total_ns) worst_total_ns = tot_ns;
          if (rxp_ns > worst_rxp_ns) worst_rxp_ns = rxp_ns;
          if (tot_ns > total_max_us * 64'd1000)   bad("TOTAL latency over limit");
          if (q_ns   > queue_lim_ns(0))           bad("QUEUE delay over ARINC jitter bound");
          if (rxp_ns > rx_pipe_max_us * 64'd1000) bad("RX_PIPE latency over limit");
          frames_ok = frames_ok + 1;
          $display("T13WMETRIC if_mode=%0d round=%0d tx_pos=%0d vl=%0d commit_rank=%0d lmax=%0d plen=%0d queue_ns=%0d rx_pipe_ns=%0d total_ns=%0d queue_lim_ns=%0d total_max_us=%0d",
                   IF_MODE, r, k, v, commit_rank[v], lmax_of(v), plen_of(v), q_ns, rxp_ns, tot_ns,
                   queue_lim_ns(0), total_max_us);
        end
      end
      if (IF_MODE == 0 && max_q_round < contention_min_us * 64'd1000)
        bad("burst produced no real contention (test would be vacuous)");

      // payload integrity + release of every RX port
      for (v = 0; v < NVL; v = v + 1) begin
        p = 16 + v;
        host_read(16'h8480 + p, rd);
        if (rd == 0) bad("RX MSG_CNT is zero after delivery");
        host_read(16'h8180 + p, rd);
        if (rd[31] !== 1'b1 || rd[10:0] !== plen_of(v)) bad("RX PORT_DESC mismatch");
        blk = rd[23:20];
        nbad = 0;
        for (i = 10; i <= (42 + plen_of(v) + 3) / 4; i = i + 1) begin
          host_read(16'h8800 + (blk << 9) + i, w);
          for (j = 0; j < 4; j = j + 1) begin
            if (4*i + j >= 42 && 4*i + j < 42 + plen_of(v)) begin
              exp_b = (v*37 + r*11 + (4*i + j - 42)) & 255;
              if (w[31 - 8*j -: 8] !== exp_b) nbad = nbad + 1;
            end
          end
        end
        if (nbad != 0) bad("RX payload corrupted under burst");
        host_write(16'h8380 + p, 32'd0);
      end
      $display("  [T13w INFO] IF_MODE=%0d round %0d: max queue=%0d ns (ARINC bound %0d ns)",
               IF_MODE, r, max_q_round, arinc_bound_ns);
    end
  endtask

  integer waitc, v, r;
  reg [31:0] rd, sum_exp;
  reg [63:0] last_start;

  initial begin
    repeat (7) @(negedge clk);
    reset = 0;
    waitc = 0;
    while (dut.init_done !== 1 && waitc < 27000) begin @(negedge clk); waitc = waitc + 1; end
    if (waitc >= 27000) bad("INIT_DONE timeout");

    host_write(16'h0008, 32'h2000);                 // CFG_MODE
    host_write(16'h0060, 32'h1234_2001);            // UDI=0x1234, IFID A=1/B=2
    host_write(16'h0064, 32'h0A00_0001);            // SRC IP
    host_write(16'h0070, 32'h0000_0142);            // UDP checksum
    host_write(16'h0078, 32'h172D);                 // hash seeds
    host_write(16'h007C, 32'hAB61);

    sum_exp = 0;
    for (v = 0; v < NVL; v = v + 1) begin
      // TX port v -> TX VL v
      host_write(16'h7D80 + 4*v + 3, 32'h0000_0001);                       // depth 1
      host_write(16'h7D80 + 4*v + 0, 32'h8000_C000 | v);                   // valid, sampling
      host_write(16'h0200 + 5*v + 4, (v << 16));                           // port_base
      host_write(16'h0200 + 5*v + 3, 32'hE000_0001 + v);                   // dst ip
      host_write(16'h0200 + 5*v + 2, ((16'd5000 + v) << 16) | (16'd49152 + v)); // dp, sp
      host_write(16'h0200 + 5*v + 1, BAG_US << 8);                         // BAG = 4 ms
      host_write(16'h0480 + v, share_q20(lmax_of(v)));
      sum_exp = sum_exp + share_q20(lmax_of(v));
      host_write(16'h0200 + 5*v + 0, 32'h8000_0003 | (lmax_of(v) << 12));  // valid, Lmax, net A+B
      // RX: VLID 0x0100+v -> RX VL 0x100+v -> RX port 16+v
      host_write(hash_addr(16'h0100 + v, 16'h172D, 1'b0, 1'b0),
                 {3'd0, 1'b1, 16'h0100 + v[15:0], 12'h100 + v[11:0]});
      host_write(16'h1D80 + 2*(12'h100 + v),     32'hF500_0000 | ((16 + v) << 12) | 32'd1518);
      host_write(16'h1D80 + 2*(12'h100 + v) + 1, {16'd0, 16'h0100 + v[15:0]});
      host_write(16'h7D80 + 4*(16 + v) + 0, 32'h8004_0000);
      host_write(16'h7D80 + 4*(16 + v) + 1, 16'd5000 + v);                 // dp
      host_write(16'h7D80 + 4*(16 + v) + 2, 32'd0);
      host_write(16'h7D80 + 4*(16 + v) + 3, 32'd1);
    end
    host_write(16'h0080, 32'h1);                    // commit hash mirror

    host_read(16'h0058, rd);
    if (rd !== sum_exp) bad("CFG_SUM != sum of computed Q20 shares");
    host_read(16'h005C, rd);
    if (rd !== 32'd0) bad("CFG_ERR set for a legal (<= 100 Mbps) configuration");
    if (arinc_bound_ns > 64'd500000) bad("TB config exceeds the ARINC 500 us jitter limit");

    host_write(16'h0008, 32'h051F);                 // TX/RX/IC/RM enable, run mode
    repeat (200) @(negedge clk);

    for (r = 0; r < NROUNDS; r = r + 1) begin
      if (r > 0) begin
        // next round only after every VL is due again: next_tx = frame
        // start + BAG + 1 us (tx_vl_scheduler), plus 10 us margin, so the
        // measured queue never contains a BAG-regulation wait.
        last_start = 0;
        for (v = 0; v < NVL; v = v + 1) if (t_txf[v] > last_start) last_start = t_txf[v];
        while (current_cycle < last_start + (BAG_US + 10) * 125) @(negedge clk);
      end
      run_round(r);
    end

    if (frames_ok != NROUNDS * NVL) bad("not every frame produced a latency sample");
    #1000;
    if (err_count == 0)
      $display("T13w WORST-CASE LATENCY PASS (IF_MODE=%0d VLs=%0d rounds=%0d frames=%0d worst_total=%0dns worst_queue=%0dns arinc_bound=%0dns worst_rx_pipe=%0dns asserted total<=%0dus rx_pipe<=%0dus host_ack_wait_max=%0dcyc)",
               IF_MODE, NVL, NROUNDS, frames_ok, worst_total_ns, worst_queue_ns, arinc_bound_ns,
               worst_rxp_ns, total_max_us, rx_pipe_max_us, host_wait_max);
    else
      $display("T13w WORST-CASE LATENCY FAIL (IF_MODE=%0d errors=%0d worst_total=%0dns worst_queue=%0dns host_ack_wait_max=%0dcyc)",
               IF_MODE, err_count, worst_total_ns, worst_queue_ns, host_wait_max);
    $finish;
  end

  initial begin
    #30_000_000;
    $display("T13w WORST-CASE LATENCY FAIL (IF_MODE=%0d watchdog 30 ms, tx=%0d del=%0d)", IF_MODE, n_tx, n_del);
    $finish;
  end
endmodule

module tb_t13w_worst;  tb_t13w_core #(.IF_MODE(0)) core(); endmodule
module tb_t13wg_worst; tb_t13w_core #(.IF_MODE(1)) core(); endmodule
