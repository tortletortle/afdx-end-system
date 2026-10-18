// T38: independent boundary self-test for the passive MAC byte-stream checker.
// It checks the checker's own error counter by exact per-frame deltas; expected
// checker diagnostics are data, not simulator errors, so this TB emits one
// machine-judgable T38 PASS/FAIL verdict line.
`timescale 1 ns / 1 ps
module tb_t38_mac_len_core #(parameter integer IF_MODE = 0);
  reg clk = 0, rst = 1;
  always #4 clk = ~clk;

  reg [7:0] tx_data = 8'h00;
  reg tx_valid = 0, active_fcs = 0;
  wire tx_ready = 1'b1;
  wire fcs_valid = tx_valid && active_fcs;
  wire nofcs_valid = tx_valid && !active_fcs;
  integer errors = 0;
  integer before_fcs, before_nofcs;
  integer i;
  reg [7:0] frame [0:1800];
  reg [31:0] crc;

  afdx_chk_mac #(.IF_MODE(IF_MODE), .FCS_MODE(2)) chk_fcs (
    .clk(clk), .rst(rst), .tx_data(tx_data), .tx_valid(fcs_valid), .tx_ready(tx_ready));
  afdx_chk_mac #(.IF_MODE(IF_MODE), .FCS_MODE(0)) chk_nofcs (
    .clk(clk), .rst(rst), .tx_data(tx_data), .tx_valid(nofcs_valid), .tx_ready(tx_ready));

  function [31:0] crc8;
    input [31:0] cin;
    input [7:0] d;
    integer b;
    reg [31:0] c;
    begin
      c = cin ^ {24'd0, d};
      for (b = 0; b < 8; b = b + 1)
        c = c[0] ? ((c >> 1) ^ 32'hEDB8_8320) : (c >> 1);
      crc8 = c;
    end
  endfunction

  task send_frame;
    input integer length;
    input integer with_fcs;
    input integer corrupt_fcs;
    begin
      active_fcs = with_fcs;
      for (i = 0; i < length; i = i + 1) frame[i] = 8'hA5;
      // Keep the checker’s SN sentinel nonzero for every FCS-bearing frame.
      if (with_fcs != 0 && length >= 5) frame[length - 5] = 8'h01;
      if (with_fcs != 0 && length >= 4) begin
        crc = 32'hFFFF_FFFF;
        for (i = 0; i < length - 4; i = i + 1) crc = crc8(crc, frame[i]);
        crc = crc ^ 32'hFFFF_FFFF;
        frame[length - 4] = crc[7:0];
        frame[length - 3] = crc[15:8];
        frame[length - 2] = crc[23:16];
        frame[length - 1] = crc[31:24];
        if (corrupt_fcs != 0) frame[length - 1] = frame[length - 1] ^ 8'h80;
        // For an over-capacity stream the checker retains only bytes 0..1517,
        // then compares a truncated pseudo-FCS. Force that retained comparison
        // to be unequal so the expected A3+A12 counter delta is deterministic.
        if (length == 1519) begin
          crc = 32'hFFFF_FFFF;
          for (i = 0; i < 1514; i = i + 1) crc = crc8(crc, frame[i]);
          crc = crc ^ 32'hFFFF_FFFF;
          if ({frame[1517],frame[1516],frame[1515],frame[1514]} == crc)
            frame[1517] = frame[1517] ^ 8'h01;
        end
      end
      for (i = 0; i < length; i = i + 1) begin
        @(negedge clk);
        tx_data = frame[i];
        tx_valid = 1'b1;
        if (IF_MODE == 0) begin
          // One accepted byte per pulse.  The checker samples at posedge;
          // deassert after the first sample, then wait 8 further negedges;
          // the next loop's initial wait supplies cycle 10.
          @(negedge clk);
          tx_valid = 1'b0;
          repeat (8) @(negedge clk);
        end
      end
      @(negedge clk);
      tx_valid = 1'b0;
      // Checker closes a frame after 12 byte slots without an accepted byte.
      if (IF_MODE == 0) repeat (125) @(negedge clk);
      else repeat (17) @(negedge clk);
    end
  endtask

  task expect_delta;
    input integer fcs_expected;
    input integer nofcs_expected;
    input [8*48-1:0] label;
    begin
      if ((chk_fcs.errors - before_fcs) != fcs_expected ||
          (chk_nofcs.errors - before_nofcs) != nofcs_expected) begin
        $display("  T38 case=%0s fcs_delta=%0d expected=%0d nofcs_delta=%0d expected=%0d",
                 label, chk_fcs.errors-before_fcs, fcs_expected,
                 chk_nofcs.errors-before_nofcs, nofcs_expected);
        errors = errors + 1;
      end
      before_fcs = chk_fcs.errors;
      before_nofcs = chk_nofcs.errors;
    end
  endtask

  initial begin
    repeat (5) @(negedge clk);
    rst = 0;
    before_fcs = 0;
    before_nofcs = 0;

    // With-FCS mode: valid CRC at each accepted/rejected size boundary.
    send_frame(64, 1, 0);   expect_delta(0, 0, "fcs_64_accept");
    send_frame(63, 1, 0);   expect_delta(1, 0, "fcs_63_reject");
    send_frame(1518, 1, 0); expect_delta(0, 0, "fcs_1518_accept");
    send_frame(1519, 1, 0); expect_delta(2, 0, "fcs_1519_overflow_and_crc");
    send_frame(64, 1, 1);   expect_delta(1, 0, "fcs_bad_crc");

    // Without-FCS mode: exact minimum/maximum and adjacent rejects.
    send_frame(60, 0, 0);   expect_delta(0, 0, "nofcs_60_accept");
    send_frame(59, 0, 0);   expect_delta(0, 1, "nofcs_59_reject");
    send_frame(1514, 0, 0); expect_delta(0, 0, "nofcs_1514_accept");
    send_frame(1515, 0, 0); expect_delta(0, 1, "nofcs_1515_reject");

    // Longer-than-buffer continuous stream must report A3; then a legal frame
    // must be recognized as a new frame and must not inherit overflow state.
    send_frame(1800, 0, 0); expect_delta(0, 1, "nofcs_1800_overflow");
    send_frame(60, 0, 0);   expect_delta(0, 0, "nofcs_recovery_60");

    active_fcs = 0;
    if (errors == 0)
      $display("T38 MAC LENGTH CHECKER PASS (IF_MODE=%0d fcs=5 nofcs=6 exact_error_deltas=1)", IF_MODE);
    else
      $display("T38 MAC LENGTH CHECKER FAIL (IF_MODE=%0d errors=%0d)", IF_MODE, errors);
    $finish;
  end
  initial begin
    #100_000_000;
    $display("T38 MAC LENGTH CHECKER FAIL (IF_MODE=%0d timeout)", IF_MODE);
    $finish;
  end
endmodule

module tb_t38_mac_len;
  tb_t38_mac_len_core #(.IF_MODE(0)) core();
endmodule

module tb_t38g_mac_len;
  tb_t38_mac_len_core #(.IF_MODE(1)) core();
endmodule
