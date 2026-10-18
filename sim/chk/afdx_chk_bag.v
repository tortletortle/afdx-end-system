// §8.8 A5: same-VL SOF spacing on the TX pins, not builder done / EOF.
// bag_us=0 disables. clr between BAG slots. Single-VL scenes only (T27).
`timescale 1 ns / 1 ps
module afdx_chk_bag #(
  parameter integer IF_MODE = 0
) (
  input wire        clk,
  input wire        rst,
  input wire        clr,
  input wire [23:0] bag_us,
  input wire        tx_valid,
  input wire        tx_ready
);
  localparam integer BYTE_SLOT = (IF_MODE != 0) ? 1 : 10;
  localparam integer IDLE_LIM  = BYTE_SLOT * 12;

  integer errors;
  integer cyc, last_sof, idle_n, gap, min_cyc;
  reg     in_frm;
  wire take = tx_valid && ((IF_MODE != 0) || tx_ready);

  initial errors = 0;

  always @(posedge clk) begin
    if (rst || clr) begin
      cyc <= 0; last_sof <= -1; idle_n <= 0; in_frm <= 1'b0;
    end else begin
      cyc <= cyc + 1;
      if (take) begin
        if (!in_frm) begin
          in_frm <= 1'b1;
          if (bag_us != 24'd0 && last_sof >= 0) begin
            gap = cyc - last_sof;
            min_cyc = bag_us * 125;
            if (gap < min_cyc) begin
              if (errors < 8)
                $display("  [chk] A5 BAG early gap %0d min %0d t=%0t", gap, min_cyc, $time);
              errors = errors + 1;
            end
          end
          last_sof <= cyc;
        end
        idle_n <= 0;
      end else if (in_frm) begin
        if (idle_n + 1 >= IDLE_LIM) begin
          in_frm <= 1'b0;
          idle_n <= 0;
        end else idle_n <= idle_n + 1;
      end
    end
  end
endmodule
