// =====================================================================
// T60 — P08 IPv4 分片重组 顶层端到端验证
//
// 数据来源：sw/golden/gen_t60_vectors.py 生成的 sim/vec/t60_reasm.hex
//   （独立 golden：分片 IP 头、UDP 头、FCS 全部由 Python 模型计算，
//     不复用 DUT 任何内部信号）
//
// 端口约定：PORT=5 单播，VLID=5，MAC 由 afdx_model.dmac_of/smac_of 生成。
// 重组后整消息长度 MSG_LEN=636，负载 = (i*7 + (i/8)*13 + 0x5A) & 0xFF。
//
// 用例（与向量文件顺序一致）：
//   in-order     两片按序 → 投递 1 条消息，hit+1，上下文释放
//   delayed-tail 首片等待超过 1ms 后补末片 → 等待中不交付、补齐后交付
//   out-of-order 末片先到   → 末片到达不投递；首片补齐时投递
//   overlap      重叠片     → 整组作废，不投递
//   three-frag   三片       → 投递 1 条消息
//
// 字节交付通过公共 host 接口核对；内部探针用于诊断及资源/时序断言。
// =====================================================================
`timescale 1 ns / 1 ps
module tb_t60_reasm_e2e;
  reg clk=0, reset=1;
  always #4 clk=~clk;

  reg  [7:0] rx_data=0;
  reg        rx_valid=0;
  wire [7:0] tx_data[0:1];
  wire       tx_valid[0:1];
  wire hcs,hwe,hack;
  wire [15:0] haddr;
  wire [31:0] hwdata,hrdata;

  AFDX_top dut (
    .clk(clk),.reset(reset),.tx_data(tx_data[0]),.tx_valid(tx_valid[0]),.tx_ready(),
    .rx_data(rx_data),.rx_valid(rx_valid),.rx_ready(1'b0),.rx_error(1'b0),
    .tx_data_b(tx_data[1]),.tx_valid_b(tx_valid[1]),.tx_ready_b(),
    .rx_data_b(8'd0),.rx_valid_b(1'b0),.rx_ready_b(1'b0),.rx_error_b(1'b0),
    .host_cs(hcs),.host_we(hwe),.host_addr(haddr),.host_wdata(hwdata),
    .host_rdata(hrdata),.host_ack(hack),.host_irq(),
    .pps_in(1'b0),.pps_out(),.rtc_time_us(),.dbg_frame_event());
  afdx_host_bfm u_host (.clk(clk),.cs(hcs),.we(hwe),.addr(haddr),.wdata(hwdata),.rdata(hrdata),.ack(hack));

  integer errors=0, checks=0, cycle=0;
  always @(posedge clk) cycle<=cycle+1;
  task bad; input [8*112-1:0] r; begin
    if(errors<25) $display("  [err] T60 cyc=%0d %0s",cycle,r); errors=errors+1; end endtask
  task chk; input c; input [8*112-1:0] r; begin checks=checks+1; if(!c) bad(r); end endtask

  integer PORT = 5;
  integer MSG_LEN = 636;
  // VLID 与 index=5 同值（T35 哈希映像中 VLID5→index5）
  localparam integer VLID = 5;

  // ---------------- 向量读取 ----------------
  localparam integer VMAX = 60000;
  integer vec_fd, vec_scan, vec_words;
  reg [31:0] vec_word;
  reg [31:0] vec[0:VMAX-1];
  integer pos;            // 当前读取位置

  // ---------------- RX VL 查找表配置（与 T35 同源） ----------------
  // T60 只用一个 VL（VLID=5, index=5），故加载完整哈希映像 + 该 index 的 RX 配置。
  reg [31:0] himg[0:8191];
  reg [31:0] hmeta[0:3];

  task read_word; input [15:0] a; output [31:0] v; integer g; begin
    @(negedge clk); u_host.cs=1; u_host.we=0; u_host.addr=a;
    @(negedge clk); g=0;
    while(hack!==1'b1 && g<64) begin @(negedge clk); g=g+1; end
    if(hack!==1'b1) bad("host read timeout");
    v=hrdata; u_host.cs=0;
  end endtask

  // 消息计数窗口：0x8480 + 端口号（不是 port*4）。hop_port = host_addr[7:0]-0x80，
  // 故读取地址 0x8480+p 对应的端口号即 p，与 T11/T21/T13 等既有测试一致。
  reg [31:0] v_dummy;
  task msg_cnt; output [31:0] v; begin read_word(16'h8480+PORT, v); end endtask

  task wait_message;
    input [31:0] target;
    integer wg; reg [31:0] count;
    begin
      // Interval prep alone is MAX_FRAGS^2+MAX_FRAGS (~272) cycles per fragment;
      // slot-reuse injects 18 fragments plus copy/check, so keep a wide bound.
      wg=0; msg_cnt(count);
      while(count != target && wg<512) begin
        repeat(256) @(negedge clk);
        msg_cnt(count); wg=wg+1;
      end
      if(count != target) bad("message delivery did not complete within bounded wait");
    end
  endtask

  // Poll AC2D until reassembly owns the expected number of contexts.
  // Fixed short gaps (60/200) are shorter than the sequential interval prep.
  task wait_reasm_used;
    input [31:0] want_used;
    integer wg; reg [31:0] used;
    begin
      wg=0; read_word(16'hAC2D,used);
      while(used !== want_used && wg<4096) begin
        @(negedge clk);
        read_word(16'hAC2D,used);
        wg=wg+1;
      end
    end
  endtask

  // 排空端口队列：先读描述符（0x8180+p，解 pin），再写 MSG_RD（0x8380+p=0）弹出。
  // 每个用例都投递 1 条消息；不排空的话 depth=1 的队列在下个用例必然溢出
  // （表现为后续用例 MSG_CNT 不增、qovf 计数上涨）。
  task drain_port;
    integer n, g, guard;
    begin
      g = 0;
      read_word(16'h8480+PORT, n);
      while (g < 8 && n != 32'd0) begin
        read_word(16'h8180+PORT, v_dummy);          // descriptor read (unpin)
        u_host.wr(16'h8380+PORT, 32'd0);            // MSG_RD pop
        for (guard=0; guard<8; guard=guard+1) @(negedge clk);
        read_word(16'h8480+PORT, n);
        g = g + 1;
      end
    end
  endtask

  // Read the delivered descriptor and all 636 application bytes through the
  // public host PMEM window. The IP/UDP headers are intentionally excluded.
  task check_host_payload;
    input integer payload_len;
    input integer corrupt_last;
    integer blk, word_ix, byte_ix, app_ix;
    reg [31:0] descw, dataw;
    reg [7:0] want;
    begin
      read_word(16'h8180+PORT, descw);
      chk(descw[31]===1'b1, "host descriptor valid after reassembly");
      chk(descw[10:0]===payload_len[10:0], "host descriptor application length matches vector");
      if (descw[31]===1'b1 && descw[10:0]===payload_len[10:0]) begin
        blk = descw[23:20];
        // In the raw-frame layout, first-fragment app byte 0 starts at byte 42.
        // Only read data after a valid public descriptor; otherwise invalid-block
        // reads create thousands of secondary errors after the primary failure.
        for (word_ix=0; word_ix<(payload_len+5)/4; word_ix=word_ix+1) begin
          read_word(16'h8800 + (blk<<9) + 11'd10 + word_ix, dataw);
          for (byte_ix=0; byte_ix<4; byte_ix=byte_ix+1) begin
            app_ix = word_ix*4 + byte_ix - 2; // byte 42 is lane 2 of word 10
            if (app_ix>=0 && app_ix<payload_len) begin
              want = (app_ix*7 + (app_ix/8)*13 + 8'h5A) & 8'hFF;
              if (corrupt_last && app_ix==payload_len-1) want=want ^ 8'h01;
              case (byte_ix)
                0: if (dataw[31:24]!==want) begin
                     if(errors<12) $display("  [payload] app=%0d got=%02x want=%02x blk=%0d",app_ix,dataw[31:24],want,blk);
                     errors=errors+1;
                   end
                1: if (dataw[23:16]!==want) begin
                     if(errors<12) $display("  [payload] app=%0d got=%02x want=%02x blk=%0d",app_ix,dataw[23:16],want,blk);
                     errors=errors+1;
                   end
                2: if (dataw[15:8]!==want) begin
                     if(errors<12) $display("  [payload] app=%0d got=%02x want=%02x blk=%0d",app_ix,dataw[15:8],want,blk);
                     errors=errors+1;
                   end
                3: if (dataw[7:0]!==want) begin
                     if(errors<12) $display("  [payload] app=%0d got=%02x want=%02x blk=%0d",app_ix,dataw[7:0],want,blk);
                     errors=errors+1;
                   end
              endcase
            end
          end
        end
      end else begin
        $display("  [diag] T60 skips payload reads: invalid public descriptor length=%0d",payload_len);
      end
    end
  endtask

  // 诊断：打印公开丢弃统计 + 一次性内部探针（仅定位用，非验收依据）
  // 诊断：打印公开丢弃统计 + 三级去向。仅在用例失败时由 TB 调用（见 chk_fail）。
  task diag; input [8*32-1:0] tag; reg [31:0] a,b,c,d; integer di; begin
    if (errors == 0) begin end else begin
    read_word(16'h001C,a);      // flt_drop_total
    read_word(16'h0040,b);      // unconf
    read_word(16'h0044,c);      // lmax
    read_word(16'h0048,d);      // ic drop
    read_word(16'hAC2D,a2);     // reasm 占用上下文数
    $display("  [diag] %0s flt_drop_total=%0d unconf=%0d lmax=%0d ic_drop=%0d reasm_used=%0d",
             tag, a,b,c,d,a2);
    $display("  [diag] reasm hit=%0d drop=%0d in=%b/%b copy=%b/%b busy=%b done=%b",
      dut.g_rx_legacy.u_rxreasm.hit_cnt, dut.g_rx_legacy.u_rxreasm.drop_cnt,
      dut.reasm_in_vld, dut.reasm_in_ready,
      dut.reasm_copy_valid, dut.reasm_copy_ready,
      dut.g_rx_legacy.u_rxreasm.copy_busy, dut.reasm_copy_done);
    for (di=0; di<8; di=di+1) begin
      if (dut.g_rx_legacy.u_rxreasm.slot_vld[di])
        $display("  [diag] slot%0d first=%b src_count=%0d frag_count=%0d end=%0d iv0=%b [%0d,%0d)",
          di, dut.g_rx_legacy.u_rxreasm.slot_has_first[di], dut.g_rx_legacy.u_rxreasm.slot_src_count[di],
          dut.g_rx_legacy.u_rxreasm.slot_frag[di], dut.g_rx_legacy.u_rxreasm.slot_end[di],
           dut.g_rx_legacy.u_rxreasm.frag_iv_valid[(di*16)+0],
           dut.g_rx_legacy.u_rxreasm.frag_iv_start[(di*16)+0],
           dut.g_rx_legacy.u_rxreasm.frag_iv_end[(di*16)+0]);
    end
    dump_trace;
    end
  end endtask
  reg [31:0] a2;

  // 读一条记录（一片帧）并注入。
  // 向量里的「长度」= 不含前导/SFD 的帧长（从 DMAC 起算、含 FCS），
  // 注入时需额外发 7 字节前导 + 1 字节 SFD。
  reg [7:0] fb[0:4095];
  integer flen;
  task load_and_inject_frag;
    integer i, nw, nb;
    begin
      flen = vec[pos]; pos = pos + 1;
      if (flen < 64 || flen > 4096) bad("vector fragment length out of range");
      nb = flen + 8;                       // 前导7 + SFD1 + 帧体
      nw = (nb + 3) / 4;
      for (i = 0; i < nw; i = i + 1) begin
        fb[i*4+0] = vec[pos][31:24];
        fb[i*4+1] = vec[pos][23:16];
        fb[i*4+2] = vec[pos][15:8];
        fb[i*4+3] = vec[pos][7:0];
        pos = pos + 1;
      end
      if (pos > VMAX) bad("vector overrun");
      @(negedge clk);
      for (i = 0; i < nb; i = i + 1) begin
        rx_valid = 1; rx_data = fb[i];
        @(negedge clk);
      end
      rx_valid = 0;
      repeat (8) @(negedge clk);
    end
  endtask

  // RX VL 配置字（与 T35 的 RX_W0 同构，仅把 Lmax 放大到 700 以容纳 646B 分片）：
  //   w0[31]=valid, w0[29:28]=net_mode(A网), w0[11:0]=Lmax
  localparam [31:0] RX_W0 = 32'hF500_0000 | (5<<12) | 32'd700;
  task configure;
    integer guard, i; reg [31:0] value;
    begin
      reset=1; repeat(8) @(negedge clk); reset=0;
      read_word(16'h000C,value); guard=0;
      while(!value[13] && guard<30000) begin read_word(16'h000C,value); guard=guard+1; end
      if(!value[13]) bad("default initialization timeout");
      // 1) 载入完整 RX VLID 哈希映像（0x3D80..，8192 字）并提交
      u_host.wr(16'h0008,32'h2000);
      u_host.wr(16'h0078,hmeta[0]); u_host.wr(16'h007C,hmeta[1]);
      for (i=0;i<8192;i=i+1) u_host.wr(16'h3D80+i, himg[i]);
      u_host.wr(16'h0080,1);
      read_word(16'h0080,value); if(value[0]!==1) bad("hash commit absent");
      // 2) 配置 RX VL 表：index=5 → w0 + key(=5)
      u_host.wr(16'h1D80+(5<<1), RX_W0);
      u_host.wr(16'h1D81+(5<<1), 32'd5);
      read_word(16'h1D80+(5<<1),value); if(value!==RX_W0) bad("RX cfg w0 readback");
      read_word(16'h1D81+(5<<1),value); if(value!==32'd5) bad("RX cfg key readback");
      // 3) 端口表 + TX/RX 开关
      u_host.wr(16'h1F80,32'hF5000000|(PORT<<12)|700);
      u_host.wr(16'h1F81,32'h0100);
      u_host.wr(16'h7D80+4*PORT,32'h80040000);
      u_host.wr(16'h7D81+4*PORT,5000);
      u_host.wr(16'h7D82+4*PORT,0);
      u_host.wr(16'h7D83+4*PORT,1);
      u_host.wr(16'h0204,PORT<<16);
      u_host.wr(16'h0203,0);
      u_host.wr(16'h0202,5000<<16);
      u_host.wr(16'h0201,1000<<8);
      u_host.wr(16'h0480,6040);
      u_host.wr(16'h0200,32'h80000003|(700<<12));
      u_host.wr(16'h0060,32'h172D2001); u_host.wr(16'h0064,32'h0A000002);
      u_host.wr(16'h0070,32'h0142);
      read_word(16'h005C,value); if(value!==0) bad("legal configuration rejected");
      // 开通 RX（bit1）；重组测试稍后单独设置 IC 与非冗余 RM 模式。
      u_host.wr(16'h0008,(1<<1));
      repeat(20) @(negedge clk);
    end
  endtask

  integer ncases, ci, nfrag, fi, reuse_i, cancel_guard;
  reg [31:0] v, base_cnt, base_drop;
  reg [15:0] rx_free_initial;
  integer neighbor_blk;
  reg [15:0] neighbor_before;
  reg copy_active=0, copy_committed=0;
  reg [3:0] active_copy_src=0;
  reg [3:0] active_copy_dst=0;
  integer expected_copy_bytes=0, committed_copy_bytes=0;
  integer copy_byte_lo=0, copy_byte_hi=0, monitor_lane, monitor_byte;
  integer copy_jobs=0, copy_returns=0, check_jobs=0, check_finishes=0;
  // Structural assertions complement the public-interface byte scoreboard.
  // free_map alone would not detect a repeated return of the same block.
  always @(posedge clk) begin
    if (dut.rst_sync) begin
      copy_active=0; copy_committed=0;
      copy_jobs=0; copy_returns=0; check_jobs=0; check_finishes=0;
    end else begin
      if (dut.reasm_copy_valid && dut.reasm_copy_ready) begin
        if(copy_active) bad("new copy accepted before previous source return");
        copy_active=1; copy_committed=0;
        active_copy_src=dut.reasm_copy_src_blk; copy_jobs=copy_jobs+1;
        active_copy_dst=dut.reasm_copy_dst_blk;
        expected_copy_bytes=dut.reasm_copy_len; committed_copy_bytes=0;
        copy_byte_lo=dut.reasm_copy_dst_byte;
        copy_byte_hi=copy_byte_lo+expected_copy_bytes;
      end
      if(dut.copy_wr_grant) begin
        if(!copy_active) bad("destination write without a live copy job");
        if(dut.copy_wr_addr[12:9] !== active_copy_dst)
          bad("copy write reached a different destination block");
        for(monitor_lane=0;monitor_lane<4;monitor_lane=monitor_lane+1) begin
          if(dut.copy_wr_be[3-monitor_lane]) begin
            monitor_byte=dut.copy_wr_addr[8:0]*4+monitor_lane;
            if(monitor_byte<copy_byte_lo || monitor_byte>=copy_byte_hi)
              bad("copy byte enable reached outside requested destination range");
            committed_copy_bytes=committed_copy_bytes+1;
          end
        end
      end
      if(dut.reasm_copy_done) begin
        if(!copy_active) bad("copy completion without an owned source");
        if(committed_copy_bytes!=expected_copy_bytes)
          bad("copy done before every destination byte committed");
        copy_committed=1;
      end
      if(dut.reasm_free_valid) begin
        if(dut.rx_free_map[dut.reasm_free_id] !== 1'b0)
          bad("reassembly returned a block that was already free");
        if(dut.g_rx_legacy.u_rxreasm.complete_check_busy && dut.reasm_free_id==dut.reasm_check_blk)
          bad("destination released while UDP checker still owns it");
        if(copy_active && dut.reasm_free_id==active_copy_src) begin
          if(!copy_committed) bad("source released before final copy write committed");
          copy_active=0; copy_returns=copy_returns+1;
        end
      end
      if(dut.reasm_check_valid && dut.reasm_check_ready) begin
        if(copy_active || dut.g_rx_legacy.u_rxreasm.complete_sources_pending || dut.copy_wr_valid)
          bad("UDP check started before all copy writes and source returns");
        check_jobs=check_jobs+1;
      end
      if(dut.reasm_check_done) check_finishes=check_finishes+1;
      if(({2'd0,dut.copy_rd_grant}+{2'd0,dut.check_rd_grant}+
          {2'd0,dut.host_pmem_rd}+{2'd0,dut.fb_rd_en_a}+{2'd0,dut.sap_pm_gnt})>3'd1)
        bad("PMEM read port granted to multiple owners");
      if(dut.reasm_out_vld && !dut.reasm_out_drop && dut.reasm_out_desc[176]) begin
        if(copy_active || dut.g_rx_legacy.u_rxreasm.complete_check_busy || !dut.g_rx_legacy.u_rxreasm.complete_checked)
          bad("fragment descriptor published before successful UDP check");
      end
    end
  end

  // MAC 侧一次性探针：帧结束瞬间打印长度判定要素（仅定位用）
  // ---------------------------------------------------------------------
  // 交付侧捕获（仅定位用，PASS 时不打印）：
  //   记录每一帧在「重组输出→解析→端口」三级的去向，任何断言失败时由
  //   dump_trace 一次性打印，便于回归失败时定位是哪一级拒绝的。
  //   这些探针只读顶层公共层次信号，不参与任何断言。
  // ---------------------------------------------------------------------
  integer n_reasm_out = 0, n_prs_out = 0, n_pb_in = 0;
  reg [3:0] last_reasm_blk = 4'd0, last_reasm_drop = 1'b0;
  reg [10:0] last_reasm_plen = 11'd0;
  reg [2:0] last_prs_rsn = 3'd0;
  reg       last_prs_drop = 1'b0;
  reg [7:0] last_prs_port = 8'd0;
  always @(posedge clk) begin
    if (dut.reasm_out_vld) begin
      n_reasm_out    <= n_reasm_out + 1;
      last_reasm_drop <= dut.reasm_out_drop;
      last_reasm_blk  <= dut.reasm_out_desc[162:159];
      last_reasm_plen <= dut.reasm_out_desc[173:163];
    end
    if (dut.prs_out_vld) begin
      n_prs_out    <= n_prs_out + 1;
      last_prs_drop <= dut.prs_out_drop;
      last_prs_rsn  <= dut.prs_out_reason;
      last_prs_port <= dut.prs_out_port;
    end
    if (dut.prs_out_vld && dut.pb_in_ready && !dut.prs_to_sap) n_pb_in <= n_pb_in + 1;
  end
  task dump_trace; begin
    $display("  [trace] reasm_out=%0d (drop=%b blk=%0d plen=%0d) prs_out=%0d (drop=%b rsn=%0d port=%0d) pb_in=%0d",
      n_reasm_out, last_reasm_drop, last_reasm_blk, last_reasm_plen,
      n_prs_out, last_prs_drop, last_prs_rsn, last_prs_port, n_pb_in);
  end endtask

  initial begin
    // Read the actual serialized extent, without requesting unfilled words.
    // Malformed, empty and oversized inputs remain failures.
    vec_fd=$fopen("vec/t60_reasm.hex","r"); vec_words=0;
    if(vec_fd==0) $fatal(1,"T60 REASM E2E FAIL missing vector file");
    while(!$feof(vec_fd)) begin
      vec_scan=$fscanf(vec_fd,"%h",vec_word);
      if(vec_scan==1) begin
        if(vec_words>=VMAX) $fatal(1,"T60 REASM E2E FAIL oversized vectors");
        vec[vec_words]=vec_word; vec_words=vec_words+1;
      end else if(!$feof(vec_fd)) $fatal(1,"T60 REASM E2E FAIL malformed vectors");
    end
    $fclose(vec_fd);
    if(vec_words==0) $fatal(1,"T60 REASM E2E FAIL empty vectors");
    $readmemh("vec/t12_top.img.hex", himg, 0, 8191);
    $readmemh("vec/t12_top.meta.hex", hmeta, 0, 3);
    ncases = vec[0]; pos = 1;      // [0]=用例数；随后每用例「分片数 + 分片」
    $display("T60 VECTOR cases=%0d hash_seed=%04X/%04X keys=%0d",
             ncases, hmeta[0][15:0], hmeta[1][15:0], hmeta[2]);

    configure;
    rx_free_initial = dut.rx_free_map;

    // ---------- E1 默认旁路 ----------
    $display("T60 CASE E1");
    read_word(16'hAC2A,v); chk(v[0]===1'b0, "E1 reasm default disabled (bit7=0 in CTL_RST)");

    // 本向量只注入 A 网的一条非冗余 VL：IC 保持开启并检查每片的 SN；
    // RM 关闭对应 P7 可配置的 non-redundant VL。重组位为 ctl_r[7]。
    u_host.wr(16'h0008,(1<<1) | (1<<2) | (1<<7));
    read_word(16'hAC2A,v); chk(v[0]===1'b1, "E2 reasm enabled via ctl_r[7]");
    read_word(16'h0008,v); chk(v[2]===1'b1 && v[3]===1'b0, "E2 IC on, RM off for A-only non-redundant VL");

    // ---------- in-order ----------
    $display("T60 CASE in-order");
    drain_port;                                 // 排空前序用例遗留消息（depth=1）
    msg_cnt(base_cnt);
    nfrag = vec[pos]; pos = pos + 1;
    load_and_inject_frag;                       // 首片
    // 同步：描述符穿过 lookup→flt→ic/rm 后，reassembly 还要跑完
    // MAX_FRAGS^2 间隔扫描才落槽；短固定等待会读到「尚未入槽」瞬态。
    wait_reasm_used(32'd1);
    diag("after-frag1");
    read_word(16'hAC2D,v); chk(v===32'd1, "in-order: first frag holds 1 context");
    read_word(16'hAC2B,v); chk(v===32'd0, "in-order: nothing delivered on first frag");
    neighbor_blk=dut.g_rx_legacy.u_rxreasm.slot_blk0[0];
    read_word(16'h8800+(neighbor_blk<<9)+169,v);
    neighbor_before=v[15:0]; // raw bytes 678/679, beyond the destination range
    load_and_inject_frag;                       // 末片
    wait_message(base_cnt+1);
    diag("after-frag2");
    msg_cnt(v); chk(v===base_cnt+1, "in-order: exactly one message delivered");
    read_word(16'hAC2B,v); chk(v===32'd1, "in-order: hit counted once");
    read_word(16'hAC2D,v); chk(v===32'd0, "in-order: context released");
    check_host_payload(636,0);
    read_word(16'h8800+(neighbor_blk<<9)+169,v);
    chk(v[15:0]===neighbor_before,"copy preserves destination neighbors at raw bytes 678/679");

    // ---------- legal 1ms fragment gap; no fixed reassembly timeout ----------
    $display("T60 CASE delayed-tail");
    drain_port;                                 // 排空前序用例遗留消息（depth=1）
    chk(dut.rx_free_map===rx_free_initial, "in-order: fragment blocks returned after host consume");
    msg_cnt(base_cnt);
    nfrag = vec[pos]; pos = pos + 1;
    load_and_inject_frag;                       // 只有首片
    wait_reasm_used(32'd1);
    diag("missing-after-frag1");
    read_word(16'hAC2D,v); chk(v===32'd1, "missing: lone frag holds context");
    // 130000 cycles at 125MHz = 1.04ms, beyond the old 524us expiration.
    repeat (130000) @(negedge clk);
    msg_cnt(v); chk(v===base_cnt, "missing: never delivered");
    read_word(16'hAC2D,v); chk(v===32'd1, "delayed-tail: context survives legal 1ms gap");
    load_and_inject_frag;
    wait_message(base_cnt+1);
    msg_cnt(v); chk(v===base_cnt+1, "delayed-tail: delivered only after missing tail arrives");
    read_word(16'hAC2D,v); chk(v===32'd0, "delayed-tail: context released after completion");
    check_host_payload(636,0);
    drain_port;
    chk(dut.rx_free_map===rx_free_initial, "delayed-tail: all blocks recovered after consume");

    // ---------- out-of-order ----------
    $display("T60 CASE out-of-order");
    drain_port;                                 // 排空前序用例遗留消息（depth=1）
    msg_cnt(base_cnt);
    nfrag = vec[pos]; pos = pos + 1;
    load_and_inject_frag;                       // 末片先到
    wait_reasm_used(32'd1);
    diag("ooo-after-last");
    msg_cnt(v); chk(v===base_cnt, "out-of-order: last-first alone not delivered");
    read_word(16'hAC2D,v); chk(v===32'd1, "out-of-order: last frag holds context");
    load_and_inject_frag;                       // 首片补齐
    wait_message(base_cnt+1);
    diag("ooo-after-first");
    msg_cnt(v); chk(v===base_cnt+1, "out-of-order: completed on fill");
    read_word(16'hAC2D,v); chk(v===32'd0, "out-of-order: context released");
    check_host_payload(636,0);

    // ---------- overlap ----------
    $display("T60 CASE overlap");
    drain_port;                                 // 排空前序用例遗留消息（depth=1）
    msg_cnt(base_cnt);
    nfrag = vec[pos]; pos = pos + 1;
    load_and_inject_frag;                       // 首片
    load_and_inject_frag;                       // 重叠片
    repeat (2500) @(negedge clk);
    msg_cnt(v); chk(v===base_cnt, "overlap: invalidated, never delivered");
    read_word(16'hAC2D,v); chk(v===32'd0, "overlap: context released");

    // ---------- three-frag ----------
    $display("T60 CASE three-frag");
    drain_port;                                 // 排空前序用例遗留消息（depth=1）
    msg_cnt(base_cnt);
    nfrag = vec[pos]; pos = pos + 1;
    load_and_inject_frag;                       // 首片 400
    wait_reasm_used(32'd1);
    load_and_inject_frag;                       // 中片 200
    // Mid fragment must finish its own prep/merge before the observation.
    repeat (400) @(negedge clk);
    diag("three-frag-after-mid");
    msg_cnt(v); chk(v===base_cnt, "three-frag: not yet complete");
    read_word(16'hAC2D,v); chk(v===32'd1, "three-frag: one context held");
    load_and_inject_frag;                       // 末片 36
    wait_message(base_cnt+1);
    diag("three-frag-after-last");
    msg_cnt(v); chk(v===base_cnt+1, "three-frag: delivered once complete");
    read_word(16'hAC2D,v); chk(v===32'd0, "three-frag: context released");
    check_host_payload(636,0);
    drain_port;
    chk(dut.rx_free_map===rx_free_initial, "three-frag: fragment blocks returned after host consume");

    // ---------- source-table reuse beyond MAX_FRAGS=16 ----------
    $display("T60 CASE slot-reuse");
    drain_port;
    msg_cnt(base_cnt);
    nfrag = vec[pos]; pos = pos + 1;
    chk(nfrag==18, "slot-reuse: vector contains 18 fragments");
    load_and_inject_frag;                       // 首片：UDP + 8 app bytes
    wait_reasm_used(32'd1);
    for (reuse_i=0; reuse_i<16; reuse_i=reuse_i+1) begin
      load_and_inject_frag;                     // 16 x 32-byte copied fragments
      // Prep (~272) + copy engine; allow each source entry to free before the next.
      repeat (400) @(negedge clk);
    end
    load_and_inject_frag;                       // 116-byte tail; closes 636-byte datagram
    wait_message(base_cnt+1);
    msg_cnt(v); chk(v===base_cnt+1, "slot-reuse: delivered after more than 16 source fragments");
    read_word(16'hAC2D,v); chk(v===32'd0, "slot-reuse: context released after completion");
    check_host_payload(636,0);
    drain_port;
    chk(dut.rx_free_map===rx_free_initial, "slot-reuse: all source blocks returned after host consume");
    diag("slot-reuse-final");

    // Valid IP/FCS on every input fragment isolates the full-UDP failure.
    // Indices 6..8 are bad payload, zero checksum and wrong UDP length.
    for (ci=6; ci<9; ci=ci+1) begin
      $display("T60 CASE invalid-UDP index=%0d",ci);
      drain_port; msg_cnt(base_cnt);
      read_word(16'hAC2C,base_drop);
      nfrag=vec[pos]; pos=pos+1;
      for(fi=0;fi<nfrag;fi=fi+1) load_and_inject_frag;
      repeat(3000) @(negedge clk);
      msg_cnt(v); chk(v===base_cnt,"invalid-UDP: no message delivered");
      read_word(16'hAC2C,v); chk(v===base_drop+1,"invalid-UDP: one rejection counted");
      read_word(16'hAC2D,v); chk(v===0,"invalid-UDP: context released");
      chk(dut.rx_free_map===rx_free_initial,"invalid-UDP: all blocks returned exactly once");
    end

    $display("T60 CASE odd-valid after failures");
    msg_cnt(base_cnt); nfrag=vec[pos]; pos=pos+1;
    for(fi=0;fi<nfrag;fi=fi+1) load_and_inject_frag;
    wait_message(base_cnt+1);
    msg_cnt(v); chk(v===base_cnt+1,"odd-valid: checksum and recovery succeed");
    check_host_payload(635,0); drain_port;
    chk(dut.rx_free_map===rx_free_initial,"odd-valid: all blocks returned");

    // Checksum policy skips only checksum, while UDP length stays mandatory.
    u_host.wr(16'h0070,32'h0140);
    $display("T60 CASE disabled-bad-udp");
    msg_cnt(base_cnt); nfrag=vec[pos]; pos=pos+1;
    for(fi=0;fi<nfrag;fi=fi+1) load_and_inject_frag;
    wait_message(base_cnt+1);
    msg_cnt(v); chk(v===base_cnt+1,"disabled checksum: bad payload checksum accepted by policy");
    check_host_payload(636,1); drain_port;
    chk(dut.rx_free_map===rx_free_initial,"disabled checksum: blocks returned");
    $display("T60 CASE disabled-bad-length");
    msg_cnt(base_cnt); read_word(16'hAC2C,base_drop);
    nfrag=vec[pos]; pos=pos+1;
    for(fi=0;fi<nfrag;fi=fi+1) load_and_inject_frag;
    repeat(3000) @(negedge clk);
    msg_cnt(v); chk(v===base_cnt,"disabled checksum: bad length still rejected");
    read_word(16'hAC2C,v); chk(v===base_drop+1,"disabled checksum: bad length counted once");
    chk(dut.rx_free_map===rx_free_initial,"disabled checksum: invalid length blocks returned");
    chk(ncases==12,"all twelve vector cases consumed");
    chk(pos==vec_words,"all serialized vector words consumed");
    chk(copy_jobs==copy_returns && !copy_active,"every accepted copy source returned once after commit");
    chk(check_jobs==check_finishes && check_jobs==11,"all complete datagrams received one UDP check");
    u_host.wr(16'h0070,32'h0142);

    // An incomplete datagram is explicitly cancelled by disabling reassembly.
    // Reuse the first independent vector with IC disabled for this replay.
    $display("T60 CASE disable-drain and recovery");
    u_host.wr(16'h0008,(1<<1)|(1<<7));
    pos=2; load_and_inject_frag; wait_reasm_used(32'd1);
    read_word(16'hAC2D,v); chk(v===1,"disable-drain: incomplete context owned before cancel");
    u_host.wr(16'h0008,(1<<1)); repeat(256) @(negedge clk);
    read_word(16'hAC2D,v); chk(v===0,"disable-drain: context cleared");
    chk(dut.rx_free_map===rx_free_initial,"disable-drain: incomplete destination returned");
    u_host.wr(16'h0008,(1<<1)|(1<<7));
    msg_cnt(base_cnt); pos=2;
    load_and_inject_frag; load_and_inject_frag;
    wait_message(base_cnt+1);
    check_host_payload(636,0); drain_port;
    chk(dut.rx_free_map===rx_free_initial,"disable-drain: subsequent datagram recovers");
    chk(copy_jobs==copy_returns && !copy_active,"disable-drain: copy sources remain balanced");
    chk(check_jobs==check_finishes && check_jobs==12,"disable-drain: recovery checked once");

    // Cancel after the checker has accepted a job, then immediately reenable.
    // The remembered drain must outlive the short disable pulse.
    $display("T60 CASE disable during active UDP check");
    msg_cnt(base_cnt); pos=2;
    load_and_inject_frag; load_and_inject_frag;
    cancel_guard=0;
    while(!dut.g_rx_legacy.u_rxreasm.complete_check_busy && cancel_guard<2000) begin
      @(negedge clk); cancel_guard=cancel_guard+1;
    end
    chk(dut.g_rx_legacy.u_rxreasm.complete_check_busy,"active-cancel: checker owns a live job");
    u_host.wr(16'h0008,(1<<1));
    u_host.wr(16'h0008,(1<<1)|(1<<7));
    repeat(3000) @(negedge clk);
    msg_cnt(v); chk(v===base_cnt,"active-cancel: cancelled datagram not published after reenable");
    read_word(16'hAC2D,v); chk(v===0,"active-cancel: context drained after checker completion");
    chk(dut.rx_free_map===rx_free_initial,"active-cancel: all blocks returned after checker drain");
    pos=2; load_and_inject_frag; load_and_inject_frag;
    wait_message(base_cnt+1); check_host_payload(636,0); drain_port;
    chk(dut.rx_free_map===rx_free_initial,"active-cancel: subsequent good datagram recovers");
    chk(copy_jobs==copy_returns && !copy_active,"active-cancel: source copies balanced");
    chk(check_jobs==check_finishes && check_jobs==14,"active-cancel: both jobs complete exactly once");
    chk(u_host.errors==0,"host BFM reported no hidden ACK errors");

    if(errors==0) $display("T60 REASM E2E PASS checks=%0d",checks);
    else $display("T60 REASM E2E FAIL errors=%0d",errors);
    $finish;
  end
  initial begin #40000000; $display("T60 REASM E2E FAIL timeout"); $finish; end
endmodule
