// §12.1 mac_bfm: one GMII/byte-stream port with the documented fault tasks.
// Play path is LOOPBACK=0 inject (switch -> ES). Skew = extra DELAY_US on this port.
`timescale 1 ns / 1 ps
module afdx_mac_bfm #(
  parameter integer IF_MODE  = 0,
  parameter integer DELAY_US = 10
) (
  input  wire        clk,
  input  wire        rst,
  input  wire [7:0]  tx_data,
  input  wire        tx_valid,
  input  wire        tx_ready,
  output wire [7:0]  rx_data,
  output wire        rx_valid,
  output wire        rx_ready,
  output wire [31:0] frames_fwd
);
  wire [31:0] cor;
  wire [10:0] last_len;
  afdx_net_port #(.IF_MODE(IF_MODE), .DELAY_US(DELAY_US), .LOOPBACK(0)) u_p (
    .clk(clk), .rst(rst),
    .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready),
    .corrupt_next(1'b0),
    .rx_data(rx_data), .rx_valid(rx_valid), .rx_ready(rx_ready),
    .frames_fwd(frames_fwd), .frames_corrupt(cor), .last_len(last_len));

  task load_byte;
    input integer off;
    input [7:0] b;
    begin
      u_p.inj_mem[off] = b;
    end
  endtask

  task inject;
    input integer n;
    begin
      u_p.inj_len = n[10:0];
      u_p.inj_req = 1'b1;
      @(posedge clk);
      u_p.inj_req = 1'b0;
    end
  endtask

  task inject_crc_bad;
    input integer n;
    begin
      if (n > 0) u_p.inj_mem[n - 1] = u_p.inj_mem[n - 1] ^ 8'hFF;
      inject(n);
    end
  endtask

  task inject_trunc;
    input integer n;
    input integer keep;
    integer k;
    begin
      k = (keep < n) ? keep : n;
      inject(k);
    end
  endtask

  task inject_drop;
    begin
      u_p.drop_next = 1'b1;
    end
  endtask

  task inject_dup;
    begin
      u_p.dup_next = 1'b1;
    end
  endtask

  task inject_reorder;
    begin
      u_p.swap_head;
    end
  endtask

  task inject_ifg_jitter;
    input integer extra_cyc;
    begin
      u_p.ifg_extra = extra_cyc;
    end
  endtask
endmodule
