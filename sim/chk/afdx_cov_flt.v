// §12.3 FLT reason bins: PASS/UNCONF/NET/LMAX/VLID.
`timescale 1 ns / 1 ps
module afdx_cov_flt (
  input wire clk, rst_sync,
  input wire out_vld, out_ready, out_pass,
  input wire [2:0] out_reason
);
  integer n_pass, n_unconf, n_net, n_lmax, n_vlid;
  initial begin n_pass = 0; n_unconf = 0; n_net = 0; n_lmax = 0; n_vlid = 0; end
  always @(posedge clk) begin
    if (!rst_sync && out_vld && out_ready) begin
      if (out_pass) n_pass = n_pass + 1;
      case (out_reason)
        3'd1: n_unconf = n_unconf + 1;
        3'd2: n_net = n_net + 1;
        3'd3: n_lmax = n_lmax + 1;
        3'd4: n_vlid = n_vlid + 1;
        default: ;
      endcase
    end
  end
endmodule
