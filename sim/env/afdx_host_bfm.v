// Host register/PMEM master for the ES system TB (design book §12.1 host_bfm).
// Tasks are called hierarchically from the scenario (u_host.wr / u_host.rd).
`timescale 1 ns / 1 ps
module afdx_host_bfm (
  input  wire        clk,
  output reg         cs,
  output reg         we,
  output reg  [15:0] addr,
  output reg  [31:0] wdata,
  input  wire [31:0] rdata,
  input  wire        ack
);
  integer errors;
  initial begin cs = 0; we = 0; addr = 16'd0; wdata = 32'd0; errors = 0; end

  task bad;
    input [8*96-1:0] reason;
    begin
      if (errors < 25) $display("  [err] host t=%0t: %0s", $time, reason);
      errors = errors + 1;
    end
  endtask

  task wr;
    input [15:0] a;
    input [31:0] d;
    begin
      @(negedge clk);
      cs = 1'b1; we = 1'b1; addr = a; wdata = d;
      @(negedge clk);
      if (ack !== 1'b1) bad("write ACK missing");
      cs = 1'b0; we = 1'b0;
    end
  endtask

  // Hold a write request across several clocks and report an early ACK.
  // This lets a focused top-level TB prove that a resource stall suppresses
  // ACK while CS/WE/address/data stay asserted; legacy wr() remains unchanged.
  task stall_probe_write;
    input [15:0] a;
    input [31:0] d;
    input integer cycles;
    output integer no_early_ack;
    integer i;
    begin
      no_early_ack = 1;
      @(negedge clk);
      cs = 1'b1; we = 1'b1; addr = a; wdata = d;
      for (i=0;i<cycles;i=i+1) begin
        @(negedge clk);
        if (ack !== 1'b0) no_early_ack = 0;
        if (cs !== 1'b1 || we !== 1'b1 || addr !== a || wdata !== d)
          no_early_ack = 0;
      end
      cs = 1'b0; we = 1'b0;
    end
  endtask

  task rd;
    input  [15:0] a;
    output [31:0] d;
    begin
      @(negedge clk);
      cs = 1'b1; we = 1'b0; addr = a;
      @(negedge clk);
      if (ack !== 1'b1) bad("read ACK missing");
      d = rdata;
      cs = 1'b0;
    end
  endtask

  task wr_burst_word;
    input [15:0] a;
    input [31:0] d;
    begin
      addr = a; wdata = d;
      @(negedge clk);
      if (ack !== 1'b1) bad("burst write ACK missing");
    end
  endtask
endmodule
