// =====================================================================
// tb_t24_mgmt_tx.v — T24/T24g: 管理面响应上线（设计书 v0.5.20 §7.1.1）
//
// 目的：覆盖 §2.6 声明的缺口——SNMP/615A 响应此前只留在观测窗由主机读走，
// 本用例验证开启 CTL[9]（MGMT_TX_EN）后响应真的从 MAC 口发出去：
//
//   注入真实 SNMP GET（复用 t15_mgmt.hex 的黄金向量，含正确 IP/UDP 校验和）
//   -> mgmt_sap_rx 搬载荷 -> snmp_lite 解析 -> §7.1.1 FSM 打包进 PMEM 开放块
//   -> tx_port_buf msg_commit -> BAG 调度 -> builder 封装 -> mac_tx_if -> A/B 口
//
// 判定要点（不是"看到有帧就算过"）：
//   1. 负例 CTL[9]=0 时响应不得上线（回到观测窗行为）；
//   2. 正例固定 GET .1.3（NUM_TX_VL=128），A/B 帧与独立 BER/校验和/FCS 金标逐字节一致；
//   3. 金标同时锁定 UDP sport/dport、peer IP 反转、UDP/IP 长度及 AFDX SN。
//
// 只覆盖"响应上线"这一段；不重复 T15 已覆盖的 BER 边界与响应解码判定。
// =====================================================================
`timescale 1 ns / 1 ps
module tb_t24_mgmt_tx #(parameter integer IF_MODE=0);

  // 与 T15 B 段对齐：已知可收 SAP 的端口号；顶层参数一并覆写，保证
  // sap_to_snmp 与提交端口一致（默认 SNMP_SAP_PORT=6 的 RX 路径另测）。
  localparam integer P_SAP   = 5;
  localparam [15:0]  PT_SAP  = 16'h7D80 + 4*P_SAP;
  localparam [31:0]  W0_VL   = 32'hF500_0000 | (P_SAP<<12) | 32'd700;
  localparam [15:0]  DP_MGMT = 16'd5000;
  localparam [15:0]  SP_PEER = 16'd49152;
  localparam [31:0]  IP_PEER = 32'h0A00_0001;
  localparam integer CASE_NEG = 10;
  localparam integer CASE_TX  = 36;

  localparam [31:0] CTL_BASE = 32'h051F;
  localparam [31:0] CTL_TXON = 32'h071F;

  reg clk=0, reset=1;
  always #4 clk=~clk;

  reg  [7:0]  rx_data=0, rx_data_b=0;
  // rx_ready 兼作 mac_tx_if.link_rdy（见 T22 注释）；默认保持 1，否则 TX FIFO
  // 填满后 builder 永久卡在 ST_EMIT。
  reg        rx_valid=0, rx_ready=1, rx_valid_b=0, rx_ready_b=1;
  wire [7:0] tx_data, tx_data_b;
  wire       tx_valid, tx_ready, tx_valid_b, tx_ready_b;
  reg        host_cs=0, host_we=0;
  reg [15:0] host_addr=0;
  reg [31:0] host_wdata=0;
  wire [31:0] host_rdata;
  wire host_ack;

  AFDX_top #(.IF_MODE(IF_MODE), .FCS_MODE(2),
             .SNMP_SAP_PORT(5), .TFTP_SAP_PORT(9)) dut (
    .rx_error(1'b0), .rx_error_b(1'b0),
    .clk(clk), .reset(reset),
    .tx_data(tx_data), .rx_data(rx_data), .tx_valid(tx_valid), .rx_valid(rx_valid),
    .tx_ready(tx_ready), .rx_ready(rx_ready),
    .tx_data_b(tx_data_b), .tx_valid_b(tx_valid_b), .tx_ready_b(tx_ready_b),
    .rx_data_b(rx_data_b), .rx_valid_b(rx_valid_b), .rx_ready_b(rx_ready_b),
    .host_cs(host_cs), .host_we(host_we), .host_addr(host_addr), .host_wdata(host_wdata),
    .host_rdata(host_rdata), .host_ack(host_ack), .host_irq(),
    .pps_in(1'b0), .pps_out(), .rtc_time_us(), .dbg_frame_event());

  // ---- 黄金向量（与 T15 同源，避免手搓帧的校验和/长度错误）----
  reg [31:0] vec [0:4095];
  reg [31:0] txexp [0:63];
  integer clen [0:63];
  integer cplen[0:63];
  integer cbase[0:63];
  integer exp_len [0:1], exp_base [0:1], exp_pos;
  integer ncase=0, vi2=1, cid, i, b, waitc, errors=0;
  integer na=0, nb=0;
  integer snmp_tx_prev=0;
  reg [7:0] ca [0:511];
  reg [7:0] cb [0:511];
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

  task bad;
    input [8*120-1:0] reason;
    begin
      if (errors < 20) $display("  [err] T24%0d: %0s", IF_MODE, reason);
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

  // ---- 抓 MAC A/B 发出字节 ----
  // IF_MODE=0：有效字节在 valid&&ready；IF_MODE=1(GMII)：帧内 ready=0（忙），只看 valid。
  integer tx_seen=0, sch_seen=0, fb_done_seen=0;
  always @(posedge clk) if (!reset) begin
    if (tx_valid) tx_seen = tx_seen + 1;
    if (dut.sch_start_vld) sch_seen = sch_seen + 1;
    if (dut.fb_done) fb_done_seen = fb_done_seen + 1;
    if (tx_valid && (IF_MODE != 0 || tx_ready)) begin
      if (na < 512) ca[na] = tx_data;
      na = na + 1;
    end
    if (tx_valid_b && (IF_MODE != 0 || tx_ready_b)) begin
      if (nb < 512) cb[nb] = tx_data_b;
      nb = nb + 1;
    end
  end

  // ---- 注入一个黄金用例的 SAP 帧并等引擎产出新响应 ----
  task send_case;
    input integer c;
    integer acc0;
    begin
      acc0 = dut.mgmt_accept_cnt;
      snmp_tx_prev = dut.snmp_cnt_tx;
      for (b = 0; b < clen[c]; b = b + 1) begin
        @(negedge clk); rx_ready=1; rx_valid=1; rx_data=fbyte(c,b);
        if (IF_MODE == 0) begin
          @(negedge clk); rx_valid=0; repeat (8) @(negedge clk);
        end
      end
      // IF_MODE=0：拉低 ready 结束 RX 包络；随后恢复 1，避免卡 TX link_rdy
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
      while (dut.snmp_cnt_tx === snmp_tx_prev && waitc < 4000) begin
        @(negedge clk); waitc = waitc + 1;
      end
      if (waitc >= 4000) bad("snmp engine did not produce a new response");
      repeat (200) @(negedge clk);
    end
  endtask

  // ---- 检查线上抓到的响应帧 ----
  task check_rsp;
    integer j, dpv, spv, shown_a, shown_b;
    reg [31:0] dip;
    begin
      shown_a = 0; shown_b = 0;
      if (na < 50) begin bad("response frame too short"); return; end
      if (na != exp_len[0]) bad("net-A length differs from exact full-frame golden");
      if (nb != exp_len[1]) bad("net-B length differs from exact full-frame golden");
      if (ca[0] !== 8'h03) bad("response DMAC prefix wrong");
      // 大端：UDP sport@34-35，dport@36-37；IP dst@30-33
      spv = {ca[34], ca[35]};
      dpv = {ca[36], ca[37]};
      dip = {ca[30], ca[31], ca[32], ca[33]};
      if (spv !== DP_MGMT) bad("response sport must be SAP management UDP port");
      if (dpv !== SP_PEER) bad("response dp must be reversed peer sport");
      if (dpv === DP_MGMT) bad("response dp must not equal management port");
      if (dip !== IP_PEER) bad("response dst IP must be reversed peer IP");
      for (j = 0; j < exp_len[0] && j < na; j = j + 1)
        if (ca[j] !== expected_byte(0, j)) begin
          if (shown_a < 8) $display("  [diff] net-A byte[%0d] got=%02x want=%02x", j, ca[j], expected_byte(0, j));
          shown_a = shown_a + 1;
          bad("net-A byte differs from full BER/frame golden");
        end
      for (j = 0; j < exp_len[1] && j < nb; j = j + 1)
        if (cb[j] !== expected_byte(1, j)) begin
          if (shown_b < 8) $display("  [diff] net-B byte[%0d] got=%02x want=%02x", j, cb[j], expected_byte(1, j));
          shown_b = shown_b + 1;
          bad("net-B byte differs from full BER/frame golden");
        end
    end
  endtask

  initial begin
    $readmemh("vec/t15_mgmt.hex", vec);
    $readmemh("vec/snmp_tx_expected.hex", txexp);
    exp_pos = 1;
    if (txexp[0] != 2) bad("full-frame SNMP expectation vector missing or malformed");
    for (i = 0; i < 2; i = i + 1) begin
      exp_len[i] = txexp[exp_pos];
      exp_base[i] = exp_pos + 1;
      exp_pos = exp_base[i] + (exp_len[i] + 3) / 4;
    end
    ncase = vec[0];
    if (ncase < 37) begin
      $display("T24 MGMT-TX FAIL (golden vectors missing)");
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

    // ================= 0. 冷启动 + 配置 =================
    repeat (4) @(negedge clk); reset = 0;
    waitc = 0;
    while (dut.init_done !== 1'b1 && waitc < 27000) begin @(negedge clk); waitc = waitc + 1; end
    if (waitc >= 27000) begin
      $display("T24 MGMT-TX FAIL (INIT_DONE timeout)");
      $finish;
    end
    // 配置期必须 CFG_MODE(bit13)=1 且 TX/RX_EN=0，否则 cfg_write 无效
    host_write(16'h0008, 32'h2000);
    // 与 T15 同款：RX 哈希 + SAP 端口 type=2
    host_write(16'h0078, 32'h172D); host_write(16'h007C, 32'hAB61);
    host_write(16'h42B2, 32'h1010_0100); host_write(16'h0080, 32'h1);
    // The frame oracle uses UDI=0x172D and IFIDs A=1/B=2; program SMAC_CFG.
    host_write(16'h0060, 32'h172D_2001);
    host_read(16'h0060, rd);
    if (rd !== 32'h172D_2001) bad("SMAC_CFG readback mismatch");
    host_write(16'h1F80, W0_VL); host_write(16'h1F81, 32'h0000_0100);
    host_write(PT_SAP,   32'h8006_0000); host_write(PT_SAP+1, {16'd0, DP_MGMT});
    host_write(PT_SAP+2, 32'h0000_0000); host_write(PT_SAP+3, 32'h0000_0001);
    // TX VL0：必须写 w4.port_base=P_SAP，否则调度器盯着 port0，永远不 take SAP
    host_write(16'h0204, (P_SAP << 16));           // port_base = SNMP_SAP_PORT
    host_write(16'h0203, 32'h0000_0000);           // dst_ip 占位（实际走 peer 反转）
    host_write(16'h0202, {DP_MGMT, 16'd0});        // dp/sp 占位（实际走 peer 反转）
    host_write(16'h0201, 32'h0000_0A00);           // BAG = 10 us（[31:8]），避免等 1 ms BAG
    host_write(16'h0480, 32'd8305);                // Q20 份额
    host_write(16'h0200, 32'h8050_0003);           // valid, Lmax=1280, net A+B
    host_write(16'h0064, 32'h0A00_0002);           // 本端源 IP（与 T22 同址段）
    // 读回关键配置，确认 CFG 写入生效
    host_read(PT_SAP, rd);
    if (rd !== 32'h8006_0000) bad("SAP port w0 readback mismatch");
    host_read(16'h0200, rd);
    if (rd[31] !== 1'b1) bad("TX VL0 valid not set");
    host_read(16'h0204, rd);
    if (rd[23:16] !== P_SAP[7:0]) bad("TX VL0 port_base mismatch");
    host_read(16'h005C, rd);
    if (rd[1:0] !== 2'b00) begin
      $display("  [diag] cfg_missing/over=%0h", rd);
      bad("cfg_missing or cfg_over blocks TX_EN");
    end

    // ================= 1. 负例：CTL[9]=0 响应不上线 =================
    // 用例 10 = SN0 GET；正例改用用例 11 = SN1，避免 IC 拒收重复 SN。
    host_write(16'h0008, CTL_BASE);                // 退出 CFG_MODE，开 TX/RX/SNMP
    host_read(16'h0008, rd);
    if (rd !== CTL_BASE) begin
      $display("  [diag] CTL readback=%0h want=%0h", rd, CTL_BASE);
      bad("CTL_BASE not accepted");
    end
    send_case(CASE_NEG);
    repeat (600) @(negedge clk);
    if (na > 0) bad("response went on-wire while MGMT_TX_EN=0 (negative case)");
    // 清掉观测窗里挂着的响应，避免开 MGMT_TX_EN 后把负例响应也发出去
    host_write(16'hAC1C, 32'd1);
    repeat (20) @(negedge clk);
    if (dut.snmp_resp_vld !== 1'b0) bad("snmp resp_vld still high after ACK");

    // ================= 2. 正例：开 CTL[9] + SN1 GET 响应上线 =================
    host_write(16'h0008, CTL_TXON);
    host_read(16'h0008, rd);
    if (rd[9] !== 1'b1) bad("CTL MGMT_TX_EN(bit9) not set");
    if (rd[0] !== 1'b1) bad("CTL TX_EN(bit0) not set");
    na = 0; nb = 0;
    send_case(CASE_TX);
    waitc = 0;
    while (na == 0 && waitc < 30000) begin @(negedge clk); waitc = waitc + 1; end
    if (waitc >= 30000) begin
      $display("  [diag] after wait: mt_state=%0d mt_len=%0d resp_vld=%0b pb_req=%0b snmp_tx=%0d macc=%0d",
               dut.mt_state, dut.mt_len, dut.snmp_resp_vld, dut.pb_req[P_SAP],
               dut.snmp_cnt_tx, dut.mgmt_accept_cnt);
      $display("  [diag] tx_seen=%0d sch_seen=%0d fb_done=%0d pb_rej=%0b fb_busy=%0b start_len=%0d fb_st=%0d p1_done=%0b",
               tx_seen, sch_seen, fb_done_seen, dut.pb_rej, dut.fb_busy, dut.sch_start_len,
               dut.u_builder.st, dut.u_builder.p1_done);
      bad("SNMP response frame did not go on-wire");
    end
    // Wait for the MAC envelope to close; an IF_MODE=0 frame with FCS can
    // take more than 800 clocks at BYTE_SLOT_CYC=10.
    waitc = 0;
    if (IF_MODE == 0) begin
      while ((tx_ready || tx_ready_b) && waitc < 4000) begin
        @(negedge clk); waitc = waitc + 1;
      end
    end else begin
      while (!(tx_ready && tx_ready_b) && waitc < 4000) begin
        @(negedge clk); waitc = waitc + 1;
      end
    end
    if (waitc >= 4000) bad("MAC frame envelope did not close");
    repeat (2) @(negedge clk);
    $display("T24 FSM: state=%0d len=%0d port=%0d blk=%0d | wrvld=%0b txen=%0b pb_req=%0b sch_en=%0b na=%0d macc=%0d",
             dut.mt_state, dut.mt_len, dut.mt_sel_port, dut.mt_blk,
             dut.pb_wr_valid, dut.mt_tx_en, dut.pb_req[P_SAP], dut.sch_enable, na,
             dut.mgmt_accept_cnt);
    check_rsp;

    if (errors == 0)
      $display("T24 MGMT-TX PASS (IF_MODE=%0d: negative clean; SNMP GET -> response on-wire; A/B match; dp=%0d sport=%0d; reqid echoed; A2 present)",
               IF_MODE, SP_PEER, DP_MGMT);
    else
      $display("T24 MGMT-TX FAIL (errors=%0d)", errors);
    $finish;
  end
endmodule
