// =====================================================================
// tb_t03_frame_builder.v —— T03 帧构建器对黄金模型逐字节比对（§7.3/§6）
// 向量: sim/vec/t03_frames.hex（sw/golden/gen_t03_vectors.py 生成，勿手改）
//   16 帧: L=8/17/18/19（填充边界）、1471/1470（上界）、9/100 + 8 个随机；
//   第 4 帧 UDP 校验和关闭（csum_en=0 → 字段 0）。
// DUT 环境: bram_sdp(32×8192) 当 PMEM（1W2R：A 口 pass1、B 口 pass2），
//   tx_sn_gen 真实例化（SN 由 host_override 预置为向量值），
//   接收端 3 种 out_rdy 模式: (a) 10 拍/字节线速节拍 (b) 每拍 rdy=1 压力
//   (c) 随机背压。每帧: 字节流 == 期望帧、长度 == max(60,43+L)、
//   B 网字节仅偏移 10 低 4 位不同、blk_free 恰 1 次、done 恰 1 次、
//   p1_stall_cnt == 0（pass1 早于偏移 40 完成）。
// 性能记录: 打印 start→首字节拍数、start→done 拍数（写入报告）。
// 判据: 末行 "T03 BUILDER PASS" / "T03 BUILDER FAIL: n errors"
// =====================================================================
`timescale 1 ns / 1 ps
module tb_t03_frame_builder;
  reg clk = 1'b0;
  reg reset = 1'b1;
  always #4 clk = ~clk;
  integer err = 0;
  integer i, k, f, mode;

  // ---- 向量存储 ----
  localparam integer VEC_WORDS = 1 + 16 * (6 + 368 + 380);
  reg [31:0] vec [0:VEC_WORDS-1];
  integer nframes;

  // ---- PMEM ----
  reg          m_we = 0;
  reg  [12:0]  m_waddr = 0;
  reg  [31:0]  m_wdata = 0;
  wire         rd_en_a, rd_en_b;
  wire [12:0]  rd_addr_a, rd_addr_b;
  wire [31:0]  rd_data_a, rd_data_b;
  bram_sdp #(.W(32), .D(8192)) u_pmem (
    .clk(clk), .wr_en(m_we), .wr_addr(m_waddr), .wr_data(m_wdata),
    .rd_en_a(rd_en_a), .rd_addr_a(rd_addr_a), .rd_data_a(rd_data_a),
    .rd_en_b(rd_en_b), .rd_addr_b(rd_addr_b), .rd_data_b(rd_data_b));

  // ---- SN ----
  wire        snap_req, snap_ack;
  wire [7:0]  snap_vl, snap;
  reg         sn_ovr_we = 0;
  reg  [7:0]  sn_ovr_vl = 0, sn_ovr_val = 0;
  reg         sn_commit = 0;
  reg  [7:0]  sn_commit_vl = 0;
  wire [1:0]  sn_pend;
  wire        sn_err;
  tx_sn_gen #(.NUM_TX_VL(128)) u_sn (
    .clk(clk), .rst_sync(reset),
    .snap_req(snap_req), .snap_vl(snap_vl), .snap(snap), .snap_ack(snap_ack),
    .commit(sn_commit), .commit_vl(sn_commit_vl),
    .init_all(1'b0), .ovr_we(sn_ovr_we), .ovr_vl(sn_ovr_vl), .ovr_val(sn_ovr_val),
    .sn_pend(sn_pend), .err(sn_err));

  // ---- DUT ----
  reg         start_vld = 0;
  reg  [7:0]  start_vl = 0;
  reg  [3:0]  start_blk = 0;
  reg  [12:0] start_len = 0;
  reg  [15:0] h_vlid = 0, h_ident = 0, h_sport = 0, h_dport = 0;
  reg  [7:0]  h_udi = 0, h_tos = 0, h_ttl = 0;
  reg  [3:0]  h_ifid = 0;
  reg  [31:0] h_sip = 0, h_dip = 0;
  reg         h_csum_en = 1;
  wire        busy, done, len_err, out_vld, out_sof, out_eof, blk_free;
  wire [7:0]  out_a, out_b;
  wire [3:0]  blk_free_id;
  wire [15:0] p1_stall_cnt;
  reg         out_rdy = 0;
  tx_frame_builder #(.BYTE_SLOT_CYC(10)) dut (
    .clk(clk), .rst_sync(reset),
    .start_vld(start_vld), .start_vl(start_vl), .start_blk(start_blk), .start_len(start_len),
    .busy(busy), .done(done), .len_err(len_err),
    .hdr_vlid(h_vlid), .hdr_udi(h_udi), .hdr_ifid(h_ifid), .hdr_net_a(4'd1), .hdr_net_b(4'd2),
    .hdr_tos(h_tos), .hdr_ttl(h_ttl), .hdr_ident(h_ident), .hdr_src_ip(h_sip), .hdr_dst_ip(h_dip),
    .hdr_sport(h_sport), .hdr_dport(h_dport), .hdr_udp_csum_en(h_csum_en),
    .snap_req(snap_req), .snap_vl(snap_vl), .snap(snap), .snap_ack(snap_ack),
    .rd_en_a(rd_en_a), .rd_addr_a(rd_addr_a), .rd_data_a(rd_data_a),
    .rd_en_b(rd_en_b), .rd_addr_b(rd_addr_b), .rd_data_b(rd_data_b),
    .out_vld(out_vld), .out_byte_a(out_a), .out_byte_b(out_b), .out_sof(out_sof), .out_eof(out_eof),
    .out_rdy(out_rdy),
    .blk_free(blk_free), .blk_free_id(blk_free_id), .p1_stall_cnt(p1_stall_cnt));

  // ---- 接收端 ready 生成 ----
  // mode 0: 10 拍节拍；1: 常 1；2: 随机
  integer pace = 0;
  reg [31:0] rnd = 32'h5EED;
  always @(posedge clk) begin
    if (reset) begin out_rdy <= 1'b0; pace <= 0; end
    else begin
      case (mode)
        0: begin pace <= (pace == 9) ? 0 : pace + 1; out_rdy <= (pace == 9); end
        1: out_rdy <= 1'b1;
        default: begin rnd <= {rnd[30:0], rnd[31] ^ rnd[21] ^ rnd[1] ^ rnd[0]}; out_rdy <= rnd[3] | rnd[7]; end
      endcase
    end
  end

  // ---- 捕获 ----
  reg [7:0]  cap_a [0:1600];
  reg [7:0]  cap_b [0:1600];
  integer    cap_n, n_free, n_done, first_cyc, done_cyc, cyc, start_cyc;
  reg        seen_sof;
  always @(posedge clk) begin
    cyc <= cyc + 1;
    if (out_vld && out_rdy) begin
      if (cap_n == 0 && !out_sof) begin $display("  [err] first byte without sof"); err = err + 1; end
      if (cap_n == 0) first_cyc = cyc;
      cap_a[cap_n] <= out_a; cap_b[cap_n] <= out_b; cap_n <= cap_n + 1;
    end
    if (blk_free) n_free <= n_free + 1;
    if (done) begin n_done <= n_done + 1; done_cyc = cyc; end
  end

  // 模式 0 结束时刻的 stall 快照 / 越界 / sn err 观察（声明前置: vlog-2730）
  reg [15:0] stall_after_mode0 = 16'hFFFF;
  always @(posedge clk) if (mode == 1 && stall_after_mode0 == 16'hFFFF) stall_after_mode0 <= p1_stall_cnt;
  reg len_err_seen = 0;
  always @(posedge clk) if (len_err) len_err_seen <= 1'b1;
  integer sn_err_cnt = 0;
  always @(posedge clk) if (sn_err) sn_err_cnt = sn_err_cnt + 1;

  // 期望帧读取
  integer base, L, sn, csum_en, flen, w;
  reg [3:0] fblk;
  reg [31:0] ew;
  reg [7:0]  eb;
  integer sum_first, sum_done, min_first, max_first;

  task run_frame; input integer fi; input integer md;
    begin
      mode = md;
      base = 1 + fi * (6 + 368 + 380);
      L = vec[base+5][31:19]; sn = vec[base+5][18:11]; csum_en = vec[base+5][10];
      flen = (43 + L < 60) ? 60 : 43 + L;
      fblk = fi % 6;
      // 装载 PMEM 块 (fi % 6)
      for (w = 0; w < 368; w = w + 1) begin
        @(negedge clk); m_we <= 1'b1; m_waddr <= {fblk, w[8:0]}; m_wdata <= vec[base+6+w];
      end
      @(negedge clk); m_we <= 1'b0;
      // 预置 SN
      @(negedge clk); sn_ovr_we <= 1'b1; sn_ovr_vl <= fi[7:0]; sn_ovr_val <= sn[7:0];
      @(negedge clk); sn_ovr_we <= 1'b0;
      // 参数
      h_vlid <= vec[base][31:16]; h_udi <= vec[base][15:8]; h_ifid <= vec[base][7:4];
      h_sport <= vec[base+1][31:16]; h_dport <= vec[base+1][15:0];
      h_sip <= vec[base+2]; h_dip <= vec[base+3];
      h_ident <= vec[base+4][31:16]; h_tos <= vec[base+4][15:8]; h_ttl <= vec[base+4][7:0];
      h_csum_en <= csum_en[0];
      cap_n = 0; n_free = 0; n_done = 0; seen_sof = 0;
      @(negedge clk);
      start_cyc = cyc;
      start_vld <= 1'b1; start_vl <= fi[7:0]; start_blk <= fblk; start_len <= L[12:0];
      @(negedge clk); start_vld <= 1'b0;
      // 等 done
      k = 0;
      while (n_done == 0 && k < 40000) begin @(negedge clk); k = k + 1; end
      @(negedge clk); @(negedge clk);
      if (n_done != 1) begin $display("  [err] f%0d mode%0d: done count=%0d", fi, md, n_done); err = err + 1; end
      if (n_free != 1) begin $display("  [err] f%0d mode%0d: blk_free count=%0d", fi, md, n_free); err = err + 1; end
      if (busy) begin $display("  [err] f%0d: busy still high", fi); err = err + 1; end
      if (cap_n != flen) begin $display("  [err] f%0d mode%0d: len got=%0d want=%0d", fi, md, cap_n, flen); err = err + 1; end
      for (k = 0; k < flen && k < cap_n; k = k + 1) begin
        ew = vec[base + 6 + 368 + (k >> 2)];
        case (k & 3) 0: eb = ew[31:24]; 1: eb = ew[23:16]; 2: eb = ew[15:8]; default: eb = ew[7:0]; endcase
        if (cap_a[k] !== eb) begin
          if (err < 40) $display("  [err] f%0d mode%0d L=%0d byte[%0d] got=%02x want=%02x", fi, md, L, k, cap_a[k], eb);
          err = err + 1;
        end
        if (k == 10) begin
          if (cap_b[k] !== {eb[7:4], 4'd2}) begin $display("  [err] f%0d B-net smac[4]=%02x", fi, cap_b[k]); err = err + 1; end
        end else if (cap_b[k] !== cap_a[k]) begin
          $display("  [err] f%0d B-net byte[%0d] differs", fi, k); err = err + 1;
        end
      end
      // 提交 SN（模拟 mac_tx_if.frame_done）
      @(negedge clk); sn_commit <= 1'b1; sn_commit_vl <= fi[7:0]; @(negedge clk); sn_commit <= 1'b0;
      if (md == 0) begin
        sum_first = sum_first + (first_cyc - start_cyc);
        sum_done  = sum_done  + (done_cyc  - start_cyc);
        if (first_cyc - start_cyc < min_first) min_first = first_cyc - start_cyc;
        if (first_cyc - start_cyc > max_first) max_first = first_cyc - start_cyc;
      end
    end
  endtask

  initial begin
    cyc = 0; sum_first = 0; sum_done = 0; min_first = 1 << 30; max_first = 0; mode = 0;
    $readmemh("vec/t03_frames.hex", vec);
    nframes = vec[0];
    $display("== T03: %0d golden frames", nframes);
    repeat (4) @(negedge clk);
    reset <= 1'b0;
    repeat (4) @(negedge clk);

    // 模式 0: 线速节拍（全部帧）
    for (f = 0; f < nframes; f = f + 1) run_frame(f, 0);
    $display("  [ok] mode0 (10 cyc/byte): %0d frames; start->first byte %0d..%0d cyc, avg start->done %0d cyc",
             nframes, min_first, max_first, sum_done / nframes);
    // 模式 1: 每拍 ready（压力）
    for (f = 0; f < nframes; f = f + 1) run_frame(f, 1);
    $display("  [ok] mode1 (rdy=1 every cycle): %0d frames", nframes);
    // 模式 2: 随机背压
    for (f = 0; f < nframes; f = f + 1) run_frame(f, 2);
    $display("  [ok] mode2 (random backpressure): %0d frames", nframes);

    if (p1_stall_cnt !== 16'd0) begin
      // 模式 1 下 pass1 (368 拍) 可能晚于偏移 40 (40 拍)——这是预期停顿，
      // 只在模式 0 下要求为 0：模式 0 在前，先记录后清零判断
      $display("  [info] p1_stall_cnt=%0d (expected >0 only from mode1/2 stress)", p1_stall_cnt);
    end
    if (stall_after_mode0 !== 16'd0) begin
      $display("  [err] p1_stall_cnt after mode0 = %0d (pass1 must finish before offset 40 at line rate)", stall_after_mode0);
      err = err + 1;
    end
    // 越界长度
    @(negedge clk); start_vld <= 1'b1; start_len <= 13'd1472; start_blk <= 4'd0; start_vl <= 8'd0;
    @(negedge clk); start_vld <= 1'b0;
    @(negedge clk);
    if (!len_err_seen || busy) begin $display("  [err] L=1472 not rejected"); err = err + 1; end
    @(negedge clk); start_vld <= 1'b1; start_len <= 13'd7;
    @(negedge clk); start_vld <= 1'b0;
    @(negedge clk);
    if (busy) begin $display("  [err] L=7 not rejected"); err = err + 1; end
    if (sn_err_cnt != 0) begin $display("  [err] tx_sn_gen err pulses = %0d", sn_err_cnt); err = err + 1; end

    if (err == 0)
      $display("T03 BUILDER PASS (%0d golden frames x 3 rdy modes, L=8..1471, pad/SN/csum/B-net, stall=0 at line rate)", nframes);
    else
      $display("T03 BUILDER FAIL: %0d errors", err);
    $finish;
  end

  initial begin
    $dumpfile("out/t03_frame_builder.vcd");
    $dumpvars(0, tb_t03_frame_builder);
  end
endmodule
