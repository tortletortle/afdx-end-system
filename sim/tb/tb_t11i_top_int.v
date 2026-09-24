// T11i — 顶层 RX 事件中断（v0.5.17）。
// INT_STATUS 0x0018（W1C）：[0] 新采样消息 [1] 队列入队 [2] 采样覆盖/队列满
// [3] CRC 错帧（A 或 B）；[4..7] 未定义恒 0。INT_ENABLE 0x0014 低 8 位有效。
// host_irq = CTL[14]（软件中断）| |(INT_STATUS & INT_ENABLE)，电平式，故屏蔽期间
// 事件仍登记在状态里，使能后立刻拉高 IRQ。
// 覆盖：复位初值、INT_ENABLE 位宽、软件中断、屏蔽/电平语义、采样交付、队列入队、
// 采样覆盖、队列满、坏 FCS（crc_err 只置 bit3 且不投递）、事件优先于同拍 W1C、
// W1C 只清所选位、事件脉冲宽度、块守恒与统计。
// 不覆盖：TFTP/SNMP/RTC（bit5..7，管理面未实现）、丢帧突增阈值（bit4）。
// 每帧为 t08a 真实 79 B 模型帧（SN/载荷标记打补丁、重算 FCS、关 UDP 校验和）；
// 每个 VL 独立维护 SN（IC 严格序号：VL 首帧必须 SN=1）。
`timescale 1 ns / 1 ps
module tb_t11i_core #(parameter integer IF_MODE=0);
  reg clk=0, reset=1;
  always #4 clk=~clk;
  reg host_cs=0, host_we=0, rx_valid=0, rx_valid_b=0, rx_ready=0, rx_ready_b=0;
  reg [15:0] host_addr=0;
  reg [31:0] host_wdata=0;
  reg [7:0] rx_data=0, rx_data_b=0;
  wire [31:0] host_rdata;
  wire host_ack, host_irq;
  AFDX_top #(.IF_MODE(IF_MODE), .FCS_MODE(2)) dut (
    .clk(clk), .reset(reset), .tx_data(), .tx_valid(), .tx_ready(),
    .rx_data(rx_data), .rx_valid(rx_valid), .rx_ready(rx_ready),
    .tx_data_b(), .tx_valid_b(), .tx_ready_b(),
    .rx_data_b(rx_data_b), .rx_valid_b(rx_valid_b), .rx_ready_b(rx_ready_b),
    .host_cs(host_cs), .host_we(host_we), .host_addr(host_addr),
    .host_wdata(host_wdata), .host_rdata(host_rdata), .host_ack(host_ack),
    .host_irq(host_irq), .pps_in(1'b0), .pps_out(), .rtc_time_us(),
    .dbg_frame_event());

  localparam integer P_S = 5;                    // 采样端口
  localparam integer P_Q = 6;                    // 队列端口
  localparam [11:0]  VL_S = 12'h100, VL_Q = 12'h101;
  localparam [15:0]  PT_S = 16'h7D80 + 4*P_S;
  localparam [15:0]  PT_Q = 16'h7D80 + 4*P_Q;
  reg [31:0] vec [0:1144];
  reg [7:0] base [0:78];
  reg [7:0] frm_a [0:78];
  reg [7:0] frm_b [0:78];
  reg [31:0] rd, w;
  reg [15:0] dport;
  integer errors=0, i, k, waitc, prs_ok=0, drops_seen=0, dup_seen=0, crc_seen=0;
  integer exp_deliv=0, exp_prs=0, exp_dup=0;
  reg [7:0] sn_s_a, sn_s_b, sn_q_a, sn_q_b;       // 每 VL 每网的下一 SN

  task bad(input [8*96-1:0] reason);
    begin
      if (errors<25) $display("  [err] T11i t=%0t: %0s",$time,reason);
      errors=errors+1;
    end
  endtask
  always @(posedge clk) if(!reset) begin
    if(dut.rx_ovf_a||dut.rx_ovf_b) bad("RX FIFO overflow");
    if(dut.prs_out_vld && dut.pb_in_ready) begin
      if(dut.prs_out_drop) drops_seen=drops_seen+1; else prs_ok=prs_ok+1;
    end
    if(dut.rm_dup_fire) dup_seen=dup_seen+1;
    if(dut.rx_crc_err_a||dut.rx_crc_err_b) crc_seen=crc_seen+1;
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

  function [31:0] crc_step(input [31:0] c, input [7:0] b);
    integer j; reg [31:0] x;
    begin
      x=c^{24'd0,b};
      for(j=0;j<8;j=j+1) x=x[0]?((x>>1)^32'hEDB88320):(x>>1);
      crc_step=x;
    end
  endfunction
  // 与 rx_vl_lookup.mix_bucket 逐位一致（2048 桶）
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
  // vlid（字节 4/5）、SN（74）、载荷标记（42/43）打补丁后重算 FCS；corrupt=1 时
  // 翻转 FCS 末字节（长度/格式仍合法，只有 CRC 错）。
  task build(input net, input [15:0] vlid, input [7:0] sn, input [7:0] mk, input corrupt);
    integer j; reg [31:0] c; reg [7:0] v;
    begin
      c=32'hFFFFFFFF;
      for(j=0;j<75;j=j+1) begin
        v=(j==4)?vlid[15:8]:(j==5)?vlid[7:0]:(j==74)?sn:(j==42)?mk:(j==43)?~mk:base[j];
        if(net) frm_b[j]=v; else frm_a[j]=v;
        c=crc_step(c,v);
      end
      c=~c;
      for(j=0;j<4;j=j+1) begin
        v=c[8*j+:8];
        if(corrupt && j==3) v=v^8'h5A;
        if(net) frm_b[75+j]=v; else frm_a[75+j]=v;
      end
    end
  endtask
  task drive_a(input integer delay);
    integer b;
    begin
      repeat(delay) @(negedge clk);
      for(b=0;b<79;b=b+1) begin
        @(negedge clk); rx_ready=1;rx_valid=1;rx_data=frm_a[b];
        if(IF_MODE==0) begin @(negedge clk);rx_valid=0; repeat(8) @(negedge clk); end
      end
      @(negedge clk);rx_ready=0;rx_valid=0;
    end
  endtask
  task drive_b(input integer delay);
    integer b;
    begin
      repeat(delay) @(negedge clk);
      for(b=0;b<79;b=b+1) begin
        @(negedge clk); rx_ready_b=1;rx_valid_b=1;rx_data_b=frm_b[b];
        if(IF_MODE==0) begin @(negedge clk);rx_valid_b=0; repeat(8) @(negedge clk); end
      end
      @(negedge clk);rx_ready_b=0;rx_valid_b=0;
    end
  endtask

  task wait_init;
    begin
      waitc=0;
      while(dut.init_done!==1 && waitc<26000) begin @(negedge clk);waitc=waitc+1;end
      if(waitc>=26000) bad("INIT_DONE timeout");
    end
  endtask
  task cfg_mode_on; begin host_write(16'h0008,32'h2000); end endtask
  task run_on;      begin host_write(16'h0008,32'h051E); end endtask
  function integer popc(input [15:0] m);
    integer j; begin popc=0; for(j=0;j<16;j=j+1) popc=popc+m[j]; end
  endfunction
  task idle(input integer n);
    begin
      repeat(120) @(negedge clk);
      if(popc(dut.rx_free_map)!==10-n) bad("held RX block count wrong (conservation)");
    end
  endtask
  task read_desc(input integer p); begin host_read(16'h8180+p,rd); end endtask
  task msg_rd(input integer p); begin host_write(16'h8380+p,32'd0); end endtask
  // A/B 同步一对（同 SN）——IC 去重后恰好投递一次
  task pair(input sel, input [7:0] mk, input drop_exp);  // sel=0 采样 VL，1 队列 VL
    begin
      if(!sel) begin
        build(0,16'h0100,sn_s_a,mk,0); build(1,16'h0100,sn_s_b,mk,0);
      end else begin
        build(0,16'h0101,sn_q_a,mk,0); build(1,16'h0101,sn_q_b,mk,0);
      end
      fork drive_a(0); drive_b(3); join
      if(!sel) begin sn_s_a=sn_s_a+1; sn_s_b=sn_s_b+1; end
      else     begin sn_q_a=sn_q_a+1; sn_q_b=sn_q_b+1; end
      if(!drop_exp) exp_deliv=exp_deliv+1;      // 队列满丢弃由端口缓冲自己丢
      exp_prs=exp_prs+1; exp_dup=exp_dup+1;
    end
  endtask
  task chk_st(input [31:0] exp, input [8*44-1:0] tag);
    begin
      host_read(16'h0018,rd);
      if(rd!==exp) begin $display("  [err] INT_STATUS=%h want %h",rd,exp); bad(tag); end
      if(host_irq!==1'b1) bad("host_irq not asserted with pending+enabled status");
    end
  endtask
  task chk_st0(input [8*40-1:0] tag);
    begin
      host_read(16'h0018,rd);
      if(rd!==32'd0) bad(tag);
      if(host_irq!==1'b0) bad("host_irq stuck high with empty status");
    end
  endtask
  task w1c(input [31:0] mask); begin host_write(16'h0018,mask); end endtask

  initial begin
    $readmemh("vec/t08a_frames.hex",vec);
    if(vec[0]!==22 || vec[37][15:0]!==79 || vec[37][31:24]!==2)
      bad("t08a real frame vector missing or shifted");
    for(i=0;i<79;i=i+1) begin
      rd=vec[37+2+(i>>2)];
      case(i&3) 0: base[i]=rd[31:24]; 1: base[i]=rd[23:16];
                2: base[i]=rd[15:8]; default: base[i]=rd[7:0]; endcase
    end
    if(base[74]!==8'd1) bad("base frame SN byte not at offset 74");
    dport={base[36],base[37]};
    if({base[38],base[39]}!==16'd40) bad("base frame UDP length is not 8+32");
    repeat(7) @(negedge clk);reset=0;
    // ============ 0. 复位初值 ============
    wait_init;
    host_read(16'h0014,rd);
    if(rd!==32'd0) bad("INT_ENABLE not clear after reset");
    chk_st0("INT_STATUS not clear after reset");
    // ============ 配置 ============
    cfg_mode_on;
    host_write(16'h0014,32'h0000_01FF);           // 高位无存储，读回低 8 位
    host_read(16'h0014,rd);
    if(rd!==32'hFF) bad("INT_ENABLE readback is not low 8 bits");
    host_write(16'h0014,32'h0000_0000);
    host_write(16'h0078,32'h172D); host_write(16'h007C,32'hAB61);
    host_write(hash_addr(16'h0100,16'h172D,1'b0,1'b0),{3'd0,1'b1,16'h0100,VL_S});
    host_write(hash_addr(16'h0101,16'h172D,1'b0,1'b0),{3'd0,1'b1,16'h0101,VL_Q});
    host_write(16'h0080,32'h1);                   // 提交哈希映像（RX 开流门控）
    host_write(16'h0070,32'h0000_0140);           // 关 UDP 校验和（载荷打补丁）
    host_write(16'h1F80,32'hF500_0000|(P_S<<12)|32'd79);
    host_write(16'h1F81,{16'd0,16'h0100});
    host_write(16'h1F82,32'hF500_0000|(P_Q<<12)|32'd79);
    host_write(16'h1F83,{16'd0,16'h0101});
    host_write(PT_S,32'h8004_0000); host_write(PT_S+1,{16'd0,dport});
    host_write(PT_S+2,32'd0);       host_write(PT_S+3,32'd1);
    host_write(PT_Q,32'h8005_0000); host_write(PT_Q+1,{16'd0,dport});
    host_write(PT_Q+2,32'd0);       host_write(PT_Q+3,32'd1);
    host_write(16'h0014,32'h0000_000F);           // 使能 bit0..3
    run_on;
    sn_s_a=1; sn_s_b=1; sn_q_a=1; sn_q_b=1;
    // ============ 1. 软件中断（CTL[14]）与电平语义 ============
    host_write(16'h0008,32'h4000);
    if(host_irq!==1'b1) bad("software IRQ (CTL[14]) not forwarded");
    host_read(16'h0018,rd);
    if(rd!==32'd0) bad("software IRQ set status bits");
    host_write(16'h0008,32'h051E);
    if(host_irq!==1'b0) bad("software IRQ not cleared");
    // ============ 2. 屏蔽下仍登记、使能后成为电平 ============
    host_write(16'h0014,32'h0000_0000);
    pair(0,8'h11,0);
    idle(1);
    host_read(16'h0018,rd);
    if(rd!==32'h1) bad("masked sample event not recorded in INT_STATUS");
    if(host_irq!==1'b0) bad("host_irq raised while masked");
    host_write(16'h0014,32'h0000_000F);
    if(host_irq!==1'b1) bad("pending status did not raise IRQ on enable");
    w1c(32'h1); w1c(32'h1);                        // 第二笔对已清位无影响
    chk_st0("W1C did not clear bit0");
    read_desc(P_S); msg_rd(P_S); idle(0);
    // ============ 3. 队列入队（bit1） ============
    pair(1,8'h22,0);
    idle(1);
    chk_st(32'h2,"queue enqueue did not set bit1");
    w1c(32'h1);                                    // 清未置位位不影响 bit1
    chk_st(32'h2,"W1C of bit0 disturbed bit1");
    read_desc(P_Q); msg_rd(P_Q); idle(0);
    w1c(32'hFF); chk_st0("W1C after queue scenario");
    // ============ 4. 采样覆盖（bit0|bit2） ============
    pair(0,8'h33,0);
    read_desc(P_S);                                // 主机已读：旧块转为 pin
    pair(0,8'h44,0);
    idle(1);
    chk_st(32'h5,"sampling overwrite did not set bit0|bit2");
    host_read(16'h8480+P_S,rd);
    if(rd!==32'd1) bad("overwrite did not keep exactly one message");
    if(dut.u_rxpb.ovr_cnt!==32'd1) bad("OVR statistic mismatch");
    read_desc(P_S); msg_rd(P_S); idle(0);
    w1c(32'hFF);
    chk_st0("W1C 0xFF did not clear sample+overwrite");
    // ============ 5. 队列满丢弃（bit1|bit2） ============
    pair(1,8'h55,0);
    read_desc(P_Q);
    pair(1,8'h66,1);
    idle(1);
    chk_st(32'h6,"queue overflow did not set bit1|bit2");
    if(dut.u_rxpb.qovf_cnt!==32'd1) bad("Q_OVF statistic mismatch");
    read_desc(P_Q); msg_rd(P_Q); idle(0);
    w1c(32'hFF);
    chk_st0("W1C after queue overflow");
    // ============ 6. 坏 FCS（A 网 / B 网）：只置 bit3、不投递 ============
    build(0,16'h0100,sn_s_a,8'h77,1'b1);
    drive_a(0);
    repeat(60) @(negedge clk);
    chk_st(32'h8,"A 网坏 FCS did not set bit3");
    if(prs_ok!==exp_prs) bad("bad FCS frame reached the parse/port stage (A)");
    if(crc_seen!==1) bad("mac_rx_if crc_err pulse count wrong (A)");
    if(dut.u_rxpb.port_drop_cnt!==32'd0) bad("bad FCS counted as port drop");
    w1c(32'h8); chk_st0("W1C bit3 (A)");
    build(1,16'h0100,sn_s_b,8'h78,1'b1);
    drive_b(0);
    repeat(60) @(negedge clk);
    chk_st(32'h8,"B 网坏 FCS did not set bit3");
    if(crc_seen!==2) bad("mac_rx_if crc_err pulse count wrong (B)");
    if(prs_ok!==exp_prs) bad("bad FCS frame reached the parse/port stage (B)");
    w1c(32'h8); chk_st0("W1C bit3 (B)");
    // ============ 7. 事件优先于同拍 W1C ============
    build(0,16'h0100,sn_s_a,8'h88,0); build(1,16'h0100,sn_s_b,8'h88,0);
    fork
      begin : race_w1c
        @(negedge clk);
        while(dut.u_rxpb.ev_sample!==1'b1) @(negedge clk);   // 事件脉冲所在拍
        host_cs=1;host_we=1;host_addr=16'h0018;host_wdata=32'h1;
        @(negedge clk); host_cs=0; host_we=0;                // 与事件同拍被采样
      end
      begin drive_a(0); end
      begin drive_b(6); end
    join
    repeat(60) @(negedge clk);
    host_read(16'h0018,rd);
    if(rd!==32'h1) bad("same-cycle W1C beat the new event (event must win)");
    exp_deliv=exp_deliv+1; exp_prs=exp_prs+1; exp_dup=exp_dup+1;
    sn_s_a=sn_s_a+1; sn_s_b=sn_s_b+1;
    idle(1);
    read_desc(P_S); msg_rd(P_S); idle(0);
    w1c(32'h1); chk_st0("W1C after race");
    // ============ 8. 统计、守恒、脉冲宽度 ============
    if(dut.u_rxpb.deliver_cnt!==exp_deliv) bad("deliver count mismatch");
    if(prs_ok!==exp_prs) bad("parse-accepted count mismatch");
    if(drops_seen!==0) bad("unexpected parse drop");
    if(dut.u_rxpb.port_drop_cnt!==32'd0) bad("port drop count mismatch");
    if(dup_seen!==exp_dup) bad("A/B duplicate count mismatch");
    if(dut.u_rxpb.ev_sample!==1'b0||dut.u_rxpb.ev_queue!==1'b0||
       dut.u_rxpb.ev_ovf!==1'b0) bad("event pulses not 1-cycle");
    if(errors==0) $display("T11i TOP INT PASS (sw IRQ, mask/level, sample/queue/ovf, crc bit3, event>W1C, W1C semantics)");
    else          $display("T11i TOP INT FAIL: %0d errors",errors);
    $finish;
  end
  initial begin
    #4_000_000;
    $display("T11i TOP INT FAIL: timeout"); $finish;
  end
endmodule

module tb_t11i_top_int;  tb_t11i_core #(.IF_MODE(0)) core(); endmodule
module tb_t11ig_top_int; tb_t11i_core #(.IF_MODE(1)) core(); endmodule
