// T94 — afdx_app_top 多 VL 吞吐（封装口；新答疑主口径）
// 判据：稳态有效载荷 ≥100 Mbps；submit/deliver 对齐；drop=0；载荷逐字节一致。
// VL96..111（Lmax=1471）；ROUNDS=3；稳态窗=第 2–3 轮。
// 每帧必须等 submit_cnt+1（tx_valid↓ 后 busy 在 posedge 才置位，不可连发）。
`timescale 1 ns / 1 ps
module tb_t94_app_throughput;
  localparam integer CLK_NS = 8;
  localparam integer NVL = 16;
  localparam integer VL_BASE = 96;
  localparam integer PLEN = 1471;
  localparam integer ROUNDS = 3;
  localparam integer MIN_MBPS_X1000 = 100_000;
  localparam integer EXPECT = NVL * ROUNDS;

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

  integer rx_payload_bytes = 0;
  integer tx_payload_bytes = 0;
  integer win_start = 0, win_stop = 0;
  integer steady_start = 0, steady_stop = 0;
  integer rx_got = 0;

  task bad;
    input [8*96-1:0] why;
    begin
      if (errors < 40) $display("  [err] T94 cyc=%0d %0s", cycle, why);
      errors = errors + 1;
    end
  endtask

  function [7:0] payb;
    input integer vl, rnd, off;
    begin payb = (vl * 17 + rnd * 31 + off * 13 + 8'h5A) & 8'hFF; end
  endfunction

  task send_one;
    input integer vl;
    input integer rnd;
    integer k, g, s0;
    reg [15:0] vlid;
    begin
      g = 0;
      while (!tx_ready && g < 2_000_000) begin @(negedge clk); g = g + 1; end
      if (!tx_ready) bad("tx_ready timeout");
      vlid = 16'h0100 + vl[15:0];
      s0 = dut.u_tx.submit_cnt;
      @(negedge clk);
      tx_valid = 1; tx_data = vlid[15:8];
      @(negedge clk); tx_data = vlid[7:0];
      for (k = 0; k < PLEN; k = k + 1) begin
        @(negedge clk); tx_data = payb(vl, rnd, k);
      end
      @(negedge clk); tx_valid = 0; tx_data = 0;
      // 必须等 posedge 采样到帧结束并完成 MSG_WR；否则下一帧叠进同一 capt
      g = 0;
      while (dut.u_tx.submit_cnt < s0 + 1 && g < 2_000_000) begin
        @(negedge clk); g = g + 1;
      end
      if (dut.u_tx.submit_cnt < s0 + 1) bad("submit_cnt timeout");
      tx_payload_bytes = tx_payload_bytes + PLEN;
    end
  endtask

  task recv_one;
    input integer expect_vl;
    input integer expect_rnd;
    integer k, guard;
    reg [15:0] vlid, got;
    begin
      vlid = 16'h0100 + expect_vl[15:0];
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
        $display("  [dbg] expect_vlid=%04h got=%04h", vlid, got);
        bad("VLID mismatch");
      end else checks = checks + 1;
      for (k = 0; k < PLEN; k = k + 1) begin
        @(negedge clk);
        guard = 0;
        while (!rx_valid && guard < 200000) begin @(negedge clk); guard = guard + 1; end
        if (!rx_valid) begin bad("timeout payload"); disable recv_one; end
        if (rx_data !== payb(expect_vl, expect_rnd, k)) bad("payload mismatch");
        else checks = checks + 1;
        rx_payload_bytes = rx_payload_bytes + 1;
      end
      rx_got = rx_got + 1;
    end
  endtask

  integer r, v, csv, js, d0, g;
  real tx_mbps, rx_mbps, steady_rx_mbps;
  integer win_cyc, steady_cyc, steady_rx_bytes;

  initial begin
    $display("T94 afdx_app_top throughput NVL=%0d PLEN=%0d ROUNDS=%0d", NVL, PLEN, ROUNDS);
    csv = $fopen("t94_metrics.csv", "w");
    if (!csv) csv = $fopen("sim/out/t94_metrics.csv", "w");
    js  = $fopen("t94_verilog_summary.json", "w");
    if (!js)  js  = $fopen("sim/out/t94_verilog_summary.json", "w");
    if (csv)
      $fwrite(csv, "direction,verified_payload_bytes,window_cycles,clock_period_ns,payload_mbps\n");

    repeat (16) @(negedge clk); reset = 0;
    g = 0;
    while (dut.u_init.cfg_done !== 1'b1 && g < 20_000_000) begin
      @(negedge clk); g = g + 1;
    end
    if (dut.u_init.cfg_done !== 1'b1) bad("cfg_done timeout");
    else $display("T94 cfg_done at cycle %0d", cycle);

    for (r = 0; r < ROUNDS; r = r + 1) begin
      if (r == 0) win_start = cycle;
      if (r == 1) steady_start = cycle;
      for (v = 0; v < NVL; v = v + 1) begin
        d0 = dut.u_rx.deliver_cnt;
        // 同帧并行收：TX 等 submit 后再发下一帧；RX 与 GMII/交付重叠
        fork
          send_one(VL_BASE + v, r);
          recv_one(VL_BASE + v, r);
        join
        g = 0;
        while (dut.u_rx.deliver_cnt < d0 + 1 && g < 200000) begin
          @(negedge clk); g = g + 1;
        end
        if (dut.u_rx.deliver_cnt < d0 + 1) bad("deliver_cnt lag");
      end
      $display("T94 round %0d done submit=%0d deliver=%0d",
               r, dut.u_tx.submit_cnt, dut.u_rx.deliver_cnt);
      // 轮内 16 帧串行 e2e 已 ≫ BAG，同 VL 下一轮无需再垫
    end
    win_stop = cycle;
    steady_stop = cycle;

    if (dut.u_tx.submit_cnt !== EXPECT) bad("submit_cnt mismatch");
    else checks = checks + 1;
    if (dut.u_rx.deliver_cnt !== EXPECT) bad("deliver_cnt mismatch");
    else checks = checks + 1;
    if (dut.u_tx.drop_cnt !== 0) bad("drop_cnt nonzero");
    else checks = checks + 1;
    if (rx_got !== EXPECT) bad("rx_got mismatch");
    else checks = checks + 1;

    if (steady_start == 0) steady_start = win_start;
    win_cyc = (win_stop > win_start) ? (win_stop - win_start) : 0;
    steady_cyc = (steady_stop > steady_start) ? (steady_stop - steady_start) : 0;
    steady_rx_bytes = 2 * NVL * PLEN;
    if (win_cyc > 0)
      tx_mbps = tx_payload_bytes * 8.0 / (win_cyc * CLK_NS * 1.0e-3);
    else tx_mbps = 0.0;
    if (win_cyc > 0)
      rx_mbps = rx_payload_bytes * 8.0 / (win_cyc * CLK_NS * 1.0e-3);
    else rx_mbps = 0.0;
    if (steady_cyc > 0)
      steady_rx_mbps = steady_rx_bytes * 8.0 / (steady_cyc * CLK_NS * 1.0e-3);
    else steady_rx_mbps = 0.0;

    $display("T94_METRIC tx_payload_mbps=%.6f rx_payload_mbps=%.6f steady_rx_mbps=%.6f win_cyc=%0d steady_cyc=%0d",
             tx_mbps, rx_mbps, steady_rx_mbps, win_cyc, steady_cyc);
    $display("T94_METRIC submit=%0d deliver=%0d drop=%0d rx_bytes=%0d",
             dut.u_tx.submit_cnt, dut.u_rx.deliver_cnt, dut.u_tx.drop_cnt, rx_payload_bytes);

    if (steady_rx_mbps * 1000.0 < MIN_MBPS_X1000) bad("steady rx Mbps < 100");
    else checks = checks + 1;

    if (csv) begin
      $fwrite(csv, "tx,%0d,%0d,%0d,%.6f\n", tx_payload_bytes, win_cyc, CLK_NS, tx_mbps);
      $fwrite(csv, "rx,%0d,%0d,%0d,%.6f\n", rx_payload_bytes, win_cyc, CLK_NS, rx_mbps);
      $fwrite(csv, "rx_steady,%0d,%0d,%0d,%.6f\n", steady_rx_bytes, steady_cyc, CLK_NS, steady_rx_mbps);
      $fclose(csv);
    end
    if (js) begin
      $fwrite(js, "{\"nvl\":%0d,\"rounds\":%0d,\"plen\":%0d,\"expect\":%0d,",
              NVL, ROUNDS, PLEN, EXPECT);
      $fwrite(js, "\"submit\":%0d,\"deliver\":%0d,\"drop\":%0d,",
              dut.u_tx.submit_cnt, dut.u_rx.deliver_cnt, dut.u_tx.drop_cnt);
      $fwrite(js, "\"tx_bytes\":%0d,\"rx_bytes\":%0d,\"steady_rx_bytes\":%0d,",
              tx_payload_bytes, rx_payload_bytes, steady_rx_bytes);
      $fwrite(js, "\"window_cycles\":%0d,\"steady_cycles\":%0d,\"clock_period_ns\":%0d,",
              win_cyc, steady_cyc, CLK_NS);
      $fwrite(js, "\"tx_payload_mbps\":%.6f,\"rx_payload_mbps\":%.6f,\"steady_rx_mbps\":%.6f}\n",
              tx_mbps, rx_mbps, steady_rx_mbps);
      $fclose(js);
    end

    if (errors == 0)
      $display("T94 PASS checks=%0d steady_rx_mbps=%.6f submit=%0d deliver=%0d",
               checks, steady_rx_mbps, dut.u_tx.submit_cnt, dut.u_rx.deliver_cnt);
    else
      $display("T94 FAIL errors=%0d checks=%0d steady_rx_mbps=%.6f",
               errors, checks, steady_rx_mbps);
    $finish;
  end
endmodule
