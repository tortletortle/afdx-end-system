// T93 — afdx_app_top 时延/抖动（封装口；新答疑主口径）
// 时延：帧首字节 tx_valid 上升沿拍 → 同帧 rx 首字节（VLID_hi）出现拍；≤2 ms。
// 抖动：同 VL 同帧长多帧时延 max−min。
// BAG 间隔：按 VL 统计 GMII 上相邻帧 TX SFD(0xD5) 间隔 min/max/极差（A、B 两网各自统计），
//   判据 min ≥ BAG（BAG 取 afdx_app_init.BAG_US，运行时与本 TB 常量交叉核对）；
//   gmii_frame_gap_* 为跨 VL 的 A 网全局帧间隔，仅观察，不是 BAG 判据。
// 场景：A 单 VL 8 帧；B 4 VL 争用各 4 帧。
// 注意：本 TB 用层次引用 dut.u_tx / dut.u_rx / dut.u_init 读内部计数器与参数，仅 RTL 仿真可用，
//   不能用于门级或黑盒。
`timescale 1 ns / 1 ps

// GMII 帧监视：SFD 后第 5、6 字节取目的 MAC 低 16 位的低字节作 VL 键；按 VL 记 SFD 间隔。
module t93_sfd_mon #(parameter integer NET = 0) (
  input  wire        clk,
  input  wire [31:0] cyc,
  input  wire        dv,
  input  wire [7:0]  d,
  input  integer     fh
);
  integer last [0:255];
  integer cnt  [0:255];
  integer gmin [0:255];
  integer gmax [0:255];
  integer nfr = 0;
  reg     in_frm = 1'b0, sfd_seen = 1'b0;
  integer sfd_cyc = 0, mb = 0, k;
  reg [7:0] hi = 8'd0;
  integer g;
  initial for (k = 0; k < 256; k = k + 1) begin
    last[k] = 0; cnt[k] = 0; gmin[k] = 32'h7fff_ffff; gmax[k] = 0;
  end
  always @(posedge clk) begin
    if (dv) begin
      if (!in_frm) begin in_frm = 1'b1; sfd_seen = 1'b0; mb = 0; end
      if (!sfd_seen) begin
        if (d == 8'hD5) begin sfd_seen = 1'b1; sfd_cyc = cyc; mb = 0; end
      end else begin
        if (mb == 4) hi = d;
        if (mb == 5) begin
          if (cnt[d] > 0) begin
            g = sfd_cyc - last[d];
            if (g < gmin[d]) gmin[d] = g;
            if (g > gmax[d]) gmax[d] = g;
          end
          last[d] = sfd_cyc;
          if (fh != 0) $fwrite(fh, "%0d,%0d,%0d,%0d\n", NET, d, cnt[d], sfd_cyc);
          cnt[d] = cnt[d] + 1;
          nfr = nfr + 1;
        end
        mb = mb + 1;
      end
    end else in_frm = 1'b0;
  end
endmodule

module tb_t93_app_latency;
  localparam integer CLK_NS = 8;
  localparam integer LAT_MAX_NS = 2_000_000;
  localparam integer LAT_MAX_CYC = LAT_MAX_NS / CLK_NS;
  localparam integer PLEN = 256;
  localparam integer VL_A = 32;          // Lmax 档含 256
  localparam integer NA = 8;
  localparam integer NVL_B = 4;
  localparam integer NB = 4;
  localparam integer VL_B0 = 32;

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

  // 跨 VL 的 A 网全局帧间隔：仅观察，不是 BAG 判据（不同 VL 的帧交错，间隔小于 BAG 是正常的）
  integer gmii_sfd_last = 0, gmii_frame_gap_max = 0, gmii_frame_gap_min = 32'h7fff_ffff;
  integer gmii_seen = 0;
  reg gmii_dv_d = 0;
  always @(posedge clk) begin
    gmii_dv_d <= gmii_dv_a;
    if (gmii_dv_a && !gmii_dv_d) begin
      if (gmii_seen > 0) begin
        if (cycle - gmii_sfd_last > gmii_frame_gap_max) gmii_frame_gap_max = cycle - gmii_sfd_last;
        if (cycle - gmii_sfd_last < gmii_frame_gap_min) gmii_frame_gap_min = cycle - gmii_sfd_last;
      end
      gmii_sfd_last = cycle;
      gmii_seen = gmii_seen + 1;
    end
  end

  // 按 VL 的 TX SFD 间隔监视（A、B 两网）
  localparam integer BAG_US  = 1000;                      // 须等于 afdx_app_init.BAG_US
  localparam integer BAG_CYC = BAG_US * 1000 / CLK_NS;    // 125000 周期
  localparam integer EXP_FRAMES = NA + NVL_B * NB;        // 每网期望帧数
  integer sfd_csv = 0;
  t93_sfd_mon #(.NET(0)) mon_a (.clk(clk), .cyc(cycle), .dv(gmii_dv_a), .d(gmii_a), .fh(sfd_csv));
  t93_sfd_mon #(.NET(1)) mon_b (.clk(clk), .cyc(cycle), .dv(gmii_dv_b), .d(gmii_b), .fh(sfd_csv));

  task bad;
    input [8*96-1:0] why;
    begin
      if (errors < 40) $display("  [err] T93 cyc=%0d %0s", cycle, why);
      errors = errors + 1;
    end
  endtask

  function [7:0] payb;
    input integer vl, fr, off;
    begin payb = (vl * 19 + fr * 7 + off * 11 + 8'hC3) & 8'hFF; end
  endfunction

  task wait_ready;
    integer g;
    begin
      g = 0;
      while (!tx_ready && g < 2_000_000) begin @(negedge clk); g = g + 1; end
      if (!tx_ready) bad("tx_ready timeout");
    end
  endtask

  task send_one;
    input integer vl;
    input integer fr;
    output integer t_first;
    integer k, g, s0;
    reg [15:0] vlid;
    begin
      wait_ready;
      vlid = 16'h0100 + vl[15:0];
      s0 = dut.u_tx.submit_cnt;
      @(negedge clk);
      t_first = cycle;
      tx_valid = 1; tx_data = vlid[15:8];
      @(negedge clk); tx_data = vlid[7:0];
      for (k = 0; k < PLEN; k = k + 1) begin
        @(negedge clk); tx_data = payb(vl, fr, k);
      end
      @(negedge clk); tx_valid = 0; tx_data = 0;
      // tx_valid↓ 后 busy 在下一 posedge 才置位；等 submit 防叠帧
      g = 0;
      while (dut.u_tx.submit_cnt < s0 + 1 && g < 2_000_000) begin
        @(negedge clk); g = g + 1;
      end
      if (dut.u_tx.submit_cnt < s0 + 1) bad("submit timeout");
    end
  endtask

  task recv_one;
    input integer vl;
    input integer fr;
    output integer t_first_rx;
    integer k, guard;
    reg [15:0] vlid, got;
    begin
      vlid = 16'h0100 + vl[15:0];
      guard = 0;
      while (!rx_valid && guard < 5_000_000) begin @(negedge clk); guard = guard + 1; end
      if (!rx_valid) begin bad("timeout VLID_hi"); t_first_rx = cycle; disable recv_one; end
      t_first_rx = cycle;
      got[15:8] = rx_data;
      @(negedge clk);
      guard = 0;
      while (!rx_valid && guard < 200000) begin @(negedge clk); guard = guard + 1; end
      if (!rx_valid) begin bad("timeout VLID_lo"); disable recv_one; end
      got[7:0] = rx_data;
      if (got !== vlid) bad("VLID mismatch");
      else checks = checks + 1;
      for (k = 0; k < PLEN; k = k + 1) begin
        @(negedge clk);
        guard = 0;
        while (!rx_valid && guard < 200000) begin @(negedge clk); guard = guard + 1; end
        if (!rx_valid) begin bad("timeout payload"); disable recv_one; end
        if (rx_data !== payb(vl, fr, k)) bad("payload mismatch");
        else checks = checks + 1;
      end
    end
  endtask

  integer csv, js, gapcsv, i, v, t_tx, t_rx, lat, lat_ns, nv, nviol, vmin, vmax;
  integer a_min, a_max, a_jit;
  integer b_max, b_min;
  integer lat_a [0:NA-1];
  integer lat_b [0:NVL_B*NB-1];
  integer bi;

  initial begin
    $display("T93 afdx_app_top latency/jitter PLEN=%0d", PLEN);
    csv = $fopen("t93_metrics.csv", "w");
    if (!csv) csv = $fopen("sim/out/t93_metrics.csv", "w");
    js  = $fopen("t93_verilog_summary.json", "w");
    if (!js)  js  = $fopen("sim/out/t93_verilog_summary.json", "w");
    if (csv)
      $fwrite(csv, "phase,vl,frame,t_tx_first,t_rx_first,lat_cyc,lat_ns\n");
    sfd_csv = $fopen("t93_gmii_sfd.csv", "w");
    if (!sfd_csv) sfd_csv = $fopen("sim/out/t93_gmii_sfd.csv", "w");
    if (sfd_csv) $fwrite(sfd_csv, "net,vl,seq,t_sfd\n");
    if (dut.u_init.BAG_US != BAG_US) bad("TB BAG_US != afdx_app_init.BAG_US");

    repeat (16) @(negedge clk); reset = 0;
    i = 0;
    while (dut.u_init.cfg_done !== 1'b1 && i < 20_000_000) begin
      @(negedge clk); i = i + 1;
    end
    if (dut.u_init.cfg_done !== 1'b1) bad("cfg_done timeout");
    else $display("T93 cfg_done at cycle %0d", cycle);

    // ---- Phase A: 单 VL ----
    a_min = 32'h7fff_ffff; a_max = 0;
    for (i = 0; i < NA; i = i + 1) begin
      fork
        send_one(VL_A, i, t_tx);
        recv_one(VL_A, i, t_rx);
      join
      // deliver_cnt 晚于 rx 流；等 S_REL
      begin : wa
        integer g;
        g = 0;
        while (dut.u_rx.deliver_cnt < (i + 1) && g < 100000) begin
          @(negedge clk); g = g + 1;
        end
      end
      lat = t_rx - t_tx;
      if (lat < 0) lat = 0;
      lat_a[i] = lat;
      lat_ns = lat * CLK_NS;
      if (lat > a_max) a_max = lat;
      if (lat < a_min) a_min = lat;
      if (lat > LAT_MAX_CYC) bad("phaseA latency > 2ms");
      else checks = checks + 1;
      if (csv)
        $fwrite(csv, "A,%0d,%0d,%0d,%0d,%0d,%0d\n", VL_A, i, t_tx, t_rx, lat, lat_ns);
      $display("T93 A frame%0d lat_cyc=%0d lat_ns=%0d", i, lat, lat_ns);
      // 同 VL 下一帧需过 BAG；留足间隔
      repeat (130000) @(negedge clk);
    end
    a_jit = a_max - a_min;
    $display("T93_METRIC phaseA max_ns=%0d min_ns=%0d jit_ns=%0d",
             a_max * CLK_NS, a_min * CLK_NS, a_jit * CLK_NS);

    // ---- Phase B: 4 VL 争用（串行注入，调度侧重叠）----
    b_max = 0; b_min = 32'h7fff_ffff; bi = 0;
    for (i = 0; i < NB; i = i + 1) begin
      for (v = 0; v < NVL_B; v = v + 1) begin
        fork
          send_one(VL_B0 + v, i, t_tx);
          recv_one(VL_B0 + v, i, t_rx);
        join
        begin : wb
          integer g, expect_d;
          expect_d = NA + bi + 1;
          g = 0;
          while (dut.u_rx.deliver_cnt < expect_d && g < 100000) begin
            @(negedge clk); g = g + 1;
          end
        end
        lat = t_rx - t_tx;
        if (lat < 0) lat = 0;
        lat_b[bi] = lat;
        lat_ns = lat * CLK_NS;
        if (lat > b_max) b_max = lat;
        if (lat < b_min) b_min = lat;
        if (lat > LAT_MAX_CYC) bad("phaseB latency > 2ms");
        else checks = checks + 1;
        if (csv)
          $fwrite(csv, "B,%0d,%0d,%0d,%0d,%0d,%0d\n",
                  VL_B0 + v, i, t_tx, t_rx, lat, lat_ns);
        bi = bi + 1;
      end
      // 轮间略等 BAG，避免同 VL 欠账
      repeat (130000) @(negedge clk);
    end
    $display("T93_METRIC phaseB max_ns=%0d min_ns=%0d jit_ns=%0d",
             b_max * CLK_NS, b_min * CLK_NS, (b_max - b_min) * CLK_NS);
    $display("T93_METRIC gmii_frame_gap_max_cyc=%0d gmii_frame_gap_min_cyc=%0d gmii_frames=%0d (cross-VL, observe only)",
             gmii_frame_gap_max, gmii_frame_gap_min, gmii_seen);

    // ---- 按 VL 的 TX SFD 间隔：min ≥ BAG ----
    gapcsv = $fopen("t93_vl_gap.csv", "w");
    if (!gapcsv) gapcsv = $fopen("sim/out/t93_vl_gap.csv", "w");
    if (gapcsv) $fwrite(gapcsv, "net,vl,frames,gap_min_cyc,gap_max_cyc,gap_range_cyc\n");
    nviol = 0; nv = 0; vmin = 32'h7fff_ffff; vmax = 0;
    for (i = 0; i < 256; i = i + 1) begin
      if (mon_a.cnt[i] > 0) begin
        if (gapcsv) begin
          if (mon_a.cnt[i] > 1)
            $fwrite(gapcsv, "0,%0d,%0d,%0d,%0d,%0d\n", i, mon_a.cnt[i],
                    mon_a.gmin[i], mon_a.gmax[i], mon_a.gmax[i] - mon_a.gmin[i]);
          else
            $fwrite(gapcsv, "0,%0d,%0d,,,\n", i, mon_a.cnt[i]);
        end
        if (mon_a.cnt[i] > 1) begin
          nv = nv + 1;
          if (mon_a.gmin[i] < vmin) vmin = mon_a.gmin[i];
          if (mon_a.gmax[i] > vmax) vmax = mon_a.gmax[i];
          if (mon_a.gmin[i] < BAG_CYC) begin
            nviol = nviol + 1;
            bad("netA VL TX SFD gap < BAG");
            $display("  [err] T93 netA vl=%0d gap_min=%0d < BAG_CYC=%0d", i, mon_a.gmin[i], BAG_CYC);
          end
        end
      end
      if (mon_b.cnt[i] > 0) begin
        if (gapcsv) begin
          if (mon_b.cnt[i] > 1)
            $fwrite(gapcsv, "1,%0d,%0d,%0d,%0d,%0d\n", i, mon_b.cnt[i],
                    mon_b.gmin[i], mon_b.gmax[i], mon_b.gmax[i] - mon_b.gmin[i]);
          else
            $fwrite(gapcsv, "1,%0d,%0d,,,\n", i, mon_b.cnt[i]);
        end
        if (mon_b.cnt[i] > 1) begin
          if (mon_b.gmin[i] < vmin) vmin = mon_b.gmin[i];
          if (mon_b.gmax[i] > vmax) vmax = mon_b.gmax[i];
          if (mon_b.gmin[i] < BAG_CYC) begin
            nviol = nviol + 1;
            bad("netB VL TX SFD gap < BAG");
            $display("  [err] T93 netB vl=%0d gap_min=%0d < BAG_CYC=%0d", i, mon_b.gmin[i], BAG_CYC);
          end
        end
      end
    end
    if (gapcsv) $fclose(gapcsv);
    if (mon_a.nfr !== EXP_FRAMES) bad("netA SFD frame count != expected");
    else checks = checks + 1;
    if (mon_b.nfr !== EXP_FRAMES) bad("netB SFD frame count != expected");
    else checks = checks + 1;
    if (nv == 0) bad("no VL with >=2 frames for BAG check");
    else if (nviol == 0) checks = checks + 1;
    $display("T93_METRIC vl_bag bag_cyc=%0d vl_with_gap=%0d gap_min_cyc=%0d gap_max_cyc=%0d viol=%0d sfd_a=%0d sfd_b=%0d",
             BAG_CYC, nv, vmin, vmax, nviol, mon_a.nfr, mon_b.nfr);
    if (sfd_csv) $fclose(sfd_csv);
    sfd_csv = 0;

    if (csv) $fclose(csv);
    if (js) begin
      $fwrite(js, "{\"plen\":%0d,\"lat_max_ns\":%0d,", PLEN, LAT_MAX_NS);
      $fwrite(js, "\"phaseA_max_ns\":%0d,\"phaseA_min_ns\":%0d,\"phaseA_jit_ns\":%0d,",
              a_max * CLK_NS, a_min * CLK_NS, a_jit * CLK_NS);
      $fwrite(js, "\"phaseB_max_ns\":%0d,\"phaseB_min_ns\":%0d,\"phaseB_jit_ns\":%0d,",
              b_max * CLK_NS, b_min * CLK_NS, (b_max - b_min) * CLK_NS);
      $fwrite(js, "\"gmii_frame_gap_max_cyc\":%0d,\"gmii_frame_gap_min_cyc\":%0d,\"gmii_frames\":%0d,",
              gmii_frame_gap_max, gmii_frame_gap_min, gmii_seen);
      $fwrite(js, "\"bag_us\":%0d,\"bag_cyc\":%0d,\"vl_gap_min_cyc\":%0d,\"vl_gap_max_cyc\":%0d,\"vl_bag_viol\":%0d,",
              BAG_US, BAG_CYC, vmin, vmax, nviol);
      $fwrite(js, "\"sfd_frames_a\":%0d,\"sfd_frames_b\":%0d,",
              mon_a.nfr, mon_b.nfr);
      $fwrite(js, "\"deliver\":%0d,\"submit\":%0d,\"drop\":%0d}\n",
              dut.u_rx.deliver_cnt, dut.u_tx.submit_cnt, dut.u_tx.drop_cnt);
      $fclose(js);
    end

    if (errors == 0)
      $display("T93 PASS checks=%0d A_max_ns=%0d B_max_ns=%0d A_jit_ns=%0d",
               checks, a_max * CLK_NS, b_max * CLK_NS, a_jit * CLK_NS);
    else
      $display("T93 FAIL errors=%0d checks=%0d", errors, checks);
    $finish;
  end
endmodule
