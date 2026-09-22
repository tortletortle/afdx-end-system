`timescale 1 ns / 1 ps
module vec_test;
  wire [31:0] a = {1'b0, 18'h0, 2'b00, 1'b0, 1'b0, 1'b0, 6'd16, 1'b0, 1'b0};
  wire [33:0] b = {1'b0, 18'h0, 2'b00, 1'b0, 1'b0, 1'b0, 6'd16, 1'b0, 1'b0};
  wire [31:0] c = {1'b0, 17'h0, 2'b00, 1'b0, 1'b0, 1'b0, 6'd16, 1'b0, 1'b0};
  initial begin
    $display("VEC_A_32bit=%h", a);
    $display("VEC_B_34bit_low32=%h", b[31:0]);
    $display("VEC_C_31bit=%h", c);
    $finish;
  end
endmodule
