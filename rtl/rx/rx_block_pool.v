// RX PMEM 块池：6..11 专属 RX，12..15 公共借用。TX 0..5 由 tx_port_buf 管理。
// 同拍 A/B 首字节各拿不同的空闲块；归还仅对未来拍可见，避免别名。
`timescale 1 ns / 1 ps
module rx_block_pool #(
  parameter integer CHAIN_ENABLE = 0
) (
  input wire clk, rst_sync,
  input wire alloc_a, alloc_b,
  output reg valid_a, valid_b,
  output reg [3:0] blk_a, blk_b,
  input wire free_a, free_b, free_pipe, free_reasm,
  input wire [3:0] free_id_a, free_id_b, free_id_pipe, free_id_reasm,
  // v0.5.16: rx_port_buf 释放口（主机 MSG_RD / 覆盖 / 队列满 / 解析丢弃），同拍至多 2 块
  input wire free_pb0, free_pb1, free_spill,
  input wire [3:0] free_id_pb0, free_id_pb1, free_id_spill,
  output reg [15:0] free_map,
  output reg [15:0] exhaust_cnt,
  output reg [15:0] borrow_cnt,
  // Optional bounded message chain; slot i occupies bits [4*i +: 4].
  input wire alloc_chain,
  input wire [2:0] alloc_chain_count,
  output reg valid_chain,
  output reg [19:0] chain_blocks,
  output reg [2:0] chain_count,
  // Returns use the existing OR semantics and are visible next cycle only.
  input wire [15:0] free_chain_mask
);
  integer j;
  reg [15:0] free_next;
  reg [15:0] free_bits;
  reg [15:0] chain_next;
  reg [2:0] chain_borrow_inc;
  reg chain_exhaust_inc;
  wire [15:0] chain_free_bits;

  generate
    if (CHAIN_ENABLE != 0) begin : g_chain_enabled
      integer k;
      reg [15:0] candidate_map;
      reg [19:0] candidate_blocks;
      reg [2:0] candidate_count;
      reg [2:0] candidate_borrows;
      assign chain_free_bits = free_chain_mask & 16'hFFC0;
      always @* begin
        // free_next contains old free_map after the A/B candidates.
        chain_next = free_next;
        valid_chain = 1'b0;
        chain_blocks = 20'd0;
        chain_count = 3'd0;
        chain_borrow_inc = 3'd0;
        chain_exhaust_inc = 1'b0;
        candidate_map = free_next;
        candidate_blocks = 20'd0;
        candidate_count = 3'd0;
        candidate_borrows = 3'd0;
        if (alloc_chain) begin
          chain_exhaust_inc = 1'b1;
          if (alloc_chain_count >= 3'd1 && alloc_chain_count <= 3'd5) begin
            for (k=6; k<16; k=k+1) begin
              if (candidate_map[k] && candidate_count < alloc_chain_count) begin
                candidate_blocks[4*candidate_count +: 4] = k[3:0];
                candidate_count = candidate_count + 3'd1;
                candidate_map[k] = 1'b0;
                if (k >= 12) candidate_borrows = candidate_borrows + 3'd1;
              end
            end
            // Commit all requested IDs together; failure retains A/B only.
            if (candidate_count == alloc_chain_count) begin
              chain_next = candidate_map;
              valid_chain = 1'b1;
              chain_blocks = candidate_blocks;
              chain_count = candidate_count;
              chain_borrow_inc = candidate_borrows;
              chain_exhaust_inc = 1'b0;
            end
          end
        end
      end
    end else begin : g_chain_disabled
      // No optional input is referenced in the default elaborated branch.
      assign chain_free_bits = 16'd0;
      always @* begin
        chain_next = free_next;
        valid_chain = 1'b0;
        chain_blocks = 20'd0;
        chain_count = 3'd0;
        chain_borrow_inc = 3'd0;
        chain_exhaust_inc = 1'b0;
      end
    end
  endgenerate
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
    free_bits = chain_free_bits;
    if (free_a && free_id_a >= 4'd6) free_bits[free_id_a] = 1'b1;
    if (free_b && free_id_b >= 4'd6) free_bits[free_id_b] = 1'b1;
    if (free_pipe && free_id_pipe >= 4'd6) free_bits[free_id_pipe] = 1'b1;
    if (free_reasm && free_id_reasm >= 4'd6) free_bits[free_id_reasm] = 1'b1;
    if (free_pb0 && free_id_pb0 >= 4'd6) free_bits[free_id_pb0] = 1'b1;
    if (free_pb1 && free_id_pb1 >= 4'd6) free_bits[free_id_pb1] = 1'b1;
    if (free_spill && free_id_spill >= 4'd6) free_bits[free_id_spill] = 1'b1;
  end
  always @(posedge clk) begin
    if (rst_sync) begin
      free_map <= 16'hFFC0;
      exhaust_cnt <= 16'd0;
      borrow_cnt <= 16'd0;
    end else begin
      free_map <= chain_next | free_bits;
      exhaust_cnt <= exhaust_cnt + {15'd0,(alloc_a && !valid_a)} +
                                   {15'd0,(alloc_b && !valid_b)} +
                                   {15'd0,chain_exhaust_inc};
      borrow_cnt <= borrow_cnt + {15'd0,(valid_a && blk_a >= 4'd12)} +
                                 {15'd0,(valid_b && blk_b >= 4'd12)} +
                                 {13'd0,chain_borrow_inc};
    end
  end
endmodule
