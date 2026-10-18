// =====================================================================
// T56 — a615a_fetch_engine：615A 主动取件单元级闭环（P05，2026-10-10）
//
// TB 扮演装载端（loader）：
//   * 包侧：消费引擎输出的 TFTP 请求/ACK（pkt_vld 读口），核对 RRQ 内容、
//     ACK 块号与目标端口；用 pkt_ack 释放，模拟管理发送路径送达。
//   * 字节侧：以固定 TID 向引擎 sap_* 口送入 DATA 响应（可停顿契约），
//     完成多块传输；核对下载到 file_rx 的完整文件（长度+逐字节）。
// 覆盖：作业发起/忙标志、RRQ→DATA→ACK 闭环、末块+dally→done、文件发布与
// 读回、ERROR 响应→failed+failure_code、失败后再启动、空闲期杂散响应排空。
// =====================================================================
`timescale 1 ns / 1 ps
module tb_t56_fetch_engine;
  reg clk = 0;
  always #4 clk = ~clk;
  reg rst = 1;

  // 作业配置
  reg         start = 0;
  wire        start_ready;
  reg  [31:0] server_ip = 32'h0A000002;
  reg  [15:0] local_tid = 16'h3001;
  reg  [2047:0] filename = 0;
  reg  [7:0]  filename_len = 8'd6;
  reg  [15:0] timeout_ticks = 16'd50;
  reg         timeout_tick = 0;
  reg         abort = 0;

  // 状态
  wire        busy, done, failed;
  wire [3:0]  failure_code;
  wire [31:0] rx_bytes;
  wire        file_busy, file_valid;
  reg         file_ack = 0;
  wire [13:0] file_length;
  wire [1:0]  file_error_code;
  reg         rd_en = 0;
  reg  [12:0] rd_addr = 0;
  wire        rd_valid;
  wire [7:0]  rd_data;
  wire [31:0] ok_cnt, drop_cnt;

  // SAP 字节侧（TB 发送）
  reg         sap_vld = 0, sap_sop = 0, sap_eop = 0;
  reg  [7:0]  sap_data = 0;
  reg  [15:0] sap_sport = 16'd40100, sap_dport = 16'h3001;
  reg  [31:0] sap_srcip = 32'h0A000002;
  wire        sap_ready;

  // 包侧（引擎输出）
  wire        pkt_vld;
  wire [10:0] pkt_len;
  wire [31:0] pkt_dst_ip;
  wire [15:0] pkt_src_port, pkt_dst_port;
  reg  [10:0] pkt_rd_addr = 0;
  wire [7:0]  pkt_byte;
  reg         pkt_ack = 0;

  a615a_fetch_engine dut (
    .clk(clk), .rst_sync(rst), .en(1'b1),
    .sap_vld(sap_vld), .sap_sop(sap_sop), .sap_eop(sap_eop), .sap_data(sap_data),
    .sap_sport(sap_sport), .sap_dport(sap_dport), .sap_srcip(sap_srcip),
    .sap_ready(sap_ready),
    .pkt_vld(pkt_vld), .pkt_len(pkt_len), .pkt_dst_ip(pkt_dst_ip),
    .pkt_src_port(pkt_src_port), .pkt_dst_port(pkt_dst_port),
    .pkt_rd_addr(pkt_rd_addr), .pkt_byte(pkt_byte), .pkt_ack(pkt_ack),
    .start(start), .start_ready(start_ready), .start_write(1'b0), .server_ip(server_ip),
    .preload_start(1'b0), .preload_data_valid(1'b0), .preload_data(8'd0),
    .preload_commit(1'b0), .preload_length(14'd0), .preload_abort(1'b0),
    .preload_start_ready(), .preload_data_ready(), .preload_error(),
    .upload_block_req(), .upload_block_number(),
    .local_tid(local_tid), .filename(filename), .filename_len(filename_len),
    .timeout_ticks(timeout_ticks), .timeout_tick(timeout_tick), .abort(abort),
    .busy(busy), .done(done), .failed(failed), .failure_code(failure_code),
    .rx_bytes(rx_bytes), .file_busy(file_busy), .file_valid(file_valid),
    .file_ack(file_ack), .file_length(file_length), .file_error_code(file_error_code),
    .rd_en(rd_en), .rd_addr(rd_addr), .rd_valid(rd_valid), .rd_data(rd_data),
    .ok_cnt(ok_cnt), .drop_cnt(drop_cnt)
  );

  integer errors = 0, checks = 0;
  task bad;
    input [8*96-1:0] reason;
    begin if (errors < 15) $display("  [err] T56 %0s", reason); errors = errors + 1; end
  endtask
  task chk;
    input cond; input [8*96-1:0] reason;
    begin checks = checks + 1; if (!cond) bad(reason); end
  endtask

  function [7:0] payb; input integer j; begin payb = (j * 7 + 8'h21) & 8'hFF; end endfunction
  function [7:0] fnb; input [2047:0] d; input integer k;
    begin fnb = d[2047 - 8*k -: 8]; end
  endfunction

  // ---- 包侧：读取并校验一个交付包 ----
  integer guard, i, got_op, got_blk, got_dp, got_sp;
  task pkt_take;
    input integer exp_op; input integer exp_blk; input integer exp_dp;
    input integer is_rrq;               // 1=校验 RRQ filename
    integer j;
    begin
      guard = 0;
      while (pkt_vld !== 1'b1 && guard < 200000) begin @(negedge clk); guard = guard + 1; end
      if (pkt_vld !== 1'b1) begin bad("pkt_vld timeout"); disable pkt_take; end
      pkt_rd_addr = 11'd1; #1; got_op = pkt_byte;
      pkt_rd_addr = 11'd2; #1;
      got_dp = pkt_dst_port;
      chk(got_op === exp_op, "packet opcode");
      chk(pkt_dst_ip === 32'h0A000002, "packet dst ip");
      if (exp_dp >= 0) begin
        chk(pkt_dst_port === exp_dp[15:0], "packet dst port");
      end
      if (exp_op == 1 || exp_op == 2) begin
        chk(pkt_len === (filename_len + 9), "RRQ/WRQ length");
        for (j = 0; j < filename_len; j = j + 1) begin
          pkt_rd_addr = 2 + j; #1;
          chk(pkt_byte === fnb(filename, j), "RRQ filename byte");
        end
      end else if (exp_op == 4) begin
        pkt_rd_addr = 11'd2; #1; j = pkt_byte;
        pkt_rd_addr = 11'd3; #1;
        chk({j[7:0], pkt_byte} === exp_blk[15:0], "ACK block number");
        chk(pkt_len === 11'd4, "ACK length");
      end
      @(negedge clk); pkt_ack = 1;
      @(negedge clk); pkt_ack = 0;
      @(negedge clk);
    end
  endtask

  // ---- 字节侧：送入一个 DATA/ERROR 响应 ----
  reg [7:0] spkt [0:600];
  integer spn;
  task sap_send;
    integer k;
    reg acc;
    begin
      for (k = 0; k < spn; k = k + 1) begin
        @(negedge clk);
        sap_vld = 1; sap_sop = (k == 0); sap_eop = (k == spn-1); sap_data = spkt[k];
        acc = 0;
        while (!acc) begin
          @(posedge clk);
          acc = (sap_ready === 1'b1);
        end
      end
      @(negedge clk); sap_vld = 0; sap_sop = 0; sap_eop = 0;
    end
  endtask

  task mk_data;
    input integer blk; input integer first; input integer n;
    integer k;
    begin
      spkt[0]=8'h00; spkt[1]=8'h03; spkt[2]=blk[15:8]; spkt[3]=blk[7:0];
      for (k = 0; k < n; k = k + 1) spkt[4+k] = payb(first + k);
      spn = 4 + n;
    end
  endtask

  task mk_err;
    input integer code;
    begin
      spkt[0]=8'h00; spkt[1]=8'h05; spkt[2]=code[15:8]; spkt[3]=code[7:0];
      spkt[4]="E"; spkt[5]=8'h00;
      spn = 6;
    end
  endtask

  task do_start;
    begin
      guard = 0;
      while (start_ready !== 1'b1 && guard < 100) begin @(negedge clk); guard = guard + 1; end
      @(negedge clk); start = 1;
      @(negedge clk); start = 0;
      @(negedge clk);
      chk(busy === 1'b1, "busy after start");
    end
  endtask

  integer t;
  task pump_ticks;
    input integer n;
    begin
      for (t = 0; t < n; t = t + 1) begin
        @(negedge clk); timeout_tick = 1;
        @(negedge clk); timeout_tick = 0;
      end
    end
  endtask

  task wait_done;
    begin
      guard = 0;
      while (done !== 1'b1 && guard < 200000) begin @(negedge clk); guard = guard + 1; end
      chk(done === 1'b1 && busy === 1'b0, "done reached");
    end
  endtask

  task readback;
    input integer len; input integer first;
    integer k;
    begin
      for (k = 0; k < len; k = k + 1) begin
        @(negedge clk); rd_en = 1; rd_addr = k[12:0];
        @(negedge clk); @(negedge clk);
        chk(rd_valid === 1'b1 && rd_data === payb(first + k), "file readback byte");
        rd_en = 0;
      end
    end
  endtask

  initial begin
    filename = 0;
    filename[2047 -: 8]="F"; filename[2039 -: 8]="W"; filename[2031 -: 8]=".";
    filename[2023 -: 8]="B"; filename[2015 -: 8]="I"; filename[2007 -: 8]="N";
    filename_len = 8'd6;

    repeat (5) @(negedge clk);
    rst = 0; repeat (2) @(negedge clk);

    // ================= J1: 正常取件 512+100 两段 =================
    $display("CASE J1");
    do_start;
    pkt_take(1, 0, 69, 1);            // RRQ → loader
    mk_data(1, 0, 512); sap_send;     // DATA(1) 512B
    pkt_take(4, 1, 40100, 0);         // ACK(1)
    mk_data(2, 512, 100); sap_send;   // DATA(2) 100B 末块
    pkt_take(4, 2, 40100, 0);         // ACK(2)
    pump_ticks(60);                   // dally 超时
    wait_done;
    chk(failed === 1'b0, "J1 no failure");
    // 文件发布与读回
    guard = 0;
    while (file_valid !== 1'b1 && guard < 4000) begin @(negedge clk); guard = guard + 1; end
    chk(file_valid === 1'b1, "J1 file published");
    chk(file_length === 14'd612, "J1 file length 612");
    chk(file_error_code === 2'd0, "J1 file no error");
    chk(rx_bytes === 32'd612, "J1 rx_bytes");
    readback(612, 0);
    // ack 释放文件
    @(negedge clk); file_ack = 1; @(negedge clk); file_ack = 0; @(negedge clk);
    chk(file_valid === 1'b0, "J1 file acked");

    // ================= J2: 服务器 ERROR → failed，再启动恢复 =================
    $display("CASE J2");
    do_start;
    pkt_take(1, 0, 69, 1);
    mk_err(1); sap_send;              // ERROR(1) 服务器错误
    guard = 0;
    while (failed !== 1'b1 && guard < 4000) begin @(negedge clk); guard = guard + 1; end
    chk(failed === 1'b1 && busy === 1'b0, "J2 failed state");
    chk(failure_code === 4'd3, "J2 failure code = E_SERVER");
    chk(file_valid === 1'b0, "J2 no file published");

    // ================= J3: 失败后再启动，单块小文件 =================
    $display("CASE J3");
    timeout_ticks = 16'd30;
    do_start;
    pkt_take(1, 0, 69, 1);
    mk_data(1, 0, 64); sap_send;      // 单块 64B（末块）
    pkt_take(4, 1, 40100, 0);
    pump_ticks(40);
    wait_done;
    chk(failed === 1'b0, "J3 done without failure");
    guard = 0;
    while (file_valid !== 1'b1 && guard < 4000) begin @(negedge clk); guard = guard + 1; end
    chk(file_valid === 1'b1 && file_length === 14'd64, "J3 file 64B published");
    readback(64, 0);
    @(negedge clk); file_ack = 1; @(negedge clk); file_ack = 0; @(negedge clk);

    // ================= J4: 空闲期杂散响应 → 排空丢弃、不阻塞 SAP =================
    $display("CASE J4");
    chk(busy === 1'b0 && done === 1'b1, "J4 idle after J3");
    t = drop_cnt;
    mk_data(7, 0, 8); sap_send;       // 引擎空闲：应答被排空
    repeat (20) @(negedge clk);
    chk(busy === 1'b0, "J4 stays idle");
    chk(drop_cnt === t + 32'd1, "J4 stray response drained and counted");
    chk(sap_ready === 1'b1, "J4 SAP not blocked while idle");

    if (errors == 0) $display("T56 FETCH ENGINE PASS checks=%0d ok=%0d drop=%0d", checks, ok_cnt, drop_cnt);
    else $display("T56 FETCH ENGINE FAIL errors=%0d", errors);
    $finish;
  end
  initial begin #8000000; $display("T56 FETCH ENGINE FAIL timeout"); $finish; end
endmodule
