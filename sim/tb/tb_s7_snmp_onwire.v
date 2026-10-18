// T31 / S7 — SNMP GET / GETNEXT / SET on the wire through net_model.
// Requests are injected as switch-to-ES frames (10 us store-and-forward).
// DUT TX is not looped back. Does not replace T15 BER or T24 GET-only oracles.
`timescale 1 ns / 1 ps
module tb_s7_snmp_onwire_core #(parameter integer IF_MODE = 0);
  localparam integer DELAY_US = 10;
  localparam integer P_SAP = 5;
  localparam [15:0]  PT_SAP = 16'h7D80 + 4*P_SAP;
  localparam [31:0]  W0_VL = 32'hF500_0000 | (P_SAP << 12) | 32'd700;
  localparam [15:0]  DP_MGMT = 16'd5000;
  localparam [15:0]  SP_PEER = 16'd49152;
  localparam [31:0]  IP_PEER = 32'h0A00_0001;
  localparam [31:0]  CTL_TXON = 32'h071F;

  reg clk = 0, reset = 1;
  always #4 clk = ~clk;

  wire        host_cs, host_we;
  wire [15:0] host_addr;
  wire [31:0] host_wdata;
  wire [31:0] host_rdata;
  wire        host_ack;
  wire [7:0] tx_data, tx_data_b, rx_data, rx_data_b;
  wire       tx_valid, tx_valid_b, tx_ready, tx_ready_b;
  wire       rx_valid, rx_valid_b, rx_ready, rx_ready_b;
  wire [31:0] fwd_a, fwd_b;

  AFDX_top #(.IF_MODE(IF_MODE), .FCS_MODE(2),
             .SNMP_SAP_PORT(P_SAP), .TFTP_SAP_PORT(9)) dut (
    .rx_error(1'b0), .rx_error_b(1'b0),
    .clk(clk), .reset(reset),
    .tx_data(tx_data), .rx_data(rx_data),
    .tx_valid(tx_valid), .rx_valid(rx_valid),
    .tx_ready(tx_ready), .rx_ready(rx_ready),
    .tx_data_b(tx_data_b), .tx_valid_b(tx_valid_b), .tx_ready_b(tx_ready_b),
    .rx_data_b(rx_data_b), .rx_valid_b(rx_valid_b), .rx_ready_b(rx_ready_b),
    .host_cs(host_cs), .host_we(host_we), .host_addr(host_addr),
    .host_wdata(host_wdata), .host_rdata(host_rdata), .host_ack(host_ack),
    .host_irq(),
    .pps_in(1'b0), .pps_out(), .rtc_time_us(), .dbg_frame_event());

  afdx_host_bfm u_host (
    .clk(clk), .cs(host_cs), .we(host_we), .addr(host_addr), .wdata(host_wdata),
    .rdata(host_rdata), .ack(host_ack));

  afdx_mac_bfm #(.IF_MODE(IF_MODE), .DELAY_US(DELAY_US)) u_mac_a (
    .clk(clk), .rst(reset),
    .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready),
    .rx_data(rx_data), .rx_valid(rx_valid), .rx_ready(rx_ready),
    .frames_fwd(fwd_a));
  afdx_mac_bfm #(.IF_MODE(IF_MODE), .DELAY_US(DELAY_US)) u_mac_b (
    .clk(clk), .rst(reset),
    .tx_data(tx_data_b), .tx_valid(tx_valid_b), .tx_ready(tx_ready_b),
    .rx_data(rx_data_b), .rx_valid(rx_valid_b), .rx_ready(rx_ready_b),
    .frames_fwd(fwd_b));

  reg [31:0] vec [0:8191];
  integer vec_fd, vec_words, vec_scan;
  reg [31:0] vec_word;
  reg [8*512-1:0] vec_line, vec_token;
  integer clen [0:63], cplen [0:63], cbase [0:63];
  integer ncase, vi2, cid, i, b, waitc, errors, na, nb, j;
  integer acc0, snmp_tx_prev, found_rid, found_a2;
  integer spv, dpv;
  reg [31:0] dip, rd;
  reg [7:0] ca [0:511], cb [0:511];

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

  always @(posedge clk) if (!reset) begin
    if (tx_valid && (IF_MODE != 0 || tx_ready)) begin
      if (na < 512) ca[na] = tx_data;
      na = na + 1;
    end
    if (tx_valid_b && (IF_MODE != 0 || tx_ready_b)) begin
      if (nb < 512) cb[nb] = tx_data_b;
      nb = nb + 1;
    end
  end

  task bad;
    input [8*96-1:0] reason;
    begin
      if (errors < 25) $display("  [err] T31 t=%0t: %0s", $time, reason);
      errors = errors + 1;
    end
  endtask

  task inject_case;
    input integer c;
    begin
      for (b = 0; b < clen[c]; b = b + 1)
        u_mac_a.load_byte(b, fbyte(c, b));
      u_mac_a.inject(clen[c]);
    end
  endtask

  task send_and_wait;
    input integer c;
    begin
      acc0 = dut.mgmt_accept_cnt;
      snmp_tx_prev = dut.snmp_cnt_tx;
      na = 0; nb = 0;
      inject_case(c);
      waitc = 0;
      while (dut.mgmt_accept_cnt <= acc0 && waitc < 80000) begin
        @(negedge clk); waitc = waitc + 1;
      end
      if (waitc >= 80000) bad("SAP did not accept injected frame");
      waitc = 0;
      while (dut.snmp_cnt_tx === snmp_tx_prev && waitc < 20000) begin
        @(negedge clk); waitc = waitc + 1;
      end
      if (waitc >= 20000) bad("snmp engine produced no response");
      waitc = 0;
      while (na < 50 && waitc < 40000) begin
        @(negedge clk); waitc = waitc + 1;
      end
      if (na < 50) bad("SNMP response did not go on-wire");
      repeat (800) @(negedge clk);
    end
  endtask

  task dump_frame;
    input integer case_id;
    input integer net_id;
    input integer frame_len;
    integer z;
    begin
      $write("T31_FRAME case=%0d net=%0d len=%0d hex=", case_id, net_id, frame_len);
      for (z = 0; z < frame_len; z = z + 1) begin
        if (net_id == 0) $write("%02x", ca[z]);
        else             $write("%02x", cb[z]);
      end
      $display("");
    end
  endtask

  task check_rsp;
    input integer case_id;
    input integer rid0, rid1, rid2, rid3;
    input integer rid_n;
    begin
      if (na < 50) begin bad("response too short"); disable check_rsp; end
      if (na != nb) bad("A/B length differ");
      dump_frame(case_id, 0, na);
      dump_frame(case_id, 1, nb);
      spv = {ca[34], ca[35]};
      dpv = {ca[36], ca[37]};
      dip = {ca[30], ca[31], ca[32], ca[33]};
      if (spv !== DP_MGMT) bad("response sport not management UDP");
      if (dpv !== SP_PEER) bad("response dport not reversed peer sport");
      if (dip !== IP_PEER) bad("response dst IP not reversed peer");
      found_a2 = 0; found_rid = 0;
      for (j = 42; j < (na - 4); j = j + 1) begin
        if (ca[j] === 8'hA2) found_a2 = 1;
        if (rid_n == 2 && j + 1 < na - 4 &&
            ca[j] === rid0[7:0] && ca[j+1] === rid1[7:0]) found_rid = 1;
        if (rid_n == 3 && j + 2 < na - 4 &&
            ca[j] === rid0[7:0] && ca[j+1] === rid1[7:0] &&
            ca[j+2] === rid2[7:0]) found_rid = 1;
        if (rid_n == 4 && j + 3 < na - 4 &&
            ca[j] === rid0[7:0] && ca[j+1] === rid1[7:0] &&
            ca[j+2] === rid2[7:0] && ca[j+3] === rid3[7:0]) found_rid = 1;
      end
      if (!found_a2) bad("response has no A2 PDU");
      if (!found_rid) bad("response missing request-id");
    end
  endtask

  initial begin
    errors = 0; na = 0; nb = 0;
    vec_fd = $fopen("vec/t15_mgmt.hex", "r");
    if (vec_fd == 0) $fatal(1, "T31 vector file cannot be opened");
    vec_words = 0;
    while (!$feof(vec_fd)) begin
      vec_scan = $fgets(vec_line, vec_fd);
      if (vec_scan != 0) begin
        vec_scan = $sscanf(vec_line, "%s", vec_token);
        if (vec_scan == 1 && vec_token != "//") begin
          if ($sscanf(vec_token, "%h", vec_word) != 1 || (^vec_word === 1'bx))
            $fatal(1, "T31 malformed vector token");
          if (vec_words >= 8192) $fatal(1, "T31 vector capacity exceeded");
          vec[vec_words] = vec_word; vec_words = vec_words + 1;
        end
      end
    end
    $fclose(vec_fd);
    ncase = vec[0];
    if (ncase < 13 || ncase > 64) begin
      $display("T31 SNMP ONWIRE FAIL (golden vectors missing)");
      $finish;
    end
    vi2 = 1;
    for (i = 0; i < ncase; i = i + 1) begin
      if (vi2 + 3 > vec_words) $fatal(1, "T31 truncated vector header");
      cid = vec[vi2][31:24];
      if (cid >= 64 || vi2 + 3 + (vec[vi2][15:0] + 3) / 4 > vec_words)
        $fatal(1, "T31 vector record out of bounds");
      clen[cid] = vec[vi2][15:0];
      cplen[cid] = vec[vi2+1];
      cbase[cid] = vi2 + 3;
      vi2 = vi2 + 3 + (vec[vi2][15:0] + 3) / 4;
    end

    repeat (7) @(negedge clk); reset = 0;
    waitc = 0;
    while (dut.init_done !== 1 && waitc < 27000) begin @(negedge clk); waitc = waitc + 1; end
    if (waitc >= 27000) bad("INIT_DONE timeout");

    u_host.wr(16'h0008, 32'h2000);
    u_host.wr(16'h0078, 32'h172D);
    u_host.wr(16'h007C, 32'hAB61);
    u_host.wr(16'h42B2, 32'h1010_0100);
    u_host.wr(16'h0080, 32'h1);
    u_host.wr(16'h1F80, W0_VL);
    u_host.wr(16'h1F81, 32'h0000_0100);
    u_host.wr(PT_SAP, 32'h8006_0000);
    u_host.wr(PT_SAP + 1, {16'd0, DP_MGMT});
    u_host.wr(PT_SAP + 2, 32'd0);
    u_host.wr(PT_SAP + 3, 32'd1);
    u_host.wr(16'h0204, (P_SAP << 16));
    u_host.wr(16'h0203, 32'd0);
    u_host.wr(16'h0202, {DP_MGMT, 16'd0});
    u_host.wr(16'h0201, 32'h0000_0A00);
    u_host.wr(16'h0480, 32'd8305);
    u_host.wr(16'h0200, 32'h8050_0003);
    u_host.wr(16'h0064, 32'h0A00_0002);
    u_host.rd(16'h005C, rd);
    if (rd[1:0] !== 2'b00) bad("CFG_ERR blocks TX_EN");
    u_host.wr(16'h0008, CTL_TXON);

    u_host.rd(16'h0038, rd);
    $display("T31_EXPECT case=10 value=%08x", rd);
    send_and_wait(10);
    check_rsp(10, 8'h11, 8'h22, 8'h33, 8'h44, 4);
    $display("  [s7] GET on-wire na=%0d fwd=%0d", na, fwd_a);

    u_host.rd(16'h0100, rd);
    $display("T31_EXPECT case=11 value=%08x", rd);
    send_and_wait(11);
    check_rsp(11, 8'h02, 8'h01, 8'h55, 8'h00, 3);
    $display("  [s7] GETNEXT on-wire na=%0d", na);

    send_and_wait(12);
    check_rsp(12, 8'hA5, 8'hA5, 8'h00, 8'h00, 2);
    if (dut.snmp_ctl_shadow !== 16'h1234) bad("SET did not commit ctl 0x1234");
    $display("  [s7] SET on-wire ctl=%04h", dut.snmp_ctl_shadow);

    errors = errors + u_host.errors;
    if (errors == 0)
      $display("T31 SNMP ONWIRE PASS (IF_MODE=%0d GET+GETNEXT+SET via mac_bfm DELAY_US=%0d)",
               IF_MODE, DELAY_US);
    else
      $display("T31 SNMP ONWIRE FAIL (IF_MODE=%0d errors=%0d)", IF_MODE, errors);
    $finish;
  end

  initial begin
    #80_000_000;
    $display("T31 SNMP ONWIRE FAIL: timeout IF_MODE=%0d", IF_MODE);
    $finish;
  end
endmodule

module tb_s7_snmp_onwire;
  tb_s7_snmp_onwire_core #(.IF_MODE(0)) core();
endmodule
module tb_s7_snmp_onwire_gmii;
  tb_s7_snmp_onwire_core #(.IF_MODE(1)) core();
endmodule
