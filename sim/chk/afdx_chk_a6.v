// §8.8 A6: PMEM RX pool — no double alloc, no free of an already-free block.
`timescale 1 ns / 1 ps
module afdx_chk_a6 (
  input wire clk, rst_sync,
  input wire alloc_a, alloc_b, valid_a, valid_b,
  input wire [3:0] blk_a, blk_b,
  input wire free_a, free_b, free_pipe, free_reasm, free_pb0, free_pb1, free_spill,
  input wire [3:0] free_id_a, free_id_b, free_id_pipe, free_id_reasm,
  input wire [3:0] free_id_pb0, free_id_pb1, free_id_spill,
  input wire [15:0] free_map
);
  integer errors, n, id;
  initial errors = 0;

  function integer nfree;
    input [3:0] bid;
    begin
      nfree = 0;
      if (free_a && free_id_a == bid) nfree = nfree + 1;
      if (free_b && free_id_b == bid) nfree = nfree + 1;
      if (free_pipe && free_id_pipe == bid) nfree = nfree + 1;
      if (free_reasm && free_id_reasm == bid) nfree = nfree + 1;
      if (free_pb0 && free_id_pb0 == bid) nfree = nfree + 1;
      if (free_pb1 && free_id_pb1 == bid) nfree = nfree + 1;
      if (free_spill && free_id_spill == bid) nfree = nfree + 1;
    end
  endfunction

  always @(posedge clk) begin
    if (!rst_sync) begin
      if (valid_a && valid_b && (blk_a == blk_b)) begin
        if (errors < 8) $display("  [chk] A6 same-cycle alloc blk %0d t=%0t", blk_a, $time);
        errors = errors + 1;
      end
      for (id = 6; id < 16; id = id + 1) begin
        n = nfree(id[3:0]);
        if (n > 1) begin
          if (errors < 8) $display("  [chk] A6 two frees blk %0d t=%0t", id, $time);
          errors = errors + 1;
        end
        // Allocation reads old free_map; a return for an old-free block is stale.
        if (n >= 1 && free_map[id]) begin
          if (errors < 8) $display("  [chk] A6 free of free blk %0d t=%0t", id, $time);
          errors = errors + 1;
        end
      end
    end
  end
endmodule
