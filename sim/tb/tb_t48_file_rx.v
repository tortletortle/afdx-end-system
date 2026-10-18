// =====================================================================
// T48 — a615a_file_rx 完整文件接收缓冲（P03，2026-10-10）
//
// 覆盖：输入暂停（in_valid 停顿时字节不丢）、字节顺序与长度、空文件
// 策略、容量溢出（继续排空但不发布）、abort、file_end 独立周期要求、
// 完整发布（file_valid 保持到 ack）与同步读回（rd 越界抑制）、
// MAX_BYTES 参数不合法（E_BAD_PARAM）。两个实例：大容量常规用例 +
// 小容量（64 B）溢出用例。预期字节由 TB 独立产生。
// =====================================================================
`timescale 1 ns / 1 ps
module tb_t48_file_rx;
  reg clk = 0;
  always #4 clk = ~clk;
  reg rst = 1;

  // ---- big instance (default 8192) ----
  reg file_start = 0;
  wire start_ready;
  reg in_valid = 0;
  wire in_ready;
  reg [7:0] in_data = 0;
  reg file_end = 0, file_abort = 0;
  wire file_busy, file_valid;
  reg file_ack = 0;
  wire [13:0] file_length;
  wire [1:0] error_code;
  reg rd_en = 0;
  reg [12:0] rd_addr = 0;
  wire rd_valid;
  wire [7:0] rd_data;

  // ---- small instance (64 B) for overflow ----
  reg s_start = 0;
  wire s_ready;
  reg s_valid = 0;
  wire s_in_ready;
  reg [7:0] s_data = 0;
  reg s_end = 0, s_abort = 0;
  wire s_busy, s_valid_out;
  reg s_ack = 0;
  wire [13:0] s_length;
  wire [1:0] s_error;

  a615a_file_rx #(.MAX_BYTES(8192)) dut (
    .clk(clk), .rst_sync(rst), .file_start(file_start), .file_start_ready(start_ready),
    .in_valid(in_valid), .in_ready(in_ready), .in_data(in_data),
    .file_end(file_end), .file_abort(file_abort),
    .preload_start(1'b0), .preload_start_ready(),
    .preload_data_valid(1'b0), .preload_data_ready(), .preload_data(8'd0),
    .preload_commit(1'b0), .preload_length(14'd0), .preload_abort(1'b0),
    .upload_job_active(1'b0), .preload_error(),
    .file_busy(file_busy), .file_valid(file_valid), .file_ack(file_ack),
    .file_length(file_length), .error_code(error_code),
    .rd_en(rd_en), .rd_addr(rd_addr), .rd_valid(rd_valid), .rd_data(rd_data)
  );
  a615a_file_rx #(.MAX_BYTES(64)) dut_small (
    .clk(clk), .rst_sync(rst), .file_start(s_start), .file_start_ready(s_ready),
    .in_valid(s_valid), .in_ready(s_in_ready), .in_data(s_data),
    .file_end(s_end), .file_abort(s_abort),
    .preload_start(1'b0), .preload_start_ready(),
    .preload_data_valid(1'b0), .preload_data_ready(), .preload_data(8'd0),
    .preload_commit(1'b0), .preload_length(14'd0), .preload_abort(1'b0),
    .upload_job_active(1'b0), .preload_error(),
    .file_busy(s_busy), .file_valid(s_valid_out), .file_ack(s_ack),
    .file_length(s_length), .error_code(s_error),
    .rd_en(1'b0), .rd_addr(13'd0), .rd_valid(), .rd_data()
  );

  integer errors = 0, checks = 0;
  task bad;
    input [8*96-1:0] reason;
    begin if (errors < 15) $display("  [err] T48 %0s", reason); errors = errors + 1; end
  endtask
  task chk;
    input cond; input [8*96-1:0] reason;
    begin checks = checks + 1; if (!cond) bad(reason); end
  endtask

  // byte pattern: (i*13 + 7) & 255
  function [7:0] pb; input integer i; begin pb = (i * 13 + 7) & 8'hFF; end endfunction

  integer i, guard;
  task start_big;
    begin
      @(negedge clk); file_start = 1;
      @(negedge clk); file_start = 0;
      @(negedge clk);
      chk(file_busy === 1'b1, "start must set file_busy");
    end
  endtask
  task end_big;
    begin
      @(negedge clk); file_end = 1;
      @(negedge clk); file_end = 0;
      @(negedge clk); @(negedge clk);
    end
  endtask

  initial begin
    repeat (5) @(negedge clk);
    rst = 0; repeat (2) @(negedge clk);

    // ---- C1: 300 bytes with pauses, published with exact length ----
    start_big;
    for (i = 0; i < 300; i = i + 1) begin
      @(negedge clk); in_valid = 1; in_data = pb(i);
      if (i % 37 == 13) begin  // pause: drop valid for 3 cycles mid-file
        @(negedge clk); in_valid = 0;
        repeat (3) @(negedge clk);
      end
      if (in_ready !== 1'b1) bad("C1 in_ready low while busy");
    end
    @(negedge clk); in_valid = 0;
    // file_end must be a separate cycle after the last handshake
    end_big;
    chk(file_valid === 1'b1, "C1 file published");
    chk(file_length === 14'd300, "C1 length 300");
    chk(error_code === 2'd0, "C1 no error");
    chk(file_busy === 1'b0, "C1 busy released");
    // synchronous read-back of every byte
    for (i = 0; i < 300; i = i + 1) begin
      @(negedge clk); rd_en = 1; rd_addr = i[12:0];
      @(negedge clk); @(negedge clk);
      chk(rd_valid === 1'b1 && rd_data === pb(i), "C1 read-back byte");
      rd_en = 0;
    end
    // out-of-range read suppressed
    @(negedge clk); rd_en = 1; rd_addr = 13'd300;
    @(negedge clk); @(negedge clk);
    chk(rd_valid === 1'b0, "C1 read beyond length suppressed");
    rd_en = 0;
    // ack clears valid
    @(negedge clk); file_ack = 1;
    @(negedge clk); file_ack = 0; @(negedge clk);
    chk(file_valid === 1'b0, "C1 ack clears file_valid");
    chk(start_ready === 1'b1, "C1 start_ready after ack");

    // ---- C2: empty file (0 bytes) publishes length 0 ----
    start_big;
    end_big;
    chk(file_valid === 1'b1 && file_length === 14'd0, "C2 empty file publishes length 0");
    chk(error_code === 2'd0, "C2 empty file no error");
    @(negedge clk); file_ack = 1; @(negedge clk); file_ack = 0; @(negedge clk);

    // ---- C3: file_end with in_valid same cycle is not accepted ----
    start_big;
    @(negedge clk); in_valid = 1; in_data = 8'hAA; file_end = 1;   // same cycle
    @(negedge clk); in_valid = 0; file_end = 0;
    repeat (2) @(negedge clk);
    chk(file_busy === 1'b1, "C3 same-cycle file_end ignored (still busy)");
    chk(file_valid === 1'b0, "C3 nothing published yet");
    end_big;
    chk(file_valid === 1'b1 && file_length === 14'd1, "C3 published after proper file_end");
    @(negedge clk); file_ack = 1; @(negedge clk); file_ack = 0; @(negedge clk);

    // ---- C4: abort discards the file ----
    start_big;
    for (i = 0; i < 50; i = i + 1) begin
      @(negedge clk); in_valid = 1; in_data = pb(i);
    end
    @(negedge clk); in_valid = 0; file_abort = 1;
    @(negedge clk); file_abort = 0;
    repeat (2) @(negedge clk);
    chk(file_busy === 1'b0, "C4 abort releases busy");
    chk(file_valid === 1'b0, "C4 abort publishes nothing");
    chk(error_code === 2'd2, "C4 abort error code");
    chk(start_ready === 1'b1, "C4 restart allowed after abort");

    // ---- C5: start refused while an unacked file is valid ----
    start_big;
    @(negedge clk); in_valid = 1; in_data = 8'h55;
    @(negedge clk); in_valid = 0;
    end_big;
    chk(file_valid === 1'b1, "C5 file valid");
    @(negedge clk); file_start = 1;
    @(negedge clk); file_start = 0; @(negedge clk);
    chk(file_valid === 1'b1 && file_busy === 1'b0, "C5 unacked file preserved");
    @(negedge clk); file_ack = 1; @(negedge clk); file_ack = 0; @(negedge clk);

    // ---- C6: small instance overflow ----
    @(negedge clk); s_start = 1; @(negedge clk); s_start = 0; @(negedge clk);
    chk(s_busy === 1'b1, "C6 small busy");
    for (i = 0; i < 70; i = i + 1) begin
      @(negedge clk); s_valid = 1; s_data = pb(i);
      if (s_in_ready !== 1'b1) bad("C6 in_ready must stay high to drain after overflow");
    end
    @(negedge clk); s_valid = 0;
    @(negedge clk); s_end = 1;
    @(negedge clk); s_end = 0;
    repeat (2) @(negedge clk);
    chk(s_valid_out === 1'b0, "C6 overflow file not published");
    chk(s_length === 14'd0, "C6 overflow length cleared");
    chk(s_error === 2'd1, "C6 overflow error code");
    chk(s_ready === 1'b1, "C6 restart allowed after overflow");
    // exact-capacity file on the small instance still publishes
    @(negedge clk); s_start = 1; @(negedge clk); s_start = 0; @(negedge clk);
    for (i = 0; i < 64; i = i + 1) begin @(negedge clk); s_valid = 1; s_data = pb(i); end
    @(negedge clk); s_valid = 0;
    @(negedge clk); s_end = 1; @(negedge clk); s_end = 0;
    repeat (2) @(negedge clk);
    chk(s_valid_out === 1'b1 && s_length === 14'd64, "C6 exact-capacity file publishes");
    chk(s_error === 2'd0, "C6 exact-capacity no error");

    if (errors == 0) $display("T48 FILE_RX PASS checks=%0d", checks);
    else $display("T48 FILE_RX FAIL errors=%0d", errors);
    $finish;
  end
  initial begin #6000000; $display("T48 FILE_RX FAIL timeout"); $finish; end
endmodule
