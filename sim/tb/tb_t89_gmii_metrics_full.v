// T89 — GMII 指标场（新增系统场，非原矩阵）。IF_MODE=2 公开端口。
// 必测：TX 时延(min/max/6VL)、RX 时延、32VL 抖动 max-min。
// 可选 128VL 吞吐：本轮未做（打印 NOT DONE）。
// 输出 t89_metrics.csv + t89_verilog_summary.json（cwd=OutDir）。
// Host 不用 BFM 单拍 ACK：与 T88 一样轮询 host_ack（避免复位后首拍漏 ACK）。
`timescale 1 ns / 1 ps
module tb_t89_gmii_metrics_full;
  reg clk = 0, reset = 1;
  always #4 clk = ~clk;
  integer cycle = 0;
  always @(posedge clk) cycle <= cycle + 1;

  wire [7:0] tx_a, tx_b;
  wire dv_a, dv_b;
  reg loop_en = 0; // 复位/INIT 期间勿回环，避免 X 灌 RX
  wire [7:0] rx_data = loop_en ? tx_a : 8'd0;
  wire       rx_valid = loop_en ? dv_a : 1'b0;

  reg host_cs = 0, host_we = 0;
  reg [15:0] host_addr = 0;
  reg [31:0] host_wdata = 0;
  wire [31:0] host_rdata;
  wire host_ack, host_irq;

  AFDX_top dut (
    .clk(clk), .reset(reset),
    .tx_data(tx_a), .tx_valid(dv_a), .tx_ready(),
    .rx_data(rx_data), .rx_valid(rx_valid), .rx_ready(1'b0), .rx_error(1'b0),
    .tx_data_b(tx_b), .tx_valid_b(dv_b), .tx_ready_b(),
    .rx_data_b(8'd0), .rx_valid_b(1'b0), .rx_ready_b(1'b0), .rx_error_b(1'b0),
    .host_cs(host_cs), .host_we(host_we), .host_addr(host_addr), .host_wdata(host_wdata),
    .host_rdata(host_rdata), .host_ack(host_ack), .host_irq(host_irq),
    .pps_in(1'b0), .pps_out(), .rtc_time_us(), .dbg_frame_event()
  );

  integer errors = 0, checks = 0;
  integer csv, sumfd;
  integer max_tx = 0, max_rx = 0, max_jit = 0;
  integer min_vl_lat [0:31], max_vl_lat [0:31];
  integer commit_t, sof_t, eof_t, rx_ready_t;
  integer i, waitc, base, n;
  reg [31:0] rd;

  localparam integer N32 = 32;
  localparam integer FRAMES_PER_VL = 3; // jitter samples/VL (was 2; only add samples)
  localparam integer BAG32 = 103500; // 828us @125MHz
  localparam integer JIT_BOUND_40SIG_US = 141;
  localparam integer JIT_BOUND_PROJ_US = 50;
  localparam integer P_RX = 5;
  localparam integer SHARE1 = 8305;
  localparam integer SHARE32 = 32724;
  // A3 6VL contention (contrast T13w: BAG=4000us, VL0-2 Lmax=1518/Plen=1471, VL3-5 Lmax=356)
  localparam integer A3_NVL = 6;
  localparam integer A3_BAG_US = 1000;
  localparam integer A3_PLEN = 256;
  localparam integer A3_LMAX = 303;

  task bad;
    input [8*100-1:0] why;
    begin if (errors < 40) $display("  [err] T89 %0s", why); errors = errors + 1; end
  endtask

  task host_write;
    input [15:0] addr; input [31:0] data;
    begin
      @(negedge clk); host_cs = 1; host_we = 1; host_addr = addr; host_wdata = data;
      n = 0; while (host_ack !== 1'b1 && n < 64) begin @(negedge clk); n = n + 1; end
      if (host_ack !== 1'b1) bad("host write ACK timeout");
      host_cs = 0; host_we = 0;
    end
  endtask
  task host_read;
    input [15:0] addr; output [31:0] data;
    begin
      @(negedge clk); host_cs = 1; host_we = 0; host_addr = addr;
      n = 0; while (host_ack !== 1'b1 && n < 64) begin @(negedge clk); n = n + 1; end
      if (host_ack !== 1'b1) bad("host read ACK timeout");
      data = host_rdata; host_cs = 0;
    end
  endtask

  function [10:0] mix_bucket;
    input [15:0] vlid, seed;
    reg [15:0] x;
    begin
      x = vlid + seed + 16'h9E37; x = x ^ (x >> 7); x = x * 16'h9E37; x = x ^ (x >> 9);
      mix_bucket = x & 11'h7FF;
    end
  endfunction

  task csv_row;
    input [8*16-1:0] phase;
    input integer vl, frame, t0, t1, t2, t3;
    begin
      $fwrite(csv, "%0s,%0d,%0d,%0d,%0d,%0d,%0d\n", phase, vl, frame, t0, t1, t2, t3);
    end
  endtask

  task wait_init;
    begin
      waitc = 0; host_read(16'h000C, rd);
      while (rd[13] !== 1'b1 && waitc < 40000) begin host_read(16'h000C, rd); waitc = waitc + 1; end
      if (rd[13] !== 1'b1) bad("INIT_DONE");
    end
  endtask

  // nvl TX VLs on ports 16..; one RX port P_RX; BAG in 0201 (us<<8); share @0480
  task cfg_nvl;
    input integer nvl, bag_us, plen, lmax, share;
    integer v;
    begin
      host_write(16'h0008, 32'h0000_2000);
      host_write(16'h0060, 32'h1234_2001);
      host_write(16'h0064, 32'h0A00_0001);
      host_write(16'h0070, 32'h0000_0142);
      for (v = 0; v < nvl; v = v + 1) begin
        // Port table for TX port 16+v (same as T42); ports 6/7 are mgmt SAPs.
        host_write(16'h7D80 + 4 * (16 + v) + 3, 32'd1);
        host_write(16'h7D80 + 4 * (16 + v), 32'h8000_C000 | v);
        host_write(16'h0204 + 5 * v, (16 + v) << 16);
        host_write(16'h0203 + 5 * v, 32'hE000_0001);
        host_write(16'h0202 + 5 * v, 32'h1388_C000);
        host_write(16'h0201 + 5 * v, bag_us << 8);
        host_write(16'h0480 + v, share);
        host_write(16'h0200 + 5 * v, 32'h8000_0001 | (lmax << 12)); // valid + LMAX + net A
        // Distinct VL_RX index per VLID — sharing 0x100 polluted IC PSN across VLs.
        host_write(16'h3D80 + (mix_bucket(16'h0100 + v, 16'h172D) << 1),
                   {3'd0, 1'b1, 16'h0100 + v[15:0], 12'h100 + v[11:0]});
      end
      host_write(16'h0078, 32'h0000_172D);
      host_write(16'h007C, 32'h0000_AB61);
      host_write(16'h0080, 32'h1);
      host_write(16'h1F80, 32'hF500_0000 | (P_RX << 12) | lmax);
      host_write(16'h1F81, {16'd0, 16'h0100});
      host_write(16'h7D80 + 4 * P_RX, 32'h8004_0000);
      host_write(16'h7D81 + 4 * P_RX, 32'h0000_1388);
      host_write(16'h7D82 + 4 * P_RX, 32'd0);
      host_write(16'h7D83 + 4 * P_RX, 32'd64);
      host_write(16'h0014, 32'h1);
      host_write(16'h0008, 32'h051F);
      // TX timing only — keep loopback off so IC/PSN stay clean for any later RX.
      loop_en = 0;
    end
  endtask

  task submit_and_time;
    input [8*16-1:0] phase;
    input integer vl, plen;
    integer bi, words, waited, port;
    reg [7:0] pb;
    begin
      port = 16 + vl;
      host_read(16'h0074, rd);
      if (rd[4] !== 1'b1) bad("no TX block");
      base = 16'h8800 + (rd[3:0] << 9);
      words = (plen + 3) / 4;
      @(negedge clk); host_cs = 1; host_we = 1;
      for (bi = 0; bi < words; bi = bi + 1) begin
        pb = (vl * 17 + bi) & 8'hFF;
        host_addr = base + bi;
        host_wdata = {pb, pb + 8'd1, pb + 8'd2, pb + 8'd3};
        @(negedge clk);
        if (host_ack !== 1'b1) bad("PMEM ack");
      end
      host_cs = 0; host_we = 0;
      commit_t = cycle;
      host_write(16'h8280 + port, plen);
      sof_t = 0; eof_t = 0; waited = 0;
      while (!dv_a && waited < 500000) begin @(posedge clk); waited = waited + 1; end
      sof_t = cycle;
      while (dv_a && waited < 1000000) begin @(posedge clk); waited = waited + 1; end
      eof_t = cycle;
      if (sof_t == 0 || eof_t <= sof_t) bad("TX timing capture fail");
      if (eof_t - commit_t > 250000) bad("TX latency >2ms");
      if (eof_t - commit_t > max_tx) max_tx = eof_t - commit_t;
      csv_row(phase, vl, 0, commit_t, sof_t, eof_t, 0);
      checks = checks + 1;
    end
  endtask

  initial begin
    csv = $fopen("t89_metrics.csv", "w");
    if (!csv) csv = $fopen("sim/out/t89_metrics.csv", "w");
    if (!csv) begin $display("T89 FAIL: cannot open csv"); $finish; end
    $fwrite(csv, "phase,vl,frame,t_commit,t_sof,t_eof,t_rx_ready\n");

    repeat (8) @(negedge clk); reset = 0;
    wait_init();

    // B RX latency FIRST: before any TX advances SN / pollutes IC.
    // Re-init clears IC PSN; if TX SN already >1 → first_fail (seen prior run).
    begin : rxlat
      integer msg_before, polls2, guard, bi;
      reg [7:0] pb;
      host_write(16'h0008, 32'h0000_2000);
      host_write(16'h0060, 32'h1234_2001);
      host_write(16'h0064, 32'h0A00_0001);
      host_write(16'h0070, 32'h0000_0142);
      host_write(16'h7D83, 32'h0000_0001);
      host_write(16'h7D80, 32'h8000_C000);
      host_write(16'h0204, 32'h0000_0000);
      host_write(16'h0203, 32'hE000_0001);
      host_write(16'h0202, 32'h1388_C000);
      host_write(16'h0201, 32'h0003_E800); // BAG 1000us
      host_write(16'h0480, SHARE1);
      host_write(16'h0200, 32'h8004_F003); // A+B
      host_write(16'h0078, 32'h0000_172D);
      host_write(16'h007C, 32'h0000_AB61);
      host_write(16'h3D80 + (mix_bucket(16'h0100, 16'h172D) << 1),
                 {3'd0, 1'b1, 16'h0100, 12'h100});
      host_write(16'h0080, 32'h1);
      host_write(16'h1F80, 32'hF500_0000 | (P_RX << 12) | 32'd1518);
      host_write(16'h1F81, {16'd0, 16'h0100});
      host_write(16'h7D80 + 4 * P_RX, 32'h8004_0000);
      host_write(16'h7D81 + 4 * P_RX, 32'h0000_1388);
      host_write(16'h7D82 + 4 * P_RX, 32'd0);
      host_write(16'h7D83 + 4 * P_RX, 32'd16);
      host_write(16'h0014, 32'h1);
      host_write(16'h0008, 32'h051F);
      loop_en = 1;
      guard = 0; host_read(16'h8480 + P_RX, rd);
      while (rd !== 32'd0 && guard < 64) begin
        host_read(16'h8180 + P_RX, rd);
        host_write(16'h8380 + P_RX, 32'd0);
        repeat (40) @(negedge clk);
        host_read(16'h8480 + P_RX, rd); guard = guard + 1;
      end
      host_read(16'h8480 + P_RX, rd); msg_before = rd;
      host_read(16'h0074, rd);
      if (rd[4] !== 1'b1) bad("RX probe no TX block");
      base = 16'h8800 + (rd[3:0] << 9);
      @(negedge clk); host_cs = 1; host_we = 1;
      for (bi = 0; bi < 8; bi = bi + 1) begin
        pb = (bi * 17) & 8'hFF;
        host_addr = base + bi;
        host_wdata = {pb, pb + 8'd1, pb + 8'd2, pb + 8'd3};
        @(negedge clk);
      end
      host_cs = 0; host_we = 0;
      commit_t = cycle;
      host_write(16'h8280, 32'd32);
      waitc = 0;
      while (!dv_a && waitc < 500000) begin @(posedge clk); waitc = waitc + 1; end
      sof_t = cycle;
      while (dv_a && waitc < 1000000) begin @(posedge clk); waitc = waitc + 1; end
      eof_t = cycle;
      polls2 = 0; host_read(16'h8480 + P_RX, rd);
      while (rd <= msg_before && polls2 < 400000) begin
        host_read(16'h8480 + P_RX, rd); polls2 = polls2 + 1;
      end
      rx_ready_t = cycle;
      if (rd <= msg_before) bad("RX no deliver");
      else begin
        if (rx_ready_t - eof_t > 250000) bad("RX latency >2ms");
        if (rx_ready_t - eof_t > max_rx) max_rx = rx_ready_t - eof_t;
      end
      csv_row("rx_lat", 0, 0, 0, 0, eof_t, rx_ready_t);
      checks = checks + 1;
      loop_en = 0;
    end

    // A1 min frame (TX only, no loopback)
    cfg_nvl(1, 1000, 17, 79, SHARE1);
    submit_and_time("tx_min", 0, 17);

    // A2 max frame
    host_write(16'h0008, 32'h0000_2000);
    cfg_nvl(1, 1000, 1471, 1518, SHARE1);
    submit_and_time("tx_max", 0, 1471);

    // A3 6 VL (not T13w config — print both for card contrast)
    $display("T89_6VL_CFG nvl=%0d bag_us=%0d plen=%0d lmax=%0d share=%0d (contrast T13w: bag_us=4000 vl0-2 lmax=1518/plen=1471 vl3-5 lmax=356)",
             A3_NVL, A3_BAG_US, A3_PLEN, A3_LMAX, SHARE1);
    host_write(16'h0008, 32'h0000_2000);
    cfg_nvl(A3_NVL, A3_BAG_US, A3_PLEN, A3_LMAX, SHARE1);
    for (i = 0; i < A3_NVL; i = i + 1) submit_and_time("tx_6vl", i, A3_PLEN);

    // C 32 VL jitter (TX commit→eof range per VL); >=3 frames/VL
    host_write(16'h0008, 32'h0000_2000);
    cfg_nvl(N32, 828, 256, 303, SHARE32);
    for (i = 0; i < N32; i = i + 1) begin
      min_vl_lat[i] = 2147483647; max_vl_lat[i] = 0;
    end
    begin : jit_rounds
      integer round;
      for (round = 0; round < FRAMES_PER_VL; round = round + 1) begin
        if (round > 0) repeat (BAG32 + 5000) @(negedge clk);
        for (i = 0; i < N32; i = i + 1) begin
          submit_and_time("jit32", i, 256);
          if (eof_t - commit_t < min_vl_lat[i]) min_vl_lat[i] = eof_t - commit_t;
          if (eof_t - commit_t > max_vl_lat[i]) max_vl_lat[i] = eof_t - commit_t;
        end
      end
    end
    max_jit = 0;
    for (i = 0; i < N32; i = i + 1) begin
      if (max_vl_lat[i] - min_vl_lat[i] > max_jit)
        max_jit = max_vl_lat[i] - min_vl_lat[i];
    end
    if (max_jit > JIT_BOUND_40SIG_US * 125) bad("jitter exceeds 40+Sigma bound");
    $display("T89_JITTER max_cyc=%0d max_ns=%0d max_us=%0d bound_40sig_us=%0d bound_proj_us=%0d frames_per_vl=%0d",
             max_jit, max_jit * 8, (max_jit * 8) / 1000, JIT_BOUND_40SIG_US, JIT_BOUND_PROJ_US, FRAMES_PER_VL);

    $display("T89_128VL_THROUGHPUT NOT DONE");

    $fclose(csv);
    sumfd = $fopen("t89_verilog_summary.json", "w");
    if (!sumfd) sumfd = $fopen("sim/out/t89_verilog_summary.json", "w");
    $fwrite(sumfd,
      "{\"max_tx_cyc\":%0d,\"max_rx_cyc\":%0d,\"max_jit_cyc\":%0d,\"max_tx_ns\":%0d,\"max_rx_ns\":%0d,\"max_jit_ns\":%0d,\"max_tx_us\":%0d,\"max_rx_us\":%0d,\"max_jit_us\":%0d,\"bound_40sig_us\":%0d,\"bound_proj_us\":%0d,\"frames_per_vl\":%0d,\"errors\":%0d,\"checks\":%0d}\n",
      max_tx, max_rx, max_jit, max_tx * 8, max_rx * 8, max_jit * 8,
      (max_tx * 8) / 1000, (max_rx * 8) / 1000, (max_jit * 8) / 1000,
      JIT_BOUND_40SIG_US, JIT_BOUND_PROJ_US, FRAMES_PER_VL, errors, checks);
    $fclose(sumfd);

    if (errors == 0 && max_tx <= 250000 && max_rx <= 250000)
      $display("T89 GMII METRICS PASS checks=%0d max_tx_ns=%0d max_rx_ns=%0d max_jit_ns=%0d (us: %0d/%0d/%0d)",
               checks, max_tx * 8, max_rx * 8, max_jit * 8,
               (max_tx * 8) / 1000, (max_rx * 8) / 1000, (max_jit * 8) / 1000);
    else
      $display("T89 GMII METRICS FAIL errors=%0d", errors);
    $finish;
  end

  initial begin #800_000_000; $display("T89 GMII METRICS FAIL: timeout"); $finish; end
endmodule
