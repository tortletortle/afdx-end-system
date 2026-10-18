// Dual-net ES loopback fabric (design book §12.1 net_model):
// two independent store-and-forward delays, default 10 us each.
`timescale 1 ns / 1 ps
module afdx_net_model #(
  parameter integer IF_MODE  = 0,
  parameter integer DELAY_US = 10,
  parameter integer DEPTH    = 4,
  parameter integer LOOPBACK = 1
) (
  input  wire       clk,
  input  wire       rst,
  input  wire [7:0] tx_data,
  input  wire       tx_valid,
  input  wire       tx_ready,
  input  wire [7:0] tx_data_b,
  input  wire       tx_valid_b,
  input  wire       tx_ready_b,
  input  wire       corrupt_a,
  input  wire       corrupt_b,
  output wire [7:0] rx_data,
  output wire       rx_valid,
  output wire       rx_ready,
  output wire [7:0] rx_data_b,
  output wire       rx_valid_b,
  output wire       rx_ready_b,
  output wire [31:0] fwd_a,
  output wire [31:0] fwd_b
);
  wire [31:0] cor_a, cor_b;
  wire [10:0] len_a, len_b;
  afdx_net_port #(.IF_MODE(IF_MODE), .DELAY_US(DELAY_US), .DEPTH(DEPTH), .LOOPBACK(LOOPBACK)) u_a (
    .clk(clk), .rst(rst),
    .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready),
    .corrupt_next(corrupt_a),
    .rx_data(rx_data), .rx_valid(rx_valid), .rx_ready(rx_ready),
    .frames_fwd(fwd_a), .frames_corrupt(cor_a), .last_len(len_a));
  afdx_net_port #(.IF_MODE(IF_MODE), .DELAY_US(DELAY_US), .DEPTH(DEPTH), .LOOPBACK(LOOPBACK)) u_b (
    .clk(clk), .rst(rst),
    .tx_data(tx_data_b), .tx_valid(tx_valid_b), .tx_ready(tx_ready_b),
    .corrupt_next(corrupt_b),
    .rx_data(rx_data_b), .rx_valid(rx_valid_b), .rx_ready(rx_ready_b),
    .frames_fwd(fwd_b), .frames_corrupt(cor_b), .last_len(len_b));
endmodule
