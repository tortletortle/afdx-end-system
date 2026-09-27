// =====================================================================
// rst_sync.v —— 同步复位（设计书 §4.2）
// 模板 reset 高有效（可异步释放）→ 打 3 拍生成 rst_sync，防抖兼容 BFM
// 仅 rst_sync 允许出现在 always 的 if 条件里（§10 复位约定）
// =====================================================================
`timescale 1 ns / 1 ps
module rst_sync (
  input  wire clk,
  input  wire reset,      // 高有效
  output wire rst_sync,
  output wire rst_rxpb
);
  reg [2:0] r;
  // Dedicated RX port-buffer reset copy. Both flops sample r[1] on the
  // same edge; unlike an extra pipeline stage, this adds no reset latency.
  // Preserve the copy so synthesis does not merge it with r[2].
  (* preserve *) reg r_rxpb;
  always @(posedge clk) begin
    r <= {r[1:0], reset};
    r_rxpb <= r[1];
  end
  assign rst_sync = r[2];
  assign rst_rxpb = r_rxpb;
endmodule
