// T25g: IF_MODE=1 (GMII) 变体，判据与 T25 相同。
`timescale 1 ns / 1 ps
module tb_t25g_mgmt_tftp_tx #(parameter integer IF_MODE=1);
  tb_t25_mgmt_tftp_tx #(.IF_MODE(IF_MODE)) u_core();
endmodule
