// A9 adjacent-forward monitor using the RX descriptor timestamp coordinate.
`timescale 1 ns / 1 ps
module afdx_chk_a9 (
  input wire clk, rst_sync,
  input wire out_vld, out_ready, out_fwd, active_q,
  input wire [11:0] out_vl,
  input wire [7:0]  out_sn,
  input wire [23:0] out_ts,
  input wire [23:0] skew_q
);
  integer errors;
  reg [7:0] last_sn [0:4095];
  reg [23:0] last_ts [0:4095];
  reg seen [0:4095];
  reg [23:0] delta_u24, delta_abs_u24;
  integer i;

  initial begin
    errors = 0;
    delta_u24 = 24'd0;
    delta_abs_u24 = 24'd0;
    for (i = 0; i < 4096; i = i + 1) seen[i] = 1'b0;
  end

  always @(posedge clk) begin
    if (rst_sync) begin
      // Errors are cumulative across reset; reset clears only prior-sample state.
      for (i = 0; i < 4096; i = i + 1) seen[i] = 1'b0;
    end else if (out_vld && out_ready && out_fwd && active_q && (out_vl < 13'd4096)) begin
      if (seen[out_vl] && last_sn[out_vl] === out_sn) begin
        // Match rx_rm's 24-bit modulo subtraction and sign-bit absolute value.
        delta_u24 = out_ts - last_ts[out_vl];
        delta_abs_u24 = delta_u24[23] ? (~delta_u24 + 24'd1) : delta_u24;
        if (delta_abs_u24 <= skew_q) begin
          if (errors < 8)
            $display("  [chk] A9 duplicate forward vl=%0d sn=%0d delta=%0d skew=%0d t=%0t",
                     out_vl, out_sn, delta_abs_u24, skew_q, $time);
          errors = errors + 1;
        end
      end
      seen[out_vl] = 1'b1;
      last_sn[out_vl] = out_sn;
      last_ts[out_vl] = out_ts;
    end
  end
endmodule
