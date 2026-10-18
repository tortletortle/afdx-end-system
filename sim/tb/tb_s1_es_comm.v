// T26 / S1 — ES communication through net_model (store-and-forward + 10 us).
// Same architectural path as design-book §12.1: host -> TX MAC -> switch -> RX MAC -> port.
// Does not wire DUT TX bytes back with a TB fork; the fabric forwards them.
// Config is the known-good 1 ms BAG / 79 B VL0 used by T22 (legal bag_exp=0).
`timescale 1 ns / 1 ps
module tb_s1_es_comm_core #(parameter integer IF_MODE = 0);
  localparam integer DELAY_US = 10;
  localparam integer P_RX = 5;
  localparam integer P_TX = 0;
  localparam [11:0]  VL_RX = 12'h100;
  localparam [15:0]  PT_RX = 16'h7D80 + 4*P_RX;
  localparam [15:0]  VLID_TX = 16'h0100;
  localparam integer PLEN = 32;
  localparam integer WIRE_B = 79;

  reg clk = 0, reset = 1;
  always #4 clk = ~clk;

  wire        host_cs, host_we;
  wire [15:0] host_addr;
  wire [31:0] host_wdata;
  wire [31:0] host_rdata;
  wire        host_ack, host_irq;

  wire [7:0] tx_data, tx_data_b, rx_data, rx_data_b;
  wire       tx_valid, tx_valid_b, tx_ready, tx_ready_b;
  wire       rx_valid, rx_valid_b, rx_ready, rx_ready_b;
  wire [31:0] fwd_a, fwd_b;

  reg corrupt_a = 0, corrupt_b = 0;

  AFDX_top #(.IF_MODE(IF_MODE), .FCS_MODE(2)) dut (
    .rx_error(1'b0), .rx_error_b(1'b0),
    .clk(clk), .reset(reset),
    .tx_data(tx_data), .rx_data(rx_data),
    .tx_valid(tx_valid), .rx_valid(rx_valid),
    .tx_ready(tx_ready), .rx_ready(rx_ready),
    .tx_data_b(tx_data_b), .tx_valid_b(tx_valid_b), .tx_ready_b(tx_ready_b),
    .rx_data_b(rx_data_b), .rx_valid_b(rx_valid_b), .rx_ready_b(rx_ready_b),
    .host_cs(host_cs), .host_we(host_we), .host_addr(host_addr),
    .host_wdata(host_wdata), .host_rdata(host_rdata), .host_ack(host_ack),
    .host_irq(host_irq),
    .pps_in(1'b0), .pps_out(), .rtc_time_us(), .dbg_frame_event());

  afdx_host_bfm u_host (
    .clk(clk), .cs(host_cs), .we(host_we), .addr(host_addr), .wdata(host_wdata),
    .rdata(host_rdata), .ack(host_ack));

  afdx_net_model #(.IF_MODE(IF_MODE), .DELAY_US(DELAY_US)) u_net (
    .clk(clk), .rst(reset),
    .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready),
    .tx_data_b(tx_data_b), .tx_valid_b(tx_valid_b), .tx_ready_b(tx_ready_b),
    .corrupt_a(corrupt_a), .corrupt_b(corrupt_b),
    .rx_data(rx_data), .rx_valid(rx_valid), .rx_ready(rx_ready),
    .rx_data_b(rx_data_b), .rx_valid_b(rx_valid_b), .rx_ready_b(rx_ready_b),
    .fwd_a(fwd_a), .fwd_b(fwd_b));

  afdx_chk_mac #(.IF_MODE(IF_MODE)) u_chk (
    .clk(clk), .rst(reset),
    .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready));

  afdx_cover #(.IF_MODE(IF_MODE)) u_cov (
    .clk(clk), .rst(reset), .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready));

  afdx_cov_ic u_cov_ic (
    .clk(clk), .rst_sync(dut.rst_sync),
    .out_vld(dut.u_rxic.out_vld), .out_ready(dut.u_rxic.out_ready),
    .out_reason(dut.u_rxic.out_reason), .net_id(dut.u_rxic.out_desc[99]));

  afdx_cov_rm u_cov_rm (
    .clk(clk), .rst_sync(dut.rst_sync),
    .out_vld(dut.u_rxrm.out_vld), .out_ready(dut.u_rxrm.out_ready),
    .out_fwd(dut.u_rxrm.out_fwd), .out_skew(dut.u_rxrm.out_skew),
    .active_q(dut.u_rxrm.active_q));

  afdx_cov_flt u_cov_flt (
    .clk(clk), .rst_sync(dut.rst_sync),
    .out_vld(dut.u_rxflt.out_vld), .out_ready(dut.u_rxflt.out_ready),
    .out_pass(dut.u_rxflt.out_pass), .out_reason(dut.u_rxflt.out_reason));

  afdx_cov_rsrc u_cov_rsrc (
    .clk(clk), .rst_sync(dut.rst_sync),
    .pmem_free(dut.pmem_free),
    .pb_ev_sample(dut.pb_ev_sample), .pb_ev_queue(dut.pb_ev_queue),
    .pb_ev_ovf(dut.pb_ev_ovf), .pb_ev_drop(dut.pb_ev_drop));

  integer errors, waitc, i, k, blk, base_addr;
  integer deliveries, nta, ntb;
  reg [31:0] rd, w;
  reg [7:0] tca [0:255], tcb [0:255];

  always @(posedge clk) if (!reset) begin
    if (dut.prs_out_vld && dut.pb_in_ready && !dut.prs_out_drop)
      deliveries = deliveries + 1;
    if (tx_valid && (IF_MODE != 0 || tx_ready)) begin
      if (nta < 256) tca[nta] = tx_data;
      nta = nta + 1;
    end
    if (tx_valid_b && (IF_MODE != 0 || tx_ready_b)) begin
      if (ntb < 256) tcb[ntb] = tx_data_b;
      ntb = ntb + 1;
    end
  end

  task bad;
    input [8*96-1:0] reason;
    begin
      if (errors < 25) $display("  [err] T26 t=%0t: %0s", $time, reason);
      errors = errors + 1;
    end
  endtask

  function [10:0] mix_bucket;
    input [15:0] vlid, seed;
    input table_id;
    reg [15:0] x;
    begin
      x = vlid + seed + (table_id ? 16'h1F5B : 16'h9E37);
      x = x ^ (x >> 7);
      x = x * (table_id ? 16'h45D9 : 16'h9E37);
      x = x ^ (x >> 9);
      mix_bucket = x & 11'h7FF;
    end
  endfunction

  function [15:0] hash_addr;
    input [15:0] vlid, seed;
    input table_id, way;
    begin
      hash_addr = 16'h3D80 + ({4'd0, table_id} << 12) +
                  (mix_bucket(vlid, seed, table_id) << 1) + way;
    end
  endfunction

  task wait_deliv;
    input integer need;
    begin
      waitc = 0;
      while (deliveries < need && waitc < 400000) begin
        @(negedge clk); waitc = waitc + 1;
      end
      if (deliveries < need) bad("delivery timeout through net_model");
    end
  endtask

  task send_payload;
    input integer pat;
    begin
      nta = 0;
      ntb = 0;
      u_host.rd(16'h0074, rd);
      waitc = 0;
      while (!rd[4] && waitc < 50000) begin
        @(negedge clk); waitc = waitc + 1;
        u_host.rd(16'h0074, rd);
      end
      if (!rd[4]) bad("no open TX block");
      blk = rd[3:0];
      base_addr = 16'h8800 + (blk << 9);
      @(negedge clk);
      u_host.cs = 1'b1; u_host.we = 1'b1;
      for (i = 0; i < 8; i = i + 1)
        u_host.wr_burst_word(base_addr + i, 32'hA0B0_C0D0 + pat + i);
      u_host.cs = 1'b0; u_host.we = 1'b0;
      u_host.wr(16'h8280 + P_TX, PLEN);
    end
  endtask

  task check_payload;
    input integer pat;
    integer j;
    begin
      if (nta != WIRE_B) begin
        $display("  [diag] TX A captured %0d bytes want %0d", nta, WIRE_B);
        bad("TX A length");
      end
      if (ntb != WIRE_B) begin
        $display("  [diag] TX B captured %0d bytes want %0d", ntb, WIRE_B);
        bad("TX B length");
      end
      u_host.rd(16'h8180 + P_RX, rd);
      if (rd[31] !== 1'b1 || rd[10:0] !== PLEN[10:0]) bad("PORT_DESC after net_model");
      blk = rd[23:20];
      u_host.rd(16'h8800 + (blk << 9) + 10, w);
      $display("  [diag] net fwd A/B=%0d/%0d last_len A/B=%0d/%0d nta/ntb=%0d/%0d tca42=%02h pmem42=%02h",
               fwd_a, fwd_b, u_net.u_a.last_len, u_net.u_b.last_len, nta, ntb, tca[42], w[15:8]);
      for (i = 10; i < 19; i = i + 1) begin
        u_host.rd(16'h8800 + (blk << 9) + i, w);
        for (k = 0; k < 4; k = k + 1) begin
          j = 4 * i + k;
          if (j >= 42 && j < 74)
            if (w[31 - 8 * k -: 8] !== tca[j])
              bad("RX payload != TX wire after switch");
        end
      end
      u_host.wr(16'h8380 + P_RX, 32'd0);
    end
  endtask

  initial begin
    errors = 0; deliveries = 0; nta = 0; ntb = 0;
    repeat (7) @(negedge clk); reset = 0;
    waitc = 0;
    while (dut.init_done !== 1 && waitc < 27000) begin @(negedge clk); waitc = waitc + 1; end
    if (waitc >= 27000) bad("INIT_DONE timeout");

    u_host.wr(16'h0008, 32'h2000);
    u_host.wr(16'h0060, 32'h1234_2001);
    u_host.wr(16'h0064, 32'h0A00_0001);
    u_host.wr(16'h0070, 32'h0000_0142);
    u_host.wr(16'h7D83, 32'h0000_0001);
    u_host.wr(16'h7D80, 32'h8000_C000);
    u_host.wr(16'h0204, 32'h0000_0000);
    u_host.wr(16'h0203, 32'hE000_0001);
    u_host.wr(16'h0202, 32'h1388_C000);
    u_host.wr(16'h0201, 32'h0003_E800);
    u_host.wr(16'h0480, 32'd8305);
    u_host.wr(16'h0200, 32'h8004_F003);
    u_host.rd(16'h005C, rd);
    if (rd !== 32'd0) bad("CFG_ERR set on legal 1 ms BAG");

    u_host.wr(16'h0078, 32'h172D);
    u_host.wr(16'h007C, 32'hAB61);
    u_host.wr(hash_addr(VLID_TX, 16'h172D, 1'b0, 1'b0), {3'd0, 1'b1, VLID_TX, VL_RX});
    u_host.wr(16'h0080, 32'h1);
    u_host.wr(16'h1F80, 32'hF500_0000 | (P_RX << 12) | 32'd79);
    u_host.wr(16'h1F81, {16'd0, VLID_TX});
    u_host.wr(PT_RX, 32'h8004_0000);
    u_host.wr(PT_RX + 1, 32'h0000_1388);
    u_host.wr(PT_RX + 2, 32'd0);
    u_host.wr(PT_RX + 3, 32'd1);
    u_host.wr(16'h0008, 32'h051F);

    send_payload(0);
    wait_deliv(1);
    u_host.rd(16'h004C, rd);
    $display("  [diag] after1 MSG/fwd/dup deliv=%0d fwd=%0d/%0d dup=%0d nta/ntb=%0d/%0d",
             deliveries, fwd_a, fwd_b, rd, nta, ntb);
    if (fwd_a < 1 || fwd_b < 1) bad("net_model did not forward A/B");
    u_host.rd(16'h8480 + P_RX, rd);
    if (rd !== 32'd1) bad("MSG_CNT != 1");
    u_host.rd(16'h004C, rd);
    if (rd !== 32'd1) bad("RM dup != 1 (A/B through switch)");
    check_payload(0);

    send_payload(32'h0100_0000);
    wait_deliv(2);
    u_host.rd(16'h8480 + P_RX, rd);
    if (rd !== 32'd1) bad("MSG_CNT after second frame (unread slot)");
    check_payload(32'h0100_0000);
    u_host.rd(16'h004C, rd);
    if (rd !== 32'd2) bad("RM dup != 2");

    corrupt_a = 1'b1; corrupt_b = 1'b1;
    send_payload(32'h0200_0000);
    waitc = 0;
    while (fwd_a < 3 && waitc < 400000) begin @(negedge clk); waitc = waitc + 1; end
    repeat (20000) @(negedge clk);
    if (deliveries != 2) bad("corrupt FCS frame was delivered");
    u_host.rd(16'h8480 + P_RX, rd);
    if (rd !== 32'd0) bad("MSG_CNT moved on corrupt frame");
    corrupt_a = 1'b0; corrupt_b = 1'b0;

    begin : dump_cov
      integer fd;
      fd = $fopen("out/metrics/cover_hand.csv", "w");
      if (fd != 0) begin
        $fdisplay(fd, "n_frm,n_sn1,n_sn2,n_byte");
        $fdisplay(fd, "%0d,%0d,%0d,%0d",
                  u_cov.n_frm, u_cov.n_sn1, u_cov.n_sn2, u_cov.n_byte);
        $fclose(fd);
      end
      fd = $fopen("out/metrics/cover_ic.csv", "w");
      if (fd != 0) begin
        $fdisplay(fd, "ok,reset,lost1,first_any,first_fail,ooo,badvl,net_a,net_b");
        $fdisplay(fd, "%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",
                  u_cov_ic.n_ok, u_cov_ic.n_reset, u_cov_ic.n_lost1,
                  u_cov_ic.n_first_any, u_cov_ic.n_first_fail, u_cov_ic.n_ooo,
                  u_cov_ic.n_badvl, u_cov_ic.n_net_a, u_cov_ic.n_net_b);
        $fclose(fd);
      end
      fd = $fopen("out/metrics/cover_rm.csv", "w");
      if (fd != 0) begin
        $fdisplay(fd, "fwd,dup,skew,bypass");
        $fdisplay(fd, "%0d,%0d,%0d,%0d",
                  u_cov_rm.n_fwd, u_cov_rm.n_dup, u_cov_rm.n_skew, u_cov_rm.n_bypass);
        $fclose(fd);
      end
      fd = $fopen("out/metrics/cover_flt.csv", "w");
      if (fd != 0) begin
        $fdisplay(fd, "pass,unconf,net,lmax,vlid");
        $fdisplay(fd, "%0d,%0d,%0d,%0d,%0d",
                  u_cov_flt.n_pass, u_cov_flt.n_unconf, u_cov_flt.n_net,
                  u_cov_flt.n_lmax, u_cov_flt.n_vlid);
        $fclose(fd);
      end
      fd = $fopen("out/metrics/cover_rsrc.csv", "w");
      if (fd != 0) begin
        $fdisplay(fd, "free0,free1,free2,free_gt2,sample,queue,ovf,pdrop");
        $fdisplay(fd, "%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",
                  u_cov_rsrc.n_free0, u_cov_rsrc.n_free1, u_cov_rsrc.n_free2,
                  u_cov_rsrc.n_free_gt2, u_cov_rsrc.n_sample, u_cov_rsrc.n_queue,
                  u_cov_rsrc.n_ovf, u_cov_rsrc.n_pdrop);
        $fclose(fd);
      end
    end

    errors = errors + u_host.errors + u_chk.errors;
    if (errors == 0)
      $display("T26 ES COMM PASS (IF_MODE=%0d net_model DELAY_US=%0d 2 good + 1 bad FCS)",
               IF_MODE, DELAY_US);
    else
      $display("T26 ES COMM FAIL (IF_MODE=%0d errors=%0d)", IF_MODE, errors);
    $finish;
  end

  initial begin
    #20_000_000;
    $display("T26 ES COMM FAIL: timeout IF_MODE=%0d", IF_MODE);
    $finish;
  end
endmodule

module tb_s1_es_comm;
  tb_s1_es_comm_core #(.IF_MODE(0)) core();
endmodule
module tb_s1_es_comm_gmii;
  tb_s1_es_comm_core #(.IF_MODE(1)) core();
endmodule
