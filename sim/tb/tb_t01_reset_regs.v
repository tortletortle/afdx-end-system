// =====================================================================
// tb_t01_reset_regs.v —— T01 冷启动扫描 + 寄存器/表项读写（§12.2）
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
  integer init_seen [0:7];
  integer cycles = 0, last_init_cycle = -1, init_done_cycle = -1;
  integer wait_cycles, j, total_init;
  always @(posedge clk) begin
    cycles <= cycles + 1;
    if (dut.init_we) begin
      init_seen[dut.init_target] = init_seen[dut.init_target] + 1;
      last_init_cycle = cycles;
    end
    if (dut.init_done && init_done_cycle < 0) init_done_cycle = cycles;
  end

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
    for (j = 0; j < 8; j = j + 1) init_seen[j] = 0;
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
    if (rd !== 32'h3C) begin
      $display("  [err] STATUS cold-open value %h (expect 0000003C: 15 free after reserving TX block)", rd); err = err + 1;
    end
    host_read(16'h0010, rd);
    if (rd !== 32'h0) begin
      $display("  [err] ERR reset value %h", rd); err = err + 1;
    end

    // 未清表前尝试开 TX/RX：CTL 位必须保持 0，并置 ERR.ACC（不可提前开流）。
    host_write(16'h0008, 32'h3);
    host_read(16'h0008, rd);
    if (rd[1:0] !== 2'b00) begin
      $display("  [err] early TX/RX enable admitted: CTL=%h", rd); err = err + 1;
    end
    host_read(16'h0010, rd);
    if (rd[0] !== 1'b1) begin
      $display("  [err] early enable did not set ERR.ACC: %h", rd); err = err + 1;
    end
    host_write(16'h0010, 32'h1);
    host_write(16'h0008, 32'h2000);  // CFG_MODE 可以先设，但 INIT_DONE 前不可改表
    host_write(16'h0200, 32'h8004_0001);
    host_read(16'h0010, rd);
    if (rd[0] !== 1'b1) begin
      $display("  [err] table write during init not rejected: ERR=%h", rd); err = err + 1;
    end
    host_write(16'h0010, 32'h1);

    host_read(16'h0060, rd);
    if (rd !== 32'h0001_2001) begin $display("  [err] SMAC reset %h", rd); err = err + 1; end
    host_read(16'h0070, rd);
    if (rd !== 32'h0000_0142) begin $display("  [err] UDP_CFG reset %h", rd); err = err + 1; end

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
    host_read(16'h0500, rd);  // 0x0480~0x04FF 新份额表；0x0500 仍为空洞
    if (rd !== 32'hDEAD_BEEF) begin
      $display("  [err] read 0x0500 = %h (expect DEADBEEF)", rd); err = err + 1;
    end
    host_read(16'h0010, rd);
    if (rd !== 32'h1) begin
      $display("  [err] ACC not set after unmapped read, ERR=%h", rd); err = err + 1;
    end
    host_write(16'h0010, 32'h1);

    // 7) CTL write/readback + reserved bits (bit5/bit12) write-ignored
    host_write(16'h0008, 32'h1021);
    host_read(16'h0008, rd);
    if (rd !== 32'h0) begin
      $display("  [err] CTL reserved/early TX bit writeback %h (expect 0)", rd); err = err + 1;
    end
    host_read(16'h0010, rd);
    if (rd[0] !== 1'b1) begin
      $display("  [err] early TX attempt did not set ACC: %h", rd); err = err + 1;
    end
    host_write(16'h0010, 32'h1);

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

    // 10) T01: 全 8 组扫描真实写拍与 INIT_DONE 最后写可见。
    host_read(16'h000C, rd);
    if (rd[13] !== 1'b0) begin $display("  [err] INIT_DONE too early @100us: %h", rd); err = err + 1; end
    wait_cycles = 0;
    while (dut.init_done !== 1'b1 && wait_cycles < 30000) begin
      @(negedge clk); wait_cycles = wait_cycles + 1;
    end
    if (wait_cycles >= 30000) begin $display("  [err] INIT_DONE timeout"); err = err + 1; end
    host_read(16'h000C, rd);
    if (rd[13] !== 1'b1) begin $display("  [err] INIT_DONE status bit missing: %h", rd); err = err + 1; end
    total_init = 0;
    for (j = 0; j < 8; j = j + 1) total_init = total_init + init_seen[j];
    if (total_init != 25344 || init_seen[0]!=8192 || init_seen[1]!=4096 ||
        init_seen[2]!=8192 || init_seen[3]!=4096 || init_seen[4]!=128 ||
        init_seen[5]!=256 || init_seen[6]!=256 || init_seen[7]!=128 ||
        init_done_cycle <= last_init_cycle) begin
      $display("  [err] init counts total=%0d stages=%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d last=%0d done=%0d",
        total_init,init_seen[0],init_seen[1],init_seen[2],init_seen[3],
        init_seen[4],init_seen[5],init_seen[6],init_seen[7],last_init_cycle,init_done_cycle);
      err = err + 1;
    end
    if (dut.psn_mem[8191] !== 8'd0 || dut.rm_mem[4095] !== 32'd0 ||
        dut.u_rxlookup.table1way1[2047] !== 32'd0 || dut.rx_cfg_mem[8190] !== 32'd0 ||
        dut.tx_cfg_mem[635] !== 32'd0 || dut.port_cfg_mem[1020] !== 32'd0 ||
        dut.rx_desc_mem[255] !== 32'd0 || dut.vl_stat_mem[127] !== 32'd0) begin
      $display("  [err] last address of some scanned RAM not cleared"); err = err + 1;
    end
    // 表只允许 CFG_MODE=1 且 INIT_DONE=1 时写；单拍流水可以连续两笔。
    host_read(16'h0200, rd);
    if (rd !== 32'd0) begin $display("  [err] TX valid not cleared: %h", rd); err = err + 1; end
    host_write(16'h0200, 32'h8004_0001);
    host_read(16'h0010, rd);
    if (rd[0] !== 1'b1) begin $display("  [err] table write without CFG_MODE accepted"); err = err + 1; end
    host_write(16'h0010, 32'h1);
    host_write(16'h0008, 32'h2000);
    host_write(16'h0201, 32'h0003_E800); // 1000 us BAG
    host_write(16'h0204, 32'd0);        // port_base=0; avoid undefined field if TX_EN later
    host_write(16'h0480, 32'd7047);     // (Lmax64+20)*80ns/BAG1000us，逐 VL ceil Q20
    host_write(16'h0200, 32'h8004_0001); // valid must be written last
    host_read(16'h0058, rd);
    if (rd !== 32'd7047) begin $display("  [err] CFG_SUM after VL0 %h",rd); err=err+1; end
    host_read(16'h0200, rd);
    if (rd !== 32'h8004_0001) begin $display("  [err] TX VL w0 readback %h", rd); err = err + 1; end
    host_read(16'h0201, rd);
    if (rd !== 32'h0003_E800) begin $display("  [err] TX VL w1 readback %h", rd); err = err + 1; end
    host_write(16'h1D80, 32'h8000_0000);
    host_read(16'h1D80, rd);
    if (rd !== 32'h8000_0000) begin $display("  [err] RX CFG readback %h", rd); err = err + 1; end
    host_write(16'h7D80, 32'h8000_C000);
    host_read(16'h7D80, rd);
    if (rd !== 32'h8000_C000) begin $display("  [err] PORT CFG readback %h", rd); err = err + 1; end
    host_write(16'h3D80, 32'h1000_0100);
    if (dut.u_rxlookup.table0way0[0] !== 32'h1000_0100) begin $display("  [err] real hash RAM write missing"); err = err + 1; end
    host_read(16'h3D80, rd);
    if (rd !== 32'h1000_0100) begin $display("  [err] hash frontdoor RAM readback: %h", rd); err = err + 1; end
    host_read(16'h0010, rd);
    if (rd[0] !== 1'b0) begin $display("  [err] legal hash read set ERR.ACC"); err = err + 1; end
    host_read(16'h5D80, rd); // 保留高半区仍未映射
    if (rd !== 32'hDEAD_BEEF) begin $display("  [err] reserved hash half decoded: %h", rd); err = err + 1; end
    host_read(16'h0010, rd);
    if (rd[0] !== 1'b1) begin $display("  [err] reserved hash read ERR.ACC missing"); err = err + 1; end
    host_write(16'h0010, 32'h1);
    @(negedge clk);
    host_cs <= 1'b1; host_we <= 1'b1; host_addr <= 16'h0064; host_wdata <= 32'h0A00_0001;
    @(negedge clk);
    if (host_ack !== 1'b1) begin $display("  [err] pipeline write beat 1 ack"); err = err + 1; end
    host_addr <= 16'h0070; host_wdata <= 32'h0000_0142;
    @(negedge clk);
    if (host_ack !== 1'b1) begin $display("  [err] pipeline write beat 2 ack"); err = err + 1; end
    host_cs <= 1'b0; host_we <= 1'b0;
    host_read(16'h0064, rd);
    if (rd !== 32'h0A00_0001) begin $display("  [err] pipeline IP write: %h", rd); err = err + 1; end
    host_read(16'h0070, rd);
    if (rd !== 32'h0000_0142) begin $display("  [err] pipeline UDP write: %h", rd); err = err + 1; end
    host_write(16'h0008, 32'h0000_0001);
    host_read(16'h0008, rd);
    if (rd[1:0] !== 2'b01) begin $display("  [err] TX_EN after init rejected: %h", rd); err = err + 1; end
    host_write(16'h0008, 32'h0); // 长时间 ALIVE 相位测试期间停掉空转调度
    host_read(16'h0074, rd);
    if (rd !== 32'h10) begin $display("  [err] TX_WR_BLK should be open block 0: %h", rd); err = err + 1; end
    $display("  [ok] init_sweep %0d writes, DONE after last write (%0d cycles), config R/W and pipeline pass",
             total_init,init_done_cycle-last_init_cycle);

    // 11) ALIVE: beat_cnt[23] -> high at 2^23 beats, low again at 2^24 (period 2^24)
    host_read(16'h000C, rd);
    if (rd[31] !== 1'b0) begin
      $display("  [err] ALIVE already 1 before 2^23 beats (STATUS=%h)", rd); err = err + 1;
    end
    #((( (1 << 23) + (1 << 22) ) * 8) + 64);   // (2^23 + 2^22) beats x 8 ns + margin
    host_read(16'h000C, rd);
    if (rd[31] !== 1'b1) begin
      $display("  [err] ALIVE not high at 2^23+2^22 beats (STATUS=%h)", rd); err = err + 1;
    end

    // 再次复位：INIT_DONE 必须重新为 0；旧有效项不能跨复位残留。
    @(negedge clk); reset <= 1'b1;
    repeat (6) @(negedge clk);
    reset <= 1'b0;
    repeat (6) @(negedge clk);
    host_read(16'h000C, rd);
    if (rd[13] !== 1'b0) begin $display("  [err] INIT_DONE stayed high after reset"); err = err + 1; end
    wait_cycles = 0;
    while (dut.init_done !== 1'b1 && wait_cycles < 30000) begin
      @(negedge clk); wait_cycles = wait_cycles + 1;
    end
    if (wait_cycles >= 30000 || dut.tx_cfg_mem[0] !== 32'd0 ||
        dut.port_cfg_mem[0] !== 32'd0 || dut.u_rxlookup.table0way0[0] !== 32'd0) begin
      $display("  [err] reset repeat did not reinitialize table valid/hash"); err = err + 1;
    end
    if (err == 0) $display("T01 INIT/REG PASS (25344 writes + re-reset + table R/W + pipeline + timebase)");
    else          $display("T01 INIT/REG FAIL: %0d errors", err);
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
