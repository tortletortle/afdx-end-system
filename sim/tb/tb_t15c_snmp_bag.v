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
module tb_t15c_snmp_bag #(parameter integer IF_MODE = 0);
  localparam integer VEC_LAST=192;
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

  // ================= B：顶层 =================
  reg reset = 1'b1;
  reg [7:0] rx_data = 0, rx_data_b = 0;
  reg rx_valid = 0, rx_valid_b = 0, rx_ready = 0, rx_ready_b = 0;
  reg host_cs = 0, host_we = 0;
  reg [15:0] host_addr = 0;
  reg [31:0] host_wdata = 0;
  wire [31:0] host_rdata;
  wire host_ack;
  wire [7:0] tx_data; wire tx_valid, tx_ready;
  wire [7:0] tx_data_b; wire tx_valid_b, tx_ready_b;
  AFDX_top #(.NUM_RX_VL(512), .NUM_PORTS(16), .IF_MODE(IF_MODE), .FCS_MODE(2), .SNMP_SAP_PORT(5), .TFTP_SAP_PORT(9)) dut (
    .rx_error(1'b0), .rx_error_b(1'b0),
    .clk(clk), .reset(reset), .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready),
    .rx_data(rx_data), .rx_valid(rx_valid), .rx_ready(rx_ready),
    .tx_data_b(tx_data_b), .tx_valid_b(tx_valid_b), .tx_ready_b(tx_ready_b),
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
  task drive_case_quick; input integer cc; integer acc, wc;
    begin
      acc=dut.mgmt_accept_cnt;
      for(b=0;b<clen[cc];b=b+1)begin
        @(negedge clk);rx_ready=1;rx_valid=1;rx_data=fbyte(cc,b);
        if(IF_MODE==0)begin @(negedge clk);rx_valid=0;repeat(8)@(negedge clk);end
      end
      @(negedge clk);rx_ready=0;rx_valid=0;
      wc=0;while(dut.mgmt_accept_cnt<=acc && wc<20000)begin @(negedge clk);wc=wc+1;end
      if(wc>=20000)bad("quick SAP endpoint never accepted frame");
      wc=0;while(dut.u_mgmt_sap.st!==2'd0 && wc<8000)begin @(negedge clk);wc=wc+1;end
      if(wc>=8000)bad("quick SAP endpoint stalled");
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


  localparam integer P_TX=1, V_TX=3;
  localparam [15:0] TXBASE=16'h0200+5*V_TX;
  localparam [31:0] TXW0=32'h8000_0001;
  integer wire_n=0, was_open=0, n0, c, before_ctl_writes;
  integer wire_b_n=0, b_was_open=0, bn0;
  time bstarts[0:31], b_gap_ns;
  integer ctl_writes=0, cfg_findings=0, trunc_findings=0;
  integer bag_commits=0, commits0, host_wait_cycles;
  reg [6:0] committed_vl;
  reg [9:0] committed_addr;
  reg [23:0] committed_bag;
  always @(posedge clk) if(!reset && dut.snmp_bag_commit)begin
    bag_commits=bag_commits+1;
    committed_vl=dut.snmp_bag_vl_q;committed_addr=dut.snmp_bag_addr_q;
    committed_bag=dut.snmp_bag_wdata_q;
    #1;
    if(dut.u_txcfg_h1.mem[committed_vl][31:8]!==committed_bag ||
       dut.u_sched.bag_arr[committed_vl] !== (committed_bag * 125))
      bad("table/scheduler did not commit the same BAG on the same edge");
  end
  time starts[0:31];
  time gap_ns;
  always @(negedge clk) begin
    if (reset) begin was_open=0; b_was_open=0; end
    else if (IF_MODE == 0) begin
      if(!tx_ready)was_open=0;
      if(tx_ready && tx_valid && !was_open)begin
        if(wire_n<32)starts[wire_n]=$time;
        wire_n=wire_n+1;was_open=1;
      end
      if(!tx_ready_b)b_was_open=0;
      if(tx_ready_b && tx_valid_b && !b_was_open)begin
        if(wire_b_n<32)bstarts[wire_b_n]=$time;
        wire_b_n=wire_b_n+1;b_was_open=1;
      end
    end else begin
      if(!tx_valid_b)b_was_open=0;
      else if(!b_was_open)begin
        if(wire_b_n<32)bstarts[wire_b_n]=$time;
        wire_b_n=wire_b_n+1;b_was_open=1;
      end
      if(!tx_valid)was_open=0;
      else if(!was_open)begin
        if(wire_n<32)starts[wire_n]=$time;
        wire_n=wire_n+1;was_open=1;
      end
    end
  end
  always @(posedge clk)if(!reset && dut.snmp_ctl_we)ctl_writes=ctl_writes+1;

  task queue_msg;
    reg [31:0] x;
    reg [15:0] base;
    integer j;
    begin
      host_read(16'h0074,x);
      if(x[4]!==1'b1)bad("no TX open block for positive control");
      base=16'h8800+{x[3:0],9'd0};
      for(j=0;j<5;j=j+1)host_write(base+j,32'h1122_3344+j);
      host_write(16'h8280+P_TX,17);
      repeat(5)@(negedge clk);
    end
  endtask
  task two_wire_frames;
    input integer expected_min_us;
    input integer is_diagnostic;
    begin
      n0=wire_n;rx_ready=1;
      queue_msg;queue_msg;
      c=0;
      while(wire_n<n0+2 && c<600000)begin @(negedge clk);c=c+1;end
      if(wire_n<n0+2)bad("wire-frame positive control timeout");
      else begin
        gap_ns=starts[n0+1]-starts[n0];
        if(is_diagnostic)begin
          if(gap_ns<expected_min_us*1000)begin
            cfg_findings=cfg_findings+1;bad("SNMP BAG did not reach wire scheduler");
            $display("DIAG BAG_WIRE FAIL if_mode=%0d requested_bag_us=%0d observed_start_gap_ns=%0d cfg_bag_us=%0d scheduler_bag_cycles=%0d",IF_MODE,expected_min_us,gap_ns,dut.u_txcfg_h1.mem[V_TX][31:8],dut.u_sched.bag_arr[V_TX]);
          end else $display("DIAG BAG_WIRE PASS if_mode=%0d gap_ns=%0d",IF_MODE,gap_ns);
        end else begin
          if(gap_ns<expected_min_us*1000 || gap_ns>(expected_min_us+50)*1000)bad("wire BAG positive control out of bounds");
          $display("DIAG CONTROL_WIRE if_mode=%0d configured_bag_us=%0d gap_ns=%0d errors=%0d",IF_MODE,expected_min_us,gap_ns,errors);
        end
      end
      c=0;
      while((dut.mac_a_busy || dut.fb_busy) && c<30000)begin @(negedge clk);c=c+1;end
      repeat(30)@(negedge clk);
    end
  endtask

  initial begin
    $readmemh("vec/t15c_mgmt.hex",vec,0,VEC_LAST);
    ncase=vec[0];vi2=1;
    for(i=0;i<ncase;i=i+1)begin
      cid=vec[vi2][31:24];clen[cid]=vec[vi2][15:0];cplen[cid]=vec[vi2+1];cbase[cid]=vi2+3;
      vi2=vi2+3+(vec[vi2][15:0]+3)/4;
    end
    repeat(7)@(negedge clk);reset=0;
    waitc=0;
    while(dut.init_done!==1'b1 && waitc<30000)begin @(negedge clk);waitc=waitc+1;end
    if(dut.init_done!==1'b1)bad("initialization control timeout");
    host_write(16'h0008,32'h2000);
    host_write(16'h0060,32'h1234_2001);
    host_write(16'h0064,32'h0A00_0001);
    host_write(16'h0078,32'h172D);host_write(16'h007C,32'hAB61);
    host_write(16'h42B2,32'h1010_0100);host_write(16'h0080,1);
    host_write(16'h1F80,W0_VL);host_write(16'h1F81,32'h0000_0100);
    host_write(PT_SAP,32'h8006_0000);host_write(PT_SAP+1,5000);
    host_write(PT_SAP+2,0);host_write(PT_SAP+3,1);
    host_write(16'h7D80+4*P_TX,32'h8001_0000);
    host_write(16'h7D80+4*P_TX+1,5001);
    host_write(16'h7D80+4*P_TX+2,0);
    host_write(16'h7D80+4*P_TX+3,4);
    host_write(TXBASE+1,1000<<8);host_write(TXBASE+2,32'h1389_C000);
    host_write(TXBASE+3,32'hE000_0001);host_write(TXBASE+4,P_TX<<16);
    host_write(16'h0480+V_TX,7047);host_write(TXBASE,TXW0);
    repeat(8)@(negedge clk);
    if(dut.u_sched.bag_arr[V_TX]!==31'd125000)bad("host configuration did not reach scheduler");
    host_write(16'h0008,32'h051F);
    two_wire_frames(1000,0);
    host_write(16'h0008,32'h051E);
    drive_case(0);t_grab;
    if(r_err!==0 || vbv[0]!==1000)bad("on-wire baseline GET BAG control failed");
    $display("DIAG CONTROL_GET_BAG if_mode=%0d value=%0d error=%0d errors=%0d",IF_MODE,vbv[0],r_err,errors);
    drive_case(1);t_grab;
    if(r_err!==0 || vbv[0]!==2000)bad("on-wire SET BAG acceptance control failed");
    host_read(TXBASE+1,d);
    $display("DIAG BAG_STATE if_mode=%0d response_error=%0d set_echo=%0d host_table_bag_us=%0d scheduler_bag_cycles=%0d cfg_sum_q20=%0d",IF_MODE,r_err,vbv[0],d[31:8],dut.u_sched.bag_arr[V_TX],dut.cfg_sum_r);
    if(d[31:8]!==24'd2000)bad("SET did not update top table control");
    host_write(16'h0008,32'h051F);
    two_wire_frames(2000,1);
    // The unchanged host path is a positive control for the same new BAG.
    host_write(16'h0008,32'h2000);host_write(TXBASE,TXW0);
    repeat(8)@(negedge clk);
    host_write(16'h0008,32'h051F);
    two_wire_frames(2000,0);
    host_write(16'h0008,32'h051E);
    // Fully valid SET seeds the request buffer. The next packet has valid
    // ETH/IP/UDP/FCS but its BER INTEGER is cut one byte short.
    drive_case(2);t_grab;
    if(r_err!==0 || dut.snmp_ctl_shadow!==16'h1234)bad("warm top SET control failed");
    before_ctl_writes=ctl_writes;
    drive_case(3);host_read(16'hAC1C,d);
    if(d[0] === 1'b1)t_grab;else begin r_err=-1;rlen=0;end
    if(ctl_writes!=before_ctl_writes || dut.snmp_ctl_shadow!==16'h1234 || r_err==0)begin
      trunc_findings=trunc_findings+1;bad("truncated BER performed SET or returned success");
      $display("DIAG TOP_TRUNCATED_SET FAIL if_mode=%0d received_payload_bytes=%0d control_before=1234 control_after=%04h response_error=%0d write_delta=%0d snmp_drops=%0d",IF_MODE,cplen[3],dut.snmp_ctl_shadow,r_err,ctl_writes-before_ctl_writes,dut.snmp_cnt_drop);
    end else $display("DIAG TOP_TRUNCATED_SET PASS if_mode=%0d",IF_MODE);
    // Decreasing back to the originally reserved BAG must also update both copies.
    drive_case(4);t_grab;
    if(r_err!==0 || vbv[0]!==1000 || dut.u_sched.bag_arr[V_TX]!==31'd125000)
      bad("decreasing BAG did not commit");
    host_write(16'h0008,32'h051F);two_wire_frames(1000,1);
    host_write(16'h0008,32'h051E);
    // Mixed multi-object SET: no dropped pulses and repeated BAG writes are ordered.
    commits0=bag_commits;drive_case(5);t_grab;
    if(r_err!==0 || r_nvb!==3 || bag_commits!==commits0+2 ||
       dut.u_sched.bag_arr[V_TX]!==31'd250000 || dut.u_txcfg_h1.mem[V_TX][31:8]!==2000 ||
       dut.snmp_ctl_shadow!==16'h3456)bad("mixed SET ordered/acknowledged commit");
    host_write(16'h0008,32'h051F);two_wire_frames(2000,1);
    host_write(16'h0008,32'h2000);host_write(TXBASE,32'h8000_0002); // B-only
    repeat(8)@(negedge clk);rx_ready=0;rx_ready_b=0;host_write(16'h0008,32'h051F);
    queue_msg;queue_msg;
    c=0;while(!dut.u_sched.ifq_nonempty && c<4000)begin @(negedge clk);c=c+1;end
    if(!dut.u_sched.ifq_nonempty)bad("link-down in-flight fixture never granted a frame");
    commits0=bag_commits;drive_case_quick(6);
    c=0;while(!dut.snmp_set_active && c<2000)begin @(negedge clk);c=c+1;end
    if(!dut.snmp_set_active)bad("in-flight BAG SET did not acquire configuration lock");
    // Present a real host CTL write while BAG validation/commit is active.
    // It must wait for the accepted BAG commit, not for a link-down frame.
    @(negedge clk);host_cs=1;host_we=1;host_addr=16'h0008;host_wdata=32'h051F;
    host_wait_cycles=0;
    while(host_ack!==1'b1 && host_wait_cycles<2000)begin @(negedge clk);host_wait_cycles=host_wait_cycles+1;end
    if(host_ack!==1'b1 || host_wait_cycles==0)bad("host configuration was not held until BAG commit");
    host_cs=0;host_we=0;
    c=0;while(!dut.snmp_resp_vld && c<3000)begin @(negedge clk);c=c+1;end
    if(!dut.snmp_resp_vld)bad("BAG SET response missing while B link-down");
    t_grab;
    if(r_err!==0 || vbv[0]!==1000 || bag_commits!==commits0+1 ||
       dut.u_sched.bag_arr[V_TX]!==31'd125000 || dut.u_txcfg_h1.mem[V_TX][31:8]!==1000 ||
       !dut.u_sched.ifq_nonempty)
      bad("link-down atomic BAG commit or retained in-flight frame");
    // The old, already-granted frame starts after link recovery; the queued
    // successor must then obey the BAG committed during link-down.
    bn0=wire_b_n;rx_ready_b=1;c=0;
    while(wire_b_n<bn0+2 && c<600000)begin @(negedge clk);c=c+1;end
    if(wire_b_n<bn0+2)bad("B link-up frame pair timeout after BAG commit");
    else begin
      b_gap_ns=bstarts[bn0+1]-bstarts[bn0];
      if(b_gap_ns<1000000 || b_gap_ns>1050000)begin
        cfg_findings=cfg_findings+1;bad("in-flight B frames violated newly committed BAG");
      end
      $display("T15cBAGINFLIGHT if_mode=%0d frame_gap_ns=%0d commits=%0d host_wait_cycles=%0d",IF_MODE,b_gap_ns,bag_commits,host_wait_cycles);
    end
    $display("T15cMETRIC if_mode=%0d bag_commits=%0d held_host_wait_cycles=%0d wire_frames_A=%0d",IF_MODE,bag_commits,host_wait_cycles,wire_n);
    if(errors==0)begin
      if(IF_MODE==0)$display("T15c SNMP BAG PASS (wire increase/decrease, table-cache same-edge commit, mixed repeated SET, truncated BER, link-down in-flight commit, host-write arbitration)");
      else $display("T15cg SNMP BAG PASS (wire increase/decrease, table-cache same-edge commit, mixed repeated SET, truncated BER, link-down in-flight commit, host-write arbitration)");
    end else begin
      if(IF_MODE==0)$display("T15c SNMP BAG FAIL (errors=%0d)",errors);
      else $display("T15cg SNMP BAG FAIL (errors=%0d)",errors);
      $fatal(1,"T15c failure");
    end
    $finish;
  end
  initial begin #30000000;$fatal(1,"top diagnostic watchdog");end
endmodule

module tb_t15cg_snmp_bag;
  tb_t15c_snmp_bag #(.IF_MODE(1)) u();
endmodule
