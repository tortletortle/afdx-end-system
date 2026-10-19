// rx_block_pool_cons.sv -- formal wrapper (no bind; oss-cad yosys)
// Props: TX bits stay 0; alloc blk>=6; A/B distinct. CHAIN_ENABLE=0.

`timescale 1 ns / 1 ps

module pool_formal_top (
  input  wire        clk,
  input  wire        rst_sync,
  input  wire        alloc_a,
  input  wire        alloc_b,
  input  wire        free_a,
  input  wire        free_b,
  input  wire        free_pipe,
  input  wire        free_reasm,
  input  wire [3:0]  free_id_a,
  input  wire [3:0]  free_id_b,
  input  wire [3:0]  free_id_pipe,
  input  wire [3:0]  free_id_reasm,
  input  wire        free_pb0,
  input  wire        free_pb1,
  input  wire        free_spill,
  input  wire [3:0]  free_id_pb0,
  input  wire [3:0]  free_id_pb1,
  input  wire [3:0]  free_id_spill,
  input  wire        alloc_chain,
  input  wire [2:0]  alloc_chain_count,
  input  wire [15:0] free_chain_mask
);

  wire        valid_a, valid_b, valid_chain;
  wire [3:0]  blk_a, blk_b;
  wire [15:0] free_map;
  wire [15:0] exhaust_cnt, borrow_cnt;
  wire [19:0] chain_blocks;
  wire [2:0]  chain_count;

  rx_block_pool #(
    .CHAIN_ENABLE(0)
  ) dut (
    .clk(clk),
    .rst_sync(rst_sync),
    .alloc_a(alloc_a),
    .alloc_b(alloc_b),
    .valid_a(valid_a),
    .valid_b(valid_b),
    .blk_a(blk_a),
    .blk_b(blk_b),
    .free_a(free_a),
    .free_b(free_b),
    .free_pipe(free_pipe),
    .free_reasm(free_reasm),
    .free_id_a(free_id_a),
    .free_id_b(free_id_b),
    .free_id_pipe(free_id_pipe),
    .free_id_reasm(free_id_reasm),
    .free_pb0(free_pb0),
    .free_pb1(free_pb1),
    .free_spill(free_spill),
    .free_id_pb0(free_id_pb0),
    .free_id_pb1(free_id_pb1),
    .free_id_spill(free_id_spill),
    .free_map(free_map),
    .exhaust_cnt(exhaust_cnt),
    .borrow_cnt(borrow_cnt),
    .alloc_chain(alloc_chain),
    .alloc_chain_count(alloc_chain_count),
    .valid_chain(valid_chain),
    .chain_blocks(chain_blocks),
    .chain_count(chain_count),
    .free_chain_mask(free_chain_mask)
  );

  // Start under reset so free_map is initialized (16'hFFC0).
  always @(*) begin
    if ($initstate)
      assume (rst_sync == 1'b1);
  end

  always @(posedge clk) begin
    if (!rst_sync) begin
      assert (free_map[5:0] == 6'd0);
      if (valid_a)
        assert (blk_a >= 4'd6);
      if (valid_b)
        assert (blk_b >= 4'd6);
      if (valid_a && valid_b)
        assert (blk_a != blk_b);
    end
  end

endmodule
