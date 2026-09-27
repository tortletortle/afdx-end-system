// T22 — 冷启动 TX→RX 回环（v0.5.17）：主机 PMEM 写 → TX VL0 A/B 发帧 →
// 抓取 DUT 自己发出的字节流并回灌到 RX A/B 入口 → 哈希查表 → FLT → IC（A/B 去重）
// → RM → 解析（UDP 目的端口）→ RX 端口缓冲 → 主机描述符 + PMEM 载荷逐字节回读。
// 与 tb_t22a_frontdoor_tx 的区别：T22a 只到 TX 出口（含 FCS/SN 核对），本 TB 让同一
// 帧真正走完整条 RX 链并做逐字节比对（载荷、头、长度），另查 IC 重复副本计数、
// DROP_CNT/K、端口统计、块守恒与 v0.5.17 的中断位置位。
// 冷启动口径：复位 → INIT_DONE → 一次 CFG_MODE 内配好 TX VL0 与 RX（种子/哈希项/
// RX_VL_CFG/端口表 + 映像提交）→ 开流；两帧之间保留真实 BAG（1000 μs）。
// 不覆盖：SAP/管理面投递、块池耗尽反压（T21）、端到端时延（T13）。
`timescale 1 ns / 1 ps
module tb_t22_loopback_core #(parameter integer IF_MODE=0);
  reg clk=0, reset=1;
  always #4 clk=~clk;
  reg host_cs=0, host_we=0;
  reg [15:0] host_addr=0;
  reg [31:0] host_wdata=0;
  wire [31:0] host_rdata;
  wire host_ack, host_irq;
  // 回灌驱动。rx_ready 在 IF_MODE=0 下既是 RX 的整帧包络，又是顶层 TX 的
  // link_rdy（顶层把同一根信号同时给了 mac_tx_if 和 mac_rx_if），所以空闲时
  // 保持 1、只在回灌帧尾拉低几拍表示帧结束（两相不重叠，不会互相干扰）。
  reg rx_valid=0, rx_valid_b=0, rx_ready=1, rx_ready_b=1;
  reg [7:0] rx_data=0, rx_data_b=0;
  wire [7:0] tx_data, tx_data_b;
  wire tx_valid, tx_valid_b, tx_ready, tx_ready_b;
  AFDX_top #(.IF_MODE(IF_MODE), .FCS_MODE(2)) dut (
    .clk(clk), .reset(reset),
    .tx_data(tx_data), .rx_data(rx_data), .tx_valid(tx_valid), .rx_valid(rx_valid),
    .tx_ready(tx_ready), .rx_ready(rx_ready),
    .tx_data_b(tx_data_b), .tx_valid_b(tx_valid_b), .tx_ready_b(tx_ready_b),
    .rx_data_b(rx_data_b), .rx_valid_b(rx_valid_b), .rx_ready_b(rx_ready_b),
    .host_cs(host_cs), .host_we(host_we), .host_addr(host_addr), .host_wdata(host_wdata),
    .host_rdata(host_rdata), .host_ack(host_ack), .host_irq(host_irq),
    .pps_in(1'b0), .pps_out(), .rtc_time_us(), .dbg_frame_event());

  localparam integer P_RX = 5;                      // RX 采样端口
  localparam [11:0]  VL_RX = 12'h100;               // 与 TX VL0 的 hdr_vlid 一致
  localparam [15:0]  PT_RX = 16'h7D80 + 4*P_RX;
  localparam [15:0]  VLID_TX = 16'h0100;            // hdr_vlid = 0x0100 + VL 号

  // DUT 自己发出的字节流（抓取用）
  reg [7:0] ca [0:255], cb [0:255];
  integer na=0, nb=0;
  reg [7:0] rxbuf_a [0:255], rxbuf_b [0:255];        // 回灌副本
  integer nrx_a=0, nrx_b=0;
  reg [31:0] rd, w;
  reg [15:0] dport_exp, vlid_seen;
  integer errors=0, i, k, waitc, blk=0, base_addr, deliveries=0, drops=0, dup_seen=0;
  reg [31:0] crc_a, crc_b;
  reg [7:0] pl_a [0:31], pl_b [0:31];                // 两帧的 32 B 载荷（取自发出流）

  function [31:0] crc_step(input [31:0] c, input [7:0] b);
    integer j; reg [31:0] x;
    begin
      x=c^{24'd0,b};
      for(j=0;j<8;j=j+1) x=x[0]?((x>>1)^32'hEDB88320):(x>>1);
      crc_step=x;
    end
  endfunction
  function [10:0] mix_bucket(input [15:0] vlid, input [15:0] seed, input table_id);
    reg [15:0] x;
    begin
      x = vlid + seed + (table_id ? 16'h1F5B : 16'h9E37);
      x = x ^ (x >> 7);
      x = x * (table_id ? 16'h45D9 : 16'h9E37);
      x = x ^ (x >> 9);
      mix_bucket = x & 11'h7FF;
    end
  endfunction
  function [15:0] hash_addr(input [15:0] vlid, input [15:0] seed, input table_id, input way);
    begin hash_addr = 16'h3D80 + ({4'd0,table_id} << 12) + (mix_bucket(vlid,seed,table_id) << 1) + way; end
  endfunction

  task bad(input [8*96-1:0] reason);
    begin
      if(errors<25) $display("  [err] T22 t=%0t: %0s",$time,reason);
      errors=errors+1;
    end
  endtask
  // 抓取两网发出字节 + CRC（IF_MODE=0 只有 tx_ready 拍有效）
  always @(posedge clk) if(!reset) begin
    if(tx_valid && (IF_MODE!=0 || tx_ready)) begin
      if(na<256) ca[na]=tx_data;
      na=na+1; crc_a=crc_step(crc_a,tx_data);
    end
    if(tx_valid_b && (IF_MODE!=0 || tx_ready_b)) begin
      if(nb<256) cb[nb]=tx_data_b;
      nb=nb+1; crc_b=crc_step(crc_b,tx_data_b);
    end
  end
  always @(posedge clk) if(!reset) begin
    if(dut.rx_ovf_a||dut.rx_ovf_b) bad("RX FIFO overflow");
    if(dut.prs_out_vld && dut.pb_in_ready) begin
      if(dut.prs_out_drop) drops=drops+1; else deliveries=deliveries+1;
    end
    if(dut.rm_dup_fire) dup_seen=dup_seen+1;
    if(host_irq!==1'b1 && dut.int_st_r[0]) bad("host_irq low with pending INT bit0");
  end

  task host_write(input [15:0] addr,input [31:0] data);
    begin
      @(negedge clk);host_cs=1;host_we=1;host_addr=addr;host_wdata=data;
      @(negedge clk);
      if(host_ack!==1'b1)bad("host write ACK missing");
      host_cs=0;host_we=0;
    end
  endtask
  task host_read(input [15:0] addr,output [31:0] data);
    begin
      @(negedge clk);host_cs=1;host_we=0;host_addr=addr;
      @(negedge clk);
      if(host_ack!==1'b1)bad("host read ACK missing");
      data=host_rdata;host_cs=0;
    end
  endtask
  task cfg_mode_on; begin host_write(16'h0008,32'h2000); end endtask
  // CTL: bit0 TX_EN、bit1 RX_EN、bit2 IC_EN、bit3 RM_EN、bit13 CFG_MODE=0
  task run_on;      begin host_write(16'h0008,32'h051F); end endtask
  function integer popc(input [15:0] m);
    integer j; begin popc=0; for(j=0;j<16;j=j+1) popc=popc+m[j]; end
  endfunction
  task idle(input integer n);
    begin
      repeat(150) @(negedge clk);
      if(popc(dut.rx_free_map)!==10-n) bad("held RX block count wrong (conservation)");
    end
  endtask
  // 回灌：把抓到的 79 B 按 RX 采样口节奏送进 A/B（B 延迟 6 拍模拟双网偏斜）
  task replay_a;
    integer b;
    begin
      repeat(2) @(negedge clk);
      for(b=0;b<nrx_a;b=b+1) begin
        @(negedge clk); rx_ready=1;rx_valid=1;rx_data=rxbuf_a[b];
        if(IF_MODE==0) begin @(negedge clk);rx_valid=0; repeat(8) @(negedge clk); end
      end
      @(negedge clk);rx_ready=0;rx_valid=0;
      repeat(4) @(negedge clk); rx_ready=1;
    end
  endtask
  task replay_b;
    integer b;
    begin
      repeat(8) @(negedge clk);
      for(b=0;b<nrx_b;b=b+1) begin
        @(negedge clk); rx_ready_b=1;rx_valid_b=1;rx_data_b=rxbuf_b[b];
        if(IF_MODE==0) begin @(negedge clk);rx_valid_b=0; repeat(8) @(negedge clk); end
      end
      @(negedge clk);rx_ready_b=0;rx_valid_b=0;
      repeat(4) @(negedge clk); rx_ready_b=1;
    end
  endtask

  initial begin
    crc_a=32'hFFFFFFFF; crc_b=32'hFFFFFFFF;
    repeat(7) @(negedge clk); reset=0;
    // ================= 0. 冷启动 =================
    waitc=0;
    while(dut.init_done!==1 && waitc<27000) begin @(negedge clk);waitc=waitc+1;end
    if(waitc>=27000) bad("INIT_DONE timeout");
    cfg_mode_on;
    // ================= 1. TX VL0 + RX 侧配置 =================
    host_write(16'h0060,32'h1234_2001);            // UDI=0x1234, IFID A=1/B=2
    host_write(16'h0064,32'h0A00_0001);
    host_write(16'h0070,32'h0000_0142);            // UDP 校验和：发送计算 + 接收校验
    host_write(16'h7D83,32'h0000_0001);            // TX 源端口 0 深度 1
    host_write(16'h7D80,32'h8000_C000);            // valid, sampling, src port 49152
    host_write(16'h0204,32'h0000_0000);            // port_base=0
    host_write(16'h0203,32'hE000_0001);            // dst_ip
    host_write(16'h0202,32'h1388_C000);            // dp=5000, sp=49152
    host_write(16'h0201,32'h0003_E800);            // BAG 1000 us
    host_write(16'h0480,32'd8305);                 // Q20 份额
    host_write(16'h0200,32'h8004_F003);            // valid, Lmax=79, net A+B
    host_read(16'h0058,rd);
    if(rd!==32'd8305) bad("CFG_SUM wrong");
    host_read(16'h005C,rd);
    if(rd!==32'd0) bad("CFG_ERR not clear");
    // RX：种子 -> 哈希项（vlid 0x0100 -> idx 0x100）-> 提交映像 -> RX_VL_CFG -> 端口表
    host_write(16'h0078,32'h172D); host_write(16'h007C,32'hAB61);
    host_write(hash_addr(VLID_TX,16'h172D,1'b0,1'b0),{3'd0,1'b1,VLID_TX,VL_RX});
    host_read(16'h0080,rd);
    if(rd[1]!==1'b1 || rd[2]!==1'b1 || rd[3]!==1'b1) bad("hash seeds/entry not registered");
    host_write(16'h0080,32'h1);                    // 提交完整映像（RX 开流门控）
    host_write(16'h1F80,32'hF500_0000|(P_RX<<12)|32'd79);
    host_write(16'h1F81,{16'd0,VLID_TX});
    host_write(PT_RX,32'h8004_0000); host_write(PT_RX+1,32'h0000_1388);  // dp=5000
    host_write(PT_RX+2,32'd0);       host_write(PT_RX+3,32'd1);
    host_read(16'h1F81,rd);
    if(rd!=={16'd0,VLID_TX}) bad("RX_VL_CFG readback");
    host_read(PT_RX+1,rd);
    if(rd!==32'h1388) bad("RX port w1 readback");
    host_write(16'h0014,32'h0000_0001);            // 只使能“新采样消息”中断源
    run_on;
    // ================= 2. 第一帧：PMEM 写 -> MSG_WR -> 抓发 =================
    host_read(16'h0074,rd);
    if(rd[4]!==1'b1 || rd[3:0]!==4'd0) bad("first open TX block is not 0");
    base_addr = 16'h8800 + (rd[3:0] << 9);
    @(negedge clk); host_cs<=1; host_we<=1;
    for(i=0;i<8;i=i+1) begin
      host_addr <= base_addr + i; host_wdata <= 32'hA0B0_C0D0 + i;
      @(negedge clk);
      if(host_ack!==1'b1) bad("PMEM burst ack missing");
    end
    host_cs<=0; host_we<=0;
    host_write(16'h8280,32'd32);
    waitc=0;
    while((dut.mac_a_done!==1'b1 || dut.mac_b_done!==1'b1) && waitc<30000) begin
      @(negedge clk); waitc=waitc+1;
    end
    if(waitc>=30000) bad("TX frame A/B did not complete");
    repeat(12) @(negedge clk);
    if(na!=79 || nb!=79) bad("TX frame length is not 79 B");
    if(crc_a!==32'hDEBB_20E3 || crc_b!==32'hDEBB_20E3) bad("TX FCS wrong");
    if(ca[0]!==8'h03 || ca[4]!==VLID_TX[15:8] || ca[5]!==VLID_TX[7:0])
      bad("TX frame DMAC/VLID prefix");
    for(i=0;i<8;i=i+1) begin
      w = 32'hA0B0_C0D0 + i;
      for(k=0;k<4;k=k+1)
        if(ca[42+4*i+k]!==w[31-8*k -: 8])
          bad("TX payload byte mismatch before loopback");
    end
    // ================= 3. 回灌 -> RX 端口交付 =================
    nrx_a=79; nrx_b=79;
    for(i=0;i<79;i=i+1) begin rxbuf_a[i]=ca[i]; rxbuf_b[i]=cb[i]; end
    fork replay_a; replay_b; join
    waitc=0;
    while(deliveries<1 && waitc<9000) begin @(negedge clk); waitc=waitc+1; end
    if(deliveries!=1) bad("loopback frame was not delivered to the RX port");
    idle(1);
    // ================= 4. 描述符、载荷逐字节、统计、中断 =================
    host_read(16'h8480+P_RX,rd);
    if(rd!==32'd1) bad("MSG_CNT is not 1 after loopback");
    host_read(16'h8180+P_RX,rd);
    if(rd[31]!==1'b1 || rd[30]!==1'b1 || rd[29]!==1'b0 || rd[28]!==1'b0)
      bad("PORT_DESC flags wrong after loopback");
    if(rd[27:24]!==4'd1) bad("PORT_DESC cnt wrong");
    if(rd[10:0]!==11'd32) bad("PORT_DESC payload length is not 32");
    if(rd[23:20]<4'd6) bad("PORT_DESC block outside RX pool");
    blk=rd[23:20];
    // 载荷逐字节：PMEM[blk] 字节 42..73 == 发出流字节 42..73（PMEM 字为大端字节序）
    for(i=10;i<19;i=i+1) begin
      host_read(16'h8800 + (blk<<9) + i, w);
      for(k=0;k<4;k=k+1) begin
        if(4*i+k>=42 && 4*i+k<74) begin
          if(w[31-8*k -: 8]!==ca[4*i+k])
            bad("RX payload byte read back differs from the transmitted frame");
          if(4*i+k<74) pl_a[4*i+k-42]=ca[4*i+k];
        end
      end
    end
    if(dut.u_rxpb.deliver_cnt!==32'd1) bad("RX deliver statistic mismatch");
    if(dut.u_rxpb.port_drop_cnt!==32'd0) bad("parse/port drop on the looped frame");
    if(dut.u_rxpb.ovr_cnt!==32'd0 || dut.u_rxpb.qovf_cnt!==32'd0) bad("port overflow stat raised");
    if(drops!==0) bad("parse rejected the looped frame");
    if(dup_seen!==1) bad("A/B copies were not deduplicated exactly once");
    host_read(16'h0040,rd); if(rd!==32'd0) bad("FLT unconf count nonzero");
    host_read(16'h0044,rd); if(rd!==32'd0) bad("FLT lmax count nonzero");
    host_read(16'h0048,rd); if(rd!==32'd0) bad("IC drop count nonzero");
    host_read(16'h004C,rd); if(rd!==32'd1) bad("RM dup count is not 1");
    host_read(16'h0018,rd);
    if(rd[0]!==1'b1) bad("INT_STATUS bit0 not set by the looped delivery");
    if(host_irq!==1'b1) bad("host_irq not raised by the looped delivery");
    host_write(16'h0018,32'h1);
    if(host_irq!==1'b0) bad("host_irq not cleared by W1C");
    host_write(16'h8380+P_RX,32'd0);              // MSG_RD 释放
    idle(0);
    // ================= 5. 第二帧：序号连续 + 又一次回环 =================
    host_read(16'h0074,rd);
    if(rd[4]!==1'b1 || rd[3:0]!==4'd1) bad("second open TX block is not 1");
    base_addr = 16'h8800 + (rd[3:0] << 9);
    na=0; nb=0; crc_a=32'hFFFFFFFF; crc_b=32'hFFFFFFFF;
    @(negedge clk); host_cs<=1; host_we<=1;
    for(i=0;i<8;i=i+1) begin
      host_addr <= base_addr + i; host_wdata <= 32'hB1C2_D3E4 + i;
      @(negedge clk);
      if(host_ack!==1'b1) bad("second PMEM burst ack missing");
    end
    host_cs<=0; host_we<=0;
    host_write(16'h8280,32'd32);
    waitc=0;
    while((na<79 || nb<79) && waitc<200000) begin @(negedge clk); waitc=waitc+1; end
    if(na!=79 || nb!=79) bad("second TX frame incomplete (BAG wait)");
    else begin
      if(ca[74]!==8'd2) bad("second frame SN is not 2");
      if(ca[42]!==8'hB1 || ca[73]!==8'hEB) bad("second frame payload prefix/suffix wrong");
    end
    nrx_a=79; nrx_b=79;
    for(i=0;i<79;i=i+1) begin rxbuf_a[i]=ca[i]; rxbuf_b[i]=cb[i]; end
    fork replay_a; replay_b; join
    waitc=0;
    while(deliveries<2 && waitc<9000) begin @(negedge clk); waitc=waitc+1; end
    if(deliveries!=2) bad("second loopback frame was not delivered (SN continuity)");
    idle(1);
    host_read(16'h8180+P_RX,rd);
    if(rd[31]!==1'b1 || rd[27:24]!==4'd1 || rd[10:0]!==11'd32) bad("second PORT_DESC wrong");
    blk=rd[23:20];
    for(i=10;i<19;i=i+1) begin
      host_read(16'h8800 + (blk<<9) + i, w);
      for(k=0;k<4;k=k+1)
        if(4*i+k>=42 && 4*i+k<74 && w[31-8*k -: 8]!==ca[4*i+k])
          bad("second RX payload byte differs from the transmitted frame");
    end
    if(dut.u_rxpb.deliver_cnt!==32'd2) bad("deliver statistic after two loopbacks");
    if(dup_seen!==2) bad("dup count after two loopbacks");
    host_read(16'h004C,rd); if(rd!==32'd2) bad("RM dup count after two loopbacks");
    host_write(16'h8380+P_RX,32'd0);
    idle(0);
    // ================= 6. TX 侧统计与守恒 =================
    if(dut.rm_frames_a!==16'd2 || dut.rm_frames_b!==16'd2) bad("TX frame count is not 2/2");
    if(dut.mac_a_underrun!==16'd0 || dut.mac_b_underrun!==16'd0) bad("MAC underrun");
    if(dut.sch_miss_cnt!==16'd0 || dut.sch_bag_cnt!==16'd0) bad("scheduler miss/BAG violation");
    if(dut.u_sn.sn_cur[0]!==8'd3) bad("TX SN did not advance to 3");
    if(dut.rx_drop_reason_a!==8'd0 || dut.rx_drop_reason_b!==8'd0) bad("RX MAC drop reason nonzero");
    if(errors==0)
      $display("T22 TOP LOOPBACK PASS (IF_MODE=%0d cold init + 2 looped frames, byte-exact payload, IC dedup, INT bit0)",
               IF_MODE);
    else $display("T22 TOP LOOPBACK FAIL (IF_MODE=%0d errors=%0d)",IF_MODE,errors);
    $finish;
  end
  initial begin
    #6_000_000;
    $display("T22 TOP LOOPBACK FAIL: timeout IF_MODE=%0d",IF_MODE); $finish;
  end
endmodule
module tb_t22_top_loopback;  tb_t22_loopback_core #(.IF_MODE(0)) core(); endmodule
module tb_t22g_top_loopback; tb_t22_loopback_core #(.IF_MODE(1)) core(); endmodule
