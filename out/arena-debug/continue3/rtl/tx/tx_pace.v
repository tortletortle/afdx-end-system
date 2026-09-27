// =====================================================================
// tx_pace.v —— 发送字节节拍（§7.5/§7.6：A/B 两个 mac_tx_if 共享同一节拍，
//   使两网帧起始/结束天然同拍对齐，frame_done 无抖动）
// IF_MODE=0：每 BYTE_SLOT_CYC 拍出一拍 pace_en；IF_MODE=1（GMII）：恒 1。
// 时钟/复位: clk(125 MHz) / rst_sync
// =====================================================================
`timescale 1 ns / 1 ps
module tx_pace #(
  parameter integer IF_MODE       = 0,
  parameter integer BYTE_SLOT_CYC = 10
) (
  input  wire clk,
  input  wire rst_sync,
  output wire pace_en
);
  reg [7:0] cnt;
  always @(posedge clk) begin
    if (rst_sync)                            cnt <= 8'd0;
    else if (cnt == BYTE_SLOT_CYC[7:0] - 8'd1) cnt <= 8'd0;
    else                                     cnt <= cnt + 8'd1;
  end
  assign pace_en = (IF_MODE != 0) ? 1'b1 : (cnt == BYTE_SLOT_CYC[7:0] - 8'd1);
endmodule
