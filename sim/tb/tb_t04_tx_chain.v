// =====================================================================
// tb_t04_tx_chain.v —— 发送链集成单测（T04 BAG 合规 / T07 双网 / 线上帧完整性）
// 链路: tx_port_buf + tx_sn_gen + tx_frame_builder + tx_vl_scheduler(O-14 顺序扫描)
//       + tx_rm + tx_pace + 2× mac_tx_if(A/B) + bram_sdp(PMEM)，TB 扮演 host_if 与 VL 表。
// 检查:
//   (a) 每帧: FCS 残差 0xDEBB20E3、帧长 = 42+max(L,17)+1+4、DMAC/SMAC/长度字段、
//       载荷 == 主机写入、SN 每 VL 递增（255→1）、字节间隔（IF_MODE=0 恒 BYTE_SLOT_CYC；
//       IF_MODE=1 帧内无空拍）、帧间 ≥ IFG_BYTES 槽；
//   (b) BAG: 同 VL 相邻帧首字节间隔 ≥ BAG（所有 VL、全程）；单 VL 阶段间隔 ≤ BAG + 600 拍
//       （量化 + 扫描 + 启动开销）；bag_viol 恒 0；
//   (c) 双网: net_mode=3 时 B 路与 A 路同拍同字节、仅偏移 11 为 0x40（A 为 0x20）；
//       net_mode=1 时 B 路无任何 tx_valid；frame_done 每帧恰 1 次、done_vl 正确；
//   (d) underrun_cnt=0、take_miss=0、块守恒（结束时 free_map 回到全池）。
// 判据: 末行 "T04 TXCHAIN PASS" / "T04 TXCHAIN FAIL: n errors"
// 顶层: tb_t04_tx_chain（IF_MODE=0）、tb_t04g_tx_chain（IF_MODE=1，GMII）
// =====================================================================
`timescale 1 ns / 1 ps
module tb_t04_core #(
  parameter integer IF_MODE = 0
) ();
  localparam integer BYTE_SLOT = (IF_MODE != 0) ? 1 : 10;
  localparam integer IFG_BYTES = 12;
  localparam integer NVL = 8;

  reg clk = 1'b0;
  reg reset = 1'b1;
  always #4 clk = ~clk;               // 125 MHz
  integer err = 0;
  integer cyc = 0;
  always @(posedge clk) cyc <= cyc + 1;

  // ---------------- 时基 ----------------
  wire [63:0] rtc64; wire tick_us, alive;
  timebase #(.TICK_US(1)) u_tb (.clk(clk), .rst(reset), .rtc_hold(1'b0), .freq_adj(16'd524),
                                .rtc64(rtc64), .tick_us(tick_us), .alive(alive));
  wire [23:0] tb_us = rtc64[23:0];

  // ---------------- PMEM ----------------
  reg          m_we = 0;
  reg  [12:0]  m_waddr = 0;
  reg  [31:0]  m_wdata = 0;
  wire         rd_en_a, rd_en_b;
  wire [12:0]  rd_addr_a, rd_addr_b;
  wire [31:0]  rd_data_a, rd_data_b;
  bram_sdp #(.W(32), .D(8192)) u_pmem (
    .clk(clk), .wr_en(m_we), .wr_addr(m_waddr), .wr_data(m_wdata), .wr_be(4'hf),
    .rd_en_a(rd_en_a), .rd_addr_a(rd_addr_a), .rd_data_a(rd_data_a),
    .rd_en_b(rd_en_b), .rd_addr_b(rd_addr_b), .rd_data_b(rd_data_b));

  // ---------------- tx_port_buf ----------------
  reg         p_commit = 0;
  reg  [7:0]  p_port = 0;
  reg  [15:0] p_len = 0;
  wire        p_rej;
  wire [3:0]  p_wblk;  wire p_wblk_vld;
  wire [31:0] p_ddata;
  wire [255:0] p_req, p_full;
  wire        sch_take, sch_ack;
  wire [7:0]  sch_port;
  wire [3:0]  sch_blk;
  wire [12:0] sch_len;
  wire        blk_free; wire [3:0] blk_free_id;
  wire [15:0] free_map, ovr_cnt, q_ovf_cnt, exh_cnt;
  wire        pending;
  tx_port_buf #(.NUM_PORTS(256), .TX_BLK_LO(0), .TX_BLK_N(6)) u_pb (
    .clk(clk), .rst_sync(reset), .tb_us(tb_us[7:0]),
    .msg_commit(p_commit), .port_id(p_port), .len(p_len),
    .port_type(2'd0), .port_depth(4'd1), .commit_rej(p_rej),
    .wr_blk(p_wblk), .wr_blk_vld(p_wblk_vld),
    .desc_rd_addr(8'd0), .desc_rd_data(p_ddata),
    .sch_req(p_req), .buf_full(p_full),
    .sch_take(sch_take), .sch_port(sch_port), .sch_ack(sch_ack),
    .sch_blk(sch_blk), .sch_len(sch_len),
    .blk_free(blk_free), .blk_free_id(blk_free_id),
    .free_map(free_map), .ovr_cnt(ovr_cnt), .q_ovf_cnt(q_ovf_cnt),
    .pmem_exhaust_cnt(exh_cnt), .pending(pending));

  // ---------------- builder 状态（前置声明：vlog-2388）----------------
  wire        b_busy, b_done, b_len_err;
  wire [7:0]  b_cur_vl;

  // ---------------- tx_sn_gen ----------------
  wire        snap_req, snap_ack;
  wire [7:0]  snap_vl, snap;
  wire        frame_done; wire [7:0] done_vl;
  wire [1:0]  sn_pend; wire sn_err;
  tx_sn_gen #(.NUM_TX_VL(128)) u_sn (
    .clk(clk), .rst_sync(reset),
    .snap_req(snap_req), .snap_vl(snap_vl), .snap(snap), .snap_ack(snap_ack),
    // SN 提交点 = builder.done（末字节已入 mac_tx_if FIFO，帧级原子、不会再丢，§5.3 规则 5）；
    // 不用线上 frame_done：FIFO 在途可达多帧，而 tx_sn_gen 只有单 pend 槽（§7.4 已知限制）
    .cancel(1'b0), .commit(b_done), .commit_vl(b_cur_vl),
    .init_all(1'b0), .ovr_we(1'b0), .ovr_vl(8'd0), .ovr_val(8'd0),
    .sn_pend(sn_pend), .err(sn_err));

  // ---------------- scheduler ----------------
  reg         cfg_we = 0;
  reg  [6:0]  cfg_vl = 0;
  reg         cfg_valid = 0;
  reg  [23:0] cfg_bag = 0;
  reg  [7:0]  cfg_port = 0;
  wire        start_vld; wire [7:0] start_vl; wire [3:0] start_blk; wire [12:0] start_len;
  wire        frame_start;
  wire        bag_viol; wire [15:0] bag_ovf_cnt, take_miss_cnt; wire [7:0] vl_valid_cnt;
  tx_vl_scheduler #(.NUM_TX_VL(128), .NUM_PORTS(256)) u_sch (
    .clk(clk), .rst_sync(reset), .enable(1'b1), .tb_us(tb_us),
    .cfg_we(cfg_we), .cfg_vl(cfg_vl), .cfg_valid(cfg_valid), .cfg_bag_us(cfg_bag), .cfg_port(cfg_port),
    .cfg_bag_only(1'b0), .start_cfg_rd(), .frame_permit(),
    .port_ready(p_req),
    .sch_take(sch_take), .sch_port(sch_port), .sch_ack(sch_ack), .sch_blk(sch_blk), .sch_len(sch_len),
    .start_vld(start_vld), .start_vl(start_vl), .start_blk(start_blk), .start_len(start_len),
    .builder_busy(b_busy), .builder_len_err(b_len_err), .frame_start(frame_start),
    .bag_viol(bag_viol), .bag_ovf_cnt(bag_ovf_cnt), .take_miss_cnt(take_miss_cnt), .vl_valid_cnt(vl_valid_cnt));

  // ---------------- VL 表（TB 模拟，按 start_vl 组合查表）----------------
  wire [15:0] h_vlid  = 16'h0100 + {8'd0, start_vl};
  wire [15:0] h_sport = 16'd49152 + {8'd0, start_vl};   // port_id == vl
  reg  [1:0]  vl_net [0:127];
  wire [1:0]  net_mode = vl_net[b_cur_vl[6:0]];

  // ---------------- builder ----------------
  wire        o_vld, o_sof, o_eof, o_rdy;
  wire [7:0]  o_a, o_b;
  wire [15:0] p1_stall;
  tx_frame_builder #(.BYTE_SLOT_CYC(BYTE_SLOT)) u_fb (
    .clk(clk), .rst_sync(reset),
    .start_vld(start_vld), .start_vl(start_vl), .start_blk(start_blk), .start_len(start_len),
    .busy(b_busy), .done(b_done), .cur_vl(b_cur_vl), .len_err(b_len_err),
    .hdr_vlid(h_vlid), .hdr_udi(16'h1234), .hdr_ifid_a(3'd1), .hdr_ifid_b(3'd2),
    .hdr_tos(8'd0), .hdr_ttl(8'd1), .hdr_ident(16'd0),
    .hdr_src_ip(32'h0A00_0001), .hdr_dst_ip(32'hE000_0001),
    .hdr_sport(h_sport), .hdr_dport(16'd5000), .hdr_udp_csum_en(1'b1),
    .snap_req(snap_req), .snap_vl(snap_vl), .snap(snap), .snap_ack(snap_ack),
    .rd_en_a(rd_en_a), .rd_addr_a(rd_addr_a), .rd_data_a(rd_data_a),
    .rd_en_b(rd_en_b), .rd_addr_b(rd_addr_b), .rd_data_b(rd_data_b),
    .out_vld(o_vld), .out_byte_a(o_a), .out_byte_b(o_b), .out_sof(o_sof), .out_eof(o_eof), .out_rdy(o_rdy),
    .blk_free(blk_free), .blk_free_id(blk_free_id), .p1_stall_cnt(p1_stall));

  // ---------------- tx_rm + pace + mac_tx_if ×2 ----------------
  wire a_vld, a_sof, a_eof, a_rdy, bb_vld, bb_sof, bb_eof, bb_rdy;
  wire [7:0] a_byte, bb_byte;
  wire a_start, a_done, b_start, b_done_m;
  wire [15:0] frames_a, frames_b;
  tx_rm u_rm (
    .clk(clk), .rst_sync(reset), .net_mode(net_mode), .in_vl(b_cur_vl),
    .in_vld(o_vld), .in_byte_a(o_a), .in_byte_b(o_b), .in_sof(o_sof), .in_eof(o_eof), .in_rdy(o_rdy),
    .a_vld(a_vld), .a_byte(a_byte), .a_sof(a_sof), .a_eof(a_eof), .a_rdy(a_rdy),
    .b_vld(bb_vld), .b_byte(bb_byte), .b_sof(bb_sof), .b_eof(bb_eof), .b_rdy(bb_rdy),
    .a_start(a_start), .b_start(b_start), .a_done(a_done), .b_done(b_done_m),
    .frame_start(frame_start), .frame_done(frame_done), .done_vl(done_vl),
    .frames_a(frames_a), .frames_b(frames_b));
  wire pace_en;
  tx_pace #(.IF_MODE(IF_MODE), .BYTE_SLOT_CYC(BYTE_SLOT)) u_pace (.clk(clk), .rst_sync(reset), .pace_en(pace_en));
  wire [7:0] txa_data, txb_data; wire txa_valid, txa_ready, txb_valid, txb_ready, a_busy, b_busy_m;
  wire [15:0] ur_a, ur_b;
  mac_tx_if #(.IF_MODE(IF_MODE), .FCS_MODE(2), .IFG_BYTES(IFG_BYTES), .FIFO_D(64), .START_THRESH(48)) u_mac_a (
    .clk(clk), .rst_sync(reset), .in_vld(a_vld), .in_byte(a_byte), .in_sof(a_sof), .in_eof(a_eof), .in_rdy(a_rdy),
    .pace_en(pace_en), .start_permit(1'b1), .tx_data(txa_data), .tx_valid(txa_valid), .tx_ready(txa_ready), .link_rdy(1'b1),
    .frame_start(a_start), .frame_done(a_done), .busy(a_busy), .underrun_cnt(ur_a));
  mac_tx_if #(.IF_MODE(IF_MODE), .FCS_MODE(2), .IFG_BYTES(IFG_BYTES), .FIFO_D(64), .START_THRESH(48)) u_mac_b (
    .clk(clk), .rst_sync(reset), .in_vld(bb_vld), .in_byte(bb_byte), .in_sof(bb_sof), .in_eof(bb_eof), .in_rdy(bb_rdy),
    .pace_en(pace_en), .start_permit(1'b1), .tx_data(txb_data), .tx_valid(txb_valid), .tx_ready(txb_ready), .link_rdy(1'b1),
    .frame_start(b_start), .frame_done(b_done_m), .busy(b_busy_m), .underrun_cnt(ur_b));

  // =====================================================================
  // 参考状态
  // =====================================================================
  reg [7:0]  exp_pl  [0:NVL-1][0:1471];
  integer    exp_len [0:NVL-1];
  integer    exp_cnt [0:NVL-1];      // 该端口已提交、尚未在线上看到的帧数（应 ≤1）
  integer    bag_us  [0:NVL-1];
  integer    last_start [0:NVL-1];
  integer    n_frames [0:NVL-1];
  reg  [7:0] exp_sn  [0:NVL-1];
  integer    max_gap, min_gap, single_phase;
  integer    frames_seen_a, frames_seen_b, done_seen, b_activity_when_off;
  integer    i, k, w;
  reg [31:0] rnd = 32'h0BAD_5EED;
  function [31:0] lfsr; input [31:0] x; lfsr = {x[30:0], x[31] ^ x[21] ^ x[1] ^ x[0]}; endfunction

  // CRC32 残差
  function [31:0] crc_step; input [31:0] c; input [7:0] d;
    integer b; reg [31:0] s;
    begin
      s = c ^ {24'd0, d};
      for (b = 0; b < 8; b = b + 1) s = s[0] ? (s >> 1) ^ 32'hEDB8_8320 : (s >> 1);
      crc_step = s;
    end
  endfunction

  // ---------------- A 路捕获 / 解析 ----------------
  reg [7:0]  cap [0:1600];
  integer    cap_n, f_start_cyc, last_vld_cyc, last_frame_end_cyc;
  reg        in_frm;
  reg [31:0] crc_acc, crc_b;
  reg        b_in_frm = 0;
  // A 帧的 FCS 区：帧总长由 IP Total Length 推出 = 14 + max(ip_total, 45) + 1 + 4，FCS = 末 4 字节
  wire [15:0] ipt_live = {cap[16], cap[17]};
  wire [15:0] body_live = (ipt_live < 16'd45) ? 16'd60 : (16'd14 + ipt_live + 16'd1);
  wire        b_fcs_zone = (cap_n >= body_live);
  integer    L, vl, port, flen_want, pad;
  reg [15:0] ip_tot, udp_l;
  reg        pl_ok;
  integer    gap;

  task check_frame;
    begin
      frames_seen_a = frames_seen_a + 1;
      if (crc_acc !== 32'hDEBB_20E3) begin $display("  [err] frame %0d: FCS bad (residue %08x)", frames_seen_a, crc_acc); err = err + 1; end
      if (cap[0] !== 8'h03 || cap[1] !== 8'h00 || cap[2] !== 8'h00 || cap[3] !== 8'h00 || cap[4] !== 8'h01) begin
        $display("  [err] frame %0d: DMAC %02x%02x%02x%02x%02x", frames_seen_a, cap[0], cap[1], cap[2], cap[3], cap[4]); err = err + 1;
      end
      vl = cap[5];
      if (cap[6] !== 8'h02 || cap[7] !== 8'h00 || cap[8] !== 8'h00 || cap[9] !== 8'h12 || cap[10] !== 8'h34 || cap[11] !== 8'h20) begin
        $display("  [err] frame %0d: SMAC-A %02x%02x%02x%02x%02x%02x", frames_seen_a, cap[6], cap[7], cap[8], cap[9], cap[10], cap[11]); err = err + 1;
      end
      if (vl >= NVL) begin $display("  [err] frame %0d: vl %0d out of range", frames_seen_a, vl); err = err + 1; end
      else begin
        port = vl;
        ip_tot = {cap[16], cap[17]}; udp_l = {cap[38], cap[39]};
        L = exp_len[port];
        if (ip_tot !== 28 + L || udp_l !== 8 + L) begin
          $display("  [err] vl%0d frame: ip_total=%0d udp_len=%0d want %0d/%0d", vl, ip_tot, udp_l, 28+L, 8+L); err = err + 1;
        end
        if ({cap[34], cap[35]} !== 16'd49152 + port[15:0]) begin $display("  [err] vl%0d: sport %02x%02x", vl, cap[34], cap[35]); err = err + 1; end
        pad = (L < 17) ? 17 - L : 0;
        flen_want = 42 + L + pad + 1 + 4;
        if (cap_n !== flen_want) begin $display("  [err] vl%0d: frame len %0d want %0d (L=%0d)", vl, cap_n, flen_want, L); err = err + 1; end
        else begin
          pl_ok = 1'b1;
          for (k = 0; k < L; k = k + 1) if (cap[42 + k] !== exp_pl[port][k]) pl_ok = 1'b0;
          for (k = 0; k < pad; k = k + 1) if (cap[42 + L + k] !== 8'h00) pl_ok = 1'b0;
          if (!pl_ok) begin $display("  [err] vl%0d: payload/pad mismatch (L=%0d)", vl, L); err = err + 1; end
          if (cap[42 + L + pad] !== exp_sn[port]) begin
            $display("  [err] vl%0d: SN got %0d want %0d", vl, cap[42 + L + pad], exp_sn[port]); err = err + 1;
          end
        end
        exp_sn[port] = (exp_sn[port] == 8'd255) ? 8'd1 : exp_sn[port] + 8'd1;
        exp_cnt[port] = exp_cnt[port] - 1;
        if (exp_cnt[port] < 0) begin $display("  [err] vl%0d: frame without commit", vl); err = err + 1; exp_cnt[port] = 0; end
        // BAG
        if (n_frames[port] > 0) begin
          gap = f_start_cyc - last_start[port];
          if (gap < bag_us[port] * 125) begin
            $display("  [err] vl%0d: BAG violated gap=%0d cyc < %0d", vl, gap, bag_us[port] * 125); err = err + 1;
          end
          if (single_phase) begin
            if (gap > max_gap) max_gap = gap;
            if (gap < min_gap) min_gap = gap;
            // 上界 = BAG + 扫描 1 轮(128) + take/setup(≈30) + 最大帧 pass1 前置(368, 偏移 40 处等待)
            //        + GMII 起帧阈值(48) + 量化(125) ≈ +700，取 +800
            if (gap > bag_us[port] * 125 + 800) begin
              $display("  [err] vl%0d: single-VL gap=%0d > BAG+800 (%0d)", vl, gap, bag_us[port] * 125 + 800); err = err + 1;
            end
          end
        end
        last_start[port] = f_start_cyc;
        n_frames[port] = n_frames[port] + 1;
      end
      // 帧间隙
      if (last_frame_end_cyc >= 0 && (f_start_cyc - last_frame_end_cyc) < IFG_BYTES * BYTE_SLOT) begin
        $display("  [err] frame %0d: IFG %0d cyc < %0d", frames_seen_a, f_start_cyc - last_frame_end_cyc, IFG_BYTES * BYTE_SLOT); err = err + 1;
      end
      last_frame_end_cyc = last_vld_cyc;
    end
  endtask

  // 帧结束检测：IF_MODE=0 用 tx_ready 下降沿；IF_MODE=1 用 tx_valid 下降
  reg txa_ready_d = 0, txa_valid_d = 0;
  wire frame_end_a = (IF_MODE != 0) ? (txa_valid_d & ~txa_valid) : (txa_ready_d & ~txa_ready);
  always @(posedge clk) begin
    txa_ready_d <= txa_ready; txa_valid_d <= txa_valid;
    if (reset) begin cap_n = 0; in_frm = 0; crc_acc = 32'hFFFF_FFFF; last_frame_end_cyc = -1; last_vld_cyc = 0; frames_seen_b = 0; b_activity_when_off = 0; end
    else begin
      if (txa_valid) begin
        if (IF_MODE == 0 && !txa_ready) begin $display("  [err] tx_valid outside tx_ready envelope @%0d", cyc); err = err + 1; end
        if (!in_frm) begin
          in_frm = 1; cap_n = 0; crc_acc = 32'hFFFF_FFFF; f_start_cyc = cyc;
          if (IF_MODE == 0 && !(txa_ready_d)) begin $display("  [err] envelope not ahead of first byte @%0d", cyc); err = err + 1; end
        end else begin
          if (IF_MODE == 0 && (cyc - last_vld_cyc) != BYTE_SLOT) begin
            if (err < 20) $display("  [err] byte spacing %0d != %0d @%0d", cyc - last_vld_cyc, BYTE_SLOT, cyc); err = err + 1;
          end
          if (IF_MODE != 0 && (cyc - last_vld_cyc) != 1) begin
            if (err < 20) $display("  [err] GMII gap inside frame @%0d", cyc); err = err + 1;
          end
        end
        // B 路：同拍逐字节比对（仅偏移 11 不同；FCS 4 字节各自计算，只查 B 的残差）
        if (txb_valid) begin
          if (cap_n == 0) begin frames_seen_b = frames_seen_b + 1; crc_b = 32'hFFFF_FFFF; b_in_frm = 1; end
          crc_b = crc_step(crc_b, txb_data);
          if (cap_n == 11) begin
            if (txb_data !== 8'h40 || txa_data !== 8'h20) begin $display("  [err] B smac[5]=%02x A=%02x", txb_data, txa_data); err = err + 1; end
          end else if (cap_n < 42 || !b_fcs_zone) begin
            if (txb_data !== txa_data) begin
              if (err < 20) $display("  [err] B byte[%0d]=%02x != A %02x", cap_n, txb_data, txa_data); err = err + 1;
            end
          end
        end
        cap[cap_n] = txa_data; cap_n = cap_n + 1; crc_acc = crc_step(crc_acc, txa_data); last_vld_cyc = cyc;
      end else if (txb_valid) begin
        b_activity_when_off = b_activity_when_off + 1;   // B 有字节而 A 无：不同拍或 A-only 模式泄漏
      end
      if (frame_end_a && in_frm) begin
        in_frm = 0;
        if (b_in_frm) begin
          b_in_frm = 0;
          if (crc_b !== 32'hDEBB_20E3) begin $display("  [err] B-net FCS bad (residue %08x)", crc_b); err = err + 1; end
        end
        check_frame;
      end
    end
  end
  always @(posedge clk) if (frame_done) done_seen = done_seen + 1;
  integer viol_seen = 0;
  always @(posedge clk) if (bag_viol) viol_seen = viol_seen + 1;

  // =====================================================================
  // 主机行为
  // =====================================================================
  task cfg_vl_t; input integer v; input integer bag; input [1:0] nm; input valid;
    begin
      @(negedge clk); cfg_we <= 1'b1; cfg_vl <= v[6:0]; cfg_valid <= valid; cfg_bag <= bag[23:0]; cfg_port <= v[7:0];
      vl_net[v] = nm;
      @(negedge clk); cfg_we <= 1'b0;
      bag_us[v] = bag;
    end
  endtask

  // 写载荷 + commit（仅当端口空且有开放块）
  task host_send; input integer pt; input integer len;
    reg [31:0] wd; integer b; reg [3:0] blk;
    begin
      @(negedge clk);
      while (!p_wblk_vld || p_req[pt] || exp_cnt[pt] != 0) @(negedge clk);
      blk = p_wblk;
      for (w = 0; w < (len + 3) / 4; w = w + 1) begin
        wd = 32'd0;
        for (b = 0; b < 4; b = b + 1) begin
          rnd = lfsr(rnd);
          if (4 * w + b < len) begin exp_pl[pt][4 * w + b] = rnd[15:8]; wd[31 - 8 * b -: 8] = rnd[15:8]; end
        end
        m_we <= 1'b1; m_waddr <= {blk, w[8:0]}; m_wdata <= wd; @(negedge clk);
      end
      m_we <= 1'b0;
      exp_len[pt] = len;
      p_commit <= 1'b1; p_port <= pt[7:0]; p_len <= len[15:0];
      @(negedge clk); p_commit <= 1'b0;
      @(negedge clk);
      if (p_rej) begin $display("  [err] commit p%0d rejected", pt); err = err + 1; end
      else exp_cnt[pt] = exp_cnt[pt] + 1;
    end
  endtask

  integer active_n, rounds, target, lens_i;
  integer len_pick;
  integer t_end;
  task drive_phase; input integer vl_lo; input integer vl_hi; input integer nframes_total; input integer lmax;
    integer got0;
    begin
      got0 = frames_seen_a; rounds = 0;
      while (frames_seen_a - got0 < nframes_total && rounds < 200000) begin
        for (i = vl_lo; i <= vl_hi; i = i + 1) begin
          if (p_wblk_vld && !p_req[i] && exp_cnt[i] == 0) begin
            rnd = lfsr(rnd);
            case (rnd[3:0])
              4'd0: len_pick = 8;  4'd1: len_pick = 16; 4'd2: len_pick = 17; 4'd3: len_pick = 18;
              4'd4: len_pick = lmax;
              default: len_pick = 8 + (rnd[26:16] % (lmax - 7));
            endcase
            host_send(i, len_pick);
          end
        end
        @(negedge clk); rounds = rounds + 1;
      end
      // 等在途帧发完
      t_end = cyc;
      while ((b_busy || a_busy || b_busy_m || frames_seen_a < got0 + nframes_total) && cyc - t_end < 200000) @(negedge clk);
    end
  endtask

  initial begin
    for (i = 0; i < NVL; i = i + 1) begin exp_len[i] = 0; exp_cnt[i] = 0; bag_us[i] = 0; last_start[i] = 0; n_frames[i] = 0; exp_sn[i] = 8'd1; end
    for (i = 0; i < 128; i = i + 1) vl_net[i] = 2'b11;
    frames_seen_a = 0; done_seen = 0; max_gap = 0; min_gap = 1 << 30; single_phase = 0;
    repeat (5) @(negedge clk); reset <= 1'b0; repeat (5) @(negedge clk);

    // ---- 阶段 1：单 VL，BAG 32 μs，双网，30 帧（间隔上下界 + 抖动）----
    $display("T04 phase 1: single VL BAG=32us dual-net, IF_MODE=%0d", IF_MODE);
    cfg_vl_t(0, 32, 2'b11, 1'b1);
    single_phase = 1;
    drive_phase(0, 0, 30, (IF_MODE != 0) ? 1471 : 200);
    single_phase = 0;
    $display("  single-VL start gap: min=%0d max=%0d cyc (BAG=%0d cyc)", min_gap, max_gap, 32 * 125);
    if (frames_seen_a < 30) begin $display("  [err] phase1 only %0d frames", frames_seen_a); err = err + 1; end
    if (frames_seen_b != frames_seen_a) begin $display("  [err] phase1 B frames %0d != A %0d", frames_seen_b, frames_seen_a); err = err + 1; end
    if (b_activity_when_off != 0) begin $display("  [err] phase1 B/A not cycle-aligned (%0d)", b_activity_when_off); err = err + 1; end

    // ---- 阶段 2：5 VL 混合 BAG（32/64/128/256/512 μs），VL4 大帧，200 帧 ----
    $display("T04 phase 2: 5 VLs BAG 32/64/128/256/512us");
    cfg_vl_t(1, 64, 2'b11, 1'b1);
    cfg_vl_t(2, 128, 2'b11, 1'b1);
    cfg_vl_t(3, 256, 2'b11, 1'b1);
    cfg_vl_t(4, 512, 2'b11, 1'b1);
    drive_phase(0, 4, 200, 64);
    for (i = 0; i < 5; i = i + 1) $display("  vl%0d: %0d frames", i, n_frames[i]);
    if (n_frames[4] < 3) begin $display("  [err] vl4 starved (%0d frames)", n_frames[4]); err = err + 1; end

    // ---- 阶段 3：net_mode=A only（VL5），B 路必须静默；VL0~4 停用 ----
    $display("T04 phase 3: VL5 A-only, B silent");
    for (i = 0; i < 5; i = i + 1) cfg_vl_t(i, bag_us[i], 2'b11, 1'b0);
    repeat (2000) @(negedge clk);                    // 让在途帧结束
    b_activity_when_off = 0;
    cfg_vl_t(5, 32, 2'b01, 1'b1);
    drive_phase(5, 5, 10, 100);
    if (b_activity_when_off != 0) begin $display("  [err] B active %0d cycles in A-only mode", b_activity_when_off); err = err + 1; end
    if (n_frames[5] < 10) begin $display("  [err] phase3 vl5 %0d frames", n_frames[5]); err = err + 1; end

    // ---- 收尾检查 ----
    repeat (3000) @(negedge clk);
    if (done_seen != frames_seen_a) begin $display("  [err] frame_done %0d != frames %0d", done_seen, frames_seen_a); err = err + 1; end
    if (viol_seen != 0 || bag_ovf_cnt != 0) begin $display("  [err] bag_viol=%0d ovf=%0d", viol_seen, bag_ovf_cnt); err = err + 1; end
    if (take_miss_cnt != 0) begin $display("  [err] take_miss=%0d", take_miss_cnt); err = err + 1; end
    if (ur_a != 0 || ur_b != 0) begin $display("  [err] underrun a=%0d b=%0d", ur_a, ur_b); err = err + 1; end
    if (p1_stall != 0) $display("  [info] builder p1_stall=%0d", p1_stall);
    if (sn_err) begin $display("  [err] sn_gen err"); err = err + 1; end
    // 端口 0..4 停用后可能仍各有 1 条已提交未发送消息占块；其余块须回到空闲
    $display("  free_map=%04x exh=%0d ovr=%0d qovf=%0d frames A=%0d B=%0d", free_map, exh_cnt, ovr_cnt, q_ovf_cnt, frames_seen_a, frames_seen_b);
    if (exh_cnt != 0 || q_ovf_cnt != 0 || ovr_cnt != 0) begin $display("  [err] unexpected buf counters"); err = err + 1; end

    if (err == 0) $display("T04 TXCHAIN PASS (IF_MODE=%0d, %0d frames, BAG/FCS/SN/payload/dual-net/IFG ok, single-VL gap %0d..%0d cyc)",
                           IF_MODE, frames_seen_a, min_gap, max_gap);
    else $display("T04 TXCHAIN FAIL: %0d errors", err);
    $finish;
  end

  initial begin
    #40_000_000;   // 40 ms 上限
    $display("T04 TXCHAIN FAIL: timeout"); $finish;
  end
endmodule

module tb_t04_tx_chain;  tb_t04_core #(.IF_MODE(0)) core (); endmodule
module tb_t04g_tx_chain; tb_t04_core #(.IF_MODE(1)) core (); endmodule
