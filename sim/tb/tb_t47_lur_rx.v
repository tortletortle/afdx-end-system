// =====================================================================
// T47 — a615a_lur_rx 受限 LUR 文件解析（P03，2026-10-10）
//
// 覆盖：完整文件边界（SOP/EOP 包整文件）、条目/字符串长度（含 NUL）、
// NUL 终止强制、可打印字符集、完整文件容量（声明长度=实际长度）、
// 条目计数 1..MAX_FILES、失败后重新解析、结果保持到 ack、名称/部件号
// 逐字节读取与越界抑制、overflow 拒绝。预期字节由 TB 独立构造。
// =====================================================================
`timescale 1 ns / 1 ps
module tb_t47_lur_rx;
  reg clk = 0;
  always #4 clk = ~clk;
  reg rst = 1;
  reg [15:0] expected_version = 16'h4134;
  reg in_valid = 0, in_sop = 0, in_eop = 0;
  wire in_ready;
  reg [7:0] in_data = 0;
  wire result_valid, request_ok;
  reg result_ack = 0;
  wire [3:0] error_code;
  wire [15:0] file_count;
  reg [2:0] file_select = 0;
  wire [7:0] filename_length, part_number_length;
  reg name_read = 0, select_part_number = 0;
  reg [7:0] name_byte_index = 0;
  wire [7:0] name_byte;
  wire name_byte_valid;

  a615a_lur_rx #(.MAX_FILES(8)) dut (
    .clk(clk), .rst_sync(rst), .expected_version(expected_version),
    .in_valid(in_valid), .in_ready(in_ready), .in_sop(in_sop), .in_eop(in_eop),
    .in_data(in_data), .result_valid(result_valid), .result_ack(result_ack),
    .request_ok(request_ok), .error_code(error_code), .file_count(file_count),
    .file_select(file_select), .filename_length(filename_length),
    .part_number_length(part_number_length), .name_read(name_read),
    .select_part_number(select_part_number), .name_byte_index(name_byte_index),
    .name_byte(name_byte), .name_byte_valid(name_byte_valid)
  );

  integer errors = 0, checks = 0;
  task bad;
    input [8*96-1:0] reason;
    begin if (errors < 15) $display("  [err] T47 %0s", reason); errors = errors + 1; end
  endtask
  task chk;
    input cond; input [8*96-1:0] reason;
    begin checks = checks + 1; if (!cond) bad(reason); end
  endtask

  // ---------------- independent file builder ----------------
  reg [7:0] fb [0:8200];
  integer fn;
  task fb_clear; begin fn = 0; end endtask
  task fb_put; input [7:0] b; begin fb[fn] = b; fn = fn + 1; end endtask
  task fb_put16; input [15:0] v; begin fb_put(v[15:8]); fb_put(v[7:0]); end endtask
  task fb_put32; input [31:0] v; begin fb_put(v[31:24]); fb_put(v[23:16]); fb_put(v[15:8]); fb_put(v[7:0]); end endtask
  task fb_name; input integer n; // n includes the NUL, bytes filled by caller via fb chars
    begin fb_put(n & 255); end
  endtask

  task build_valid2;
    begin
      fb_clear;
      fb_put32(25);              // declared total = 25
      fb_put16(16'h4134);
      fb_put16(2);
      fb_put(8'd3); fb_put("A"); fb_put("B"); fb_put(8'h00);
      fb_put(8'd3); fb_put("P"); fb_put("1"); fb_put(8'h00);
      fb_put(8'd4); fb_put("C"); fb_put("D"); fb_put("E"); fb_put(8'h00);
      fb_put(8'd3); fb_put("P"); fb_put("Q"); fb_put(8'h00);
    end
  endtask

  task send_file;
    input integer n;
    integer i;
    begin
      for (i = 0; i < n; i = i + 1) begin
        @(negedge clk); in_valid = 1; in_sop = (i == 0); in_eop = (i == n-1); in_data = fb[i];
        if (in_ready !== 1'b1) bad("in_ready low during file");
      end
      @(negedge clk); in_valid = 0; in_sop = 0; in_eop = 0;
    end
  endtask

  integer guard;
  task wait_result;
    begin
      guard = 0;
      while (result_valid !== 1'b1 && guard < 200000) begin @(negedge clk); guard = guard + 1; end
      if (result_valid !== 1'b1) bad("result_valid timeout");
    end
  endtask

  task ack_result;
    begin
      @(negedge clk); result_ack = 1;
      @(negedge clk); result_ack = 0;
      @(negedge clk);
      chk(result_valid === 1'b0, "result cleared after ack");
    end
  endtask

  task read_name;
    input [2:0] sel; input sel_part; input [7:0] idx; output [7:0] got; output integer valid;
    begin
      @(negedge clk);
      file_select = sel; name_read = 1; select_part_number = sel_part; name_byte_index = idx;
      @(negedge clk); @(negedge clk);
      got = name_byte; valid = name_byte_valid;
      @(negedge clk); name_read = 0;
    end
  endtask

  reg [7:0] got; integer vld;
  integer i;
  initial begin
    repeat (5) @(negedge clk);
    rst = 0; repeat (2) @(negedge clk);

    // ---- C1: valid 2-entry file -> OK, count=2, byte reads ----
    build_valid2; send_file(fn); wait_result;
    chk(error_code === 4'd0, "C1 error_code=0");
    chk(file_count === 16'd2, "C1 file_count=2");
    chk(request_ok === 1'b1, "C1 request_ok");
    chk(filename_length === 8'd3, "C1 entry0 name length 3");
    chk(part_number_length === 8'd3, "C1 entry0 part length 3");
    read_name(3'd0, 1'b0, 8'd0, got, vld); chk(vld === 1 && got === "A", "C1 entry0 name[0]");
    read_name(3'd0, 1'b0, 8'd1, got, vld); chk(vld === 1 && got === "B", "C1 entry0 name[1]");
    read_name(3'd0, 1'b0, 8'd2, got, vld); chk(vld === 1 && got === 8'h00, "C1 entry0 name NUL");
    read_name(3'd0, 1'b0, 8'd3, got, vld); chk(vld === 0, "C1 entry0 name over-length suppressed");
    read_name(3'd0, 1'b1, 8'd0, got, vld); chk(vld === 1 && got === "P", "C1 entry0 part[0]");
    read_name(3'd0, 1'b1, 8'd1, got, vld); chk(vld === 1 && got === "1", "C1 entry0 part[1]");
    read_name(3'd1, 1'b0, 8'd3, got, vld); chk(vld === 1 && got === 8'h00, "C1 entry1 name NUL");
    read_name(3'd2, 1'b0, 8'd0, got, vld); chk(vld === 0, "C1 select beyond count suppressed");
    ack_result;

    // ---- C2: file version mismatch -> E_VERSION(2) ----
    build_valid2; fb[5] = 8'h33;   // version low byte differs from expected 0x34
    send_file(fn); wait_result;
    chk(error_code === 4'd2, "C2 E_VERSION");
    chk(file_count === 16'd0, "C2 count cleared on reject");
    chk(request_ok === 1'b0, "C2 request_ok low on reject");
    ack_result;

    // ---- C3: unsupported expected_version -> E_VERSION ----
    expected_version = 16'h4234;
    build_valid2; send_file(fn); wait_result;
    chk(error_code === 4'd2, "C3 unsupported expected version");
    ack_result;
    expected_version = 16'h4134; repeat (2) @(negedge clk);

    // ---- C4: declared length mismatch -> E_LENGTH(1) ----
    build_valid2; fb[3] = 8'd26;   // declared 26 != actual 25
    send_file(fn); wait_result;
    chk(error_code === 4'd1, "C4 E_LENGTH");
    ack_result;

    // ---- C5: count 0 / count over MAX_FILES -> E_COUNT(3) ----
    build_valid2; fb[6] = 8'h00; fb[7] = 8'h00;
    send_file(fn); wait_result;
    chk(error_code === 4'd3, "C5 count=0 E_COUNT");
    ack_result;
    build_valid2; fb[7] = 8'd9;
    send_file(fn); wait_result;
    chk(error_code === 4'd3, "C5 count=9 E_COUNT");
    ack_result;

    // ---- C6: string violations -> E_STRING(4) ----
    build_valid2; fb[8] = 8'd1;    // name length 1 (<2)
    send_file(fn); wait_result;
    chk(error_code === 4'd4, "C6 name length <2 E_STRING");
    ack_result;
    build_valid2; fb[10] = 8'h1F;  // non-printable name byte
    send_file(fn); wait_result;
    chk(error_code === 4'd4, "C6 non-printable E_STRING");
    ack_result;
    build_valid2; fb[11] = 8'h58;  // last name byte not NUL
    send_file(fn); wait_result;
    chk(error_code === 4'd4, "C6 missing NUL E_STRING");
    ack_result;

    // ---- C7: truncated file (<8 bytes) -> E_TRUNCATED(5) ----
    fb_clear; fb_put(8'h00); fb_put(8'h00); fb_put(8'h00); fb_put(8'h04);
    send_file(fn); wait_result;
    chk(error_code === 4'd5, "C7 E_TRUNCATED");
    ack_result;

    // ---- C8: trailing byte after complete last entry -> E_TRAILING(8) ----
    build_valid2; fb[fn] = 8'h00; fn = fn + 1; fb[3] = 8'd26;  // declared matches new total
    send_file(fn); wait_result;
    chk(error_code === 4'd8, "C8 E_TRAILING");
    ack_result;

    // ---- C9: overflow (>8192) -> E_OVERFLOW(6) ----
    fb_clear;
    for (i = 0; i < 8193; i = i + 1) fb_put((i * 5 + 1) & 255);
    send_file(8193); wait_result;
    chk(error_code === 4'd6, "C9 E_OVERFLOW");
    ack_result;

    // ---- C10: recovery — valid file parses again after all failures ----
    build_valid2; send_file(fn); wait_result;
    chk(error_code === 4'd0 && file_count === 16'd2, "C10 recovery OK");
    ack_result;

    if (errors == 0) $display("T47 LUR_RX PASS checks=%0d", checks);
    else $display("T47 LUR_RX FAIL errors=%0d", errors);
    $finish;
  end
  initial begin #6000000; $display("T47 LUR_RX FAIL timeout"); $finish; end
endmodule
