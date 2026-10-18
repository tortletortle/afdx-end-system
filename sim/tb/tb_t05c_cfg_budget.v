// T05c — Q20 份额表前门配置与硬件超配拒绝（不测 T05b 满载抖动）。
// 32 VL @ (303+20)B/8000us -> 108384；@828us -> 1047168；
// 128 VL @ (1518+20)B/8000us -> 2064384，硬件必须拒绝 TX_EN。
`timescale 1 ns / 1 ps
module tb_t05c_cfg_budget;
  reg clk=0, reset=1;
  always #4 clk=~clk;
  reg cs=0, we=0;
  reg [15:0] addr=0;
  reg [31:0] wdata=0;
  wire [31:0] rdata;
  wire ack;
  AFDX_top #(.IF_MODE(0)) dut (
    .rx_error(1'b0), .rx_error_b(1'b0),
    .clk(clk), .reset(reset),
    .tx_data(), .rx_data(8'd0), .tx_valid(), .rx_valid(1'b0),
    .tx_ready(), .rx_ready(1'b1),
    .tx_data_b(), .tx_valid_b(), .tx_ready_b(),
    .rx_data_b(8'd0), .rx_valid_b(1'b0), .rx_ready_b(1'b1),
    .host_cs(cs), .host_we(we), .host_addr(addr), .host_wdata(wdata),
    .host_rdata(rdata), .host_ack(ack), .host_irq(),
    .pps_in(1'b0), .pps_out(), .rtc_time_us(), .dbg_frame_event());
  integer err=0, i;
  reg [31:0] got;
  task wr(input [15:0] a, input [31:0] d);
    begin
      @(negedge clk); cs<=1; we<=1; addr<=a; wdata<=d;
      @(negedge clk);
      if (ack !== 1'b1) begin $display("  [err] no write ack @%h",a);err=err+1;end
      cs<=0; we<=0;
    end
  endtask
  task rd(input [15:0] a, output [31:0] d);
    begin
      @(negedge clk); cs<=1; we<=0; addr<=a;
      @(negedge clk);
      if (ack !== 1'b1) begin $display("  [err] no read ack @%h",a);err=err+1;end
      d=rdata; cs<=0;
    end
  endtask
  task check(input [15:0] a, input [31:0] expected, input [31:0] mask);
    begin
      rd(a,got);
      if ((got & mask) !== (expected & mask)) begin
        $display("  [err] read @%h got %h want %h mask %h",a,got,expected,mask);
        err=err+1;
      end
    end
  endtask
  function [31:0] w0_valid(input integer lmax, input integer bag_exp);
    begin w0_valid=32'h8000_0001 | ((lmax & 4095)<<12) | ((bag_exp & 255)<<4);end
  endfunction
  initial begin
    repeat(6) @(negedge clk); reset<=0;
    repeat(25500) @(negedge clk);
    check(16'h000C,32'h0000_2000,32'h0000_2000); // INIT_DONE
    check(16'h0058,0,32'hFFFF_FFFF); // 复位无份额
    check(16'h005C,0,32'h3);
    check(16'h0480,0,32'hFFFF_FFFF);
    wr(16'h0480,32'd3387);             // 不在 CFG_MODE 不得装表
    check(16'h0010,32'd1,32'd1);
    check(16'h0480,0,32'hFFFF_FFFF);
    wr(16'h0010,32'd1);

    wr(16'h0008,32'h2000); // CFG_MODE=1
    // 先使能后写份额：硬件不得将“缺份额”等同 0 带宽。
    wr(16'h0201,32'd8000 << 8);
    wr(16'h0200,w0_valid(303,3));
    check(16'h005C,32'd2,32'd3); // MISSING_SHARE
    check(16'h0058,0,32'hFFFF_FFFF);
    wr(16'h0480,32'd3387);
    check(16'h005C,0,32'd3);
    // 其余 31 项，脚本份额优先写、w0.valid 最后写。
    for(i=1;i<32;i=i+1) begin
      wr(16'h0200 + 5*i + 1,32'd8000<<8);
      wr(16'h0480 + i,32'd3387);
      wr(16'h0200 + 5*i,w0_valid(303,3));
    end
    check(16'h0058,32'd108384,32'hFFFF_FFFF); // T05a
    check(16'h005C,0,32'd3);
    check(16'h000C,0,32'h0000_4000); // STATUS.CFG_OVER=0
    wr(16'h0008,32'h1); // 非超限，允许 TX_EN
    check(16'h0008,32'h1,32'h1);

    wr(16'h0008,32'h2000);
    for(i=0;i<32;i=i+1) begin
      wr(16'h0200 + 5*i + 1,32'd828<<8);
      wr(16'h0480 + i,32'd32724);
    end
    check(16'h0058,32'd1047168,32'hFFFF_FFFF); // T05b 的配置判决，非抖动测值
    check(16'h005C,0,32'd3);
    wr(16'h0008,32'h1);
    check(16'h0008,32'h1,32'h1);

    wr(16'h0008,32'h2000);
    for(i=0;i<32;i=i+1) wr(16'h0200 + 5*i,32'h0);
    check(16'h0058,0,32'hFFFF_FFFF);
    // T05c: 128 项；一次一个 VL 激活，sum 超过 2^20 后配置模式仍可修改。
    for(i=0;i<128;i=i+1) begin
      wr(16'h0200 + 5*i + 1,32'd8000<<8);
      wr(16'h0480 + i,32'd16128);
      wr(16'h0200 + 5*i,w0_valid(1518,3));
    end
    check(16'h04FF,32'd16128,32'hFFFF_FFFF); // 边界项读回
    check(16'h0058,32'd2064384,32'hFFFF_FFFF);
    check(16'h005C,32'd1,32'd3);  // CFG_ERR.OVER
    check(16'h000C,32'h0000_4000,32'h0000_4000); // STATUS.CFG_OVER
    check(16'h0010,32'h2,32'h2);   // ERR.BAG_OVF
    wr(16'h0008,32'h1);            // 超额不得开流
    check(16'h0008,0,32'h1);
    check(16'h0010,32'h3,32'h3);  // 拒绝的 ACC + BAG_OVF
    wr(16'h0010,32'h3);            // 超额仍在，W1C 不得永久掩盖
    check(16'h0010,32'h2,32'h2);
    wr(16'h0008,32'h2000); // 重新配置消除超额
    for(i=64;i<128;i=i+1) wr(16'h0200 + 5*i,32'h0);
    check(16'h0058,32'd1032192,32'hFFFF_FFFF); // 64×16128，低于上限
    check(16'h005C,0,32'd3);
    check(16'h000C,0,32'h0000_4000);
    wr(16'h0010,32'h3);
    check(16'h0010,0,32'd3);
    // 边界必须严格大于阈值才拒绝：=2^20 可开流，+1 不可开流。
    wr(16'h0480,32'd32512); // 63×16128 + 32512 = 1048576
    check(16'h0058,32'd1048576,32'hFFFF_FFFF);
    check(16'h005C,0,32'd3);
    check(16'h000C,0,32'h0000_4000);
    wr(16'h0480,32'd32513);
    check(16'h0058,32'd1048577,32'hFFFF_FFFF);
    check(16'h005C,32'd1,32'd3);
    wr(16'h0008,32'h1);
    check(16'h0008,0,32'd1);
    wr(16'h0008,32'h2000);
    wr(16'h0480,32'd16128);
    check(16'h0058,32'd1032192,32'hFFFF_FFFF);
    wr(16'h0010,32'd3); // 修复后清掉粘滞错误
    // 份额窗 8 笔连续请求拍：每拍 ack，旧值覆写后 sum 不得重复累加。
    @(negedge clk); cs<=1; we<=1;
    for (i=0;i<8;i=i+1) begin
      addr<=16'h0480+i; wdata<=32'd16128;
      @(negedge clk);
      if (ack !== 1'b1) begin $display("  [err] Q20 burst ack vl=%0d",i);err=err+1;end
    end
    cs<=0; we<=0;
    check(16'h0058,32'd1032192,32'hFFFF_FFFF);
    wr(16'h0008,32'h1);
    check(16'h0008,32'h1,32'h1);

    wr(16'h0008,32'h2000);
    wr(16'h0480,0); // 已使能 VL0 零份额 = 缺份额
    check(16'h0058,32'd1016064,32'hFFFF_FFFF);
    check(16'h005C,32'd2,32'd3);
    wr(16'h0008,32'h1); // 缺份额不得开流，ACC 置位
    check(16'h0008,0,32'h1);
    check(16'h0010,32'd1,32'd1);
    wr(16'h0008,32'h2000);
    wr(16'h0480,32'd16128);
    wr(16'h0481,32'h0020_0000); // 保留位非零：不应篡改旧份额
    check(16'h0010,32'd1,32'd1);
    check(16'h0481,32'd16128,32'hFFFF_FFFF);
    check(16'h0058,32'd1032192,32'hFFFF_FFFF);
    wr(16'h0481,32'd16129); // 单项覆写 O(1) 更新 +1
    check(16'h0058,32'd1032193,32'hFFFF_FFFF);
    wr(16'h0481,32'd16128);
    check(16'h0058,32'd1032192,32'hFFFF_FFFF);
    check(16'h005C,0,32'd3);
    wr(16'h0008,32'h1);
    check(16'h0008,32'h1,32'h1);

    // 重复复位：原份额 RAM 可以保留数据，但 loaded 随 TXCFG 扫描清除，读回与 sum 必须为 0。
    @(negedge clk); reset<=1;
    repeat(6) @(negedge clk); reset<=0;
    repeat(25500) @(negedge clk);
    check(16'h000C,32'h2000,32'h2000);
    check(16'h0058,0,32'hFFFF_FFFF);
    check(16'h005C,0,32'd3);
    check(16'h0480,0,32'hFFFF_FFFF);
    check(16'h0010,0,32'd3);
    if (err==0) $display("T05c CFGBUDGET PASS (Q20 32/128 VL; exact-boundary/burst/missing/over/reset; frontdoor)");
    else        $display("T05c CFGBUDGET FAIL: %0d errors",err);
    $finish;
  end
  initial begin
    #1_000_000;
    $display("T05c CFGBUDGET FAIL: timeout, %0d errors",err);
    $finish;
  end
endmodule
