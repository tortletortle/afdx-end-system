// =====================================================================
// T53 — tx_pmem_byte_reader 字节通道读取（P03，2026-10-10）
//
// 覆盖：字节顺序（块内大端、跨字/跨块边界）、读延迟（issue→capture→emit）、
// 停顿保持（字内 byte_ready=0 时 data/last/valid 稳定）、结束
// （byte_last 与 done）、取消（复位）、非法参数（len=0/>8192、块数不匹配、
// 重复块、块号>5、块数为 0）的 start_error。PMEM 模型 6 块×512 字。
// =====================================================================
`timescale 1 ns / 1 ps
module tb_t53_byte_reader;
  reg clk = 0;
  always #4 clk = ~clk;
  reg rst = 1, start = 0;
  reg [13:0] start_len = 0;
  reg [2:0] start_block_count = 0;
  reg [15:0] start_blocks = 0;
  wire start_error;
  wire pmem_rd_en;
  wire [12:0] pmem_rd_addr;
  reg [31:0] pmem_rd_data = 0;
  reg byte_ready = 0;
  wire start_ready_w, byte_valid_w, byte_last_w, done_w;
  wire [7:0] byte_data_w;

  tx_pmem_byte_reader dut (
    .clk(clk), .rst_sync(rst), .start(start), .start_ready(start_ready_w),
    .start_len(start_len), .start_block_count(start_block_count),
    .start_blocks(start_blocks), .start_error(start_error),
    .pmem_rd_en(pmem_rd_en), .pmem_rd_addr(pmem_rd_addr),
    .pmem_rd_data(pmem_rd_data), .byte_valid(byte_valid_w),
    .byte_ready(byte_ready), .byte_data(byte_data_w), .byte_last(byte_last_w),
    .done(done_w)
  );

  // PMEM model: 6 blocks x 512 words, sync read with 1-cycle latency.
  reg [31:0] mem [0:6*512-1];
  always @(posedge clk) if (pmem_rd_en) pmem_rd_data <= mem[pmem_rd_addr];

  integer errors = 0, checks = 0;
  task bad;
    input [8*96-1:0] reason;
    begin if (errors < 15) $display("  [err] T53 %0s", reason); errors = errors + 1; end
  endtask
  task chk;
    input cond; input [8*96-1:0] reason;
    begin checks = checks + 1; if (!cond) bad(reason); end
  endtask

  // Independent expected byte: block b word w lane l = (b*37 + w*5 + l) & 0xFF
  function [7:0] expb;
    input integer b; input integer w; input integer l;
    begin expb = (b * 37 + w * 5 + l) & 8'hFF; end
  endfunction
  integer b, w, l;
  task fill_mem;
    begin
      for (b = 0; b < 6; b = b + 1)
        for (w = 0; w < 512; w = w + 1)
          mem[b*512+w] = {expb(b,w,0), expb(b,w,1), expb(b,w,2), expb(b,w,3)};
    end
  endtask

  integer i, guard, got, blk_i, wi, li;
  reg [7:0] sd;
  reg sl, vseen;
  task run_read;
    input integer len;
    input [2:0] nblk;
    input [15:0] blocks;
    input integer stall_every;   // 每 N 字节做一次 3 拍停顿（N=0 不停顿；取奇数落在字内）
    integer k;
    begin
      start_len = len[13:0]; start_block_count = nblk; start_blocks = blocks;
      @(negedge clk); start = 1;
      @(negedge clk); start = 0;
      @(negedge clk);
      chk(start_error === 1'b0, "unexpected start_error");
      k = 0; guard = 0;
      while (k < len && guard < 80000) begin
        if (byte_valid_w === 1'b1 && byte_ready === 1'b1) begin
          blk_i = k / 2048;
          wi = (k % 2048) / 4;
          li = k % 4;
          chk(byte_data_w === expb(blocks[4*blk_i +: 4], wi, li), "byte stream mismatch");
          chk(byte_last_w === (k == len-1), "byte_last position");
          k = k + 1;
          if (stall_every != 0 && (k % stall_every) == 0 && k < len) begin
            // 字内停顿：先清 ready，再逐拍核对 data/last 保持不变
            byte_ready = 0;
            vseen = 0;
            repeat (3) begin
              @(negedge clk);
              if (byte_valid_w === 1'b1) begin
                if (vseen)
                  chk(byte_data_w === sd && byte_last_w === sl, "hold during stall");
                sd = byte_data_w; sl = byte_last_w; vseen = 1;
              end
            end
            chk(vseen === 1, "valid must hold during mid-word stall");
            byte_ready = 1;
          end
        end
        guard = guard + 1;
        @(negedge clk);
      end
      chk(k == len, "delivered byte count");
      guard = 0; got = 0;
      while (!got && guard < 100) begin
        if (done_w === 1'b1) got = 1;
        guard = guard + 1;
        @(negedge clk);
      end
      chk(got === 1, "done pulse");
      @(negedge clk);
    end
  endtask

  integer ge;
  task run_bad;
    input integer len;
    input [2:0] nblk;
    input [15:0] blocks;
    begin
      start_len = len[13:0]; start_block_count = nblk; start_blocks = blocks;
      @(negedge clk); start = 1;
      @(negedge clk); start = 0;
      ge = 0;
      while (start_error !== 1'b1 && ge < 50) begin @(negedge clk); ge = ge + 1; end
      chk(start_error === 1'b1, "expected start_error");
      chk(byte_valid_w === 1'b0, "no bytes on illegal start");
      @(negedge clk); @(negedge clk);
    end
  endtask

  initial begin
    fill_mem;
    repeat (5) @(negedge clk);
    rst = 0; repeat (2) @(negedge clk);
    byte_ready = 1;
    chk(start_ready_w === 1'b1, "start_ready after reset");

    // C1: 8 bytes inside one block
    run_read(8, 3'd1, 16'h0001, 0);
    // C2: exactly one block
    run_read(2048, 3'd1, 16'h0002, 0);
    // C3: one byte past a block boundary
    run_read(2049, 3'd2, 16'h0012, 0);
    // C4: two blocks with mid-word stalls
    run_read(4096, 3'd2, 16'h0034, 513);
    // C5: four blocks, max length, stalls
    run_read(8192, 3'd4, 16'h5043, 1025);
    // C6: non-contiguous block list order honoured (block 0 then 3)
    run_read(2049, 3'd2, 16'h0030, 0);

    // errors: len 0 / len > 8192 / count mismatch / duplicate / block>5 / count 0
    run_bad(0, 3'd1, 16'h0001);
    run_bad(8193, 3'd5, 16'h0001);
    run_bad(100, 3'd3, 16'h0001);
    run_bad(100, 3'd2, 16'h0011);
    run_bad(100, 3'd1, 16'h0006);
    run_bad(100, 3'd0, 16'h0001);

    // C7: cancel by reset mid-stream; a fresh read still works
    start_len = 14'd100; start_block_count = 3'd1; start_blocks = 16'h0004;
    @(negedge clk); start = 1; @(negedge clk); start = 0;
    repeat (10) @(negedge clk);
    rst = 1; repeat (3) @(negedge clk); rst = 0; repeat (2) @(negedge clk);
    chk(byte_valid_w === 1'b0, "no bytes after mid-stream reset");
    run_read(16, 3'd1, 16'h0005, 0);

    if (errors == 0) $display("T53 BYTE_READER PASS checks=%0d", checks);
    else $display("T53 BYTE_READER FAIL errors=%0d", errors);
    $finish;
  end
  initial begin #8000000; $display("T53 BYTE_READER FAIL timeout"); $finish; end
endmodule
