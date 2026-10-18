// Binding declarations activate only when this named module is an elaborated sim top.
module afdx_bind_rx_ic;
bind rx_ic afdx_chk_a8 u_a8_ic (
  .clk(clk), .rst_sync(rst_sync),
  .in_vld(in_vld), .in_ready(in_ready),
  .out_vld(out_vld), .out_ready(out_ready)
);


bind rx_ic afdx_chk_a10 u_a10 (
  .clk(clk), .rst_sync(rst_sync),
  .mem_we(mem_we), .sweep_we(sweep_we), .debug_we(debug_we),
  .accept_q(accept_q), .state(state)
);


bind rx_ic afdx_cov_ic u_cov_ic (
  .clk(clk), .rst_sync(rst_sync),
  .out_vld(out_vld), .out_ready(out_ready),
  .out_reason(out_reason), .net_id(out_desc[99])
);
endmodule
