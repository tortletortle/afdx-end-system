// =====================================================================
// T14 —— 全局统计页 stats_regs（0x0100~0x01FF）
// A 部分（单元级）：直接驱动 stats_regs 事件口，校验帧/字节/丢弃计数、
//   帧长 8 桶与前 8 VL 直方图、复位清零、W1C 与读清语义、冻结、
//   "同拍清零 + 事件"不丢事件、0x00~0x03 镜像只读。
// B 部分（顶层）：AFDX_top 前门读写 0x0100~0x01FF，真实 64 B 金标帧经
//   mac_rx_if→lookup→FLT→IC→RM 流过，TB 侧独立累加与寄存器回读比对；
//   并校验统计页写不再误置 ERR.ACC、只读镜像写仍置 ERR.ACC。
// 边界：dmac/ip_csum/udp_csum 三类无判决源，B 部分不对其断言非零。
// =====================================================================
`timescale 1 ns / 1 ps
module tb_t14_stats_regs #(parameter integer IF_MODE = 0);
  integer errors = 0;
  reg clk = 0;
  always #4 clk = ~clk;
  task bad;
    input [8*110-1:0] reason;
    begin if (errors < 24) $display("  [err] T14: %0s", reason); errors = errors + 1; end
  endtask

  // ---------------- A 部分：单元级 ----------------
  reg        u_rst = 1'b1, u_freeze = 1'b0;
  reg        u_rx_in_evt = 0;  reg [10:0] u_rx_in_len = 0;
  reg        u_rx_acc_evt = 0; reg [10:0] u_rx_acc_len = 0;
  reg [11:0] u_rx_acc_vl = 0;  reg [23:0] u_rx_acc_ts = 0;
  reg        u_tx_evt = 0;     reg [12:0] u_tx_len = 0;
  reg [11:0] u_drop_evt = 0;
  reg [31:0] u_pb0 = 32'h1111_0000, u_pb1 = 32'h2222_0000,
             u_pb2 = 32'h3333_0000, u_pb3 = 32'h4444_0000;
  reg        u_rd = 0, u_wr = 0;
  reg [7:0]  u_off = 0;
  reg [31:0] u_wdata = 0;
  wire [31:0] u_rdata;
  wire        u_wrok;
  stats_regs uut (
    .clk(clk), .rst_sync(u_rst), .freeze(u_freeze),
    .rx_in_evt(u_rx_in_evt), .rx_in_len(u_rx_in_len),
    .rx_acc_evt(u_rx_acc_evt), .rx_acc_len(u_rx_acc_len),
    .rx_acc_vl(u_rx_acc_vl), .rx_acc_ts(u_rx_acc_ts),
    .tx_evt(u_tx_evt), .tx_len(u_tx_len), .drop_evt(u_drop_evt),
    .pb_deliver_cnt(u_pb0), .pb_port_drop_cnt(u_pb1),
    .pb_ovr_cnt(u_pb2), .pb_qovf_cnt(u_pb3),
    .host_rd(u_rd), .host_wr(u_wr), .host_off(u_off), .host_wdata(u_wdata),
    .host_rdata(u_rdata), .wr_ok(u_wrok),
    .snmp_off(8'h00), .snmp_rdata(), .jit_max_o(), .drop_total_o());

  task peek;                       // 纯组合观测，不产生读清
    input [7:0] off; output [31:0] d;
    begin u_off = off; #1; d = u_rdata; end
  endtask
  task uread;                      // 带 strobe 的读（RD_CLR_EN=1 时读清）
    input [7:0] off; output [31:0] d;
    begin @(negedge clk); u_off = off; u_rd = 1'b1; #1; d = u_rdata;
          @(negedge clk); u_rd = 1'b0; end
  endtask
  task uwrite;
    input [7:0] off; input [31:0] data;
    begin @(negedge clk); u_off = off; u_wdata = data; u_wr = 1'b1;
          @(negedge clk); u_wr = 1'b0; end
  endtask
  task rx_in;
    input [10:0] len;
    begin @(negedge clk); u_rx_in_evt = 1; u_rx_in_len = len;
          @(negedge clk); u_rx_in_evt = 0; end
  endtask
  task rx_acc;
    input [10:0] len; input [11:0] vl; input [23:0] ts;
    begin @(negedge clk); u_rx_acc_evt = 1; u_rx_acc_len = len;
          u_rx_acc_vl = vl; u_rx_acc_ts = ts;
          @(negedge clk); u_rx_acc_evt = 0; end
  endtask
  task tx_ev;
    input [12:0] len;
    begin @(negedge clk); u_tx_evt = 1; u_tx_len = len;
          @(negedge clk); u_tx_evt = 0; end
  endtask
  task drop_ev;
    input [11:0] m;
    begin @(negedge clk); u_drop_evt = m; @(negedge clk); u_drop_evt = 0; end
  endtask

  // ---------------- B 部分：顶层 ----------------
  reg reset = 1'b1;
  reg [7:0] rx_data = 0, rx_data_b = 0;
  reg rx_valid = 0, rx_valid_b = 0, rx_ready = 0, rx_ready_b = 0;
  reg host_cs = 0, host_we = 0;
  reg [15:0] host_addr = 0;
  reg [31:0] host_wdata = 0;
  wire [31:0] host_rdata;
  wire host_ack;
  AFDX_top #(.IF_MODE(IF_MODE), .FCS_MODE(2)) dut (
    .rx_error(1'b0), .rx_error_b(1'b0),
    .clk(clk), .reset(reset), .tx_data(), .tx_valid(), .tx_ready(),
    .rx_data(rx_data), .rx_valid(rx_valid), .rx_ready(rx_ready),
    .tx_data_b(), .tx_valid_b(), .tx_ready_b(),
    .rx_data_b(rx_data_b), .rx_valid_b(rx_valid_b), .rx_ready_b(rx_ready_b),
    .host_cs(host_cs), .host_we(host_we), .host_addr(host_addr),
    .host_wdata(host_wdata), .host_rdata(host_rdata), .host_ack(host_ack),
    .host_irq(), .pps_in(1'b0), .pps_out(), .rtc_time_us(), .dbg_frame_event());

  task host_write;
    input [15:0] addr; input [31:0] data;
    begin
      @(negedge clk); host_cs = 1; host_we = 1; host_addr = addr; host_wdata = data;
      @(negedge clk); if (host_ack !== 1'b1) bad("host write ACK missing");
      host_cs = 0; host_we = 0;
    end
  endtask
  task host_read;
    input [15:0] addr; output [31:0] data;
    begin
      @(negedge clk); host_cs = 1; host_we = 0; host_addr = addr;
      @(negedge clk); if (host_ack !== 1'b1) bad("host read ACK missing");
      data = host_rdata; host_cs = 0;
    end
  endtask

  // TB 侧独立记分板：不读 RTL 计数器，只观测流水握手拍
  integer sb_rx_frames = 0, sb_rx_bytes = 0, sb_rx_acc = 0;
  integer sb_bkt [0:7];
  integer sb_i;
  always @(posedge clk) if (!reset) begin
    if (dut.lookup_take) begin
      sb_rx_frames = sb_rx_frames + 1;
      sb_rx_bytes  = sb_rx_bytes + dut.lookup_in_desc[158:148];
    end
    if (dut.rm_fire && dut.rm_out_fwd) begin
      sb_rx_acc = sb_rx_acc + 1;
      sb_bkt[bucket_of(dut.rm_out_desc[158:148])] =
        sb_bkt[bucket_of(dut.rm_out_desc[158:148])] + 1;
    end
  end
  function integer bucket_of;
    input [12:0] l;
    begin
      if      (l <= 13'd64)   bucket_of = 0;
      else if (l <= 13'd128)  bucket_of = 1;
      else if (l <= 13'd256)  bucket_of = 2;
      else if (l <= 13'd512)  bucket_of = 3;
      else if (l <= 13'd768)  bucket_of = 4;
      else if (l <= 13'd1024) bucket_of = 5;
      else if (l <= 13'd1518) bucket_of = 6;
      else                    bucket_of = 7;
    end
  endfunction

  localparam integer P_SAP = 5;
  localparam [15:0] PT_SAP = 16'h7D80 + 4*P_SAP;
  localparam [31:0] W0_VL  = 32'hF500_0000 | (P_SAP<<12) | 32'd79;
  reg [31:0] vec [0:1144];
  integer vec_idx, case0_base;
  function [7:0] frame_byte;
    input integer off; reg [31:0] q;
    begin
      q = vec[case0_base + (off>>2)];
      case (off & 3) 0: frame_byte = q[31:24]; 1: frame_byte = q[23:16];
                     2: frame_byte = q[15:8]; default: frame_byte = q[7:0]; endcase
    end
  endfunction
  integer b;
  task drive_frame;
    begin
      for (b = 0; b < 64; b = b + 1) begin
        @(negedge clk); rx_ready = 1; rx_valid = 1; rx_data = frame_byte(b);
        if (IF_MODE == 0) begin
          @(negedge clk); rx_valid = 0; repeat (8) @(negedge clk);
        end
      end
      @(negedge clk); rx_ready = 0; rx_valid = 0;
    end
  endtask

  reg [31:0] d, e;
  integer waitc, i;

  initial begin
    for (sb_i = 0; sb_i < 8; sb_i = sb_i + 1) sb_bkt[sb_i] = 0;

    // ============ A 部分 ============
    repeat (4) @(negedge clk); u_rst = 1'b0;
    // A1 复位清零
    peek(8'h04,d); if (d !== 32'd0) bad("A1 RX_FRAME not zero after reset");
    peek(8'h0B,d); if (d !== 32'd0) bad("A1 DROP_TOTAL not zero after reset");
    peek(8'h20,d); if (d !== 32'd0) bad("A1 HIST_LEN0 not zero after reset");
    // A2 0x00~0x03 镜像只读
    peek(8'h00,d); if (d !== u_pb0) bad("A2 deliver mirror wrong");
    peek(8'h01,d); if (d !== u_pb1) bad("A2 port-drop mirror wrong");
    peek(8'h02,d); if (d !== u_pb2) bad("A2 ovr mirror wrong");
    peek(8'h03,d); if (d !== u_pb3) bad("A2 qovf mirror wrong");
    u_off = 8'h00; #1; if (u_wrok !== 1'b0) bad("A2 mirror must reject writes");
    u_off = 8'h04; #1; if (u_wrok !== 1'b1) bad("A2 RX_FRAME must accept W1C");
    // A3 帧/字节计数 + 64 bit 进位
    rx_in(11'd64); rx_in(11'd1518); rx_in(11'd100);
    peek(8'h04,d); if (d !== 32'd3) bad("A3 RX_FRAME count wrong");
    peek(8'h05,d); if (d !== 32'd1682) bad("A3 RX_BYTE_LO wrong");
    peek(8'h06,d); if (d !== 32'd0) bad("A3 RX_BYTE_HI must stay 0");
    tx_ev(13'd1471); tx_ev(13'd8);
    peek(8'h08,d); if (d !== 32'd2) bad("A3 TX_FRAME wrong");
    peek(8'h09,d); if (d !== 32'd1479) bad("A3 TX_BYTE_LO wrong");
    // A4 接受帧 + 帧长分桶 + 前 8 VL 直方图
    rx_acc(11'd64,  12'd0, 24'd100);
    rx_acc(11'd65,  12'd3, 24'd140);
    rx_acc(11'd1518,12'd7, 24'd200);
    rx_acc(11'd200, 12'd9, 24'd260);   // VL>=8：不进 VL 直方图
    peek(8'h07,d); if (d !== 32'd4) bad("A4 RX_ACCEPT wrong");
    peek(8'h20,d); if (d !== 32'd1) bad("A4 HIST_LEN[0] (<=64) wrong");
    peek(8'h21,d); if (d !== 32'd1) bad("A4 HIST_LEN[1] (65..128) wrong");
    peek(8'h22,d); if (d !== 32'd1) bad("A4 HIST_LEN[2] (129..256) wrong");
    peek(8'h26,d); if (d !== 32'd1) bad("A4 HIST_LEN[6] (1025..1518) wrong");
    peek(8'h28,d); if (d !== 32'd1) bad("A4 HIST_VL[0] wrong");
    peek(8'h2B,d); if (d !== 32'd1) bad("A4 HIST_VL[3] wrong");
    peek(8'h2F,d); if (d !== 32'd1) bad("A4 HIST_VL[7] wrong");
    peek(8'h29,d); if (d !== 32'd0) bad("A4 HIST_VL[1] must stay 0");
    // A5 抖动（帧间到达间隔）高水位 / 最近值
    peek(8'h0D,d); if (d !== 32'd60) bad("A5 JIT_LAST wrong");
    peek(8'h0C,d); if (d !== 32'd60) bad("A5 JIT_MAX wrong");
    // A6 12 类丢弃 + 合计
    drop_ev(12'b0000_0000_0001);       // len
    drop_ev(12'b0000_1000_0000);       // crc
    drop_ev(12'b1000_0000_0000);       // rm
    drop_ev(12'b0000_1000_0001);       // 同拍两类
    peek(8'h10,d); if (d !== 32'd2) bad("A6 DROP_K[0] len wrong");
    peek(8'h17,d); if (d !== 32'd2) bad("A6 DROP_K[7] crc wrong");
    peek(8'h1B,d); if (d !== 32'd1) bad("A6 DROP_K[11] rm wrong");
    peek(8'h11,d); if (d !== 32'd0) bad("A6 DROP_K[1] dmac must stay 0 (unsourced)");
    peek(8'h0B,d); if (d !== 32'd5) bad("A6 DROP_TOTAL wrong");
    // A7 W1C：整字清 + 部分位清
    uwrite(8'h04, 32'hFFFF_FFFF);
    peek(8'h04,d); if (d !== 32'd0) bad("A7 W1C full clear failed");
    uwrite(8'h0B, 32'h0000_0001);      // 5 & ~1 = 4
    peek(8'h0B,d); if (d !== 32'd4) bad("A7 W1C partial clear failed");
    uwrite(8'h0B, 32'hFFFF_FFFF);
    // A8 同拍清零 + 事件：事件不得丢失
    @(negedge clk); u_off = 8'h04; u_wdata = 32'hFFFF_FFFF; u_wr = 1'b1;
                    u_rx_in_evt = 1; u_rx_in_len = 11'd70;
    @(negedge clk); u_wr = 1'b0; u_rx_in_evt = 0;
    peek(8'h04,d); if (d !== 32'd1) bad("A8 event lost on same-cycle clear");
    // A9 读清语义
    uwrite(8'h0F, 32'h1);
    peek(8'h0F,d); if (d !== 32'h1) bad("A9 STATS_CTL readback wrong");
    uread(8'h04,d); if (d !== 32'd1) bad("A9 read-clear must return old value");
    peek(8'h04,d); if (d !== 32'd0) bad("A9 read-clear did not clear");
    peek(8'h07,e); uread(8'h07,d);
    if (d !== e) bad("A9 read-clear ACCEPT returned wrong value");
    peek(8'h07,d); if (d !== 32'd0) bad("A9 read-clear ACCEPT did not clear");
    // 镜像不受读清影响
    uread(8'h00,d); if (d !== u_pb0) bad("A9 mirror changed by read-clear");
    peek(8'h00,d); if (d !== u_pb0) bad("A9 mirror cleared by read-clear");
    uwrite(8'h0F, 32'h0);
    // A10 冻结（STATS_CTL[1]）与 DBG_CTRL 冻结口
    uwrite(8'h0F, 32'h2);
    rx_in(11'd64); peek(8'h04,d); if (d !== 32'd0) bad("A10 FREEZE_SW did not stop counting");
    uwrite(8'h0F, 32'h0);
    u_freeze = 1'b1; rx_in(11'd64);
    peek(8'h04,d); if (d !== 32'd0) bad("A10 freeze input did not stop counting");
    u_freeze = 1'b0; rx_in(11'd64);
    peek(8'h04,d); if (d !== 32'd1) bad("A10 counting did not resume");
    // A11 再复位清零
    @(negedge clk); u_rst = 1'b1; repeat (3) @(negedge clk); u_rst = 1'b0;
    peek(8'h04,d); if (d !== 32'd0) bad("A11 RX_FRAME not cleared by reset");
    peek(8'h20,d); if (d !== 32'd0) bad("A11 HIST_LEN not cleared by reset");
    peek(8'h0C,d); if (d !== 32'd0) bad("A11 JIT_MAX not cleared by reset");
    peek(8'h1B,d); if (d !== 32'd0) bad("A11 DROP_K not cleared by reset");

    // ============ B 部分 ============
    $readmemh("vec/t08a_frames.hex", vec);
    if (vec[0] !== 32'd22 || vec[1][15:0] !== 16'd64 || vec[2] !== 32'h7)
      bad("B0 64B SAP golden fixture missing");
    case0_base = 3;
    vec_idx = 1;
    repeat (7) @(negedge clk); reset = 0;
    waitc = 0;
    while (dut.init_done !== 1 && waitc < 26000) begin @(negedge clk); waitc = waitc + 1; end
    if (waitc >= 26000) bad("B0 INIT_DONE timeout");
    // B1 复位后整页为 0（除 0x00~0x03 镜像）
    for (i = 4; i < 16; i = i + 1) begin
      host_read(16'h0100 + i[15:0], d);
      if (d !== 32'd0) bad("B1 stats word not zero after reset");
    end
    host_read(16'h0140, d); if (d !== 32'd0) bad("B1 unmapped page word must read 0");
    host_read(16'h0010, d); if (d[0] !== 1'b0) bad("B1 page read set ERR.ACC");
    // B2 统计页 W1C 写不置 ERR.ACC；只读镜像写置 ERR.ACC
    host_write(16'h0104, 32'hFFFF_FFFF);
    host_read(16'h0010, d); if (d[0] !== 1'b0) bad("B2 legal stats W1C set ERR.ACC");
    host_write(16'h0100, 32'hFFFF_FFFF);
    host_read(16'h0010, d); if (d[0] !== 1'b1) bad("B2 RO mirror write did not set ERR.ACC");
    host_write(16'h0010, 32'h1);
    host_read(16'h0010, d); if (d[0] !== 1'b0) bad("B2 ERR.ACC W1C failed");
    // B3 配置并放一帧真实 64 B 金标帧
    host_write(16'h0008, 32'h2000);
    host_write(16'h0078, 32'h172D); host_write(16'h007C, 32'hAB61);
    host_write(16'h42B2, 32'h1010_0100); host_write(16'h0080, 32'h1);
    host_write(16'h1F80, W0_VL); host_write(16'h1F81, 32'h0000_0100);
    host_write(PT_SAP,   32'h8006_0000); host_write(PT_SAP+1, 32'h0000_1388);
    host_write(PT_SAP+2, 32'd0);         host_write(PT_SAP+3, 32'd1);
    host_write(16'h0008, 32'h051E);
    drive_frame();
    waitc = 0;
    while (dut.mgmt_accept_cnt < 1 && waitc < 20000) begin @(negedge clk); waitc = waitc + 1; end
    if (waitc >= 20000) bad("B3 frame never reached SAP handoff");
    repeat (40) @(negedge clk);
    if (sb_rx_frames !== 1) bad("B3 scoreboard expected exactly one pipeline frame");
    host_read(16'h0104, d);
    if (d !== sb_rx_frames[31:0]) bad("B3 RX_FRAME_CNT != TB scoreboard");
    host_read(16'h0105, d);
    if (d !== sb_rx_bytes[31:0]) bad("B3 RX_BYTE_LO != TB scoreboard");
    host_read(16'h0107, d);
    if (d !== sb_rx_acc[31:0]) bad("B3 RX_ACCEPT != TB scoreboard");
    if (sb_rx_acc != 1) bad("B3 expected exactly one RM forward");
    host_read(16'h0120 + bucket_of(64), d);
    if (d !== 32'd1) bad("B3 frame-length histogram bucket not incremented");
    // 0x00~0x03 既有口径不变（SAP 帧不进端口面）
    host_read(16'h0100, d); if (d !== 32'd0) bad("B3 legacy deliver mirror changed");
    host_read(16'h0101, d); if (d !== 32'd0) bad("B3 legacy port-drop mirror changed");
    // B4 顶层 W1C 与读清
    host_write(16'h0104, 32'hFFFF_FFFF);
    host_read(16'h0104, d); if (d !== 32'd0) bad("B4 top-level W1C failed");
    host_write(16'h010F, 32'h1);
    host_read(16'h0107, d); if (d !== sb_rx_acc[31:0]) bad("B4 read-clear returned wrong value");
    host_read(16'h0107, d); if (d !== 32'd0) bad("B4 read-clear did not clear at top level");
    host_write(16'h010F, 32'h0);
    // B5 顶层复位清零
    reset = 1; repeat (7) @(negedge clk); reset = 0;
    waitc = 0;
    while (dut.init_done !== 1 && waitc < 26000) begin @(negedge clk); waitc = waitc + 1; end
    host_read(16'h0105, d); if (d !== 32'd0) bad("B5 RX_BYTE not cleared by reset");
    host_read(16'h0120, d); if (d !== 32'd0) bad("B5 histogram not cleared by reset");

    if (errors == 0)
      $display("T14 STATS PASS (unit: frame/byte/drop12/hist8+vl8/W1C/read-clear/freeze/reset; top: page RW, 1 real frame, bytes=%0d, scoreboard match)", sb_rx_bytes);
    else
      $display("T14 STATS FAIL (errors=%0d)", errors);
    $finish;
  end
  initial begin
    #60_000_000; $display("T14 STATS FAIL: timeout"); $finish;
  end
endmodule

module tb_t14_stats_regs_gmii;
  tb_t14_stats_regs #(.IF_MODE(1)) u_tb();
endmodule
