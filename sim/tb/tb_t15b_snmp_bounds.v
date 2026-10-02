// =====================================================================
// T15b -- received-length / nested BER boundaries / bounded responses
//
// Stimulus: SNMPv1 PDUs built byte-by-byte by the tasks below (BER short
// and 0x81 long form), independent of the DUT encoder.  Bytes are pushed
// one per clock WITHOUT waiting for in_ready, exactly like the top level
// where mgmt_sap_rx has no out_ready.
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
// Verdict line: "T15u SNMP ROBUST PASS (...)" / "T15u SNMP ROBUST FAIL (...)"
// =====================================================================
`timescale 1ns/1ps
module tb_t15b_snmp_bounds;
  reg clk = 0; always #4 clk = ~clk;
  reg rst = 1, vld = 0, sop = 0, eop = 0, ack = 0;
  reg [7:0]  data = 0;
  reg [10:0] raddr = 0;
  reg [15:0] ctl = 16'h051c;
  reg [15:0] sport = 16'd41001;
  wire [15:0] peer;
  wire ready, rvld, ctlwe, bagwe;
  wire [15:0] ctlwd;
  wire [7:0]  bagidx;
  wire [31:0] bagwd;
  wire [10:0] rlen;
  wire [7:0]  rbyte, soff;
  wire [31:0] rx_count, tx_count, drop_count;
  snmp_lite #(.SET_ACK_EN(1)) dut (
    .clk(clk), .rst_sync(rst), .en(1'b1),
    .in_vld(vld), .in_sop(sop), .in_eop(eop), .in_data(data),
    .in_sport(sport), .in_ready(ready),
    .uptime_cs(32'h12345), .ctl_val(ctl), .drop_total(32'd0),
    .jit_max_us(32'd0), .buf_util(32'd0), .stats_off(soff),
    .stats_data(32'd0), .vl_data(32'd0), .vl_bag_allowed(1'b1),
    .ctl_we(ctlwe), .ctl_wdata(ctlwd),
    .vl_bag_we(bagwe), .vl_bag_index(bagidx), .vl_bag_wdata(bagwd),
    .mib_group(), .mib_leaf(), .mib_index(),
    .set_ack(1'b1), .set_active(),
    .resp_vld(rvld), .resp_len(rlen), .resp_ack(ack), .resp_rd_addr(raddr), .resp_byte(rbyte),
    .rx_pdu_cnt(rx_count), .resp_cnt(tx_count), .drop_pdu_cnt(drop_count),
    .last_err(), .last_idx(), .last_pdu(), .peer_port(peer), .vb_n(), .state_o());

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
  task bad; input [8*48-1:0] msg; begin errors = errors + 1; $display("  [err] T15b t=%0t: %0s", $time, msg); end endtask
  task chk; input cond; input [8*48-1:0] msg; begin checks = checks + 1; if (!cond) bad(msg); end endtask

  // ---------------- BER request builder ----------------
  reg [7:0] vbl [0:255]; integer vn;
  reg [7:0] pkt [0:1023]; integer pn;
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
  task put_p; input [7:0] b; begin pkt[pn] = b; pn = pn + 1; end endtask
  task put_len; input integer L; begin if (L < 128) put_p(L); else begin put_p(8'h81); put_p(L); end end endtask
  function integer lensz; input integer L; begin lensz = (L < 128) ? 1 : 2; end endfunction
  task build; input [7:0] pdu; input [7:0] rid;
    integer vbl_tl, pdu_cl, pdu_tl, msg_cl, k;
    begin
      vbl_tl = 1 + lensz(vn) + vn;
      pdu_cl = 3 + 3 + 3 + vbl_tl;
      pdu_tl = 1 + lensz(pdu_cl) + pdu_cl;
      msg_cl = 3 + 8 + pdu_tl;
      pn = 0;
      put_p(8'h30); put_len(msg_cl);
      put_p(8'h02); put_p(8'h01); put_p(8'h00);
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
  integer r_id, r_err, r_idx, r_val, r_comm_ok;
  task wait_resp; input integer maxc; output integer seen;
    integer t; begin t = 0; while (rvld !== 1'b1 && t < maxc) begin @(negedge clk); t = t + 1; end seen = (rvld === 1'b1); end
  endtask
  task rd_len; inout integer p; output integer L;
    begin if (rsp[p] == 8'h81) begin L = rsp[p+1]; p = p + 2; end else begin L = rsp[p]; p = p + 1; end end
  endtask
  task decode;
    integer j, p, L, n;
    begin
      for (j = 0; j < rlen && j < 256; j = j + 1) begin @(negedge clk); raddr = j; #1; rsp[j] = rbyte; end
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
      r_val = -1;
      if (L > 0) begin
        p = p + 1; rd_len(p, L);                // VarBind
        p = p + 1; rd_len(p, L); p = p + L;     // OID
        p = p + 1; rd_len(p, L); r_val = 0;
        for (j = 0; j < L; j = j + 1) r_val = (r_val << 8) | rsp[p+j];
      end
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


  integer cases=0, k, j, nfull, seen, before_w, before_d, before_t;
  task warm;
    begin
      reset_unit;
      vb_begin;vb_int(1,11,0,32'h1234);build(8'ha3,40);send;
      expect_resp(40,0,0,"warm valid SET");ackr;
      chk(ctl==16'h1234,"warm value");
      @(negedge clk);ctl=16'h5555;
    end
  endtask
  task good_set;
    begin vb_begin;vb_int(1,11,0,32'h5678);build(8'ha3,41);end
  endtask
  task drop_packet;
    input [8*48-1:0] tag;
    begin
      before_w=nwr;before_d=drop_count;before_t=tx_count;
      send;wait_resp(1200,seen);
      chk(!seen,tag);chk(nwr==before_w && ctl==16'h5555,"rejected PDU has zero SET side effects");
      chk(drop_count==before_d+1,"one rejected PDU counted once");
      chk(tx_count==before_t,"malformed PDU has no response");
      if(seen)ackr;
      get1(42);send;expect_resp(42,0,0,"recovery GET after rejected PDU");ackr;
      cases=cases+1;
    end
  endtask
  task vb_raw;
    input [7:0] leaf,tag; input integer n; input [7:0] fill;
    integer q;
    begin
      put_v(8'h30);put_v(15+n);put_oid(1,leaf,0);put_v(tag);put_v(n);
      for(q=0;q<n;q=q+1)put_v(fill);
    end
  endtask
  task bad_integer;
    input integer n;input [7:0] fill;
    begin
      warm;vb_begin;vb_raw(11,8'h02,n,fill);build(8'ha3,60);
      before_w=nwr;send;expect_resp(60,3,1,"unsupported unsigned SET integer");ackr;
      chk(nwr==before_w && ctl==16'h5555,"badValue SET has zero writes");cases=cases+1;
    end
  endtask
  initial begin
    // Every possible nonempty prefix of a valid request must be rejected.
    for(k=1;k<46;k=k+1)begin
      warm;good_set;chk(pn==46,"short-form SET fixture length");pn=k;
      drop_packet("all-byte truncation sweep");
    end
    // All enclosing lengths still have the original outer length: a check
    // of req_len alone is insufficient for these cases.
    for(k=0;k<10;k=k+1)begin
      warm;good_set;
      case(k)
        0:pkt[14]=pkt[14]-1; 1:pkt[14]=pkt[14]+1; // PDU
        2:pkt[25]=pkt[25]-1; 3:pkt[25]=pkt[25]+1; // VarBindList
        4:pkt[27]=pkt[27]-1; 5:pkt[27]=pkt[27]+1; // VarBind
        6:pkt[29]=pkt[29]-1; 7:pkt[29]=pkt[29]+1; // OID
        8:pkt[42]=pkt[42]-1; 9:pkt[42]=pkt[42]+1; // value
      endcase
      drop_packet("nested length mismatch");
    end
    warm;good_set;pkt[pn]=8'h55;pn=pn+1;drop_packet("trailing octet outside outer SEQUENCE");
    warm;good_set;pkt[1]=8'h80;drop_packet("indefinite length unsupported");
    warm;good_set;pkt[1]=8'h82;drop_packet("two-octet length form unsupported");
    warm;good_set;pkt[1]=8'h81;pn=2;drop_packet("truncated long length octet");
    warm;good_set;pkt[29]=8'd0;drop_packet("empty OID");
    warm;good_set;pkt[29]=8'd17;drop_packet("OID exceeds local capacity");
    // A valid writable prefix followed by malformed syntax must not commit.
    warm;vb_begin;vb_int(1,11,0,32'h6789);vb_int(1,11,0,32'h1234);build(8'ha3,43);
    pkt[47]=pkt[47]-1;drop_packet("malformed second VarBind after writable first");
    bad_integer(0,0);bad_integer(5,0);bad_integer(1,8'hff);
    for(k=0;k<2;k=k+1)begin
      warm;vb_begin;vb_int(1,5,3,k==0 ? 32'd0 : 32'h00800000);build(8'ha3,61);
      before_w=nwr;send;expect_resp(61,3,1,"BAG unsigned half-range bound");ackr;
      chk(nwr==before_w,"invalid BAG has zero writes");cases=cases+1;
    end
    // 256-byte request with valid 0x81 containers and exactly eight VarBinds.
    warm;vb_begin;vb_raw(3,8'h04,91,8'h5a);
    for(j=0;j<7;j=j+1)vb_null(1,3,0);
    build(8'ha0,70);chk(pn==256,"exact-256 fixture size");send;
    expect_resp(70,0,0,"exactly 256 bytes accepted");ackr;cases=cases+1;
    for(k=0;k<2;k=k+1)begin
      warm;vb_begin;vb_raw(3,8'h04,91,8'h5a);
      for(j=0;j<7;j=j+1)vb_null(1,3,0);
      build(8'ha0,71);nfull=pn;
      for(j=nfull;j<(k==0?257:769);j=j+1)pkt[j]=8'h55;
      pn=(k==0?257:769);drop_packet("oversize valid prefix does not wrap/execute");
    end
    // Empty VBL and 0x81 containers remain supported; output length includes
    // outer/PDU overhead, not merely the sum of VarBind bytes.
    reset_unit;vb_begin;build(8'ha0,80);send;expect_resp(80,0,0,"empty VBL");ackr;cases=cases+1;
    for(k=6;k<=7;k=k+1)begin
      reset_unit;vb_begin;for(j=0;j<k;j=j+1)vb_null(1,1,0);
      build(8'ha0,81+k);send;
      expect_resp(81+k,k==6?0:1,0,"complete response capacity check");
      chk(rlen<=256,"no encoded response buffer wrap");ackr;cases=cases+1;
    end
    // Queued request metadata must not change the owner of an unacked response.
    reset_unit;sport=41017;get1(17);send;expect_resp(17,0,0,"response context first");
    chk(peer==41017,"response peer initial");sport=41018;get1(18);send;
    expect_resp(17,0,0,"response bytes held across pending request");
    chk(peer==41017,"unacked response retains original peer");ackr;
    expect_resp(18,0,0,"pending request response");chk(peer==41018,"pending peer applied to its own response");ackr;cases=cases+1;
    if(errors==0)$display("T15b SNMP BOUNDS PASS (%0d cases, %0d checks: all-byte truncation, nested TLV ends, oversize, unsigned values, response capacity, peer context)",cases,checks);
    else $display("T15b SNMP BOUNDS FAIL (errors=%0d cases=%0d checks=%0d)",errors,cases,checks);
    if(errors!=0)$fatal(1,"T15b failed");
    $finish;
  end
  initial begin #3000000;$fatal(1,"T15b watchdog");end
endmodule
