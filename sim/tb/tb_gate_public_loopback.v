// T88b — 公开端口双网回环（新增系统场，非原矩阵）
// 只用顶层端口；禁止层次引用 / bind。IF_MODE=2 线回环。
// S1：INIT/ID/REV/CTL；S2：1 TX VL + 1 RX VL，A/B 各一帧，载荷逐字节一致，RM 去重 +1。
// 载荷期望来自 sim/vec/t88b_payload32.hex（Python 生成），不复用 RTL 常量作金标。
`timescale 1 ns / 1 ps
module tb_gate_public_loopback;
  localparam integer IF_MODE = 2;
  reg clk = 0, reset = 1;
  always #4 clk = ~clk;

  wire [7:0] tx_data, tx_data_b;
  wire tx_valid, tx_valid_b, tx_ready, tx_ready_b;
  // IF_MODE=2：TX 已含前导码/SFD，线回环直接进 RX。
  wire [7:0] rx_data = tx_data;
  wire       rx_valid = tx_valid;
  wire [7:0] rx_data_b = tx_data_b;
  wire       rx_valid_b = tx_valid_b;

  reg host_cs = 0, host_we = 0;
  reg [15:0] host_addr = 0;
  reg [31:0] host_wdata = 0;
  wire [31:0] host_rdata;
  wire host_ack, host_irq;

  AFDX_top #(.IF_MODE(IF_MODE), .FCS_MODE(2)) dut (
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

  localparam integer P_RX = 5;
  localparam [11:0]  VL_RX = 12'h100;
  localparam [15:0]  VLID_TX = 16'h0100;
  localparam [15:0]  PT_RX = 16'h7D80 + 4 * P_RX;

  reg [7:0] exp_pl [0:31];
  reg [7:0] cap_a [0:2047], cap_b [0:2047];
  integer na = 0, nb = 0, frame_a = 0, frame_b = 0;
  integer errors = 0, checks = 0, s1_ok = 0, s2_ok = 0;
  integer waitc, i, k, base_addr, blk, polls;
  reg [31:0] rd, w;
  reg prev_a = 0, prev_b = 0;
  integer capturing = 0;

  function [10:0] mix_bucket;
    input [15:0] vlid;
    input [15:0] seed;
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
    input [15:0] vlid;
    input [15:0] seed;
    input table_id;
    input way;
    begin
      hash_addr = 16'h3D80 + ({4'd0, table_id} << 12) +
                  (mix_bucket(vlid, seed, table_id) << 1) + way;
    end
  endfunction

  task bad;
    input [8*112-1:0] why;
    begin
      errors = errors + 1;
      if (errors < 25) $display("  [err] T88b t=%0t: %0s", $time, why);
    end
  endtask
  task gate_check;
    input cond;
    input [8*96-1:0] why;
    begin
      checks = checks + 1;
      if (cond !== 1'b1) bad(why);
    end
  endtask

  task host_write;
    input [15:0] addr;
    input [31:0] data;
    integer n;
    begin
      @(negedge clk);
      host_cs = 1; host_we = 1; host_addr = addr; host_wdata = data;
      n = 0;
      while (host_ack !== 1'b1 && n < 64) begin @(negedge clk); n = n + 1; end
      if (host_ack !== 1'b1) bad("host write ACK timeout");
      host_cs = 0; host_we = 0;
    end
  endtask
  task host_read;
    input [15:0] addr;
    output [31:0] data;
    integer n;
    begin
      @(negedge clk);
      host_cs = 1; host_we = 0; host_addr = addr;
      n = 0;
      while (host_ack !== 1'b1 && n < 64) begin @(negedge clk); n = n + 1; end
      if (host_ack !== 1'b1) bad("host read ACK timeout");
      data = host_rdata;
      host_cs = 0;
    end
  endtask

  // 抓完整 GMII 帧（含前导码）；帧界 = tx_valid 下降沿
  always @(posedge clk) if (!reset && capturing) begin
    if (tx_valid) begin
      if (na < 2048) cap_a[na] = tx_data;
      na = na + 1;
    end else if (prev_a && na > 0) begin
      frame_a = frame_a + 1;
    end
    if (tx_valid_b) begin
      if (nb < 2048) cap_b[nb] = tx_data_b;
      nb = nb + 1;
    end else if (prev_b && nb > 0) begin
      frame_b = frame_b + 1;
    end
    prev_a = tx_valid;
    prev_b = tx_valid_b;
  end

  integer fd, code, bi;
  reg [7:0] hb;
  initial begin
    // 载荷金标：sim/vec/t88b_payload32.hex（相对仿真 cwd=sim/ 或仓库根）
    fd = $fopen("vec/t88b_payload32.hex", "r");
    if (fd == 0) fd = $fopen("sim/vec/t88b_payload32.hex", "r");
    if (fd == 0) begin
      $display("GATE_S0 FAIL: cannot open t88b_payload32.hex");
      $finish;
    end
    for (bi = 0; bi < 32; bi = bi + 1) begin
      code = $fscanf(fd, "%h\n", hb);
      if (code != 1) begin
        $display("GATE_S0 FAIL: payload hex short at %0d", bi);
        $finish;
      end
      exp_pl[bi] = hb;
    end
    $fclose(fd);

    repeat (8) @(negedge clk);
    reset = 0;

    // ========== S1：INIT / ID / REV / CTL ==========
    waitc = 0;
    host_read(16'h000C, rd);
    while (rd[13] !== 1'b1 && waitc < 40000) begin
      host_read(16'h000C, rd);
      waitc = waitc + 1;
    end
    gate_check(rd[13] === 1'b1, "S1 INIT_DONE");
    host_read(16'h0000, rd);
    gate_check(rd === 32'hAF07_1000, "S1 REG_ID");
    host_read(16'h0004, rd);
    gate_check(rd === 32'h0004_0000, "S1 REG_REV");
    host_write(16'h0008, 32'h0000_2000);
    host_read(16'h0008, rd);
    gate_check(rd[13] === 1'b1, "S1 CTL CFG_MODE sticky");
    if (errors == 0) begin
      s1_ok = 1;
      $display("GATE_S1 PASS");
    end else $display("GATE_S1 FAIL errors=%0d", errors);

    // ========== S2：配置 + 双网单帧回环 ==========
    host_write(16'h0060, 32'h1234_2001);
    host_write(16'h0064, 32'h0A00_0001);
    host_write(16'h0070, 32'h0000_0142);
    host_write(16'h7D83, 32'h0000_0001);
    host_write(16'h7D80, 32'h8000_C000);
    host_write(16'h0204, 32'h0000_0000);
    host_write(16'h0203, 32'hE000_0001);
    host_write(16'h0202, 32'h1388_C000);
    host_write(16'h0201, 32'h0003_E800);
    host_write(16'h0480, 32'd8305);
    host_write(16'h0200, 32'h8004_F003); // A+B
    host_write(16'h0078, 32'h0000_172D);
    host_write(16'h007C, 32'h0000_AB61);
    host_write(hash_addr(VLID_TX, 16'h172D, 1'b0, 1'b0),
               {3'd0, 1'b1, VLID_TX, VL_RX});
    host_write(16'h0080, 32'h1);
    host_write(16'h1F80, 32'hF500_0000 | (P_RX << 12) | 32'd79);
    host_write(16'h1F81, {16'd0, VLID_TX});
    host_write(PT_RX, 32'h8004_0000);
    host_write(PT_RX + 1, 32'h0000_1388);
    host_write(PT_RX + 2, 32'd0);
    host_write(PT_RX + 3, 32'd1);
    host_write(16'h0014, 32'h1);
    host_write(16'h0008, 32'h051F);

    host_read(16'h0074, rd);
    gate_check(rd[4] === 1'b1, "S2 TX block open");
    base_addr = 16'h8800 + (rd[3:0] << 9);
    // 按金标写 8 个大端字
    @(negedge clk); host_cs = 1; host_we = 1;
    for (i = 0; i < 8; i = i + 1) begin
      host_addr = base_addr + i;
      host_wdata = {exp_pl[4*i], exp_pl[4*i+1], exp_pl[4*i+2], exp_pl[4*i+3]};
      @(negedge clk);
      if (host_ack !== 1'b1) bad("S2 PMEM ack");
    end
    host_cs = 0; host_we = 0;

    na = 0; nb = 0; frame_a = 0; frame_b = 0; prev_a = 0; prev_b = 0;
    capturing = 1;
    host_write(16'h8280, 32'd32);

    waitc = 0;
    while ((frame_a < 1 || frame_b < 1) && waitc < 400000) begin
      @(negedge clk);
      waitc = waitc + 1;
    end
    capturing = 0;
    gate_check(frame_a >= 1, "S2 TX A frame");
    gate_check(frame_b >= 1, "S2 TX B frame");

    // 等 RX 交付（线回环）
    polls = 0;
    host_read(16'h8480 + P_RX, rd);
    while (rd < 32'd1 && polls < 200000) begin
      host_read(16'h8480 + P_RX, rd);
      polls = polls + 1;
    end
    gate_check(rd === 32'd1, "S2 RX MSG_CNT==1");

    host_read(16'h8180 + P_RX, rd);
    gate_check(rd[31] === 1'b1, "S2 DESC valid");
    gate_check(rd[10:0] === 11'd32, "S2 DESC plen=32");
    blk = rd[23:20];
    // 载荷在帧偏移 42..73（无前导码的 MAC 帧布局；PMEM 存剥离后的帧）
    for (i = 10; i < 18; i = i + 1) begin
      host_read(16'h8800 + (blk << 9) + i, w);
      for (k = 0; k < 4; k = k + 1) begin
        if (4 * i + k >= 42 && 4 * i + k < 74) begin
          if (w[31-8*k -: 8] !== exp_pl[4*i+k-42])
            bad("S2 payload byte mismatch vs golden hex");
        end
      end
    end
    host_read(16'h004C, rd);
    gate_check(rd === 32'd1, "S2 RM dup count +1");

    if (errors == 0) begin
      s2_ok = 1;
      $display("GATE_S2 PASS (A/B frames, MSG_CNT=1, payload match, RM dup=1)");
    end else $display("GATE_S2 FAIL errors=%0d", errors);

    if (s1_ok && s2_ok && errors == 0)
      $display("GATE_PUBLIC_LOOPBACK PASS checks=%0d", checks);
    else
      $display("GATE_PUBLIC_LOOPBACK FAIL errors=%0d checks=%0d s1=%0d s2=%0d",
               errors, checks, s1_ok, s2_ok);
    $finish;
  end

  initial begin
    #20_000_000;
    $display("GATE_PUBLIC_LOOPBACK FAIL: timeout");
    $finish;
  end
endmodule
