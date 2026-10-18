// T37/T37g — TFTP multi-block load, host readback, and unload over net_model.
// Requests enter as switch-to-ES frames; DUT TX is captured on both MACs.
// This is a network-model path, not a remote TFTP peer loopback.
`timescale 1 ns / 1 ps
module tb_t37_tftp_multiblock_core #(
  parameter integer IF_MODE = 0,
  parameter integer LOAD_WORDS = 8192,
  parameter integer CAPACITY_ONLY = 0
);
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

  AFDX_top #(.IF_MODE(IF_MODE), .FCS_MODE(2), .LOAD_WORDS(LOAD_WORDS),
             .TFTP_SAP_PORT(P_SAP), .SNMP_SAP_PORT(9),
             .TFTP_TIMEOUT_US(2000)) dut (
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
  integer clen [0:63], cplen [0:63], cbase [0:63];
  integer ncase, vi2, cid, i, b, waitc, errors, na, nb, j;
  integer acc0, tftp_pkt_prev, found;
  integer spv, dpv, exp_idx, exp_words, exp_pos;
  reg [31:0] dip, rd;
  reg [7:0] ca [0:1023], cb [0:1023];
  reg [31:0] txexp [0:127];
  reg [31:0] err_exp [0:511];
  reg [31:0] unload_exp [0:511];
  integer exp_len [0:5], exp_base [0:5], err_len [0:5], err_base [0:5];
  integer unload_len [0:3], unload_base [0:3];
  integer unload_pos, err_pos;

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

  function [7:0] error_expected_byte;
    input integer frame_idx;
    input integer off;
    reg [31:0] q;
    begin
      q = err_exp[err_base[frame_idx] + (off >> 2)];
      case (off & 3)
        0: error_expected_byte = q[31:24]; 1: error_expected_byte = q[23:16];
        2: error_expected_byte = q[15:8]; default: error_expected_byte = q[7:0];
      endcase
    end
  endfunction

  function [31:0] crc32_byte;
    input [31:0] crc_in;
    input [7:0] data_in;
    reg [31:0] c;
    integer k;
    begin
      c = crc_in ^ data_in;
      for (k = 0; k < 8; k = k + 1)
        c = c[0] ? ((c >> 1) ^ 32'hEDB88320) : (c >> 1);
      crc32_byte = c;
    end
  endfunction

  function [31:0] captured_crc_a;
    input integer frame_len;
    integer k;
    reg [31:0] c;
    begin
      c = 32'hFFFF_FFFF;
      for (k = 0; k < frame_len - 4; k = k + 1)
        c = crc32_byte(c, ca[k]);
      captured_crc_a = ~c;
    end
  endfunction

  function [31:0] captured_crc_b;
    input integer frame_len;
    integer k;
    reg [31:0] c;
    begin
      c = 32'hFFFF_FFFF;
      for (k = 0; k < frame_len - 4; k = k + 1)
        c = crc32_byte(c, cb[k]);
      captured_crc_b = ~c;
    end
  endfunction

  always @(posedge clk) if (!reset) begin
    if (tx_valid && (IF_MODE != 0 || tx_ready)) begin
      if (na < 1024) ca[na] = tx_data;
      na = na + 1;
    end
    if (tx_valid_b && (IF_MODE != 0 || tx_ready_b)) begin
      if (nb < 1024) cb[nb] = tx_data_b;
      nb = nb + 1;
    end
  end

  task bad;
    input [8*96-1:0] reason;
    begin
      if (errors < 25) $display("  [err] T37 t=%0t: %0s", $time, reason);
      errors = errors + 1;
    end
  endtask

  task host_read;
    input [15:0] a;
    output [31:0] d;
    begin
      u_host.rd(a,d);
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
    input integer need_a;
    input integer need_b;
    begin
      acc0 = dut.mgmt_accept_cnt;
      tftp_pkt_prev = dut.tftp_pkt;
      na = 0; nb = 0;
      inject_case(c);
      waitc = 0;
      while (dut.mgmt_accept_cnt <= acc0 && waitc < 80000) begin
        @(negedge clk); waitc = waitc + 1;
      end
      if (waitc >= 80000) bad("SAP did not accept injected TFTP frame");
      waitc = 0;
      while (dut.tftp_pkt === tftp_pkt_prev && waitc < 20000) begin
        @(negedge clk); waitc = waitc + 1;
      end
      if (waitc >= 20000) bad("tftp engine produced no PDU");
      waitc = 0;
      while ((na < need_a || nb < need_b) && waitc < 80000) begin
        @(negedge clk); waitc = waitc + 1;
      end
      if (waitc >= 80000) bad("TFTP response frame(s) did not complete on both MACs");
      repeat (800) @(negedge clk);
    end
  endtask

  task wait_response_frames;
    input integer need_a;
    input integer need_b;
    input integer max_cycles;
    input [8*96-1:0] msg;
    begin
      na = 0; nb = 0; waitc = 0;
      while ((na < need_a || nb < need_b) && waitc < max_cycles) begin
        @(negedge clk); waitc = waitc + 1;
      end
      if (waitc >= max_cycles) bad(msg);
      repeat (800) @(negedge clk);
    end
  endtask

  task inject_and_expect_silent;
    input integer c;
    input integer wait_cycles;
    integer accepted0, pkt0, w;
    begin
      accepted0 = dut.mgmt_accept_cnt;
      pkt0 = dut.tftp_pkt;
      na = 0; nb = 0;
      inject_case(c);
      w = 0;
      while (dut.mgmt_accept_cnt <= accepted0 && w < 80000) begin
        @(negedge clk); w = w + 1;
      end
      if (w >= 80000) bad("terminal ACK was not accepted by the management SAP");
      w = 0;
      while (dut.tftp_pkt === pkt0 && w < 20000) begin
        @(negedge clk); w = w + 1;
      end
      if (w >= 20000) bad("terminal ACK did not reach the TFTP engine");
      repeat (wait_cycles) @(negedge clk);
      if (na != 0 || nb != 0)
        bad("closed unload session emitted a response/retransmission after ACK(2)");
    end
  endtask

  task check_ack;
    input [7:0] blk_hi;
    input [7:0] blk_lo;
    input [7:0] expected_sn;
    integer shown_a, shown_b;
    reg [31:0] got_fcs_a, got_fcs_b;
    begin
      shown_a = 0; shown_b = 0;
      if (na < 50) begin bad("ACK frame too short"); disable check_ack; end
      exp_idx = (blk_lo == 8'h00) ? 0 : (blk_lo == 8'h01) ? 2 : 4;
      if (na != exp_len[exp_idx]) bad("net-A full frame length differs from golden");
      if (nb != exp_len[exp_idx+1]) bad("net-B full frame length differs from golden");
      if (ca[11] !== 8'h20) bad("net-A SMAC ifid");
      if (cb[11] !== 8'h40) bad("net-B SMAC ifid");
      spv = {ca[34], ca[35]};
      dpv = {ca[36], ca[37]};
      dip = {ca[30], ca[31], ca[32], ca[33]};
      if (spv !== DP_MGMT) bad("ACK sport not management UDP");
      if (dpv !== SP_PEER) bad("ACK dport not reversed peer TID");
      if (dip !== IP_PEER) bad("ACK dst IP not reversed peer");
      if ({ca[38], ca[39]} !== 16'd12) bad("UDP length is not exactly 8-byte header + 4-byte ACK");
      if ({ca[16], ca[17]} !== 16'd32) bad("IPv4 total length does not match the 4-byte ACK");
      if (ca[42] !== 8'h00 || ca[43] !== 8'h04 ||
          ca[44] !== blk_hi || ca[45] !== blk_lo)
        bad("TFTP ACK opcode/block bytes differ");
      for (j = 0; j < exp_len[exp_idx] && j < na; j = j + 1)
        if (j < exp_len[exp_idx]-5 && ca[j] !== expected_byte(exp_idx, j)) begin
          if (shown_a < 8) $display("  [diff] net-A byte[%0d] got=%02x want=%02x", j, ca[j], expected_byte(exp_idx, j));
          shown_a = shown_a + 1;
          if (j < 64) bad("net-A byte differs from complete golden frame");
          else errors = errors + 1;
        end
      for (j = 0; j < exp_len[exp_idx+1] && j < nb; j = j + 1)
        if (j < exp_len[exp_idx+1]-5 && cb[j] !== expected_byte(exp_idx+1, j)) begin
          if (shown_b < 8) $display("  [diff] net-B byte[%0d] got=%02x want=%02x", j, cb[j], expected_byte(exp_idx+1, j));
          shown_b = shown_b + 1;
          if (j < 64) bad("net-B byte differs from complete golden frame");
          else errors = errors + 1;
        end
      if (ca[exp_len[exp_idx]-5] !== expected_sn || cb[exp_len[exp_idx+1]-5] !== expected_sn)
        bad("ACK response AFDX sequence number differs from expected progression");
      got_fcs_a = {ca[exp_len[exp_idx]-1],ca[exp_len[exp_idx]-2],ca[exp_len[exp_idx]-3],ca[exp_len[exp_idx]-4]};
      got_fcs_b = {cb[exp_len[exp_idx+1]-1],cb[exp_len[exp_idx+1]-2],cb[exp_len[exp_idx+1]-3],cb[exp_len[exp_idx+1]-4]};
      if (got_fcs_a !== captured_crc_a(exp_len[exp_idx])) bad("net-A ACK FCS invalid after sequence update");
      if (got_fcs_b !== captured_crc_b(exp_len[exp_idx+1])) bad("net-B ACK FCS invalid after sequence update");
    end
  endtask

  task check_error;
    input [15:0] code;
    integer idx, j;
    begin
      idx = (code == 16'd5) ? 0 : (code == 16'd4) ? 2 : 4;
      if (na != err_len[idx] || nb != err_len[idx+1]) bad("TFTP ERROR full-frame length differs from independent oracle");
      if (na < 64 || nb < 64) begin bad("TFTP ERROR frame too short"); disable check_error; end
      if ({ca[42],ca[43]} !== 16'h0005 || {cb[42],cb[43]} !== 16'h0005 ||
          {ca[44],ca[45]} !== code || {cb[44],cb[45]} !== code)
        bad("TFTP ERROR opcode/code bytes differ");
      for (j=0; j<err_len[idx] && j<na; j=j+1)
        if (ca[j] !== error_expected_byte(idx,j)) bad("net-A ERROR frame differs from complete independent oracle");
      for (j=0; j<err_len[idx+1] && j<nb; j=j+1)
        if (cb[j] !== error_expected_byte(idx+1,j)) bad("net-B ERROR frame differs from complete independent oracle");
    end
  endtask

  task check_unload;
    input integer frame_idx;
    input [7:0] expected_sn;
    integer j, payload_len, shown_a, shown_b;
    reg [15:0] got_blk;
    reg [31:0] got_fcs_a, got_fcs_b;
    begin
      shown_a=0; shown_b=0;
      payload_len = (frame_idx < 2) ? 516 : 12;
      got_blk = (frame_idx < 2) ? 16'd1 : 16'd2;
      if (na != unload_len[frame_idx]) bad("net-A unload frame length differs from golden");
      if (nb != unload_len[frame_idx+1]) bad("net-B unload frame length differs from golden");
      if ({ca[30],ca[31],ca[32],ca[33]} !== IP_PEER ||
          {cb[30],cb[31],cb[32],cb[33]} !== IP_PEER) bad("unload destination IP is not peer");
      if ({ca[34],ca[35]} !== DP_MGMT || {ca[36],ca[37]} !== SP_PEER ||
          {cb[34],cb[35]} !== DP_MGMT || {cb[36],cb[37]} !== SP_PEER)
        bad("unload UDP ports do not preserve peer TID");
      if ({ca[38],ca[39]} !== payload_len+8 || {cb[38],cb[39]} !== payload_len+8)
        bad("unload UDP length does not match DATA payload");
      if ({ca[16],ca[17]} !== payload_len+28 || {cb[16],cb[17]} !== payload_len+28)
        bad("unload IPv4 length does not match DATA payload");
      if ({ca[42],ca[43]} !== 16'h0003 || {cb[42],cb[43]} !== 16'h0003 ||
          {ca[44],ca[45]} !== got_blk || {cb[44],cb[45]} !== got_blk)
        bad("unload DATA opcode/block differs");
      for (j=0; j<unload_len[frame_idx] && j<na; j=j+1)
        if (j < unload_len[frame_idx]-5 && ca[j] !== unload_expected_byte(frame_idx,j)) begin
          if (shown_a < 4) $display("  [diff] unload A[%0d] got=%02x want=%02x",j,ca[j],unload_expected_byte(frame_idx,j));
          shown_a=shown_a+1; bad("net-A unload differs from complete golden frame");
        end
      for (j=0; j<unload_len[frame_idx+1] && j<nb; j=j+1)
        if (j < unload_len[frame_idx+1]-5 && cb[j] !== unload_expected_byte(frame_idx+1,j)) begin
          if (shown_b < 4) $display("  [diff] unload B[%0d] got=%02x want=%02x",j,cb[j],unload_expected_byte(frame_idx+1,j));
          shown_b=shown_b+1; bad("net-B unload differs from complete golden frame");
        end
      if (ca[unload_len[frame_idx]-5] !== expected_sn || cb[unload_len[frame_idx+1]-5] !== expected_sn)
        bad("initial unload response AFDX sequence differs from expected progression");
      got_fcs_a = {ca[unload_len[frame_idx]-1],ca[unload_len[frame_idx]-2],ca[unload_len[frame_idx]-3],ca[unload_len[frame_idx]-4]};
      got_fcs_b = {cb[unload_len[frame_idx+1]-1],cb[unload_len[frame_idx+1]-2],cb[unload_len[frame_idx+1]-3],cb[unload_len[frame_idx+1]-4]};
      if (got_fcs_a !== captured_crc_a(unload_len[frame_idx])) bad("net-A unload FCS invalid after sequence update");
      if (got_fcs_b !== captured_crc_b(unload_len[frame_idx+1])) bad("net-B unload FCS invalid after sequence update");
    end
  endtask

  // AFDX retransmission reuses the TFTP payload but consumes a fresh link
  // sequence number. Compare the stable frame body to the golden image, then
  // independently check the expected SN and the recomputed Ethernet FCS.
  task check_unload_retry;
    input integer frame_idx;
    input [7:0] expected_sn;
    integer j, len_a, len_b, shown_a, shown_b;
    reg [31:0] got_fcs_a, got_fcs_b;
    begin
      shown_a = 0; shown_b = 0;
      len_a = unload_len[frame_idx];
      len_b = unload_len[frame_idx+1];
      if (na != len_a) bad("net-A retransmitted frame length differs from golden");
      if (nb != len_b) bad("net-B retransmitted frame length differs from golden");
      if (len_a < 5 || len_b < 5) begin
        bad("retransmitted AFDX frame too short for SN/FCS");
        disable check_unload_retry;
      end
      for (j = 0; j < len_a - 5 && j < na; j = j + 1)
        if (ca[j] !== unload_expected_byte(frame_idx,j)) begin
          if (shown_a < 4) $display("  [diff] retry A[%0d] got=%02x want=%02x",j,ca[j],unload_expected_byte(frame_idx,j));
          shown_a = shown_a + 1;
          bad("net-A retransmission stable bytes differ from golden");
        end
      for (j = 0; j < len_b - 5 && j < nb; j = j + 1)
        if (cb[j] !== unload_expected_byte(frame_idx+1,j)) begin
          if (shown_b < 4) $display("  [diff] retry B[%0d] got=%02x want=%02x",j,cb[j],unload_expected_byte(frame_idx+1,j));
          shown_b = shown_b + 1;
          bad("net-B retransmission stable bytes differ from golden");
        end
      if (ca[len_a-5] !== expected_sn || cb[len_b-5] !== expected_sn)
        bad("retransmitted frame AFDX sequence number did not advance as expected");
      got_fcs_a = {ca[len_a-1],ca[len_a-2],ca[len_a-3],ca[len_a-4]};
      got_fcs_b = {cb[len_b-1],cb[len_b-2],cb[len_b-3],cb[len_b-4]};
      if (got_fcs_a !== captured_crc_a(len_a)) bad("net-A retransmission FCS invalid after SN update");
      if (got_fcs_b !== captured_crc_b(len_b)) bad("net-B retransmission FCS invalid after SN update");
    end
  endtask

  task check_host_image;
    integer k, lane;
    reg [7:0] want_byte;
    reg [31:0] word_data;
    begin
      for (k=0; k<520; k=k+4) begin
        host_read(16'hCC20 + (k >> 2), word_data);
        for (lane=0; lane<4; lane=lane+1) begin
          if (k+lane < 512) want_byte=fbyte(1,46+k+lane);
          else if (k+lane < 520) want_byte=fbyte(2,46+(k+lane-512));
          else want_byte=8'h00;
          if (word_data[31-8*lane -: 8] !== want_byte)
            bad("host load-area readback differs byte-for-byte from injected DATA");
        end
      end
      host_read(16'hAC21, word_data);
      if (word_data !== 32'd520) bad("network-loaded byte count is not 520");
      host_read(16'hAC20, word_data);
      if (word_data[31] !== 1'b1 || word_data[26] !== 1'b0)
        bad("network multi-block load did not commit cleanly");
    end
  endtask

  task check_host_image_512;
    integer k, lane;
    reg [31:0] word_data;
    begin
      for (k=0; k<512; k=k+4) begin
        host_read(16'hCC20 + (k >> 2), word_data);
        for (lane=0; lane<4; lane=lane+1)
          if (word_data[31-8*lane -: 8] !== fbyte(49,46+k+lane))
            bad("zero-terminal-block scenario load image differs byte-for-byte");
      end
      host_read(16'hAC21, word_data);
      if (word_data !== 32'd512) bad("full-block plus empty terminator must commit exactly 512 bytes");
      host_read(16'hAC20, word_data);
      if (word_data[31] !== 1'b1 || word_data[26] !== 1'b0)
        bad("full-block zero terminator did not mark the image loaded and close WRQ");
    end
  endtask

  initial begin
    errors = 0; na = 0; nb = 0;
    $readmemh("vec/t15_mgmt.hex", vec);
    $readmemh("vec/tftp_tx_expected.hex", txexp);
    $readmemh("vec/tftp_error_expected.hex", err_exp);
    $readmemh("vec/tftp_unload_expected.hex", unload_exp);
    exp_words = txexp[0];
    exp_pos = 1;
    if (exp_words != 6) bad("full-frame TFTP ACK expectation vector missing or malformed");
    for (i = 0; i < 6; i = i + 1) begin
      exp_len[i] = txexp[exp_pos];
      exp_base[i] = exp_pos + 1;
      exp_pos = exp_base[i] + (exp_len[i] + 3) / 4;
    end
    err_pos = 1;
    if (err_exp[0] != 6) bad("full-frame TFTP ERROR expectation vector missing or malformed");
    for (i = 0; i < 6; i = i + 1) begin
      err_len[i] = err_exp[err_pos];
      err_base[i] = err_pos + 1;
      err_pos = err_base[i] + (err_len[i] + 3) / 4;
    end
    unload_pos = 1;
    if (unload_exp[0] != 4) bad("full-frame TFTP unload expectation vector missing or malformed");
    for (i = 0; i < 4; i = i + 1) begin
      unload_len[i] = unload_exp[unload_pos];
      unload_base[i] = unload_pos + 1;
      unload_pos = unload_base[i] + (unload_len[i] + 3) / 4;
    end
    ncase = vec[0];
    if (ncase < 54) begin
      $display("T37 TFTP MULTIBLOCK FAIL (required vector cases 0/41-51 missing)");
      $finish;
    end
    vi2 = 1;
    for (i = 0; i < ncase; i = i + 1) begin
      cid = vec[vi2][31:24];
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
    u_host.wr(16'h0060, 32'h172D_2001);
    u_host.rd(16'h0060, rd);
    if (rd !== 32'h172D_2001) bad("SMAC_CFG readback mismatch");
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
    u_host.rd(16'h0008, rd);
    if (rd[9] !== 1'b1) bad("MGMT_TX_EN not set");

    if (CAPACITY_ONLY != 0) begin
      send_and_wait(0, exp_len[0], exp_len[1]);
      check_ack(8'h00, 8'h00, 8'h01);
      send_and_wait(1, exp_len[2], exp_len[3]);
      check_ack(8'h00, 8'h01, 8'h02);
      send_and_wait(52, exp_len[4], exp_len[5]);
      check_ack(8'h00, 8'h02, 8'h03);
      host_read(16'hAC21, rd);
      if (rd !== 32'd1024) bad("exact network capacity was not committed after two full blocks");
      host_read(16'hAC20, rd);
      if (rd[31] !== 1'b0 || rd[26] !== 1'b1 || rd[15:0] !== 16'd0)
        bad("exact-capacity full-block transfer must remain an active, error-free load");
      host_read(16'hCC20, rd);
      if (rd !== {fbyte(1,46),fbyte(1,47),fbyte(1,48),fbyte(1,49)})
        bad("network capacity boundary corrupted the first word before overflow");
      host_read(16'hCC20 + 16'd255, rd);
      if (rd !== {fbyte(52,554),fbyte(52,555),fbyte(52,556),fbyte(52,557)})
        bad("network capacity boundary failed to retain the last in-range word");

      send_and_wait(53, err_len[4], err_len[5]);
      check_error(16'd3);
      host_read(16'hAC21, rd);
      if (rd !== 32'd1024) bad("network overflow byte changed committed byte count");
      host_read(16'hAC20, rd);
      if (rd[31] !== 1'b0 || rd[26] !== 1'b0 || rd[15:0] !== 16'd3)
        bad("network capacity+1 must return ERROR(3), leave image uncommitted, and close WRQ");
      host_read(16'hAC24, rd);
      if (rd[15:0] !== SP_PEER || rd[23:16] !== 8'd1)
        bad("network capacity ERROR(3) changed peer TID or missed error counter");
      host_read(16'hCC20, rd);
      if (rd !== {fbyte(1,46),fbyte(1,47),fbyte(1,48),fbyte(1,49)})
        bad("network overflow byte wrapped and corrupted the first word");
      host_read(16'hCC20 + 16'd255, rd);
      if (rd !== {fbyte(52,554),fbyte(52,555),fbyte(52,556),fbyte(52,557)})
        bad("network overflow byte modified the last in-range word");
      errors = errors + u_host.errors;
      if (errors == 0)
        $display("T40 TFTP NETWORK CAPACITY PASS (IF_MODE=%0d configured LOAD_WORDS=%0d, exact-capacity multi-block load, capacity+1 ERROR(3), byte count and public memory no-wrap checks, A/B full-frame match)",
                 IF_MODE, LOAD_WORDS);
      else
        $display("T40 TFTP NETWORK CAPACITY FAIL (IF_MODE=%0d errors=%0d)", IF_MODE, errors);
      $finish;
    end else begin
    send_and_wait(0, exp_len[0], exp_len[1]);
    check_ack(8'h00, 8'h00, 8'h01);
    $display("  [t37] WRQ -> ACK(0) on-wire A/B=%0d/%0d", na, nb);

    send_and_wait(41, err_len[0], err_len[1]);
    check_error(16'd5);
    host_read(16'hAC20, rd);
    if (rd[15:0] !== 16'd5 || rd[26] !== 1'b1)
      bad("wrong-TID ERROR(5) must leave the WRQ session active");
    host_read(16'hAC24, rd);
    if (rd[15:0] !== SP_PEER || rd[23:16] !== 8'd1)
      bad("wrong-TID request changed the established peer TID or missed err counter");

    waitc = 0;
    while (dut.fb_busy && waitc < 20000) begin @(negedge clk); waitc = waitc + 1; end
    send_and_wait(42, exp_len[2], exp_len[3]);
    check_ack(8'h00, 8'h01, 8'h03);
    $display("  [t37] DATA(1/512) -> ACK(1) on-wire A/B=%0d/%0d", na, nb);

    send_and_wait(43, exp_len[2], exp_len[3]);
    check_ack(8'h00, 8'h01, 8'h04);
    host_read(16'hAC21, rd);
    if (rd !== 32'd512) bad("duplicate DATA(1) changed committed byte count");
    host_read(16'hAC24, rd);
    if (rd[31:24] !== 8'd1 || rd[23:16] !== 8'd1)
      bad("duplicate DATA did not increment only the duplicate counter");

    waitc = 0;
    while (dut.fb_busy && waitc < 20000) begin @(negedge clk); waitc = waitc + 1; end
    send_and_wait(44, exp_len[4], exp_len[5]);
    check_ack(8'h00, 8'h02, 8'h05);
    $display("  [t37] DATA(2/8) -> ACK(2) completes load A/B=%0d/%0d", na, nb);
    check_host_image();

    send_and_wait(45, unload_len[0], unload_len[1]);
    check_unload(0, 8'h06);
    $display("  [t37] RRQ UPLOAD -> DATA(1/512) A/B=%0d/%0d", na, nb);

    // Deliberately lose peer ACK(1). The TFTP DATA bytes stay fixed while the
    // AFDX sequence byte advances and the Ethernet FCS is recomputed.
    wait_response_frames(unload_len[0], unload_len[1], 300000,
                         "lost ACK(1) did not cause a DATA(1) timeout retransmission");
    check_unload_retry(0, 8'h07);
    host_read(16'hAC25, rd);
    if (rd[15:8] == 8'd0 || rd[7:0] == 8'd0)
      bad("lost ACK(1) was not reflected in timeout/retry counters");

    send_and_wait(46, unload_len[2], unload_len[3]);
    check_unload_retry(2, 8'h08);
    $display("  [t37] ACK(1) -> DATA(2/8) A/B=%0d/%0d", na, nb);

    // ACK the final short block and require the network-visible session to close.
    inject_and_expect_silent(47, 300000);
    host_read(16'hAC20, rd);
    if (rd[27] !== 1'b0) bad("ACK(2) did not close the public RRQ unload session");

    send_and_wait(48, exp_len[0], exp_len[1]);
    check_ack(8'h00, 8'h00, 8'h09);
    send_and_wait(49, exp_len[2], exp_len[3]);
    check_ack(8'h00, 8'h01, 8'h0A);
    send_and_wait(50, exp_len[4], exp_len[5]);
    check_ack(8'h00, 8'h02, 8'h0B);
    check_host_image_512();

    send_and_wait(51, unload_len[0], unload_len[1]);
    check_unload(0, 8'h0C);
    for (i=0; i<3; i=i+1) begin
      wait_response_frames(unload_len[0], unload_len[1], 350000,
                           "retry-exhaustion scenario missed a bounded DATA retransmission");
      check_unload_retry(0, 8'h0D+i);
      host_read(16'hAC25, rd);
      if (rd[7:0] !== i+1) bad("retry counter did not advance exactly once per DATA retransmission");
    end
    wait_response_frames(err_len[2], err_len[3], 350000,
                         "retry exhaustion did not return a network-visible ERROR(4)");
    check_error(16'd4);
    host_read(16'hAC20, rd);
    if (rd[15:0] !== 16'd4 || rd[27] !== 1'b0 || rd[26] !== 1'b0)
      bad("retry exhaustion ERROR(4) did not close and clear the RRQ session");
    na = 0; nb = 0;
    repeat (750000) @(negedge clk);
    if (na != 0 || nb != 0) bad("closed RRQ session continued transmitting after retry exhaustion");

    errors = errors + u_host.errors;
    if (errors == 0)
      $display("T37 TFTP NETWORK PASS (IF_MODE=%0d multi-block load/unload, wrong-TID recovery, duplicate DATA, zero-byte final block, lost ACK retry, retry exhaustion cleanup, A/B full-frame match)",
               IF_MODE);
    else
      $display("T37 TFTP MULTIBLOCK FAIL (IF_MODE=%0d errors=%0d)", IF_MODE, errors);
    $finish;
    end
  end

  initial begin
    #80_000_000;
    $display("T37 TFTP MULTIBLOCK FAIL: timeout IF_MODE=%0d", IF_MODE);
    $finish;
  end
endmodule

module tb_t37_tftp_multiblock;
  tb_t37_tftp_multiblock_core #(.IF_MODE(0)) core();
endmodule
module tb_t37g_tftp_multiblock;
  tb_t37_tftp_multiblock_core #(.IF_MODE(1)) core();
endmodule
module tb_t40_tftp_capacity;
  tb_t37_tftp_multiblock_core #(.IF_MODE(0), .LOAD_WORDS(256), .CAPACITY_ONLY(1)) core();
endmodule
module tb_t40g_tftp_capacity;
  tb_t37_tftp_multiblock_core #(.IF_MODE(1), .LOAD_WORDS(256), .CAPACITY_ONLY(1)) core();
endmodule
