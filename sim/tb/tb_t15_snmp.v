// =====================================================================
// T15 —— snmp_lite（GET / GETNEXT / SET + STATS_BLOCK 只读组）
// 请求 PDU 全部来自 sw/golden/gen_t15_vectors.py 生成的真实 SAP 帧
// （ETH/IP/UDP + AFDX SN + zlib 线序 FCS），TB 侧自己做 BER 解码来校验响应。
//   A 部分：把金标帧的 UDP 载荷直接灌进 snmp_lite 单元，逐条校验
//           响应 PDU 的 BER 结构、request-id 回抄、error-status/index、
//           VarBind 的 OID 与值编码。
//   B 部分：同样的帧真的走线 → mac_rx_if → 解析 → mgmt_sap_rx 取 PMEM
//           载荷 → snmp_lite，主机经 0xAC14~0xAC1F 观测窗读响应字节。
// 边界：响应只编码并经观测窗读出，未接入 TX 帧构建器（管理面回包不上线）。
// =====================================================================
`timescale 1 ns / 1 ps
module tb_t15_snmp #(parameter integer IF_MODE = 0);
  integer errors = 0;
  reg clk = 0;
  always #4 clk = ~clk;
  task bad;
    input [8*110-1:0] reason;
    begin if (errors < 30) $display("  [err] T15: %0s", reason); errors = errors + 1; end
  endtask
  task badv;
    input [8*90-1:0] reason; input [31:0] got; input [31:0] want;
    begin
      if (errors < 30) $display("  [err] T15: %0s (got=%0h want=%0h)", reason, got, want);
      errors = errors + 1;
    end
  endtask

  // ---------------- 金标帧 ----------------
  reg [31:0] vec [0:2047];
  integer cbase [0:63];
  integer clen  [0:63];
  integer cplen [0:63];
  integer ncase, vi2, cid, i, k, b, waitc;
  function [7:0] fbyte; input integer c; input integer off;
    reg [31:0] q;
    begin
      q = vec[cbase[c] + (off>>2)];
      case (off & 3) 0: fbyte=q[31:24]; 1: fbyte=q[23:16];
                     2: fbyte=q[15:8];  default: fbyte=q[7:0]; endcase
    end
  endfunction
  function [7:0] pbyte;                 // 用例 c 的第 j 个 UDP 载荷字节
    input integer c; input integer j;
    begin pbyte = fbyte(c, 42 + j); end
  endfunction

  // ---------------- 响应缓存与 BER 解码 ----------------
  reg [7:0] rb [0:255];
  integer rlen;
  integer r_err, r_idx, r_nvb, r_rid, r_ver, r_comm;
  integer vbg [0:7];
  integer vbl [0:7];
  integer vbi [0:7];
  integer vbt [0:7];
  integer vbn [0:7];
  integer vbv [0:7];
  integer vbp [0:7];
  integer pp, ln, ol, vl, stop, jj;
  function [7:0] pfx; input integer j;
    begin
      case (j) 0:pfx=8'h2B;1:pfx=8'h06;2:pfx=8'h01;3:pfx=8'h04;
               4:pfx=8'h01;5:pfx=8'hA2;6:pfx=8'h5C;7:pfx=8'h01; default:pfx=8'h00; endcase
    end
  endfunction
  function [7:0] dch; input integer j;
    begin
      case (j) 0:dch="A";1:dch="F";2:dch="D";3:dch="X";4:dch="-";5:dch="E";
               6:dch="S";7:dch=" ";8:dch="e";9:dch="L";10:dch="i";11:dch="n";
               12:dch="x";13:dch=" ";14:dch="v";15:dch="1"; default:dch=8'h20; endcase
    end
  endfunction
  task get_len;                          // 短式 / 0x81 长式
    begin
      if (rb[pp] < 8'h80) begin ln = rb[pp]; pp = pp + 1; end
      else if (rb[pp] == 8'h81) begin ln = rb[pp+1]; pp = pp + 2; end
      else begin bad("response used an unsupported long-form length"); ln = 0; pp = pp + 2; end
    end
  endtask
  task decode;
    begin
      r_err = -1; r_idx = -1; r_nvb = 0; r_rid = 0; r_ver = -1; r_comm = 0;
      pp = 0;
      if (rb[0] !== 8'h30) bad("response is not a BER SEQUENCE");
      pp = 1; get_len;
      if ((pp + ln) !== rlen) badv("outer SEQUENCE length wrong", pp+ln, rlen);
      if (rb[pp] !== 8'h02 || rb[pp+1] !== 8'd1) bad("version TLV malformed");
      r_ver = rb[pp+2]; pp = pp + 3;
      if (rb[pp] !== 8'h04) bad("community TLV malformed");
      r_comm = rb[pp+1]; pp = pp + 2;
      if (r_comm !== 6) bad("community must be echoed as 6 bytes");
      if (rb[pp] !== "p" || rb[pp+1] !== "u" || rb[pp+2] !== "b" ||
          rb[pp+3] !== "l" || rb[pp+4] !== "i" || rb[pp+5] !== "c")
        bad("community not echoed verbatim");
      pp = pp + r_comm;
      if (rb[pp] !== 8'hA2) badv("PDU type must be GetResponse", {24'd0,rb[pp]}, 32'hA2);
      pp = pp + 1; get_len;
      if (rb[pp] !== 8'h02) bad("request-id TLV malformed");
      ol = rb[pp+1]; pp = pp + 2;
      for (jj = 0; jj < ol; jj = jj + 1) r_rid = (r_rid << 8) | rb[pp+jj];
      pp = pp + ol;
      if (rb[pp] !== 8'h02 || rb[pp+1] !== 8'd1) bad("error-status TLV malformed");
      r_err = rb[pp+2]; pp = pp + 3;
      if (rb[pp] !== 8'h02 || rb[pp+1] !== 8'd1) bad("error-index TLV malformed");
      r_idx = rb[pp+2]; pp = pp + 3;
      if (rb[pp] !== 8'h30) bad("varbind-list TLV malformed");
      pp = pp + 1; get_len;
      stop = pp + ln;
      while (pp < stop && r_nvb < 8) begin
        if (rb[pp] !== 8'h30) bad("varbind TLV malformed");
        pp = pp + 1; get_len;
        if (rb[pp] !== 8'h06) bad("OID TLV malformed");
        ol = rb[pp+1]; pp = pp + 2;
        if (ol !== 11) badv("OID length must be 11", ol, 11);
        for (jj = 0; jj < 8; jj = jj + 1)
          if (rb[pp+jj] !== pfx(jj)) bad("enterprise OID prefix wrong");
        vbg[r_nvb] = rb[pp+8];
        vbl[r_nvb] = rb[pp+9];
        vbi[r_nvb] = rb[pp+10];
        pp = pp + ol;
        vbt[r_nvb] = rb[pp];
        vl = rb[pp+1];
        vbn[r_nvb] = vl;
        pp = pp + 2;
        vbp[r_nvb] = pp;
        vbv[r_nvb] = 0;
        for (jj = 0; jj < vl && jj < 4; jj = jj + 1) vbv[r_nvb] = (vbv[r_nvb] << 8) | rb[pp+jj];
        pp = pp + vl;
        r_nvb = r_nvb + 1;
      end
      if (pp !== stop) bad("varbind list did not consume exactly its length");
    end
  endtask

  // ================= A：snmp_lite 单元级 =================
  reg        s_rst = 1'b1;
  reg        s_vld = 0, s_sop = 0, s_eop = 0;
  reg [7:0]  s_data = 0;
  reg [15:0] s_sport = 16'd49152;
  reg [31:0] s_uptime = 32'h0001_2345;
  reg [15:0] s_ctl = 16'h051C;
  reg [31:0] s_drop = 32'h0000_00AB, s_jit = 32'h0000_1F40, s_buf = 32'd6;
  reg [31:0] s_vl_data = 32'h00AB_CDEF;
  wire s_bag_allowed = 1'b1;
  wire s_bag_we;
  wire [7:0] s_bag_idx;
  wire [31:0] s_bag_wdata;
  reg [31:0] s_bag_seen = 32'd0;
  reg [7:0] idx_req [0:63];
  integer idx_len;
  reg        s_rack = 0;
  reg [10:0] s_raddr = 0;
  wire [7:0]  s_off;
  wire [31:0] s_sdata = 32'h1000_0000 + {24'd0, s_off};
  wire        s_ctlwe;
  wire [15:0] s_ctlwd;
  wire        s_rvld;
  wire [10:0] s_rlen;
  wire [7:0]  s_rbyte;
  wire [31:0] s_rx, s_tx, s_drp;
  wire [3:0]  s_e, s_ix, s_vbn;
  wire [7:0]  s_pdu;
  wire [15:0] s_peer;
  snmp_lite #(.NUM_TX_VL(128), .NUM_RX_VL(4096), .MAX_VB(8), .SET_ACK_EN(1)) sut (
    .clk(clk), .rst_sync(s_rst), .en(1'b1),
    .in_vld(s_vld), .in_sop(s_sop), .in_eop(s_eop), .in_data(s_data),
    .in_sport(s_sport), .in_ready(),
    .uptime_cs(s_uptime), .ctl_val(s_ctl), .drop_total(s_drop),
    .jit_max_us(s_jit), .buf_util(s_buf),
    .stats_off(s_off), .stats_data(s_sdata),
    .ctl_we(s_ctlwe), .ctl_wdata(s_ctlwd),
    .vl_data(s_vl_data), .vl_bag_allowed(s_bag_allowed),
    .vl_bag_we(s_bag_we), .vl_bag_index(s_bag_idx), .vl_bag_wdata(s_bag_wdata),
    .mib_group(), .mib_leaf(), .mib_index(),
    .set_ack(1'b1), .set_active(),
    .resp_vld(s_rvld), .resp_len(s_rlen), .resp_ack(s_rack),
    .resp_rd_addr(s_raddr), .resp_byte(s_rbyte),
    .rx_pdu_cnt(s_rx), .resp_cnt(s_tx), .drop_pdu_cnt(s_drp),
    .last_err(s_e), .last_idx(s_ix), .last_pdu(s_pdu), .peer_port(s_peer),
    .vb_n(s_vbn), .state_o());
  always @(posedge clk) begin
    if (!s_rst && s_ctlwe) s_ctl <= s_ctlwd;
    if (!s_rst && s_bag_we) s_bag_seen <= s_bag_wdata;
  end

  task u_send; input integer c;
    begin
      for (i = 0; i < cplen[c]; i = i + 1) begin
        @(negedge clk);
        s_vld = 1; s_sop = (i == 0); s_eop = (i == cplen[c]-1); s_data = pbyte(c, i);
      end
      @(negedge clk); s_vld = 0; s_sop = 0; s_eop = 0;
      waitc = 0;
      while (s_rvld !== 1'b1 && waitc < 4000) begin @(negedge clk); waitc = waitc + 1; end
    end
  endtask
  task idx_send;
    input integer kind; input integer leaf;
    integer z;
    begin
      idx_len = (kind == 2) ? 47 : 44;
      for (z = 0; z < 64; z = z + 1) idx_req[z] = 8'd0;
      idx_req[0] = 8'h30; idx_req[1] = (kind == 2) ? 8'h2D : 8'h2A;
      idx_req[2] = 8'h02; idx_req[3] = 8'h01; idx_req[4] = 8'h00;
      idx_req[5] = 8'h04; idx_req[6] = 8'h06;
      idx_req[7] = 8'h70; idx_req[8] = 8'h75; idx_req[9] = 8'h62;
      idx_req[10] = 8'h6C; idx_req[11] = 8'h69; idx_req[12] = 8'h63;
      idx_req[13] = (kind == 2) ? 8'hA3 : (kind == 1) ? 8'hA1 : 8'hA0;
      idx_req[14] = (kind == 2) ? 8'h20 : 8'h1D;
      idx_req[15] = 8'h02; idx_req[16] = 8'h02;
      idx_req[17] = 8'h02; idx_req[18] = (kind == 2) ? 8'h23 : 8'h20;
      idx_req[19] = 8'h02; idx_req[20] = 8'h01; idx_req[21] = 8'h00;
      idx_req[22] = 8'h02; idx_req[23] = 8'h01; idx_req[24] = 8'h00;
      idx_req[25] = 8'h30; idx_req[26] = (kind == 2) ? 8'h14 : 8'h11;
      idx_req[27] = 8'h30; idx_req[28] = (kind == 2) ? 8'h12 : 8'h0F;
      idx_req[29] = 8'h06; idx_req[30] = 8'h0B;
      idx_req[31] = 8'h2B; idx_req[32] = 8'h06; idx_req[33] = 8'h01;
      idx_req[34] = 8'h04; idx_req[35] = 8'h01; idx_req[36] = 8'hA2;
      idx_req[37] = 8'h5C; idx_req[38] = 8'h01; idx_req[39] = 8'h01;
      idx_req[40] = leaf[7:0]; idx_req[41] = 8'd5;
      if (kind == 2) begin
        idx_req[42] = 8'h02; idx_req[43] = 8'h03;
        idx_req[44] = 8'h12; idx_req[45] = 8'h34; idx_req[46] = 8'h56;
      end else begin
        idx_req[42] = 8'h05; idx_req[43] = 8'h00;
      end
      for (z = 0; z < idx_len; z = z + 1) begin
        @(negedge clk); s_vld = 1'b1; s_sop = (z == 0);
        s_eop = (z == idx_len-1); s_data = idx_req[z];
      end
      @(negedge clk); s_vld = 1'b0; s_sop = 1'b0; s_eop = 1'b0;
      waitc = 0;
      while (s_rvld !== 1'b1 && waitc < 4000) begin @(negedge clk); waitc = waitc + 1; end
    end
  endtask

  task u_grab;                       // 取回响应并解码
    begin
      if (s_rvld !== 1'b1) begin bad("unit: no response produced"); rlen = 0; end
      else begin
        rlen = s_rlen;
        for (i = 0; i < rlen; i = i + 1) begin s_raddr = i[10:0]; #1; rb[i] = s_rbyte; end
        decode;
        @(negedge clk); s_rack = 1; @(negedge clk); s_rack = 0;
      end
    end
  endtask

  // ================= B：顶层 =================
  reg reset = 1'b1;
  reg [7:0] rx_data = 0, rx_data_b = 0;
  reg rx_valid = 0, rx_valid_b = 0, rx_ready = 0, rx_ready_b = 0;
  reg host_cs = 0, host_we = 0;
  reg [15:0] host_addr = 0;
  reg [31:0] host_wdata = 0;
  wire [31:0] host_rdata;
  wire host_ack;
  AFDX_top #(.IF_MODE(IF_MODE), .FCS_MODE(2), .SNMP_SAP_PORT(5), .TFTP_SAP_PORT(9)) dut (
    .clk(clk), .reset(reset), .tx_data(), .tx_valid(), .tx_ready(),
    .rx_data(rx_data), .rx_valid(rx_valid), .rx_ready(rx_ready),
    .tx_data_b(), .tx_valid_b(), .tx_ready_b(),
    .rx_data_b(rx_data_b), .rx_valid_b(rx_valid_b), .rx_ready_b(rx_ready_b),
    .host_cs(host_cs), .host_we(host_we), .host_addr(host_addr),
    .host_wdata(host_wdata), .host_rdata(host_rdata), .host_ack(host_ack),
    .host_irq(), .pps_in(1'b0), .pps_out(), .rtc_time_us(), .dbg_frame_event());
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
  localparam [31:0] W0_VL  = 32'hF500_0000 | (P_SAP<<12) | 32'd700;
  reg [31:0] d, e;
  integer acc0;
  task drive_case; input integer c;
    begin
      acc0 = dut.mgmt_accept_cnt;
      for (b = 0; b < clen[c]; b = b + 1) begin
        @(negedge clk); rx_ready=1; rx_valid=1; rx_data=fbyte(c,b);
        if (IF_MODE == 0) begin
          @(negedge clk); rx_valid=0; repeat (8) @(negedge clk);
        end
      end
      @(negedge clk); rx_ready=0; rx_valid=0;
      waitc = 0;
      while (dut.mgmt_accept_cnt <= acc0 && waitc < 20000) begin
        @(negedge clk); waitc = waitc + 1;
      end
      if (waitc >= 20000) bad("SAP endpoint never accepted the frame");
      waitc = 0;
      while (dut.u_mgmt_sap.st !== 2'd0 && waitc < 8000) begin
        @(negedge clk); waitc = waitc + 1;
      end
      repeat (400) @(negedge clk);
    end
  endtask
  task t_grab;                       // 顶层经观测窗取回响应并解码
    reg [31:0] w;
    begin
      host_read(16'hAC1C, w);
      if (w[0] !== 1'b1) begin bad("top: no SNMP response queued"); rlen = 0; end
      else begin
        host_read(16'hAC15, w); rlen = w[10:0];
        for (i = 0; i < rlen; i = i + 1) begin
          host_write(16'hAC1A, i[31:0]);
          host_read(16'hAC1B, w);
          rb[i] = w[7:0];
        end
        decode;
        host_write(16'hAC1C, 32'd1);
      end
    end
  endtask

  initial begin
    $readmemh("vec/t15_mgmt.hex", vec);
    ncase = vec[0];
    if (ncase < 22) bad("A0 management golden vectors missing");
    vi2 = 1;
    for (i = 0; i < ncase; i = i + 1) begin
      cid = vec[vi2][31:24];
      clen[cid]  = vec[vi2][15:0];
      cplen[cid] = vec[vi2+1];
      cbase[cid] = vi2 + 3;
      vi2 = vi2 + 3 + (vec[vi2][15:0] + 3) / 4;
    end

    // ---------------- A ----------------
    repeat (4) @(negedge clk); s_rst = 1'b0;
    // A1 GET afdxEsUpTime（TimeTicks）
    u_send(10); u_grab;
    if (r_err !== 0 || r_idx !== 0) badv("A1 GET must succeed", r_err, 0);
    if (r_rid !== 32'h11223344) badv("A1 request-id not echoed", r_rid, 32'h11223344);
    if (r_ver !== 0) bad("A1 version must be echoed as v1(0)");
    if (r_nvb !== 1) badv("A1 varbind count", r_nvb, 1);
    if (vbg[0] !== 1 || vbl[0] !== 2) bad("A1 OID not echoed");
    if (vbt[0] !== 8'h43) badv("A1 upTime must be TimeTicks(0x43)", vbt[0], 8'h43);
    if (vbv[0] !== s_uptime) badv("A1 upTime value", vbv[0], s_uptime);
    // A2 GETNEXT 从标量组末项走到 STATS_BLOCK 组首项
    u_send(11); u_grab;
    if (r_err !== 0) bad("A2 GETNEXT must succeed");
    if (vbg[0] !== 2 || vbl[0] !== 0) bad("A2 GETNEXT must step into the STATS_BLOCK group");
    if (vbt[0] !== 8'h41) bad("A2 STATS_BLOCK objects must be Counter32");
    if (vbv[0] !== 32'h1000_0000) badv("A2 STATS_BLOCK value", vbv[0], 32'h1000_0000);
    // A3 SET afdxEsCtl（唯一可写对象）
    u_send(12); u_grab;
    if (r_err !== 0 || r_idx !== 0) badv("A3 SET must succeed", r_err, 0);
    if (vbv[0] !== 32'h1234) badv("A3 SET must echo the new value", vbv[0], 32'h1234);
    if (s_ctl !== 16'h1234) badv("A3 SET did not reach the control shadow", {16'd0,s_ctl}, 32'h1234);
    // A4 GET 回读 SET 结果
    u_send(13); u_grab;
    if (vbv[0] !== 32'h1234) badv("A4 GET after SET", vbv[0], 32'h1234);
    if (vbt[0] !== 8'h02) bad("A4 esCtl must be INTEGER");
    // A5 GET 不存在的对象 → noSuchName(2)
    u_send(14); u_grab;
    if (r_err !== 2) badv("A5 unknown OID must return noSuchName(2)", r_err, 2);
    if (r_idx !== 1) badv("A5 error-index must point at varbind 1", r_idx, 1);
    if (vbt[0] !== 8'h05 || vbn[0] !== 0) bad("A5 error response must carry NULL values");
    // A6 SET 只读对象 → readOnly(4)
    u_send(15); u_grab;
    if (r_err !== 4) badv("A6 SET to RO must return readOnly(4)", r_err, 4);
    if (r_idx !== 1) bad("A6 error-index wrong");
    // A7 community 不符 → 静默丢弃
    e = s_drp; d = s_tx;
    u_send(16);
    repeat (40) @(negedge clk);
    if (s_rvld === 1'b1) bad("A7 wrong community must not be answered");
    if (s_drp !== (e + 32'd1)) badv("A7 drop counter did not advance", s_drp, e+32'd1);
    if (s_tx !== d) bad("A7 response counter must not advance");
    // A8 多 VarBind：两个 STATS_BLOCK 字
    u_send(17); u_grab;
    if (r_err !== 0) bad("A8 multi-varbind GET must succeed");
    if (r_nvb !== 2) badv("A8 varbind count", r_nvb, 2);
    if (vbg[0] !== 2 || vbl[0] !== 4) bad("A8 varbind 1 OID wrong");
    if (vbg[1] !== 2 || vbl[1] !== 7) bad("A8 varbind 2 OID wrong");
    if (vbv[0] !== 32'h1000_0004 || vbv[1] !== 32'h1000_0007) bad("A8 STATS_BLOCK values wrong");
    // A9 OCTET STRING 对象
    u_send(18); u_grab;
    if (vbt[0] !== 8'h04) bad("A9 descr must be OCTET STRING");
    if (vbn[0] !== 16) badv("A9 descr length", vbn[0], 16);
    for (i = 0; i < 16; i = i + 1)
      if (rb[vbp[0]+i] !== dch(i)) bad("A9 descr string content wrong");
    // A10 SET 类型不符 → badValue(3)
    u_send(19); u_grab;
    if (r_err !== 3) badv("A10 SET with wrong type must return badValue(3)", r_err, 3);
    if (s_ctl !== 16'h1234) bad("A10 rejected SET must not change the object");
    // A11 三 VarBind 标量组
    u_send(20); u_grab;
    if (r_nvb !== 3) badv("A11 varbind count", r_nvb, 3);
    if (vbv[0] !== 32'd128) badv("A11 numTxVl", vbv[0], 32'd128);
    if (vbv[1] !== 32'd4096) badv("A11 numRxVl", vbv[1], 32'd4096);
    if (vbt[2] !== 8'h42) bad("A11 bufUtil must be Gauge32");
    if (vbv[2] !== s_buf) badv("A11 bufUtil value", vbv[2], s_buf);
    // A12 GETNEXT 走出 MIB 末尾 → noSuchName(2)
    u_send(21); u_grab;
    if (r_err !== 2) badv("A12 GETNEXT past end must return noSuchName(2)", r_err, 2);
    // A13 indexed VL objects：.5~.9、非零 instance、GETNEXT 与 .5 SET
    idx_send(0, 5); u_grab;
    if (r_err !== 0 || vbg[0] !== 1 || vbl[0] !== 5 || vbi[0] !== 5 || vbv[0] !== s_vl_data)
      bad("A13 indexed .5 GET wrong");
    idx_send(0, 6); u_grab;
    if (r_err !== 0 || vbl[0] !== 6 || vbi[0] !== 5 || vbv[0] !== s_vl_data)
      bad("A13 indexed .6 GET wrong");
    idx_send(0, 7); u_grab;
    if (r_err !== 0 || vbl[0] !== 7 || vbi[0] !== 5) bad("A13 indexed .7 GET wrong");
    idx_send(0, 8); u_grab;
    if (r_err !== 0 || vbl[0] !== 8 || vbi[0] !== 5) bad("A13 indexed .8 GET wrong");
    idx_send(0, 9); u_grab;
    if (r_err !== 0 || vbl[0] !== 9 || vbi[0] !== 5) bad("A13 indexed .9 GET wrong");
    idx_send(1, 5); u_grab;
    if (r_err !== 0 || vbl[0] !== 5 || vbi[0] !== 6) bad("A13 indexed GETNEXT wrong");
    idx_send(2, 5); u_grab;
    if (r_err !== 0 || vbl[0] !== 5 || vbi[0] !== 5 || vbv[0] !== 32'h0012_3456)
      bad("A13 indexed .5 SET wrong");
    if (s_bag_seen !== 32'h0012_3456 || s_bag_idx !== 8'd5)
      bad("A13 indexed .5 SET writeback wrong");
    // A14 计数器自洽
    if (s_rx !== 32'd19) badv("A14 rx_pdu_cnt", s_rx, 32'd19);
    if (s_tx !== 32'd18) badv("A14 resp_cnt", s_tx, 32'd18);
    if (s_drp !== 32'd1) badv("A13 drop_pdu_cnt", s_drp, 32'd1);

    // ---------------- B ----------------
    repeat (7) @(negedge clk); reset = 0;
    waitc = 0;
    while (dut.init_done !== 1 && waitc < 26000) begin @(negedge clk); waitc = waitc + 1; end
    if (waitc >= 26000) bad("B0 INIT_DONE timeout");
    host_write(16'h0008, 32'h2000);
    host_write(16'h0078, 32'h172D); host_write(16'h007C, 32'hAB61);
    host_write(16'h42B2, 32'h1010_0100); host_write(16'h0080, 32'h1);
    host_write(16'h1F80, W0_VL); host_write(16'h1F81, 32'h0000_0100);
    host_write(PT_SAP,   32'h8006_0000); host_write(PT_SAP+1, 32'h0000_1388);
    host_write(PT_SAP+2, 32'd0);         host_write(PT_SAP+3, 32'd1);
    host_write(16'h0008, 32'h051E);
    // 注意：IC 要求同一 VL 的 SN 严格递增，因此 B 段必须按金标帧的 SN 顺序
    // （用例 10..21 对应 SN 0..11）逐条上线，不能跳着发。
    // B1 GET afdxEsUpTime
    drive_case(10); t_grab;
    if (r_err !== 0) bad("B1 on-wire GET failed");
    if (r_rid !== 32'h11223344) bad("B1 on-wire request-id not echoed");
    if (vbg[0] !== 1 || vbl[0] !== 2) bad("B1 on-wire OID wrong");
    if (vbt[0] !== 8'h43) bad("B1 on-wire upTime must be TimeTicks");
    if (vbv[0] !== dut.uptime_cs) badv("B1 upTime differs from the core counter",
                                        vbv[0], dut.uptime_cs);
    host_read(16'hAC14, d);
    if (d[19:12] !== 8'hA0) badv("B1 last PDU type", {24'd0,d[19:12]}, 32'hA0);
    if (d[11:8] !== 4'd1) bad("B1 varbind count in status word");
    host_read(16'hAC1E, d);
    if (d[15:0] !== 16'hC000) badv("B1 SAP source port wrong", d, 32'hC000);
    host_read(16'hAC1F, d);
    if (d !== 32'h0A00_0001) badv("B1 SAP source IP wrong", d, 32'h0A00_0001);
    host_read(16'hAC1D, d);
    if (d[15:0] !== 16'd5000) badv("B1 SAP dest port wrong", d, 32'd5000);
    // B2 GETNEXT 跨组
    drive_case(11); t_grab;
    if (r_err !== 0 || vbg[0] !== 2 || vbl[0] !== 0)
      bad("B2 on-wire GETNEXT must step into STATS_BLOCK");
    // B3 SET / 回读
    drive_case(12); t_grab;
    if (r_err !== 0 || vbv[0] !== 32'h1234) bad("B3 on-wire SET failed");
    drive_case(13); t_grab;
    if (vbv[0] !== 32'h1234) bad("B3 on-wire GET after SET wrong");
    if (dut.snmp_ctl_shadow !== 16'h1234) bad("B3 control shadow not updated");
    // B4 三种错误码
    drive_case(14); t_grab;
    if (r_err !== 2 || r_idx !== 1) badv("B4 on-wire noSuchName wrong", r_err, 2);
    drive_case(15); t_grab;
    if (r_err !== 4) badv("B4 on-wire readOnly wrong", r_err, 4);
    // B5 community 不符：静默丢弃
    host_read(16'hAC18, e);
    drive_case(16);
    host_read(16'hAC1C, d);
    if (d[0] !== 1'b0) bad("B5 bad community must not produce a response");
    host_read(16'hAC18, d);
    if (d !== (e + 32'd1)) badv("B5 drop counter did not advance", d, e+32'd1);
    // B6 STATS_BLOCK 只读组必须直通全局统计页
    drive_case(17); t_grab;
    if (r_err !== 0 || r_nvb !== 2) bad("B6 on-wire STATS_BLOCK GET failed");
    host_read(16'h0104, d);
    if (vbv[0] !== d) badv("B6 STATS_BLOCK word 4 != stats page", vbv[0], d);
    host_read(16'h0107, e);
    if (vbv[1] !== e) badv("B6 STATS_BLOCK word 7 != stats page", vbv[1], e);
    if (d === 32'd0) bad("B6 RX frame counter should be non-zero after real traffic");
    // B7 OCTET STRING / badValue / 多 VarBind / 走到表尾
    drive_case(18); t_grab;
    if (vbt[0] !== 8'h04 || vbn[0] !== 16) bad("B7 on-wire descr encoding wrong");
    for (i = 0; i < 16; i = i + 1)
      if (rb[vbp[0]+i] !== dch(i)) bad("B7 on-wire descr content wrong");
    drive_case(19); t_grab;
    if (r_err !== 3) badv("B7 on-wire badValue wrong", r_err, 3);
    drive_case(20); t_grab;
    if (r_nvb !== 3 || vbv[0] !== 32'd128 || vbv[1] !== 32'd4096)
      bad("B7 on-wire three-varbind GET wrong");
    drive_case(21); t_grab;
    if (r_err !== 2) badv("B7 on-wire GETNEXT past end wrong", r_err, 2);
    // B8 守恒与计数
    if (dut.rx_free_map !== 16'hFFC0) bad("B8 SAP blocks not returned to RX pool");
    host_read(16'hAC10, e); host_read(16'hAC11, d);
    if (d !== e) bad("B8 SAP accept/return counters diverged");
    if (e !== 32'd12) badv("B8 SAP accept count", e, 32'd12);
    host_read(16'hAC16, d);
    if (d !== 32'd12) badv("B8 on-wire rx_pdu_cnt", d, 32'd12);
    host_read(16'hAC17, d);
    if (d !== 32'd11) badv("B8 on-wire resp_cnt", d, 32'd11);
    // B9 核查 20260928 A01 顶层路径：多 VarBind SET 原子性与按序提交
    drive_case(27); t_grab;
    if (r_err !== 4 || r_idx !== 2) badv("B9 atomic SET must return readOnly(4) idx 2", r_err*16+r_idx, 32'h42);
    if (dut.snmp_ctl_shadow !== 16'h1234) badv("B9 rejected SET partially wrote the control shadow",
                                               {16'd0,dut.snmp_ctl_shadow}, 32'h1234);
    drive_case(28); t_grab;
    if (r_err !== 0 || r_nvb !== 2) bad("B9 two-VarBind SET must succeed");
    if (dut.snmp_ctl_shadow !== 16'h0567) badv("B9 ctl not committed", {16'd0,dut.snmp_ctl_shadow}, 32'h0567);
    if (dut.tx_cfg_mem[26][31:8] !== 24'h000321) badv("B9 BAG[5] not committed to tx_cfg_mem",
                                                       {8'd0,dut.tx_cfg_mem[26][31:8]}, 32'h000321);
    if (dut.rx_free_map !== 16'hFFC0) bad("B9 SAP blocks not returned to RX pool");
    host_read(16'hAC16, d);
    if (d !== 32'd14) badv("B9 on-wire rx_pdu_cnt", d, 32'd14);
    host_read(16'hAC17, d);
    if (d !== 32'd13) badv("B9 on-wire resp_cnt", d, 32'd13);
    // B9b BAG 侧原子性：失败 SET 不得写 tx_cfg_mem
    drive_case(29); t_grab;
    if (r_err !== 2 || r_idx !== 2) badv("B9b SET with unknown leaf must return noSuchName(2) idx 2", r_err*16+r_idx, 32'h22);
    if (dut.tx_cfg_mem[26][31:8] !== 24'h000321) badv("B9b rejected SET partially wrote BAG[5]",
                                                       {8'd0,dut.tx_cfg_mem[26][31:8]}, 32'h000321);
    // B10 核查 A02 顶层忙时：响应未取走时连发三个 GET（30 待取、31 暂存、32 整包拒绝并计数）
    host_read(16'hAC18, e);
    drive_case(30); drive_case(31); drive_case(32);
    host_read(16'hAC18, d);
    if (d !== (e + 32'd1)) badv("B10 busy SAP frame not rejected+counted exactly once", d, e+32'd1);
    t_grab;
    if (r_rid !== 32'h88 || r_err !== 0 || vbv[0] !== 32'h0567) badv("B10 first response must be id 0x88 ctl=0x0567", r_rid, 32'h88);
    // 暂存的 31 在 ACK 后才开始解析/组包：轮询响应就绪，不假定固定延迟
    d = 0; waitc = 0;
    while (d[0] !== 1'b1 && waitc < 400) begin
      repeat (50) @(negedge clk); host_read(16'hAC1C, d); waitc = waitc + 1;
    end
    t_grab;
    if (r_rid !== 32'h89 || r_err !== 0) badv("B10 held request must be answered next with id 0x89", r_rid, 32'h89);
    // 被拒的 32 不得在稍后冒出应答
    repeat (4000) @(negedge clk);
    host_read(16'hAC1C, d);
    if (d[0] !== 1'b0) bad("B10 rejected request must not produce a response");
    if (dut.rx_free_map !== 16'hFFC0) bad("B10 SAP blocks not returned to RX pool");
    host_read(16'hAC16, d);
    if (d !== 32'd17) badv("B10 on-wire rx_pdu_cnt", d, 32'd17);
    host_read(16'hAC17, d);
    if (d !== 32'd16) badv("B10 on-wire resp_cnt", d, 32'd16);

    if (errors == 0)
      $display("T15 SNMP PASS (unit: 12 real BER PDUs, GET/GETNEXT/SET, STATS_BLOCK, noSuchName/readOnly/badValue/community-drop, OCTET STRING, multi-varbind; top: 18 on-wire SAP frames, 16 answered, 1 community drop, 1 busy reject counted; atomic CTL/BAG SET + ordered commit)");
    else
      $display("T15 SNMP FAIL (errors=%0d)", errors);
    $finish;
  end
  initial begin
    #300_000_000; $display("T15 SNMP FAIL: timeout"); $finish;
  end
endmodule

module tb_t15_snmp_gmii;
  tb_t15_snmp #(.IF_MODE(1)) u_tb();
endmodule
