// §8.8 A7: table write while !CFG_MODE must raise wr_bad / ERR.ACC.
`timescale 1 ns / 1 ps
module afdx_chk_a7 (
  input wire clk, rst_sync,
  input wire we, wr_bad,
  input wire ctl_cfg,
  input wire tx_hit, rx_hit, port_hit, share_hit, hash_hit
);
  integer errors;
  wire table_wr = we && (tx_hit || rx_hit || port_hit || share_hit || hash_hit);
  initial errors = 0;
  always @(posedge clk) begin
    if (!rst_sync && table_wr && !ctl_cfg && !wr_bad) begin
      if (errors < 8) $display("  [chk] A7 table write with CFG_MODE=0 not flagged t=%0t", $time);
      errors = errors + 1;
    end
  end
endmodule
