// Binding declarations activate only when this named module is an elaborated sim top.
module afdx_bind_full;
// §8.8 bind (O-16). Compiled after RTL. Counters only — no $error / FAIL text.
bind rx_block_pool afdx_chk_a6 u_a6 (
  .clk(clk), .rst_sync(rst_sync),
  .alloc_a(alloc_a), .alloc_b(alloc_b),
  .valid_a(valid_a), .valid_b(valid_b), .blk_a(blk_a), .blk_b(blk_b),
  .free_a(free_a), .free_b(free_b), .free_pipe(free_pipe),
  .free_reasm(free_reasm), .free_id_reasm(free_id_reasm),
  .free_pb0(free_pb0), .free_pb1(free_pb1), .free_spill(free_spill),
  .free_id_a(free_id_a), .free_id_b(free_id_b), .free_id_pipe(free_id_pipe),
  .free_id_pb0(free_id_pb0), .free_id_pb1(free_id_pb1), .free_id_spill(free_id_spill),
  .free_map(free_map)
);

bind AFDX_top afdx_chk_a7 u_a7 (
  .clk(clk), .rst_sync(rst_sync),
  .we(we), .wr_bad(wr_bad), .ctl_cfg(ctl_r[13]),
  .tx_hit(tx_hit), .rx_hit(rx_hit), .port_hit(port_hit),
  .share_hit(share_hit), .hash_hit(hash_hit)
);

bind rx_rm afdx_chk_a9 u_a9 (
  .clk(clk), .rst_sync(rst_sync),
  .out_vld(out_vld), .out_ready(out_ready), .out_fwd(out_fwd),
  .active_q(active_q), .out_vl(out_vl),
  .out_sn(out_desc[107:100]), .out_ts(out_desc[147:124]), .skew_q(skew_q)
);

bind mac_tx_if afdx_chk_a2 #(.IF_MODE(IF_MODE)) u_a2 (
  .clk(clk), .rst_sync(rst_sync),
  .tx_valid(tx_valid), .tx_ready(tx_ready)
);

bind rx_ic afdx_chk_a8 u_a8_ic (
  .clk(clk), .rst_sync(rst_sync),
  .in_vld(in_vld), .in_ready(in_ready),
  .out_vld(out_vld), .out_ready(out_ready)
);

bind rx_rm afdx_chk_a8 u_a8_rm (
  .clk(clk), .rst_sync(rst_sync),
  .in_vld(in_vld), .in_ready(in_ready),
  .out_vld(out_vld), .out_ready(out_ready)
);

bind rx_ic afdx_chk_a10 u_a10 (
  .clk(clk), .rst_sync(rst_sync),
  .mem_we(mem_we), .sweep_we(sweep_we), .debug_we(debug_we),
  .accept_q(accept_q), .state(state)
);

bind AFDX_top afdx_chk_a11 u_a11 (
  .clk(clk), .rst_sync(rst_sync),
  .flt_free(flt_free), .ic_rej_fire(ic_rej_fire),
  .rm_dup_fire(rm_dup_fire), .pb_ev_drop(pb_ev_drop),
  .flt_drop_total(flt_drop_total)
);

bind rx_ic afdx_cov_ic u_cov_ic (
  .clk(clk), .rst_sync(rst_sync),
  .out_vld(out_vld), .out_ready(out_ready),
  .out_reason(out_reason), .net_id(out_desc[99])
);

bind rx_rm afdx_cov_rm u_cov_rm (
  .clk(clk), .rst_sync(rst_sync),
  .out_vld(out_vld), .out_ready(out_ready),
  .out_fwd(out_fwd), .out_skew(out_skew), .active_q(active_q)
);
endmodule
