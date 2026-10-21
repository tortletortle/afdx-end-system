// T88a — chipsim 缩配顶层 GMII 回环冒烟（新增系统场，非原矩阵）
// 目标：AFDX_top_chipsim 上发 1 帧、线回环、RX 描述符 MSG_CNT>=1。
// 用于 P1.1 修复前后对照：漏接 rx_error* 时预期 FAIL，接好后 PASS。
`timescale 1 ns / 1 ps
module tb_chipsim_smoke;
  reg clk = 0, reset = 1;
  always #4 clk = ~clk;

  reg host_cs = 0, host_we = 0;
  reg [15:0] host_addr = 0;
  reg [31:0] host_wdata = 0;
  wire [31:0] host_rdata;
  wire host_ack, host_irq;
  wire [7:0] tx_data, tx_data_b;
  wire tx_valid, tx_valid_b, tx_ready, tx_ready_b;
  // IF_MODE=2（chipsim 内 AFDX_top 默认）：TX 已含前导码，线回环即可。
  wire [7:0] rx_data = tx_data;
  wire       rx_valid = tx_valid;
  wire [7:0] rx_data_b = tx_data_b;
  wire       rx_valid_b = tx_valid_b;

  // P1.1 后 chipsim 暴露 rx_error*；修复前对照见 sim/out/p1_chipsim_before_*（无端口例化）。
  AFDX_top_chipsim dut (
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
  localparam [11:0]  VL_RX = 12'd1;
  localparam [15:0]  VLID_TX = 16'h0100;
  localparam [15:0]  PT_RX = 16'h7D80 + 4 * P_RX;
  // HASH_BUCKETS=64：bucket(0x0100,0x172D,0)=25 → 0x3D80+50
  localparam [15:0]  HASH0 = 16'h3DB2;

  integer errors = 0, checks = 0, waitc, i, base_addr;
  reg [31:0] rd;
  integer tx_bytes = 0;

  task bad;
    input [8*96-1:0] why;
    begin
      errors = errors + 1;
      if (errors < 20) $display("  [err] T88a t=%0t: %0s", $time, why);
    end
  endtask
  task ok;
    input [8*64-1:0] why;
    begin checks = checks + 1; $display("  [ok] %0s", why); end
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

  always @(posedge clk) if (!reset && tx_valid) tx_bytes = tx_bytes + 1;

  initial begin
    repeat (8) @(negedge clk);
    reset = 0;
    waitc = 0;
    host_read(16'h000C, rd);
    while (rd[13] !== 1'b1 && waitc < 40000) begin
      host_read(16'h000C, rd);
      waitc = waitc + 1;
    end
    if (rd[13] !== 1'b1) bad("INIT_DONE timeout");
    else ok("INIT_DONE");

    host_read(16'h0000, rd);
    if (rd !== 32'hAF07_0040) bad("REG_ID expect AF070040 (NUM_RX_VL=64)");
    else ok("REG_ID");

    host_write(16'h0008, 32'h2000); // CFG_MODE
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
    host_write(16'h0200, 32'h8004_F001); // valid, Lmax=79, net A only (DUAL_NET_EN=0)

    host_write(16'h0078, 32'h172D);
    host_write(16'h007C, 32'hAB61);
    host_write(HASH0, 32'h1010_0001); // valid + VLID 0x0100 + idx 1
    host_write(16'h0080, 32'h1);
    host_write(16'h1D82, 32'hF500_0000 | (P_RX << 12) | 32'd79);
    host_write(16'h1D83, {16'd0, VLID_TX});
    host_write(PT_RX, 32'h8004_0000);
    host_write(PT_RX + 1, 32'h0000_1388);
    host_write(PT_RX + 2, 32'd0);
    host_write(PT_RX + 3, 32'd1);
    host_write(16'h0008, 32'h051F); // run: TX/RX/IC/RM

    host_read(16'h0074, rd);
    if (rd[4] !== 1'b1) bad("no open TX block");
    base_addr = 16'h8800 + (rd[3:0] << 9);
    @(negedge clk); host_cs = 1; host_we = 1;
    for (i = 0; i < 8; i = i + 1) begin
      host_addr = base_addr + i;
      host_wdata = 32'hA0B0_C0D0 + i;
      @(negedge clk);
      if (host_ack !== 1'b1) bad("PMEM burst ack");
    end
    host_cs = 0; host_we = 0;
    tx_bytes = 0;
    host_write(16'h8280, 32'd32);

    waitc = 0;
    while (tx_bytes < 64 && waitc < 250000) begin
      @(negedge clk);
      waitc = waitc + 1;
    end
    if (tx_bytes < 64) bad("TX did not emit a GMII frame");
    else ok("TX bytes seen");

    // 等 RX 交付（线回环）
    waitc = 0;
    host_read(16'h8480 + P_RX, rd);
    while (rd < 32'd1 && waitc < 200000) begin
      host_read(16'h8480 + P_RX, rd);
      waitc = waitc + 1;
    end
    if (rd < 32'd1) bad("RX MSG_CNT < 1 after loopback");
    else ok("RX MSG_CNT >= 1");

    if (errors == 0)
      $display("T88a CHIPSIM SMOKE PASS (checks=%0d MSG_CNT=%0d tx_bytes=%0d)",
               checks, rd, tx_bytes);
    else
      $display("T88a CHIPSIM SMOKE FAIL (errors=%0d checks=%0d MSG_CNT=%0d tx_bytes=%0d)",
               errors, checks, rd, tx_bytes);
    $finish;
  end

  initial begin
    #8_000_000;
    $display("T88a CHIPSIM SMOKE FAIL: timeout");
    $finish;
  end
endmodule
