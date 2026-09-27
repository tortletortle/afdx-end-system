// =====================================================================
// tx_rm.v —— 发送冗余管理：整帧按 net_mode 分发到 A/B 两路 mac_tx_if（§7.5）
// 设计书 v0.5.5：SMAC 第 6 字节的 A/B 差异已在 builder 内 mux 完成
//   （out_byte_a / out_byte_b，偏移 11 = 0x20/0x40，O-03），本模块退化为纯分发器：
//   * net_mode[1:0]: bit0 = A 网使能，bit1 = B 网使能（VL 表 w0[3:0] 低 2 位；0 视为 A）
//   * in_rdy = 各使能路 in_rdy 的与（两路 FIFO 同步推进，帧起始/结束天然对齐）
//   * 关闭的一路无任何活动（T07：net_mode=A 时 B 路 vld 恒 0）
//   * frame_done = 使能路 frame_done 全部到齐（A/B 共享 tx_pace，本应同拍；
//     若不同拍则用 pending 位对齐后合成 1 拍脉冲）
// 时钟/复位: clk(125 MHz) / rst_sync；握手 vld/rdy 与 pulse（§10）
// =====================================================================
`timescale 1 ns / 1 ps
module tx_rm (
  input  wire       clk,
  input  wire       rst_sync,
  input  wire [1:0] net_mode,       // 帧起始（in_sof 拍）采样，帧内保持
  input  wire [7:0] in_vl,          // 同上：本帧 VL（供 frame_done → tx_sn_gen.commit）
  // ---- 来自 builder ----
  input  wire       in_vld,
  input  wire [7:0] in_byte_a,
  input  wire [7:0] in_byte_b,
  input  wire       in_sof,
  input  wire       in_eof,
  output wire       in_rdy,
  // ---- 到 mac_tx_if A/B ----
  output wire       a_vld,
  output wire [7:0] a_byte,
  output wire       a_sof,
  output wire       a_eof,
  input  wire       a_rdy,
  output wire       b_vld,
  output wire [7:0] b_byte,
  output wire       b_sof,
  output wire       b_eof,
  input  wire       b_rdy,
  // ---- 帧结束合成 ----
  input  wire       a_start,
  input  wire       b_start,
  input  wire       a_done,
  input  wire       b_done,
  output wire       frame_start,    // 使能路的线上帧起始（A/B 共享节拍，同拍时只算 1 次）
  output reg        frame_done,
  output wire [7:0] done_vl,        // frame_done 拍有效
  output reg  [15:0] frames_a,
  output reg  [15:0] frames_b
);
  // 帧内 net_mode 锁存（sof 拍取输入）
  reg [1:0] nm_r;
  reg       in_frame;
  wire [1:0] nm_in  = (net_mode == 2'b00) ? 2'b01 : net_mode;
  wire [1:0] nm     = (in_sof & in_vld) ? nm_in : nm_r;
  wire en_a = nm[0];
  wire en_b = nm[1];

  always @(posedge clk) begin
    if (rst_sync) begin nm_r <= 2'b01; in_frame <= 1'b0; end
    else if (in_vld & in_rdy) begin
      if (in_sof) nm_r <= nm_in;
      in_frame <= ~in_eof;
    end
  end

  // 同步推进：两使能路都 ready 才收
  assign in_rdy = (~en_a | a_rdy) & (~en_b | b_rdy);
  wire   go     = in_vld & in_rdy;
  assign a_vld  = go & en_a;
  assign b_vld  = go & en_b;
  assign a_byte = in_byte_a;
  assign b_byte = in_byte_b;
  assign a_sof  = in_sof;  assign a_eof = in_eof;
  assign b_sof  = in_sof;  assign b_eof = in_eof;

  // frame_done 合成：按帧的 net_mode（发送端 FIFO 有深度，用 done 拍的期望位图）
  // 发送方向存在 FIFO 延迟，done 出现时本模块可能已在收下一帧，故按队列记录每帧的 nm。
  // done 事件计数——A/B 各自 pending 计数，队头帧所需的路都到齐时合成 1 拍 frame_done。
  reg [3:0] pend_a, pend_b;
  reg [1:0] exp_q [0:15];   // 帧序 FIFO：每帧期望的 en 位图（深 16，见 tx_vl_scheduler.ifq）
  reg [7:0] vl_q  [0:15];
  reg [3:0] eq_wr, eq_rd;
  wire [1:0] exp_head = exp_q[eq_rd];
  reg  [7:0] done_vl_r;
  assign done_vl = done_vl_r;
  assign frame_start = a_start | b_start;
  wire have_a = (pend_a != 4'd0) | ~exp_head[0];
  wire have_b = (pend_b != 4'd0) | ~exp_head[1];
  wire fire   = (eq_wr != eq_rd) & have_a & have_b;

  integer k;
  always @(posedge clk) begin
    if (rst_sync) begin
      pend_a <= 4'd0; pend_b <= 4'd0; eq_wr <= 4'd0; eq_rd <= 4'd0;
      frame_done <= 1'b0; frames_a <= 16'd0; frames_b <= 16'd0;
      done_vl_r <= 8'd0;
      for (k = 0; k < 16; k = k + 1) begin exp_q[k] <= 2'b00; vl_q[k] <= 8'd0; end
    end else begin
      frame_done <= fire;
      done_vl_r  <= vl_q[eq_rd];
      if (go & in_sof) begin exp_q[eq_wr] <= nm_in; vl_q[eq_wr] <= in_vl; eq_wr <= eq_wr + 4'd1; end
      if (fire) eq_rd <= eq_rd + 4'd1;
      pend_a <= pend_a + {3'b0, a_done} - {3'b0, (fire & exp_head[0])};
      pend_b <= pend_b + {3'b0, b_done} - {3'b0, (fire & exp_head[1])};
      if (a_done) frames_a <= frames_a + 16'd1;
      if (b_done) frames_b <= frames_b + 16'd1;
    end
  end
endmodule
