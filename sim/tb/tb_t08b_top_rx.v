// T08b: 双网 RX 顶层入口/单 PMEM 1W 仲裁冒烟；不是完整 T08/T22。
// IF_MODE=0/1：双网同拍起帧不能同块，79B 尾字 BE 不覆盖低字节，
// 描述符只在对应末字真的落 PMEM 后弹出；RX 优先时主机 ACK 等待实际写完成。
`timescale 1 ns / 1 ps
module tb_t08b_core #(parameter IF_MODE=0);

  // continue2: PMEM is now 4 byte-lane BRAMs (bram_sdp BYTE_EN split); reassemble word
  function [31:0] pmem_word(input [12:0] a);
    pmem_word = {dut.u_pmem.g_lanes.g_lane[3].u_lane.mem[a], dut.u_pmem.g_lanes.g_lane[2].u_lane.mem[a],
                 dut.u_pmem.g_lanes.g_lane[1].u_lane.mem[a], dut.u_pmem.g_lanes.g_lane[0].u_lane.mem[a]};
  endfunction
  reg clk=0, reset=1;
  always #4 clk=~clk;
  reg [7:0] rx_data=0, rx_data_b=0;
  reg rx_valid=0, rx_valid_b=0, rx_ready=0, rx_ready_b=0;
  reg host_cs=0,host_we=0;
  reg [15:0] host_addr=0;
  reg [31:0] host_wdata=0;
  wire [31:0] host_rdata;
  wire host_ack, host_irq;
  AFDX_top #(.IF_MODE(IF_MODE),.FCS_MODE(2)) dut (
    .clk(clk),.reset(reset),.tx_data(),.tx_valid(),.tx_ready(),
    .rx_data(rx_data),.rx_valid(rx_valid),.rx_ready(rx_ready),
    .tx_data_b(),.tx_valid_b(),.tx_ready_b(),
    .rx_data_b(rx_data_b),.rx_valid_b(rx_valid_b),.rx_ready_b(rx_ready_b),
    .host_cs(host_cs),.host_we(host_we),.host_addr(host_addr),.host_wdata(host_wdata),
    .host_rdata(host_rdata),.host_ack(host_ack),.host_irq(host_irq),
    .pps_in(1'b0),.pps_out(),.rtc_time_us(),.dbg_frame_event());
  reg [31:0] vec[0:1144];
  integer err=0,good_a=0,good_b=0, bad=0, host_stall=0, cycles=0;
  integer i,k,bbase,readback,waitc;
  integer drain_cycles=0;
  reg [31:0] actual;
  reg [7:0] expected,obtained;
  reg [162:0] snap_a,snap_b;
  reg [3:0] last_blk_a,last_blk_b;
  function [7:0] vecbyte;
    input integer base;
    input integer idx;
    reg [31:0] word;
    begin
      word=vec[base+2+(idx>>2)];
      case(idx&3)
        0: vecbyte=word[31:24]; 1: vecbyte=word[23:16];
        2: vecbyte=word[15:8]; default: vecbyte=word[7:0];
      endcase
    end
  endfunction
  always @(posedge clk) begin
    cycles=cycles+1;
    if (!reset) begin
      if (dut.rx_ovf_a || dut.rx_ovf_b) begin
        $display("  [err] RX write/desc FIFO overflow");err=err+1;
      end
      if (dut.rx_desc_pop_a) begin
        good_a=good_a+1; snap_a=dut.rx_desc_a;
        last_blk_a=dut.rx_desc_a[162:159];
        if (last_blk_a!=4'd6 || dut.rx_desc_a[158:148]!=11'd79 ||
            dut.rx_desc_a[99]!=1'b0) begin
          $display("  [err] A desc blk=%0d len=%0d",last_blk_a,dut.rx_desc_a[158:148]);err=err+1;
        end
        // desc_pop 前内存必须已经完成 tail BE：在该沿前同步窥视供 RAM 可见性的断言。
        if (pmem_word({last_blk_a,9'd19}) !== {vecbyte(37,76),vecbyte(37,77),vecbyte(37,78),8'hA5}) begin
          $display("  [err] A desc before PMEM tail write got=%h",pmem_word({last_blk_a,9'd19}));err=err+1;
        end
      end
      if (dut.rx_desc_pop_b) begin
        good_b=good_b+1; snap_b=dut.rx_desc_b;
        last_blk_b=dut.rx_desc_b[162:159];
        if (last_blk_b!=4'd7 || dut.rx_desc_b[158:148]!=11'd79 ||
            dut.rx_desc_b[99]!=1'b1) begin
          $display("  [err] B desc blk=%0d len=%0d",last_blk_b,dut.rx_desc_b[158:148]);err=err+1;
        end
        if (pmem_word({last_blk_b,9'd19}) !== {vecbyte(37,76),vecbyte(37,77),vecbyte(37,78),8'hA5}) begin
          $display("  [err] B desc before PMEM tail write got=%h",pmem_word({last_blk_b,9'd19}));err=err+1;
        end
      end
      if (dut.rx_frame_err_a) bad=bad+1;
    end
  end
  task host_write(input [15:0] addr,input [31:0] data);
    begin
      @(negedge clk);host_cs<=1;host_we<=1;host_addr<=addr;host_wdata<=data;
      @(negedge clk);
      if(host_ack!==1) begin $display("  [err] host ack missing @%h",addr);err=err+1;end
      host_cs<=0;host_we<=0;
    end
  endtask
  task host_read(input [15:0] addr,output [31:0] data);
    begin
      @(negedge clk);host_cs<=1;host_we<=0;host_addr<=addr;
      @(negedge clk);
      if(host_ack!==1) begin $display("  [err] read ack missing @%h",addr);err=err+1;end
      data=host_rdata;host_cs<=0;
    end
  endtask
  task pair_frame(input integer base,input integer nbytes,input integer both);
    integer b;
    begin
      for(b=0;b<nbytes;b=b+1) begin
        @(negedge clk);
        rx_ready<=1;rx_valid<=1;rx_data<=vecbyte(base,b);
        if(both!=0) begin rx_ready_b<=1;rx_valid_b<=1;rx_data_b<=vecbyte(base,b);end
        if(IF_MODE==0) begin
          @(negedge clk);rx_valid<=0;rx_valid_b<=0;
          repeat(8) @(negedge clk);
        end
      end
      @(negedge clk);rx_valid<=0;rx_ready<=0;rx_valid_b<=0;rx_ready_b<=0;
    end
  endtask
  task conflicted_host_write;
    integer t;
    reg saw_ack;
    begin
      wait(dut.rx_pmem_busy);
      @(negedge clk);host_cs<=1;host_we<=1;host_addr<=16'h8800;host_wdata<=32'hDEAD_BEEF;
      @(negedge clk);
      if(host_ack!==0) begin $display("  [err] host ACK before RX priority write");err=err+1;end
      else host_stall=host_stall+1;
      host_cs<=0;host_we<=0;
      saw_ack=0;
      for(t=0;t<16 && !saw_ack;t=t+1) begin
        @(negedge clk);
        if(host_ack) saw_ack=1;
      end
      if(!saw_ack) begin $display("  [err] host deferred ACK timed out");err=err+1;end
    end
  endtask
  initial begin
    $readmemh("vec/t08a_frames.hex",vec);
    repeat(7) @(negedge clk);reset<=0;
    waitc=0;
    while(dut.init_done!==1 && waitc<26000) begin @(negedge clk);waitc=waitc+1;end
    if(waitc>=26000) begin $display("  [err] INIT timeout");err=err+1;end
    host_read(16'h000C,actual);
    if(actual[7:2]!==6'd15) begin $display("  [err] initial pool free=%0d",actual[7:2]);err=err+1;end
    host_write(16'h0008,32'h2000); // 配置期 RX 还未开流，预填低 lane 哨兵
    host_write(16'h8813+16'd3072,32'hA5A5_A5A5); // block6 offset19
    host_write(16'h8813+16'd3584,32'hA5A5_A5A5); // block7 offset19
    // 顶层 RX_EN 必须在种子+至少一有效项+显式 commit 后才可打开。
    // VLID=0x0100 在默认 seed0 下候选桶 665，idx=0x100。
    host_write(16'h0078,32'h0000_172D);
    host_write(16'h007C,32'h0000_AB61);
    host_write(16'h42B2,32'h1010_0100);
    host_write(16'h0080,32'h1);
    host_read(16'h0080,actual);
    if(actual[3:0]!==4'hF) begin $display("  [err] hash image not armed: %h",actual);err=err+1;end
    host_write(16'h0008,32'h051E); // RX_EN, IC/RM EN, 非 CFG
    fork
      pair_frame(37,79,1);
      conflicted_host_write();
    join
    // Continue12: both inputs serialize through a five-edge lookup instead
    // of the former two-edge lookup. Wait for *both exact FLT rejects* and
    // full block return, bounded to 24 cycles (192 ns at 125 MHz). Keeping a
    // fixed 12-cycle sleep sampled the second block while still owned by RX.
    // A leak, lost descriptor, duplicate reject or stalled pipeline still fails.
    while ((good_a!=1 || good_b!=1 || dut.flt_unconf_cnt!==32'd2 ||
            dut.rx_free_map!==16'hFFC0) && drain_cycles<24) begin
      @(negedge clk);drain_cycles=drain_cycles+1;
    end
    if(good_a!=1 || good_b!=1 || bad!=0 || host_stall!=1 ||
       pmem_word(0)!==32'hDEAD_BEEF || dut.rx_free_map!==16'hFFC0 ||
       dut.flt_unconf_cnt!==32'd2) begin
      $display("  [err] good A/B=%0d/%0d bad=%0d hoststall=%0d hostword=%h free=%h",
         good_a,good_b,bad,host_stall,pmem_word(0),dut.rx_free_map);err=err+1;
    end
    for(k=0;k<79;k=k+1) begin
      actual=pmem_word(last_blk_a*512+(k>>2));
      case(k&3)
        0: obtained=actual[31:24]; 1: obtained=actual[23:16];
        2: obtained=actual[15:8]; default: obtained=actual[7:0];
      endcase
      expected=vecbyte(37,k);
      if(obtained!==expected) begin
        if(err<8) $display("  [err] A PMEM byte %0d got %h want %h",k,obtained,expected);
        err=err+1;
      end
      actual=pmem_word(last_blk_b*512+(k>>2));
      case(k&3)
        0: obtained=actual[31:24]; 1: obtained=actual[23:16];
        2: obtained=actual[15:8]; default: obtained=actual[7:0];
      endcase
      if(obtained!==expected) begin
        if(err<8) $display("  [err] B PMEM byte %0d got %h want %h",k,obtained,expected);
        err=err+1;
      end
    end
    pair_frame(81,79,0); // 含 SN 的 CRC 损坏帧；不能给后级描述符
    repeat(12) @(negedge clk);
    if(good_a!=1 || good_b!=1 || bad!=1 || dut.rx_free_map!==16'hFFC0) begin
      $display("  [err] bad FCS isolation / pool good=%0d/%0d bad=%0d free=%h",
          good_a,good_b,bad,dut.rx_free_map);err=err+1;
    end
    host_write(16'h0008,32'h2000); // RX 停止，配置期读 PMEM
    host_read(16'h8800,actual);
    if(actual!==32'hDEAD_BEEF) begin $display("  [err] host write readback=%h",actual);err=err+1;end
    if(err==0) $display("T08b RX-TOP-INGRESS PASS (IF_MODE=%0d, dual net, BE, ACK priority, bad FCS, drain=%0d/24 cycles, unconf=%0d)",IF_MODE,drain_cycles,dut.flt_unconf_cnt);
    else $display("T08b RX-TOP-INGRESS FAIL: %0d errors (IF_MODE=%0d)",err,IF_MODE);
    $finish;
  end
  initial begin #4_000_000; $display("T08b RX-TOP-INGRESS FAIL: timeout %0d",IF_MODE);$finish;end
endmodule
module tb_t08b_top_rx; tb_t08b_core #(.IF_MODE(0)) core(); endmodule
module tb_t08bg_top_rx; tb_t08b_core #(.IF_MODE(1)) core(); endmodule
