// §8.8 A10: rejected IC frames must not commit PSN (sweep/debug writes excluded).
`timescale 1 ns / 1 ps
module afdx_chk_a10 (
  input wire clk, rst_sync,
  input wire mem_we, sweep_we, debug_we, accept_q,
  input wire [1:0] state
);
  localparam [1:0] ST_WRITE = 2'd2;
  integer errors;
  initial errors = 0;
  always @(posedge clk) begin
    if (!rst_sync && mem_we && !sweep_we && !debug_we && !accept_q && (state == ST_WRITE)) begin
      if (errors < 8) $display("  [chk] A10 PSN write on reject t=%0t", $time);
      errors = errors + 1;
    end
  end
endmodule
