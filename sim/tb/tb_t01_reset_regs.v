// =====================================================================
// tb_t01_reset_regs.v —— T01 复位与寄存器/表项读写（骨架版，§12.2）
// 检查: 复位值、R/W 属性、RO 写/未列出地址 → ERR.ACC、W1C、
//       CTL 保留位写无效、IRQ_SW（CTL bit14，自测 T01 用）、
//       TB_CNT_US 计数、ALIVE 每 2^24 拍翻转
// 附: crc32 单元自检 "123456789" → 0xCBF43926（T00 项）
// 波形: out/t01_smoke.vcd（前 300 μs，ALIVE 相用寄存器读证明，避免巨型文件）
// =====================================================================
`timescale 1 ns / 1 ps
module tb_t01_reset_regs;
  reg clk = 1'b0;
  reg reset = 1'b1;
  always #4 clk = ~clk;              // 125 MHz = 8 ns

  reg         host_cs  = 1'b0;
  reg         host_we  = 1'b0;
  reg  [15:0] host_addr = 16'h0;
  reg  [31:0] host_wdata = 32'h0;
  wire [31:0] host_rdata;
  wire        host_ack;
  wire        host_irq;

  AFDX_top #(.CLK_FREQ_HZ(125_000_000), .TICK_US(1)) dut (
    .clk(clk),        .reset(reset),
    .tx_data(),       .rx_data(8'h00),
    .tx_valid(),      .rx_valid(1'b0),
    .tx_ready(),      .rx_ready(1'b0),
    .tx_data_b(),     .tx_valid_b(),     .tx_ready_b(),
    .rx_data_b(8'h00),.rx_valid_b(1'b0),.rx_ready_b(1'b0),
    .host_cs(host_cs),  .host_we(host_we),
    .host_addr(host_addr), .host_wdata(host_wdata),
    .host_rdata(host_rdata), .host_ack(host_ack), .host_irq(host_irq),
    .pps_in(1'b0),     .pps_out(),
    .rtc_time_us(),    .dbg_frame_event()
  );

  integer err = 0;
  reg [31:0] rd;

  // §5.4 两拍协议: negedge 驱动第 1 拍，下一个 negedge 读第 2 拍
  task host_read(input [15:0] a, output [31:0] d);
    begin
      @(negedge clk);
      host_cs <= 1'b1; host_we <= 1'b0; host_addr <= a;
      @(negedge clk);
      d = host_rdata;
      if (host_ack !== 1'b1) begin
        $display("  [err] host_ack not high at beat2 (addr=%h)", a); err = err + 1;
      end
      host_cs <= 1'b0;
    end
  endtask

  task host_write(input [15:0] a, input [31:0] d);
    begin
      @(negedge clk);
      host_cs <= 1'b1; host_we <= 1'b1; host_addr <= a; host_wdata <= d;
      @(negedge clk);
      if (host_ack !== 1'b1) begin
        $display("  [err] host_ack not high at beat2 write (addr=%h)", a); err = err + 1;
      end
      host_cs <= 1'b0; host_we <= 1'b0;
    end
  endtask

  // ---- crc32 独立例化（T00 常数自检）----
  wire [31:0] crc_final;
  reg  [7:0]  crc_d  = 8'h00;
  reg         crc_dv = 1'b0;
  crc32 u_crc (.clk(clk), .rst(reset), .init(1'b0),
               .data_valid(crc_dv), .data(crc_d), .crc_out(), .crc_final(crc_final));

  integer i;
  initial begin
    #80;                              // 复位稳定（含 rst_sync 3 拍）
    reset <= 1'b0;
    repeat (8) @(negedge clk);

    // 1) crc32 self-check: "123456789" -> 0xCBF43926 (after reset release)
    for (i = 0; i < 9; i = i + 1) begin
      @(negedge clk);
      crc_d  <= 8'h31 + i[7:0];
      crc_dv <= 1'b1;
    end
    @(negedge clk);
    crc_dv <= 1'b0;
    @(negedge clk);
    if (crc_final !== 32'hCBF4_3926) begin
      $display("  [err] crc32 self-check: got=%h want=CBF43926", crc_final); err = err + 1;
    end else
      $display("  [ok] crc32 self-check 0xCBF43926");

    // 2) 复位值
    host_read(16'h0008, rd);
    if (rd !== 32'h51C) begin
      $display("  [err] CTL reset value %h (expect 0000051C)", rd); err = err + 1;
    end
    host_read(16'h000C, rd);
    if (rd !== 32'h40) begin
      $display("  [err] STATUS reset value %h (expect 00000040: PMEM_FREE=16 in [7:2], ALIVE=0)", rd); err = err + 1;
    end
    host_read(16'h0010, rd);
    if (rd !== 32'h0) begin
      $display("  [err] ERR reset value %h", rd); err = err + 1;
    end

    // 3) ID / REV
    host_read(16'h0000, rd);
    if (rd !== 32'hAF07_1000) begin
      $display("  [err] ID %h (expect AF071000: NUM_RX_VL=4096)", rd); err = err + 1;
    end
    host_read(16'h0004, rd);
    if (rd !== 32'h4_0000) begin
      $display("  [err] REV %h", rd); err = err + 1;
    end

    // 4) RO 写 → ERR.ACC
    host_write(16'h0000, 32'hDEAD_BEEF);
    host_read(16'h0010, rd);
    if (rd !== 32'h1) begin
      $display("  [err] ERR after RO write %h (expect ACC=1)", rd); err = err + 1;
    end

    // 5) W1C 清
    host_write(16'h0010, 32'h1);
    host_read(16'h0010, rd);
    if (rd !== 32'h0) begin
      $display("  [err] ERR after W1C clear %h", rd); err = err + 1;
    end

    // 6) 未列出地址 → DEAD_BEEF + ACC
    host_read(16'h0100, rd);
    if (rd !== 32'hDEAD_BEEF) begin
      $display("  [err] read 0x0100 = %h (expect DEADBEEF)", rd); err = err + 1;
    end
    host_read(16'h0010, rd);
    if (rd !== 32'h1) begin
      $display("  [err] ACC not set after unmapped read, ERR=%h", rd); err = err + 1;
    end
    host_write(16'h0010, 32'h1);

    // 7) CTL write/readback + reserved bits (bit5/bit12) write-ignored
    host_write(16'h0008, 32'h1021);
    host_read(16'h0008, rd);
    if (rd !== 32'h1) begin
      $display("  [err] CTL reserved-bit writeback %h (expect 00000001: bit5/bit12 write-ignored)", rd); err = err + 1;
    end

    // 8) IRQ_SW（CTL bit14，T01 自测）
    host_write(16'h0008, 32'h4020);
    @(negedge clk);
    if (host_irq !== 1'b1) begin
      $display("  [err] host_irq not high after IRQ_SW"); err = err + 1;
    end
    host_write(16'h0008, 32'h20);
    @(negedge clk);
    if (host_irq !== 1'b0) begin
      $display("  [err] host_irq not low after IRQ_SW clear"); err = err + 1;
    end

    // 9) TB_CNT_US counting: 100 us delay, delta in [95,105]
    host_read(16'h0050, rd);
    #100_000;                          // 100 us
    host_read(16'h0050, rd);
    if (rd < 32'd95 || rd > 32'd105) begin
      $display("  [err] TB_CNT_US delta over 100us = %0d (expect ~100)", rd); err = err + 1;
    end

    // 10) ALIVE: beat_cnt[23] -> high at 2^23 beats, low again at 2^24 (period 2^24)
    host_read(16'h000C, rd);
    if (rd[31] !== 1'b0) begin
      $display("  [err] ALIVE already 1 before 2^23 beats (STATUS=%h)", rd); err = err + 1;
    end
    #((( (1 << 23) + (1 << 22) ) * 8) + 64);   // (2^23 + 2^22) beats x 8 ns + margin
    host_read(16'h000C, rd);
    if (rd[31] !== 1'b1) begin
      $display("  [err] ALIVE not high at 2^23+2^22 beats (STATUS=%h)", rd); err = err + 1;
    end

    if (err == 0)
      $display("T01 SMOKE PASS (skeleton: register page + timebase + CRC32)");
    else
      $display("T01 SMOKE FAIL: %0d errors", err);
    $finish;
  end

  // VCD: 只 dump 前 300 μs（ALIVE 相由寄存器读证明）
  initial begin
    $dumpfile("out/t01_smoke.vcd");
    $dumpvars(1, dut);
    #300_000;
    $dumpoff;
  end
endmodule
