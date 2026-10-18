// Payload compare helper for system TBs (§12.1 scoreboard: TX wire vs RX PMEM).
`timescale 1 ns / 1 ps
module afdx_scoreboard;
  integer mismatches;
  initial mismatches = 0;
  task check_byte;
    input integer off;
    input [7:0] got;
    input [7:0] want;
    begin
      if (got !== want) begin
        if (mismatches < 12)
          $display("  [sb] byte %0d got %02h want %02h", off, got, want);
        mismatches = mismatches + 1;
      end
    end
  endtask
endmodule
