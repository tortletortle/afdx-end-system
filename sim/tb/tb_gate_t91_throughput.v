// T91 — gate/RTL public-port throughput (新增系统场，非原矩阵 / G4)
// 只用顶层端口；禁止 bind / 层次引用。IF_MODE=2 线回环。
// VO 兼容：AFDX_top 不加 #()（RTL 默认 IF_MODE=2 / FCS_MODE=2）。
// 正式：NVL=16、ROUNDS=3（T42 同配）；吞吐统计窗 = 第 2–3 轮稳态。
// +T91_ROUNDS=1 仅探速（不宣称 P）；NVL=128 不做（见冲刺卡）。
// 判据：SFD 间隔≥BAG；载荷对 vec；deliver==NVL*ROUNDS；稳态 Mbps≥100。
`timescale 1 ns / 1 ps
module tb_gate_t91_throughput;
  localparam integer IF_MODE = 2;
  localparam integer NVL_DEFAULT = 16;
  localparam integer ROUNDS_DEFAULT = 3; // 正式同 T42；探速用 +T91_ROUNDS=1
  localparam integer NVL_MAX = 16;       // 正式仅 16；128 不做
  localparam integer PAY_ROUNDS_MAX = 8;
  localparam integer PLEN = 1024;
  localparam integer LMAX = PLEN + 47; // 1071
  localparam integer BAG_US = 1000;
  localparam integer BAG_CYC = 125000;
  localparam integer MIN_MBPS = 100;
  localparam integer TX_PORT_BASE = 16;
  localparam integer PAY_WORDS = (NVL_MAX * PAY_ROUNDS_MAX * PLEN) / 4;
  // equal Q20 share（NVL≤16）：ceil((LMAX+20)·8·2^20 / (BAG_US·1000)) == 9152（同 T42/T90 G2）
  localparam [63:0] SHARE64 = ((64'd1091 * 8 * 1048576) + 999999) / 1000000;
  localparam integer SHARE = SHARE64;
  // NVL=128：四档分组 share（同 T90），Σ≤Q20
  localparam integer SHARE_G0 = 705;
  localparam integer SHARE_G1 = 2710;
  localparam integer SHARE_G2 = 9152;
  localparam integer SHARE_G3 = 12902;
  localparam integer EXPECT_CFG_SUM_128 = 32*SHARE_G0 + 32*SHARE_G1
                                       + 32*SHARE_G2 + 32*SHARE_G3;
  localparam integer HOST_ACK_TIMEOUT = 2000; // gate ACK 放宽（RTL 通常远小于此）

  integer nvl = NVL_DEFAULT;
  integer rounds = ROUNDS_DEFAULT;

  reg clk = 0, reset = 1;
  always #4 clk = ~clk;
  integer cycle = 0;
  always @(posedge clk) cycle <= cycle + 1;
  // 低频进度：每 100 µs 仿真时间打一行（仅打印，不参与判据）
  integer prog_next_cyc = 12500; // 100e3 ns / 8 ns
  always @(posedge clk) begin
    if (!reset && cycle >= prog_next_cyc) begin
      $display("T91_PROGRESS sim_us=%0d cycle=%0d", cycle / 125, cycle);
      prog_next_cyc = prog_next_cyc + 12500;
    end
  end

  wire [7:0] tx_data, tx_data_b;
  wire tx_valid, tx_valid_b, tx_ready, tx_ready_b;
  // IF_MODE=2：线回环（同 tb_gate_public_loopback）
  wire [7:0] rx_data = tx_data;
  wire       rx_valid = tx_valid;
  wire [7:0] rx_data_b = tx_data_b;
  wire       rx_valid_b = tx_valid_b;

  reg host_cs = 0, host_we = 0;
  reg [15:0] host_addr = 0;
  reg [31:0] host_wdata = 0;
  wire [31:0] host_rdata;
  wire host_ack, host_irq;

  // VO 无 parameter 口；不加 #()。
  AFDX_top dut (
    .clk(clk), .reset(reset),
    .tx_data(tx_data), .rx_data(rx_data), .tx_valid(tx_valid), .rx_valid(rx_valid),
    .tx_ready(tx_ready), .rx_ready(1'b0),
    .tx_data_b(tx_data_b), .tx_valid_b(tx_valid_b), .tx_ready_b(tx_ready_b),
    .rx_data_b(rx_data_b), .rx_valid_b(rx_valid_b), .rx_ready_b(1'b0),
    .rx_error(1'b0), .rx_error_b(1'b0),
    .host_cs(host_cs), .host_we(host_we), .host_addr(host_addr), .host_wdata(host_wdata),
    .host_rdata(host_rdata), .host_ack(host_ack), .host_irq(host_irq),
    .pps_in(1'b0), .pps_out(), .rtc_time_us(), .dbg_frame_event()
  );

  integer errors = 0, checks = 0;
  integer host_ack_wait_max = 0;
  integer i, r, n, waitc, base, port_tx, port_rx;
  integer cfg_sum_rd = 0;
  integer rx_deliver_cnt = 0;
  integer first_sfd_a = 0, first_sfd_b = 0;
  integer last_eof_a = 0, last_eof_b = 0, last_rx_host = 0;
  integer window_cycles = 0;
  reg [63:0] tx_bytes_a = 0, tx_bytes_b = 0, rx_dedup_bytes = 0;
  integer vl_tx_cnt_a [0:NVL_MAX-1];
  integer vl_tx_cnt_b [0:NVL_MAX-1];
  integer prev_sfd_a [0:NVL_MAX-1];
  integer prev_sfd_b [0:NVL_MAX-1];
  integer commit_t [0:NVL_MAX-1][0:7]; // ROUNDS ≤8
  integer rx_host_t [0:NVL_MAX-1][0:7];
  integer port_rx_of [0:NVL_MAX-1];
  integer port_tx_of [0:NVL_MAX-1];
  integer rx_pool [0:NVL_MAX-1];
  integer vl_of_rx_port [0:255];
  reg [31:0] rd;
  integer csv, sfd;
  real tx_mbps_a, tx_mbps_b, rx_mbps;
  // 独立黄金：tools/gen_t91_payload_vec.py → sim/vec/t91_payload.hex（非 RTL 常量）
  reg [31:0] pay_mem [0:PAY_WORDS-1];
  integer window_start = 0, window_stop = 0;
  integer steady_first_round = 1; // 0-based：第 2 轮起计入吞吐

  reg tx_phase = 0;
  reg active_a = 0, active_b = 0;
  integer size_a = 0, size_b = 0, gap_a = 100, gap_b = 100;
  integer frame_start_a = 0, frame_start_b = 0;
  integer cap_sfd_a = 0, cap_sfd_b = 0;
  reg [7:0] cap_a [0:1599];
  reg [7:0] cap_b [0:1599];

  function integer share_for;
    input integer vl;
    input integer nvl_local;
    begin
      if (nvl_local <= 16)
        share_for = SHARE;
      else if (vl < 32)
        share_for = SHARE_G0;
      else if (vl < 64)
        share_for = SHARE_G1;
      else if (vl < 96)
        share_for = SHARE_G2;
      else
        share_for = SHARE_G3;
    end
  endfunction

  function integer expect_cfg_sum;
    input integer nvl_local;
    begin
      if (nvl_local <= 16)
        expect_cfg_sum = nvl_local * SHARE;
      else
        expect_cfg_sum = EXPECT_CFG_SUM_128;
    end
  endfunction

  task bad;
    input [8*120-1:0] why;
    begin
      if (errors < 40) $display("  [err] T91 cycle=%0d %0s", cycle, why);
      errors = errors + 1;
    end
  endtask

  task host_write;
    input [15:0] addr;
    input [31:0] data;
    begin
      @(negedge clk);
      host_cs = 1; host_we = 1; host_addr = addr; host_wdata = data;
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
    input [15:0] addr;
    output [31:0] data;
    begin
      @(negedge clk);
      host_cs = 1; host_we = 0; host_addr = addr;
      n = 0;
      while (host_ack !== 1'b1 && n < HOST_ACK_TIMEOUT) begin
        @(negedge clk); n = n + 1;
      end
      if (n > host_ack_wait_max) host_ack_wait_max = n;
      if (host_ack !== 1'b1) bad("host read ACK timeout");
      data = host_rdata;
      host_cs = 0;
    end
  endtask

  // 同 T88b/T90 桶混合（table0 / seed 0x172D）
  function [10:0] mix_bucket;
    input [15:0] vlid;
    input [15:0] seed;
    reg [15:0] x;
    begin
      x = vlid + seed + 16'h9E37;
      x = x ^ (x >> 7);
      x = x * 16'h9E37;
      x = x ^ (x >> 9);
      mix_bucket = x & 11'h7FF;
    end
  endfunction

  // 期望载荷只从 pay_mem（vec）取；公式仅在 gen_t91_payload_vec.py
  function [7:0] expect_pay;
    input integer vl, round, off;
    integer li, wi, bi;
    begin
      li = ((vl * PAY_ROUNDS_MAX) + round) * PLEN + off;
      wi = li / 4;
      bi = li % 4;
      expect_pay = pay_mem[wi][31 - 8 * bi -: 8];
    end
  endfunction

  function integer in_steady_window;
    input integer cyc;
    begin
      if (rounds < 2)
        in_steady_window = 1; // 探速 ROUNDS=1：整场计入（不宣称稳态 P）
      else
        in_steady_window = (cyc >= window_start && cyc < window_stop);
    end
  endfunction

  task wait_init;
    begin
      waitc = 0;
      host_read(16'h000C, rd);
      while (rd[13] !== 1'b1 && waitc < 40000) begin
        host_read(16'h000C, rd);
        waitc = waitc + 1;
      end
      if (rd[13] !== 1'b1) bad("INIT_DONE");
    end
  endtask

  task build_rx_pool;
    integer p, nn;
    begin
      nn = 0;
      for (p = 0; p < 256; p = p + 1)
        if (p != 6 && p != 7 &&
            (p < TX_PORT_BASE || p >= TX_PORT_BASE + nvl)) begin
          if (nn < nvl) begin
            rx_pool[nn] = p;
            nn = nn + 1;
          end
        end
      if (nn != nvl) bad("rx_pool size != nvl");
    end
  endtask

  task cfg_all;
    integer v, rx_idx, bucket, way;
    integer way0_vl [0:2047];
    begin
      build_rx_pool();
      for (v = 0; v < 256; v = v + 1) vl_of_rx_port[v] = -1;
      for (v = 0; v < 2048; v = v + 1) way0_vl[v] = -1;

      host_write(16'h0008, 32'h0000_2000); // CFG_MODE
      host_write(16'h0060, 32'h1234_2001);
      host_write(16'h0064, 32'h0A00_0001);
      host_write(16'h0070, 32'h0000_0142);
      host_write(16'h0078, 32'h0000_172D);
      host_write(16'h007C, 32'h0000_AB61);

      for (v = 0; v < nvl; v = v + 1) begin
        port_tx = TX_PORT_BASE + v;
        port_tx_of[v] = port_tx;
        host_write(16'h7D80 + 4 * port_tx + 3, 32'd1);
        host_write(16'h7D80 + 4 * port_tx, 32'h8000_C000 | v);
        host_write(16'h0200 + 5 * v + 4, port_tx << 16);
        host_write(16'h0200 + 5 * v + 3, 32'hE000_0001);
        host_write(16'h0200 + 5 * v + 2, 32'h1388_C000);
        host_write(16'h0200 + 5 * v + 1, BAG_US << 8);
        host_write(16'h0480 + v, share_for(v, nvl));
        host_write(16'h0200 + 5 * v, 32'h8000_0003 | (LMAX << 12)); // A+B
      end

      for (v = 0; v < nvl; v = v + 1) begin
        port_rx = rx_pool[v];
        port_rx_of[v] = port_rx;
        vl_of_rx_port[port_rx] = v;
        rx_idx = 12'h100 + v[11:0];
        bucket = mix_bucket(16'h0100 + v, 16'h172D);
        if (way0_vl[bucket] < 0) begin
          way = 0;
          way0_vl[bucket] = v;
        end else
          way = 1;
        host_write(16'h3D80 + (bucket << 1) + way,
                   {3'd0, 1'b1, 16'h0100 + v[15:0], rx_idx[11:0]});
        host_write(16'h1D80 + 2 * rx_idx, 32'hF500_0000 | (port_rx << 12) | LMAX);
        host_write(16'h1D80 + 2 * rx_idx + 1, {16'd0, 16'h0100 + v[15:0]});
        host_write(16'h7D80 + 4 * port_rx, 32'h8004_0000);
        host_write(16'h7D81 + 4 * port_rx, 32'h0000_1388);
        host_write(16'h7D82 + 4 * port_rx, 32'd0);
        host_write(16'h7D83 + 4 * port_rx, 32'd8);
      end

      host_write(16'h0080, 32'h1);
      host_read(16'h0058, rd);
      cfg_sum_rd = rd;
      if (rd !== expect_cfg_sum(nvl)) bad("CFG_SUM mismatch");
      host_read(16'h005C, rd);
      if (rd !== 0) bad("CFG_ERR nonzero");
      host_write(16'h0014, 32'h1);
      // SAP 开：0x051F（口预算含 6/7）；若关 SAP 可改 0x011F
      host_write(16'h0008, 32'h051F);
      $display("T91_CFG nvl=%0d rounds=%0d plen=%0d expect_cfg_sum=%0d ctl=0x051F",
               nvl, rounds, PLEN, expect_cfg_sum(nvl));
    end
  endtask

  task submit_msg;
    input integer vl, round, when_cyc;
    integer words_local, j;
    reg [7:0] pb;
    begin
      port_tx = port_tx_of[vl];
      host_read(16'h0074, rd);
      waitc = 0;
      while (rd[4] !== 1'b1 && waitc < 10000) begin
        host_read(16'h0074, rd);
        waitc = waitc + 1;
      end
      if (rd[4] !== 1'b1) bad("no TX block");
      base = 16'h8800 + (rd[3:0] << 9);
      words_local = (PLEN + 3) / 4;
      for (j = 0; j < words_local; j = j + 1) begin
        pb = expect_pay(vl, round, 4 * j);
        host_write(base + j, {pb,
                              expect_pay(vl, round, 4 * j + 1),
                              expect_pay(vl, round, 4 * j + 2),
                              expect_pay(vl, round, 4 * j + 3)});
      end
      while (cycle < when_cyc) @(negedge clk);
      if (round < 8) commit_t[vl][round] = cycle;
      host_write(16'h8280 + port_tx, PLEN);
    end
  endtask

  task finish_tx_frame;
    input integer net;
    integer vl, expect_size, round_seen, k, sn_off;
    begin
      if (net == 0) begin
        expect_size = size_a;
        if (expect_size < 8 + 64) begin bad("A frame too short"); disable finish_tx_frame; end
        vl = ((cap_a[12] << 8) | cap_a[13]) - 16'h0100;
        if (vl < 0 || vl >= nvl) begin bad("A VLID OOR"); disable finish_tx_frame; end
        if (expect_size != 8 + PLEN + 47) bad("A Lmax/DV length");
        if (cap_a[7] !== 8'hD5) bad("A SFD");
        sn_off = 8 + 42 + PLEN;
        round_seen = vl_tx_cnt_a[vl];
        if (round_seen >= rounds) bad("A extra frame");
        else begin
          if (cap_a[sn_off] !== ((round_seen % 255) + 1)) bad("A SN");
          // 载荷逐字节 vs vec（expect_pay ← t91_payload.hex）
          for (k = 0; k < PLEN; k = k + 1)
            if (cap_a[8 + 42 + k] !== expect_pay(vl, round_seen, k))
              bad("A payload vs vec");
          if (first_sfd_a == 0) first_sfd_a = cap_sfd_a;
          last_eof_a = cycle;
          // 同 VL 相邻帧 TX SFD 间隔 ≥ BAG（网 A）
          if (round_seen > 0 &&
              (cap_sfd_a - prev_sfd_a[vl]) < BAG_CYC)
            bad("A SFD gap < BAG");
          prev_sfd_a[vl] = cap_sfd_a;
          if (in_steady_window(cap_sfd_a))
            tx_bytes_a = tx_bytes_a + PLEN;
          vl_tx_cnt_a[vl] = round_seen + 1;
          checks = checks + 1;
        end
      end else begin
        expect_size = size_b;
        if (expect_size < 8 + 64) begin bad("B frame too short"); disable finish_tx_frame; end
        vl = ((cap_b[12] << 8) | cap_b[13]) - 16'h0100;
        if (vl < 0 || vl >= nvl) begin bad("B VLID OOR"); disable finish_tx_frame; end
        if (expect_size != 8 + PLEN + 47) bad("B Lmax/DV length");
        if (cap_b[7] !== 8'hD5) bad("B SFD");
        round_seen = vl_tx_cnt_b[vl];
        if (round_seen >= rounds) bad("B extra frame");
        else begin
          for (k = 0; k < PLEN; k = k + 1)
            if (cap_b[8 + 42 + k] !== expect_pay(vl, round_seen, k))
              bad("B payload vs vec");
          if (first_sfd_b == 0) first_sfd_b = cap_sfd_b;
          last_eof_b = cycle;
          // 同 VL 相邻帧 TX SFD 间隔 ≥ BAG（网 B）
          if (round_seen > 0 &&
              (cap_sfd_b - prev_sfd_b[vl]) < BAG_CYC)
            bad("B SFD gap < BAG");
          prev_sfd_b[vl] = cap_sfd_b;
          if (in_steady_window(cap_sfd_b))
            tx_bytes_b = tx_bytes_b + PLEN;
          vl_tx_cnt_b[vl] = round_seen + 1;
          checks = checks + 1;
        end
      end
    end
  endtask

  always @(posedge clk) if (!reset && tx_phase) begin
    if (tx_valid) begin
      if (!active_a) begin
        if (gap_a < 12 && size_a != 0) bad("A IFG");
        active_a = 1; size_a = 0; frame_start_a = cycle; cap_sfd_a = 0;
      end
      if (size_a < 1600) begin
        cap_a[size_a] = tx_data;
        if (cap_sfd_a == 0 && tx_data === 8'hD5) cap_sfd_a = cycle;
      end
      size_a = size_a + 1; gap_a = 0;
    end else begin
      gap_a = gap_a + 1;
      if (active_a) begin finish_tx_frame(0); active_a = 0; end
    end
    if (tx_valid_b) begin
      if (!active_b) begin
        if (gap_b < 12 && size_b != 0) bad("B IFG");
        active_b = 1; size_b = 0; frame_start_b = cycle; cap_sfd_b = 0;
      end
      if (size_b < 1600) begin
        cap_b[size_b] = tx_data_b;
        if (cap_sfd_b == 0 && tx_data_b === 8'hD5) cap_sfd_b = cycle;
      end
      size_b = size_b + 1; gap_b = 0;
    end else begin
      gap_b = gap_b + 1;
      if (active_b) begin finish_tx_frame(1); active_b = 0; end
    end
  end

  task drain_rx_once;
    integer p, plen_got, blk, guard, vl, slot, pi, wi, off, k, boff, j;
    reg [31:0] desc, pw;
    reg [7:0] got0;
    begin
      for (pi = 0; pi < nvl; pi = pi + 1) begin
        p = rx_pool[pi];
        host_read(16'h8480 + p, rd);
        guard = 0;
        while (rd != 0 && guard < 8) begin
          host_read(16'h8180 + p, desc);
          if (desc[31] !== 1'b1) bad("RX desc invalid");
          plen_got = desc[10:0];
          blk = desc[23:20];
          vl = vl_of_rx_port[p];
          if (vl < 0 || vl >= nvl) bad("RX port→vl map broken");
          if (plen_got != PLEN) bad("RX plen mismatch");
          host_read(16'h8800 + (blk << 9) + (42 >> 2), pw);
          got0 = pw[31 - 8 * (42 % 4) -: 8];
          slot = -1;
          for (j = 0; j < rounds; j = j + 1)
            if (got0 === expect_pay(vl, j, 0)) slot = j;
          if (slot < 0) bad("RX payload round unknown");
          if (slot < 8 && rx_host_t[vl][slot] != 0) bad("RX duplicate deliver slot");
          for (off = 0; off < plen_got; off = off + 1) begin
            boff = 42 + off;
            wi = boff / 4;
            k = boff % 4;
            if (off == 0 || k == 0)
              host_read(16'h8800 + (blk << 9) + wi, pw);
            if (pw[31 - 8 * k -: 8] !== expect_pay(vl, slot, off))
              bad("RX payload vs vec");
          end
          if (slot < 8) rx_host_t[vl][slot] = cycle;
          last_rx_host = cycle;
          host_write(16'h8380 + p, 32'd0);
          // 交付计数整场精确；吞吐字节仅稳态窗
          if (in_steady_window(cycle))
            rx_dedup_bytes = rx_dedup_bytes + plen_got;
          rx_deliver_cnt = rx_deliver_cnt + 1;
          host_read(16'h8480 + p, rd);
          guard = guard + 1;
          checks = checks + 1;
        end
      end
    end
  endtask

  integer t0, expect_rx, win_lo, win_hi;
  integer expect_tx;

  initial begin
    if ($value$plusargs("T91_NVL=%d", nvl)) ;
    if ($value$plusargs("T91_ROUNDS=%d", rounds)) ;
    if (nvl < 1 || nvl > NVL_MAX) begin
      $display("T91 FAIL: T91_NVL out of 1..%0d (128 不做)", NVL_MAX);
      $finish;
    end
    if (rounds < 1 || rounds > PAY_ROUNDS_MAX) begin
      $display("T91 FAIL: T91_ROUNDS out of 1..%0d", PAY_ROUNDS_MAX);
      $finish;
    end
    if (nvl * SHARE > 1048576) begin
      $display("T91 FAIL: nvl*SHARE=%0d > Q20", nvl * SHARE);
      $finish;
    end

    $readmemh("vec/t91_payload.hex", pay_mem);

    for (i = 0; i < NVL_MAX; i = i + 1) begin
      vl_tx_cnt_a[i] = 0; vl_tx_cnt_b[i] = 0;
      prev_sfd_a[i] = 0; prev_sfd_b[i] = 0;
      for (r = 0; r < 8; r = r + 1) begin
        commit_t[i][r] = 0; rx_host_t[i][r] = 0;
      end
    end

    csv = $fopen("t91_metrics.csv", "w");
    if (!csv) csv = $fopen("sim/out/t91_metrics.csv", "w");
    if (!csv) begin $display("T91 FAIL: cannot open t91_metrics.csv"); $finish; end
    $fwrite(csv, "direction,verified_payload_bytes,window_cycles,clock_period_ns,payload_mbps,nvl,rounds\n");

    repeat (8) @(negedge clk);
    reset = 0;
    wait_init();
    cfg_all();

    t0 = cycle;
    // 稳态窗：第 2..ROUNDS 轮（同 T42：跳过首 BAG）。ROUNDS=1 探速则整场。
    if (rounds >= 2) begin
      window_start = t0 + BAG_CYC;
      window_stop  = t0 + rounds * BAG_CYC;
      steady_first_round = 1;
    end else begin
      window_start = 0;
      window_stop  = 32'h7fff_ffff;
      steady_first_round = 0;
    end
    $display("T91_WINDOW_PLAN t0=%0d start=%0d stop=%0d rounds=%0d steady_rounds=%0d..%0d",
             t0, window_start, window_stop, rounds,
             (rounds >= 2) ? 2 : 1, rounds);

    tx_phase = 1;
    for (r = 0; r < rounds; r = r + 1)
      for (i = 0; i < nvl; i = i + 1) begin
        submit_msg(i, r, t0 + r * BAG_CYC + i * BAG_CYC / nvl);
        if (i[1:0] == 2'd3) drain_rx_once();
      end

    while (cycle < t0 + rounds * BAG_CYC + BAG_CYC) begin
      drain_rx_once();
      repeat (16) @(negedge clk);
    end
    tx_phase = 0;
    repeat (64) drain_rx_once();

    expect_tx = nvl * rounds;
    expect_rx = nvl * rounds;
    for (i = 0; i < nvl; i = i + 1) begin
      if (vl_tx_cnt_a[i] != rounds) bad("TX A missing rounds");
      if (vl_tx_cnt_b[i] != rounds) bad("TX B missing rounds");
    end
    // 交付数必须精确等于 NVL×ROUNDS（!= 即 FAIL）
    if (rx_deliver_cnt != expect_rx)
      bad("RX deliver != NVL*ROUNDS");

    // 吞吐窗长度 = 计划稳态窗（cycles）
    win_lo = window_start;
    win_hi = window_stop;
    if (win_hi <= win_lo) begin
      bad("empty throughput window");
      window_cycles = 1;
    end else
      window_cycles = win_hi - win_lo;

    tx_mbps_a = $itor(tx_bytes_a) * 8.0 / (window_cycles * 0.008);
    tx_mbps_b = $itor(tx_bytes_b) * 8.0 / (window_cycles * 0.008);
    rx_mbps   = $itor(rx_dedup_bytes) * 8.0 / (window_cycles * 0.008);

    if (tx_mbps_a < MIN_MBPS) bad("TX A payload Mbps <100");
    if (tx_mbps_b < MIN_MBPS) bad("TX B payload Mbps <100");
    if (rx_mbps < MIN_MBPS) bad("RX dedup payload Mbps <100");

    $fwrite(csv, "tx_a,%0d,%0d,8,%.6f,%0d,%0d\n",
            tx_bytes_a, window_cycles, tx_mbps_a, nvl, rounds);
    $fwrite(csv, "tx_b,%0d,%0d,8,%.6f,%0d,%0d\n",
            tx_bytes_b, window_cycles, tx_mbps_b, nvl, rounds);
    $fwrite(csv, "rx_dedup,%0d,%0d,8,%.6f,%0d,%0d\n",
            rx_dedup_bytes, window_cycles, rx_mbps, nvl, rounds);
    $fclose(csv);

    sfd = $fopen("t91_verilog_summary.json", "w");
    if (!sfd) sfd = $fopen("sim/out/t91_verilog_summary.json", "w");
    if (sfd) begin
      $fwrite(sfd, "{\"errors\":%0d,\"checks\":%0d,", errors, checks);
      $fwrite(sfd, "\"cfg_sum\":%0d,\"expect_cfg_sum\":%0d,\"share\":%0d,",
              cfg_sum_rd, expect_cfg_sum(nvl), SHARE);
      $fwrite(sfd, "\"tx_bytes_a\":%0d,\"tx_bytes_b\":%0d,\"rx_dedup_bytes\":%0d,",
              tx_bytes_a, tx_bytes_b, rx_dedup_bytes);
      $fwrite(sfd, "\"window_cycles\":%0d,\"window_start\":%0d,\"window_stop\":%0d,",
              window_cycles, window_start, window_stop);
      $fwrite(sfd, "\"rounds\":%0d,\"nvl\":%0d,\"plen\":%0d,",
              rounds, nvl, PLEN);
      $fwrite(sfd, "\"steady_first_round\":%0d,\"claim_mode\":\"%0s\",",
              steady_first_round, (rounds >= 2) ? "steady" : "probe");
      $fwrite(sfd, "\"tx_mbps_a\":%.6f,\"tx_mbps_b\":%.6f,\"rx_dedup_mbps\":%.6f,",
              tx_mbps_a, tx_mbps_b, rx_mbps);
      $fwrite(sfd, "\"rx_deliver\":%0d,\"expect_rx\":%0d,\"expect_tx\":%0d,",
              rx_deliver_cnt, expect_rx, expect_tx);
      $fwrite(sfd, "\"host_ack_wait_max\":%0d,\"host_ack_timeout\":%0d,",
              host_ack_wait_max, HOST_ACK_TIMEOUT);
      $fwrite(sfd, "\"min_mbps\":%0d,\"bag_us\":%0d,\"bag_cyc\":%0d,\"ctl\":%0d}\n",
              MIN_MBPS, BAG_US, BAG_CYC, 32'h051F);
      $fclose(sfd);
    end

    $display("T91_METRIC tx_a=%.3f tx_b=%.3f rx_dedup=%.3f Mbps nvl=%0d rounds=%0d",
             tx_mbps_a, tx_mbps_b, rx_mbps, nvl, rounds);
    $display("T91_WINDOW start=%0d stop=%0d cycles=%0d deliver=%0d expect=%0d (must ==) ack_max=%0d",
             window_start, window_stop, window_cycles, rx_deliver_cnt, expect_rx, host_ack_wait_max);

    if (errors == 0 &&
        tx_mbps_a >= MIN_MBPS && tx_mbps_b >= MIN_MBPS && rx_mbps >= MIN_MBPS &&
        rx_deliver_cnt == expect_rx)
      $display("T91 GATE THROUGHPUT PASS checks=%0d nvl=%0d rounds=%0d",
               checks, nvl, rounds);
    else
      $display("T91 GATE THROUGHPUT FAIL errors=%0d checks=%0d deliver=%0d expect=%0d",
               errors, checks, rx_deliver_cnt, expect_rx);
    $finish;
  end

  initial begin
    #200_000_000; // 200 ms 仿真时限（R=3 + 余量）
    $display("T91 GATE THROUGHPUT FAIL: timeout");
    $finish;
  end
endmodule
