// =====================================================================
// tb_t02_tx_buf_sn.v —— 第 2 周发送侧存储/SN 单测（§7.1 / §7.4 / §6.6）
// 检查 1: tx_sn_gen —— 复位后首帧 SN=1；连续 commit 递增；255→1 回绕且
//         永不出 0；未 commit 的 snap 不消耗 SN；同拍 commit+snap 同 VL
//         旁路；多 VL 互不干扰；host_override；重复申请 err；init_all 清零。
// 检查 2: tx_port_buf —— 采样口 commit/覆盖（ovr_cnt、fresh、旧块回收）/
//         take；队列口 depth=3 FIFO 顺序 + 满拒写（q_ovf_cnt、buf_full、
//         commit_rej）+ 拒写块退回；TX 池 6 块耗尽（pmem_exhaust_cnt、
//         wr_blk_vld=0）+ blk_free 后恢复；commit 与 take 同拍（T17 前置:
//         commit 优先、take 挂起 1 拍、pending 置位、结果仍正确）；
//         描述符只读口位域；随机 2000 事件对照 TB 参考模型（队列长度、
//         位图、块守恒 free+open+inuse == 6）。
// 判据: 末行 "T02 TXBUF PASS" / "T02 TXBUF FAIL: n errors"
// =====================================================================
`timescale 1 ns / 1 ps
module tb_t02_tx_buf_sn;
  reg clk = 1'b0;
  reg reset = 1'b1;
  always #4 clk = ~clk;               // 125 MHz
  integer err = 0;
  integer i, j, n;

  // ---------------------------------------------------------------
  // DUT 1: tx_sn_gen
  // ---------------------------------------------------------------
  reg        s_req = 0, s_commit = 0, s_cancel = 0, s_init = 0, s_ovr_we = 0;
  reg  [7:0] s_req_vl = 0, s_commit_vl = 0, s_ovr_vl = 0, s_ovr_val = 0;
  wire [7:0] s_snap;
  wire       s_ack, s_err;
  wire [1:0] s_pend;
  tx_sn_gen #(.NUM_TX_VL(128)) u_sn (
    .clk(clk), .rst_sync(reset),
    .snap_req(s_req), .snap_vl(s_req_vl), .snap(s_snap), .snap_ack(s_ack),
    .cancel(s_cancel), .commit(s_commit), .commit_vl(s_commit_vl),
    .init_all(s_init), .ovr_we(s_ovr_we), .ovr_vl(s_ovr_vl), .ovr_val(s_ovr_val),
    .sn_pend(s_pend), .err(s_err));

  reg [7:0] got_sn;
  // 申请并等 ack（1 拍）
  task sn_snap; input [7:0] vl; output [7:0] sn;
    begin
      @(negedge clk); s_req <= 1'b1; s_req_vl <= vl;
      @(negedge clk); s_req <= 1'b0;
      if (s_ack !== 1'b1) begin $display("  [err] sn: no ack vl=%0d", vl); err = err + 1; end
      sn = s_snap;
    end
  endtask
  task sn_commit; input [7:0] vl;
    begin
      @(negedge clk); s_commit <= 1'b1; s_commit_vl <= vl;
      @(negedge clk); s_commit <= 1'b0;
    end
  endtask
  task sn_expect; input [7:0] vl; input [7:0] want;
    begin
      sn_snap(vl, got_sn);
      if (got_sn !== want) begin
        $display("  [err] sn vl=%0d got=%0d want=%0d", vl, got_sn, want); err = err + 1;
      end
    end
  endtask

  // ---------------------------------------------------------------
  // DUT 2: tx_port_buf
  // ---------------------------------------------------------------
  reg  [7:0]  tb_us = 8'd0;
  always @(posedge clk) tb_us <= tb_us + 8'd1;   // 加速时基（只看 age 采样）
  reg         p_commit = 0, p_take = 0, p_free = 0;
  reg  [7:0]  p_port = 0, p_tport = 0, p_daddr = 0;
  reg  [15:0] p_len = 0;
  reg  [1:0]  p_type = 0;
  reg  [3:0]  p_depth = 1, p_free_id = 0;
  wire        p_rej, p_wblk_vld, p_ack, p_pending;
  wire [3:0]  p_wblk, p_blk;
  wire [12:0] p_slen;
  wire [31:0] p_ddata;
  wire [255:0] p_req, p_full;
  wire [15:0] p_free_map, p_ovr, p_qovf, p_exh;
  tx_port_buf #(.NUM_PORTS(256), .TX_BLK_LO(0), .TX_BLK_N(6)) u_pb (
    .clk(clk), .rst_sync(reset), .tb_us(tb_us),
    .msg_commit(p_commit), .port_id(p_port), .len(p_len),
    .port_type(p_type), .port_depth(p_depth), .commit_rej(p_rej),
    .wr_blk(p_wblk), .wr_blk_vld(p_wblk_vld),
    .desc_rd_addr(p_daddr), .desc_rd_data(p_ddata),
    .sch_req(p_req), .buf_full(p_full),
    .sch_take(p_take), .sch_port(p_tport), .sch_ack(p_ack),
    .sch_blk(p_blk), .sch_len(p_slen),
    .blk_free(p_free), .blk_free_id(p_free_id),
    .free_map(p_free_map), .ovr_cnt(p_ovr), .q_ovf_cnt(p_qovf),
    .pmem_exhaust_cnt(p_exh), .pending(p_pending));

  // ---- 参考模型 ----
  reg [3:0]  m_q [0:255][0:7];      // 每端口块队列
  reg [12:0] m_l [0:255][0:7];
  integer    m_cnt [0:255];
  reg [1:0]  m_type [0:255];
  integer    m_depth [0:255];
  reg [15:0] m_free;                // 参考空闲位图（含开放块之外）
  integer    m_inuse;               // 在途块（已 take 未 free）
  integer    m_ovr, m_qovf, m_exh;

  reg [3:0]  last_blk;              // 最近一次 commit 用到的块
  reg        last_rej;

  // commit：记录使用的开放块，等 1 拍看 rej
  task pb_commit; input [7:0] port; input [15:0] len; input [1:0] typ; input [3:0] dep;
    reg had_blk; reg [3:0] blk;
    begin
      @(negedge clk);
      had_blk = p_wblk_vld; blk = p_wblk;
      p_commit <= 1'b1; p_port <= port; p_len <= len; p_type <= typ; p_depth <= dep;
      @(negedge clk); p_commit <= 1'b0;
      @(negedge clk);              // rej 在 commit 后 2 拍（S1 对齐）
      last_rej = p_rej; last_blk = blk;
      // 参考模型
      m_type[port] = typ; m_depth[port] = (dep == 0) ? 1 : dep;
      if (!had_blk) begin
        m_exh = m_exh + 1;
        if (!last_rej) begin $display("  [err] commit p%0d: no block but not rejected", port); err = err + 1; end
      end else if (typ == 2'd0) begin
        if (m_cnt[port] != 0) begin m_ovr = m_ovr + 1; m_free[m_q[port][0]] = 1'b1; end
        m_q[port][0] = blk; m_l[port][0] = len[12:0]; m_cnt[port] = 1;
        m_free[blk] = 1'b0;
        if (last_rej) begin $display("  [err] commit p%0d sampling rejected", port); err = err + 1; end
      end else if (m_cnt[port] >= m_depth[port]) begin
        m_qovf = m_qovf + 1;
        if (!last_rej) begin $display("  [err] commit p%0d queue full but accepted", port); err = err + 1; end
      end else begin
        m_q[port][m_cnt[port]] = blk; m_l[port][m_cnt[port]] = len[12:0];
        m_cnt[port] = m_cnt[port] + 1; m_free[blk] = 1'b0;
        if (last_rej) begin $display("  [err] commit p%0d queue rejected cnt=%0d dep=%0d", port, m_cnt[port], m_depth[port]); err = err + 1; end
      end
    end
  endtask

  // take：等 ack（S0→S1→ack = 2 拍）
  reg [3:0] took_blk;
  task pb_take; input [7:0] port;
    integer k;
    begin
      @(negedge clk); p_take <= 1'b1; p_tport <= port;
      @(negedge clk); p_take <= 1'b0;
      @(negedge clk);
      if (m_cnt[port] == 0) begin
        if (p_ack) begin $display("  [err] take p%0d empty but ack", port); err = err + 1; end
      end else begin
        if (!p_ack) begin $display("  [err] take p%0d no ack", port); err = err + 1; end
        if (p_blk !== m_q[port][0] || p_slen !== m_l[port][0]) begin
          $display("  [err] take p%0d got blk=%0d len=%0d want blk=%0d len=%0d",
                   port, p_blk, p_slen, m_q[port][0], m_l[port][0]); err = err + 1;
        end
        took_blk = m_q[port][0];
        for (k = 0; k < 7; k = k + 1) begin m_q[port][k] = m_q[port][k+1]; m_l[port][k] = m_l[port][k+1]; end
        m_cnt[port] = m_cnt[port] - 1;
        m_inuse = m_inuse + 1;
      end
    end
  endtask
  task pb_free; input [3:0] blk;
    begin
      @(negedge clk); p_free <= 1'b1; p_free_id <= blk;
      @(negedge clk); p_free <= 1'b0;
      m_free[blk] = 1'b1; m_inuse = m_inuse - 1;
    end
  endtask

  // 对账：位图 / 满位 / 块守恒
  integer nfree, nq, chk_k;
  task pb_check; input [255:0] tag;
    begin
      @(negedge clk); @(negedge clk);
      for (chk_k = 0; chk_k < 256; chk_k = chk_k + 1) begin
        if (p_req[chk_k] !== (m_cnt[chk_k] != 0)) begin
          $display("  [err] %0s sch_req[%0d]=%b model cnt=%0d", tag, chk_k, p_req[chk_k], m_cnt[chk_k]); err = err + 1;
        end
        if (m_type[chk_k] != 2'd0 && m_cnt[chk_k] != 0 &&
            p_full[chk_k] !== (m_cnt[chk_k] >= m_depth[chk_k])) begin
          $display("  [err] %0s buf_full[%0d]=%b model cnt=%0d dep=%0d", tag, chk_k, p_full[chk_k], m_cnt[chk_k], m_depth[chk_k]); err = err + 1;
        end
      end
      // 块守恒: free_map + open + queued + inuse == 6
      nfree = 0; nq = 0;
      for (chk_k = 0; chk_k < 16; chk_k = chk_k + 1) nfree = nfree + p_free_map[chk_k];
      for (chk_k = 0; chk_k < 256; chk_k = chk_k + 1) nq = nq + m_cnt[chk_k];
      if (nfree + (p_wblk_vld ? 1 : 0) + nq + m_inuse != 6) begin
        $display("  [err] %0s block conservation: free=%0d open=%0d queued=%0d inuse=%0d", tag, nfree, p_wblk_vld, nq, m_inuse); err = err + 1;
      end
      if (p_ovr !== m_ovr[15:0] || p_qovf !== m_qovf[15:0] || p_exh !== m_exh[15:0]) begin
        $display("  [err] %0s counters ovr=%0d/%0d qovf=%0d/%0d exh=%0d/%0d", tag, p_ovr, m_ovr, p_qovf, m_qovf, p_exh, m_exh); err = err + 1;
      end
    end
  endtask

  reg [7:0] sn_a, sn_b;
  reg [3:0] b0, b1, b2;
  integer rnd, op, port, rlen, rtype, rdep;
  initial begin
    for (i = 0; i < 256; i = i + 1) begin m_cnt[i] = 0; m_type[i] = 0; m_depth[i] = 1; end
    m_free = 16'h003F; m_inuse = 0; m_ovr = 0; m_qovf = 0; m_exh = 0;
    repeat (4) @(negedge clk);
    reset <= 1'b0;
    repeat (3) @(negedge clk);

    // =============================================================
    $display("== check 1: tx_sn_gen");
    // 1a 复位后首帧 SN=1，未 commit 再申请仍 1（不消耗）
    sn_expect(8'd5, 8'd1);
    sn_expect(8'd5, 8'd1);            // 触发 err（重复申请）但值不变
    if (s_err !== 1'b1) begin $display("  [err] sn: dup snap without err"); err = err + 1; end
    sn_commit(8'd5);
    sn_expect(8'd5, 8'd2);
    sn_commit(8'd5);
    sn_expect(8'd5, 8'd3);
    sn_commit(8'd5);
    // 1b 多 VL 独立
    sn_expect(8'd0, 8'd1); sn_commit(8'd0);
    sn_expect(8'd127, 8'd1); sn_commit(8'd127);
    sn_expect(8'd5, 8'd4); sn_commit(8'd5);
    sn_expect(8'd0, 8'd2); sn_commit(8'd0);
    // 1c 回绕：override 到 254 → 254, 255, 1, 2（永不 0）
    @(negedge clk); s_ovr_we <= 1'b1; s_ovr_vl <= 8'd9; s_ovr_val <= 8'd254;
    @(negedge clk); s_ovr_we <= 1'b0;
    sn_expect(8'd9, 8'd254); sn_commit(8'd9);
    sn_expect(8'd9, 8'd255); sn_commit(8'd9);
    sn_expect(8'd9, 8'd1);   sn_commit(8'd9);
    sn_expect(8'd9, 8'd2);   sn_commit(8'd9);
    // 1d 全程 255 次 commit 扫一遍，收集是否出现 0
    for (i = 0; i < 300; i = i + 1) begin
      sn_snap(8'd77, sn_a);
      if (sn_a == 8'd0) begin $display("  [err] sn 0 emitted at iter %0d", i); err = err + 1; end
      sn_commit(8'd77);
    end
    // 第 1 帧 SN=1 … 第 255 帧 SN=255，第 256 帧 SN=1，第 300 帧 SN=45 → 下次 46
    sn_expect(8'd77, 8'd46);
    // 1e 同拍 commit + snap 同 VL：应拿到 commit 后的新值
    @(negedge clk); s_req <= 1'b1; s_req_vl <= 8'd77; s_commit <= 1'b1; s_commit_vl <= 8'd77;
    @(negedge clk); s_req <= 1'b0; s_commit <= 1'b0;
    sn_b = s_snap;                    // 上面 sn_expect 未 commit 时挂起 46；同拍 commit(46)+snap → 47
    if (sn_b !== 8'd47) begin $display("  [err] same-cycle commit+snap got=%0d want=47", sn_b); err = err + 1; end
    sn_commit(8'd77);
    // 1f init_all
    @(negedge clk); s_init <= 1'b1; @(negedge clk); s_init <= 1'b0;
    sn_expect(8'd77, 8'd1); sn_commit(8'd77);
    sn_expect(8'd5, 8'd1);
    if (s_pend !== 2'd1) begin $display("  [err] sn_pend after snap = %0d", s_pend); err = err + 1; end
    sn_commit(8'd5);
    if (s_pend !== 2'd0) begin $display("  [err] sn_pend after commit = %0d", s_pend); err = err + 1; end
    // Failed staged fragments release the pending snapshot without increment.
    sn_expect(8'd3,8'd1);
    @(negedge clk);s_commit_vl=3;s_cancel=1;
    @(negedge clk);s_cancel=0;
    if(s_pend!==0 || s_err)begin $display("  [err] cancel did not clear snapshot");err=err+1;end
    sn_expect(8'd3,8'd1);
    @(negedge clk);s_cancel=1;s_req=1;s_req_vl=3;
    @(negedge clk);s_cancel=0;s_req=0;
    if(s_pend!==1 || s_err || s_snap!==1)begin $display("  [err] cancel/request collision");err=err+1;end
    sn_commit(8'd3);sn_expect(8'd3,8'd2);
    @(negedge clk);s_commit_vl=4;s_cancel=1;
    @(negedge clk);
    if(s_pend!==1 || !s_err)begin $display("  [err] wrong-owner cancel accepted");err=err+1;end
    s_commit_vl=3;s_commit=1;
    @(negedge clk);s_cancel=0;s_commit=0;
    sn_expect(8'd3,8'd2);sn_commit(8'd3);
    $display("  [ok] tx_sn_gen basic/wrap/override/init/cancel");

    // =============================================================
    $display("== check 2: tx_port_buf");
    pb_check("init");
    if (!p_wblk_vld) begin $display("  [err] no open block after reset"); err = err + 1; end
    // 2a 采样口 p3：commit → req；再 commit 覆盖 → ovr=1；take → 拿到第二块
    pb_commit(8'd3, 16'd100, 2'd0, 4'd1);
    b0 = last_blk;
    pb_check("smp1");
    pb_commit(8'd3, 16'd200, 2'd0, 4'd1);
    b1 = last_blk;
    pb_check("smp2");
    // 描述符只读口: valid=1 fresh=1 blk=b1 len=200
    @(negedge clk); p_daddr <= 8'd3; @(negedge clk); @(negedge clk);
    if (p_ddata[27] !== 1'b1 || p_ddata[25] !== 1'b1 || p_ddata[24:21] !== b1 || p_ddata[20:8] !== 13'd200) begin
      $display("  [err] desc p3 = %h (want valid,fresh,blk=%0d,len=200)", p_ddata, b1); err = err + 1;
    end
    pb_take(8'd3);
    pb_check("smp3");
    pb_take(8'd3);                    // 空取: 无 ack
    pb_free(took_blk);
    pb_check("smp4");
    // 2b 队列口 p10 depth=3：4 次 commit，第 4 次拒；顺序 take
    pb_commit(8'd10, 16'd11, 2'd1, 4'd3);
    pb_commit(8'd10, 16'd22, 2'd1, 4'd3);
    pb_check("q2");
    pb_commit(8'd10, 16'd33, 2'd1, 4'd3);
    pb_check("q3");
    if (p_full[10] !== 1'b1) begin $display("  [err] buf_full[10] not set at depth"); err = err + 1; end
    pb_commit(8'd10, 16'd44, 2'd1, 4'd3);   // 拒
    pb_check("q4rej");
    pb_take(8'd10); b0 = took_blk;
    pb_take(8'd10); b1 = took_blk;
    pb_check("q5");
    pb_commit(8'd10, 16'd55, 2'd1, 4'd3);
    pb_take(8'd10); b2 = took_blk;
    pb_take(8'd10);
    pb_check("q6");
    pb_free(b0); pb_free(b1); pb_free(b2); pb_free(took_blk);
    pb_check("q7");
    // 2c 块耗尽：6 块池，队列 p20 depth 8 连续提交 → 第 6 次后 wr_blk_vld=0，第 7 次拒 exh
    for (i = 0; i < 7; i = i + 1) pb_commit(8'd20, 16'd64 + i, 2'd1, 4'd8);
    pb_check("exh");
    if (p_wblk_vld) begin $display("  [err] wr_blk_vld still 1 after exhausting pool"); err = err + 1; end
    if (m_exh != 1) begin $display("  [err] model exh=%0d (test assumption)", m_exh); err = err + 1; end
    pb_take(8'd20); pb_free(took_blk);
    pb_check("exh_recover");
    if (!p_wblk_vld) begin $display("  [err] open block not re-acquired after free"); err = err + 1; end
    for (i = 0; i < 5; i = i + 1) begin pb_take(8'd20); pb_free(took_blk); end
    pb_check("drain");
    // 2d 同拍 commit(p30 采样) + take(p31 队列，已有 1 条) → 都成功
    pb_commit(8'd31, 16'd7, 2'd1, 4'd2);
    @(negedge clk);
    b0 = p_wblk;
    p_commit <= 1'b1; p_port <= 8'd30; p_len <= 16'd9; p_type <= 2'd0; p_depth <= 4'd1;
    p_take <= 1'b1; p_tport <= 8'd31;
    @(negedge clk); p_commit <= 1'b0; p_take <= 1'b0;
    if (p_pending !== 1'b1) begin $display("  [err] pending not flagged on same-cycle commit+take"); err = err + 1; end
    @(negedge clk); @(negedge clk);
    if (p_ack !== 1'b1 || p_blk !== m_q[31][0] || p_slen !== 13'd7) begin
      $display("  [err] deferred take: ack=%b blk=%0d len=%0d", p_ack, p_blk, p_slen); err = err + 1;
    end
    took_blk = m_q[31][0]; m_cnt[31] = 0; m_inuse = m_inuse + 1;
    m_q[30][0] = b0; m_l[30][0] = 13'd9; m_cnt[30] = 1; m_type[30] = 0; m_free[b0] = 0;
    pb_check("same_cycle");
    pb_free(took_blk);
    pb_take(8'd30); pb_free(took_blk);
    pb_check("same_cycle_done");

    // 2e 随机 2000 事件（端口 0..7 混合类型，深度 1..3）
    rnd = 32'h1234_5678;
    for (n = 0; n < 2000; n = n + 1) begin
      rnd = $random(rnd);
      op = (rnd & 32'h7FFF_FFFF) % 10; port = ((rnd >> 8) & 7); rlen = 1 + (((rnd >> 12) & 32'h7FFF) % 1471);
      rtype = (port < 3) ? 0 : 1; rdep = 1 + (port % 3);
      if (m_type[port] == 0 && rtype != 0 && m_cnt[port] != 0) rtype = 0;   // 不在非空时改类型
      if (op < 5)       pb_commit(port[7:0], rlen[15:0], rtype[1:0], rdep[3:0]);
      else if (op < 8)  begin pb_take(port[7:0]); if (p_ack) begin
                          rnd = $random(rnd);
                          if (rnd[0]) pb_free(took_blk); else begin
                            // 延迟释放：立刻在下一个 op 里释放，简化为直接释放
                            pb_free(took_blk);
                          end
                        end end
      else if (n % 50 == 0) pb_check("rand");
    end
    pb_check("rand_final");
    $display("  [ok] tx_port_buf sampling/queue/exhaust/same-cycle/random 2000");

    if (err == 0)
      $display("T02 TXBUF PASS (tx_sn_gen wrap/override/init; tx_port_buf smp/queue/exhaust/T17-pending/random)");
    else
      $display("T02 TXBUF FAIL: %0d errors", err);
    $finish;
  end

  initial begin
    $dumpfile("out/t02_tx_buf_sn.vcd");
    $dumpvars(0, tb_t02_tx_buf_sn);
  end
endmodule
