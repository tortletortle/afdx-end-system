// =====================================================================
// rst_sync.v —— 同步复位（设计书 §4.2）
// 模板 reset 高有效（可异步释放）→ 打 3 拍生成 rst_sync，防抖兼容 BFM
// 仅 rst_sync 允许出现在 always 的 if 条件里（§10 复位约定）
// =====================================================================
`timescale 1 ns / 1 ps
module rst_sync (
  input  wire clk,
  input  wire reset,      // 高有效
  output wire rst_sync
);
  reg [2:0] r;
  always @(posedge clk)
    r <= {r[1:0], reset};
  assign rst_sync = r[2];
endmodule
