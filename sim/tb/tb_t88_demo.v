// T88 — 系统演示场（新增，非原矩阵）。本轮步骤 1–4；5–8 未做。
// 公开端口；AFDX_top 默认 IF_MODE=2；禁止层次引用。
// 配置/抓帧对齐已过的 T88b；载荷金标：sim/vec/t88b_payload32.hex。
`timescale 1 ns / 1 ps
module tb_t88_demo;
  reg clk = 0, reset = 1;
  always #4 clk = ~clk;

  wire [7:0] tx_data, tx_data_b;
  wire tx_valid, tx_valid_b, tx_ready, tx_ready_b;
  reg disconnect_a = 0, inject_a = 0;
  reg [7:0] inj_data = 0;
  reg inj_valid = 0;
  wire [7:0] rx_data = inject_a ? inj_data : tx_data;
  wire       rx_valid = disconnect_a ? 1'b0 : (inject_a ? inj_valid : tx_valid);
  wire [7:0] rx_data_b = tx_data_b;
  wire       rx_valid_b = tx_valid_b;

  reg host_cs = 0, host_we = 0;
  reg [15:0] host_addr = 0;
  reg [31:0] host_wdata = 0;
  wire [31:0] host_rdata;
  wire host_ack, host_irq;

  AFDX_top dut (
    .clk(clk), .reset(reset),
    .tx_data(tx_data), .rx_data(rx_data), .tx_valid(tx_valid), .rx_valid(rx_valid),
    .tx_ready(tx_ready), .rx_ready(1'b0),
    .tx_data_b(tx_data_b), .tx_valid_b(tx_valid_b), .tx_ready_b(tx_ready_b),
    .rx_data_b(rx_data_b), .rx_valid_b(rx_valid_b), .rx_ready_b(1'b0),
    .rx_error(1'b0), .rx_error_b(1'b0),
    .host_cs(host_cs), .host_we(host_we), .host_addr(host_addr), .host_wdata(host_wdata),
    .host_rdata(host_rdata), .host_ack(host_ack), .host_irq(host_irq),
    .pps_in(1'b0), .pps_out(), .rtc_time_us(), .dbg_frame_event()
  );

  localparam integer P_RX = 5;
  localparam [11:0] VL_RX = 12'h100;
  localparam [15:0] VLID0 = 16'h0100;
  localparam [15:0] VLID1 = 16'h0101; // hash only (demo multi-VL cfg); traffic uses VLID0
  localparam [15:0] PT_RX = 16'h7D80 + 4 * P_RX;
  // BAG register is microseconds; scheduler multiplies by CYCLES_PER_US (125).
  localparam integer BAG_US = 1000;
  localparam integer BAG_CYC = BAG_US * 125;

  reg [7:0] exp_pl [0:31];
  reg [7:0] cap_a [0:2047], cap_b [0:2047];
  integer na = 0, nb = 0, frame_a = 0, frame_b = 0;
  integer errors = 0, checks = 0, steps_ok = 0;
  integer waitc, i, base_addr, polls, msg0, crc0, unconf0, lmax0, rmdup0, e0;
  reg [31:0] rd, w, cnow, unow;
  reg prev_a = 0, prev_b = 0;
  integer capturing = 0;

  function [10:0] mix_bucket;
    input [15:0] vlid, seed; input table_id;
    reg [15:0] x;
    begin
      x = vlid + seed + (table_id ? 16'h1F5B : 16'h9E37);
      x = x ^ (x >> 7); x = x * (table_id ? 16'h45D9 : 16'h9E37); x = x ^ (x >> 9);
      mix_bucket = x & 11'h7FF;
    end
  endfunction
  function [15:0] hash_addr;
    input [15:0] vlid, seed; input table_id, way;
    begin
      hash_addr = 16'h3D80 + ({4'd0, table_id} << 12) + (mix_bucket(vlid, seed, table_id) << 1) + way;
    end
  endfunction

  task bad; input [8*96-1:0] why;
    begin errors = errors + 1; if (errors < 40) $display("  [err] T88 t=%0t %0s", $time, why); end
  endtask
  task chk; input cond; input [8*80-1:0] why;
    begin checks = checks + 1; if (cond !== 1'b1) bad(why); end
  endtask
  task host_write;
    input [15:0] addr; input [31:0] data; integer n;
    begin
      @(negedge clk); host_cs = 1; host_we = 1; host_addr = addr; host_wdata = data;
      n = 0; while (host_ack !== 1'b1 && n < 64) begin @(negedge clk); n = n + 1; end
      if (host_ack !== 1'b1) bad("host write ACK timeout");
      host_cs = 0; host_we = 0;
    end
  endtask
  task host_read;
    input [15:0] addr; output [31:0] data; integer n;
    begin
      @(negedge clk); host_cs = 1; host_we = 0; host_addr = addr;
      n = 0; while (host_ack !== 1'b1 && n < 64) begin @(negedge clk); n = n + 1; end
      if (host_ack !== 1'b1) bad("host read ACK timeout");
      data = host_rdata; host_cs = 0;
    end
  endtask

  always @(posedge clk) if (!reset && capturing) begin
    if (tx_valid) begin
      if (na < 2048) cap_a[na] = tx_data;
      na = na + 1;
    end else if (prev_a && na > 0) frame_a = frame_a + 1;
    if (tx_valid_b) begin
      if (nb < 2048) cap_b[nb] = tx_data_b;
      nb = nb + 1;
    end else if (prev_b && nb > 0) frame_b = frame_b + 1;
    prev_a = tx_valid; prev_b = tx_valid_b;
  end

  // Enter CFG mode, program 1 TX VL (A+B) + 2 RX hash keys, exit to run.
  task cfg_base;
    input integer lmax_val;
    begin
      host_write(16'h0008, 32'h0000_2000);
      host_write(16'h0060, 32'h1234_2001);
      host_write(16'h0064, 32'h0A00_0001);
      host_write(16'h0070, 32'h0000_0142);
      host_write(16'h7D83, 32'h0000_0001);
      host_write(16'h7D80, 32'h8000_C000);
      host_write(16'h0204, 32'h0000_0000);
      host_write(16'h0203, 32'hE000_0001);
      host_write(16'h0202, 32'h1388_C000);
      host_write(16'h0201, 32'h0003_E800);
      host_write(16'h0480, BAG_US); // BAG μs → scheduler cycles
      host_write(16'h0200, 32'h8004_F003); // A+B, LMAX field in word
      host_write(16'h0078, 32'h0000_172D);
      host_write(16'h007C, 32'h0000_AB61);
      host_write(hash_addr(VLID0, 16'h172D, 1'b0, 1'b0), {3'd0, 1'b1, VLID0, VL_RX});
      host_write(hash_addr(VLID1, 16'h172D, 1'b0, 1'b0), {3'd0, 1'b1, VLID1, VL_RX});
      host_write(16'h0080, 32'h1);
      host_write(16'h1F80, 32'hF500_0000 | (P_RX << 12) | lmax_val);
      host_write(16'h1F81, {16'd0, VLID0});
      host_write(PT_RX, 32'h8004_0000);
      host_write(PT_RX + 1, 32'h0000_1388);
      host_write(PT_RX + 2, 32'd0);
      host_write(PT_RX + 3, 32'd16);
      host_write(16'h0014, 32'h1);
      host_write(16'h0008, 32'h051F);
    end
  endtask

  task submit32;
    integer bi;
    begin
      host_read(16'h0074, rd);
      chk(rd[4] === 1'b1, "TX block open");
      base_addr = 16'h8800 + (rd[3:0] << 9);
      @(negedge clk); host_cs = 1; host_we = 1;
      for (bi = 0; bi < 8; bi = bi + 1) begin
        host_addr = base_addr + bi;
        host_wdata = {exp_pl[4*bi], exp_pl[4*bi+1], exp_pl[4*bi+2], exp_pl[4*bi+3]};
        @(negedge clk);
        if (host_ack !== 1'b1) bad("PMEM ack");
      end
      host_cs = 0; host_we = 0;
      host_write(16'h8280, 32'd32);
    end
  endtask

  task wait_bag;
    begin repeat (BAG_CYC + 2000) @(negedge clk); end
  endtask

  // MSG_CNT @0x8480+p is queue occupancy, not a cumulative counter.
  // Host path: read PORT_DESC @0x8180+p then MSG_RD @0x8380+p (see tb_s1/t86).
  task rx_pop;
    begin
      host_read(16'h8180 + P_RX, rd); // side-effect: clear fresh/ovf
      host_write(16'h8380 + P_RX, 32'd0);
      repeat (80) @(negedge clk);
    end
  endtask

  task msg_rd_all;
    integer guard;
    begin
      guard = 0;
      host_read(16'h8480 + P_RX, rd);
      while (rd !== 32'd0 && guard < 32) begin
        rx_pop();
        polls = 0;
        host_read(16'h8480 + P_RX, rd);
        while (rd !== 32'd0 && polls < 2000) begin
          host_read(16'h8480 + P_RX, rd); polls = polls + 1;
        end
        guard = guard + 1;
      end
    end
  endtask

  task wait_msg_ge;
    input integer expect_cnt;
    begin
      polls = 0; host_read(16'h8480 + P_RX, rd);
      while (rd < expect_cnt && polls < 500000) begin
        host_read(16'h8480 + P_RX, rd); polls = polls + 1;
      end
      chk(rd >= expect_cnt, "MSG_CNT");
    end
  endtask

  task wait_rm_dup_ge;
    input integer expect_cnt;
    begin
      polls = 0; host_read(16'h004C, rd);
      while (rd < expect_cnt && polls < 200000) begin
        host_read(16'h004C, rd); polls = polls + 1;
      end
      chk(rd >= expect_cnt, "RM dup >=1");
    end
  endtask

  task capture_ab;
    begin
      wait_bag();
      na = 0; nb = 0; frame_a = 0; frame_b = 0; prev_a = 0; prev_b = 0; capturing = 1;
      submit32();
      waitc = 0;
      while ((frame_a < 1 || frame_b < 1) && waitc < 500000) begin
        @(negedge clk); waitc = waitc + 1;
      end
      capturing = 0;
      chk(frame_a >= 1, "captured A frame");
      chk(frame_b >= 1, "TX B also");
    end
  endtask

  task capture_one_a;
    begin
      wait_bag();
      na = 0; nb = 0; frame_a = 0; frame_b = 0; prev_a = 0; prev_b = 0; capturing = 1;
      submit32();
      waitc = 0;
      while (frame_a < 1 && waitc < 500000) begin @(negedge clk); waitc = waitc + 1; end
      capturing = 0;
      chk(frame_a >= 1, "captured A frame");
    end
  endtask

  task inject_cap;
    input integer flen;
    integer bi;
    begin
      waitc = 0;
      while ((tx_valid || tx_valid_b) && waitc < 20000) begin @(negedge clk); waitc = waitc + 1; end
      repeat (16) @(negedge clk);
      inject_a = 1; inj_valid = 0;
      for (bi = 0; bi < flen; bi = bi + 1) begin
        @(negedge clk); inj_data = cap_a[bi]; inj_valid = 1;
      end
      @(negedge clk); inj_valid = 0; inject_a = 0;
      repeat (2000) @(negedge clk);
    end
  endtask

  integer fd, code, bi;
  reg [7:0] hb;
  initial begin
    fd = $fopen("vec/t88b_payload32.hex", "r");
    if (fd == 0) fd = $fopen("sim/vec/t88b_payload32.hex", "r");
    if (fd == 0) begin $display("T88 DEMO FAIL: missing payload hex"); $finish; end
    for (bi = 0; bi < 32; bi = bi + 1) begin
      code = $fscanf(fd, "%h\n", hb);
      if (code != 1) begin $display("T88 DEMO FAIL: hex short"); $finish; end
      exp_pl[bi] = hb;
    end
    $fclose(fd);

    repeat (8) @(negedge clk); reset = 0;

    // ===== step 1: INIT + CFG =====
    e0 = errors;
    waitc = 0; host_read(16'h000C, rd);
    while (rd[13] !== 1'b1 && waitc < 40000) begin host_read(16'h000C, rd); waitc = waitc + 1; end
    chk(rd[13] === 1'b1, "INIT_DONE");
    host_read(16'h0000, rd); chk(rd === 32'hAF07_1000, "REG_ID");
    host_read(16'h0004, rd); chk(rd === 32'h0004_0000, "REG_REV");
    cfg_base(32'd1518);
    host_read(16'h0008, rd); chk(rd[0] === 1'b1, "CTL run bit");
    if (errors == e0) begin steps_ok = steps_ok + 1; $display("[DEMO step 1] PASS"); end
    else $display("[DEMO step 1] NOT_PASS");

    // ===== step 2: dual-net + RM =====
    e0 = errors;
    msg_rd_all();
    host_read(16'h004C, rd); rmdup0 = rd;
    capture_ab();
    wait_msg_ge(32'd1);
    wait_rm_dup_ge(rmdup0 + 1);
    if (errors == e0) begin steps_ok = steps_ok + 1; $display("[DEMO step 2] PASS"); end
    else $display("[DEMO step 2] NOT_PASS");
    msg_rd_all();

    // ===== step 3: A down (rx_valid=0), B-only TX =====
    e0 = errors;
    host_write(16'h0008, 32'h0000_2000);
    host_write(16'h0200, 32'h8004_F002); // B only
    host_write(16'h0008, 32'h051F);
    disconnect_a = 1;
    wait_bag();
    submit32();
    wait_msg_ge(32'd1);
    host_read(16'h8480 + P_RX, rd);
    chk(rd === 32'd1, "exactly +1 via B");
    disconnect_a = 0;
    host_write(16'h0008, 32'h0000_2000);
    host_write(16'h0200, 32'h8004_F003); // restore A+B
    host_write(16'h0008, 32'h051F);
    if (errors == e0) begin steps_ok = steps_ok + 1; $display("[DEMO step 3] PASS"); end
    else $display("[DEMO step 3] NOT_PASS");
    msg_rd_all();

    // ===== step 4: four rejects =====
    // Capture on A-only TX so B does not leave a late RM copy after MSG_RD.
    e0 = errors;
    host_write(16'h0008, 32'h0000_2000);
    host_write(16'h0200, 32'h8004_F001); // A only for capture/inject
    host_write(16'h0008, 32'h051F);

    // 4a bad FCS (T88b S3: baseline MSG_CNT unchanged + CRC +1)
    capture_one_a();
    wait_msg_ge(32'd1);
    repeat (4000) @(negedge clk);
    msg_rd_all();
    host_read(16'h8480 + P_RX, rd); msg0 = rd;
    host_read(16'h0117, rd); crc0 = rd;
    chk(na >= 72, "cap len");
    cap_a[na - 1] = cap_a[na - 1] ^ 8'hFF;
    inject_cap(na);
    host_read(16'h0117, rd); chk(rd === crc0 + 1, "4a CRC +1");
    host_read(16'h8480 + P_RX, rd); chk(rd === msg0, "4a no deliver");

    // 4b wrong VLID (FCS breaks → CRC or unconf; no new deliver)
    capture_one_a();
    wait_msg_ge(32'd1);
    repeat (4000) @(negedge clk);
    msg_rd_all();
    host_read(16'h8480 + P_RX, rd); msg0 = rd;
    host_read(16'h0117, rd); crc0 = rd;
    host_read(16'h0040, rd); unconf0 = rd;
    if (na > 22) begin
      cap_a[8 + 12] = 8'h0E;
      cap_a[8 + 13] = 8'hEE;
    end
    inject_cap(na);
    host_read(16'h8480 + P_RX, rd); chk(rd === msg0, "4b no deliver");
    host_read(16'h0117, cnow);
    host_read(16'h0040, unow);
    chk((cnow > crc0) || (unow > unconf0), "4b reject counter");

    // 4c over Lmax (payload/wire above RX LMAX 64)
    host_write(16'h0008, 32'h0000_2000);
    host_write(16'h1F80, 32'hF500_0000 | (P_RX << 12) | 32'd64);
    host_write(16'h0008, 32'h051F);
    host_read(16'h0044, rd); lmax0 = rd;
    msg_rd_all();
    host_read(16'h8480 + P_RX, rd); msg0 = rd;
    wait_bag();
    submit32();
    waitc = 0;
    host_read(16'h0044, rd);
    while (rd < lmax0 + 1 && waitc < 200000) begin
      host_read(16'h0044, rd); waitc = waitc + 1;
    end
    host_read(16'h8480 + P_RX, rd); chk(rd === msg0, "4c no deliver");
    host_read(16'h0044, rd); chk(rd >= lmax0 + 1, "4c LMAX +1");

    // 4d RM/IC reject replay of same captured frame
    host_write(16'h0008, 32'h0000_2000);
    host_write(16'h1F80, 32'hF500_0000 | (P_RX << 12) | 32'd1518);
    host_write(16'h0008, 32'h051F);
    capture_one_a();
    wait_msg_ge(32'd1);
    repeat (4000) @(negedge clk);
    // Keep delivered frame in queue as baseline; replay must not increase MSG_CNT
    host_read(16'h8480 + P_RX, rd); msg0 = rd;
    host_read(16'h004C, rd); rmdup0 = rd;
    host_read(16'h0048, rd); unconf0 = rd; // IC drop baseline
    inject_cap(na);
    host_read(16'h8480 + P_RX, rd); chk(rd === msg0, "4d no deliver dup");
    host_read(16'h004C, rd);
    host_read(16'h0048, unow);
    chk((rd >= rmdup0 + 1) || (unow >= unconf0 + 1), "4d RM dup or IC reject");

    host_write(16'h0008, 32'h0000_2000);
    host_write(16'h0200, 32'h8004_F003); // restore A+B
    host_write(16'h0008, 32'h051F);

    if (errors == e0) begin steps_ok = steps_ok + 1; $display("[DEMO step 4] PASS"); end
    else $display("[DEMO step 4] NOT_PASS");

    $display("[DEMO steps 5-8] NOT DONE");
    if (steps_ok == 4 && errors == 0)
      $display("T88 DEMO PASS checks=%0d steps_ok=4 (1-4 only)", checks);
    else
      $display("T88 DEMO FAIL errors=%0d checks=%0d steps_ok=%0d", errors, checks, steps_ok);
    $finish;
  end

  initial begin #120_000_000; $display("T88 DEMO FAIL: timeout"); $finish; end
endmodule
