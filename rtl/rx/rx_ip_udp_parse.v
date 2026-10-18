// =====================================================================
// rx_ip_udp_parse.v —— RX 后级解析与端口匹配（§7.12），v0.5.16 接入 AFDX_top
// 输入: RM forward 的描述符（DW=174：[173:163] payload_len，[162:159] blk，
//   [158:148] len，[15:0] UDP dport，其余同 rx_ic 头注释）。
// P1（IP Total Length = 28+L、UDP Length = 8+L、SN 位置、IP/UDP 校验）已由
//   mac_rx_if 在收字节时流式核对，坏帧根本不产生描述符（O-04/O-05，不先交付后
//   撤销），本模块不再回读 PMEM。
// P2 端口匹配（v0.5.16 定案，见设计书 §7.13 实现状态）:
//   port = RX_VL_CFG.w0.port_base[11:0]；须 < NUM_PORTS、端口表 w0.valid=1、
//   w0[18] dir=1（RX 端口）、w0[17:16] type ∈ {0 采样, 1 队列}、端口表
//   w1[15:0] == 帧 UDP 目的端口。SAP(type=2) 在 sap_enable 时交给顶层
//   管理面 descriptor handoff；关断时按 R_SAP 丢弃并计数；type=3 保留同 R_CFG。
// 输出: 每个输入恰好一个结果 {drop, reason, port, type, depth, blk, plen}，
//   out_vld 保持到 out_ready；drop=1 时由 rx_port_buf 归还块（不占 free_pipe）。
// 端口表字由顶层组合读出（port_w0/w1/w3 按 in_w0.port_base 索引）；BRAM 化
//   时改为 1 拍同步读 + 1 拍比较（§7.12 P2 两拍）。
// 时钟/复位: clk / rst_sync（§4.2）。
// =====================================================================
`timescale 1 ns / 1 ps
module rx_ip_udp_parse #(
  parameter integer DW        = 174,
  parameter integer NUM_PORTS = 256,
  parameter integer CHAIN_ENABLE = 0
) (
  input  wire          clk,
  input  wire          rst_sync,
  input  wire          in_vld,
  output wire          in_ready,
  input  wire [DW-1:0] in_desc,
  input  wire [31:0]   in_w0,          // RX_VL_CFG w0 of the frame's VL
  input  wire [31:0]   port_w0,        // port table w0 @ in_w0.port_base
  input  wire [31:0]   port_w1,        // port table w1 (UDP dst port [15:0])
  input  wire [31:0]   port_w3,        // port table w3 (queue depth [3:0])
  input  wire          sap_enable,     // CTL.SNMP_EN: enable SAP -> mgmt handoff
  output reg           out_vld,
  input  wire          out_ready,
  output reg           out_drop,
  output reg  [2:0]    out_reason,
  output reg  [7:0]    out_port,
  output reg  [1:0]    out_type,
  output reg  [3:0]    out_depth,
  output reg  [3:0]    out_blk,
  output reg  [10:0]   out_plen,
  output reg  [23:0]   out_ts,
  // Optional chain sideband; appended to keep legacy port order.
  input  wire [13:0]   in_app_len,
  input  wire [19:0]   in_blocks,
  input  wire [2:0]    in_block_count,
  output reg  [13:0]   out_app_len,
  output reg  [19:0]   out_blocks,
  output reg  [2:0]    out_block_count
);
  localparam [2:0] R_OK=3'd0, R_RANGE=3'd1, R_CFG=3'd2, R_DIR=3'd3,
                   R_DPORT=3'd4, R_SAP=3'd5;
  wire [11:0] pbase = in_w0[23:12];
  wire range_ok = (pbase < NUM_PORTS);
  reg [2:0] rsn;
  always @* begin
    if (!range_ok)                     rsn = R_RANGE;
    else if (!port_w0[31])             rsn = R_CFG;
    else if (!port_w0[18])             rsn = R_DIR;
    else if (port_w0[17:16] == 2'd2 && !sap_enable) rsn = R_SAP;
    else if (port_w0[17:16] == 2'd3)   rsn = R_CFG;
    else if (port_w1[15:0] != in_desc[15:0]) rsn = R_DPORT;
    else                               rsn = R_OK;
  end
  assign in_ready = !rst_sync && (!out_vld || out_ready);
  always @(posedge clk) begin
    if (rst_sync) begin
      out_vld <= 1'b0; out_drop <= 1'b0; out_reason <= R_OK; out_port <= 8'd0;
      out_type <= 2'd0; out_depth <= 4'd0; out_blk <= 4'd0; out_plen <= 11'd0;
      out_ts <= 24'd0;
    end else if (in_vld && in_ready) begin
      out_vld    <= 1'b1;
      out_drop   <= (rsn != R_OK);
      out_reason <= rsn;
      out_port   <= pbase[7:0];
      out_type   <= port_w0[17:16];
      out_depth  <= (port_w3[3:0] == 4'd0) ? 4'd1 : port_w3[3:0];
      out_blk    <= in_desc[162:159];
      out_plen   <= in_desc[173:163];
      out_ts     <= in_desc[147:124];
    end else if (out_ready) out_vld <= 1'b0;
  end
  // Both branches capture on the same ownership handshake as out_desc.
  // A stalled descriptor keeps all fields, including a drop's block ownership.
  generate
    if (CHAIN_ENABLE != 0) begin : g_chain_sideband
      always @(posedge clk) begin
        if (rst_sync) begin
          out_app_len <= 14'd0;
          out_blocks <= 20'd0;
          out_block_count <= 3'd0;
        end else if (in_vld && in_ready) begin
          out_app_len <= in_app_len;
          out_blocks <= in_blocks;
          out_block_count <= in_block_count;
        end
      end
    end else begin : g_legacy_sideband
      // No references to optional inputs: existing named instances may omit them.
      always @(posedge clk) begin
        if (rst_sync) begin
          out_app_len <= 14'd0;
          out_blocks <= 20'd0;
          out_block_count <= 3'd0;
        end else if (in_vld && in_ready) begin
          out_app_len <= {3'd0, in_desc[173:163]};
          out_blocks <= {16'd0, in_desc[162:159]};
          out_block_count <= 3'd1;
        end
      end
    end
  endgenerate
endmodule
