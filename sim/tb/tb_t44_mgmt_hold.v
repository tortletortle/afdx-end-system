// =====================================================================
// T44 — mgmt_sap_rx 字节流停顿契约（P02，2026-10-10）
//
// 目的：验证 SAP 侧新加的 out_ready 逐字节握手：
//   * out_ready=0 期间 data/valid/SOP/EOP 与待消费位置必须保持不变；
//   * 停顿释放后字节序列完整、无跳字节、无重复、无丢字节；
//   * SOP 只在首字节、EOP 只在末字节；
//   * PMEM 块在所有复制读取完成之后才 free，且只释放一次；
//   * 无停顿路径每拍 1 字节。
//
// 覆盖：SOP 停顿、流中停顿、EOP 停顿、伪随机 ready、零长包、
// 超长包（>622 B 载荷截断）、free_take 延迟。预期字节由本 TB 的
// 固定图案与常量独立产生（不读 DUT 内部、不从 DUT 输出反推）。
// =====================================================================
`timescale 1 ns / 1 ps
module tb_t44_mgmt_hold;
  localparam integer PAY_OFF = 42;
  localparam integer PBUF_W  = 160;
  localparam integer NWORD   = 256;
  localparam integer MAXCAP  = 2048;

  reg clk = 0;
  always #4 clk = ~clk;
  reg rst_sync = 1;

  // ---- descriptor in ----
  reg        in_vld = 0;
  wire       in_ready;
  reg  [7:0] in_port = 8'd7;
  reg  [3:0] in_blk  = 4'd0;
  reg [10:0] in_plen = 11'd0;

  // ---- pmem model (sync read, data valid the cycle after the grant) ----
  reg [31:0] pmem [0:NWORD-1];
  reg [31:0] pm_rdq = 0;
  wire       pm_req;
  wire [12:0] pm_addr;
  wire       pm_gnt = 1'b1;
  wire [31:0] pm_data = pm_rdq;
  always @(posedge clk) if (pm_req && pm_gnt) pm_rdq <= pmem[pm_addr[8:0]];

  // ---- byte stream out ----
  wire        out_vld, out_sop, out_eop;
  wire [7:0]  out_data;
  wire [15:0] out_sport, out_dport;
  wire [31:0] out_srcip;
  wire [10:0] out_plen;
  reg         out_ready = 1;

  // ---- free hand shake ----
  wire        free_req;
  reg         free_take_en = 0;              // 1: 由 TB 控制；0: 立即接收
  reg         free_take_r = 0;
  wire        free_take = free_take_en ? free_take_r : free_req;
  wire [3:0]  free_id;

  // ---- case-scope expectations (declared before the monitor that reads them) ----
  integer case_id = 0;
  integer i, exp_bytes, wlast, blast, exp_words;
  integer s_ac, s_fc, s_hm, s_re, s_tc;

  // ---- observability ----
  wire [31:0] accept_cnt, free_cnt, last_desc, pay_cnt, trunc_cnt;

  mgmt_sap_rx #(.PAY_OFF(PAY_OFF), .PBUF_W(PBUF_W)) dut (
    .clk(clk), .rst_sync(rst_sync),
    .in_vld(in_vld), .in_ready(in_ready), .in_port(in_port),
    .in_blk(in_blk), .in_plen(in_plen),
    .in_app_len(14'd0), .in_blocks(20'd0), .in_block_count(3'd0),
    .pm_req(pm_req), .pm_addr(pm_addr), .pm_gnt(pm_gnt), .pm_data(pm_data),
    .out_vld(out_vld), .out_sop(out_sop), .out_eop(out_eop), .out_data(out_data),
    .out_sport(out_sport), .out_dport(out_dport), .out_srcip(out_srcip),
    .out_plen(out_plen), .out_ready(out_ready),
    .out_app_len(),
    .free_req(free_req), .free_take(free_take), .free_id(free_id),
    .accept_cnt(accept_cnt), .free_cnt(free_cnt), .last_desc(last_desc),
    .pay_cnt(pay_cnt), .trunc_cnt(trunc_cnt)
  );

  // ---- independent expected frame bytes ----
  // 布局：26..29 srcip；34..35 sport；36..37 dport；42.. 载荷。
  // 字节值 = (i*7+0x21)&0xFF（固定图案，独立常量）。
  reg [7:0] fbytes [0:4095];
  integer gb;
  task build_frame_bytes;
    input integer plen;
    integer i;
    begin
      for (i = 0; i < 4096; i = i + 1) fbytes[i] = (i * 7 + 8'h21) & 8'hFF;
      fbytes[26]=8'hA5; fbytes[27]=8'h5A; fbytes[28]=8'hC3; fbytes[29]=8'h3C;
      fbytes[34]=8'h12; fbytes[35]=8'h34;
      fbytes[36]=8'h50; fbytes[37]=8'h00;
      for (i = 0; i < NWORD; i = i + 1) pmem[i] = 32'hDEAD_0000 + i;
      for (i = 6; i < NWORD; i = i + 1)
        pmem[i] = {fbytes[4*(i-6)+24], fbytes[4*(i-6)+25],
                   fbytes[4*(i-6)+26], fbytes[4*(i-6)+27]};
      gb = plen;
    end
  endtask

  // ---- capture & monitors (single-driver block) ----
  reg [7:0]  cap [0:MAXCAP-1];
  reg        cap_sop [0:MAXCAP-1];
  reg        cap_eop [0:MAXCAP-1];
  integer    got = 0;
  integer    total_checks = 0;
  integer    errors = 0;
  reg        cap_en = 0;
  integer    grants = 0;

  reg        holding_d = 0;
  reg [7:0]  hd = 0; reg hs = 0; reg he = 0;
  reg        held_mismatch = 0;      // sticky
  reg        released_early = 0;     // sticky
  reg        free_chk_en = 0;        // 由 initial 单驱动写、此处只读

  always @(posedge clk) begin
    if (rst_sync) begin
      got <= 0; holding_d <= 0; held_mismatch <= 0;
      released_early <= 0; grants <= 0;
    end else begin
      if (pm_req && pm_gnt) grants <= grants + 1;
      if (out_vld && out_ready && cap_en && got < MAXCAP) begin
        cap[got] <= out_data; cap_sop[got] <= out_sop; cap_eop[got] <= out_eop;
        got <= got + 1;
      end
      if (holding_d && out_vld && !out_ready)
        if (out_data !== hd || out_sop !== hs || out_eop !== he)
          held_mismatch <= 1;
      holding_d <= out_vld && !out_ready;
      hd <= out_data; hs <= out_sop; he <= out_eop;
      // free 不得早于最后一次复制读取（零长包无复制读取，用 free_chk_en 屏蔽）
      if (free_chk_en && free_req && (grants < exp_words)) released_early <= 1;
    end
  end

  task bad;
    input [8*128-1:0] reason;
    begin
      if (errors < 20) $display("  [err] T44 case=%0d time=%0d %0s", case_id, $time, reason);
      errors = errors + 1;
    end
  endtask

  task calc_expect;
    input integer plen;
    reg [12:0] lb;
    begin
      lb = PAY_OFF - 1 + plen;
      if ((lb >> 2) > (6 + PBUF_W - 1)) wlast = 6 + PBUF_W - 1; else wlast = lb >> 2;
      if (lb > ((6 + PBUF_W) * 4 - 1)) blast = (6 + PBUF_W) * 4 - 1; else blast = lb;
      exp_words = wlast - 6 + 1;
      exp_bytes = (plen == 0) ? 0 : (blast - PAY_OFF + 1);
    end
  endtask

  task check_stream;
    begin
      if (got !== exp_bytes) bad("delivered byte count mismatch");
      for (i = 0; i < exp_bytes; i = i + 1) begin
        if (cap[i] !== fbytes[PAY_OFF + i]) bad("payload byte mismatch");
        total_checks = total_checks + 1;
        if (cap_sop[i] !== (i == 0)) bad("SOP position wrong");
        if (cap_eop[i] !== (i == exp_bytes - 1)) bad("EOP position wrong");
      end
      if (out_sport !== 16'h1234) bad("sport extraction wrong");
      if (out_dport !== 16'h5000) bad("dport extraction wrong");
      if (out_srcip !== 32'hA55AC33C) bad("srcip extraction wrong");
      if (out_plen !== gb[10:0]) bad("out_plen latch wrong");
      total_checks = total_checks + 4;
    end
  endtask

  task wait_idle;
    integer guard;
    begin
      guard = 0;
      while (in_ready !== 1'b1 && guard < 10000) begin @(negedge clk); guard = guard + 1; end
      if (in_ready !== 1'b1) bad("module never returned to S_IDLE");
    end
  endtask

  task send_desc;
    input integer plen;
    begin
      @(negedge clk); in_vld = 1; in_plen = plen[10:0]; in_port = 8'd7; in_blk = 4'd0;
      @(negedge clk); in_vld = 0;
    end
  endtask

  // policy 0=直通 1=在 got==hold_at 的字节处停 hold_len 拍
  //        2=在 EOP 字节处停 hold_len 拍 3=LFSR 伪随机 ready
  // 退出条件：全部字节接收且无在途字节（正常）；或流已安静（seen 后连续
  // quiet 拍无 out_vld，覆盖丢字节的失败路径与延迟释放）；或长时间未启动。
  // 不使用 free_req 判定——它在本设计里流一开始就为高。
  task consume;
    input integer policy;
    input integer hold_at;
    input integer hold_len;
    reg [15:0] lfsr;
    reg held1;
    reg done;
    reg seen;
    integer quiet;
    begin
      lfsr = 16'hACE1; held1 = 0; done = 0; seen = 0; quiet = 0;
      while (!done) begin
        @(negedge clk);
        if (out_vld) begin quiet = 0; seen = 1; end else quiet = quiet + 1;
        if ((got >= exp_bytes) && !out_vld) begin
          done = 1;
        end else if (seen && (quiet >= 400)) begin
          done = 1;
        end else if (!seen && (quiet >= 800)) begin
          done = 1;
        end else begin
          case (policy)
            0: out_ready = 1;
            1: begin
              if (!held1 && out_vld && (got >= hold_at)) begin
                out_ready = 0;
                repeat (hold_len) @(negedge clk);
                out_ready = 1; held1 = 1;
              end else out_ready = 1;
            end
            2: begin
              if (!held1 && out_vld && out_eop) begin
                out_ready = 0;
                repeat (hold_len) @(negedge clk);
                out_ready = 1; held1 = 1;
              end else out_ready = 1;
            end
            3: begin
              lfsr = {lfsr[14:0], lfsr[15]^lfsr[13]^lfsr[12]^lfsr[10]};
              out_ready = lfsr[0] | lfsr[3];
            end
            default: out_ready = 1;
          endcase
        end
      end
      repeat (4) @(negedge clk);
      out_ready = 1;
    end
  endtask

  task run_case;
    input integer policy;
    input integer plen;
    input integer hold_at;
    input integer hold_len;
    begin
      case_id = case_id + 1;
      build_frame_bytes(plen);
      calc_expect(plen);
      wait_idle;
      s_ac = accept_cnt; s_fc = free_cnt;
      s_hm = held_mismatch; s_re = released_early; s_tc = trunc_cnt;
      cap_en = 1; got = 0; grants = 0;
      free_take_en = 0; free_take_r = 0; free_chk_en = (plen > 0);
      send_desc(plen);
      consume(policy, hold_at, hold_len);
      cap_en = 0;
      wait_idle;
      if (held_mismatch !== s_hm) bad("output not stable during stall");
      if (released_early !== s_re) bad("PMEM released before last read");
      if (accept_cnt !== s_ac + 1) bad("accept_cnt not exactly +1");
      if (free_cnt !== s_fc + 1) bad("free_cnt not exactly +1");
      if (pm_req) bad("pm_req still active after completion");
      if (exp_bytes < gb) begin
        if (trunc_cnt < s_tc + 1) bad("trunc_cnt not raised for oversized payload");
      end
      check_stream;
      $display("T44_CASE id=%0d policy=%0d plen=%0d exp=%0d got=%0d free=%0d",
               case_id, policy, plen, exp_bytes, got, free_cnt);
    end
  endtask

  initial begin
    $timeformat(-9, 0, "ns", 12);
    repeat (8) @(negedge clk);
    rst_sync = 0;
    repeat (4) @(negedge clk);

    // 1) 直通 512 B
    run_case(0, 512, 0, 0);
    // 2) SOP 处停顿 17 拍
    run_case(1, 512, 0, 17);
    // 3) 流中第 200 字节处停顿 37 拍
    run_case(1, 512, 200, 37);
    // 4) EOP 字节处停顿 23 拍
    run_case(2, 512, 0, 23);
    // 5) 短包 8 B EOP 停顿 9 拍
    run_case(2, 8, 0, 9);
    // 6) 伪随机 ready
    run_case(3, 512, 0, 0);
    // 7) 零长包
    begin
      case_id = case_id + 1;
      build_frame_bytes(0);
      calc_expect(0);
      wait_idle;
      s_ac = accept_cnt; s_fc = free_cnt;
      s_hm = held_mismatch; s_re = released_early;
      cap_en = 1; got = 0;
      free_chk_en = 0; free_take_en = 0;
      send_desc(0);
      repeat (12) @(negedge clk);
      cap_en = 0;
      wait_idle;
      if (got !== 0) bad("zero-length packet emitted bytes");
      if (accept_cnt !== s_ac + 1) bad("zero-length accept_cnt");
      if (free_cnt !== s_fc + 1) bad("zero-length free_cnt");
      if (held_mismatch !== s_hm) bad("zero-length stability failure");
      $display("T44_CASE id=%0d zero-length OK got=%0d", case_id, got);
    end
    // 8) 超长包 700 B：截断到 622 B 载荷，完整归还
    run_case(1, 700, 300, 21);
    // 9) free_take 延迟：S_WAIT 等待归还
    begin
      case_id = case_id + 1;
      build_frame_bytes(64);
      calc_expect(64);
      wait_idle;
      s_ac = accept_cnt; s_fc = free_cnt;
      cap_en = 1; got = 0; grants = 0;
      free_chk_en = 0;               // 本用例单独控制释放节奏
      free_take_en = 1; free_take_r = 0;   // 释放权交给 TB：先不接收
      send_desc(64);
      consume(1, 32, 13);
      repeat (40) @(negedge clk);    // S_WAIT 中等待归还，期间不得悬挂
      free_take_r = 1;
      repeat (4) @(negedge clk);
      free_take_r = 0;
      cap_en = 0;
      wait_idle;
      if (free_cnt !== s_fc + 1) bad("delayed free did not complete exactly once");
      check_stream;
      $display("T44_CASE id=%0d delayed-free OK", case_id);
    end

    if (errors == 0)
      $display("T44 MGMT SAP HOLD PASS cases=%0d checks=%0d", case_id, total_checks);
    else
      $display("T44 MGMT SAP HOLD FAIL errors=%0d", errors);
    $finish;
  end

  initial begin
    #8000000;
    $display("T44 MGMT SAP HOLD FAIL timeout");
    $finish;
  end
endmodule
