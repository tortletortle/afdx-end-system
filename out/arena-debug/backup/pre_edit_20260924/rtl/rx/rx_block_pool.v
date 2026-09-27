// RX PMEM 块池：6..11 专属 RX，12..15 公共借用。TX 0..5 由 tx_port_buf 管理。
// 同拍 A/B 首字节各拿不同的空闲块；归还仅对未来拍可见，避免别名。
`timescale 1 ns / 1 ps
module rx_block_pool (
  input wire clk, rst_sync,
  input wire alloc_a, alloc_b,
  output reg valid_a, valid_b,
  output reg [3:0] blk_a, blk_b,
  input wire free_a, free_b, free_pipe,
  input wire [3:0] free_id_a, free_id_b, free_id_pipe,
  // v0.5.16: rx_port_buf 释放口（主机 MSG_RD / 覆盖 / 队列满 / 解析丢弃），同拍至多 2 块
  input wire free_pb0, free_pb1,
  input wire [3:0] free_id_pb0, free_id_pb1,
  output reg [15:0] free_map,
  output reg [15:0] exhaust_cnt,
  output reg [15:0] borrow_cnt
);
  integer j;
  reg [15:0] free_next;
  reg [15:0] free_bits;
  always @* begin
    valid_a = 1'b0; valid_b = 1'b0;
    blk_a = 4'd0; blk_b = 4'd0;
    free_next = free_map;
    for (j=6; j<16; j=j+1) begin
      if (alloc_a && !valid_a && free_next[j]) begin
        valid_a = 1'b1; blk_a = j[3:0]; free_next[j] = 1'b0;
      end
      if (alloc_b && !valid_b && free_next[j]) begin
        valid_b = 1'b1; blk_b = j[3:0]; free_next[j] = 1'b0;
      end
    end
    free_bits = 16'd0;
    if (free_a && free_id_a >= 4'd6) free_bits[free_id_a] = 1'b1;
    if (free_b && free_id_b >= 4'd6) free_bits[free_id_b] = 1'b1;
    if (free_pipe && free_id_pipe >= 4'd6) free_bits[free_id_pipe] = 1'b1;
    if (free_pb0 && free_id_pb0 >= 4'd6) free_bits[free_id_pb0] = 1'b1;
    if (free_pb1 && free_id_pb1 >= 4'd6) free_bits[free_id_pb1] = 1'b1;
  end
  always @(posedge clk) begin
    if (rst_sync) begin
      free_map <= 16'hFFC0;
      exhaust_cnt <= 16'd0;
      borrow_cnt <= 16'd0;
    end else begin
      free_map <= free_next | free_bits;
      exhaust_cnt <= exhaust_cnt + {15'd0,(alloc_a && !valid_a)} +
                                   {15'd0,(alloc_b && !valid_b)};
      borrow_cnt <= borrow_cnt + {15'd0,(valid_a && blk_a >= 4'd12)} +
                                 {15'd0,(valid_b && blk_b >= 4'd12)};
    end
  end
endmodule
