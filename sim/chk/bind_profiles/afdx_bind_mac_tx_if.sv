// Binding declarations activate only when this named module is an elaborated sim top.
module afdx_bind_mac_tx_if;
bind mac_tx_if afdx_chk_a2 #(.IF_MODE(IF_MODE)) u_a2 (
  .clk(clk), .rst_sync(rst_sync),
  .tx_valid(tx_valid), .tx_ready(tx_ready)
);
endmodule
