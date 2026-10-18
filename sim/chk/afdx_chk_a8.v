// §8.8 A8: no-backpressure accept-to-first-out_vld should be <= 15 cycles.
`timescale 1 ns / 1 ps
module afdx_chk_a8 (
  input wire clk, rst_sync,
  input wire in_vld, in_ready,
  input wire out_vld, out_ready
);
  integer errors, cyc, t0, lat;
  reg pend, saw_hold;
  initial begin errors = 0; pend = 0; end
  always @(posedge clk) begin
    if (rst_sync) begin
      cyc <= 0; pend <= 1'b0; saw_hold <= 1'b0;
    end else begin
      cyc <= cyc + 1;
      if (in_vld && in_ready) begin
        t0 = cyc;
        pend <= 1'b1;
        saw_hold <= 1'b0;
      end
      if (pend && out_vld && !out_ready) saw_hold <= 1'b1;
      if (pend && out_vld && out_ready) begin
        lat = cyc - t0;
        if (!saw_hold && lat > 15) begin
          if (errors < 8) $display("  [chk] A8 chain %0d cyc t=%0t", lat, $time);
          errors = errors + 1;
        end
        pend <= 1'b0;
      end
    end
  end
endmodule
