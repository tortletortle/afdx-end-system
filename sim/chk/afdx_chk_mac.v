// §8.8 A1/A3/A4/A12 on the MAC TX byte pins (process checkers, O-16).
// A3: total byte-stream length is [64,1518] with FCS, [60,1514] without FCS.
// A12: independent 802.3 CRC vs last 4 bytes.
// A2 not enabled: IF_MODE=0 shares tx_ready with RX link_rdy (EOF dip false-fails).
// Does not use $error (Questa ** Error fails the runner even with a PASS line).
`timescale 1 ns / 1 ps
module afdx_chk_mac #(
  parameter integer IF_MODE  = 0,
  parameter integer FCS_MODE = 2
) (
  input wire       clk,
  input wire       rst,
  input wire [7:0] tx_data,
  input wire       tx_valid,
  input wire       tx_ready
);
  localparam integer BYTE_SLOT = (IF_MODE != 0) ? 1 : 10;
  localparam integer IDLE_LIM  = BYTE_SLOT * 12;

  integer errors;
  integer cyc, last_take, idle_n, cap_len, i;
  integer body;
  reg     in_frm, overflow;
  reg [7:0] cap [0:1517];
  reg [31:0] crc, want, got;
  wire take = tx_valid && ((IF_MODE != 0) || tx_ready);

  initial errors = 0;

  function [31:0] crc8;
    input [31:0] cin;
    input [7:0]  d;
    integer b;
    reg [31:0] c;
    begin
      c = cin ^ {24'd0, d};
      for (b = 0; b < 8; b = b + 1)
        c = c[0] ? ((c >> 1) ^ 32'hEDB8_8320) : (c >> 1);
      crc8 = c;
    end
  endfunction

  always @(posedge clk) begin
    if (rst) begin
      cyc <= 0; last_take <= 0; idle_n <= 0; cap_len <= 0; in_frm <= 1'b0;
      overflow <= 1'b0;
    end else begin
      cyc <= cyc + 1;
      if (take) begin
        if (in_frm && (cyc - last_take) < BYTE_SLOT) begin
          if (errors < 8) $display("  [chk] A1 byte gap %0d cyc min %0d t=%0t",
                                   cyc - last_take, BYTE_SLOT, $time);
          errors = errors + 1;
        end
        if (!in_frm) begin
          in_frm <= 1'b1;
          cap_len <= 1;
          cap[0] <= tx_data;
          overflow <= 1'b0;
        end else if (cap_len < 1518) begin
          cap[cap_len] <= tx_data;
          cap_len <= cap_len + 1;
        end else overflow <= 1'b1;
        last_take <= cyc;
        idle_n <= 0;
      end else if (in_frm) begin
        if (idle_n + 1 >= IDLE_LIM) begin
          in_frm <= 1'b0;
          idle_n <= 0;
          body = (FCS_MODE != 0 && cap_len >= 4) ? (cap_len - 4) : cap_len;
          if (FCS_MODE != 0) begin
            if (overflow || cap_len < 64 || cap_len > 1518) begin
              if (errors < 8) $display("  [chk] A3 total len %0d (incl FCS; expected 64..1518) t=%0t",
                                       cap_len, $time);
              errors = errors + 1;
            end
          end else if (overflow || cap_len < 60 || cap_len > 1514) begin
            if (errors < 8) $display("  [chk] A3 total len %0d (no FCS; expected 60..1514) t=%0t",
                                     cap_len, $time);
            errors = errors + 1;
          end
          if (FCS_MODE != 0 && cap_len >= 5 && cap[cap_len - 5] == 8'd0) begin
            if (errors < 8) $display("  [chk] A4 SN=0 t=%0t", $time);
            errors = errors + 1;
          end
          if (FCS_MODE != 0 && cap_len >= 5) begin
            crc = 32'hFFFF_FFFF;
            for (i = 0; i < body; i = i + 1)
              crc = crc8(crc, cap[i]);
            want = crc ^ 32'hFFFF_FFFF;
            got = {cap[cap_len-1], cap[cap_len-2], cap[cap_len-3], cap[cap_len-4]};
            if (got !== want) begin
              if (errors < 8)
                $display("  [chk] A12 FCS got %08h want %08h t=%0t", got, want, $time);
              errors = errors + 1;
            end
          end
        end else idle_n <= idle_n + 1;
      end
    end
  end
endmodule
