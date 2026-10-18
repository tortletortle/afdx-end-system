// =====================================================================
// tb_t25_mgmt_tftp_tx.v — T25/T25g: TFTP 管理响应上线（设计书 §7.1.1）
//
// T24 已覆盖 SNMP GET → 响应上线；本用例补对等的 615A-TFTP 路径：
//
//   注入真实 WRQ UPLOAD（vec/t15_mgmt.hex case0，含正确 IP/UDP/FCS）
//   -> mgmt_sap_rx -> a615a_tftp -> §7.1.1 FSM -> tx_port_buf
//   -> BAG/builder -> mac_tx_if -> A/B 口
//
// 判定：
//   1. CTL[9]=0 负例：ACK 不得上线（仍走观测窗）；
//   2. CTL[9]=1 正例：A/B 出线且 ifid/FCS 外一致；
//   3. UDP sport=管理口、dport=请求 sport（TID 反转）、dst IP=peer；
//   4. 载荷为 ACK(0)：00 04 00 00。
// =====================================================================
`timescale 1 ns / 1 ps
module tb_t25_mgmt_tftp_tx #(parameter integer IF_MODE=0);

  // 与 T16 C 段对齐：TFTP 占 SAP 端口 5，SNMP 挪开
  localparam integer P_SAP   = 5;
  localparam [15:0]  PT_SAP  = 16'h7D80 + 4*P_SAP;
  localparam [31:0]  W0_VL   = 32'hF500_0000 | (P_SAP<<12) | 32'd700;
  localparam [15:0]  DP_MGMT = 16'd5000;
  localparam [15:0]  SP_PEER = 16'd49152;
  localparam [31:0]  IP_PEER = 32'h0A00_0001;
  localparam integer CASE_WRQ = 0;
  localparam integer CASE_RRQ_UPLOAD = 37;
  localparam integer CASE_UPLOAD_ACK1 = 38;

  localparam [31:0] CTL_BASE = 32'h051F; // TX/RX/IC/RM/SNMP/RTC，MGMT_TX=0
  localparam [31:0] CTL_TXON = 32'h071F; // + CTL[9]

  reg clk=0, reset=1;
  always #4 clk=~clk;

  reg  [7:0]  rx_data=0, rx_data_b=0;
  // rx_ready 兼作 mac_tx_if.link_rdy；默认 1，否则 TX FIFO 满后 builder 卡死
  reg        rx_valid=0, rx_ready=1, rx_valid_b=0, rx_ready_b=1;
  wire [7:0] tx_data, tx_data_b;
  wire       tx_valid, tx_ready, tx_valid_b, tx_ready_b;
  reg        host_cs=0, host_we=0;
  reg [15:0] host_addr=0;
  reg [31:0] host_wdata=0;
  wire [31:0] host_rdata;
  wire host_ack;

  AFDX_top #(.IF_MODE(IF_MODE), .FCS_MODE(2),
             .TFTP_SAP_PORT(P_SAP), .SNMP_SAP_PORT(9),
             .TFTP_TIMEOUT_US(100000)) dut (
    .rx_error(1'b0), .rx_error_b(1'b0),
    .clk(clk), .reset(reset),
    .tx_data(tx_data), .rx_data(rx_data), .tx_valid(tx_valid), .rx_valid(rx_valid),
    .tx_ready(tx_ready), .rx_ready(rx_ready),
    .tx_data_b(tx_data_b), .tx_valid_b(tx_valid_b), .tx_ready_b(tx_ready_b),
    .rx_data_b(rx_data_b), .rx_valid_b(rx_valid_b), .rx_ready_b(rx_ready_b),
    .host_cs(host_cs), .host_we(host_we), .host_addr(host_addr), .host_wdata(host_wdata),
    .host_rdata(host_rdata), .host_ack(host_ack), .host_irq(),
    .pps_in(1'b0), .pps_out(), .rtc_time_us(), .dbg_frame_event());

  reg [31:0] vec [0:4095];
  reg [31:0] txexp [0:127];
  integer clen [0:63];
  integer cplen[0:63];
  integer cbase[0:63];
  integer exp_len [0:5], exp_base [0:5], exp_pos;
  reg [31:0] unload_exp [0:511];
  integer unload_len [0:3], unload_base [0:3], unload_pos;
  reg [31:0] peer_exp [0:511];
  integer peer_len [0:3], peer_base [0:3], peer_pos;
  integer ncase=0, vi2=1, cid, i, b, waitc, errors=0;
  integer peer_count, peer_idx, peer_saw_default, peer_saw_alt;
  integer na=0, nb=0;
  integer tftp_pkt_prev=0;
  reg [7:0] ca [0:1023];
  reg [7:0] cb [0:1023];
  reg [31:0] rd;

  function [7:0] fbyte;
    input integer c; input integer off;
    reg [31:0] q;
    begin
      q = vec[cbase[c] + (off >> 2)];
      case (off & 3)
        0: fbyte = q[31:24]; 1: fbyte = q[23:16];
        2: fbyte = q[15:8];  default: fbyte = q[7:0];
      endcase
    end
  endfunction

  function [7:0] expected_byte;
    input integer frame_idx;
    input integer off;
    reg [31:0] q;
    begin
      q = txexp[exp_base[frame_idx] + (off >> 2)];
      case (off & 3)
        0: expected_byte = q[31:24]; 1: expected_byte = q[23:16];
        2: expected_byte = q[15:8];  default: expected_byte = q[7:0];
      endcase
    end
  endfunction

  function [7:0] unload_expected_byte;
    input integer frame_idx;
    input integer off;
    reg [31:0] q;
    begin
      q = unload_exp[unload_base[frame_idx] + (off >> 2)];
      case (off & 3)
        0: unload_expected_byte = q[31:24]; 1: unload_expected_byte = q[23:16];
        2: unload_expected_byte = q[15:8]; default: unload_expected_byte = q[7:0];
      endcase
    end
  endfunction

  function [7:0] peer_expected_byte;
    input integer frame_idx;
    input integer off;
    reg [31:0] q;
    begin
      q = peer_exp[peer_base[frame_idx] + (off >> 2)];
      case (off & 3)
        0: peer_expected_byte = q[31:24]; 1: peer_expected_byte = q[23:16];
        2: peer_expected_byte = q[15:8]; default: peer_expected_byte = q[7:0];
      endcase
    end
  endfunction

  task bad;
    input [8*120-1:0] reason;
    begin
      if (errors < 20) $display("  [err] T25%0d: %0s", IF_MODE, reason);
      errors = errors + 1;
    end
  endtask

  task host_write;
    input [15:0] a; input [31:0] dd;
    begin
      @(negedge clk); host_cs=1; host_we=1; host_addr=a; host_wdata=dd;
      @(negedge clk);
      if (host_ack !== 1'b1) bad("host write ACK missing");
      host_cs=0; host_we=0;
    end
  endtask

  task host_read;
    input [15:0] a; output [31:0] dd;
    begin
      @(negedge clk); host_cs=1; host_we=0; host_addr=a;
      @(negedge clk);
      if (host_ack !== 1'b1) bad("host read ACK missing");
      dd = host_rdata; host_cs=0;
    end
  endtask

  integer tx_seen=0, sch_seen=0, fb_done_seen=0;
  always @(posedge clk) if (!reset) begin
    if (tx_valid) tx_seen = tx_seen + 1;
    if (dut.sch_start_vld) sch_seen = sch_seen + 1;
    if (dut.fb_done) fb_done_seen = fb_done_seen + 1;
    if (tx_valid && (IF_MODE != 0 || tx_ready)) begin
      if (na < 1024) ca[na] = tx_data;
      na = na + 1;
    end
    if (tx_valid_b && (IF_MODE != 0 || tx_ready_b)) begin
      if (nb < 1024) cb[nb] = tx_data_b;
      nb = nb + 1;
    end
  end

  task send_case;
    input integer c;
    integer acc0;
    begin
      acc0 = dut.mgmt_accept_cnt;
      tftp_pkt_prev = dut.tftp_pkt;
      for (b = 0; b < clen[c]; b = b + 1) begin
        @(negedge clk); rx_ready=1; rx_valid=1; rx_data=fbyte(c,b);
        if (IF_MODE == 0) begin
          @(negedge clk); rx_valid=0; repeat (8) @(negedge clk);
        end
      end
      @(negedge clk); rx_ready=0; rx_valid=0;
      repeat (4) @(negedge clk); rx_ready=1; rx_ready_b=1;
      waitc = 0;
      while (dut.mgmt_accept_cnt <= acc0 && waitc < 20000) begin
        @(negedge clk); waitc = waitc + 1;
      end
      if (waitc >= 20000) bad("SAP endpoint never accepted the frame");
      waitc = 0;
      while (dut.u_mgmt_sap.st !== 2'd0 && waitc < 8000) begin
        @(negedge clk); waitc = waitc + 1;
      end
      if (waitc >= 8000) bad("SAP endpoint never became idle");
      waitc = 0;
      while (dut.tftp_pkt === tftp_pkt_prev && waitc < 4000) begin
        @(negedge clk); waitc = waitc + 1;
      end
      if (waitc >= 4000) bad("tftp engine did not accept a new PDU");
      waitc = 0;
      while (dut.tftp_resp_vld !== 1'b1 && waitc < 4000) begin
        @(negedge clk); waitc = waitc + 1;
      end
      if (waitc >= 4000) bad("tftp engine did not produce a response");
      repeat (200) @(negedge clk);
    end
  endtask

  task check_ack;
    input integer frame_a;
    input integer frame_b;
    input [15:0] block_no;
    integer j, dpv, spv, shown_a, shown_b;
    reg [31:0] dip;
    begin
      shown_a = 0; shown_b = 0;
      if (na < 50) begin bad("response frame too short"); return; end
      if (na != exp_len[frame_a]) bad("net-A length differs from exact full-frame golden");
      if (nb != exp_len[frame_b]) bad("net-B length differs from exact full-frame golden");
      if (ca[0] !== 8'h03) bad("response DMAC prefix wrong");
      spv = {ca[34], ca[35]};
      dpv = {ca[36], ca[37]};
      dip = {ca[30], ca[31], ca[32], ca[33]};
      if (spv !== DP_MGMT) bad("response sport must be SAP management UDP port");
      if (dpv !== SP_PEER) bad("response dp must be reversed peer TID");
      if (dpv === DP_MGMT) bad("response dp must not equal management port");
      if (dip !== IP_PEER) bad("response dst IP must be reversed peer IP");
      if ({ca[38], ca[39]} !== 16'd12) bad("UDP length must be 12 for the 4-byte ACK");
      if ({ca[16], ca[17]} !== 16'd32) bad("IPv4 total length must be 32 for the 4-byte ACK");
      if (ca[42] !== 8'h00 || ca[43] !== 8'h04 ||
          ca[44] !== block_no[15:8] || ca[45] !== block_no[7:0])
        bad("TFTP ACK payload opcode/block differs");
      for (j = 0; j < exp_len[frame_a] && j < na; j = j + 1)
        if (ca[j] !== expected_byte(frame_a, j)) begin
          if (shown_a < 8) $display("  [diff] net-A byte[%0d] got=%02x want=%02x", j, ca[j], expected_byte(frame_a, j));
          shown_a = shown_a + 1;
          bad("net-A byte differs from full-frame golden");
        end
      for (j = 0; j < exp_len[frame_b] && j < nb; j = j + 1)
        if (cb[j] !== expected_byte(frame_b, j)) begin
          if (shown_b < 8) $display("  [diff] net-B byte[%0d] got=%02x want=%02x", j, cb[j], expected_byte(frame_b, j));
          shown_b = shown_b + 1;
          bad("net-B byte differs from full-frame golden");
        end
    end
  endtask

  task check_unload_frame;
    input integer frame_idx;
    integer j, payload_len, udp_len, ip_len, shown_a, shown_b;
    reg [31:0] dip;
    begin
      shown_a = 0; shown_b = 0;
      payload_len = (frame_idx < 2) ? 516 : 12;
      udp_len = payload_len + 8;
      ip_len = payload_len + 28;
      if (na != unload_len[frame_idx]) bad("net-A unload length differs from independent golden");
      if (nb != unload_len[frame_idx+1]) bad("net-B unload length differs from independent golden");
      if (na < 50 || nb < 50) begin bad("unload DATA frame too short"); return; end
      if ({ca[30],ca[31],ca[32],ca[33]} !== IP_PEER) bad("unload dst IP is not the original peer");
      if ({ca[34],ca[35]} !== DP_MGMT || {ca[36],ca[37]} !== SP_PEER)
        bad("unload UDP ports are not management-port / original TID");
      if ({ca[38],ca[39]} !== udp_len[15:0]) bad("unload UDP length differs from DATA payload length");
      if ({ca[16],ca[17]} !== ip_len[15:0]) bad("unload IPv4 length differs from DATA payload length");
      for (j = 0; j < unload_len[frame_idx] && j < na; j = j + 1)
        if (ca[j] !== unload_expected_byte(frame_idx, j)) begin
          if (shown_a < 8) $display("  [diff] unload net-A byte[%0d] got=%02x want=%02x",
                                    j, ca[j], unload_expected_byte(frame_idx, j));
          shown_a = shown_a + 1;
          bad("net-A unload frame differs from full-frame golden");
        end
      for (j = 0; j < unload_len[frame_idx+1] && j < nb; j = j + 1)
        if (cb[j] !== unload_expected_byte(frame_idx+1, j)) begin
          if (shown_b < 8) $display("  [diff] unload net-B byte[%0d] got=%02x want=%02x",
                                    j, cb[j], unload_expected_byte(frame_idx+1, j));
          shown_b = shown_b + 1;
          bad("net-B unload frame differs from full-frame golden");
        end
    end
  endtask

  task check_peer_pair;
    integer j, shown;
    begin
      shown = 0;
      if (na != peer_len[0] + peer_len[2]) bad("peer-isolation net-A frame count/length mismatch");
      if (nb != peer_len[1] + peer_len[3]) bad("peer-isolation net-B frame count/length mismatch");
      for (j = 0; j < peer_len[0] && j < na; j = j + 1)
        if (ca[j] !== peer_expected_byte(0, j)) begin
          if (shown < 8) $display("  [diff] peer net-A first byte[%0d] got=%02x want=%02x", j, ca[j], peer_expected_byte(0,j));
          shown = shown + 1; bad("first peer ACK differs from full-frame golden");
        end
      for (j = 0; j < peer_len[2] && (peer_len[0]+j) < na; j = j + 1)
        if (ca[peer_len[0]+j] !== peer_expected_byte(2, j)) begin
          if (shown < 8) $display("  [diff] peer net-A second byte[%0d] got=%02x want=%02x", j, ca[peer_len[0]+j], peer_expected_byte(2,j));
          shown = shown + 1; bad("second peer ACK differs from full-frame golden");
        end
      for (j = 0; j < peer_len[1] && j < nb; j = j + 1)
        if (cb[j] !== peer_expected_byte(1, j)) begin
          if (shown < 8) $display("  [diff] peer net-B first byte[%0d] got=%02x want=%02x", j, cb[j], peer_expected_byte(1,j));
          shown = shown + 1; bad("first peer ACK differs from full-frame golden");
        end
      for (j = 0; j < peer_len[3] && (peer_len[1]+j) < nb; j = j + 1)
        if (cb[peer_len[1]+j] !== peer_expected_byte(3, j)) begin
          if (shown < 8) $display("  [diff] peer net-B second byte[%0d] got=%02x want=%02x", j, cb[peer_len[1]+j], peer_expected_byte(3,j));
          shown = shown + 1; bad("second peer ACK differs from full-frame golden");
        end
    end
  endtask

  initial begin
    $readmemh("vec/t15_mgmt.hex", vec);
    $readmemh("vec/tftp_tx_expected.hex", txexp);
    $readmemh("vec/tftp_unload_expected.hex", unload_exp);
    $readmemh("vec/tftp_peer_expected.hex", peer_exp);
    exp_pos = 1;
    if (txexp[0] != 6) bad("full-frame TFTP ACK expectation vector missing or malformed");
    for (i = 0; i < 6; i = i + 1) begin
      exp_len[i] = txexp[exp_pos];
      exp_base[i] = exp_pos + 1;
      exp_pos = exp_base[i] + (exp_len[i] + 3) / 4;
    end
    unload_pos = 1;
    if (unload_exp[0] != 4) bad("full-frame TFTP unload expectation vector missing or malformed");
    for (i = 0; i < 4; i = i + 1) begin
      unload_len[i] = unload_exp[unload_pos];
      unload_base[i] = unload_pos + 1;
      unload_pos = unload_base[i] + (unload_len[i] + 3) / 4;
    end
    peer_pos = 1;
    if (peer_exp[0] != 4) bad("full-frame TFTP peer-isolation expectations missing or malformed");
    for (i = 0; i < 4; i = i + 1) begin
      peer_len[i] = peer_exp[peer_pos];
      peer_base[i] = peer_pos + 1;
      peer_pos = peer_base[i] + (peer_len[i] + 3) / 4;
    end
    ncase = vec[0];
    if (ncase < 1) begin
      $display("T25 MGMT-TFTP-TX FAIL (golden vectors missing)");
      $finish;
    end
    vi2 = 1;
    for (i = 0; i < ncase; i = i + 1) begin
      cid = vec[vi2][31:24];
      clen[cid]  = vec[vi2][15:0];
      cplen[cid] = vec[vi2+1];
      cbase[cid] = vi2 + 3;
      vi2 = vi2 + 3 + (vec[vi2][15:0] + 3) / 4;
    end
    if (clen[CASE_WRQ] < 50) begin
      $display("T25 MGMT-TFTP-TX FAIL (WRQ case0 missing)");
      $finish;
    end

    // ================= 0. 冷启动 + 配置 =================
    repeat (4) @(negedge clk); reset = 0;
    waitc = 0;
    while (dut.init_done !== 1'b1 && waitc < 27000) begin @(negedge clk); waitc = waitc + 1; end
    if (waitc >= 27000) begin
      $display("T25 MGMT-TFTP-TX FAIL (INIT_DONE timeout)");
      $finish;
    end
    host_write(16'h0008, 32'h2000); // CFG_MODE
    host_write(16'h0078, 32'h172D); host_write(16'h007C, 32'hAB61);
    host_write(16'h42B2, 32'h1010_0100); host_write(16'h0080, 32'h1);
    host_write(16'h0060, 32'h172D_2001);
    host_read(16'h0060, rd);
    if (rd !== 32'h172D_2001) bad("SMAC_CFG readback mismatch");
    host_write(16'h1F80, W0_VL); host_write(16'h1F81, 32'h0000_0100);
    host_write(PT_SAP,   32'h8006_0000); host_write(PT_SAP+1, {16'd0, DP_MGMT});
    host_write(PT_SAP+2, 32'h0000_0000); host_write(PT_SAP+3, 32'h0000_0001);
    host_write(16'h0204, (P_SAP << 16));
    host_write(16'h0203, 32'h0000_0000);
    host_write(16'h0202, {DP_MGMT, 16'd0});
    host_write(16'h0201, 32'h0000_0A00); // BAG=10 us
    host_write(16'h0480, 32'd8305);
    host_write(16'h0200, 32'h8050_0003);
    host_write(16'h0064, 32'h0A00_0002);
    host_read(PT_SAP, rd);
    if (rd !== 32'h8006_0000) bad("SAP port w0 readback mismatch");
    host_read(16'h0204, rd);
    if (rd[23:16] !== P_SAP[7:0]) bad("TX VL0 port_base mismatch");
    host_read(16'h005C, rd);
    if (rd[1:0] !== 2'b00) begin
      $display("  [diag] cfg_missing/over=%0h", rd);
      bad("cfg_missing or cfg_over blocks TX_EN");
    end

    // ================= 1. 负例：CTL[9]=0 =================
    host_write(16'h0008, CTL_BASE);
    host_read(16'h0008, rd);
    if (rd !== CTL_BASE) begin
      $display("  [diag] CTL readback=%0h want=%0h", rd, CTL_BASE);
      bad("CTL_BASE not accepted");
    end
    send_case(CASE_WRQ);
    repeat (600) @(negedge clk);
    if (na > 0) bad("TFTP ACK went on-wire while MGMT_TX_EN=0 (negative case)");
    host_write(16'hAC28, 32'd1); // 清观测窗响应，避免正例把负例 ACK 发出
    repeat (20) @(negedge clk);
    if (dut.tftp_resp_vld !== 1'b0) bad("tftp resp_vld still high after ACK");

    // ================= 2. 正例：CTL[9]=1 + 再发 WRQ =================
    // 会话已因负例 WRQ 建立；再发同 TID 的 WRQ 会被拒。先复位引擎：
    // 关掉再开 TX_EN 不够；写 CTL 保留位外，靠重新冷启动代价大。
    // 用新 sport 的等价帧不方便（黄金向量固定）。改为在正例前复位 DUT
    // 并重配——但 init_sweep 太慢。更干净：正例复用负例后已清响应、
    // 再发 DATA 会走已有会话；我们直接再发 WRQ 前先把引擎会话清掉。
    // a615a_tftp 无主机强制复位口；对整机 soft-reset 过大。
    // 实操：负例只用观测窗确认引擎活着，正例前完整复位重跑配置。
    reset = 1; na = 0; nb = 0; tx_seen = 0; sch_seen = 0; fb_done_seen = 0;
    repeat (8) @(negedge clk); reset = 0;
    waitc = 0;
    while (dut.init_done !== 1'b1 && waitc < 27000) begin @(negedge clk); waitc = waitc + 1; end
    if (waitc >= 27000) begin
      $display("T25 MGMT-TFTP-TX FAIL (re-INIT_DONE timeout)");
      $finish;
    end
    host_write(16'h0008, 32'h2000);
    host_write(16'h0078, 32'h172D); host_write(16'h007C, 32'hAB61);
    host_write(16'h42B2, 32'h1010_0100); host_write(16'h0080, 32'h1);
    host_write(16'h0060, 32'h172D_2001);
    host_read(16'h0060, rd);
    if (rd !== 32'h172D_2001) bad("SMAC_CFG readback mismatch");
    host_write(16'h1F80, W0_VL); host_write(16'h1F81, 32'h0000_0100);
    host_write(PT_SAP,   32'h8006_0000); host_write(PT_SAP+1, {16'd0, DP_MGMT});
    host_write(PT_SAP+2, 32'h0000_0000); host_write(PT_SAP+3, 32'h0000_0001);
    host_write(16'h0204, (P_SAP << 16));
    host_write(16'h0203, 32'h0000_0000);
    host_write(16'h0202, {DP_MGMT, 16'd0});
    host_write(16'h0201, 32'h0000_0A00);
    host_write(16'h0480, 32'd8305);
    host_write(16'h0200, 32'h8050_0003);
    host_write(16'h0064, 32'h0A00_0002);
    host_write(16'h0008, CTL_TXON);
    host_read(16'h0008, rd);
    if (rd[9] !== 1'b1) bad("CTL MGMT_TX_EN(bit9) not set");
    if (rd[0] !== 1'b1) bad("CTL TX_EN(bit0) not set");
    na = 0; nb = 0;
    send_case(CASE_WRQ);
    waitc = 0;
    while (na == 0 && waitc < 30000) begin @(negedge clk); waitc = waitc + 1; end
    if (waitc >= 30000) begin
      $display("  [diag] mt_state=%0d mt_len=%0d resp_vld=%0b pb_req=%0b tftp_pkt=%0d macc=%0d",
               dut.mt_state, dut.mt_len, dut.tftp_resp_vld, dut.pb_req[P_SAP],
               dut.tftp_pkt, dut.mgmt_accept_cnt);
      $display("  [diag] tx_seen=%0d sch_seen=%0d fb_done=%0d pb_rej=%0b fb_busy=%0b start_len=%0d",
               tx_seen, sch_seen, fb_done_seen, dut.pb_rej, dut.fb_busy, dut.sch_start_len);
      bad("TFTP ACK frame did not go on-wire");
    end
    repeat (800) @(negedge clk);
    $display("T25 FSM: state=%0d len=%0d port=%0d blk=%0d | wrvld=%0b txen=%0b pb_req=%0b na=%0d macc=%0d",
             dut.mt_state, dut.mt_len, dut.mt_sel_port, dut.mt_blk,
             dut.pb_wr_valid, dut.mt_tx_en, dut.pb_req[P_SAP], na,
             dut.mgmt_accept_cnt);
    check_ack(0, 1, 16'd0);

    // Load both test blocks over RX, then verify the top-level synchronous
    // unload RAM and management TX byte pump against independent full frames.
    na = 0; nb = 0;
    send_case(1); // DATA(1), 512 B -> ACK(1)
    waitc = 0;
    while (na < 50 && waitc < 30000) begin @(negedge clk); waitc = waitc + 1; end
    if (waitc >= 30000) bad("TFTP ACK(1) after DATA(1) did not go on-wire");
    repeat (800) @(negedge clk);
    check_ack(2, 3, 16'd1);

    na = 0; nb = 0;
    send_case(2); // DATA(2), 8 B -> ACK(2), completes the loaded image
    waitc = 0;
    while (na < 50 && waitc < 30000) begin @(negedge clk); waitc = waitc + 1; end
    if (waitc >= 30000) bad("TFTP ACK(2) after DATA(2) did not go on-wire");
    repeat (800) @(negedge clk);
    check_ack(4, 5, 16'd2);

    na = 0; nb = 0;
    send_case(CASE_RRQ_UPLOAD); // DATA(1), full 512-byte image block
    waitc = 0;
    while (na < unload_len[0] && waitc < 30000) begin @(negedge clk); waitc = waitc + 1; end
    if (waitc >= 30000) bad("RRQ UPLOAD DATA(1) did not go on-wire");
    repeat (800) @(negedge clk);
    check_unload_frame(0);

    na = 0; nb = 0;
    send_case(CASE_UPLOAD_ACK1); // ACK(1) -> DATA(2), 8-byte final slice
    waitc = 0;
    while (na < unload_len[2] && waitc < 30000) begin @(negedge clk); waitc = waitc + 1; end
    if (waitc >= 30000) bad("RRQ UPLOAD DATA(2) tail did not go on-wire");
    repeat (800) @(negedge clk);
    check_unload_frame(2);

    // Two requests arrive from different peers while TX_EN is low. Management
    // TX still commits each response; the scheduler remains paused so both
    // descriptors and their per-block peer metadata coexist before either
    // frame launches. Re-enable TX and compare all four A/B frames exactly.
    reset = 1; na = 0; nb = 0; tx_seen = 0; sch_seen = 0; fb_done_seen = 0;
    repeat (8) @(negedge clk); reset = 0;
    waitc = 0;
    while (dut.init_done !== 1'b1 && waitc < 27000) begin @(negedge clk); waitc = waitc + 1; end
    if (waitc >= 27000) bad("peer-isolation re-INIT_DONE timeout");
    host_write(16'h0008, 32'h2000);
    host_write(16'h0078, 32'h172D); host_write(16'h007C, 32'hAB61);
    host_write(16'h42B2, 32'h1010_0100); host_write(16'h0080, 32'h1);
    host_write(16'h0060, 32'h172D_2001);
    host_write(16'h1F80, W0_VL); host_write(16'h1F81, 32'h0000_0100);
    host_write(PT_SAP, 32'h8006_0000); host_write(PT_SAP+1, {16'd0, DP_MGMT});
    host_write(PT_SAP+2, 32'h0000_0000); host_write(PT_SAP+3, 32'h0000_0001);
    host_write(16'h0204, (P_SAP << 16)); host_write(16'h0203, 32'h0000_0000);
    host_write(16'h0202, {DP_MGMT, 16'd0}); host_write(16'h0201, 32'h0000_0A00);
    host_write(16'h0480, 32'd8305); host_write(16'h0200, 32'h8050_0003);
    host_write(16'h0064, 32'h0A00_0002);
    host_write(16'h0008, 32'h071E); // MGMT_TX_EN=1, TX_EN=0
    na = 0; nb = 0;
    send_case(CASE_WRQ);
    send_case(39);
    waitc = 0;
    peer_count = 0; peer_saw_default = 0; peer_saw_alt = 0;
    while (peer_count < 2 && waitc < 30000) begin
      @(negedge clk); waitc = waitc + 1;
      peer_count = 0;
      for (peer_idx = 0; peer_idx < 16; peer_idx = peer_idx + 1)
        if (dut.mgmt_meta_valid[peer_idx]) peer_count = peer_count + 1;
    end
    if (peer_count != 2) bad("two queued management peer metadata slots were not committed");
    for (peer_idx = 0; peer_idx < 16; peer_idx = peer_idx + 1) begin
      if (dut.mgmt_meta_valid[peer_idx]) begin
        if (dut.mgmt_meta_ip[peer_idx] == 32'h0A00_0001 && dut.mgmt_meta_port[peer_idx] == 16'd49152)
          peer_saw_default = peer_saw_default + 1;
        else if (dut.mgmt_meta_ip[peer_idx] == 32'h0A00_0063 && dut.mgmt_meta_port[peer_idx] == 16'd40000)
          peer_saw_alt = peer_saw_alt + 1;
        else bad("queued peer metadata contains an unexpected IP/TID");
      end
    end
    if (peer_saw_default != 1 || peer_saw_alt != 1)
      bad("queued responses did not retain one original peer each");
    if (na != 0 || nb != 0) bad("TX scheduler launched while TX_EN was disabled");
    host_write(16'h0008, CTL_TXON);
    waitc = 0;
    while ((na < peer_len[0] + peer_len[2] || nb < peer_len[1] + peer_len[3]) && waitc < 30000) begin
      @(negedge clk); waitc = waitc + 1;
    end
    if (waitc >= 30000) bad("queued peer responses did not go on-wire after TX_EN");
    repeat (800) @(negedge clk);
    check_peer_pair();

    if (errors == 0)
      $display("T25 MGMT-TFTP-TX PASS (IF_MODE=%0d: ACK/DATA/unload full frames; queued peer metadata isolation; A/B full-frame match)",
               IF_MODE);
    else
      $display("T25 MGMT-TFTP-TX FAIL (errors=%0d)", errors);
    $finish;
  end
endmodule
