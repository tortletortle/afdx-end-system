// §8.8 A2: IF_MODE=0 only — tx_ready=0 implies tx_valid=0 (MAC envelope, not shared RX pin).
`timescale 1 ns / 1 ps
module afdx_chk_a2 #(
  parameter integer IF_MODE = 0
) (
  input wire clk, rst_sync,
  input wire tx_valid, tx_ready
);
  integer errors;
  initial errors = 0;
  always @(posedge clk) begin
    if (!rst_sync && (IF_MODE == 0) && tx_valid && !tx_ready) begin
      if (errors < 8) $display("  [chk] A2 tx_valid while tx_ready=0 t=%0t", $time);
      errors = errors + 1;
    end
  end
endmodule
