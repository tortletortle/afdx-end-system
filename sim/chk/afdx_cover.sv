// §12.3 hand bins on the TX byte stream. Line/branch 95% is not claimed.
`timescale 1 ns / 1 ps
module afdx_cover #(
  parameter integer IF_MODE = 0
) (
  input wire clk, rst,
  input wire [7:0] tx_data,
  input wire tx_valid, tx_ready
);
  localparam integer BYTE_SLOT = (IF_MODE != 0) ? 1 : 10;
  localparam integer IDLE_LIM  = BYTE_SLOT * 12;
  integer n_byte, n_frm, n_sn1, n_sn2, n_sn254, n_sn255;
  integer n_len8, n_len17, n_len18, n_len19, n_len1470, n_len1471;
  integer cap_len, idle_n, body, sn;
  reg in_frm;
  reg [7:0] cap [0:1517];
  wire take = tx_valid && ((IF_MODE != 0) || tx_ready);

  initial begin
    n_byte = 0; n_frm = 0;
    n_sn1 = 0; n_sn2 = 0; n_sn254 = 0; n_sn255 = 0;
    n_len8 = 0; n_len17 = 0; n_len18 = 0; n_len19 = 0;
    n_len1470 = 0; n_len1471 = 0;
    cap_len = 0; idle_n = 0; in_frm = 0;
  end

`ifdef QUESTA_COV
  covergroup cg @(posedge clk);
    cp_v: coverpoint tx_valid;
  endgroup
  cg cg_i;
  initial cg_i = new;
`endif

  always @(posedge clk) begin
    if (rst) begin
      cap_len <= 0; idle_n <= 0; in_frm <= 1'b0;
    end else begin
      if (take) begin
        n_byte = n_byte + 1;
        if (!in_frm) begin
          in_frm <= 1'b1;
          cap_len <= 1;
          cap[0] <= tx_data;
        end else if (cap_len < 1518) begin
          cap[cap_len] <= tx_data;
          cap_len <= cap_len + 1;
        end
        idle_n <= 0;
      end else if (in_frm) begin
        if (idle_n + 1 >= IDLE_LIM) begin
          in_frm <= 1'b0;
          idle_n <= 0;
          n_frm = n_frm + 1;
          body = (cap_len >= 4) ? (cap_len - 4) : cap_len;
          if (body >= 43) begin
            if ((body - 43) == 8)    n_len8 = n_len8 + 1;
            if ((body - 43) == 17)   n_len17 = n_len17 + 1;
            if ((body - 43) == 18)   n_len18 = n_len18 + 1;
            if ((body - 43) == 19)   n_len19 = n_len19 + 1;
            if ((body - 43) == 1470) n_len1470 = n_len1470 + 1;
            if ((body - 43) == 1471) n_len1471 = n_len1471 + 1;
          end
          if (cap_len >= 5) begin
            sn = cap[cap_len - 5];
            if (sn == 1) n_sn1 = n_sn1 + 1;
            if (sn == 2) n_sn2 = n_sn2 + 1;
            if (sn == 254) n_sn254 = n_sn254 + 1;
            if (sn == 255) n_sn255 = n_sn255 + 1;
          end
        end else idle_n <= idle_n + 1;
      end
    end
  end
endmodule
