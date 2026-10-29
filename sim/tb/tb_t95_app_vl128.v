// T95 — afdx_app_top 128 VL 配置并全部发送（封装口）
// TX：VL0..127 各 1 帧；RX：VL0..125 交付校验；VL126/127 期望 unconf（无 RX 表）。
// 载荷分档同 init：0–31→17，32–63→256，64–95→1024，96–127→1471（126/127 仅发）。
`timescale 1 ns / 1 ps
module tb_t95_app_vl128;
  localparam integer CLK_NS = 8;
  localparam integer NVL_TX = 128;
  localparam integer NVL_RX = 126;
  localparam integer EXPECT_UNCONF = 2 * 2; // VL126/127 × A/B

  reg clk = 0, reset = 1;
  always #(CLK_NS/2) clk = ~clk;

  reg  [7:0] tx_data = 0;
  reg        tx_valid = 0;
  wire [7:0] rx_data;
  wire       rx_valid;
  wire       tx_ready;
  reg        rx_ready = 1;
  wire [7:0] gmii_a, gmii_b;
  wire       gmii_dv_a, gmii_dv_b;

  afdx_app_top dut (
    .clk(clk), .reset(reset),
    .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready),
    .rx_data(rx_data), .rx_valid(rx_valid), .rx_ready(rx_ready),
    .gmii_tx_data_a(gmii_a), .gmii_tx_valid_a(gmii_dv_a),
    .gmii_tx_data_b(gmii_b), .gmii_tx_valid_b(gmii_dv_b)
  );

  integer errors = 0, checks = 0, cycle = 0;
  always @(posedge clk) cycle <= cycle + 1;

  task bad;
    input [8*96-1:0] why;
    begin
      if (errors < 40) $display("  [err] T95 cyc=%0d %0s", cycle, why);
      errors = errors + 1;
    end
  endtask

  function integer plen_of;
    input integer vl;
    begin
      if (vl < 32)       plen_of = 17;
      else if (vl < 64)  plen_of = 256;
      else if (vl < 96)  plen_of = 1024;
      else               plen_of = 1471;
    end
  endfunction

  function [7:0] payb;
    input integer vl, off;
    begin payb = (vl * 17 + off * 13 + 8'hA5) & 8'hFF; end
  endfunction

  task send_one;
    input integer vl;
    integer k, g, s0, plen;
    reg [15:0] vlid;
    begin
      plen = plen_of(vl);
      g = 0;
      while (!tx_ready && g < 2_000_000) begin @(negedge clk); g = g + 1; end
      if (!tx_ready) bad("tx_ready timeout");
      vlid = 16'h0100 + vl[15:0];
      s0 = dut.u_tx.submit_cnt;
      @(negedge clk);
      tx_valid = 1; tx_data = vlid[15:8];
      @(negedge clk); tx_data = vlid[7:0];
      for (k = 0; k < plen; k = k + 1) begin
        @(negedge clk); tx_data = payb(vl, k);
      end
      @(negedge clk); tx_valid = 0; tx_data = 0;
      g = 0;
      while (dut.u_tx.submit_cnt < s0 + 1 && g < 2_000_000) begin
        @(negedge clk); g = g + 1;
      end
      if (dut.u_tx.submit_cnt < s0 + 1) bad("submit timeout");
    end
  endtask

  task recv_one;
    input integer vl;
    integer k, guard, plen;
    reg [15:0] vlid, got;
    begin
      plen = plen_of(vl);
      vlid = 16'h0100 + vl[15:0];
      guard = 0;
      while (!rx_valid && guard < 5_000_000) begin @(negedge clk); guard = guard + 1; end
      if (!rx_valid) begin bad("timeout VLID_hi"); disable recv_one; end
      got[15:8] = rx_data;
      @(negedge clk);
      guard = 0;
      while (!rx_valid && guard < 200000) begin @(negedge clk); guard = guard + 1; end
      if (!rx_valid) begin bad("timeout VLID_lo"); disable recv_one; end
      got[7:0] = rx_data;
      if (got !== vlid) begin
        $display("  [dbg] expect=%04h got=%04h", vlid, got);
        bad("VLID mismatch");
      end else checks = checks + 1;
      for (k = 0; k < plen; k = k + 1) begin
        @(negedge clk);
        guard = 0;
        while (!rx_valid && guard < 200000) begin @(negedge clk); guard = guard + 1; end
        if (!rx_valid) begin bad("timeout payload"); disable recv_one; end
        if (rx_data !== payb(vl, k)) bad("payload mismatch");
        else checks = checks + 1;
      end
    end
  endtask

  integer vl, g, csv, js, d0, unconf0, unconf1, unconf_delta;
  integer rx_done;

  initial begin
    $display("T95 afdx_app_top VL128 TX=%0d RX=%0d", NVL_TX, NVL_RX);
    csv = $fopen("t95_metrics.csv", "w");
    if (!csv) csv = $fopen("sim/out/t95_metrics.csv", "w");
    js  = $fopen("t95_verilog_summary.json", "w");
    if (!js)  js  = $fopen("sim/out/t95_verilog_summary.json", "w");
    if (csv) $fwrite(csv, "vl,plen,submit,deliver\n");

    repeat (16) @(negedge clk); reset = 0;
    g = 0;
    while (dut.u_init.cfg_done !== 1'b1 && g < 20_000_000) begin
      @(negedge clk); g = g + 1;
    end
    if (dut.u_init.cfg_done !== 1'b1) bad("cfg_done timeout");
    else $display("T95 cfg_done at cycle %0d", cycle);

    // 确认末 VL 端口：避开 6/7 与 TX16..143 后 VL125 应为 port 255
    $display("T95 map VL0 port=%0d valid=%0b; VL125 port=%0d valid=%0b",
             dut.u_rx.port_of_vl[0], dut.u_rx.vl_valid[0],
             dut.u_rx.port_of_vl[125], dut.u_rx.vl_valid[125]);
    if (dut.u_rx.port_of_vl[125] !== 8'd255)
      $display("T95 NOTE: VL125 port=%0d (expected 255 for this pool order)",
               dut.u_rx.port_of_vl[125]);
    if (!dut.u_rx.vl_valid[125]) bad("VL125 not mapped");

    unconf0 = dut.u_es.flt_unconf_cnt;
    rx_done = 0;

    // 先发有 RX 的 0..125：先 submit，等 RM fwd，再收（避免 fork 下线侧未到就超时）
    for (vl = 0; vl < NVL_RX; vl = vl + 1) begin
      d0 = dut.u_rx.deliver_cnt;
      begin : one_rx
        integer f0, gg;
        f0 = dut.u_es.rm_fwd_cnt;
        send_one(vl);
        gg = 0;
        while (dut.u_es.rm_fwd_cnt < f0 + 1 && gg < 5_000_000) begin
          @(negedge clk); gg = gg + 1;
        end
        if (dut.u_es.rm_fwd_cnt < f0 + 1) begin
          $display("  [dbg] vl=%0d map_port=%0d rx_st=%0d fwd=%0d",
                   vl, dut.u_rx.port_of_vl[vl], dut.u_rx.st, dut.u_es.rm_fwd_cnt);
          bad("rm_fwd timeout");
        end
        recv_one(vl);
      end
      g = 0;
      while (dut.u_rx.deliver_cnt < d0 + 1 && g < 500000) begin
        @(negedge clk); g = g + 1;
      end
      if (dut.u_rx.deliver_cnt < d0 + 1) bad("deliver lag");
      rx_done = rx_done + 1;
      if (csv)
        $fwrite(csv, "%0d,%0d,%0d,%0d\n",
                vl, plen_of(vl), dut.u_tx.submit_cnt, dut.u_rx.deliver_cnt);
      if ((vl % 32) == 31)
        $display("T95 progress vl=%0d submit=%0d deliver=%0d fwd=%0d",
                 vl, dut.u_tx.submit_cnt, dut.u_rx.deliver_cnt, dut.u_es.rm_fwd_cnt);
    end

    // VL126/127：只发，应收 unconf，无应用口交付
    for (vl = NVL_RX; vl < NVL_TX; vl = vl + 1) begin
      send_one(vl);
      if (csv)
        $fwrite(csv, "%0d,%0d,%0d,%0d\n",
                vl, plen_of(vl), dut.u_tx.submit_cnt, dut.u_rx.deliver_cnt);
    end
    // 等线侧 unconf 计数落稳
    repeat (500000) @(negedge clk);
    unconf1 = dut.u_es.flt_unconf_cnt;
    unconf_delta = unconf1 - unconf0;

    if (dut.u_tx.submit_cnt !== NVL_TX) bad("submit != 128");
    else checks = checks + 1;
    if (dut.u_rx.deliver_cnt !== NVL_RX) bad("deliver != 126");
    else checks = checks + 1;
    if (dut.u_tx.drop_cnt !== 0) bad("tx drop nonzero");
    else checks = checks + 1;
    if (unconf_delta !== EXPECT_UNCONF) begin
      $display("  [dbg] unconf_delta=%0d expect=%0d", unconf_delta, EXPECT_UNCONF);
      bad("unconf count mismatch");
    end else checks = checks + 1;

    // 尾声无多余 rx
    begin : nodup
      integer gg, extras;
      extras = 0; gg = 0;
      while (gg < 50000) begin
        @(negedge clk); gg = gg + 1;
        if (rx_valid) extras = extras + 1;
      end
      if (extras != 0) bad("extra rx after");
      else checks = checks + 1;
    end

    $display("T95_METRIC submit=%0d deliver=%0d unconf_delta=%0d drop=%0d",
             dut.u_tx.submit_cnt, dut.u_rx.deliver_cnt, unconf_delta, dut.u_tx.drop_cnt);

    if (csv) $fclose(csv);
    if (js) begin
      $fwrite(js, "{\"nvl_tx\":%0d,\"nvl_rx\":%0d,\"submit\":%0d,\"deliver\":%0d,",
              NVL_TX, NVL_RX, dut.u_tx.submit_cnt, dut.u_rx.deliver_cnt);
      $fwrite(js, "\"unconf_delta\":%0d,\"expect_unconf\":%0d,\"drop\":%0d}\n",
              unconf_delta, EXPECT_UNCONF, dut.u_tx.drop_cnt);
      $fclose(js);
    end

    if (errors == 0)
      $display("T95 PASS checks=%0d submit=%0d deliver=%0d unconf=%0d",
               checks, dut.u_tx.submit_cnt, dut.u_rx.deliver_cnt, unconf_delta);
    else
      $display("T95 FAIL errors=%0d checks=%0d submit=%0d deliver=%0d",
               errors, checks, dut.u_tx.submit_cnt, dut.u_rx.deliver_cnt);
    $finish;
  end
endmodule
