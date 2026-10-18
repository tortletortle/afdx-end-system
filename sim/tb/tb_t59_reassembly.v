// =====================================================================
// T59 — rx_reassembly 单元验证（P08）
//
// 描述符位域（DW=208，与顶层一致）：
//   [173:163] plen  [162:159] blk  [158:148] len  [123:108] vlid
//   [107:100] sn  [99:68] src  [67:36] dst  [35:20] sport  [19:4] dport
//   [207:192] ident  [191] mf  [190] df  [189:177] frag_off  [176] is_frag
//
// 用例：
//   R1 未分片包透传（is_frag=0）
//   R2 两片重组成功：首片应用数据 600B + 末片(off=608,MF=0,36B)
//      -> 交付，plen=636，blk=首片块号，src/sport 取首片
//   R3 三片乱序到达（末片先到）-> 末片到达时尚未完整，不交付；补齐后交付
//   R4 重叠片（off 与已有片相交）-> 拒绝，reason=E_OVERLAP，不交付
//   R5 缺片（只有首片，无末片）-> 独立短超时实例下超时释放，不交付
//   R6 非法标记（offset≠0 但 is_frag=0）-> 不占上下文、透传不丢
//   R7 超长（off+plen > 8192）-> 拒绝 E_OVERSIZE
//   R8 不同 ident 的两组并发重组互不干扰
//   R9 上下文槽耗尽 -> 拒绝 E_SLOT
// =====================================================================
`timescale 1 ns / 1 ps
module tb_t59_reassembly;
  reg clk=0, rst=1;
  always #4 clk=~clk;

  localparam integer DW = 208;
  reg          en=1;
  reg          in_vld=0;
  wire         in_ready;
  reg  [DW-1:0] in_desc=0;
  reg  [11:0]  in_vl=0;
  wire         out_vld;
  reg          out_ready=1;
  wire         out_drop;
  wire [3:0]   out_reason;
  wire [DW-1:0] out_desc;
  wire [11:0]  out_vl;
  wire [31:0]  hit_cnt, drop_cnt, slot_used;

  rx_reassembly #(.DW(DW), .SLOTS(8), .MAX_BYTES(8192), .TIMEOUT_TICKS(4000)) dut (
    .clk(clk), .rst_sync(rst), .en(en),
    .in_vld(in_vld), .in_ready(in_ready), .in_desc(in_desc), .in_vl(in_vl),
    .out_vld(out_vld), .out_ready(out_ready), .out_drop(out_drop),
    .out_reason(out_reason), .out_desc(out_desc), .out_vl(out_vl),
    .copy_req_valid(), .copy_req_ready(1'b0), .copy_src_blk(), .copy_src_byte(),
    .copy_dst_blk(), .copy_dst_byte(), .copy_len(), .copy_done(1'b0),
    .check_req_valid(), .check_req_ready(1'b0), .check_blk(), .check_app_len(),
    .check_src_ip(), .check_dst_ip(), .check_done(1'b0), .check_good(1'b0), .check_reason(2'd0),
    .free_blk_valid(), .free_blk_id(), .drain_active(),
    .hit_cnt(hit_cnt), .drop_cnt(drop_cnt), .slot_used(slot_used));

  // -------------------------------------------------------------------
  // 独立短超时实例：专用于证明「缺片超时释放且绝不交付」
  // TIMEOUT_TICKS=40；其余用例用主实例（4000 拍）以免误超时。
  // -------------------------------------------------------------------
  reg          s_vld=0;
  wire         s_ready;
  reg  [DW-1:0] s_desc=0;
  reg  [11:0]  s_vl=0;
  wire         s_ovld, s_odrop;
  wire [3:0]   s_oreason;
  wire [DW-1:0] s_odesc;
  wire [11:0]  s_ovl;
  wire [31:0]  s_hit, s_drop, s_used;

  rx_reassembly #(.DW(DW), .SLOTS(8), .MAX_BYTES(8192), .TIMEOUT_TICKS(40)) dut_short (
    .clk(clk), .rst_sync(rst), .en(en),
    .in_vld(s_vld), .in_ready(s_ready), .in_desc(s_desc), .in_vl(s_vl),
    .out_vld(s_ovld), .out_ready(1'b1), .out_drop(s_odrop),
    .out_reason(s_oreason), .out_desc(s_odesc), .out_vl(s_ovl),
    .copy_req_valid(), .copy_req_ready(1'b0), .copy_src_blk(), .copy_src_byte(),
    .copy_dst_blk(), .copy_dst_byte(), .copy_len(), .copy_done(1'b0),
    .check_req_valid(), .check_req_ready(1'b0), .check_blk(), .check_app_len(),
    .check_src_ip(), .check_dst_ip(), .check_done(1'b0), .check_good(1'b0), .check_reason(2'd0),
    .free_blk_valid(), .free_blk_id(), .drain_active(),
    .hit_cnt(s_hit), .drop_cnt(s_drop), .slot_used(s_used));

  integer s_got_vld=0;
  always @(posedge clk) if (!rst && s_ovld) s_got_vld = s_got_vld + 1;

  task s_send;
    input [DW-1:0] d; input [11:0] vl;
    begin
      @(negedge clk);
      s_desc=d; s_vl=vl; s_vld=1;
      while (s_ready !== 1'b1) @(negedge clk);
      @(negedge clk);
      s_vld=0;
      while (s_ready !== 1'b1) @(negedge clk);
    end
  endtask

  integer errors=0, checks=0, cycle=0;
  always @(posedge clk) cycle <= cycle+1;
  task bad; input [8*110-1:0] r; begin if (errors<25) $display("  [err] T59 cyc=%0d %0s", cycle, r); errors=errors+1; end endtask
  task chk; input c; input [8*110-1:0] r; begin checks=checks+1; if(!c) bad(r); end endtask

  // 描述符构造
  function [DW-1:0] mk;
    input [15:0] ident; input mf; input [12:0] foff; input isfr;
    input [10:0] plen; input [3:0] blk;
    input [31:0] src; input [31:0] dst; input [15:0] sport; input [15:0] dport;
    reg [DW-1:0] d;
    begin
      d = {DW{1'b0}};
      d[207:192]=ident; d[191]=mf; d[190]=1'b0; d[189:177]=foff; d[176]=isfr;
      d[173:163]=plen; d[162:159]=blk;
      d[99:68]=src; d[67:36]=dst; d[35:20]=sport; d[19:4]=dport;
      mk=d;
    end
  endfunction

  task send;
    input [DW-1:0] d; input [11:0] vl;
    begin
      @(negedge clk);
      in_desc=d; in_vl=vl; in_vld=1;
      // The reassembly DUT may scan interval coverage before accepting the
      // next fragment. Hold valid until the ready/valid handshake occurs.
      while (in_ready !== 1'b1) @(negedge clk);
      @(negedge clk);
      in_vld=0;
      while (in_ready !== 1'b1) @(negedge clk);
    end
  endtask

  // 统计 monitor（组合可见即可计数，不做清零竞争）
  integer got_vld=0, got_drop=0;
  reg [3:0] got_reason=4'd0;
  reg [DW-1:0] got_desc=0;
  reg         TRACE=0;
  always @(posedge clk) begin
    if (!rst && out_vld) begin
      got_vld = got_vld + 1;
      if (out_drop) begin got_drop = got_drop + 1; got_reason = out_reason; end
      got_desc = out_desc;
      if (TRACE) $display("  [mon] cyc=%0d drop=%b reason=%0d plen=%0d", cycle, out_drop, out_reason, out_desc[173:163]);
    end
  end
  task clear_stats; begin @(negedge clk); got_vld=0; got_drop=0; got_reason=4'd0; end endtask
  task wait_out; begin repeat (20) @(negedge clk); end endtask
  // 每个用例前复位，保证上下文/计数完全独立（避免跨用例残留影响判定）
  task do_reset; begin rst=1; repeat(8) @(negedge clk); rst=0; clear_stats; end endtask

  integer i;
  initial begin
    rst=1; repeat(8) @(negedge clk); rst=0;
    got_vld=0; got_drop=0; got_reason=4'd0;
    en=1;
    TRACE=0;

    // ---------- R1 未分片透传 ----------
    $display("T59 CASE R1");
    do_reset;
    send(mk(16'h1111,1'b0,13'd0,1'b0, 11'd100, 4'd3, 32'h0A000001,32'h0A000002,16'd5000,16'd6000), 12'd7);
    wait_out;
    chk(got_vld==1 && got_drop==0, "R1 passthrough no drop");
    chk(slot_used==0, "R1 no slot used");
    clear_stats;

    // ---------- R2 两片成功 ----------
    $display("T59 CASE R2");
    do_reset;
    send(mk(16'h2222,1'b1,13'd0,1'b1, 11'd600, 4'd5, 32'h0A000001,32'h0A000002,16'd5000,16'd6000), 12'd7);
    repeat (2) @(negedge clk);
    chk(slot_used==1, "R2 slot allocated");
    // IPv4 wire offset includes the 8-byte UDP header; app offset 600 is wire 608.
    send(mk(16'h2222,1'b0,13'd76,1'b1, 11'd36, 4'd7, 32'h0A000001,32'h0A000002,16'd5000,16'd6000), 12'd7);
    wait_out;
    chk(got_vld==1 && got_drop==0, "R2 reassembled delivered");
    chk(out_desc[173:163]===11'd636, "R2 total plen=636");
    chk(out_desc[162:159]===4'd5, "R2 blk from first frag=5");
    chk(out_desc[99:68]===32'h0A000001, "R2 src from first frag");
    chk(slot_used==0, "R2 slot freed");
    clear_stats;

    // ---------- R3 三片乱序 ----------
    $display("T59 CASE R3");
    do_reset;
    // 末片先到（应用偏移1200，IPv4 wire offset=1208，MF=0）；此时不完整
    send(mk(16'h3333,1'b0,13'd151,1'b1, 11'd36, 4'd9, 32'h0A000011,32'h0A000022,16'd1,16'd2), 12'd7);
    wait_out;
    chk(got_vld==0, "R3 last-first no naive deliver");
    // 首片
    send(mk(16'h3333,1'b1,13'd0,1'b1, 11'd600, 4'd6, 32'h0A000011,32'h0A000022,16'd1,16'd2), 12'd7);
    // 中间片 -> 补齐后（末片已在）应交付
    send(mk(16'h3333,1'b1,13'd76,1'b1, 11'd600, 4'd8, 32'h0A000011,32'h0A000022,16'd1,16'd2), 12'd7);
    wait_out;
    chk(got_vld==1 && got_drop==0, "R3 delivered after fill (mid frag triggers)");
    chk(out_desc[173:163]===11'd1236, "R3 total plen=1236");
    chk(out_desc[162:159]===4'd6, "R3 output uses first-fragment block");
    clear_stats;

    // ---------- R4 重叠 ----------
    $display("T59 CASE R4");
    do_reset;
    send(mk(16'h4444,1'b1,13'd0,1'b1, 11'd600, 4'd2, 32'h0A000001,32'h0A000002,16'd1,16'd2), 12'd7);
    // 与首片区间 [0,600) 重叠
    send(mk(16'h4444,1'b1,13'd65,1'b1, 11'd100, 4'd3, 32'h0A000001,32'h0A000002,16'd1,16'd2), 12'd7);
    wait_out;
    chk(got_drop==1 && got_reason===4'd5, "R4 overlap rejected E_OVERLAP");
    chk(slot_used==0, "R4 slot invalidated");
    clear_stats;

    // ---------- R5 缺片超时（独立短超时实例） ----------
    $display("T59 CASE R5");
    s_got_vld = 0;
    s_send(mk(16'h5555,1'b1,13'd0,1'b1, 11'd600, 4'd1, 32'h0A000001,32'h0A000002,16'd1,16'd2), 12'd7);
    repeat (2) @(negedge clk);
    chk(s_used==1, "R5 slot held");
    repeat (200) @(negedge clk);   // 远超 TIMEOUT_TICKS=40
    chk(s_used==0, "R5 slot released by timeout");
    chk(s_got_vld==0, "R5 incomplete never delivered");
    chk(s_drop>=32'd1, "R5 timeout counted into drop_cnt");
    // 超时后同样的 ident 可重新开始（上下文已彻底释放）
    s_send(mk(16'h5555,1'b1,13'd0,1'b1, 11'd600, 4'd1, 32'h0A000001,32'h0A000002,16'd1,16'd2), 12'd7);
    repeat (2) @(negedge clk);
    chk(s_used==1, "R5 context reusable after timeout");
    s_send(mk(16'h5555,1'b0,13'd76,1'b1, 11'd36, 4'd2, 32'h0A000001,32'h0A000002,16'd1,16'd2), 12'd7);
    repeat (20) @(negedge clk);
    chk(s_got_vld==1, "R5 completes after retry");
    clear_stats;

    // ---------- R6 非法标记：offset≠0 但 is_frag=0（自相矛盾） ----------
    // frag offset 字段单位为 8 字节，协议层不可能出现"非 8 倍数"；
    // 真正可构造的非法项是 offset≠0 却声明非分片 —— 该帧会被 rx_reassembly
    // 视作未分片透传（is_frag=0 走透传路径），此处验证其「不计入重组上下文」。
    $display("T59 CASE R6");
    do_reset;
    send(mk(16'h6666,1'b0,13'd5,1'b0, 11'd100, 4'd2, 32'h0A000001,32'h0A000002,16'd1,16'd2), 12'd7);
    wait_out;
    chk(got_vld==1 && got_drop==0, "R6 non-frag passthrough not dropped");
    chk(slot_used==0, "R6 non-frag marker occupies no context");
    clear_stats;

    // ---------- R7 超长 ----------
    $display("T59 CASE R7");
    do_reset;
    // IPv4 wire offset=8160 maps to app offset=8152; +600 still exceeds 8192.
    send(mk(16'h7777,1'b1,13'd1020,1'b1, 11'd600, 4'd2, 32'h0A000001,32'h0A000002,16'd1,16'd2), 12'd7);
    wait_out;
    chk(got_drop==1 && got_reason===4'd2, "R7 oversize rejected E_OVERSIZE");
    clear_stats;

    // ---------- R8 并发两组 ----------
    $display("T59 CASE R8");
    do_reset;
    send(mk(16'h8888,1'b1,13'd0,1'b1, 11'd600, 4'd1, 32'h0A000001,32'h0A000002,16'd1,16'd2), 12'd7);
    send(mk(16'h9999,1'b1,13'd0,1'b1, 11'd600, 4'd2, 32'h0A000003,32'h0A000004,16'd3,16'd4), 12'd7);
    repeat (2) @(negedge clk);
    chk(slot_used==2, "R8 two contexts coexist");
    send(mk(16'h9999,1'b0,13'd76,1'b1, 11'd36, 4'd3, 32'h0A000003,32'h0A000004,16'd3,16'd4), 12'd7);
    wait_out;
    chk(got_vld==1 && got_drop==0, "R8 second group delivered");
    chk(out_desc[99:68]===32'h0A000003, "R8 delivered src = group2 first frag");
    chk(slot_used==1, "R8 group1 still pending");
    clear_stats;

    // ---------- R9 槽耗尽 ----------
    $display("T59 CASE R9");
    do_reset;
    // 复位后空槽：连续造 9 组不同 ident，第 9 组必因槽耗尽被拒（SLOTS=8）
    for (i=0;i<9;i=i+1)
      send(mk(16'hA000+i,1'b1,13'd0,1'b1, 11'd100, 4'd1, 32'h0B000000+i,32'h0C000000,16'd1,16'd2), 12'd7);
    wait_out;
    chk(drop_cnt>=32'd1, "R9 slot exhaustion counted");
    chk(slot_used==8, "R9 all 8 slots occupied");
    clear_stats;

    if (errors==0) $display("T59 REASSEMBLY PASS checks=%0d", checks);
    else $display("T59 REASSEMBLY FAIL errors=%0d", errors);
    $finish;
  end

  initial begin #3000000; $display("T59 REASSEMBLY FAIL timeout"); $finish; end
endmodule
