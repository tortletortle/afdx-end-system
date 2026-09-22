// =====================================================================
// tb_t00_common.v —— T00 黄金模型自检 + CRC 常数一致性（§12.2，公共）
// 检查 1: crc32 8 个模式向量 byte[i]=(i*mult+add)&0xFF + 1 个真实 AFDX 帧
//       （60 B，L=8 最小载荷）。期望值由 sw/golden/gen_crc_vectors.py
//       生成（黄金模型 = zlib.crc32 单一来源），勿手改。
// 检查 2: sync_fifo(8x32) 全行为——空/满标志、写溢出保护（满写被拒）、
//       读空保护、满/空边界同时读写（满:写丢读通；空:写通读丢）、
//       4000 拍随机压力对照 TB 参考模型（含 full/empty 逐拍对账）；
//       sync_fifo(32x4) 参数化抽查。
// 检查 3: bram_sdp(32x8192, PMEM 规格, 1W2R)——A 口全地址扫描、
//       B 口步长 97 抽样、覆写、1 拍读延迟（扫描隐含）、
//       写/A读/B读 三口同拍并发。
//       不测同地址同拍读写（O-20 第 3 条: 不做同拍读写假设）。
// 波形: out/t00_common.vcd（$dumpvars(0, tb)——兼作踩坑#11 对照实验）
// =====================================================================
`timescale 1 ns / 1 ps
module tb_t00_common;
  reg clk = 1'b0;
  reg reset = 1'b1;
  always #4 clk = ~clk;              // 125 MHz = 8 ns

  integer err = 0;
  integer i, j, k;

  // ---- DUT 1: crc32（§7.19）----
  reg         c_init = 1'b0;
  reg         c_dv   = 1'b0;
  reg  [7:0]  c_d    = 8'h0;
  wire [31:0] c_out, c_final;
  crc32 u_crc (.clk(clk), .rst(reset), .init(c_init),
               .data_valid(c_dv), .data(c_d),
               .crc_out(c_out), .crc_final(c_final));

  // ---- DUT 2/3: sync_fifo 8x32（§7.6 用）与 32x4（参数化抽查）----
  reg         f8_wr_en = 1'b0, f8_rd_en = 1'b0;
  reg  [7:0]  f8_wr_data = 8'h0;
  wire [7:0]  f8_rd_data;
  wire        f8_full, f8_empty;
  sync_fifo #(.W(8),  .D(32)) u_f8 (
    .clk(clk), .rst(reset),
    .wr_en(f8_wr_en), .wr_data(f8_wr_data),
    .rd_en(f8_rd_en), .rd_data(f8_rd_data),
    .full(f8_full), .empty(f8_empty));

  reg         f4_wr_en = 1'b0, f4_rd_en = 1'b0;
  reg  [31:0] f4_wr_data = 32'h0;
  wire [31:0] f4_rd_data;
  wire        f4_full, f4_empty;
  sync_fifo #(.W(32), .D(4))  u_f4 (
    .clk(clk), .rst(reset),
    .wr_en(f4_wr_en), .wr_data(f4_wr_data),
    .rd_en(f4_rd_en), .rd_data(f4_rd_data),
    .full(f4_full), .empty(f4_empty));

  // ---- DUT 4: bram_sdp 32x8192（PMEM 规格 §8.6；1W2R，§7.14）----
  reg          b_we = 1'b0, b_re_a = 1'b0, b_re_b = 1'b0;
  reg  [12:0]  b_waddr = 13'd0, b_raddr_a = 13'd0, b_raddr_b = 13'd0;
  reg  [31:0]  b_wdata = 32'h0;
  wire [31:0]  b_rd_data_a, b_rd_data_b;
  bram_sdp #(.W(32), .D(8192)) u_bram (
    .clk(clk),
    .wr_en(b_we), .wr_addr(b_waddr), .wr_data(b_wdata),
    .rd_en_a(b_re_a), .rd_addr_a(b_raddr_a), .rd_data_a(b_rd_data_a),
    .rd_en_b(b_re_b), .rd_addr_b(b_raddr_b), .rd_data_b(b_rd_data_b));

  // ---- 真实 AFDX 帧向量（gen_crc_vectors.py 生成，勿手改）----
  // build_frame(vlid=0x0102, udi=0x33, ifid=5, net_id=0xA,
  //   10.0.1.1->10.0.2.2, 5001->5002, payload=00..07, sn=7)
  //   body 60 B, FCS=0xC45B5174
  reg [7:0] frame60 [0:59];
  initial begin
    frame60[ 0]=8'h03; frame60[ 1]=8'h00; frame60[ 2]=8'h00; frame60[ 3]=8'h00;
    frame60[ 4]=8'h01; frame60[ 5]=8'h02; frame60[ 6]=8'h02; frame60[ 7]=8'h00;
    frame60[ 8]=8'h00; frame60[ 9]=8'h33; frame60[10]=8'h5A; frame60[11]=8'h00;
    frame60[12]=8'h08; frame60[13]=8'h00; frame60[14]=8'h45; frame60[15]=8'h00;
    frame60[16]=8'h00; frame60[17]=8'h25; frame60[18]=8'h00; frame60[19]=8'h00;
    frame60[20]=8'h40; frame60[21]=8'h00; frame60[22]=8'hFF; frame60[23]=8'h11;
    frame60[24]=8'h64; frame60[25]=8'hC5; frame60[26]=8'h0A; frame60[27]=8'h00;
    frame60[28]=8'h01; frame60[29]=8'h01; frame60[30]=8'h0A; frame60[31]=8'h00;
    frame60[32]=8'h02; frame60[33]=8'h02; frame60[34]=8'h13; frame60[35]=8'h89;
    frame60[36]=8'h13; frame60[37]=8'h8A; frame60[38]=8'h00; frame60[39]=8'h11;
    frame60[40]=8'hAE; frame60[41]=8'hA6; frame60[42]=8'h00; frame60[43]=8'h01;
    frame60[44]=8'h02; frame60[45]=8'h03; frame60[46]=8'h04; frame60[47]=8'h05;
    frame60[48]=8'h06; frame60[49]=8'h07; frame60[50]=8'h07; frame60[51]=8'h00;
    frame60[52]=8'h00; frame60[53]=8'h00; frame60[54]=8'h00; frame60[55]=8'h00;
    frame60[56]=8'h00; frame60[57]=8'h00; frame60[58]=8'h00; frame60[59]=8'h00;
  end

  // ================ 任务 ================
  // integer -> 13 bit address (V2001 has no bit-select on expressions;
  // project precedent tb_t01 line 82 uses i[7:0] on integers - vlog OK)
  function [12:0] j13;
    input integer v;
    begin
      j13 = v[12:0];
    end
  endfunction

  // 模式向量 CRC：字节 (k*mult+add)&0xFF 共 nlen 个
  // 注意: 参数不能叫 expect（SystemVerilog 2005 保留字，Verilator 5.006
  // 按 V2001 解析也会拒绝），用 expect_crc
  task crc_pattern(input integer nlen, input integer mult, input integer add,
                   input [31:0] expect_crc);
    begin
      @(negedge clk);
      c_init <= 1'b1;
      @(negedge clk);
      c_init <= 1'b0;
      for (k = 0; k < nlen; k = k + 1) begin
        c_d  <= (k*mult + add) & 255;
        c_dv <= 1'b1;
        @(negedge clk);
      end
      c_dv <= 1'b0;
      @(negedge clk);
      if (c_final !== expect_crc) begin
        $display("  [err] crc32 pattern len=%0d mult=%0d add=%0d got=%h want=%h",
                 nlen, mult, add, c_final, expect_crc);
        err = err + 1;
      end else
        $display("  [ok] crc32 pattern len=%0d -> %h", nlen, expect_crc);
    end
  endtask

  // 真实帧向量 CRC（60 字节数组）
  task crc_frame(input [31:0] expect_crc);
    begin
      @(negedge clk);
      c_init <= 1'b1;
      @(negedge clk);
      c_init <= 1'b0;
      for (k = 0; k < 60; k = k + 1) begin
        c_d  <= frame60[k];
        c_dv <= 1'b1;
        @(negedge clk);
      end
      c_dv <= 1'b0;
      @(negedge clk);
      if (c_final !== expect_crc) begin
        $display("  [err] crc32 golden frame got=%h want=%h", c_final, expect_crc);
        err = err + 1;
      end else
        $display("  [ok] crc32 golden AFDX frame (60 B) -> %h", expect_crc);
    end
  endtask

  // ================ 主序列 ================
  // fifo 参考模型（随机压力用）
  reg [7:0]  fq [0:63];
  integer    f_head, f_cnt;
  reg [7:0]  exp_rd;
  reg        prd, wr_acc, rd_acc;
  reg [31:0] r;

  initial begin
    #80;                              // 复位稳定（含 rst_sync 3 拍）
    reset <= 1'b0;
    repeat (8) @(negedge clk);

    // ---- 1) CRC32 向量（期望值: gen_crc_vectors.py）----
    crc_pattern(   0,  7,   0, 32'h0000_0000);  // 空
    crc_pattern(   9,  1,  49, 32'hCBF4_3926);  // "123456789"
    crc_pattern(   1,  0,   0, 32'hD202_EF8D);  // 单字节 0x00
    crc_pattern(   1,  0, 255, 32'hFF00_0000);  // 单字节 0xFF
    crc_pattern(  17,  7,   3, 32'h7BA7_5EE3);  // 奇数长
    crc_pattern(  64, 13,   5, 32'h708E_E432);  // 64 B 帧
    crc_pattern(  60, 11,   9, 32'h0812_159D);  // 60 B 最小帧
    crc_pattern(1518, 31,  17, 32'h32CF_6A27);  // 1518 B 最大帧
    crc_frame(32'hC45B_5174);                   // 黄金模型真实帧

    // ---- 2) sync_fifo 8x32 ----
    // 2a) 复位后标志
    if (f8_empty !== 1'b1 || f8_full !== 1'b0) begin
      $display("  [err] fifo8 flags after reset: empty=%b full=%b", f8_empty, f8_full);
      err = err + 1;
    end
    // 2b) 写 1 读 1
    @(negedge clk); f8_wr_en <= 1'b1; f8_wr_data <= 8'hA5;
    @(negedge clk); f8_wr_en <= 1'b0;
    if (f8_empty !== 1'b0) begin
      $display("  [err] fifo8 not non-empty after 1 write"); err = err + 1;
    end
    @(negedge clk); f8_rd_en <= 1'b1;
    @(negedge clk); f8_rd_en <= 1'b0;
    if (f8_rd_data !== 8'hA5) begin
      $display("  [err] fifo8 readback got=%h want=A5", f8_rd_data); err = err + 1;
    end
    if (f8_empty !== 1'b1) begin
      $display("  [err] fifo8 not empty after drain"); err = err + 1;
    end
    // 2c) 填满 32（值 1..32）→ 满写被拒 → 读回核对顺序
    for (i = 0; i < 32; i = i + 1) begin
      @(negedge clk); f8_wr_en <= 1'b1; f8_wr_data <= i[7:0] + 8'd1;
    end
    @(negedge clk); f8_wr_en <= 1'b0;
    if (f8_full !== 1'b1) begin
      $display("  [err] fifo8 not full after 32 writes"); err = err + 1;
    end
    @(negedge clk); f8_wr_en <= 1'b1; f8_wr_data <= 8'hEE;   // 满写：应被拒
    @(negedge clk); f8_wr_en <= 1'b0;
    if (f8_full !== 1'b1) begin
      $display("  [err] fifo8 full flag lost during rejected write"); err = err + 1;
    end
    @(negedge clk);
    for (i = 0; i < 32; i = i + 1) begin
      f8_rd_en <= 1'b1;
      @(negedge clk);
      if (f8_rd_data !== (i[7:0] + 8'd1)) begin
        $display("  [err] fifo8 order: read #%0d got=%0d want=%0d",
                 i, f8_rd_data, i + 1); err = err + 1;
      end
    end
    f8_rd_en <= 1'b0;
    if (f8_empty !== 1'b1) begin
      $display("  [err] fifo8 not empty after 32 reads"); err = err + 1;
    end
    // 2d) 满: 同拍写+读 → 写丢读通（保守满语义，§7.6）
    for (i = 0; i < 32; i = i + 1) begin
      @(negedge clk); f8_wr_en <= 1'b1; f8_wr_data <= i[7:0] + 8'd101;
    end
    @(negedge clk); f8_wr_en <= 1'b1; f8_wr_data <= 8'h77; f8_rd_en <= 1'b1;
    @(negedge clk); f8_wr_en <= 1'b0; f8_rd_en <= 1'b0;
    if (f8_rd_data !== 8'd101) begin
      $display("  [err] fifo8 full rd+wr: got=%0d want=101", f8_rd_data); err = err + 1;
    end
    if (f8_full !== 1'b0 || f8_empty !== 1'b0) begin
      $display("  [err] fifo8 flags after full rd+wr: full=%b empty=%b",
               f8_full, f8_empty); err = err + 1;
    end
    // 2e) 排空到空 → 空: 同拍写+读 → 写通读丢
    @(negedge clk); f8_rd_en <= 1'b1;
    repeat (31) @(negedge clk);
    f8_rd_en <= 1'b0;
    if (f8_empty !== 1'b1) begin
      $display("  [err] fifo8 not empty before empty rd+wr"); err = err + 1;
    end
    @(negedge clk); f8_wr_en <= 1'b1; f8_wr_data <= 8'h99; f8_rd_en <= 1'b1;
    @(negedge clk); f8_wr_en <= 1'b0; f8_rd_en <= 1'b0;
    if (f8_empty !== 1'b0) begin
      $display("  [err] fifo8 empty rd+wr: write must be accepted"); err = err + 1;
    end
    @(negedge clk); f8_rd_en <= 1'b1;
    @(negedge clk); f8_rd_en <= 1'b0;
    if (f8_rd_data !== 8'h99) begin
      $display("  [err] fifo8 readback after empty rd+wr got=%h", f8_rd_data); err = err + 1;
    end
    // 2f) 随机压力 4000 拍（参考模型逐拍对账）
    f_head = 0; f_cnt = 0; prd = 1'b0; r = 32'h1;
    for (i = 0; i < 4000; i = i + 1) begin
      @(negedge clk);
      if (prd && (f8_rd_data !== exp_rd)) begin
        $display("  [err] fifo8 random #%0d: got=%h want=%h", i, f8_rd_data, exp_rd);
        err = err + 1;
      end
      if (f8_full !== (f_cnt == 32)) begin
        $display("  [err] fifo8 random #%0d: full=%b model_cnt=%0d", i, f8_full, f_cnt);
        err = err + 1;
      end
      if (f8_empty !== (f_cnt == 0)) begin
        $display("  [err] fifo8 random #%0d: empty=%b model_cnt=%0d", i, f8_empty, f_cnt);
        err = err + 1;
      end
      r = r * 32'd1664525 + 32'd1013904223;      // LCG
      f8_wr_en   <= r[0];
      f8_rd_en   <= r[8];
      f8_wr_data <= r[15:8];
      wr_acc = r[0] & (f_cnt < 32);              // wr = wr_en & ~full
      rd_acc = r[8] & (f_cnt > 0);               // rd = rd_en & ~empty
      if (rd_acc) exp_rd = fq[f_head];
      if (wr_acc) fq[(f_head + f_cnt) % 64] = r[15:8];
      if (wr_acc & ~rd_acc) f_cnt = f_cnt + 1;
      if (~wr_acc & rd_acc) f_cnt = f_cnt - 1;
      if (rd_acc) f_head = (f_head + 1) % 64;
      prd = rd_acc;
    end
    // 排空并核对总量
    f8_wr_en <= 1'b0;
    @(negedge clk); f8_rd_en <= 1'b1;
    while (f8_empty !== 1'b1) @(negedge clk);
    f8_rd_en <= 1'b0;
    $display("  [ok] fifo8 random stress 4000 beats, drained (empty=%b)", f8_empty);

    // 2g) sync_fifo 32x4 参数化抽查
    for (i = 0; i < 4; i = i + 1) begin
      @(negedge clk); f4_wr_en <= 1'b1; f4_wr_data <= 32'hA100_0000 + i;
    end
    @(negedge clk); f4_wr_en <= 1'b0;
    if (f4_full !== 1'b1) begin
      $display("  [err] fifo4 not full after 4 writes"); err = err + 1;
    end
    @(negedge clk);
    for (i = 0; i < 4; i = i + 1) begin
      f4_rd_en <= 1'b1;
      @(negedge clk);
      if (f4_rd_data !== (32'hA100_0000 + i)) begin
        $display("  [err] fifo4 read #%0d got=%h", i, f4_rd_data); err = err + 1;
      end
    end
    f4_rd_en <= 1'b0;
    if (f4_empty !== 1'b1) begin
      $display("  [err] fifo4 not empty after drain"); err = err + 1;
    end

    // ---- 3) bram_sdp 32x8192（1W2R: A 口主测，B 口抽样+并发）----
    // 3a) 全地址扫描写: mem[i] = i*3+1
    @(negedge clk); b_we <= 1'b1;
    for (i = 0; i < 8192; i = i + 1) begin
      b_waddr <= j13(i); b_wdata <= i*3 + 1;
      @(negedge clk);
    end
    b_we <= 1'b0;
    // 3b) A 口流水读回（rd_en 常 1，地址每拍 +1，1 拍延迟隐含验证）
    @(negedge clk); b_re_a <= 1'b1; b_raddr_a <= 13'd0;
    for (i = 0; i < 8192; i = i + 1) begin
      @(negedge clk);
      if (b_rd_data_a !== (i*3 + 1)) begin
        $display("  [err] bram A readback addr=%0d got=%0d want=%0d",
                 i, b_rd_data_a, i*3 + 1); err = err + 1;
      end
      b_raddr_a <= j13(i + 1);
    end
    b_re_a <= 1'b0;
    $display("  [ok] bram A full sweep 8192 words");
    // 3b') B 口抽样读（步长 97 互质覆盖地址位）
    @(negedge clk); b_re_b <= 1'b1;
    for (i = 0; i < 8192; i = i + 97) begin
      b_raddr_b <= j13(i);
      @(negedge clk);
      if (b_rd_data_b !== (i*3 + 1)) begin
        $display("  [err] bram B read addr=%0d got=%0d want=%0d",
                 i, b_rd_data_b, i*3 + 1); err = err + 1;
      end
    end
    b_re_b <= 1'b0;
    $display("  [ok] bram B sampled sweep (stride 97)");
    // 3c) 覆写: addr 5 两次（A 口验证）
    @(negedge clk); b_we <= 1'b1; b_waddr <= 13'd5; b_wdata <= 32'hDEAD_BEEF;
    @(negedge clk); b_waddr <= 13'd5; b_wdata <= 32'hCAFE_BABE;
    @(negedge clk); b_we <= 1'b0;
    @(negedge clk); b_re_a <= 1'b1; b_raddr_a <= 13'd5;
    @(negedge clk); b_re_a <= 1'b0;
    @(negedge clk);
    if (b_rd_data_a !== 32'hCAFE_BABE) begin
      $display("  [err] bram overwrite got=%h want=CAFEBABE", b_rd_data_a); err = err + 1;
    end
    // 3d) 三口并发: 同拍 写100 + A读200 + B读300（互不干扰）
    @(negedge clk);
    b_we <= 1'b1;   b_waddr <= 13'd100; b_wdata <= 32'h1234_5678;
    b_re_a <= 1'b1; b_raddr_a <= 13'd200;
    b_re_b <= 1'b1; b_raddr_b <= 13'd300;
    @(negedge clk); b_we <= 1'b0; b_re_a <= 1'b0; b_re_b <= 1'b0;
    if (b_rd_data_a !== 32'd601) begin
      $display("  [err] bram A same-cycle rd(200) got=%0d want=601", b_rd_data_a);
      err = err + 1;
    end
    if (b_rd_data_b !== 32'd901) begin
      $display("  [err] bram B same-cycle rd(300) got=%0d want=901", b_rd_data_b);
      err = err + 1;
    end
    @(negedge clk); b_re_a <= 1'b1; b_raddr_a <= 13'd100;
    @(negedge clk); b_re_a <= 1'b0;
    @(negedge clk);
    if (b_rd_data_a !== 32'h1234_5678) begin
      $display("  [err] bram wr(100) not effective got=%h", b_rd_data_a); err = err + 1;
    end

    // ---- 结果 ----
    if (err == 0)
      $display("T00 COMMON PASS (crc32 x9 vectors, sync_fifo full+random 4000, bram 1W2R sweep 8192)");
    else
      $display("T00 COMMON FAIL: %0d errors", err);
    $finish;
  end

  // VCD: 全层级（踩坑#11 对照: t00 用 dumpvars(0, tb)，t01 用 (1, dut)）
  initial begin
    $dumpfile("out/t00_common.vcd");
    $dumpvars(0, tb_t00_common);
  end
endmodule
