// =====================================================================
// sync_fifo.v —— 同步 FIFO（寄存器阵列，深度 ≤ 32）
// 设计书 §7.6（两路 32×8 skid FIFO 由本模块例化，W=8/D=32）、§10
// =====================================================================
`timescale 1 ns / 1 ps
module sync_fifo #(
  parameter integer W = 8,
  parameter integer D = 32
) (
  input  wire         clk,
  input  wire         rst,
  input  wire         wr_en,
  input  wire [W-1:0] wr_data,
  input  wire         rd_en,
  output reg  [W-1:0] rd_data,
  output wire         full,
  output wire         empty
);
  // D 必为 2 的幂（2/4/8/16/32）
  localparam integer AW = (D <= 2) ? 1 : (D <= 4) ? 2 : (D <= 8) ? 3 : (D <= 16) ? 4 : 5;
  // Small flop-backed store: a flat vector avoids the eLinx $mem backend's
  // duplicate RD_DATA/RD_DATA_B drivers on the registered FIFO output.
  reg [W*D-1:0] mem_bits;
  reg [AW:0]  wr_ptr, rd_ptr, cnt;
  wire wr = wr_en & ~full;
  wire rd = rd_en & ~empty;
  wire [AW:0] inc = {{(AW){1'b0}}, 1'b1};   // 1（声明上下文无三元歧义）

  always @(posedge clk) begin
    if (rst) begin
      wr_ptr <= {(AW+1){1'b0}};
      rd_ptr <= {(AW+1){1'b0}};
      cnt    <= {(AW+1){1'b0}};
    end else begin
      if (wr) begin
        mem_bits[wr_ptr[AW-1:0]*W +: W] <= wr_data;
        wr_ptr              <= wr_ptr + 1'b1;
      end
      if (rd) begin
        rd_data <= mem_bits[rd_ptr[AW-1:0]*W +: W];
        rd_ptr  <= rd_ptr + 1'b1;
      end
      cnt <= cnt + (wr ? inc : {(AW+1){1'b0}})
                - (rd ? inc : {(AW+1){1'b0}});
    end
  end
  assign full  = (cnt == D);
  assign empty = (cnt == 0);
endmodule
