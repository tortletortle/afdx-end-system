// =====================================================================
// T49 — a615a_tftp_client_1350 包级 TFTP 客户端核心（P03，2026-10-10）
//
// 覆盖：
//   A. RRQ 下载：RRQ → 首响应锁定 server TID → 块交付 → ACK → 重复块再
//      ACK → 错误对端（错 TID）回 ERROR(5) 且不扰动会话 → 末块（短块）→
//      dally 中重复末块再 ACK → dally 超时 done。
//   B. WRQ 上传：WRQ → ACK(0) 锁定 → 512B 块 → ACK → 512 整倍数末块 →
//      尾零块 DATA(len=0) → ACK → done。
//   C. 超时重传与耗尽：S_WAIT_FIRST 超时重发 RRQ（initial + MAX_RETRIES）
//      后 failed=E_TIMEOUT。
//   D. 块号回绕：连续块 1..0xFFFF、0 的交付与 ACK（末块短块收口）。
//   E. 非法启动（local_tid=0）→ E_BAD_START；再次合法启动可运行。
// =====================================================================
`timescale 1 ns / 1 ps
module tb_t49_tftp_client;
  reg clk = 0;
  always #4 clk = ~clk;
  reg rst = 1;

  reg start = 0, start_write = 0;
  reg [31:0] server_ip = 32'h0A000002;
  reg [15:0] local_tid = 16'h1234;
  reg [2047:0] filename = 0;
  reg [7:0] filename_len = 0;
  reg timeout_tick = 0;
  reg [15:0] timeout_ticks = 16'd8;

  reg rx_valid = 0;
  wire rx_ready;
  reg [31:0] rx_src_ip = 32'h0A000002;
  reg [15:0] rx_src_port = 16'd40100;
  reg [15:0] rx_dst_port = 16'h1234;
  reg [2:0] rx_opcode = 3'd3;
  reg [15:0] rx_block = 0;
  reg [9:0] rx_data_len = 0;
  reg [4095:0] rx_data = 0;
  reg [15:0] rx_error_code = 0;

  wire tx_valid, start_ready_w, upload_block_req, upload_block_ready;
  wire download_block_valid, peer_tid_valid, busy, done_w, failed_w;
  reg tx_ready = 1;
  reg download_block_ready = 0;
  reg upload_block_valid = 0;
  wire [15:0] upload_block_number;      // DUT output (requested block number)
  reg [9:0] upload_data_len = 0;
  reg [4095:0] upload_data = 0;
  reg upload_block_last = 0;

  wire [2:0] tx_opcode;
  wire [15:0] tx_block, tx_error_code, tx_dst_port, peer_tid;
  wire [9:0] tx_data_len;
  wire [4095:0] tx_data;
  wire [31:0] tx_dst_ip;
  wire [2047:0] tx_filename;
  wire [7:0] tx_filename_len;
  wire tx_mode_octet;
  wire [15:0] download_block_number;
  wire [9:0] download_data_len;
  wire [4095:0] download_data;
  wire download_block_last;
  wire [3:0] failure_code;
  wire [15:0] server_error_code;

  a615a_tftp_client_1350 #(.MAX_RETRIES(5)) dut (
    .clk(clk), .rst_sync(rst), .start(start), .start_ready(start_ready_w),
    .start_write(start_write), .server_ip(server_ip), .local_tid(local_tid),
    .filename(filename), .filename_len(filename_len),
    .timeout_tick(timeout_tick), .timeout_ticks(timeout_ticks),
    .rx_valid(rx_valid), .rx_ready(rx_ready), .rx_src_ip(rx_src_ip),
    .rx_src_port(rx_src_port), .rx_dst_port(rx_dst_port), .rx_opcode(rx_opcode),
    .rx_block(rx_block), .rx_data_len(rx_data_len), .rx_data(rx_data),
    .rx_error_code(rx_error_code),
    .tx_valid(tx_valid), .tx_ready(tx_ready), .tx_dst_ip(tx_dst_ip),
    .tx_src_port(), .tx_dst_port(tx_dst_port), .tx_opcode(tx_opcode),
    .tx_block(tx_block), .tx_error_code(tx_error_code), .tx_data_len(tx_data_len),
    .tx_data(tx_data), .tx_filename(tx_filename), .tx_filename_len(tx_filename_len),
    .tx_mode_octet(tx_mode_octet),
    .upload_block_req(upload_block_req), .upload_block_number(upload_block_number),
    .upload_block_valid(upload_block_valid), .upload_block_ready(upload_block_ready),
    .upload_data_len(upload_data_len), .upload_data(upload_data),
    .upload_block_last(upload_block_last),
    .download_block_valid(download_block_valid), .download_block_ready(download_block_ready),
    .download_block_number(download_block_number), .download_data_len(download_data_len),
    .download_data(download_data), .download_block_last(download_block_last),
    .peer_tid_valid(peer_tid_valid), .peer_tid(peer_tid),
    .busy(busy), .done(done_w), .failed(failed_w), .failure_code(failure_code),
    .server_error_code(server_error_code)
  );

  integer errors = 0, checks = 0;
  task bad;
    input [8*96-1:0] reason;
    begin if (errors < 20) $display("  [err] T49 %0s", reason); errors = errors + 1; end
  endtask
  task chk;
    input cond; input [8*96-1:0] reason;
    begin checks = checks + 1; if (!cond) bad(reason); end
  endtask

  // ---- TX fire log ----
  integer txn = 0, txbase = 0;
  reg [2:0] l_op; reg [15:0] l_blk; reg [9:0] l_len; reg [15:0] l_dp, l_ec;
  reg [4095:0] l_data;
  always @(posedge clk) begin
    if (tx_valid && tx_ready) begin
      txn = txn + 1; l_op = tx_opcode; l_blk = tx_block; l_len = tx_data_len;
      l_dp = tx_dst_port; l_data = tx_data; l_ec = tx_error_code;
    end
  end
  // end-pulse counters (single-driver observation)
  integer fail_cnt = 0, done_cnt = 0;
  always @(posedge clk) begin
    if (failed_w) fail_cnt = fail_cnt + 1;
    if (done_w)   done_cnt = done_cnt + 1;
  end
  integer fprev, dprev;

  function [7:0] datb;      // byte k of a packed array (byte 0 = MSB)
    input [4095:0] d; input integer k;
    begin datb = d[4095 - 8*k -: 8]; end
  endfunction
  function [7:0] fnb;       // byte k of the 2048-bit filename array (byte 0 = MSB)
    input [2047:0] d; input integer k;
    begin fnb = d[2047 - 8*k -: 8]; end
  endfunction

  integer guard;
  task tx_wait;
    begin
      guard = 0;
      while (txn == txbase && guard < 8000) begin @(negedge clk); guard = guard + 1; end
      if (guard >= 8000) bad("TX fire timeout");
    end
  endtask

  task rx_send;             // one complete datagram; fill=1 populates payload
    input [15:0] sp; input [2:0] op; input [15:0] blk; input integer len;
    input [15:0] ecode; input integer fill;
    integer k;
    begin
      guard = 0;
      while (rx_ready !== 1'b1 && guard < 8000) begin @(negedge clk); guard = guard + 1; end
      if (rx_ready !== 1'b1) bad("rx_ready timeout");
      if (fill != 0) begin
        rx_data = 4096'd0;
        for (k = 0; k < len && k < 512; k = k + 1)
          rx_data[4095 - 8*k -: 8] = (k * 7 + 8'h31) & 8'hFF;
      end
      @(negedge clk);
      rx_src_port = sp; rx_opcode = op; rx_block = blk; rx_data_len = len[9:0];
      rx_error_code = ecode; rx_valid = 1;
      @(negedge clk); rx_valid = 0;
      @(negedge clk);
    end
  endtask

  task sink_take;           // accept one delivered block (full checks by caller)
    integer g;
    begin
      g = 0;
      while (download_block_valid !== 1'b1 && g < 8000) begin @(negedge clk); g = g + 1; end
      if (download_block_valid !== 1'b1) bad("download block timeout");
      @(negedge clk); download_block_ready = 1;
      @(negedge clk); download_block_ready = 0;
    end
  endtask

  task sink_fast;           // fast accept used by the wrap stream
    integer g;
    begin
      g = 0;
      while (download_block_valid !== 1'b1 && g < 400) begin @(negedge clk); g = g + 1; end
      if (download_block_valid !== 1'b1) bad("wrap stream stall");
      @(negedge clk); download_block_ready = 1;
      @(negedge clk); download_block_ready = 0;
    end
  endtask

  integer ti;
  task pump_ticks;          // one clock per timeout unit
    input integer n;
    begin
      for (ti = 0; ti < n; ti = ti + 1) begin
        @(negedge clk); timeout_tick = 1;
        @(negedge clk); timeout_tick = 0;
      end
    end
  endtask

  task pump_until_tx;       // tick until the TX counter advances (or max ticks)
    input integer base; input integer maxn;
    begin
      ti = 0;
      while (ti < maxn && txn == base) begin
        @(negedge clk); timeout_tick = 1;
        @(negedge clk); timeout_tick = 0;
        ti = ti + 1;
      end
    end
  endtask

  task pump_until_fail;     // tick until a new failure pulse (or max ticks)
    input integer base; input integer maxn;
    begin
      ti = 0;
      while (ti < maxn && fail_cnt == base) begin
        @(negedge clk); timeout_tick = 1;
        @(negedge clk); timeout_tick = 0;
        ti = ti + 1;
      end
    end
  endtask

  task wait_settle;         // watch done/failed pulses for a few cycles
    input integer n;
    begin
      for (ti = 0; ti < n; ti = ti + 1) begin
        @(negedge clk);
      end
    end
  endtask

  task do_start;
    input wrmode;
    begin
      start_write = wrmode;
      @(negedge clk); start = 1;
      @(negedge clk); start = 0;
    end
  endtask

  integer b, t, c0;
  initial begin
    filename = 0;
    filename[2047 -: 8] = "F"; filename[2039 -: 8] = "W"; filename[2031 -: 8] = ".";
    filename[2023 -: 8] = "B"; filename[2015 -: 8] = "I"; filename[2007 -: 8] = "N";
    filename_len = 8'd6;

    repeat (5) @(negedge clk);
    rst = 0; repeat (2) @(negedge clk);

    // ================= A: RRQ download =================
    txbase = txn;
    do_start(1'b0);
    @(negedge clk);
    chk(busy === 1'b1 && start_ready_w === 1'b0, "A busy after start");
    tx_wait;
    chk(l_op === 3'd1, "A first TX is RRQ");
    chk(l_dp === 16'd69, "A RRQ to port 69 before TID lock");
    chk(tx_filename_len === 8'd6 && fnb(tx_filename, 0) === "F" && fnb(tx_filename, 5) === "N",
        "A RRQ filename bytes");
    chk(tx_mode_octet === 1'b1, "A octet mode");

    // first DATA locks the server TID
    txbase = txn;
    rx_send(16'd40100, 3'd3, 16'd1, 512, 16'd0, 1);
    sink_take;
    chk(download_block_number === 16'd1 && download_data_len === 10'd512
        && download_block_last === 1'b0, "A block1 delivered");
    chk(datb(download_data, 0) === 8'h31 && datb(download_data, 511) === ((511*7+8'h31)&8'hFF),
        "A block1 payload bytes");
    tx_wait;
    chk(l_op === 3'd4 && l_blk === 16'd1 && l_dp === 16'd40100, "A ACK(1) to locked TID");
    chk(peer_tid_valid === 1'b1 && peer_tid === 16'd40100, "A peer TID locked");

    // duplicate block 1 -> re-ACK, no sink delivery
    txbase = txn;
    rx_send(16'd40100, 3'd3, 16'd1, 512, 16'd0, 0);
    chk(download_block_valid === 1'b0, "A duplicate not re-delivered");
    tx_wait;
    chk(l_op === 3'd4 && l_blk === 16'd1, "A duplicate DATA re-ACK");

    // wrong-TID packet -> out-of-band ERROR(5), session untouched
    txbase = txn;
    rx_send(16'd55555, 3'd3, 16'd1, 512, 16'd0, 0);
    tx_wait;
    chk(l_op === 3'd5 && l_ec === 16'd5 && l_len === 10'd20, "A ERROR(5) descriptor");
    chk(l_dp === 16'd55555, "A ERROR(5) routed to stranger TID");
    chk(peer_tid === 16'd40100 && peer_tid_valid === 1'b1, "A session TID untouched");
    chk(datb(l_data, 0) === "U" && datb(l_data, 7) === 8'h20 && datb(l_data, 17) === "I"
        && datb(l_data, 19) === 8'h00, "A ERROR(5) exact 20-byte text");

    // final short block -> ACK then dally
    txbase = txn;
    rx_send(16'd40100, 3'd3, 16'd2, 100, 16'd0, 1);
    sink_take;
    chk(download_block_number === 16'd2 && download_block_last === 1'b1, "A final block delivered");
    tx_wait;
    chk(l_op === 3'd4 && l_blk === 16'd2, "A ACK(2) sent");

    // dally: duplicate final block re-ACKed, timer restarted
    txbase = txn;
    rx_send(16'd40100, 3'd3, 16'd2, 100, 16'd0, 0);
    tx_wait;
    chk(l_op === 3'd4 && l_blk === 16'd2, "A dally duplicate re-ACK");

    // dally timeout -> done
    dprev = done_cnt; fprev = fail_cnt;
    pump_ticks(12);
    wait_settle(4);
    chk(done_cnt > dprev && busy === 1'b0, "A done after dally timeout");
    chk(fail_cnt === fprev, "A no failure");

    // ================= B: WRQ upload (512-multiple zero tail) =================
    txbase = txn;
    do_start(1'b1);
    tx_wait;
    chk(l_op === 3'd2 && l_dp === 16'd69, "B first TX is WRQ");
    rx_send(16'd40200, 3'd4, 16'd0, 0, 16'd0, 0);
    @(negedge clk);
    chk(peer_tid === 16'd40200, "B server TID locked");
    // block 1: 512 B
    chk(upload_block_req === 1'b1 && upload_block_number === 16'd1, "B requests block 1");
    upload_data = 4096'd0;
    for (t = 0; t < 512; t = t + 1) upload_data[4095 - 8*t -: 8] = (t * 3 + 5) & 8'hFF;
    upload_data_len = 10'd512; upload_block_last = 0;
    txbase = txn;
    @(negedge clk); upload_block_valid = 1;
    @(negedge clk); upload_block_valid = 0;
    tx_wait;
    chk(l_op === 3'd3 && l_blk === 16'd1 && l_len === 10'd512, "B DATA(1) 512B");
    chk(datb(l_data, 0) === 8'h05 && datb(l_data, 511) === ((511*3+5)&8'hFF), "B DATA(1) bytes");
    rx_send(16'd40200, 3'd4, 16'd1, 0, 16'd0, 0);
    @(negedge clk);
    // block 2: 512 B and LAST -> zero tail block expected
    chk(upload_block_number === 16'd2, "B requests block 2");
    upload_data_len = 10'd512; upload_block_last = 1;
    txbase = txn;
    @(negedge clk); upload_block_valid = 1;
    @(negedge clk); upload_block_valid = 0;
    tx_wait;
    chk(l_op === 3'd3 && l_blk === 16'd2 && l_len === 10'd512, "B DATA(2) 512B last");
    rx_send(16'd40200, 3'd4, 16'd2, 0, 16'd0, 0);
    txbase = txn;
    tx_wait;
    chk(l_op === 3'd3 && l_blk === 16'd3 && l_len === 10'd0, "B zero tail DATA(3)");
    dprev = done_cnt;
    rx_send(16'd40200, 3'd4, 16'd3, 0, 16'd0, 0);
    wait_settle(4);
    chk(done_cnt > dprev && busy === 1'b0, "B done after final ACK");

    // ================= C: timeout retransmission and exhaustion =================
    txbase = txn;
    do_start(1'b0);
    tx_wait;
    chk(l_op === 3'd1, "C initial RRQ");
    c0 = txn;
    for (b = 0; b < 5; b = b + 1) begin
      txbase = txn;
      pump_until_tx(txbase, 40);
      chk(txn == txbase + 1 && l_op === 3'd1, "C RRQ retransmission");
    end
    chk(txn == c0 + 5, "C transmissions = initial + MAX_RETRIES");
    fprev = fail_cnt;
    pump_until_fail(fprev, 40);
    wait_settle(4);
    chk(fail_cnt > fprev && failure_code === 4'd2, "C failed E_TIMEOUT after retries");
    chk(busy === 1'b0, "C busy released on failure");

    // ================= E: illegal start then recovery =================
    fprev = fail_cnt;
    local_tid = 16'd0;
    do_start(1'b0);
    wait_settle(4);
    chk(fail_cnt > fprev && failure_code === 4'd1, "E E_BAD_START on zero TID");
    local_tid = 16'h2222;
    txbase = txn;
    do_start(1'b0);
    tx_wait;
    chk(l_op === 3'd1 && start_ready_w === 1'b0, "E RRQ after recovery");
    rx_dst_port = 16'h2222;      // session latched local_tid=0x2222

    // ================= D: block-number wrap 0xFFFE -> 0xFFFF -> 0 =================
    rx_send(16'd40300, 3'd3, 16'd1, 512, 16'd0, 0);
    sink_fast;
    @(negedge clk);
    for (b = 2; b <= 16'hFFFF; b = b + 1) begin
      rx_send(16'd40300, 3'd3, b[15:0], 512, 16'd0, 0);
      sink_fast;
      @(negedge clk);
    end
    txbase = txn;
    rx_send(16'd40300, 3'd3, 16'd0, 50, 16'd0, 0);
    sink_fast;
    chk(download_block_number === 16'd0 && download_block_last === 1'b1,
        "D wrapped block 0 accepted as final");
    tx_wait;
    chk(l_op === 3'd4 && l_blk === 16'd0, "D ACK(0) after wrap");
    dprev = done_cnt;
    pump_ticks(12);
    wait_settle(4);
    chk(done_cnt > dprev, "D done via dally after wrap");

    if (errors == 0) $display("T49 TFTP_CLIENT PASS checks=%0d tx=%0d", checks, txn);
    else $display("T49 TFTP_CLIENT FAIL errors=%0d", errors);
    $finish;
  end

  initial begin #80000000; $display("T49 TFTP_CLIENT FAIL timeout"); $finish; end
endmodule
