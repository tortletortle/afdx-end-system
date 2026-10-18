// §12.3 IC reason × net bins (hand counts).
`timescale 1 ns / 1 ps
module afdx_cov_ic (
  input wire clk, rst_sync,
  input wire out_vld, out_ready,
  input wire [2:0] out_reason,
  input wire net_id
);
  integer n_ok, n_reset, n_lost1, n_first_any, n_first_fail, n_ooo, n_badvl;
  integer n_net_a, n_net_b;
  initial begin
    n_ok = 0; n_reset = 0; n_lost1 = 0; n_first_any = 0;
    n_first_fail = 0; n_ooo = 0; n_badvl = 0; n_net_a = 0; n_net_b = 0;
  end
  always @(posedge clk) begin
    if (!rst_sync && out_vld && out_ready) begin
      if (net_id) n_net_b = n_net_b + 1;
      else n_net_a = n_net_a + 1;
      case (out_reason)
        3'd0: n_ok = n_ok + 1;
        3'd1: n_reset = n_reset + 1;
        3'd2: n_lost1 = n_lost1 + 1;
        3'd3: n_first_any = n_first_any + 1;
        3'd4: n_first_fail = n_first_fail + 1;
        3'd5: n_ooo = n_ooo + 1;
        default: n_badvl = n_badvl + 1;
      endcase
    end
  end
  final begin
    integer fd;
    fd = $fopen("out/metrics/cover_ic.csv", "a");
    if (fd != 0) begin
      $fdisplay(fd, "%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",
                n_ok, n_reset, n_lost1, n_first_any, n_first_fail, n_ooo, n_badvl,
                n_net_a, n_net_b);
      $fclose(fd);
    end
  end
endmodule
