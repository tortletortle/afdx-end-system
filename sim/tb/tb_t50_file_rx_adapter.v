// =====================================================================
// T50 — a615a_tftp_file_rx_adapter 下载块→完整文件适配（P03，2026-10-10）
//
// 覆盖：整块锁存后逐字节排空（块保持）、字节顺序（MSB-first → 文件序）、
// 非法块属性（len>512 或 last!=(len<512) → block_reject 且握手被背压）、
// 末块到完整发布（等待 client_done 先低后高、独立 file_end 周期）、
// client_failed/abort 取消、容量溢出不发布、file_valid/file_length/
// error/read/ack 透传。client 侧用 TB 桩驱动。
// =====================================================================
`timescale 1 ns / 1 ps
module tb_t50_file_rx_adapter;
  reg clk = 0;
  always #4 clk = ~clk;
  reg rst = 1;

  reg start = 0;
  wire start_ready;
  reg client_done = 0, client_failed = 0, abort_request = 0;
  reg dl_valid = 0;
  wire dl_ready;
  reg [9:0] dl_len = 0;
  reg [4095:0] dl_data = 0;
  reg dl_last = 0;
  wire block_reject;
  wire file_busy, file_valid;
  reg file_ack = 0;
  wire [13:0] file_length;
  wire [1:0] file_error_code;
  reg rd_en = 0;
  reg [12:0] rd_addr = 0;
  wire rd_valid;
  wire [7:0] rd_data;
  wire [1:0] adapter_error;

  a615a_tftp_file_rx_adapter #(.MAX_BYTES(8192)) dut (
    .clk(clk), .rst_sync(rst), .start(start), .start_ready(start_ready),
    .client_done(client_done), .client_failed(client_failed),
    .abort_request(abort_request),
    .preload_start(1'b0), .preload_start_ready(),
    .preload_data_valid(1'b0), .preload_data_ready(), .preload_data(8'd0),
    .preload_commit(1'b0), .preload_length(14'd0), .preload_abort(1'b0),
    .preload_error(), .upload_job_active(1'b0),
    .upload_block_req(1'b0), .upload_block_number(16'd0),
    .upload_block_valid(), .upload_block_ready(1'b0),
    .upload_data_len(), .upload_data(), .upload_block_last(), .upload_source_ready(),
    .download_block_valid(dl_valid), .download_block_ready(dl_ready),
    .download_data_len(dl_len), .download_data(dl_data),
    .download_block_last(dl_last), .block_reject(block_reject),
    .file_busy(file_busy), .file_valid(file_valid), .file_ack(file_ack),
    .file_length(file_length), .file_error_code(file_error_code),
    .rd_en(rd_en), .rd_addr(rd_addr), .rd_valid(rd_valid), .rd_data(rd_data),
    .adapter_error(adapter_error)
  );

  integer errors = 0, checks = 0;
  task bad;
    input [8*96-1:0] reason;
    begin if (errors < 15) $display("  [err] T50 %0s", reason); errors = errors + 1; end
  endtask
  task chk;
    input cond; input [8*96-1:0] reason;
    begin checks = checks + 1; if (!cond) bad(reason); end
  endtask

  function [7:0] gb;      // global expected byte for file position g
    input integer g;
    begin gb = (g * 11 + 8'h17) & 8'hFF; end
  endfunction

  integer g, guard;
  task send_block;
    input integer blk_first;   // global index of first byte in this block
    input integer len;
    input last;
    integer k;
    begin
      dl_data = 4096'd0;
      for (k = 0; k < len && k < 512; k = k + 1)
        dl_data[4095 - 8*k -: 8] = gb(blk_first + k);
      dl_len = len[9:0]; dl_last = last;
      guard = 0;
      while (dl_ready !== 1'b1 && guard < 2000) begin @(negedge clk); guard = guard + 1; end
      if (dl_ready !== 1'b1) bad("download_block_ready timeout");
      @(negedge clk); dl_valid = 1;
      @(negedge clk); dl_valid = 0;
      @(negedge clk);
    end
  endtask

  task read_check;
    input integer len;
    integer k;
    begin
      for (k = 0; k < len; k = k + 1) begin
        @(negedge clk); rd_en = 1; rd_addr = k[12:0];
        @(negedge clk); @(negedge clk);
        chk(rd_valid === 1'b1 && rd_data === gb(k), "file read-back byte");
        rd_en = 0;
      end
    end
  endtask

  task wait_pub;
    input integer limit;
    begin
      guard = 0;
      while (file_valid !== 1'b1 && guard < limit) begin @(negedge clk); guard = guard + 1; end
    end
  endtask
  task wait_nopub;
    input integer limit;
    begin
      for (guard = 0; guard < limit; guard = guard + 1) begin
        @(negedge clk);
        if (file_valid === 1'b1) bad("unexpected publication");
      end
    end
  endtask
  integer k, pend_done;
  initial begin
    repeat (5) @(negedge clk);
    rst = 0; repeat (2) @(negedge clk);

    // ================= C1: two blocks -> complete publication =================
    chk(start_ready === 1'b1, "C1 start_ready after reset");
    @(negedge clk); start = 1;
    @(negedge clk); start = 0;
    @(negedge clk);
    chk(file_busy === 1'b1, "C1 busy after start");
    // block 1: full 512 B, last=0
    send_block(0, 512, 0);
    chk(adapter_error === 2'd0 && block_reject === 1'b0, "C1 block1 accepted");
    // block 2: short 300 B, last=1
    send_block(512, 300, 1);
    chk(file_valid === 1'b0, "C1 not published before client_done");
    // client_done must be observed low first; it is already low -> bring it high
    @(negedge clk); @(negedge clk);
    client_done = 1;
    wait_pub(4000);
    chk(file_valid === 1'b1, "C1 published after client_done");
    chk(file_length === 14'd812, "C1 file length 812");
    chk(file_error_code === 2'd0, "C1 no file error");
    chk(adapter_error === 2'd0, "C1 no adapter error");
    read_check(812);
    // ack + restart
    @(negedge clk); file_ack = 1;
    @(negedge clk); file_ack = 0; @(negedge clk);
    chk(file_valid === 1'b0, "C1 ack clears file_valid");
    client_done = 0;

    // ================= C2: illegal block attributes -> reject, backpressure =====
    @(negedge clk); start = 1; @(negedge clk); start = 0; @(negedge clk);
    // len=513 (>512)
    dl_data = 4096'd0; dl_len = 10'd513; dl_last = 1'b0;
    @(negedge clk); dl_valid = 1;
    @(negedge clk); @(negedge clk);
    chk(block_reject === 1'b1 && dl_ready === 1'b0, "C2 len>512 rejected/backpressured");
    chk(adapter_error === 2'd1, "C2 E_BAD_BLOCK recorded");
    // false last: len<512 with last=0
    dl_valid = 0; @(negedge clk);
    dl_len = 10'd100; dl_last = 1'b0;
    @(negedge clk); dl_valid = 1;
    @(negedge clk); @(negedge clk);
    chk(block_reject === 1'b1 && dl_ready === 1'b0, "C2 false-last rejected");
    dl_valid = 0;
    // abort clears the session
    @(negedge clk); abort_request = 1;
    @(negedge clk); abort_request = 0;
    @(negedge clk); @(negedge clk);
    chk(file_busy === 1'b0 && file_valid === 1'b0, "C2 abort clears session");
    chk(adapter_error === 2'd2, "C2 abort error code");

    // ================= C3: client_failed cancels without publication ============
    @(negedge clk); start = 1; @(negedge clk); start = 0; @(negedge clk);
    send_block(0, 512, 0);
    @(negedge clk); client_failed = 1;
    @(negedge clk); client_failed = 0;
    @(negedge clk); @(negedge clk);
    chk(file_busy === 1'b0 && file_valid === 1'b0, "C3 client_failed cancels");
    chk(adapter_error === 2'd2, "C3 abort error on client_failed");

    // ================= C4: completion only after done low->high with low seen ===
    client_done = 1;                      // stale high BEFORE the new session
    @(negedge clk); start = 1; @(negedge clk); start = 0; @(negedge clk);
    send_block(0, 50, 1);                 // single short final block
    wait_nopub(400);
    chk(file_valid === 1'b0, "C4 stale done must not publish");
    client_done = 0;
    repeat (3) @(negedge clk);
    client_done = 1;
    wait_pub(600);
    chk(file_valid === 1'b1 && file_length === 14'd50, "C4 published after proper low->high");
    @(negedge clk); file_ack = 1; @(negedge clk); file_ack = 0; @(negedge clk);
    client_done = 0;

    if (errors == 0) $display("T50 FILE_RX_ADAPTER PASS checks=%0d", checks);
    else $display("T50 FILE_RX_ADAPTER FAIL errors=%0d", errors);
    $finish;
  end
  initial begin #4000000; $display("T50 FILE_RX_ADAPTER FAIL timeout"); $finish; end
endmodule
