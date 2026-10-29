// T92 — afdx_app_top 基本收发（封装口 only）
// 帧格式示例：
//   VLID=0x0100, payload=01 02 03 04
//   tx_valid: 1  1  1  1  1  1
//   tx_data:  01 00 01 02 03 04
// VL 按 plen 档：0/32/64/96，与 init 的 Lmax 分组一致。
`timescale 1 ns / 1 ps
module tb_t92_app_basic;
  localparam integer CLK_NS = 8;
  localparam integer NCASE = 4;
  localparam integer PL0 = 17, PL1 = 256, PL2 = 1024, PL3 = 1471;

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
  integer gmii_bytes = 0;
  always @(posedge clk) begin
    cycle <= cycle + 1;
    if (gmii_dv_a) gmii_bytes = gmii_bytes + 1;
  end

  task bad;
    input [8*80-1:0] why;
    begin
      if (errors < 40) $display("  [err] T92 cyc=%0d %0s", cycle, why);
      errors = errors + 1;
    end
  endtask

  function [7:0] payb;
    input integer caseno, off;
    begin payb = (caseno * 17 + off * 13 + 8'hA5) & 8'hFF; end
  endfunction

  function integer plen_of;
    input integer c;
    begin
      case (c)
        0: plen_of = PL0;
        1: plen_of = PL1;
        2: plen_of = PL2;
        default: plen_of = PL3;
      endcase
    end
  endfunction

  // 与 afdx_app_init plen_for 分组对齐，避免 Lmax 拒收
  function integer vl_of;
    input integer c;
    begin
      case (c)
        0: vl_of = 0;
        1: vl_of = 32;
        2: vl_of = 64;
        default: vl_of = 96;
      endcase
    end
  endfunction

  task send_frame;
    input integer vl;
    input integer caseno;
    integer plen, k;
    reg [15:0] vlid;
    begin
      plen = plen_of(caseno);
      vlid = 16'h0100 + vl[15:0];
      @(negedge clk);
      tx_valid = 1; tx_data = vlid[15:8];
      @(negedge clk); tx_data = vlid[7:0];
      for (k = 0; k < plen; k = k + 1) begin
        @(negedge clk); tx_data = payb(caseno, k);
      end
      @(negedge clk); tx_valid = 0; tx_data = 0;
    end
  endtask

  task recv_check;
    input integer vl;
    input integer caseno;
    integer plen, k, guard;
    reg [15:0] vlid, got_vlid;
    begin
      plen = plen_of(caseno);
      vlid = 16'h0100 + vl[15:0];
      guard = 0;
      while (!rx_valid && guard < 2_000_000) begin
        @(negedge clk); guard = guard + 1;
      end
      if (!rx_valid) begin bad("timeout waiting VLID_hi"); disable recv_check; end
      got_vlid[15:8] = rx_data;
      @(negedge clk);
      guard = 0;
      while (!rx_valid && guard < 100000) begin @(negedge clk); guard = guard + 1; end
      if (!rx_valid) begin bad("timeout VLID_lo"); disable recv_check; end
      got_vlid[7:0] = rx_data;
      if (got_vlid !== vlid) bad("VLID mismatch");
      else checks = checks + 1;
      for (k = 0; k < plen; k = k + 1) begin
        @(negedge clk);
        guard = 0;
        while (!rx_valid && guard < 100000) begin @(negedge clk); guard = guard + 1; end
        if (!rx_valid) begin bad("timeout payload"); disable recv_check; end
        if (rx_data !== payb(caseno, k)) bad("payload byte mismatch");
        else checks = checks + 1;
      end
    end
  endtask

  integer c, csv, wait_sub, g0, vl, deliver0;

  initial begin
    $display("T92 afdx_app_top basic RX/TX start");
    csv = $fopen("t92_metrics.csv", "w");
    if (!csv) csv = $fopen("sim/out/t92_metrics.csv", "w");
    if (csv) $fwrite(csv, "case,vl,plen,checks,errors,submit,deliver,gmii_bytes\n");

    repeat (16) @(negedge clk); reset = 0;
    g0 = 0;
    while (dut.u_init.cfg_done !== 1'b1 && g0 < 20_000_000) begin
      @(negedge clk); g0 = g0 + 1;
    end
    if (dut.u_init.cfg_done !== 1'b1) bad("cfg_done timeout");
    else $display("T92 cfg_done at cycle %0d", cycle);
    $display("T92 post-cfg: hash_image_valid=%0b ctl=%08h rx_stream_en=%0b",
             dut.u_es.hash_image_valid, dut.u_es.ctl_r, dut.u_es.rx_stream_en);

    for (c = 0; c < NCASE; c = c + 1) begin
      vl = vl_of(c);
      $display("T92 case %0d vl=%0d plen=%0d", c, vl, plen_of(c));
      gmii_bytes = 0;
      deliver0 = dut.u_rx.deliver_cnt;
      send_frame(vl, c);

      // RX 输出可能早于 GMII 等待结束；与等待并行收
      fork
        begin : tx_watch
          wait_sub = 0;
          while (dut.u_tx.submit_cnt < (c + 1) && wait_sub < 200000) begin
            @(negedge clk); wait_sub = wait_sub + 1;
          end
          if (dut.u_tx.submit_cnt < (c + 1)) bad("TX submit timeout");
          wait_sub = 0;
          while (gmii_bytes < 60 && wait_sub < 300000) begin
            @(negedge clk); wait_sub = wait_sub + 1;
          end
          if (gmii_bytes < 60) bad("no GMII TX activity");
          wait_sub = 0;
          while (gmii_dv_a && wait_sub < 200000) begin
            @(negedge clk); wait_sub = wait_sub + 1;
          end
        end
        begin : rx_watch
          recv_check(vl, c);
        end
      join

      // deliver_cnt 在 MSG_RD(S_REL) 之后才 +1，晚于 rx_valid 流结束
      wait_sub = 0;
      while (dut.u_rx.deliver_cnt < deliver0 + 1 && wait_sub < 100000) begin
        @(negedge clk); wait_sub = wait_sub + 1;
      end
      if (dut.u_rx.deliver_cnt < deliver0 + 1)
        bad("deliver_cnt did not advance after S_REL");
      $display("T92 case%0d submit=%0d deliver=%0d mac_good=%0d rm_fwd=%0d gmii=%0d",
               c, dut.u_tx.submit_cnt, dut.u_rx.deliver_cnt,
               dut.u_es.u_mac_rx_a.good_cnt, dut.u_es.rm_fwd_cnt, gmii_bytes);
      if (csv)
        $fwrite(csv, "%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",
                c, vl, plen_of(c), checks, errors,
                dut.u_tx.submit_cnt, dut.u_rx.deliver_cnt, gmii_bytes);

      // 跨 VL 无需满 BAG；同仿真节拍留余量
      repeat (20000) @(negedge clk);
    end

    begin : nodup
      integer g, extras;
      extras = 0; g = 0;
      while (g < 50000) begin
        @(negedge clk); g = g + 1;
        if (rx_valid) extras = extras + 1;
      end
      if (extras != 0) bad("extra rx bytes after cases (dup?)");
      else checks = checks + 1;
    end

    if (csv) $fclose(csv);
    if (errors == 0)
      $display("T92 PASS checks=%0d drop=%0d submit=%0d deliver=%0d",
               checks, dut.u_tx.drop_cnt, dut.u_tx.submit_cnt, dut.u_rx.deliver_cnt);
    else
      $display("T92 FAIL errors=%0d checks=%0d submit=%0d deliver=%0d",
               errors, checks, dut.u_tx.submit_cnt, dut.u_rx.deliver_cnt);
    $finish;
  end
endmodule
