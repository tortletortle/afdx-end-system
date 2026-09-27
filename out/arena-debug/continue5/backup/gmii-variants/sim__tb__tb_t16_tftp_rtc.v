// =====================================================================
// T16 —— A615-A TFTP 引擎 + RTC/PPS 对时
// A 部分（单元级 a615a_tftp）：WRQ/DATA/ACK/ERROR/RRQ 真实报文字节流，
//   校验 ACK 编码、加载区落盘内容、CRC32、重复块、错块、白名单、mode、
//   RRQ STATUS 文件、非法操作码、超时重传与重试上限。
// B 部分（单元级 rtc_sync）：自由运行 PPS 周期、大误差跳变、小误差平滑、
//   锁定判据、失步看门狗、HOLD。
// C 部分（顶层）：真实 SAP 帧（vec/t15_mgmt.hex，含线序 FCS）经 mac_rx_if
//   → 解析 → mgmt_sap_rx 取回 PMEM 载荷 → a615a_tftp，主机经 0xAC20~0xAC29
//   观测窗读状态与响应字节，经 0xCC20 加载区回读落盘数据。
// 边界：管理面响应只编码并经观测窗读出，未接入 TX 帧构建器（不上线）。
// =====================================================================
`timescale 1 ns / 1 ps
module tb_t16_tftp_rtc;
  integer errors = 0;
  reg clk = 0;
  always #4 clk = ~clk;
  task bad;
    input [8*110-1:0] reason;
    begin if (errors < 30) $display("  [err] T16: %0s", reason); errors = errors + 1; end
  endtask
  task badv;
    input [8*90-1:0] reason; input [31:0] got; input [31:0] want;
    begin
      if (errors < 30) $display("  [err] T16: %0s (got=%0h want=%0h)", reason, got, want);
      errors = errors + 1;
    end
  endtask
  function [31:0] crc32b;                      // 反射 CRC-32 参考实现
    input [31:0] c0; input [7:0] d;
    reg [31:0] c; integer k;
    begin
      c = c0 ^ {24'd0, d};
      for (k = 0; k < 8; k = k + 1) c = c[0] ? ((c >> 1) ^ 32'hEDB88320) : (c >> 1);
      crc32b = c;
    end
  endfunction

  // ================= A：a615a_tftp 单元级 =================
  reg        t_rst = 1'b1, t_tick = 1'b0;
  reg        t_vld = 0, t_sop = 0, t_eop = 0;
  reg [7:0]  t_data = 0;
  reg [15:0] t_sport = 16'd4096;
  reg        t_rack = 0;
  reg [10:0] t_raddr = 0;
  reg        t_hrd = 0;
  reg [12:0] t_haddr = 0;
  wire        t_rdy, t_rvld, t_ok;
  wire [10:0] t_rlen;
  wire [7:0]  t_rbyte, t_retry;
  wire [31:0] t_hdata, t_bytes, t_crc, t_pkt, t_dup, t_ecnt, t_to, t_fnh;
  wire [15:0] t_err, t_tid, t_blk;
  wire [3:0]  t_st;
  a615a_tftp #(.LOAD_WORDS(8192), .RETRY_MAX(3), .TIMEOUT_US(50)) tut (
    .clk(clk), .rst_sync(t_rst), .en(1'b1), .tick_us(t_tick),
    .in_vld(t_vld), .in_sop(t_sop), .in_eop(t_eop), .in_data(t_data),
    .in_sport(t_sport), .in_ready(t_rdy),
    .resp_vld(t_rvld), .resp_len(t_rlen), .resp_ack(t_rack),
    .resp_rd_addr(t_raddr), .resp_byte(t_rbyte),
    .host_rd(t_hrd), .host_addr(t_haddr), .host_rdata(t_hdata),
    .loaded_ok(t_ok), .err_code(t_err), .tid(t_tid), .blk_expect(t_blk),
    .bytes_rcvd(t_bytes), .crc32_val(t_crc), .pkt_cnt(t_pkt), .dup_cnt(t_dup),
    .err_cnt(t_ecnt), .timeout_cnt(t_to), .retry_cnt(t_retry),
    .fname_head(t_fnh), .state_o(t_st));

  reg [7:0] pkt [0:1023];
  integer pktlen, pi;
  task send_pkt;
    begin
      for (pi = 0; pi < pktlen; pi = pi + 1) begin
        @(negedge clk);
        t_vld = 1; t_sop = (pi == 0); t_eop = (pi == pktlen - 1); t_data = pkt[pi];
      end
      @(negedge clk); t_vld = 0; t_sop = 0; t_eop = 0;
      repeat (3) @(negedge clk);
    end
  endtask
  task rbyte; input [10:0] a; output [7:0] d;
    begin t_raddr = a; #1; d = t_rbyte; end
  endtask
  task rack;
    begin @(negedge clk); t_rack = 1; @(negedge clk); t_rack = 0; end
  endtask
  task chk_ack; input [15:0] blk; input [8*40-1:0] tag;
    reg [7:0] b0,b1,b2,b3;
    begin
      if (t_rvld !== 1'b1) bad({"no response: ", tag});
      if (t_rlen !== 11'd4) bad({"ACK length wrong: ", tag});
      rbyte(0,b0); rbyte(1,b1); rbyte(2,b2); rbyte(3,b3);
      if (b0 !== 8'h00 || b1 !== 8'h04 || {b2,b3} !== blk) bad({"ACK bytes wrong: ", tag});
      rack();
    end
  endtask
  task chk_err; input [15:0] code; input [8*40-1:0] tag;
    reg [7:0] b0,b1,b2,b3;
    begin
      if (t_rvld !== 1'b1) bad({"no ERROR response: ", tag});
      if (t_rlen !== 11'd13) bad({"ERROR length wrong: ", tag});
      rbyte(0,b0); rbyte(1,b1); rbyte(2,b2); rbyte(3,b3);
      if (b0 !== 8'h00 || b1 !== 8'h05 || {b2,b3} !== code) bad({"ERROR code wrong: ", tag});
      rack();
    end
  endtask
  task mk_wrq;      // 00 02 "UPLOAD" 00 "octet" 00
    begin
      pkt[0]=8'h00; pkt[1]=8'h02; pkt[2]="U"; pkt[3]="P"; pkt[4]="L";
      pkt[5]="O"; pkt[6]="A"; pkt[7]="D"; pkt[8]=8'h00;
      pkt[9]="o"; pkt[10]="c"; pkt[11]="t"; pkt[12]="e"; pkt[13]="t"; pkt[14]=8'h00;
      pktlen = 15;
    end
  endtask
  task mk_rrq;      // 00 01 "STATUS" 00 "octet" 00
    begin
      pkt[0]=8'h00; pkt[1]=8'h01; pkt[2]="S"; pkt[3]="T"; pkt[4]="A";
      pkt[5]="T"; pkt[6]="U"; pkt[7]="S"; pkt[8]=8'h00;
      pkt[9]="o"; pkt[10]="c"; pkt[11]="t"; pkt[12]="e"; pkt[13]="t"; pkt[14]=8'h00;
      pktlen = 15;
    end
  endtask
  integer dk;
  task mk_data; input [15:0] blk; input integer n; input integer seed;
    begin
      pkt[0]=8'h00; pkt[1]=8'h03; pkt[2]=blk[15:8]; pkt[3]=blk[7:0];
      for (dk = 0; dk < n; dk = dk + 1) pkt[4+dk] = (dk*7 + seed) & 8'hFF;
      pktlen = 4 + n;
    end
  endtask

  // ================= B：rtc_sync 单元级 =================
  reg        r_rst = 1'b1, r_tick = 0, r_pps = 0, r_hold = 0, r_sv = 0;
  reg [63:0] r_free = 64'd0, r_mts = 64'd0;
  wire [63:0] r_time;
  wire        r_ppso, r_sloss, r_lock;
  wire [31:0] r_err, r_jmp, r_stp, r_pcnt, r_ph;
  rtc_sync #(.US_PER_SEC(1000), .SYNC_TIMEOUT(3000), .LOCK_N(3)) rut (
    .clk(clk), .rst_sync(r_rst), .en(1'b1), .hold(r_hold), .tick_us(r_tick),
    .rtc_free_us(r_free), .pps_in(r_pps), .sync_vld(r_sv),
    .sync_master_ts(r_mts), .path_est_us(16'd0),
    .th_jump_us(8'd100), .log2_avg(4'd2),
    .rtc_time_us(r_time), .pps_out(r_ppso), .sync_loss(r_sloss), .locked(r_lock),
    .last_err_us(r_err), .jump_cnt(r_jmp), .step_cnt(r_stp),
    .pps_cnt(r_pcnt), .sec_phase(r_ph));
  integer tk;
  task ticks; input integer n;
    begin
      for (tk = 0; tk < n; tk = tk + 1) begin
        @(negedge clk); r_tick = 1; r_free = r_free + 64'd1;
        @(negedge clk); r_tick = 0;
        @(negedge clk);
      end
    end
  endtask
  task pps_at; input [31:0] target;
    integer g;
    begin
      g = 0;
      while (r_ph !== target && g < 40000) begin
        @(negedge clk); r_tick = 1; r_free = r_free + 64'd1;
        @(negedge clk); r_tick = 0; @(negedge clk);
        g = g + 1;
      end
      if (g >= 40000) bad("pps_at: phase target never reached");
      r_pps = 1; ticks(3); r_pps = 0; ticks(3);
    end
  endtask

  // ================= C：顶层 =================
  reg reset = 1'b1;
  reg [7:0] rx_data = 0, rx_data_b = 0;
  reg rx_valid = 0, rx_valid_b = 0, rx_ready = 0, rx_ready_b = 0;
  reg host_cs = 0, host_we = 0;
  reg [15:0] host_addr = 0;
  reg [31:0] host_wdata = 0;
  wire [31:0] host_rdata;
  wire host_ack, pps_o;
  reg  tb_pps = 1'b0;
  integer pps_seen = 0;
  always @(posedge clk) if (!reset && pps_o) pps_seen = pps_seen + 1;
  AFDX_top #(.IF_MODE(0), .FCS_MODE(2), .TFTP_SAP_PORT(5), .SNMP_SAP_PORT(9),
             .RTC_US_PER_SEC(4), .RTC_SYNC_TO_US(40), .TFTP_TIMEOUT_US(100000)) dut (
    .clk(clk), .reset(reset), .tx_data(), .tx_valid(), .tx_ready(),
    .rx_data(rx_data), .rx_valid(rx_valid), .rx_ready(rx_ready),
    .tx_data_b(), .tx_valid_b(), .tx_ready_b(),
    .rx_data_b(rx_data_b), .rx_valid_b(rx_valid_b), .rx_ready_b(rx_ready_b),
    .host_cs(host_cs), .host_we(host_we), .host_addr(host_addr),
    .host_wdata(host_wdata), .host_rdata(host_rdata), .host_ack(host_ack),
    .host_irq(), .pps_in(tb_pps), .pps_out(pps_o), .rtc_time_us(), .dbg_frame_event());
  task host_write; input [15:0] a; input [31:0] d;
    begin
      @(negedge clk); host_cs=1; host_we=1; host_addr=a; host_wdata=d;
      @(negedge clk); if (host_ack !== 1'b1) bad("host write ACK missing");
      host_cs=0; host_we=0;
    end
  endtask
  task host_read; input [15:0] a; output [31:0] d;
    begin
      @(negedge clk); host_cs=1; host_we=0; host_addr=a;
      @(negedge clk); if (host_ack !== 1'b1) bad("host read ACK missing");
      d = host_rdata; host_cs=0;
    end
  endtask

  localparam integer P_SAP = 5;
  localparam [15:0] PT_SAP = 16'h7D80 + 4*P_SAP;
  // Lmax 必须覆盖最大管理帧（生成器报告 124 B），T23 的 79 只够 64 B 帧。
  localparam [31:0] W0_VL  = 32'hF500_0000 | (P_SAP<<12) | 32'd700;   // 最大管理帧 563 B（512 B TFTP 满块）
  reg [31:0] vec [0:2047];
  integer cbase [0:31];
  integer clen  [0:31];
  integer cplen [0:31];
  integer caux  [0:31];
  integer ncase, vi2, cid, i, k, b, waitc;
  reg [31:0] d, e;
  reg [7:0]  bb;
  function [7:0] fbyte; input integer c; input integer off;
    reg [31:0] q;
    begin
      q = vec[cbase[c] + (off>>2)];
      case (off & 3) 0: fbyte=q[31:24]; 1: fbyte=q[23:16];
                     2: fbyte=q[15:8];  default: fbyte=q[7:0]; endcase
    end
  endfunction
  integer acc0;
  task drive_case; input integer c;
    begin
      acc0 = dut.mgmt_accept_cnt;
      for (b = 0; b < clen[c]; b = b + 1) begin
        @(negedge clk); rx_ready=1; rx_valid=1; rx_data=fbyte(c,b);
        @(negedge clk); rx_valid=0; repeat (8) @(negedge clk);
      end
      @(negedge clk); rx_ready=0; rx_valid=0;
      // 1) 先等 SAP 端点接手本帧描述符
      waitc = 0;
      while (dut.mgmt_accept_cnt <= acc0 && waitc < 20000) begin
        @(negedge clk); waitc = waitc + 1;
      end
      if (waitc >= 20000) bad("SAP endpoint never accepted the frame");
      // 2) 再等它把整帧载荷搬完并分发完（512 B TFTP DATA 约 700 拍）
      waitc = 0;
      while (dut.u_mgmt_sap.st !== 2'd0 && waitc < 8000) begin
        @(negedge clk); waitc = waitc + 1;
      end
      if (waitc >= 8000) bad("SAP endpoint never returned to idle");
      repeat (200) @(negedge clk);
    end
  endtask
  task mgmt_byte; input integer idx; output [7:0] v;
    reg [31:0] t;
    begin host_write(16'hAC1A, idx[31:0]); host_read(16'hAC27, t); v = t[7:0]; end
  endtask

  integer exp_pkt;
  reg [31:0] crc_ref;

  initial begin
    // ---------------- A ----------------
    repeat (4) @(negedge clk); t_rst = 1'b0;
    // A1 WRQ → ACK(0)
    mk_wrq(); send_pkt(); chk_ack(16'd0, "WRQ UPLOAD");
    if (t_blk !== 16'd1) bad("A1 blk_expect must be 1 after WRQ");
    if (t_tid !== t_sport) bad("A1 TID not captured");
    if (t_fnh !== 32'h55504C4F) bad("A1 filename head wrong");
    // A2 DATA blk1 512 B（非末块）
    mk_data(16'd1, 512, 8'h21); send_pkt(); chk_ack(16'd1, "DATA blk1");
    if (t_bytes !== 32'd512) bad("A2 bytes_rcvd wrong after blk1");
    if (t_ok !== 1'b0) bad("A2 loaded_ok must stay 0 on full block");
    // A3 重复块：只补 ACK，不重复计数
    mk_data(16'd1, 512, 8'h21); send_pkt(); chk_ack(16'd1, "dup DATA blk1");
    if (t_dup !== 32'd1) bad("A3 dup_cnt wrong");
    if (t_bytes !== 32'd512) bad("A3 duplicate block must not re-count bytes");
    // A4 DATA blk2 100 B（末块）
    mk_data(16'd2, 100, 8'h5A); send_pkt(); chk_ack(16'd2, "DATA blk2");
    if (t_bytes !== 32'd612) bad("A4 bytes_rcvd wrong after final block");
    if (t_ok !== 1'b1) bad("A4 loaded_ok must be 1 on short final block");
    // A5 加载区落盘内容
    for (i = 0; i < 612; i = i + 4) begin
      @(negedge clk); t_hrd = 1; t_haddr = i[14:2];
      @(negedge clk); t_hrd = 0;
      for (k = 0; k < 4; k = k + 1) begin
        if (i + k < 512) e = (((i+k)*7 + 8'h21) & 8'hFF);
        else if (i + k < 612) e = ((((i+k-512))*7 + 8'h5A) & 8'hFF);
        else e = 32'd0;
        if (i + k < 612)
          if (t_hdata[31-8*k -: 8] !== e[7:0]) bad("A5 load-area byte mismatch");
      end
    end
    // A6 CRC32 参考比对
    crc_ref = 32'hFFFF_FFFF;
    for (i = 0; i < 512; i = i + 1) crc_ref = crc32b(crc_ref, (i*7 + 8'h21) & 8'hFF);
    for (i = 0; i < 100; i = i + 1) crc_ref = crc32b(crc_ref, (i*7 + 8'h5A) & 8'hFF);
    if (t_crc !== ~crc_ref) bad("A6 CRC32 of load payload mismatch");
    // A7 会话已结束：再来 DATA → ERROR(5)
    mk_data(16'd3, 8, 8'h11); send_pkt(); chk_err(16'd5, "DATA without session");
    // A8 白名单 / mode
    pkt[0]=8'h00; pkt[1]=8'h02; pkt[2]="N"; pkt[3]="O"; pkt[4]="P"; pkt[5]="E";
    pkt[6]=8'h00; pkt[7]="o"; pkt[8]="c"; pkt[9]="t"; pkt[10]="e"; pkt[11]="t";
    pkt[12]=8'h00; pktlen=13; send_pkt(); chk_err(16'd2, "WRQ bad filename");
    pkt[0]=8'h00; pkt[1]=8'h02; pkt[2]="U"; pkt[3]="P"; pkt[4]="L"; pkt[5]="O";
    pkt[6]="A"; pkt[7]="D"; pkt[8]=8'h00; pkt[9]="n"; pkt[10]="e"; pkt[11]="t";
    pkt[12]="a"; pkt[13]="s"; pkt[14]="c"; pkt[15]="i"; pkt[16]="i"; pkt[17]=8'h00;
    pktlen=18; send_pkt(); chk_err(16'd0, "WRQ bad mode");
    // A9 RRQ STATUS → DATA(1) 末块
    mk_rrq(); send_pkt();
    if (t_rvld !== 1'b1 || t_rlen !== 11'd36) bad("A9 RRQ DATA length wrong");
    rbyte(0,bb); if (bb !== 8'h00) bad("A9 RRQ opcode hi");
    rbyte(1,bb); if (bb !== 8'h03) bad("A9 RRQ opcode must be DATA");
    rbyte(2,bb); if (bb !== 8'h00) bad("A9 RRQ blk hi");
    rbyte(3,bb); if (bb !== 8'h01) bad("A9 RRQ blk must be 1");
    rbyte(4,bb); if (bb !== "A") bad("A9 STATUS magic[0]");
    rbyte(5,bb); if (bb !== "6") bad("A9 STATUS magic[1]");
    rbyte(6,bb); if (bb !== "1") bad("A9 STATUS magic[2]");
    rbyte(7,bb); if (bb !== "5") bad("A9 STATUS magic[3]");
    rack();
    // A10 ACK(1) 结束 RRQ
    pkt[0]=8'h00; pkt[1]=8'h04; pkt[2]=8'h00; pkt[3]=8'h01; pktlen=4; send_pkt();
    if (t_rvld !== 1'b0) bad("A10 RRQ session should close on ACK(1)");
    // A11 非法操作码
    pkt[0]=8'h00; pkt[1]=8'h06; pkt[2]=8'h00; pkt[3]=8'h00; pktlen=4; send_pkt();
    chk_err(16'd4, "OACK unsupported");
    // A12 超时重传与重试上限（TIMEOUT_US=50, RETRY_MAX=3）
    mk_wrq(); send_pkt(); chk_ack(16'd0, "WRQ before timeout test");
    exp_pkt = t_pkt;
    for (i = 0; i < 4; i = i + 1) begin
      for (k = 0; k < 60; k = k + 1) begin
        @(negedge clk); t_tick = 1; @(negedge clk); t_tick = 0;
      end
      if (i < 3) begin
        if (t_rvld !== 1'b1) bad("A12 retransmit did not fire");
        if (t_retry !== (i[7:0] + 8'd1)) bad("A12 retry_cnt wrong");
        rack();
      end
    end
    if (t_to < 32'd4) bad("A12 timeout_cnt wrong");
    if (t_err !== 16'd4) bad("A12 retry limit must raise ERROR(4)");
    if (t_pkt !== exp_pkt[31:0]) bad("A12 timeout must not count as received PDU");

    // ---------------- B ----------------
    repeat (4) @(negedge clk); r_rst = 1'b0;
    // B1 自由运行：pps_out 周期 = US_PER_SEC 个 tick
    ticks(1005);
    if (r_pcnt !== 32'd1) bad("B1 pps_out did not fire once per 1000 ticks");
    ticks(1000);
    if (r_pcnt !== 32'd2) bad("B1 pps_out period wrong");
    if (r_sloss !== 1'b0) bad("B1 sync_loss must not assert before the timeout");
    ticks(1200);                       // 累计 > SYNC_TIMEOUT(3000)
    if (r_sloss !== 1'b1) bad("B1 sync_loss must assert after the timeout");
    // B2 大误差 → 跳变
    pps_at(32'd300);
    if (r_jmp !== 32'd1) bad("B2 jump_cnt wrong");
    // PPS 上升沿要过 2 拍同步器，相位可能已推进 1~3 μs
    if (r_err < 32'd298 || r_err > 32'd305) badv("B2 last_err wrong on jump", r_err, 32'd300);
    if (r_ph > 32'd8) bad("B2 phase not realigned by jump");
    if (r_lock !== 1'b0) bad("B2 must not be locked right after a jump");
    // B3 小误差 → 平滑（adj = err>>2）
    pps_at(32'd40);
    if (r_stp !== 32'd1) bad("B3 step_cnt wrong");
    if (r_err < 32'd38 || r_err > 32'd45) badv("B3 last_err wrong on smooth step", r_err, 32'd40);
    if (r_ph < 32'd24 || r_ph > 32'd42) badv("B3 smoothed phase out of range", r_ph, 32'd30);
    // B4 反复对齐 → locked
    for (i = 0; i < 8; i = i + 1) pps_at(32'd0);
    if (r_lock !== 1'b1) bad("B4 never locked after repeated in-phase PPS");
    if (r_sloss !== 1'b0) bad("B4 sync_loss must clear while PPS present");
    // B5 失步看门狗
    ticks(3200);
    if (r_sloss !== 1'b1) bad("B5 sync_loss did not re-assert after timeout");
    // B6 HOLD 冻结相位
    r_hold = 1; e = r_ph; ticks(50);
    if (r_ph !== e) bad("B6 HOLD did not freeze the second phase");
    r_hold = 0;

    // ---------------- C ----------------
    $readmemh("vec/t15_mgmt.hex", vec);
    ncase = vec[0];
    if (ncase < 10) bad("C0 mgmt vector file missing");
    vi2 = 1;
    for (i = 0; i < ncase; i = i + 1) begin
      cid = vec[vi2][31:24];
      clen[cid]  = vec[vi2][15:0];
      cplen[cid] = vec[vi2+1];
      caux[cid]  = vec[vi2+2];
      cbase[cid] = vi2 + 3;
      vi2 = vi2 + 3 + (vec[vi2][15:0] + 3) / 4;
    end
    repeat (7) @(negedge clk); reset = 0;
    waitc = 0;
    while (dut.init_done !== 1 && waitc < 26000) begin @(negedge clk); waitc = waitc + 1; end
    if (waitc >= 26000) bad("C0 INIT_DONE timeout");
    host_write(16'h0008, 32'h2000);
    host_write(16'h0078, 32'h172D); host_write(16'h007C, 32'hAB61);
    host_write(16'h42B2, 32'h1010_0100); host_write(16'h0080, 32'h1);
    host_write(16'h1F80, W0_VL); host_write(16'h1F81, 32'h0000_0100);
    host_write(PT_SAP,   32'h8006_0000); host_write(PT_SAP+1, 32'h0000_1388);
    host_write(PT_SAP+2, 32'd0);         host_write(PT_SAP+3, 32'd1);
    host_write(16'h0008, 32'h051E);
    // C1 WRQ 上线 → ACK(0)
    drive_case(0);
    host_read(16'hAC23, d); if (d !== 32'd1) bad("C1 TFTP pkt_cnt wrong");
    host_read(16'hAC19, d); if (d < 32'd15) bad("C1 SAP payload byte count too small");
    host_read(16'hAC26, d);
    if (d[11] !== 1'b1 || d[10:0] !== 11'd4) bad("C1 no ACK queued for on-wire WRQ");
    mgmt_byte(0,bb); if (bb !== 8'h00) bad("C1 ACK byte0");
    mgmt_byte(1,bb); if (bb !== 8'h04) bad("C1 ACK byte1");
    mgmt_byte(2,bb); if (bb !== 8'h00) bad("C1 ACK byte2");
    mgmt_byte(3,bb); if (bb !== 8'h00) bad("C1 ACK block must be 0");
    host_write(16'hAC28, 32'd1);
    // C2 DATA blk1 (32 B)
    drive_case(1);
    host_read(16'hAC23, d); if (d !== 32'd2) badv("C2 pkt_cnt wrong", d, 32'd2);
    host_read(16'hAC20, d);
    if (d[31] !== 1'b0) bad("C2 a full 512 B block must not end the session");
    host_read(16'hAC25, d);
    if (d[31:16] !== 16'd2) badv("C2 blk_expect wrong", {16'd0,d[31:16]}, 32'd2);
    host_read(16'hAC21, d); if (d !== 32'd512) badv("C2 bytes_rcvd wrong", d, 32'd512);
    host_read(16'hAC22, d);
    if (d !== caux[1][31:0]) badv("C2 running CRC32 differs from Python golden", d, caux[1][31:0]);
    host_write(16'hAC28, 32'd1);
    // C3 DATA blk2 (8 B, 末块)
    drive_case(2);
    host_read(16'hAC21, d); if (d !== 32'd520) badv("C3 bytes_rcvd wrong after final block", d, 32'd520);
    host_read(16'hAC20, d);
    if (d[31] !== 1'b1) bad("C3 loaded_ok not set");
    if (d[15:0] !== 16'd0) bad("C3 err_code must stay 0");
    host_read(16'hAC22, d);
    if (d !== caux[2][31:0]) bad("C3 final CRC32 differs from Python golden");
    host_write(16'hAC28, 32'd1);
    // C4 加载区回读（0xCC20 起，8192 字）
    for (i = 0; i < 520; i = i + 4) begin
      host_read(16'hCC20 + i[15:0]/4, d);
      for (k = 0; k < 4; k = k + 1)
        if (i + k < 520) begin
          e = (i+k < 512) ? (((i+k)*7 + 8'h21) & 8'hFF)
                          : ((((i+k-512)+32)*7 + 8'h21) & 8'hFF);
          if (d[31-8*k -: 8] !== e[7:0] && errors < 6)
            badv("C4 load-area readback mismatch", {24'd0, d[31-8*k -: 8]}, e);
          else if (d[31-8*k -: 8] !== e[7:0]) errors = errors + 1;
        end
    end
    host_read(16'h0010, d); if (d[0] !== 1'b0) bad("C4 load-area read set ERR.ACC");
    // C5 无会话 DATA → ERROR(5)
    drive_case(3);
    host_read(16'hAC20, d); if (d[15:0] !== 16'd5) bad("C5 expected ERROR(5) code");
    host_write(16'hAC28, 32'd1);
    // C6 白名单外的 WRQ → ERROR(2)
    drive_case(5);
    host_read(16'hAC20, d); if (d[15:0] !== 16'd2) bad("C6 expected ERROR(2) access violation");
    host_write(16'hAC28, 32'd1);
    // C7 RRQ STATUS → DATA(1)
    drive_case(7);
    host_read(16'hAC26, d);
    if (d[11] !== 1'b1 || d[10:0] !== 11'd36) bad("C7 RRQ DATA length wrong");
    mgmt_byte(1,bb); if (bb !== 8'h03) bad("C7 RRQ must answer with DATA");
    mgmt_byte(4,bb); if (bb !== "A") bad("C7 STATUS payload magic");
    host_write(16'hAC28, 32'd1);
    // C8 非法操作码 → ERROR(4)
    drive_case(9);
    host_read(16'hAC20, d); if (d[15:0] !== 16'd4) bad("C8 expected ERROR(4)");
    // C9 顶层 RTC：pps_out 真实产生、pps_in 真实纠偏、观测窗可读
    host_read(16'hAC34, d);
    if (d < 32'd1) badv("C9 top-level PPS output never fired", d, 32'd1);
    if (pps_seen < 1) bad("C9 pps_out pin never pulsed");
    host_read(16'hAC30, d);
    if (d[1] !== 1'b1) bad("C9 sync_loss must be set before any PPS input");
    host_read(16'hAC32, e);                         // jump_cnt
    for (i = 0; i < 6; i = i + 1) begin
      @(negedge clk); tb_pps = 1'b1; repeat (30) @(negedge clk);
      tb_pps = 1'b0; repeat (200) @(negedge clk);
    end
    host_read(16'hAC32, d); host_read(16'hAC33, e);
    if ((d + e) < 32'd1) bad("C9 external PPS produced no discipline event");
    host_read(16'hAC30, d);
    if (d[1] !== 1'b0) bad("C9 sync_loss must clear once PPS is present");
    host_read(16'hAC36, e);
    repeat (600) @(negedge clk);
    host_read(16'hAC36, d);
    if (d <= e) bad("C9 corrected RTC did not advance");
    host_read(16'hAC38, d);
    if (d !== dut.uptime_cs) bad("C9 uptime_cs readback mismatch");
    // C10 SAP 块全部归还
    if (dut.rx_free_map !== 16'hFFC0) bad("C10 SAP blocks not returned to RX pool");
    host_read(16'hAC10, e); host_read(16'hAC11, d);
    if (d !== e) bad("C10 SAP accept/return counters diverged");

    if (errors == 0)
      $display("T16 TFTP/RTC PASS (unit tftp: WRQ/DATA/dup/final/CRC/whitelist/mode/RRQ/ACK/illegal/retry; unit rtc: period/jump/smooth/lock/loss/hold; top: %0d on-wire SAP frames, load area verified, pps fired)", 8);
    else
      $display("T16 TFTP/RTC FAIL (errors=%0d)", errors);
    $finish;
  end
  initial begin
    #300_000_000; $display("T16 TFTP/RTC FAIL: timeout"); $finish;
  end
endmodule
