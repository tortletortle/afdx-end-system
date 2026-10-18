// Timing monitor. dump_csv writes BAG gaps for §12.1 / §12.4 metrics.
`timescale 1 ns / 1 ps
module afdx_timing_mon #(
  parameter integer IF_MODE = 0,
  parameter integer MAX_SOF = 16
) (
  input  wire       clk,
  input  wire       rst,
  input  wire       clr,
  input  wire [7:0] tx_data,
  input  wire       tx_valid,
  input  wire       tx_ready
);
  localparam integer BYTE_SLOT = (IF_MODE != 0) ? 1 : 10;
  localparam integer IDLE_LIM  = BYTE_SLOT * 12;

  integer    cyc;
  integer    nsof;
  integer    sof_cyc [0:MAX_SOF-1];
  integer    idle_n;
  reg        in_frm;
  wire       take = tx_valid && ((IF_MODE != 0) || tx_ready);

  always @(posedge clk) begin
    if (rst || clr) begin
      cyc <= 0;
      nsof <= 0;
      idle_n <= 0;
      in_frm <= 1'b0;
    end else begin
      cyc <= cyc + 1;
      if (take) begin
        if (!in_frm) begin
          in_frm <= 1'b1;
          if (nsof < MAX_SOF) sof_cyc[nsof] <= cyc;
          nsof <= nsof + 1;
        end
        idle_n <= 0;
      end else if (in_frm) begin
        if (idle_n + 1 >= IDLE_LIM) begin
          in_frm <= 1'b0;
          idle_n <= 0;
        end         else
          idle_n <= idle_n + 1;
      end
    end
  end

  task dump_csv;
    input [8*128-1:0] path;
    input integer bag_us;
    integer fd, g, gap;
    begin
      fd = $fopen(path, "a");
      if (fd == 0) begin
        $display("  [err] timing_mon cannot open CSV");
      end else begin
        if (nsof >= 2)
          for (g = 1; g < nsof; g = g + 1) begin
            gap = sof_cyc[g] - sof_cyc[g-1];
            $fdisplay(fd, "%0d,%0d,%0d,%0d", bag_us, g, gap, bag_us * 125);
          end
        $fclose(fd);
      end
    end
  endtask
endmodule
