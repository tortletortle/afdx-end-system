// T96 — afdx_app_top 门级专项（新增系统场，不进 tests.manifest）
// 只连端口。不读任何层次内部信号。
// 两条消息、两条 VL：VL0 载荷 17 B，VL96 载荷 1471 B（封装最大帧）。
// 在 rx_data 上逐字节比对 VLID 与载荷。
`timescale 1 ns / 1 ps
module tb_t96_app_gate;
  localparam integer CLK_NS = 8;
  localparam integer VL_A = 0;
  localparam integer PL_A = 17;
  localparam integer VL_B = 96;
  localparam integer PL_B = 1471;
  localparam integer GUARD_CYC = 8000000;

  reg clk = 1'b0;
  reg reset = 1'b1;
  always #(CLK_NS/2) clk = ~clk;

  reg  [7:0] tx_data = 8'd0;
  reg        tx_valid = 1'b0;
  wire [7:0] rx_data;
  wire       rx_valid;
  wire       tx_ready;
  reg        rx_ready = 1'b1;
  wire [7:0] gmii_tx_data_a;
  wire       gmii_tx_valid_a;
  wire [7:0] gmii_tx_data_b;
  wire       gmii_tx_valid_b;

  integer errors = 0;
  integer checks = 0;
  integer quiet_i = 0;
  integer unexpected = 0;

  afdx_app_top u_top (
    .clk(clk),
    .reset(reset),
    .tx_data(tx_data),
    .tx_valid(tx_valid),
    .tx_ready(tx_ready),
    .rx_data(rx_data),
    .rx_valid(rx_valid),
    .rx_ready(rx_ready),
    .gmii_tx_data_a(gmii_tx_data_a),
    .gmii_tx_valid_a(gmii_tx_valid_a),
    .gmii_tx_data_b(gmii_tx_data_b),
    .gmii_tx_valid_b(gmii_tx_valid_b)
  );

  function [7:0] pay_byte;
    input integer vl;
    input integer idx;
    begin
      pay_byte = 8'hA5 ^ vl[7:0] ^ idx[7:0];
    end
  endfunction

  task wait_ready;
    integer guard;
    begin
      guard = 0;
      while (tx_ready !== 1'b1) begin
        @(negedge clk);
        guard = guard + 1;
        if (guard > GUARD_CYC) begin
          $display("T96 APP GATE FAIL tx_ready timeout");
          $display("Errors: 1");
          $finish;
        end
      end
    end
  endtask

  task send_msg;
    input integer vl;
    input integer plen;
    integer i;
    begin
      wait_ready;
      @(negedge clk);
      tx_data  = 8'h01;
      tx_valid = 1'b1;
      @(negedge clk);
      tx_data = vl[7:0];
      for (i = 0; i < plen; i = i + 1) begin
        @(negedge clk);
        tx_data = pay_byte(vl, i);
      end
      @(negedge clk);
      tx_valid = 1'b0;
      tx_data  = 8'd0;
    end
  endtask

  task expect_msg;
    input integer vl;
    input integer plen;
    integer i;
    integer guard;
    integer nbyte;
    reg [7:0] exp;
    begin
      nbyte = plen + 2;
      i = 0;
      guard = 0;
      while (i < nbyte) begin
        @(negedge clk);
        guard = guard + 1;
        if (rx_valid === 1'b1) begin
          if (i == 0) exp = 8'h01;
          else if (i == 1) exp = vl[7:0];
          else exp = pay_byte(vl, i - 2);
          if (rx_data !== exp) begin
            errors = errors + 1;
            $display("T96 MISMATCH vl=%0d byte=%0d got=%02h exp=%02h", vl, i, rx_data, exp);
          end
          checks = checks + 1;
          i = i + 1;
          guard = 0;
          if ((i % 256) == 0) $display("T96 PROGRESS vl=%0d bytes=%0d", vl, i);
        end
        if (guard > GUARD_CYC) begin
          $display("T96 APP GATE FAIL rx timeout vl=%0d got=%0d/%0d", vl, i, nbyte);
          $display("Errors: 1");
          $finish;
        end
      end
    end
  endtask

  initial begin
    tx_valid = 1'b0;
    tx_data  = 8'd0;
    rx_ready = 1'b1;
    reset    = 1'b1;
    repeat (8) @(negedge clk);
    reset = 1'b0;
    send_msg(VL_A, PL_A);
    expect_msg(VL_A, PL_A);
    send_msg(VL_B, PL_B);
    expect_msg(VL_B, PL_B);
    begin : quiet_window
      unexpected = 0;
      for (quiet_i = 0; quiet_i < 20000; quiet_i = quiet_i + 1) begin
        @(negedge clk);
        if (rx_valid === 1'b1) begin
          errors = errors + 1;
          unexpected = unexpected + 1;
          if (unexpected == 1) $display("T96 UNEXPECTED_RX");
        end
      end
      if (unexpected == 0) $display("T96 QUIET_WINDOW PASS cycles=20000");
    end
    if (errors == 0 && checks == (PL_A + PL_B + 4)) begin
      $display("T96 APP GATE PASS checks=%0d", checks);
      $display("Errors: 0");
    end else begin
      $display("T96 APP GATE FAIL errors=%0d checks=%0d", errors, checks);
      $display("Errors: %0d", errors);
    end
    $finish;
  end
endmodule
