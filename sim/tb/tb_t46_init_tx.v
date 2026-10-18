// =====================================================================
// T46 — a615a_init_tx 初始化文件编码基础（P03，2026-10-10）
//
// 覆盖：字段编码与长度（9 字节：u32 长度=9、2 字节版本、2 字节状态、
// 描述长度 0）、start/ready 握手、valid 保持到 ack、ack 与新请求同拍、
// 输出在 valid 期间保持（输入变化不影响已锁存字段）、复位。
// 预期字节为独立常量（非从 DUT 输出反推）。
// =====================================================================
`timescale 1 ns / 1 ps
module tb_t46_init_tx;
  reg clk = 0;
  always #4 clk = ~clk;
  reg rst = 1, start = 0, ack = 0;
  reg [15:0] version = 16'hA431;
  reg [15:0] status  = 16'h0002;
  reg [3:0]  addr = 4'd0;
  wire [7:0] byte_data;
  wire [15:0] file_length;
  wire start_ready, file_valid;

  a615a_init_tx dut (
    .clk(clk), .rst_sync(rst), .start(start), .version(version), .status(status),
    .start_ready(start_ready), .file_valid(file_valid), .file_ack(ack),
    .file_length(file_length), .byte_address(addr), .byte_data(byte_data)
  );

  integer errors = 0, checks = 0;
  task bad;
    input [8*96-1:0] reason;
    begin if (errors < 12) $display("  [err] T46 %0s", reason); errors = errors + 1; end
  endtask
  task chk;
    input cond; input [8*96-1:0] reason;
    begin checks = checks + 1; if (!cond) bad(reason); end
  endtask

  function [7:0] expect_byte;
    input [3:0] a; input [15:0] ver; input [15:0] st;
    begin
      case (a)
        4'd3: expect_byte = 8'd9;
        4'd4: expect_byte = ver[15:8];
        4'd5: expect_byte = ver[7:0];
        4'd6: expect_byte = st[15:8];
        4'd7: expect_byte = st[7:0];
        default: expect_byte = 8'd0;
      endcase
    end
  endfunction

  integer a;
  task check_bytes;
    input [15:0] ver; input [15:0] st;
    begin
      for (a = 0; a < 16; a = a + 1) begin
        addr = a[3:0]; #1;
        chk(byte_data === expect_byte(a[3:0], ver, st), "byte_data encoding");
      end
    end
  endtask

  initial begin
    repeat (5) @(negedge clk);
    rst = 0; repeat (2) @(negedge clk);

    // C1: idle state
    chk(file_valid === 1'b0, "C1 file_valid must be low after reset");
    chk(start_ready === 1'b1, "C1 start_ready must be high when idle");
    chk(file_length === 16'd9, "C1 file_length is the fixed 9-byte layout");

    // C2: start with A4/status -> valid + byte table
    version = 16'hA431; status = 16'h0002;
    @(negedge clk); start = 1;
    @(negedge clk); start = 0;
    @(negedge clk);
    chk(file_valid === 1'b1, "C2 file_valid must rise after start");
    check_bytes(16'hA431, 16'h0002);

    // C3: output holds latched fields even if inputs change while valid
    version = 16'hFFFF; status = 16'hFFFF;
    check_bytes(16'hA431, 16'h0002);

    // C4: start while valid and not acked is refused
    @(negedge clk); start = 1;
    @(negedge clk);
    chk(start_ready === 1'b0, "C4 start_ready low while valid && !ack");
    start = 0;

    // C5: ack clears valid
    @(negedge clk); ack = 1;
    @(negedge clk); ack = 0;
    @(negedge clk);
    chk(file_valid === 1'b0, "C5 ack clears file_valid");
    chk(start_ready === 1'b1, "C5 start_ready returns high");

    // C6: same-cycle ack + new start -> new fields win, valid stays high
    version = 16'h1122; status = 16'h3344;
    @(negedge clk); start = 1;
    @(negedge clk); start = 0;
    @(negedge clk);
    chk(file_valid === 1'b1, "C6 valid after restart");
    @(negedge clk); ack = 1; start = 1; version = 16'h5566; status = 16'h7788;
    @(negedge clk); ack = 0; start = 0;
    @(negedge clk);
    chk(file_valid === 1'b1, "C6 valid held when ack+start coincide");
    check_bytes(16'h5566, 16'h7788);

    // C7: reset mid-file
    rst = 1; @(negedge clk); @(negedge clk);
    chk(file_valid === 1'b0, "C7 reset clears valid");
    rst = 0; repeat (2) @(negedge clk);

    if (errors == 0) $display("T46 INIT_TX PASS checks=%0d", checks);
    else $display("T46 INIT_TX FAIL errors=%0d", errors);
    $finish;
  end
  initial begin #200000; $display("T46 INIT_TX FAIL timeout"); $finish; end
endmodule
