// §12.3 resource / port event bins.
`timescale 1 ns / 1 ps
module afdx_cov_rsrc (
  input wire clk, rst_sync,
  input wire [5:0] pmem_free,
  input wire pb_ev_sample, pb_ev_queue, pb_ev_ovf, pb_ev_drop
);
  integer n_free0, n_free1, n_free2, n_free_gt2;
  integer n_sample, n_queue, n_ovf, n_pdrop;
  initial begin
    n_free0 = 0; n_free1 = 0; n_free2 = 0; n_free_gt2 = 0;
    n_sample = 0; n_queue = 0; n_ovf = 0; n_pdrop = 0;
  end
  always @(posedge clk) begin
    if (!rst_sync) begin
      if (pmem_free == 6'd0) n_free0 = n_free0 + 1;
      else if (pmem_free == 6'd1) n_free1 = n_free1 + 1;
      else if (pmem_free == 6'd2) n_free2 = n_free2 + 1;
      else n_free_gt2 = n_free_gt2 + 1;
      if (pb_ev_sample) n_sample = n_sample + 1;
      if (pb_ev_queue) n_queue = n_queue + 1;
      if (pb_ev_ovf) n_ovf = n_ovf + 1;
      if (pb_ev_drop) n_pdrop = n_pdrop + 1;
    end
  end
endmodule
