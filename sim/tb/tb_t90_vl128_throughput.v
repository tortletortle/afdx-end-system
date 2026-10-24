// T90 — 128 TX VL 吞吐（新增系统场，非原矩阵）。r5 定稿口径：
//   TX 128 VL，口 16..143；默认 CTL 0x051F（SAP 开）。
//   RX 只配 VL0..125（126 口，避开 6/7 与 TX）；VL126/127 不配 RX 表。
//   端口预算：NUM_PORTS=256 = 128 TX + 126 RX + 2 SAP（单 ES 回环）。
//   A/B 双网回环；RM 去重。丢弃：DROP_CNT_K unconf @0x0040 增量 == 2*ROUNDS*2。
`timescale 1 ns / 1 ps
module tb_t90_vl128_throughput;
  localparam integer NVL_TX = 128;
  localparam integer NVL_RX = 126;
  localparam integer ROUNDS = 3;
  localparam integer BAG_US = 1000;
  localparam integer BAG_CYC = 125000;
  localparam integer MIN_MBPS = 100;
  localparam integer ES_TOTAL_MAX_NS = 2000000;
  // J=min(40+Σ(20+Lmax)·8/1000,500)；Σ_bytescale=97152 → 817.216 → 500 μs
  localparam integer JIT_BOUND_40SIG_US = 500;
  localparam integer JIT_BOUND_CYC = JIT_BOUND_40SIG_US * 125;
  localparam integer SHARE_G0 = 705;
  localparam integer SHARE_G1 = 2710;
  localparam integer SHARE_G2 = 9152;
  localparam integer SHARE_G3 = 12902;
  localparam integer EXPECT_CFG_SUM = 32*SHARE_G0 + 32*SHARE_G1
                                    + 32*SHARE_G2 + 32*SHARE_G3;
  localparam integer TX_PORT_BASE = 16;
  localparam integer EXPECT_UNCONF = 2 * ROUNDS * 2; // VL126/127 × rounds × A/B

  reg clk = 0, reset = 1;
  always #4 clk = ~clk;
  integer cycle = 0;
  always @(posedge clk) cycle <= cycle + 1;

  wire [7:0] tx_a, tx_b;
  wire dv_a, dv_b;
  reg loop_en = 0;
  wire [7:0] rx_data_a = loop_en ? tx_a : 8'd0;
  wire       rx_valid_a = loop_en ? dv_a : 1'b0;
  wire [7:0] rx_data_b = loop_en ? tx_b : 8'd0;
  wire       rx_valid_b = loop_en ? dv_b : 1'b0;

  reg host_cs = 0, host_we = 0;
  reg [15:0] host_addr = 0;
  reg [31:0] host_wdata = 0;
  wire [31:0] host_rdata;
  wire host_ack, host_irq;

  AFDX_top dut (
    .clk(clk), .reset(reset),
    .tx_data(tx_a), .tx_valid(dv_a), .tx_ready(),
    .rx_data(rx_data_a), .rx_valid(rx_valid_a), .rx_ready(1'b0), .rx_error(1'b0),
    .tx_data_b(tx_b), .tx_valid_b(dv_b), .tx_ready_b(),
    .rx_data_b(rx_data_b), .rx_valid_b(rx_valid_b), .rx_ready_b(1'b0), .rx_error_b(1'b0),
    .host_cs(host_cs), .host_we(host_we), .host_addr(host_addr), .host_wdata(host_wdata),
    .host_rdata(host_rdata), .host_ack(host_ack), .host_irq(host_irq),
    .pps_in(1'b0), .pps_out(), .rtc_time_us(), .dbg_frame_event()
  );

  integer errors = 0, checks = 0;
  integer csv;
  localparam integer HOST_ACK_TIMEOUT = 1000; // 契约 L93；与 T13w 一致，不得再调大
  integer host_ack_wait_max = 0;
  integer max_tx_commit2sfd_ns = 0;
  integer max_rx_sfd2host_ns = 0;
  integer es_total_max_ns = 0;
  integer window_start = 0, window_stop = 0;
  reg [63:0] tx_bytes_a = 0, tx_bytes_b = 0, rx_dedup_bytes = 0;
  integer rx_deliver_cnt = 0;
  integer cfg_sum_rd = 0, unconf0 = 0, unconf1 = 0;
  integer i, r, n, waitc, base, port_tx, port_rx;
  integer c2s_ns, s2h_ns, sfd_ns, c2s_tmp;
  integer e2e_lat, e2e_min, e2e_max, e2e_jit, sfd_gap;
  integer max_e2e_jit_cyc = 0;
  reg [31:0] rd;
  integer plen_of [0:NVL_TX-1];
  integer lmax_of [0:NVL_TX-1];
  integer share_of [0:NVL_TX-1];
  integer commit_t [0:NVL_TX-1][0:ROUNDS-1];
  integer tx_sfd_t [0:NVL_TX-1][0:ROUNDS-1];
  integer tx_eof_t [0:NVL_TX-1][0:ROUNDS-1];
  integer rx_sfd_t [0:NVL_RX-1][0:ROUNDS-1];
  integer rx_host_t [0:NVL_RX-1][0:ROUNDS-1];
  integer vl_tx_cnt_a [0:NVL_TX-1];
  integer vl_tx_cnt_b [0:NVL_TX-1];
  integer prev_start_a [0:NVL_TX-1];
  integer prev_start_b [0:NVL_TX-1];
  integer prev_sfd_b [0:NVL_TX-1];
  integer port_rx_of [0:NVL_RX-1];
  integer port_tx_of [0:NVL_TX-1];
  integer rx_pool [0:NVL_RX-1];
  integer vl_of_rx_port [0:255];

  reg active_a = 0, active_b = 0;
  integer size_a = 0, size_b = 0, gap_a = 100, gap_b = 100;
  integer frame_start_a = 0, frame_start_b = 0;
  reg [7:0] cap_a [0:1599];
  reg [7:0] cap_b [0:1599];
  integer cap_sfd_a = 0, cap_sfd_b = 0;
  integer tx_phase = 0;

  task bad;
    input [8*120-1:0] why;
    begin
      if (errors < 40) $display("  [err] T90 cycle=%0d %0s", cycle, why);
      errors = errors + 1;
    end
  endtask

  task host_write;
    input [15:0] addr; input [31:0] data;
    begin
      @(negedge clk); host_cs = 1; host_we = 1; host_addr = addr; host_wdata = data;
      n = 0;
      while (host_ack !== 1'b1 && n < HOST_ACK_TIMEOUT) begin
        @(negedge clk); n = n + 1;
      end
      if (n > host_ack_wait_max) host_ack_wait_max = n;
      if (host_ack !== 1'b1) bad("host write ACK timeout");
      host_cs = 0; host_we = 0;
    end
  endtask

  task host_read;
    input [15:0] addr; output [31:0] data;
    begin
      @(negedge clk); host_cs = 1; host_we = 0; host_addr = addr;
      n = 0;
      while (host_ack !== 1'b1 && n < HOST_ACK_TIMEOUT) begin
        @(negedge clk); n = n + 1;
      end
      if (n > host_ack_wait_max) host_ack_wait_max = n;
      if (host_ack !== 1'b1) bad("host read ACK timeout");
      data = host_rdata; host_cs = 0;
    end
  endtask

  function [10:0] mix_bucket;
    input [15:0] vlid, seed;
    reg [15:0] x;
    begin
      x = vlid + seed + 16'h9E37; x = x ^ (x >> 7); x = x * 16'h9E37; x = x ^ (x >> 9);
      mix_bucket = x & 11'h7FF;
    end
  endfunction

  function integer plen_for;
    input integer vl;
    begin
      if (vl < 32) plen_for = 17;
      else if (vl < 64) plen_for = 256;
      else if (vl < 96) plen_for = 1024;
      else plen_for = 1471;
    end
  endfunction

  function integer share_for;
    input integer vl;
    begin
      if (vl < 32) share_for = SHARE_G0;
      else if (vl < 64) share_for = SHARE_G1;
      else if (vl < 96) share_for = SHARE_G2;
      else share_for = SHARE_G3;
    end
  endfunction

  function [7:0] payload_byte;
    input integer vl, round, off;
    begin payload_byte = (vl * 17 + round * 29 + off * 13 + 8'h53) & 8'hFF; end
  endfunction

  task wait_init;
    begin
      waitc = 0; host_read(16'h000C, rd);
      while (rd[13] !== 1'b1 && waitc < 40000) begin host_read(16'h000C, rd); waitc = waitc + 1; end
      if (rd[13] !== 1'b1) bad("INIT_DONE");
    end
  endtask

  task build_rx_pool;
    integer p, nn;
    begin
      nn = 0;
      for (p = 0; p < 256; p = p + 1)
        if (p != 6 && p != 7 && (p < TX_PORT_BASE || p >= TX_PORT_BASE + NVL_TX)) begin
          if (nn < NVL_RX) begin rx_pool[nn] = p; nn = nn + 1; end
        end
      if (nn != NVL_RX) bad("rx_pool size != 126");
    end
  endtask

  // TX 0..127；RX 表/口仅 0..125。VL126/127 无 RX → FLT unconf。
  task cfg_all;
    integer v, plen, lmax, share, rx_idx, bucket, way;
    integer way0_vl [0:2047];
    begin
      build_rx_pool();
      for (v = 0; v < 256; v = v + 1) vl_of_rx_port[v] = -1;
      for (v = 0; v < 2048; v = v + 1) way0_vl[v] = -1;
      host_write(16'h0008, 32'h0000_2000);
      host_write(16'h0060, 32'h1234_2001);
      host_write(16'h0064, 32'h0A00_0001);
      host_write(16'h0070, 32'h0000_0142);
      host_write(16'h0078, 32'h0000_172D);
      host_write(16'h007C, 32'h0000_AB61);
      for (v = 0; v < NVL_TX; v = v + 1) begin
        plen = plen_for(v);
        lmax = plen + 47;
        share = share_for(v);
        plen_of[v] = plen; lmax_of[v] = lmax; share_of[v] = share;
        port_tx = TX_PORT_BASE + v;
        port_tx_of[v] = port_tx;
        host_write(16'h7D80 + 4 * port_tx + 3, 32'd1);
        host_write(16'h7D80 + 4 * port_tx, 32'h8000_C000 | v);
        host_write(16'h0200 + 5 * v + 4, port_tx << 16);
        host_write(16'h0200 + 5 * v + 3, 32'hE000_0001);
        host_write(16'h0200 + 5 * v + 2, 32'h1388_C000);
        host_write(16'h0200 + 5 * v + 1, BAG_US << 8);
        host_write(16'h0480 + v, share);
        host_write(16'h0200 + 5 * v, 32'h8000_0003 | (lmax << 12));
      end
      for (v = 0; v < NVL_RX; v = v + 1) begin
        port_rx = rx_pool[v];
        port_rx_of[v] = port_rx;
        vl_of_rx_port[port_rx] = v;
        rx_idx = 12'h100 + v[11:0];
        lmax = lmax_of[v];
        bucket = mix_bucket(16'h0100 + v, 16'h172D);
        if (way0_vl[bucket] < 0) begin
          way = 0; way0_vl[bucket] = v;
        end else way = 1;
        host_write(16'h3D80 + (bucket << 1) + way,
                   {3'd0, 1'b1, 16'h0100 + v[15:0], rx_idx[11:0]});
        host_write(16'h1D80 + 2 * rx_idx, 32'hF500_0000 | (port_rx << 12) | lmax);
        host_write(16'h1D80 + 2 * rx_idx + 1, {16'd0, 16'h0100 + v[15:0]});
        host_write(16'h7D80 + 4 * port_rx, 32'h8004_0000);
        host_write(16'h7D81 + 4 * port_rx, 32'h0000_1388);
        host_write(16'h7D82 + 4 * port_rx, 32'd0);
        host_write(16'h7D83 + 4 * port_rx, 32'd8);
      end
      // VL126/127：故意不写 hash / RX_VL_CFG / RX port
      host_write(16'h0080, 32'h1);
      host_read(16'h0058, rd);
      cfg_sum_rd = rd;
      if (rd !== EXPECT_CFG_SUM) bad("CFG_SUM mismatch");
      host_read(16'h005C, rd);
      if (rd !== 0) bad("CFG_ERR nonzero");
      host_write(16'h0014, 32'h1);
      host_write(16'h0008, 32'h051F); // 默认 CTL，SAP 开
      loop_en = 1;
      $display("T90_PORT_BUDGET NUM_PORTS=256 = 128 TX + 126 RX + 2 SAP (ctl=0x051F)");
    end
  endtask

  task submit_msg;
    input integer vl, round, when_cyc;
    integer plen, words_local, j;
    reg [7:0] pb;
    begin
      plen = plen_of[vl];
      port_tx = port_tx_of[vl];
      host_read(16'h0074, rd); waitc = 0;
      while (rd[4] !== 1'b1 && waitc < 10000) begin
        host_read(16'h0074, rd); waitc = waitc + 1;
      end
      if (rd[4] !== 1'b1) bad("no TX block");
      base = 16'h8800 + (rd[3:0] << 9);
      words_local = (plen + 3) / 4;
      for (j = 0; j < words_local; j = j + 1) begin
        pb = payload_byte(vl, round, 4 * j);
        host_write(base + j, {pb, payload_byte(vl, round, 4*j+1),
                              payload_byte(vl, round, 4*j+2), payload_byte(vl, round, 4*j+3)});
      end
      while (cycle < when_cyc) @(negedge clk);
      commit_t[vl][round] = cycle;
      host_write(16'h8280 + port_tx, plen);
    end
  endtask

  task finish_tx_frame;
    input integer net;
    integer vl, plen, expect_size, sn_off, k, round_seen, lat;
    reg [7:0] sn;
    begin
      if (net == 0) begin
        expect_size = size_a;
        if (expect_size < 8 + 64) begin bad("A frame too short"); disable finish_tx_frame; end
        vl = ((cap_a[12] << 8) | cap_a[13]) - 16'h0100;
        if (vl < 0 || vl >= NVL_TX) begin bad("A VLID OOR"); disable finish_tx_frame; end
        plen = plen_of[vl];
        if (expect_size != 8 + plen + 47) bad("A Lmax/DV length");
        if (cap_a[7] !== 8'hD5) bad("A SFD");
        sn_off = 8 + 42 + plen;
        sn = cap_a[sn_off];
        round_seen = vl_tx_cnt_a[vl];
        if (round_seen >= ROUNDS) bad("A extra frame");
        else begin
          if (sn !== ((round_seen % 255) + 1)) bad("A SN");
          for (k = 0; k < plen; k = k + 1)
            if (cap_a[8+42+k] !== payload_byte(vl, round_seen, k)) bad("A payload");
          tx_sfd_t[vl][round_seen] = cap_sfd_a;
          tx_eof_t[vl][round_seen] = cycle;
          if (vl < NVL_RX) rx_sfd_t[vl][round_seen] = cap_sfd_a;
          if (round_seen > 0) begin
            if (cap_sfd_a - tx_sfd_t[vl][round_seen - 1] < BAG_CYC)
              bad("A TX SFD BAG violate");
            if (frame_start_a - prev_start_a[vl] < BAG_CYC)
              bad("A BAG violate");
          end
          prev_start_a[vl] = frame_start_a;
          lat = cycle - commit_t[vl][round_seen];
          if (lat > 250000) bad("A commit→eof >2ms");
          if (cap_sfd_a != 0 && commit_t[vl][round_seen] != 0) begin
            c2s_tmp = (cap_sfd_a - commit_t[vl][round_seen]) * 8;
            if (c2s_tmp < 0) c2s_tmp = -c2s_tmp;
            if (c2s_tmp > max_tx_commit2sfd_ns) max_tx_commit2sfd_ns = c2s_tmp;
          end
          if (frame_start_a >= window_start && cycle <= window_stop)
            tx_bytes_a = tx_bytes_a + plen;
          vl_tx_cnt_a[vl] = round_seen + 1;
          checks = checks + 1;
        end
      end else begin
        expect_size = size_b;
        if (expect_size < 8 + 64) begin bad("B frame too short"); disable finish_tx_frame; end
        vl = ((cap_b[12] << 8) | cap_b[13]) - 16'h0100;
        if (vl < 0 || vl >= NVL_TX) begin bad("B VLID OOR"); disable finish_tx_frame; end
        plen = plen_of[vl];
        if (expect_size != 8 + plen + 47) bad("B Lmax/DV length");
        if (cap_b[7] !== 8'hD5) bad("B SFD");
        round_seen = vl_tx_cnt_b[vl];
        if (round_seen >= ROUNDS) bad("B extra frame");
        else begin
          for (k = 0; k < plen; k = k + 1)
            if (cap_b[8+42+k] !== payload_byte(vl, round_seen, k)) bad("B payload");
          if (round_seen > 0) begin
            if (cap_sfd_b - prev_sfd_b[vl] < BAG_CYC)
              bad("B TX SFD BAG violate");
            if (frame_start_b - prev_start_b[vl] < BAG_CYC)
              bad("B BAG violate");
          end
          prev_sfd_b[vl] = cap_sfd_b;
          prev_start_b[vl] = frame_start_b;
          if (frame_start_b >= window_start && cycle <= window_stop)
            tx_bytes_b = tx_bytes_b + plen;
          vl_tx_cnt_b[vl] = round_seen + 1;
          checks = checks + 1;
        end
      end
    end
  endtask

  always @(posedge clk) if (!reset && tx_phase) begin
    if (dv_a) begin
      if (!active_a) begin
        if (gap_a < 12 && size_a != 0) bad("A IFG");
        active_a = 1; size_a = 0; frame_start_a = cycle; cap_sfd_a = 0;
      end
      if (size_a < 1600) begin
        cap_a[size_a] = tx_a;
        if (cap_sfd_a == 0 && tx_a === 8'hD5) cap_sfd_a = cycle;
      end
      size_a = size_a + 1; gap_a = 0;
    end else begin
      gap_a = gap_a + 1;
      if (active_a) begin finish_tx_frame(0); active_a = 0; end
    end
    if (dv_b) begin
      if (!active_b) begin
        if (gap_b < 12 && size_b != 0) bad("B IFG");
        active_b = 1; size_b = 0; frame_start_b = cycle; cap_sfd_b = 0;
      end
      if (size_b < 1600) begin
        cap_b[size_b] = tx_b;
        if (cap_sfd_b == 0 && tx_b === 8'hD5) cap_sfd_b = cycle;
      end
      size_b = size_b + 1; gap_b = 0;
    end else begin
      gap_b = gap_b + 1;
      if (active_b) begin finish_tx_frame(1); active_b = 0; end
    end
  end

  task drain_rx_once;
    integer p, plen_got, blk, guard, vl, slot, s2h, pi, wi, off, k, boff, j;
    reg [31:0] desc, pw;
    reg [7:0] got0;
    begin
      for (pi = 0; pi < NVL_RX; pi = pi + 1) begin
        p = rx_pool[pi];
        host_read(16'h8480 + p, rd);
        guard = 0;
        while (rd != 0 && guard < 8) begin
          host_read(16'h8180 + p, desc);
          if (desc[31] !== 1'b1) bad("RX desc invalid");
          plen_got = desc[10:0];
          blk = desc[23:20];
          vl = vl_of_rx_port[p];
          if (vl < 0 || vl >= NVL_RX) bad("RX port→vl map broken");
          if (plen_got != plen_of[vl]) bad("RX plen mismatch");
          // PMEM 存整帧：UDP 载荷自字节 42 起（与 T11 一致）；首字节定 round
          host_read(16'h8800 + (blk << 9) + (42 >> 2), pw);
          got0 = pw[31-8*(42%4) -: 8];
          slot = -1;
          for (j = 0; j < ROUNDS; j = j + 1)
            if (got0 === payload_byte(vl, j, 0)) slot = j;
          if (slot < 0) bad("RX payload round unknown");
          if (rx_host_t[vl][slot] != 0) bad("RX duplicate deliver slot");
          for (off = 0; off < plen_got; off = off + 1) begin
            boff = 42 + off;
            wi = boff / 4;
            k = boff % 4;
            if (off == 0 || k == 0)
              host_read(16'h8800 + (blk << 9) + wi, pw);
            if (pw[31-8*k -: 8] !== payload_byte(vl, slot, off))
              bad("RX payload byte mismatch");
          end
          rx_host_t[vl][slot] = cycle;
          if (rx_sfd_t[vl][slot] != 0) begin
            s2h = (cycle - rx_sfd_t[vl][slot]) * 8;
            if (s2h < 0) s2h = -s2h;
            if (s2h > max_rx_sfd2host_ns) max_rx_sfd2host_ns = s2h;
          end
          host_write(16'h8380 + p, 32'd0);
          if (cycle >= window_start && cycle <= window_stop)
            rx_dedup_bytes = rx_dedup_bytes + plen_got;
          rx_deliver_cnt = rx_deliver_cnt + 1;
          host_read(16'h8480 + p, rd);
          guard = guard + 1;
          checks = checks + 1;
        end
      end
    end
  endtask

  real tx_mbps_a, tx_mbps_b, rx_mbps;
  integer t0, expect_rx;

  initial begin
    for (i = 0; i < NVL_TX; i = i + 1) begin
      vl_tx_cnt_a[i] = 0; vl_tx_cnt_b[i] = 0;
      prev_start_a[i] = 0; prev_start_b[i] = 0; prev_sfd_b[i] = 0;
      for (r = 0; r < ROUNDS; r = r + 1) begin
        commit_t[i][r] = 0; tx_sfd_t[i][r] = 0; tx_eof_t[i][r] = 0;
      end
    end
    for (i = 0; i < NVL_RX; i = i + 1)
      for (r = 0; r < ROUNDS; r = r + 1) begin
        rx_sfd_t[i][r] = 0; rx_host_t[i][r] = 0;
      end

    csv = $fopen("t90_metrics.csv", "w");
    if (!csv) csv = $fopen("sim/out/t90_metrics.csv", "w");
    if (!csv) begin $display("T90 FAIL: cannot open csv"); $finish; end
    $fwrite(csv, "vl,frame,len,t_commit,t_tx_sfd,t_tx_eof,t_rx_sfd,t_rx_host,tx_commit2sfd_ns,rx_sfd2host_ns,sfd2sfd_ns,net\n");

    repeat (8) @(negedge clk); reset = 0;
    wait_init();
    cfg_all();
    host_read(16'h0040, rd); unconf0 = rd; // DROP_CNT_K unconf baseline

    t0 = cycle;
    window_start = t0 + BAG_CYC;
    window_stop = t0 + ROUNDS * BAG_CYC;
    tx_phase = 1;

    for (r = 0; r < ROUNDS; r = r + 1)
      for (i = 0; i < NVL_TX; i = i + 1) begin
        submit_msg(i, r, t0 + r * BAG_CYC + i * BAG_CYC / NVL_TX);
        if (i[1:0] == 2'd3) drain_rx_once();
      end

    while (cycle < window_stop + 2 * BAG_CYC) begin
      drain_rx_once();
      repeat (16) @(negedge clk);
    end
    tx_phase = 0;
    repeat (32) drain_rx_once();

    host_read(16'h0040, rd); unconf1 = rd;
    $display("T90_UNCONF baseline=%0d now=%0d delta=%0d expect=%0d",
             unconf0, unconf1, unconf1 - unconf0, EXPECT_UNCONF);
    if (unconf1 - unconf0 != EXPECT_UNCONF)
      bad("DROP_CNT_K unconf delta != 2*ROUNDS*2");

    es_total_max_ns = max_tx_commit2sfd_ns + max_rx_sfd2host_ns;
    if (es_total_max_ns > ES_TOTAL_MAX_NS) bad("es_total_max_ns >2ms");

    for (i = 0; i < NVL_TX; i = i + 1) begin
      if (vl_tx_cnt_a[i] != ROUNDS) bad("TX A missing rounds");
      if (vl_tx_cnt_b[i] != ROUNDS) bad("TX B missing rounds");
    end

    for (i = 0; i < NVL_TX; i = i + 1) begin
      for (r = 0; r < ROUNDS; r = r + 1) begin
        c2s_ns = -1; s2h_ns = -1; sfd_ns = 0;
        if (tx_sfd_t[i][r] != 0 && commit_t[i][r] != 0) begin
          c2s_ns = (tx_sfd_t[i][r] - commit_t[i][r]) * 8;
          if (c2s_ns < 0) c2s_ns = -c2s_ns;
        end
        if (i < NVL_RX && rx_host_t[i][r] != 0 && rx_sfd_t[i][r] != 0) begin
          s2h_ns = (rx_host_t[i][r] - rx_sfd_t[i][r]) * 8;
          if (s2h_ns < 0) s2h_ns = -s2h_ns;
        end
        $fwrite(csv, "%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,A\n",
                i, r, plen_of[i], commit_t[i][r], tx_sfd_t[i][r], tx_eof_t[i][r],
                (i < NVL_RX) ? rx_sfd_t[i][r] : -1,
                (i < NVL_RX) ? rx_host_t[i][r] : -1,
                c2s_ns, s2h_ns, sfd_ns);
        $fwrite(csv, "%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,B\n",
                i, r, plen_of[i], commit_t[i][r], -1, -1, -1, -1, -1, -1, -1);
      end
    end
    $fclose(csv);

    tx_mbps_a = $itor(tx_bytes_a) * 8.0 / ((window_stop - window_start) * 0.008);
    tx_mbps_b = $itor(tx_bytes_b) * 8.0 / ((window_stop - window_start) * 0.008);
    rx_mbps   = $itor(rx_dedup_bytes) * 8.0 / ((window_stop - window_start) * 0.008);

    if (tx_mbps_a < MIN_MBPS) bad("TX A payload Mbps <100 (eng)");
    if (tx_mbps_b < MIN_MBPS) bad("TX B payload Mbps <100 (eng)");
    if (rx_mbps < MIN_MBPS) bad("RX dedup payload Mbps <100 (S, 126 VL)");

    expect_rx = NVL_RX * ROUNDS;
    $display("T90_DELIVER rx=%0d expect=%0d (NVL_RX=%0d)", rx_deliver_cnt, expect_rx, NVL_RX);
    if (rx_deliver_cnt != expect_rx)
      bad("RX deliver count != 126*ROUNDS");

    max_e2e_jit_cyc = 0;
    for (i = 0; i < NVL_RX; i = i + 1) begin
      e2e_min = 2147483647; e2e_max = 0;
      for (r = 0; r < ROUNDS; r = r + 1) begin
        if (rx_host_t[i][r] == 0 || commit_t[i][r] == 0)
          bad("missing commit/host for e2e");
        else begin
          e2e_lat = rx_host_t[i][r] - commit_t[i][r];
          if (e2e_lat < 0) e2e_lat = -e2e_lat;
          if (e2e_lat < e2e_min) e2e_min = e2e_lat;
          if (e2e_lat > e2e_max) e2e_max = e2e_lat;
        end
      end
      e2e_jit = e2e_max - e2e_min;
      if (e2e_jit > max_e2e_jit_cyc) max_e2e_jit_cyc = e2e_jit;
      if (e2e_jit > JIT_BOUND_CYC) bad("e2e commit-host jitter >40+Sigma");
    end
    for (i = 0; i < NVL_TX; i = i + 1)
      for (r = 1; r < ROUNDS; r = r + 1) begin
        sfd_gap = tx_sfd_t[i][r] - tx_sfd_t[i][r - 1];
        if (sfd_gap < BAG_CYC) bad("final TX SFD BAG violate");
      end

    begin : sum_json
      integer sfd;
      sfd = $fopen("t90_verilog_summary.json", "w");
      if (!sfd) sfd = $fopen("sim/out/t90_verilog_summary.json", "w");
      if (sfd) begin
        $fwrite(sfd, "{\"errors\":%0d,\"checks\":%0d,", errors, checks);
        $fwrite(sfd, "\"cfg_sum\":%0d,\"expect_cfg_sum\":%0d,", cfg_sum_rd, EXPECT_CFG_SUM);
        $fwrite(sfd, "\"tx_bytes_a\":%0d,\"tx_bytes_b\":%0d,\"rx_dedup_bytes\":%0d,",
                tx_bytes_a, tx_bytes_b, rx_dedup_bytes);
        $fwrite(sfd, "\"window_cycles\":%0d,\"rounds\":%0d,\"nvl_tx\":%0d,\"nvl_rx\":%0d,",
                window_stop - window_start, ROUNDS, NVL_TX, NVL_RX);
        $fwrite(sfd, "\"tx_mbps_a\":%.6f,\"tx_mbps_b\":%.6f,\"rx_dedup_mbps\":%.6f,",
                tx_mbps_a, tx_mbps_b, rx_mbps);
        $fwrite(sfd, "\"max_tx_commit2sfd_ns\":%0d,\"max_rx_sfd2host_ns\":%0d,\"es_total_max_ns\":%0d,",
                max_tx_commit2sfd_ns, max_rx_sfd2host_ns, es_total_max_ns);
        $fwrite(sfd, "\"max_e2e_jit_cyc\":%0d,\"max_e2e_jit_ns\":%0d,\"bound_40sig_us\":%0d,",
                max_e2e_jit_cyc, max_e2e_jit_cyc * 8, JIT_BOUND_40SIG_US);
        $fwrite(sfd, "\"unconf_delta\":%0d,\"expect_unconf\":%0d,",
                unconf1 - unconf0, EXPECT_UNCONF);
        $fwrite(sfd, "\"rx_deliver\":%0d,\"expect_rx\":%0d,",
                rx_deliver_cnt, expect_rx);
        $fwrite(sfd, "\"host_ack_wait_max\":%0d,\"host_ack_timeout\":%0d,",
                host_ack_wait_max, HOST_ACK_TIMEOUT);
        $fwrite(sfd, "\"min_mbps\":%0d,\"bag_us\":%0d,\"bag_cyc\":%0d,\"link_norm_mbps\":1000,\"ctl\":%0d}\n",
                MIN_MBPS, BAG_US, BAG_CYC, 32'h051F);
        $fclose(sfd);
      end
    end

    $display("T90_SFD2SFD_NOTE wire loopback, no network segment, value=0 by construction; not a pass criterion");
    $display("T90_HOST_ACK_WAIT_MAX cycles=%0d timeout=%0d (contract L93 / T13w)",
             host_ack_wait_max, HOST_ACK_TIMEOUT);
    $display("T90_ES_LATENCY max_tx_commit2sfd_ns=%0d max_rx_sfd2host_ns=%0d es_total_max_ns=%0d",
             max_tx_commit2sfd_ns, max_rx_sfd2host_ns, es_total_max_ns);
    $display("T90_JITTER e2e_commit_host max_min_cyc=%0d ns=%0d bound_40sig_us=%0d (period-aligned)",
             max_e2e_jit_cyc, max_e2e_jit_cyc * 8, JIT_BOUND_40SIG_US);
    $display("T90_METRIC tx_a=%.3f tx_b=%.3f rx_dedup=%.3f Mbps cfg_sum_rd=%0d ctl=0x051F nvl_rx=%0d",
             tx_mbps_a, tx_mbps_b, rx_mbps, cfg_sum_rd, NVL_RX);
    if (errors == 0)
      $display("T90 VL128 THROUGHPUT PASS checks=%0d", checks);
    else
      $display("T90 VL128 THROUGHPUT FAIL errors=%0d", errors);
    $finish;
  end
endmodule
