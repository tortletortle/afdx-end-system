`timescale 1 ns / 1 ps
// Checks identical reset assertion and release, including a second pulse.
module tb_reset_copy;
  reg clk = 1'b0;
  reg reset = 1'b1;
  always #4 clk = ~clk;
  wire rst_global, rst_rxpb;
  rst_sync dut (.clk(clk), .reset(reset),
                .rst_sync(rst_global), .rst_rxpb(rst_rxpb));
  integer cycles = 0;
  integer mismatches = 0;
  always @(negedge clk) begin
    cycles = cycles + 1;
    if (cycles > 3 && rst_global !== rst_rxpb) begin
      $display("MISMATCH cycle=%0d global=%b rxpb=%b", cycles, rst_global, rst_rxpb);
      mismatches = mismatches + 1;
    end
  end
  initial begin
    repeat (7) @(negedge clk);
    if (rst_global !== 1'b1 || rst_rxpb !== 1'b1) $fatal(1, "reset not asserted");
    reset = 1'b0;
    repeat (7) @(negedge clk);
    if (rst_global !== 1'b0 || rst_rxpb !== 1'b0) $fatal(1, "reset not released");
    reset = 1'b1;
    repeat (6) @(negedge clk);
    if (rst_global !== 1'b1 || rst_rxpb !== 1'b1) $fatal(1, "second assertion failed");
    reset = 1'b0;
    repeat (7) @(negedge clk);
    if (rst_global !== 1'b0 || rst_rxpb !== 1'b0) $fatal(1, "second release failed");
    if (mismatches != 0) $fatal(1, "reset copy is not cycle identical");
    $display("PASS reset copy identity cycles=%0d", cycles);
    $finish;
  end
endmodule
