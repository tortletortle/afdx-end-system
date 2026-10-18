// =====================================================================
// T15u -- snmp_lite robustness (audit 20260928 A01 / A02 closure)
//
// Stimulus: SNMPv1 PDUs built byte-by-byte by the tasks below (BER short
// and 0x81 long form), independent of the DUT encoder.  Bytes are pushed
// one per clock WITHOUT waiting for in_ready, exactly like the top level
// byte stream (the top-level SAP hold handshake added in P02 is verified
// separately by T44/T45; this module-level robustness suite drives snmp_lite
// directly and checks its own contract).
//
// C1  serial control: two GETs, clean responses, drop counter 0
// C2  pending-slot burst: resp 17 held unacked, 18 queued, 19 arrives with
//     the slot full -> whole-packet reject + drop_pdu_cnt+1; 17/18 intact,
//     no phantom 3rd response; then request 20 recovers normally
// C3  arrival during parse/encode: 31 sent back-to-back right after 30 ->
//     rejected; response 30 carries id 30 and community "public" byte-exact
//     (old RTL re-copied request-id/community from the overwritten buffer)
// C4  SET {ctl:=0x1234, uptime(RO):=5} -> readOnly(4) idx 2, ZERO writes
// C5  SET {ctl:=0x1234, bogus leaf}    -> noSuchName(2) idx 2, ZERO writes
// C6  SET {bag[3]:=0x000321, ctl:=0x0567} -> ok, exactly 2 writes, in order
// C7  SET with 9 VarBinds (> MAX_VB=8) -> tooBig(1), ZERO writes
// C8  256-byte SET with a 208-byte wrong-type value -> badValue, exact echo
// C9  GETNEXT with terminal second VarBind -> echo both original bindings
// C10 GET with an 8-byte unknown OID -> preserve original OID length/bytes
// C11 version policy (P04): version=1/2 GETs are dropped silently and counted;
//     a following v1 GET recovers normally
// Verdict line: "T15u SNMP ROBUST PASS (...)" / "T15u SNMP ROBUST FAIL (...)"
// =====================================================================
`timescale 1ns/1ps
module tb_t15u_snmp_robust;
  reg clk = 0; always #4 clk = ~clk;
  reg rst = 1, vld = 0, sop = 0, eop = 0, ack = 0;
  reg [7:0]  data = 0;
  reg [10:0] raddr = 0;
  reg [15:0] ctl = 16'h051c;
  wire ready, rvld, ctlwe, bagwe;
  wire [15:0] ctlwd;
  wire [7:0]  bagidx;
  wire [31:0] bagwd;
  wire [10:0] rlen;
  wire [7:0]  rbyte, soff;
  wire [31:0] rx_count, tx_count, drop_count;
  snmp_lite dut (
    .clk(clk), .rst_sync(rst), .en(1'b1),
    .in_vld(vld), .in_sop(sop), .in_eop(eop), .in_data(data),
    .in_sport(16'd49152), .in_ready(ready),
    .uptime_cs(32'h12345), .ctl_val(ctl), .drop_total(32'd0),
    .jit_max_us(32'd0), .buf_util(32'd0), .stats_off(soff),
    .stats_data(32'd0), .vl_data(32'd0), .vl_bag_allowed(1'b1),
    .ctl_we(ctlwe), .ctl_wdata(ctlwd),
    .set_ack(1'b0), .set_active(),
    .vl_bag_we(bagwe), .vl_bag_index(bagidx), .vl_bag_wdata(bagwd),
    .mib_group(), .mib_leaf(), .mib_index(),
    .resp_vld(rvld), .resp_len(rlen), .resp_ack(ack), .resp_rd_addr(raddr), .resp_byte(rbyte),
    .rx_pdu_cnt(rx_count), .resp_cnt(tx_count), .drop_pdu_cnt(drop_count),
    .last_err(), .last_idx(), .last_pdu(), .peer_port(), .vb_n(), .state_o());

  // control object model + write log (order matters for C6)
  integer nwr = 0;
  reg [1:0]  wr_kind [0:15];   // 1 = ctl, 2 = bag
  reg [31:0] wr_val  [0:15];
  reg [7:0]  wr_idx  [0:15];
  always @(posedge clk) begin
    if (rst) ctl <= 16'h051c;
    else begin
      if (ctlwe) ctl <= ctlwd;
      if (ctlwe && nwr < 16) begin wr_kind[nwr] = 2'd1; wr_val[nwr] = {16'd0, ctlwd}; wr_idx[nwr] = 8'd0; end
      if (bagwe && nwr < 16) begin wr_kind[nwr + (ctlwe ? 1 : 0)] = 2'd2; wr_val[nwr + (ctlwe ? 1 : 0)] = bagwd; wr_idx[nwr + (ctlwe ? 1 : 0)] = bagidx; end
      nwr = nwr + (ctlwe ? 1 : 0) + (bagwe ? 1 : 0);
    end
  end

  integer errors = 0, checks = 0;
  task bad; input [8*48-1:0] msg; begin errors = errors + 1; $display("  [err] T15u t=%0t: %0s", $time, msg); end endtask
  task chk; input cond; input [8*48-1:0] msg; begin checks = checks + 1; if (!cond) bad(msg); end endtask

  // ---------------- BER request builder ----------------
  reg [7:0] vbl [0:255]; integer vn;
  reg [7:0] pkt [0:299]; integer pn;
  task vb_begin; begin vn = 0; end endtask
  task put_v; input [7:0] b; begin vbl[vn] = b; vn = vn + 1; end endtask
  task put_oid; input [7:0] g, l, i;
    begin
      put_v(8'h06); put_v(8'h0b);
      put_v(8'h2b); put_v(8'h06); put_v(8'h01); put_v(8'h04);
      put_v(8'h01); put_v(8'ha2); put_v(8'h5c); put_v(8'h01);
      put_v(g); put_v(l); put_v(i);
    end
  endtask
  task vb_null; input [7:0] g, l, i;
    begin put_v(8'h30); put_v(8'h0f); put_oid(g, l, i); put_v(8'h05); put_v(8'h00); end
  endtask
  task vb_int; input [7:0] g, l, i; input [31:0] v;   // 3-byte INTEGER, v < 0x800000
    begin
      put_v(8'h30); put_v(8'h12); put_oid(g, l, i);
      put_v(8'h02); put_v(8'h03); put_v(v[23:16]); put_v(v[15:8]); put_v(v[7:0]);
    end
  endtask
  task vb_blob; input [7:0] g, l, i; input integer n;
    integer j;
    begin
      put_v(8'h30); put_v(8'h81); put_v(16+n); put_oid(g, l, i);
      put_v(8'h04); put_v(8'h81); put_v(n);
      for (j = 0; j < n; j = j + 1) put_v((j * 37 + 11) & 255);
    end
  endtask
  task put_p; input [7:0] b; begin pkt[pn] = b; pn = pn + 1; end endtask
  task put_len; input integer L; begin if (L < 128) put_p(L); else begin put_p(8'h81); put_p(L); end end endtask
  function integer lensz; input integer L; begin lensz = (L < 128) ? 1 : 2; end endfunction
  task build; input [7:0] pdu; input [7:0] rid;
    begin build_v(pdu, rid, 8'h00); end
  endtask
  // P04: version field is parameterised so the accepted-range policy is testable.
  task build_v; input [7:0] pdu; input [7:0] rid; input [7:0] ver;
    integer vbl_tl, pdu_cl, pdu_tl, msg_cl, k;
    begin
      vbl_tl = 1 + lensz(vn) + vn;
      pdu_cl = 3 + 3 + 3 + vbl_tl;
      pdu_tl = 1 + lensz(pdu_cl) + pdu_cl;
      msg_cl = 3 + 8 + pdu_tl;
      pn = 0;
      put_p(8'h30); put_len(msg_cl);
      put_p(8'h02); put_p(8'h01); put_p(ver);
      put_p(8'h04); put_p(8'h06);
      put_p("p"); put_p("u"); put_p("b"); put_p("l"); put_p("i"); put_p("c");
      put_p(pdu); put_len(pdu_cl);
      put_p(8'h02); put_p(8'h01); put_p(rid);
      put_p(8'h02); put_p(8'h01); put_p(8'h00);
      put_p(8'h02); put_p(8'h01); put_p(8'h00);
      put_p(8'h30); put_len(vn);
      for (k = 0; k < vn; k = k + 1) put_p(vbl[k]);
    end
  endtask
  task send; integer i;
    begin
      for (i = 0; i < pn; i = i + 1) begin
        @(negedge clk); vld = 1; sop = (i == 0); eop = (i == pn - 1); data = pkt[i];
      end
      @(negedge clk); vld = 0; sop = 0; eop = 0;
    end
  endtask
  task get1; input [7:0] rid; begin vb_begin; vb_null(8'd1, 8'd3, 8'd0); build(8'ha0, rid); end endtask

  // ---------------- response side ----------------
  reg [7:0] rsp [0:255];
  integer r_id, r_err, r_idx, r_val, r_comm_ok, r_vbl_pos, r_vbl_len;
  task wait_resp; input integer maxc; output integer seen;
    integer t; begin t = 0; while (rvld !== 1'b1 && t < maxc) begin @(negedge clk); t = t + 1; end seen = (rvld === 1'b1); end
  endtask
  task rd_len; inout integer p; output integer L;
    begin if (rsp[p] == 8'h81) begin L = rsp[p+1]; p = p + 2; end else begin L = rsp[p]; p = p + 1; end end
  endtask
  task decode;
    integer j, p, L, n;
    begin
      for (j = 0; j < rlen && j < 256; j = j + 1) begin
        raddr = j; @(negedge clk); #1; rsp[j] = rbyte;
      end
      p = 1; rd_len(p, L);                      // SEQUENCE
      p = p + 3;                                // version
      r_comm_ok = (rsp[p] == 8'h04 && rsp[p+1] == 8'h06 && rsp[p+2] == "p" && rsp[p+3] == "u" &&
                   rsp[p+4] == "b" && rsp[p+5] == "l" && rsp[p+6] == "i" && rsp[p+7] == "c");
      p = p + 8;
      if (rsp[p] !== 8'ha2) r_comm_ok = 0;
      p = p + 1; rd_len(p, L);
      p = p + 1; n = rsp[p]; p = p + 1; r_id = 0;
      for (j = 0; j < n; j = j + 1) r_id = (r_id << 8) | rsp[p+j];
      p = p + n;
      r_err = rsp[p+2]; p = p + 3;
      r_idx = rsp[p+2]; p = p + 3;
      p = p + 1; rd_len(p, L);                  // VarBindList
      r_vbl_pos = p; r_vbl_len = L;
      r_val = -1;
      if (L > 0) begin
        p = p + 1; rd_len(p, L);                // VarBind
        p = p + 1; rd_len(p, L); p = p + L;     // OID
        p = p + 1; rd_len(p, L); r_val = 0;
        for (j = 0; j < L; j = j + 1) r_val = (r_val << 8) | rsp[p+j];
      end
    end
  endtask
  task chk_echo;
    integer j;
    begin
      chk(r_vbl_len == vn, "error echo: original list length");
      chk(rlen == r_vbl_pos + vn, "error echo: complete response length");
      for (j = 0; j < vn; j = j + 1)
        chk(rsp[r_vbl_pos+j] === vbl[j], "error echo: original VarBind bytes");
    end
  endtask
  task ackr; begin @(negedge clk); ack = 1; @(negedge clk); ack = 0; @(negedge clk); end endtask
  task reset_unit; begin @(negedge clk); rst = 1; vld = 0; ack = 0; repeat (5) @(negedge clk); rst = 0; repeat (3) @(negedge clk); nwr = 0; end endtask
  task expect_resp; input integer id; input integer err; input integer idx; input [8*48-1:0] tag;
    integer seen;
    begin
      wait_resp(3000, seen);
      chk(seen, tag);
      if (seen) begin
        decode;
        chk(r_id == id && r_err == err && r_idx == idx && r_comm_ok, tag);
        if (!(r_id == id && r_err == err && r_idx == idx && r_comm_ok))
          $display("    got id=%0d err=%0d idx=%0d comm_ok=%0d, want id=%0d err=%0d idx=%0d", r_id, r_err, r_idx, r_comm_ok, id, err, idx);
      end
    end
  endtask

  integer seen, d0, k;
  initial begin
    reset_unit;
    // ---------- C1 ----------
    get1(8'd1); send; expect_resp(1, 0, 0, "C1 serial GET 1"); ackr;
    get1(8'd2); send; expect_resp(2, 0, 0, "C1 serial GET 2"); ackr;
    chk(tx_count == 2 && drop_count == 0, "C1 counters");

    // ---------- C2 ----------
    reset_unit;
    get1(8'd17); send; wait_resp(3000, seen); chk(seen, "C2 resp 17 present");
    chk(ready === 1'b1, "C2 slot free while resp pending");
    get1(8'd18); send; repeat (5) @(negedge clk);
    chk(ready === 1'b0, "C2 in_ready low with slot full");
    get1(8'd19); send; repeat (5) @(negedge clk);
    chk(drop_count == 1, "C2 reject counted (drop=1)");
    expect_resp(17, 0, 0, "C2 resp 17 intact"); ackr;
    expect_resp(18, 0, 0, "C2 resp 18 from slot"); ackr;
    wait_resp(3000, seen); chk(!seen, "C2 no phantom response 19");
    chk(rx_count == 2 && tx_count == 2 && drop_count == 1, "C2 counters 2/2/1");
    get1(8'd20); send; expect_resp(20, 0, 0, "C2 recovery GET 20"); ackr;

    // ---------- C3 ----------
    reset_unit;
    get1(8'd30); send;                      // parse starts right after EOP
    get1(8'd31); send;                      // arrives while 30 is parsed/encoded
    expect_resp(30, 0, 0, "C3 resp 30 id+community exact"); ackr;
    wait_resp(3000, seen); chk(!seen, "C3 no response for 31");
    chk(drop_count == 1 && tx_count == 1, "C3 counters");

    // ---------- C4 ----------
    reset_unit;
    vb_begin; vb_int(8'd1, 8'd11, 8'd0, 32'h1234); vb_int(8'd1, 8'd2, 8'd0, 32'd5); build(8'ha3, 8'd49);
    send; expect_resp(49, 4, 2, "C4 readOnly err/idx"); chk_echo; ackr;
    chk(nwr == 0 && ctl == 16'h051c, "C4 rejected SET wrote nothing");

    // ---------- C5 ----------
    reset_unit;
    vb_begin; vb_int(8'd1, 8'd11, 8'd0, 32'h1234); vb_int(8'd1, 8'd99, 8'd0, 32'd5); build(8'ha3, 8'd50);
    send; expect_resp(50, 2, 2, "C5 noSuchName err/idx"); chk_echo; ackr;
    chk(nwr == 0 && ctl == 16'h051c, "C5 rejected SET wrote nothing");

    // ---------- C6 ----------
    reset_unit;
    vb_begin; vb_int(8'd1, 8'd5, 8'd3, 32'h000321); vb_int(8'd1, 8'd11, 8'd0, 32'h0567); build(8'ha3, 8'd51);
    send; expect_resp(51, 0, 0, "C6 two-VarBind SET ok"); ackr;
    chk(nwr == 2, "C6 exactly two writes");
    chk(wr_kind[0] == 2'd2 && wr_idx[0] == 8'd3 && wr_val[0] == 32'h000321, "C6 write 1 = bag[3]");
    chk(wr_kind[1] == 2'd1 && wr_val[1] == 32'h0567, "C6 write 2 = ctl");
    chk(ctl == 16'h0567, "C6 ctl final value");

    // ---------- C7 ----------
    reset_unit;
    vb_begin; for (k = 0; k < 9; k = k + 1) vb_int(8'd1, 8'd11, 8'd0, 32'h1000 + k); build(8'ha3, 8'd52);
    send; expect_resp(52, 1, 0, "C7 tooBig err");
    chk(r_vbl_len == 0, "C7 bounded tooBig list is empty"); ackr;
    chk(nwr == 0 && ctl == 16'h051c, "C7 tooBig SET wrote nothing");

    // ---------- C8: long BER lengths and the final request-buffer byte ----------
    reset_unit;
    vb_begin; vb_blob(8'd1, 8'd11, 8'd0, 208); build(8'ha3, 8'd53);
    chk(pn == 256, "C8 exact request capacity");
    send; expect_resp(53, 3, 1, "C8 wrong-type long value"); chk_echo;
    chk(rlen == 256, "C8 exact response capacity"); ackr;
    chk(nwr == 0 && ctl == 16'h051c && drop_count == 0, "C8 no write/drop/wrap");
    get1(8'd54); send; expect_resp(54, 0, 0, "C8 recovery GET"); ackr;

    // ---------- C9: a failed walk must not return the earlier successor ----------
    reset_unit;
    vb_begin; vb_null(8'd1, 8'd3, 8'd0); vb_null(8'd2, 8'd47, 8'd0); build(8'ha1, 8'd55);
    send; expect_resp(55, 2, 2, "C9 terminal second GETNEXT"); chk_echo; ackr;
    chk(nwr == 0 && drop_count == 0, "C9 no write/drop");

    // ---------- C10: no synthetic 11-byte OID on an unknown short object ----------
    reset_unit;
    vb_begin; put_v(8'h30); put_v(8'h0c); put_v(8'h06); put_v(8'h08);
    put_v(8'h2b); put_v(8'h06); put_v(8'h01); put_v(8'h04);
    put_v(8'h01); put_v(8'ha2); put_v(8'h5c); put_v(8'h01);
    put_v(8'h05); put_v(8'h00); build(8'ha0, 8'd56);
    send; expect_resp(56, 2, 1, "C10 short unknown OID"); chk_echo; ackr;
    chk(nwr == 0 && drop_count == 0, "C10 no write/drop");

    // ---------- C11: version policy — only SNMPv1(0) is accepted (P04) ----------
    reset_unit;
    vb_begin; vb_null(8'd1, 8'd3, 8'd0); build_v(8'ha0, 8'd57, 8'd1);
    send; wait_resp(3000, seen); chk(!seen, "C11 v2c(1) GET must be dropped silently");
    chk(drop_count == 1 && tx_count == 0, "C11 version=1 drop counted exactly once");
    vb_begin; vb_null(8'd1, 8'd3, 8'd0); build_v(8'ha0, 8'd58, 8'd2);
    send; wait_resp(3000, seen); chk(!seen, "C11 unknown version(2) GET must be dropped");
    chk(drop_count == 2, "C11 version=2 drop counted exactly once");
    get1(8'd59); send; expect_resp(59, 0, 0, "C11 v1 GET recovery after drops"); ackr;
    chk(tx_count == 1, "C11 recovery response exactly once");

    if (errors == 0)
      $display("T15u SNMP ROBUST PASS (11 cases, %0d checks: pending-slot reject+count, parse-time arrival reject, atomic SET, bounded tooBig, exact error VarBind echo through byte 255, terminal GETNEXT, short unknown OID, v1-only version policy)", checks);
    else
      $display("T15u SNMP ROBUST FAIL (errors=%0d of %0d checks)", errors, checks);
    $finish;
  end
  initial begin #3000000; $display("T15u SNMP ROBUST FAIL (watchdog)"); $finish; end
endmodule
