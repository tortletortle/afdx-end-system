// =====================================================================
// rx_flt.v —— RX 语义过滤（§7.8 S2）：lookup 结果 + RX_VL_CFG 表项判决
// 顶层顺序: mac_rx_if(完帧校验) -> rx_vl_lookup -> rx_flt -> (IC/RM/端口)。
// §7.8 S1 的 DMAC 前缀/Type/version/IHL/protocol/长度口径已由 mac_rx_if
// 流式完成（O-04/O-05）；本模块只按描述符与 RX_VL_CFG w0/w1 判决，不回读
// PMEM、不算 CRC、不触碰 PSN/RM：
//   in_hit=0 或 idx 越界或 w0.valid=0 -> F_UNCONF
//   w1.expect_vl[15:0] != desc.vlid   -> F_VLID（哈希项与配置表不一致）
//   来源网不在 w0.net_mode 使能位内    -> F_NET（{B,A}，2'b00 视为仅 A）
//   desc.len > w0.lmax                -> F_LMAX（两者均含 FCS，O-01）
// w0/w1 由父层以 in_vl 组合读出（与顶层 rx_cfg_mem 既有读口同款），输入
// 握手拍判决并锁存。拒绝只发生在描述符层：父层负责释放 PMEM 块并按
// unconf/lmax 计数。每帧 1 拍判决 + 输出保持（out_ready）。
// =====================================================================
`timescale 1 ns / 1 ps
module rx_flt #(
  parameter integer NUM_RX_VL = 4096
) (
  input  wire         clk,
  input  wire         rst_sync,
  input  wire         init_we,     // 初始化扫描期间不受理、清在途
  input  wire         in_vld,
  output wire         in_ready,
  input  wire         in_hit,
  input  wire [11:0]  in_vl,
  input  wire [162:0] in_desc,
  input  wire [31:0]  in_w0,       // RX_VL_CFG[2*in_vl]，父层组合读
  input  wire [31:0]  in_w1,       // RX_VL_CFG[2*in_vl+1]（expect_vl）
  output reg          out_vld,     // 保持至 out_ready
  input  wire         out_ready,
  output reg          out_pass,
  output reg  [2:0]   out_reason,  // 0 PASS,1 UNCONF,2 NET,3 LMAX,4 VLID
  output reg  [11:0]  out_vl,
  output reg  [162:0] out_desc
);
  localparam [2:0] F_PASS=3'd0, F_UNCONF=3'd1, F_NET=3'd2, F_LMAX=3'd3,
                   F_VLID=3'd4;
  reg busy;
  assign in_ready = !rst_sync && !init_we && !busy;
  wire [10:0] len_in  = in_desc[158:148];
  wire [15:0] vlid_in = in_desc[123:108];
  wire        net_in  = in_desc[99];
  wire [1:0]  nm      = (in_w0[29:28] == 2'b00) ? 2'b01 : in_w0[29:28];
  wire unconf   = !in_hit || ({20'd0,in_vl} >= NUM_RX_VL) || !in_w0[31];
  wire vlid_bad = (in_w1[15:0] != vlid_in);
  wire net_bad  = !(net_in ? nm[1] : nm[0]);
  wire len_bad  = ({1'b0,len_in} > {1'b0,in_w0[11:0]});
  always @(posedge clk) begin
    if (rst_sync || init_we) begin
      busy <= 1'b0; out_vld <= 1'b0; out_pass <= 1'b0;
      out_reason <= F_PASS; out_vl <= 12'd0; out_desc <= 163'd0;
    end else if (!busy) begin
      if (in_vld && in_ready) begin
        out_desc <= in_desc; out_vl <= in_vl;
        out_pass <= !(unconf || vlid_bad || net_bad || len_bad);
        out_reason <= unconf   ? F_UNCONF :
                      vlid_bad ? F_VLID :
                      net_bad  ? F_NET :
                      len_bad  ? F_LMAX : F_PASS;
        out_vld <= 1'b1; busy <= 1'b1;
      end
    end else if (out_ready) begin
      out_vld <= 1'b0; busy <= 1'b0;
    end
  end
endmodule
