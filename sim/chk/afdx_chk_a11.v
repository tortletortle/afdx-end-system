// §8.8 A11: pipe drop strobes bump DROP_CNT. Check the previous cycle (no #1).
`timescale 1 ns / 1 ps
module afdx_chk_a11 (
  input wire clk, rst_sync,
  input wire flt_free, ic_rej_fire, rm_dup_fire, pb_ev_drop,
  input wire [31:0] flt_drop_total
);
  integer errors, add;
  reg rst_d;
  reg [31:0] want;
  initial begin errors = 0; want = 0; rst_d = 1'b1; end
  always @(posedge clk) begin
    add = (flt_free ? 1 : 0) + (ic_rej_fire ? 1 : 0) + (rm_dup_fire ? 1 : 0) +
          (pb_ev_drop ? 1 : 0);
    if (rst_sync) begin
      want <= 32'd0;
      rst_d <= 1'b1;
    end else begin
      if (!rst_d && (flt_drop_total !== want)) begin
        if (errors < 8)
          $display("  [chk] A11 DROP_CNT %0d want %0d t=%0t", flt_drop_total, want, $time);
        errors = errors + 1;
        want <= flt_drop_total + add;
      end else
        want <= want + add;
      rst_d <= 1'b0;
    end
  end
endmodule
