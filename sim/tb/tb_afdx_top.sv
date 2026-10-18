// Design book §12.1: one ES env around AFDX_top (not a new Txx).
// Elaborated only when it is the vsim top. Other tests compile it unused.
`timescale 1 ns / 1 ps
module tb_afdx_top;
  localparam integer IF_MODE = 0;
  localparam integer DELAY_US = 10;

  reg clk = 0, reset = 1;
  always #4 clk = ~clk;

  wire        host_cs, host_we, host_ack, host_irq;
  wire [15:0] host_addr;
  wire [31:0] host_wdata, host_rdata;
  wire [7:0]  tx_data, tx_data_b, rx_data, rx_data_b;
  wire        tx_valid, tx_valid_b, tx_ready, tx_ready_b;
  wire        rx_valid, rx_valid_b, rx_ready, rx_ready_b;
  wire [31:0] fwd_a, fwd_b;
  integer     waitc, errors;
  reg [31:0]  rd;

  AFDX_top #(.IF_MODE(IF_MODE), .FCS_MODE(2)) dut (
    .clk(clk), .reset(reset),
    .tx_data(tx_data), .rx_data(rx_data),
    .tx_valid(tx_valid), .rx_valid(rx_valid),
    .tx_ready(tx_ready), .rx_ready(rx_ready),
    .tx_data_b(tx_data_b), .tx_valid_b(tx_valid_b), .tx_ready_b(tx_ready_b),
    .rx_data_b(rx_data_b), .rx_valid_b(rx_valid_b), .rx_ready_b(rx_ready_b),
    .host_cs(host_cs), .host_we(host_we), .host_addr(host_addr),
    .host_wdata(host_wdata), .host_rdata(host_rdata), .host_ack(host_ack),
    .host_irq(host_irq),
    .pps_in(1'b0), .pps_out(), .rtc_time_us(), .dbg_frame_event());

  afdx_host_bfm u_host (
    .clk(clk), .cs(host_cs), .we(host_we), .addr(host_addr), .wdata(host_wdata),
    .rdata(host_rdata), .ack(host_ack));

  afdx_net_model #(.IF_MODE(IF_MODE), .DELAY_US(DELAY_US)) u_net (
    .clk(clk), .rst(reset),
    .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready),
    .tx_data_b(tx_data_b), .tx_valid_b(tx_valid_b), .tx_ready_b(tx_ready_b),
    .corrupt_a(1'b0), .corrupt_b(1'b0),
    .rx_data(rx_data), .rx_valid(rx_valid), .rx_ready(rx_ready),
    .rx_data_b(rx_data_b), .rx_valid_b(rx_valid_b), .rx_ready_b(rx_ready_b),
    .fwd_a(fwd_a), .fwd_b(fwd_b));

  afdx_mac_bfm #(.IF_MODE(IF_MODE), .DELAY_US(DELAY_US)) u_mac_a (
    .clk(clk), .rst(reset),
    .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready),
    .rx_data(), .rx_valid(), .rx_ready(),
    .frames_fwd());

  afdx_mac_bfm #(.IF_MODE(IF_MODE), .DELAY_US(DELAY_US + 50)) u_mac_b (
    .clk(clk), .rst(reset),
    .tx_data(tx_data_b), .tx_valid(tx_valid_b), .tx_ready(tx_ready_b),
    .rx_data(), .rx_valid(), .rx_ready(),
    .frames_fwd());

  afdx_timing_mon #(.IF_MODE(IF_MODE)) u_mon (
    .clk(clk), .rst(reset), .clr(1'b0),
    .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready));

  afdx_scoreboard u_sb ();
  afdx_chk_mac #(.IF_MODE(IF_MODE)) u_chk (
    .clk(clk), .rst(reset),
    .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready));
  afdx_cover #(.IF_MODE(IF_MODE)) u_cov (
    .clk(clk), .rst(reset), .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready));

  initial begin
    errors = 0;
    repeat (7) @(negedge clk); reset = 0;
    waitc = 0;
    while (dut.init_done !== 1 && waitc < 27000) begin @(negedge clk); waitc = waitc + 1; end
    if (waitc >= 27000) begin
      $display("  [err] tb_afdx_top INIT_DONE timeout");
      errors = errors + 1;
    end
    u_host.rd(16'h0000, rd);
    if (errors == 0)
      $display("tb_afdx_top ENV PASS (IF_MODE=%0d host+mac_bfm+net+mon+sb+cover)", IF_MODE);
    else
      $display("tb_afdx_top ENV FAIL (errors=%0d)", errors);
    $finish;
  end
endmodule
