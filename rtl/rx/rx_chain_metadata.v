// RX payload-chain ownership side table. Payload links are independent of
// rx_port_buf.b_nxt, which only sequences messages. IDs 0..5 never enter masks.
// Register at parser input ownership handoff; PB/SAP head returns arrive later.
// Disjoint register/release may coexist. Releases win an overlapping register,
// which is outside the allocator's next-cycle reuse contract.
`timescale 1 ns / 1 ps
module rx_chain_metadata (
  input  wire        clk,
  input  wire        rst_sync,
  input  wire        register_valid,
  input  wire [3:0]  register_head,
  input  wire [19:0] register_blocks,
  input  wire [2:0]  register_count,
  input  wire        release0_valid,
  input  wire [3:0]  release0_id,
  input  wire        release1_valid,
  input  wire [3:0]  release1_id,
  input  wire        release2_valid,
  input  wire [3:0]  release2_id,
  output wire [15:0] free_mask,
  input  wire [3:0]  lookup_block,
  output wire [31:0] lookup_word
);
  reg [15:0] head_mask [0:15];
  reg [15:0] member_valid;
  reg [15:0] member_has_next;
  reg [3:0]  member_next [0:15];

  // Fixed ranges avoid an out-of-bounds slice when the frontend expands
  // the last member's unselected next-link expression (index five).
  function [3:0] block_at;
    input [19:0] blocks;
    input integer index;
    begin
      case (index)
        0: block_at = blocks[3:0];
        1: block_at = blocks[7:4];
        2: block_at = blocks[11:8];
        3: block_at = blocks[15:12];
        4: block_at = blocks[19:16];
        default: block_at = 4'bxxxx;
      endcase
    end
  endfunction

  // A recorded head returns its complete sparse chain. Unrecorded heads return
  // exactly themselves; the pool retains its existing idempotent free behavior.
  wire [15:0] release0_mask = (release0_valid && release0_id >= 4'd6)
    ? ((head_mask[release0_id] != 16'd0) ? head_mask[release0_id]
                                         : (16'h0001 << release0_id)) : 16'd0;
  wire [15:0] release1_mask = (release1_valid && release1_id >= 4'd6)
    ? ((head_mask[release1_id] != 16'd0) ? head_mask[release1_id]
                                         : (16'h0001 << release1_id)) : 16'd0;
  wire [15:0] release2_mask = (release2_valid && release2_id >= 4'd6)
    ? ((head_mask[release2_id] != 16'd0) ? head_mask[release2_id]
                                         : (16'h0001 << release2_id)) : 16'd0;
  assign free_mask = rst_sync ? 16'd0
                    : ((release0_mask | release1_mask | release2_mask) & 16'hFFC0);

  // The host aperture is a read-only view and has no ownership side effects.
  assign lookup_word = (!rst_sync && member_valid[lookup_block])
    ? {26'd0, 1'b1, member_has_next[lookup_block], member_next[lookup_block]}
    : 32'd0;

  reg [15:0] register_mask;
  reg        register_ok;
  reg [3:0]  register_id;
  integer ri;
  always @* begin
    register_mask = 16'd0;
    register_id = 4'd0;
    register_ok = (register_count >= 3'd1 && register_count <= 3'd5
                   && register_head >= 4'd6
                   && register_blocks[3:0] == register_head);
    for (ri = 0; ri < 5; ri = ri + 1) begin
      if (ri < register_count) begin
        register_id = block_at(register_blocks, ri);
        // Reject the whole registration on malformed or already-owned IDs.
        if (register_id < 4'd6 || register_mask[register_id]
            || member_valid[register_id]) register_ok = 1'b0;
        register_mask = register_mask | (16'h0001 << register_id);
      end
    end
    register_mask = register_mask & 16'hFFC0;
  end

  integer si;
  always @(posedge clk) begin
    if (rst_sync) begin
      member_valid <= 16'd0;
      member_has_next <= 16'd0;
      for (si = 0; si < 16; si = si + 1) begin
        head_mask[si] <= 16'd0;
        member_next[si] <= 4'd0;
      end
    end else begin
      // All members disappear at the edge that returns the mask to the pool.
      for (si = 0; si < 16; si = si + 1) begin
        if (free_mask[si]) begin
          head_mask[si] <= 16'd0;
          member_valid[si] <= 1'b0;
          member_has_next[si] <= 1'b0;
          member_next[si] <= 4'd0;
        end
      end
      if (register_valid && register_ok && (register_mask & free_mask) == 16'd0) begin
        head_mask[register_head] <= register_mask;
        for (si = 0; si < 5; si = si + 1) begin
          if (si < register_count) begin
            member_valid[block_at(register_blocks, si)] <= 1'b1;
            member_has_next[block_at(register_blocks, si)] <= (si + 1 < register_count);
            member_next[block_at(register_blocks, si)] <= (si + 1 < register_count)
              ? block_at(register_blocks, si+1) : 4'd0;
          end
        end
      end
    end
  end
endmodule
