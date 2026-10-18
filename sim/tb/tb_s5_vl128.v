// S5 — 128 TX VL, phased at 1 ms BAG through net_model.
// The shared scoreboard checks both networks, payload, per-VL SN/order,
// BAG interval, 50 us phase drift, and exact frame/forward counts.
`timescale 1 ns / 1 ps
module tb_s5_vl128_core #(parameter integer IF_MODE = 0,
                           parameter integer NUM_ROUNDS = 2,
                           parameter integer TEST_ID = 29);
  localparam integer DELAY_US = 10;
  localparam integer NVL = 128;
  // PHY ordinary traffic must not select the management SAP ports 6/7.
  // Keep VL IDs and payload patterns independent of the host port mapping.
  localparam integer PORT_BASE = (IF_MODE == 2) ? 16 : 0;
  localparam integer LMAX = 64;
  localparam integer PLEN = 16;
  localparam integer BAG_US = 1000;
  localparam integer SHARE = 7047;
  localparam integer BAG_CYC = BAG_US * 125;
  // Project-internal target for the contest wording "tens of microseconds".
  // This is not a contest-issued exact threshold.
  localparam integer JIT_MAX = 50 * 125;
  // 60-byte minimum frame + 4-byte FCS + 8-byte preamble + 12-byte IFG.
  localparam integer WIRE_BYTES = 84;
  localparam integer WIRE_RATE_KBPS = NVL * WIRE_BYTES * 8 * 1000 / BAG_US;
  localparam integer EXPECTED_TOTAL = NUM_ROUNDS * NVL;

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

  AFDX_top #(.IF_MODE(IF_MODE), .FCS_MODE(2)) dut (
    .clk(clk), .reset(reset),
    .tx_data(tx_data), .rx_data(rx_data),
    .tx_valid(tx_valid), .rx_valid(rx_valid),
    .tx_ready(tx_ready), .rx_ready(rx_ready),
    .tx_data_b(tx_data_b), .tx_valid_b(tx_valid_b), .tx_ready_b(tx_ready_b),
    .rx_data_b(rx_data_b), .rx_valid_b(rx_valid_b), .rx_ready_b(rx_ready_b),
    .host_cs(host_cs), .host_we(host_we), .host_addr(host_addr),
    .host_wdata(host_wdata), .host_rdata(host_rdata), .host_ack(host_ack),
    .host_irq(host_irq),
    .pps_in(1'b0), .pps_out(), .rtc_time_us(), .dbg_frame_event(),
    .rx_error(1'b0), .rx_error_b(1'b0));

  afdx_host_bfm u_host (
    .clk(clk), .cs(host_cs), .we(host_we), .addr(host_addr), .wdata(host_wdata),
    .rdata(host_rdata), .ack(host_ack));

  afdx_net_model #(.IF_MODE(IF_MODE), .DELAY_US(DELAY_US), .DEPTH(128)) u_net (
    .clk(clk), .rst(reset),
    .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready),
    .tx_data_b(tx_data_b), .tx_valid_b(tx_valid_b), .tx_ready_b(tx_ready_b),
    .corrupt_a(1'b0), .corrupt_b(1'b0),
    .rx_data(rx_data), .rx_valid(rx_valid), .rx_ready(rx_ready),
    .rx_data_b(rx_data_b), .rx_valid_b(rx_valid_b), .rx_ready_b(rx_ready_b),
    .fwd_a(fwd_a), .fwd_b(fwd_b));

  integer errors, waitc, i, r, current_cycle, frames_seen, byte_cnt, vl_id;
  integer f_start_cyc, interval_cyc, max_jit, nsteady, max_gap, min_gap, sum_gap, max_phase_dev;
  integer phase_nom, phase_dev, expected_sn, expected_byte, check_i_a;
  integer f_last [0:NVL-1], f_cnt [0:NVL-1];
  integer vl_gap_min [0:NVL-1], vl_gap_sum [0:NVL-1];
  integer worst_vl_resid_cycles, worst_vl_resid_id, vl_resid_cycles;
  integer first_nom [0:NVL-1];
  integer t_start, startup_max_delay;
  integer phase_shift_cyc;
  integer sched_start_cyc, launch_latency, launch_lat_min, launch_lat_max;
  integer launch_lat_sum, launch_lat_count;
  reg in_frame;
  reg [7:0] frame_bytes [0:63];
  integer frames_seen_b, byte_cnt_b, vl_id_b;
  integer f_start_cyc_b, interval_cyc_b, max_jit_b, nsteady_b;
  integer max_gap_b, min_gap_b, sum_gap_b, max_phase_dev_b, phase_nom_b, phase_dev_b;
  integer expected_sn_b, expected_byte_b, check_i_b;
  integer f_last_b [0:NVL-1], f_cnt_b [0:NVL-1];
  integer startup_max_delay_b;
  reg in_frame_b;
  reg [7:0] frame_bytes_b [0:63];
  reg [31:0] rd;
  integer blk, j, tgt;
  localparam integer PHY_OFFSET = (IF_MODE==2)?8:0;
  integer phy_a,phy_b,timing_a,timing_b,phy_last_end_a=-1000,phy_last_end_b=-1000;
  reg [8*96-1:0] capture_name;


  always @(posedge clk) if (!reset) begin
    current_cycle <= current_cycle + 1;
    if (dut.u_sched.start_vld) sched_start_cyc = current_cycle;
  end

  wire byte_strobe = (IF_MODE != 0) ? tx_valid : (tx_valid && tx_ready);
  wire frame_active = (IF_MODE != 0) ? tx_valid : tx_ready;
  wire byte_strobe_b = (IF_MODE != 0) ? tx_valid_b : (tx_valid_b && tx_ready_b);
  wire frame_active_b = (IF_MODE != 0) ? tx_valid_b : tx_ready_b;

  always @(posedge clk) if (!reset) begin
    if (byte_strobe) begin
      if (!in_frame) begin
        in_frame <= 1'b1;
        f_start_cyc = current_cycle;
        if(IF_MODE==2 && current_cycle-phy_last_end_a-1<12)bad("PHY A IFG below12");
        launch_latency = f_start_cyc - sched_start_cyc;
        if (launch_latency < launch_lat_min) launch_lat_min = launch_latency;
        if (launch_latency > launch_lat_max) launch_lat_max = launch_latency;
        launch_lat_sum = launch_lat_sum + launch_latency;
        launch_lat_count = launch_lat_count + 1;
        byte_cnt = 0;
      end
      if(IF_MODE==2)begin
        $fwrite(phy_a,"%02x ",tx_data);
        if(byte_cnt<7 && tx_data!==8'h55)bad("PHY A preamble");
        if(byte_cnt==7 && tx_data!==8'hD5)bad("PHY A SFD");
      end
      if (byte_cnt>=PHY_OFFSET && byte_cnt<64+PHY_OFFSET) frame_bytes[byte_cnt-PHY_OFFSET] = tx_data;
      byte_cnt = byte_cnt + 1;
    end
    if (in_frame && !frame_active) begin
      in_frame <= 1'b0;
      frames_seen = frames_seen + 1;
      vl_id = frame_bytes[5];
      if (byte_cnt != 64+PHY_OFFSET) bad("net A frame length mismatch");
      if(IF_MODE==2)begin
        $fwrite(phy_a,"\n");$fwrite(timing_a,"%0d %0d\n",f_start_cyc,current_cycle-1);
        phy_last_end_a=current_cycle-1;
      end
      if (frame_bytes[4] !== 8'h01) bad("net A VLID high byte mismatch");
      if (frame_bytes[11] !== 8'h20) bad("net A IFID mismatch");
      if (vl_id < NVL) begin
        expected_sn = (f_cnt[vl_id] % 255) + 1;
        if (frame_bytes[59] !== expected_sn[7:0]) bad("net A SN/order mismatch");
        for (check_i_a = 0; check_i_a < PLEN; check_i_a = check_i_a + 1) begin
          case (check_i_a % 4)
            0: expected_byte = 8'hA5;
            1: expected_byte = vl_id & 8'hFF;
            2: expected_byte = 8'h00;
            default: expected_byte = check_i_a / 4;
          endcase
          if (frame_bytes[42 + check_i_a] !== expected_byte[7:0])
            bad("net A payload mismatch");
        end
        phase_nom = first_nom[vl_id] + f_cnt[vl_id] * BAG_CYC;
        phase_dev = f_start_cyc - phase_nom;
        if (phase_dev < 0) phase_dev = -phase_dev;
        if (phase_dev > max_phase_dev) max_phase_dev = phase_dev;
        if (f_cnt[vl_id] == 0) begin
          if (f_start_cyc < first_nom[vl_id])
            bad("first departure before VL phase");
          else if (f_start_cyc - first_nom[vl_id] > startup_max_delay)
            startup_max_delay = f_start_cyc - first_nom[vl_id];
        end else begin
          interval_cyc = f_start_cyc - f_last[vl_id];
          if (interval_cyc < BAG_CYC) bad("BAG early on wire");
          phase_dev = interval_cyc - BAG_CYC;
          if (phase_dev < 0) phase_dev = -phase_dev;
          if (phase_dev > max_jit) max_jit = phase_dev;
          if (interval_cyc > max_gap) max_gap = interval_cyc;
          if (interval_cyc < min_gap) min_gap = interval_cyc;
          sum_gap = sum_gap + interval_cyc;
          if (interval_cyc < vl_gap_min[vl_id]) vl_gap_min[vl_id] = interval_cyc;
          vl_gap_sum[vl_id] = vl_gap_sum[vl_id] + interval_cyc;
          nsteady = nsteady + 1;
        end
        f_last[vl_id] = f_start_cyc;
        f_cnt[vl_id] = f_cnt[vl_id] + 1;
      end else bad("unexpected VLID on wire");
    end
  end

  // A and B are checked independently; their payload/SN stream must match.
  always @(posedge clk) if (!reset) begin
    if (byte_strobe_b) begin
      if (!in_frame_b) begin
        in_frame_b <= 1'b1;
        f_start_cyc_b = current_cycle;
        if(IF_MODE==2 && current_cycle-phy_last_end_b-1<12)bad("PHY B IFG below12");
        byte_cnt_b = 0;
      end
      if(IF_MODE==2)begin
        $fwrite(phy_b,"%02x ",tx_data_b);
        if(byte_cnt_b<7 && tx_data_b!==8'h55)bad("PHY B preamble");
        if(byte_cnt_b==7 && tx_data_b!==8'hD5)bad("PHY B SFD");
      end
      if (byte_cnt_b>=PHY_OFFSET && byte_cnt_b<64+PHY_OFFSET) frame_bytes_b[byte_cnt_b-PHY_OFFSET] = tx_data_b;
      byte_cnt_b = byte_cnt_b + 1;
    end
    if (in_frame_b && !frame_active_b) begin
      in_frame_b <= 1'b0;
      frames_seen_b = frames_seen_b + 1;
      vl_id_b = frame_bytes_b[5];
      if (byte_cnt_b != 64+PHY_OFFSET) bad("net B frame length mismatch");
      if(IF_MODE==2)begin
        $fwrite(phy_b,"\n");$fwrite(timing_b,"%0d %0d\n",f_start_cyc_b,current_cycle-1);
        phy_last_end_b=current_cycle-1;
      end
      if (frame_bytes_b[4] !== 8'h01) bad("net B VLID high byte mismatch");
      if (frame_bytes_b[11] !== 8'h40) bad("net B IFID mismatch");
      if (vl_id_b < NVL) begin
        expected_sn_b = (f_cnt_b[vl_id_b] % 255) + 1;
        if (frame_bytes_b[59] !== expected_sn_b[7:0]) bad("net B SN/order mismatch");
        for (check_i_b = 0; check_i_b < PLEN; check_i_b = check_i_b + 1) begin
          case (check_i_b % 4)
            0: expected_byte_b = 8'hA5;
            1: expected_byte_b = vl_id_b & 8'hFF;
            2: expected_byte_b = 8'h00;
            default: expected_byte_b = check_i_b / 4;
          endcase
          if (frame_bytes_b[42 + check_i_b] !== expected_byte_b[7:0])
            bad("net B payload mismatch");
        end
        phase_nom_b = first_nom[vl_id_b] + f_cnt_b[vl_id_b] * BAG_CYC;
        phase_dev_b = f_start_cyc_b - phase_nom_b;
        if (phase_dev_b < 0) phase_dev_b = -phase_dev_b;
        if (phase_dev_b > max_phase_dev_b) max_phase_dev_b = phase_dev_b;
        if (f_cnt_b[vl_id_b] == 0) begin
          if (f_start_cyc_b < first_nom[vl_id_b])
            bad("net B first departure before VL phase");
          else if (f_start_cyc_b - first_nom[vl_id_b] > startup_max_delay_b)
            startup_max_delay_b = f_start_cyc_b - first_nom[vl_id_b];
        end else begin
          interval_cyc_b = f_start_cyc_b - f_last_b[vl_id_b];
          if (interval_cyc_b < BAG_CYC) bad("net B BAG early on wire");
          phase_dev_b = interval_cyc_b - BAG_CYC;
          if (phase_dev_b < 0) phase_dev_b = -phase_dev_b;
          if (phase_dev_b > max_jit_b) max_jit_b = phase_dev_b;
          if (interval_cyc_b > max_gap_b) max_gap_b = interval_cyc_b;
          if (interval_cyc_b < min_gap_b) min_gap_b = interval_cyc_b;
          sum_gap_b = sum_gap_b + interval_cyc_b;
          nsteady_b = nsteady_b + 1;
        end
        f_last_b[vl_id_b] = f_start_cyc_b;
        f_cnt_b[vl_id_b] = f_cnt_b[vl_id_b] + 1;
      end else bad("unexpected net B VLID on wire");
    end
  end

  task bad;
    input [8*96-1:0] reason;
    begin
      if (errors < 25) $display("  [err] T%0d t=%0t: %0s", TEST_ID, $time, reason);
      errors = errors + 1;
    end
  endtask

  task send_msg;
    input integer port_id;
    input integer when;
    begin
      u_host.rd(16'h0074, rd);
      waitc = 0;
      while (!rd[4] && waitc < 50000) begin
        @(negedge clk); waitc = waitc + 1;
        u_host.rd(16'h0074, rd);
      end
      if (!rd[4]) bad("no open TX block");
      blk = rd[3:0];
      @(negedge clk);
      u_host.cs = 1'b1; u_host.we = 1'b1;
      for (j = 0; j < 4; j = j + 1)
        u_host.wr_burst_word(16'h8800 + (blk << 9) + j, 32'hA500_0000 | (port_id << 16) | j);
      u_host.cs = 1'b0; u_host.we = 1'b0;
      while (current_cycle < when) @(negedge clk);
      u_host.wr(16'h8280 + PORT_BASE + port_id, PLEN);
    end
  endtask

  initial begin
    errors = 0; frames_seen = 0; frames_seen_b = 0; current_cycle = 0;
    if(IF_MODE==2)begin
      $sformat(capture_name,"out/metrics/t%0d_vl128_a.hex",TEST_ID);phy_a=$fopen(capture_name,"w");
      $sformat(capture_name,"out/metrics/t%0d_vl128_b.hex",TEST_ID);phy_b=$fopen(capture_name,"w");
      $sformat(capture_name,"out/metrics/t%0d_vl128_a_cycles.txt",TEST_ID);timing_a=$fopen(capture_name,"w");
      $sformat(capture_name,"out/metrics/t%0d_vl128_b_cycles.txt",TEST_ID);timing_b=$fopen(capture_name,"w");
      if(!phy_a||!phy_b||!timing_a||!timing_b)$fatal(1,"VL128 PHY capture open");
    end
    phase_shift_cyc = 0;
    if ($value$plusargs("S5_PHASE_SHIFT_CYC=%d", phase_shift_cyc)) ;
    if (phase_shift_cyc < 0 || phase_shift_cyc > 15) begin
      bad("S5_PHASE_SHIFT_CYC must be 0..15");
      phase_shift_cyc = 0;
    end
    in_frame = 0; in_frame_b = 0; byte_cnt = 0; byte_cnt_b = 0;
    max_jit = 0; max_jit_b = 0; max_gap = 0; max_gap_b = 0;
    min_gap = 32'h7fffffff; min_gap_b = 32'h7fffffff; sum_gap = 0; sum_gap_b = 0;
    max_phase_dev = 0; max_phase_dev_b = 0; nsteady = 0; nsteady_b = 0;
    startup_max_delay = 0; startup_max_delay_b = 0;
    sched_start_cyc = 0; launch_lat_min = 32'h7fffffff; launch_lat_max = 0;
    launch_lat_sum = 0; launch_lat_count = 0;
    if (WIRE_RATE_KBPS > 100000) bad("128-VL on-wire budget exceeds 100 Mbps per net");
    for (i = 0; i < NVL; i = i + 1) begin
      f_last[i] = 0; f_cnt[i] = 0; first_nom[i] = 0;
      f_last_b[i] = 0; f_cnt_b[i] = 0;
      vl_gap_min[i] = 32'h7fffffff; vl_gap_sum[i] = 0;
    end
    repeat (7) @(negedge clk); reset = 0;
    waitc = 0;
    while (dut.init_done !== 1 && waitc < 27000) begin @(negedge clk); waitc = waitc + 1; end
    if (waitc >= 27000) bad("INIT_DONE timeout");

    u_host.wr(16'h0008, 32'h2000);
    u_host.wr(16'h0060, 32'h1234_2001);
    u_host.wr(16'h0064, 32'h0A00_0001);
    u_host.wr(16'h0070, 32'h0000_0142);
    for (i = 0; i < NVL; i = i + 1) begin
      u_host.wr(16'h7D80 + 4*(PORT_BASE+i) + 3, 32'd1);
      u_host.wr(16'h7D80 + 4*(PORT_BASE+i), 32'h8000_C000 | (i & 255));
      u_host.wr(16'h0200 + 5*i + 4, ((PORT_BASE+i) << 16));
      u_host.wr(16'h0200 + 5*i + 3, 32'hE000_0001);
      u_host.wr(16'h0200 + 5*i + 2, (16'd5000 + i) | ((16'd49152 + i) << 16));
      u_host.wr(16'h0200 + 5*i + 1, BAG_US << 8);
      u_host.wr(16'h0480 + i, SHARE);
      u_host.wr(16'h0200 + 5*i, 32'h8000_0003 | (LMAX << 12));
    end
    u_host.rd(16'h0058, rd);
    if (rd !== NVL * SHARE) bad("CFG_SUM mismatch");
    u_host.rd(16'h005C, rd);
    if (rd !== 32'd0) bad("CFG_ERR set");

    u_host.wr(16'h0008, 32'h0001);
    @(negedge clk);
    t_start = current_cycle + phase_shift_cyc;
    if(IF_MODE==2)$display("T%0d_PHY_REFERENCE cycle=%0d",TEST_ID,t_start);
    for (r = 0; r < NUM_ROUNDS; r = r + 1) begin
      for (i = 0; i < NVL; i = i + 1) begin
        if (r == 0) first_nom[i] = t_start + i * BAG_CYC / NVL;
        send_msg(i, t_start + r * BAG_CYC + i * BAG_CYC / NVL);
      end
      if ((r + 1) % 10 == 0 || r + 1 == NUM_ROUNDS)
        $display("T%0d_PROGRESS event=stimulus_round round=%0d/%0d phase_shift_cycles=%0d sim_us=%0d",
                 TEST_ID, r + 1, NUM_ROUNDS, phase_shift_cyc, $time / 1000);
    end

    waitc = 0;
    while ((frames_seen < EXPECTED_TOTAL || frames_seen_b < EXPECTED_TOTAL) && waitc < 2000000) begin
      @(negedge clk); waitc = waitc + 1;
    end
    if (frames_seen != EXPECTED_TOTAL) bad("net A frame count differs from exact 128-VL total");
    if (frames_seen_b != EXPECTED_TOTAL) bad("net B frame count differs from exact 128-VL total");
    for (i = 0; i < NVL; i = i + 1)
      if (f_cnt[i] != NUM_ROUNDS) bad("missing frame for a VL");
    for (i = 0; i < NVL; i = i + 1)
      if (f_cnt_b[i] != NUM_ROUNDS) bad("missing net B frame for a VL");
    worst_vl_resid_cycles = 0; worst_vl_resid_id = 0;
    for (i = 0; i < NVL; i = i + 1) begin
      vl_resid_cycles = vl_gap_sum[i] / (NUM_ROUNDS - 1) - vl_gap_min[i];
      if (vl_resid_cycles > worst_vl_resid_cycles) begin
        worst_vl_resid_cycles = vl_resid_cycles;
        worst_vl_resid_id = i;
      end
    end
    waitc = 0;
    while ((fwd_a < EXPECTED_TOTAL || fwd_b < EXPECTED_TOTAL) && waitc < 400000) begin
      @(negedge clk); waitc = waitc + 1;
    end
    // Keep observing for one more BAG plus the modeled path delay. The exact
    // count above can otherwise pass before a late duplicate is emitted or
    // leaves the store-and-forward queue.
    repeat (BAG_CYC + DELAY_US * 125) @(negedge clk);
    if (frames_seen != EXPECTED_TOTAL) bad("net A frame count changed during drain");
    if (frames_seen_b != EXPECTED_TOTAL) bad("net B frame count changed during drain");
    if (fwd_a != EXPECTED_TOTAL) bad("net A forward count changed during drain");
    if (fwd_b != EXPECTED_TOTAL) bad("net B forward count changed during drain");
    if (in_frame || in_frame_b) bad("partial TX frame remained after drain");
    $display("  [s5] rounds=%0d frames A/B=%0d/%0d fwd=%0d/%0d wire=%0d kbps/net",
             NUM_ROUNDS, frames_seen, frames_seen_b, fwd_a, fwd_b, WIRE_RATE_KBPS);
    $display("  [s5] startup A/B=%0d/%0dus interval-dev A/B=%0d/%0dus phase-drift A/B=%0d/%0dus max-gap A/B=%0d/%0dus",
             (startup_max_delay + 124) / 125, (startup_max_delay_b + 124) / 125,
             (max_jit + 124) / 125, (max_jit_b + 124) / 125,
             (max_phase_dev + 124) / 125, (max_phase_dev_b + 124) / 125,
             (max_gap + 124) / 125, (max_gap_b + 124) / 125);
    $display("  [s5] interval-cycles A min/avg/max=%0d/%0d/%0d B=%0d/%0d/%0d",
             min_gap, sum_gap / nsteady, max_gap,
             min_gap_b, sum_gap_b / nsteady_b, max_gap_b);
    $display("  [s5] phase-drift-cycles A/B=%0d/%0d limit=%0d headroom A/B=%0d/%0d phase_shift=%0d",
             max_phase_dev, max_phase_dev_b, JIT_MAX,
             JIT_MAX - max_phase_dev, JIT_MAX - max_phase_dev_b, phase_shift_cyc);
    $display("  [s5] start-to-wire cycles min/avg/max=%0d/%0d/%0d n=%0d",
             launch_lat_min, launch_lat_sum / launch_lat_count,
             launch_lat_max, launch_lat_count);
    $display("  [s5] worst per-VL avg-minus-min interval=%0d cycles (VL=%0d)",
             worst_vl_resid_cycles, worst_vl_resid_id);
    if (fwd_a != EXPECTED_TOTAL) bad("net A forward count differs from exact 128-VL total");
    if (fwd_b != EXPECTED_TOTAL) bad("net B forward count differs from exact 128-VL total");
    if (nsteady != (NUM_ROUNDS - 1) * NVL) bad("net A steady-interval count mismatch");
    if (nsteady_b != (NUM_ROUNDS - 1) * NVL) bad("net B steady-interval count mismatch");
    if (startup_max_delay > JIT_MAX) bad("net A startup delay above 50 us");
    if (startup_max_delay_b > JIT_MAX) bad("net B startup delay above 50 us");
    if (max_jit > JIT_MAX) bad("net A interval deviation above 50 us");
    if (max_jit_b > JIT_MAX) bad("net B interval deviation above 50 us");
    if (max_phase_dev > JIT_MAX) bad("net A phase drift above 50 us");
    if (max_phase_dev_b > JIT_MAX) bad("net B phase drift above 50 us");
    if (max_gap > BAG_CYC + JIT_MAX) bad("net A maximum inter-frame gap above BAG+50 us");
    if (max_gap_b > BAG_CYC + JIT_MAX) bad("net B maximum inter-frame gap above BAG+50 us");

    if(IF_MODE==2)begin
      $fclose(phy_a);$fclose(phy_b);$fclose(timing_a);$fclose(timing_b);
    end
    errors = errors + u_host.errors;
    if (errors == 0)
      $display("T%0d VL128 PASS (IF_MODE=%0d BAG=1ms N=128 rounds=%0d via net_model)", TEST_ID, IF_MODE, NUM_ROUNDS);
    else
      $display("T%0d VL128 FAIL (IF_MODE=%0d errors=%0d)", TEST_ID, IF_MODE, errors);
    $finish;
  end

  initial begin
    #200_000_000;
    $display("T%0d VL128 FAIL: timeout IF_MODE=%0d frames A/B=%0d/%0d", TEST_ID, IF_MODE, frames_seen, frames_seen_b);
    $finish;
  end
endmodule

module tb_s5_vl128;
  tb_s5_vl128_core #(.IF_MODE(0), .NUM_ROUNDS(2), .TEST_ID(29)) core();
endmodule

// T33 extends the phased 128-VL scenario to sixteen consecutive BAG periods.
module tb_s5_vl128_continuous;
  tb_s5_vl128_core #(.IF_MODE(0), .NUM_ROUNDS(16), .TEST_ID(33)) core();
endmodule

module tb_s5_vl128_continuous_gmii;
  tb_s5_vl128_core #(.IF_MODE(1), .NUM_ROUNDS(16), .TEST_ID(33)) core();
endmodule

// T34 measures cumulative behavior over a 100 ms, 128-VL continuous run.
module tb_s5_vl128_100rounds;
  tb_s5_vl128_core #(.IF_MODE(0), .NUM_ROUNDS(100), .TEST_ID(34)) core();
endmodule

// PHY GMII follows the same full128-VL contract and phased legal1ms BAG.
module tb_s5_vl128_continuous_phy;
  tb_s5_vl128_core #(.IF_MODE(2), .NUM_ROUNDS(16), .TEST_ID(33)) core();
endmodule
module tb_s5_vl128_100rounds_phy;
  tb_s5_vl128_core #(.IF_MODE(2), .NUM_ROUNDS(100), .TEST_ID(34)) core();
endmodule
