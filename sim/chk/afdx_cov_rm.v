// §12.3 RM forward / dup / skew bins (hand counts).
`timescale 1 ns / 1 ps
module afdx_cov_rm (
  input wire clk, rst_sync,
  input wire out_vld, out_ready, out_fwd, out_skew, active_q
);
  integer n_fwd, n_dup, n_skew, n_bypass;
  initial begin n_fwd = 0; n_dup = 0; n_skew = 0; n_bypass = 0; end
  always @(posedge clk) begin
    if (!rst_sync && out_vld && out_ready) begin
      if (!active_q) n_bypass = n_bypass + 1;
      else if (out_fwd) n_fwd = n_fwd + 1;
      else n_dup = n_dup + 1;
      if (out_skew) n_skew = n_skew + 1;
    end
  end
  final begin
    integer fd;
    fd = $fopen("out/metrics/cover_rm.csv", "a");
    if (fd != 0) begin
      $fdisplay(fd, "%0d,%0d,%0d,%0d", n_fwd, n_dup, n_skew, n_bypass);
      $fclose(fd);
    end
  end
endmodule
