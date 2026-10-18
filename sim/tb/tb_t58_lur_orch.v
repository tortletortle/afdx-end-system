// =====================================================================
// T58 — 615A LUR 编排器（P05）单元验证
//
// 覆盖：
//   K1 两文件清单顺序取件：文件名（去 NUL）与长度正确、ok_files=2、
//      total_bytes 累加、每文件一次 file_ack、done 置位
//   K2 第二文件 server ERROR -> failed(F_JOB=2)，无 done
//   K3 host_skip 跳过失败 -> done 且 ok=1/fail=1
//   K4 host_abort -> failed(F_ABORT=3)
//   K5 lur_ok=0 -> F_LUR=1；count=0 -> F_EMPTY=4
//   K6 count>MAX_FILES -> F_LUR=1
//
// 说明：TB 用 job_start 计数作为「第几个文件」的唯一依据（编排器每发一次
// job_start 代表进入下一文件），名字读口按该序号从伪清单取字节。
// =====================================================================
`timescale 1 ns / 1 ps
module tb_t58_lur_orch;
  reg clk=0, rst=1;
  always #4 clk=~clk;

  reg  host_start=0, host_abort=0, host_skip=0, host_up_mode=0;
  reg host_hold_files=0,host_file_ack=0;
  wire waiting_file_ack;
  reg  [31:0] host_server_ip=32'h0A000002;
  reg  [15:0] host_local_tid=16'h3001, host_timeout_ticks=16'd4;
  reg  lur_ok=0;
  reg  [15:0] lur_file_count=16'd0;
  wire [7:0]  lur_name_len;
  wire [7:0]  lur_name_byte;
  wire        lur_name_read;
  wire [7:0]  lur_name_index;
  wire [2:0]  lur_file_select;

  wire        job_start, job_abort, job_up_mode;
  wire [31:0] job_server_ip;
  wire [15:0] job_local_tid, job_timeout_ticks;
  wire [2047:0] job_filename;
  wire [7:0]  job_filename_len;
  reg         job_start_ready=1;
  reg         job_done=0, job_failed=0;
  reg  [3:0]  job_failure_code=4'd0;

  wire        file_ack;
  wire        file_valid = 1'b1;
  wire [13:0] file_length;
  // 当前正在搬运的文件序号（由 job_start 计数推进），必须先声明后使用
  reg [2:0] file_seq = 3'd0;
  // 每文件长度：在 job_start 上升沿锁存「本次作业的长度」并保持到下一作业，
  // 使编排器在 S_SETTLE 采样 file_length 时拿到的是本作业（而非下一作业）的值。
  reg [13:0] len_lat = 14'd520;
  always @(posedge clk) begin
    if (rst) len_lat <= 14'd520;
    else if (job_start) len_lat <= (file_seq == 3'd0) ? 14'd520
                                  : (file_seq == 3'd1) ? 14'd300
                                  : 14'd64;
  end
  assign file_length = len_lat;

  wire        busy, done, failed;
  wire [3:0]  failure_code;
  wire [2:0]  cur_file;
  wire [15:0] ok_files, fail_files;
  wire [31:0] total_bytes;

  a615a_lur_orchestrator #(.MAX_FILES(8), .DEF_TICKS(50)) dut (
    .clk(clk), .rst_sync(rst),
    .host_start(host_start), .host_abort(host_abort), .host_skip(host_skip),
    .host_server_ip(host_server_ip), .host_local_tid(host_local_tid),
    .host_timeout_ticks(host_timeout_ticks), .host_up_mode(host_up_mode),
    .host_hold_files(host_hold_files),.host_file_ack(host_file_ack),.waiting_file_ack(waiting_file_ack),
    .lur_ok(lur_ok), .lur_file_count(lur_file_count),
    .lur_name_len(lur_name_len), .lur_name_byte(lur_name_byte),
    .lur_name_read(lur_name_read), .lur_name_index(lur_name_index),
    .lur_file_select(lur_file_select),
    .job_start(job_start), .job_start_ready(job_start_ready),
    .job_server_ip(job_server_ip), .job_local_tid(job_local_tid),
    .job_filename(job_filename), .job_filename_len(job_filename_len),
    .job_timeout_ticks(job_timeout_ticks), .job_abort(job_abort),
    .job_up_mode(job_up_mode), .job_done(job_done), .job_failed(job_failed),
    .job_failure_code(job_failure_code),
    .file_ack(file_ack), .file_valid(file_valid), .file_length(file_length),
    .busy(busy), .done(done), .failed(failed), .failure_code(failure_code),
    .cur_file(cur_file), .ok_files(ok_files), .fail_files(fail_files),
    .total_bytes(total_bytes));

  // ---- 伪 LUR 清单（含 NUL）；长度含 NUL ----
  // F0 = "FW.BIN\0" (7)   F1 = "CFG.DAT\0" (8)   F2 = "LOG.TXT\0" (8)
  reg [7:0] nm0 [0:7];
  reg [7:0] nm1 [0:7];
  reg [7:0] nm2 [0:7];
  initial begin
    nm0[0]=8'h46; nm0[1]=8'h57; nm0[2]=8'h2E; nm0[3]=8'h42; nm0[4]=8'h49; nm0[5]=8'h4E; nm0[6]=8'h00;
    nm1[0]=8'h43; nm1[1]=8'h46; nm1[2]=8'h47; nm1[3]=8'h2E; nm1[4]=8'h44; nm1[5]=8'h41; nm1[6]=8'h54; nm1[7]=8'h00;
    nm2[0]=8'h4C; nm2[1]=8'h4F; nm2[2]=8'h47; nm2[3]=8'h2E; nm2[4]=8'h54; nm2[5]=8'h58; nm2[6]=8'h54; nm2[7]=8'h00;
  end

  // 名字读口模型：严格复刻 a615a_lur_rx 的寄存读出行为
  //   * file_select 决定本次访问的条目（真实 RTL 由顶层从 lur_file_select 旁路）；
  //   * name_byte 相对 name_read/name_byte_index 有 1 拍延迟（name_byte_valid
  //     为寄存输出，见 a615a_lur_rx.v:88-91）。
  // 若编排器不做 1 拍对齐，本模型会立刻暴露（首字节为 0 / 字节整体错位）。
  reg [7:0] nm_q;
  reg       nb_vld_q;
  wire [7:0] nm_cur = (lur_file_select == 3'd0) ? nm0[lur_name_index] :
                      (lur_file_select == 3'd1) ? nm1[lur_name_index] :
                                                  nm2[lur_name_index];
  always @(posedge clk) begin
    if (rst) begin nm_q <= 8'd0; nb_vld_q <= 1'b0; end
    else begin
      nb_vld_q <= lur_name_read && (lur_name_index < 8'd7);
      nm_q     <= nm_cur;
    end
  end
  assign lur_name_byte = nb_vld_q ? nm_q : 8'd0;

  // 名字长度按条目号驱动（含 NUL）：F0=7, F1=8, F2=8
  assign lur_name_len = (lur_file_select == 3'd0) ? 8'd7 : 8'd8;

  integer errors=0, checks=0, cycle=0;
  always @(posedge clk) cycle <= cycle+1;
  task bad; input [8*120-1:0] r; begin if (errors<25) $display("  [err] T58 cyc=%0d %0s", cycle, r); errors=errors+1; end endtask
  task chk; input c; input [8*120-1:0] r; begin checks=checks+1; if(!c) bad(r); end endtask

  // job_start 上升沿 -> file_seq（下一文件的序号）
  reg js_d=0;
  always @(posedge clk) begin
    if (rst) begin js_d<=1'b0; file_seq<=3'd0; end
    else begin
      js_d <= job_start;
      if(host_start) file_seq<=0;
      else if (job_start && !js_d) file_seq <= file_seq + 3'd1;
    end
  end

  // ---- 单作业应答 ----
  // mode: 0 全部成功, 1 第二文件 ERROR, 2 skip 用例（第二文件 ERROR）, 3 abort,
  //       4 第一文件超时（job_failure_code=E_TIMEOUT=2）→ 无 skip 直接 failed,
  //       5 第一文件超时 + skip → 第二文件成功, ok=1/fail=1, done
  integer mode=0;
  integer seen_jobs=0;

  task serve_one;
    integer cap_len; reg [7:0] cap[0:15]; integer q;
    begin
      wait (job_start === 1'b1);
      @(negedge clk);
      cap_len = job_filename_len;
      // job_filename 的位序约定：字节 0 = 最高字节（[2047:2040]），
      // 与 client（原样直通）与 tx_pack（fnb: d[2047-8k-:8]）一致。
      for (q=0;q<16;q=q+1) cap[q] = job_filename[2047 - q*8 -: 8];
      chk(job_local_tid===16'h3001, "job tid");
      chk(job_server_ip===32'h0A000002, "job server ip");
      chk(job_timeout_ticks===16'd4, "job ticks passthrough");
      chk(job_up_mode===1'b0, "per-file LUR transfer is RRQ, independent of manifest-ready mode");
      if (seen_jobs==0) begin
        chk(cap_len===8'd6, "file0 name_len=6 (excl NUL)");
        chk(cap[0]==="F"&&cap[1]==="W"&&cap[2]==="."&&cap[3]==="B"&&cap[4]==="I"&&cap[5]==="N",
            "file0 name bytes FW.BIN");
      end else begin
        chk(cap_len===8'd7, "file1 name_len=7 (excl NUL)");
        chk(cap[0]==="C"&&cap[1]==="F"&&cap[2]==="G"&&cap[3]==="."&&cap[4]==="D"&&cap[5]==="A"&&cap[6]==="T",
            "file1 name bytes CFG.DAT");
      end
      seen_jobs = seen_jobs + 1;
      // 应答
      if ((mode==4 || mode==5) && seen_jobs==1) begin
        // 模拟 TFTP 客户端 MAX_RETRIES 耗尽后的 E_TIMEOUT 失败（failure_code=2）。
        job_failed <= 1'b1; job_failure_code <= 4'd2;
        @(negedge clk);
        job_failed <= 1'b0;
      end else if ((mode==1 || mode==2) && seen_jobs==2) begin
        job_failed <= 1'b1; job_failure_code <= 4'd3;
        @(negedge clk);
        job_failed <= 1'b0;
      end else begin
        job_done <= 1'b1;
        if(mode==6) begin
          wait(waiting_file_ack===1'b1);
          host_hold_files=0; // only a future session may use this change
          repeat(20) begin
            @(negedge clk);
            chk(file_ack===0 && waiting_file_ack && !job_start,"held file released or next job started early");
            chk(ok_files==seen_jobs-1,"held file counted before acknowledgement");
          end
          host_file_ack=1;@(negedge clk);host_file_ack=0;
        end
        // DUT 在 job_done 有效后进入 S_SETTLE，等待其产生 file_ack 脉冲（纯观测）
        wait (file_ack === 1'b1);
        @(negedge clk); @(negedge clk);
        job_done <= 1'b0;
      end
    end
  endtask

  task reset_all;
    begin
      rst=1; repeat(6) @(negedge clk); rst=0;
      seen_jobs=0; job_done=0; job_failed=0;
      host_skip=0; host_abort=0;
      host_up_mode=0;
      host_hold_files=0;host_file_ack=0;
    end
  endtask

  initial begin
    rst=1; repeat(8) @(negedge clk); rst=0;

    // ---------- K5a: lur_ok=0 ----------
    $display("T58 CASE K5a");
    lur_ok=0; lur_file_count=16'd2;
    host_start=1; @(negedge clk); host_start=0;
    wait (failed===1'b1);
    chk(failure_code===4'd1, "K5a code F_LUR=1");
    chk(done===1'b0, "K5a no done");
    reset_all();

    // ---------- K5b: count=0 ----------
    $display("T58 CASE K5b");
    lur_ok=1; lur_file_count=16'd0;
    host_start=1; @(negedge clk); host_start=0;
    wait (failed===1'b1);
    chk(failure_code===4'd4, "K5b code F_EMPTY=4");
    reset_all();

    // ---------- K6: count>8 ----------
    $display("T58 CASE K6");
    lur_ok=1; lur_file_count=16'd9;
    host_start=1; @(negedge clk); host_start=0;
    wait (failed===1'b1);
    chk(failure_code===4'd1, "K6 code F_LUR=1");
    reset_all();

    // ---------- K1: 两文件成功 ----------
    $display("T58 CASE K1");
    lur_ok=1; lur_file_count=16'd2; mode=0; host_up_mode=1;
    host_start=1; @(negedge clk); host_start=0;
    serve_one;
    serve_one;
    wait (done===1'b1);
    chk(done===1'b1 && failed===1'b0, "K1 done");
    chk(ok_files===16'd2, "K1 ok_files=2");
    chk(total_bytes===32'd820, "K1 total_bytes=520+300");
    reset_all();

    // ---------- K2: 第二文件失败 -> failed ----------
    $display("T58 CASE K2");
    lur_ok=1; lur_file_count=16'd2; mode=1;
    host_start=1; @(negedge clk); host_start=0;
    serve_one; serve_one;
    wait (failed===1'b1);
    chk(failure_code===4'd2, "K2 code F_JOB=2");
    chk(done===1'b0, "K2 no done");
    chk(fail_files===16'd1, "K2 fail_files=1");
    reset_all();

    // ---------- K3: skip ----------
    $display("T58 CASE K3");
    lur_ok=1; lur_file_count=16'd2; mode=2; host_skip=1;
    host_start=1; @(negedge clk); host_start=0;
    serve_one; serve_one;
    wait (done===1'b1 || failed===1'b1);
    chk(done===1'b1, "K3 done after skip");
    chk(ok_files===16'd1 && fail_files===16'd1, "K3 ok=1 fail=1");
    reset_all();

    // ---------- K4: abort ----------
    $display("T58 CASE K4");
    lur_ok=1; lur_file_count=16'd2; mode=3;
    host_start=1; @(negedge clk); host_start=0;
    wait (job_start===1'b1);
    @(negedge clk);
    host_abort=1; @(negedge clk); @(negedge clk);
    chk(failed===1'b1, "K4 failed");
    chk(failure_code===4'd3, "K4 code F_ABORT=3");
    reset_all();

    // ---------- K7: 第一文件超时（E_TIMEOUT）无 skip -> failed(F_JOB) ----------
    // 场景：顶层 timeout_ticks < VL BAG 时，TFTP 客户端每拍重传、MAX_RETRIES
    // 耗尽后置失败（T49 case C 已在客户端层验证该耗尽）。本用例验证编排器
    // 把该失败映射为 F_JOB=2 且不再继续后续文件（无 done）。
    $display("T58 CASE K7");
    lur_ok=1; lur_file_count=16'd2; mode=4;
    host_start=1; @(negedge clk); host_start=0;
    serve_one;
    wait (failed===1'b1);
    chk(failure_code===4'd2, "K7 code F_JOB=2 on job timeout");
    chk(done===1'b0, "K7 no done after timeout failure");
    chk(fail_files===16'd1, "K7 fail_files=1");
    chk(ok_files===16'd0, "K7 ok_files=0");
    reset_all();

    // ---------- K8: 第一文件超时 + skip -> 第二文件成功, ok=1/fail=1, done ----------
    $display("T58 CASE K8");
    lur_ok=1; lur_file_count=16'd2; mode=5; host_skip=1;
    host_start=1; @(negedge clk); host_start=0;
    serve_one;   // 文件 0 超时失败
    serve_one;   // 文件 1 正常完成
    wait (done===1'b1 || failed===1'b1);
    chk(done===1'b1, "K8 done after skip over timeout");
    chk(failed===1'b0, "K8 not failed");
    chk(ok_files===16'd1 && fail_files===16'd1, "K8 ok=1 fail=1");
    chk(total_bytes===32'd300, "K8 total_bytes counts only ok file (300)");
    reset_all();

    $display("T58 CASE K9 held files, latched mode, no premature count");
    lur_ok=1;lur_file_count=2;mode=6;host_hold_files=1;
    host_file_ack=1;host_start=1;@(negedge clk);host_start=0;host_file_ack=0;
    serve_one;serve_one;wait(done===1);
    chk(ok_files==2 && total_bytes==820,"held session totals");
    $display("T58 CASE K10 restart directly from DONE");
    seen_jobs=0;mode=0;lur_file_count=1;
    host_start=1;@(negedge clk);host_start=0;serve_one;wait(done===1);
    chk(ok_files==1 && total_bytes==520 && !failed,"done restart retained old result/counts");
    $display("T58 CASE K11 abort published held file");
    seen_jobs=0;host_hold_files=1;host_start=1;@(negedge clk);host_start=0;
    wait(job_start===1);@(negedge clk);job_done=1;wait(waiting_file_ack===1);
    @(negedge clk);host_abort=1;@(negedge clk);host_abort=0;
    chk(failed && failure_code==3 && file_ack && ok_files==0,"held abort failed to release without success count");
    job_done=0;repeat(3)@(negedge clk);
    $display("T58 CASE K12 restart directly from error terminal state");
    seen_jobs=0;host_hold_files=0;mode=0;host_start=1;@(negedge clk);host_start=0;
    serve_one;wait(done===1);
    chk(ok_files==1 && total_bytes==520 && !failed,"failed restart did not recover");
    if (errors==0) $display("T58 LUR ORCH PASS checks=%0d", checks);
    else $display("T58 LUR ORCH FAIL errors=%0d", errors);
    $finish;
  end

  initial begin #3000000; $display("T58 LUR ORCH FAIL timeout"); $finish; end
endmodule
