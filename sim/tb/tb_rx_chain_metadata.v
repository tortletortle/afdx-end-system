// Standalone parser/PB/chain-metadata contract tests. Only the coordinating
// thread may run this TB after acquiring the shared heavy-tool slot.
// Frozen legacy implementations at the end are cycle-by-cycle reference models.
`timescale 1 ns / 1 ps
module tb_rx_chain_metadata;
  reg clk = 1'b0;
  always #5 clk = ~clk;
  reg rst_sync = 1'b1;
  integer cycles = 0;
  integer cases = 0;
  integer sweep;
  reg oracle_enabled = 1'b0;
  reg model_enabled = 1'b0;
  reg [15:0] model_owned = 16'd0;
  reg [15:0] model_register_mask;

  reg parse_in_vld = 1'b0;
  reg [207:0] parse_desc = 208'd0;
  reg [31:0] parse_w0 = 32'd0;
  reg [31:0] parse_port_w0 = 32'h80040000;
  reg [31:0] parse_port_w1 = 32'h00001234;
  reg [31:0] parse_port_w3 = 32'd1;
  reg parse_sap = 1'b0;
  reg parse_out_ready = 1'b0;
  reg [13:0] parse_app_len = 14'd0;
  reg [19:0] parse_blocks = 20'd0;
  reg [2:0] parse_block_count = 3'd0;
  wire         pl_in_ready;
  wire         pl_out_vld;
  wire         pl_out_drop;
  wire [2:0]   pl_out_reason;
  wire [7:0]   pl_out_port;
  wire [1:0]   pl_out_type;
  wire [3:0]   pl_out_depth;
  wire [3:0]   pl_out_blk;
  wire [10:0]  pl_out_plen;
  wire [23:0]  pl_out_ts;
  wire         pc_in_ready;
  wire         pc_out_vld;
  wire         pc_out_drop;
  wire [2:0]   pc_out_reason;
  wire [7:0]   pc_out_port;
  wire [1:0]   pc_out_type;
  wire [3:0]   pc_out_depth;
  wire [3:0]   pc_out_blk;
  wire [10:0]  pc_out_plen;
  wire [23:0]  pc_out_ts;
  wire         pr_in_ready;
  wire         pr_out_vld;
  wire         pr_out_drop;
  wire [2:0]   pr_out_reason;
  wire [7:0]   pr_out_port;
  wire [1:0]   pr_out_type;
  wire [3:0]   pr_out_depth;
  wire [3:0]   pr_out_blk;
  wire [10:0]  pr_out_plen;
  wire [23:0]  pr_out_ts;
  wire [13:0] pl_app_len, pc_app_len;
  wire [19:0] pl_blocks, pc_blocks;
  wire [2:0] pl_block_count, pc_block_count;

  reg init_we = 1'b0;
  reg [12:0] init_addr = 13'd0;
  reg pb_in_vld = 1'b0;
  reg pb_in_drop = 1'b0;
  reg [7:0] pb_in_port = 8'd0;
  reg [1:0] pb_in_type = 2'd0;
  reg [3:0] pb_in_depth = 4'd1;
  reg [3:0] pb_in_blk = 4'd0;
  reg [10:0] pb_in_plen = 11'd0;
  reg [13:0] pb_in_app_len = 14'd0;
  reg [2:0] pb_in_block_count = 3'd0;
  reg hop_desc_rd = 1'b0;
  reg hop_msg_rd = 1'b0;
  reg [7:0] hop_port = 8'd0;
  reg [1:0] hop_type = 2'd0;
  wire         bl_in_ready;
  wire [31:0]  bl_desc_word;
  wire [3:0]   bl_cnt_word;
  wire         bl_free0;
  wire [3:0]   bl_free0_id;
  wire         bl_free1;
  wire [3:0]   bl_free1_id;
  wire         bl_ev_drop;
  wire         bl_ev_sample;
  wire         bl_ev_queue;
  wire         bl_ev_ovf;
  wire [31:0]  bl_deliver_cnt;
  wire [31:0]  bl_port_drop_cnt;
  wire [31:0]  bl_ovr_cnt;
  wire [31:0]  bl_qovf_cnt;
  wire         bc_in_ready;
  wire [31:0]  bc_desc_word;
  wire [3:0]   bc_cnt_word;
  wire         bc_free0;
  wire [3:0]   bc_free0_id;
  wire         bc_free1;
  wire [3:0]   bc_free1_id;
  wire         bc_ev_drop;
  wire         bc_ev_sample;
  wire         bc_ev_queue;
  wire         bc_ev_ovf;
  wire [31:0]  bc_deliver_cnt;
  wire [31:0]  bc_port_drop_cnt;
  wire [31:0]  bc_ovr_cnt;
  wire [31:0]  bc_qovf_cnt;
  wire         br_in_ready;
  wire [31:0]  br_desc_word;
  wire [3:0]   br_cnt_word;
  wire         br_free0;
  wire [3:0]   br_free0_id;
  wire         br_free1;
  wire [3:0]   br_free1_id;
  wire         br_ev_drop;
  wire         br_ev_sample;
  wire         br_ev_queue;
  wire         br_ev_ovf;
  wire [31:0]  br_deliver_cnt;
  wire [31:0]  br_port_drop_cnt;
  wire [31:0]  br_ovr_cnt;
  wire [31:0]  br_qovf_cnt;

  reg register_valid = 1'b0;
  reg [3:0] register_head = 4'd0;
  reg [19:0] register_blocks = 20'd0;
  reg [2:0] register_count = 3'd0;
  reg direct_mode = 1'b1;
  reg direct0_valid = 1'b0;
  reg [3:0] direct0_id = 4'd0;
  reg direct1_valid = 1'b0;
  reg [3:0] direct1_id = 4'd0;
  reg direct2_valid = 1'b0;
  reg [3:0] direct2_id = 4'd0;
  reg [3:0] lookup_block = 4'd0;
  wire [31:0] lookup_word;
  wire [15:0] free_mask;

  rx_ip_udp_parse #(.DW(208), .NUM_PORTS(4)) dut_parse_legacy (
    .clk(clk),
    // Z is the value of open optional metadata; keep the default-path test.
    .in_app_len(14'bz), .in_blocks(20'hzzzzz), .in_block_count(3'bzzz),
    .rst_sync(rst_sync),
    .in_vld(parse_in_vld),
    .in_desc(parse_desc),
    .in_w0(parse_w0),
    .port_w0(parse_port_w0),
    .port_w1(parse_port_w1),
    .port_w3(parse_port_w3),
    .sap_enable(parse_sap),
    .out_ready(parse_out_ready),
    .in_ready(pl_in_ready),
    .out_vld(pl_out_vld),
    .out_drop(pl_out_drop),
    .out_reason(pl_out_reason),
    .out_port(pl_out_port),
    .out_type(pl_out_type),
    .out_depth(pl_out_depth),
    .out_blk(pl_out_blk),
    .out_plen(pl_out_plen),
    .out_ts(pl_out_ts),
    .out_app_len(pl_app_len),
    .out_blocks(pl_blocks),
    .out_block_count(pl_block_count)
  );

  rx_ip_udp_parse #(.DW(208), .NUM_PORTS(4), .CHAIN_ENABLE(1)) dut_parse_chain (
    .clk(clk),
    .rst_sync(rst_sync),
    .in_vld(parse_in_vld),
    .in_desc(parse_desc),
    .in_w0(parse_w0),
    .port_w0(parse_port_w0),
    .port_w1(parse_port_w1),
    .port_w3(parse_port_w3),
    .sap_enable(parse_sap),
    .out_ready(parse_out_ready),
    .in_ready(pc_in_ready),
    .out_vld(pc_out_vld),
    .out_drop(pc_out_drop),
    .out_reason(pc_out_reason),
    .out_port(pc_out_port),
    .out_type(pc_out_type),
    .out_depth(pc_out_depth),
    .out_blk(pc_out_blk),
    .out_plen(pc_out_plen),
    .out_ts(pc_out_ts),
    .in_app_len(parse_app_len),
    .in_blocks(parse_blocks),
    .in_block_count(parse_block_count),
    .out_app_len(pc_app_len),
    .out_blocks(pc_blocks),
    .out_block_count(pc_block_count)
  );

  legacy_rx_ip_udp_parse_reference #(.DW(208), .NUM_PORTS(4)) ref_parse (
    .clk(clk),
    .rst_sync(rst_sync),
    .in_vld(parse_in_vld),
    .in_desc(parse_desc),
    .in_w0(parse_w0),
    .port_w0(parse_port_w0),
    .port_w1(parse_port_w1),
    .port_w3(parse_port_w3),
    .sap_enable(parse_sap),
    .out_ready(parse_out_ready),
    .in_ready(pr_in_ready),
    .out_vld(pr_out_vld),
    .out_drop(pr_out_drop),
    .out_reason(pr_out_reason),
    .out_port(pr_out_port),
    .out_type(pr_out_type),
    .out_depth(pr_out_depth),
    .out_blk(pr_out_blk),
    .out_plen(pr_out_plen),
    .out_ts(pr_out_ts)
  );

  rx_port_buf #(.NUM_PORTS(4)) dut_pb_legacy (
    .clk(clk),
    .in_app_len(14'bz), .in_block_count(3'bzzz),
    .rst_sync(rst_sync),
    .init_we(init_we),
    .init_addr(init_addr),
    .in_vld(pb_in_vld),
    .in_drop(pb_in_drop),
    .in_port(pb_in_port),
    .in_type(pb_in_type),
    .in_depth(pb_in_depth),
    .in_blk(pb_in_blk),
    .in_plen(pb_in_plen),
    .hop_desc_rd(hop_desc_rd),
    .hop_msg_rd(hop_msg_rd),
    .hop_port(hop_port),
    .hop_type(hop_type),
    .in_ready(bl_in_ready),
    .desc_word(bl_desc_word),
    .cnt_word(bl_cnt_word),
    .free0(bl_free0),
    .free0_id(bl_free0_id),
    .free1(bl_free1),
    .free1_id(bl_free1_id),
    .ev_drop(bl_ev_drop),
    .ev_sample(bl_ev_sample),
    .ev_queue(bl_ev_queue),
    .ev_ovf(bl_ev_ovf),
    .deliver_cnt(bl_deliver_cnt),
    .port_drop_cnt(bl_port_drop_cnt),
    .ovr_cnt(bl_ovr_cnt),
    .qovf_cnt(bl_qovf_cnt)
  );

  rx_port_buf #(.NUM_PORTS(4), .CHAIN_ENABLE(1)) dut_pb_chain (
    .clk(clk),
    .rst_sync(rst_sync),
    .init_we(init_we),
    .init_addr(init_addr),
    .in_vld(pb_in_vld),
    .in_drop(pb_in_drop),
    .in_port(pb_in_port),
    .in_type(pb_in_type),
    .in_depth(pb_in_depth),
    .in_blk(pb_in_blk),
    .in_plen(pb_in_plen),
    .hop_desc_rd(hop_desc_rd),
    .hop_msg_rd(hop_msg_rd),
    .hop_port(hop_port),
    .hop_type(hop_type),
    .in_ready(bc_in_ready),
    .desc_word(bc_desc_word),
    .cnt_word(bc_cnt_word),
    .free0(bc_free0),
    .free0_id(bc_free0_id),
    .free1(bc_free1),
    .free1_id(bc_free1_id),
    .ev_drop(bc_ev_drop),
    .ev_sample(bc_ev_sample),
    .ev_queue(bc_ev_queue),
    .ev_ovf(bc_ev_ovf),
    .deliver_cnt(bc_deliver_cnt),
    .port_drop_cnt(bc_port_drop_cnt),
    .ovr_cnt(bc_ovr_cnt),
    .qovf_cnt(bc_qovf_cnt),
    .in_app_len(pb_in_app_len),
    .in_block_count(pb_in_block_count)
  );

  legacy_rx_port_buf_reference #(.NUM_PORTS(4)) ref_pb (
    .clk(clk),
    .rst_sync(rst_sync),
    .init_we(init_we),
    .init_addr(init_addr),
    .in_vld(pb_in_vld),
    .in_drop(pb_in_drop),
    .in_port(pb_in_port),
    .in_type(pb_in_type),
    .in_depth(pb_in_depth),
    .in_blk(pb_in_blk),
    .in_plen(pb_in_plen),
    .hop_desc_rd(hop_desc_rd),
    .hop_msg_rd(hop_msg_rd),
    .hop_port(hop_port),
    .hop_type(hop_type),
    .in_ready(br_in_ready),
    .desc_word(br_desc_word),
    .cnt_word(br_cnt_word),
    .free0(br_free0),
    .free0_id(br_free0_id),
    .free1(br_free1),
    .free1_id(br_free1_id),
    .ev_drop(br_ev_drop),
    .ev_sample(br_ev_sample),
    .ev_queue(br_ev_queue),
    .ev_ovf(br_ev_ovf),
    .deliver_cnt(br_deliver_cnt),
    .port_drop_cnt(br_port_drop_cnt),
    .ovr_cnt(br_ovr_cnt),
    .qovf_cnt(br_qovf_cnt)
  );

  rx_chain_metadata dut_metadata (
    .clk(clk),
    .rst_sync(rst_sync),
    .register_valid(register_valid),
    .register_head(register_head),
    .register_blocks(register_blocks),
    .register_count(register_count),
    .release0_valid(direct_mode ? direct0_valid : bc_free0),
    .release0_id(direct_mode ? direct0_id : bc_free0_id),
    .release1_valid(direct_mode ? direct1_valid : bc_free1),
    .release1_id(direct_mode ? direct1_id : bc_free1_id),
    .release2_valid(direct2_valid),
    .release2_id(direct2_id),
    .free_mask(free_mask),
    .lookup_block(lookup_block),
    .lookup_word(lookup_word)
  );

  task check;
    input ok;
    input [8*120-1:0] what;
    begin
      if (ok !== 1'b1) begin
        $display("RX_CHAIN_METADATA FAIL cycle=%0d case=%0d %0s", cycles, cases, what);
        $fatal(1);
      end
    end
  endtask

  task tick;
    begin @(posedge clk); #1; end
  endtask

  task mark;
    input [8*120-1:0] what;
    begin
      cases = cases + 1;
      $display("RX_CHAIN_METADATA CASE %0d %0s", cases, what);
    end
  endtask

  function [15:0] blocks_mask;
    input [19:0] blocks;
    input [2:0] count;
    integer k;
    begin
      blocks_mask = 16'd0;
      for (k = 0; k < 5; k = k + 1)
        if (k < count) blocks_mask = blocks_mask | (16'h0001 << blocks[4*k +: 4]);
    end
  endfunction

  always @(posedge clk) begin
    cycles = cycles + 1;
    if (rst_sync) model_owned <= 16'd0;
    else if (model_enabled) begin
      check((free_mask & ~model_owned) == 16'd0, "conservation: returned block was owned");
      model_register_mask = register_valid ? blocks_mask(register_blocks, register_count) : 16'd0;
      check((model_register_mask & model_owned) == 16'd0, "conservation: no overlapping allocation");
      check((model_register_mask & 16'h003F) == 16'd0, "conservation: RX-only allocation");
      model_owned <= (model_owned | model_register_mask) & ~free_mask;
    end
  end

  // Compare every stable cycle, including release pulse timing and empty descs.
  always @(negedge clk) begin
    if (oracle_enabled) begin
      check({pl_in_ready, pl_out_vld, pl_out_drop, pl_out_reason, pl_out_port, pl_out_type, pl_out_depth, pl_out_blk, pl_out_plen, pl_out_ts} === {pr_in_ready, pr_out_vld, pr_out_drop, pr_out_reason, pr_out_port, pr_out_type, pr_out_depth, pr_out_blk, pr_out_plen, pr_out_ts},
            "legacy parser equals frozen pre-change implementation each cycle");
      check({pc_in_ready, pc_out_vld, pc_out_drop, pc_out_reason, pc_out_port, pc_out_type, pc_out_depth, pc_out_blk, pc_out_plen, pc_out_ts} === {pl_in_ready, pl_out_vld, pl_out_drop, pl_out_reason, pl_out_port, pl_out_type, pl_out_depth, pl_out_blk, pl_out_plen, pl_out_ts},
            "chain parser preserves all original outputs and handshake timing");
      check({bl_in_ready, bl_desc_word, bl_cnt_word, bl_free0, bl_free0_id, bl_free1, bl_free1_id, bl_ev_drop, bl_ev_sample, bl_ev_queue, bl_ev_ovf, bl_deliver_cnt, bl_port_drop_cnt, bl_ovr_cnt, bl_qovf_cnt} === {br_in_ready, br_desc_word, br_cnt_word, br_free0, br_free0_id, br_free1, br_free1_id, br_ev_drop, br_ev_sample, br_ev_queue, br_ev_ovf, br_deliver_cnt, br_port_drop_cnt, br_ovr_cnt, br_qovf_cnt},
            "legacy PB descriptor/events/free/stats equal frozen implementation");
      check({bc_in_ready, bc_cnt_word, bc_free0, bc_free0_id, bc_free1, bc_free1_id, bc_ev_drop, bc_ev_sample, bc_ev_queue, bc_ev_ovf, bc_deliver_cnt, bc_port_drop_cnt, bc_ovr_cnt, bc_qovf_cnt} === {bl_in_ready, bl_cnt_word, bl_free0, bl_free0_id, bl_free1, bl_free1_id, bl_ev_drop, bl_ev_sample, bl_ev_queue, bl_ev_ovf, bl_deliver_cnt, bl_port_drop_cnt, bl_ovr_cnt, bl_qovf_cnt},
            "chain PB retains legacy control/release/stats timing");
      check(bc_desc_word[31:20] === bl_desc_word[31:20], "PB descriptor status/count/head preserved");
      check(free_mask[5:0] === 6'd0, "free mask excludes TX blocks");
    end
  end

  task reset_and_init;
    begin
      parse_in_vld = 1'b0; parse_out_ready = 1'b0;
      pb_in_vld = 1'b0; hop_desc_rd = 1'b0; hop_msg_rd = 1'b0;
      init_we = 1'b0; register_valid = 1'b0;
      direct0_valid = 1'b0; direct1_valid = 1'b0; direct2_valid = 1'b0;
      rst_sync = 1'b1; tick; tick; rst_sync = 1'b0;
      init_we = 1'b1;
      for (sweep = 0; sweep < 4; sweep = sweep + 1) begin
        init_addr = sweep; tick;
      end
      init_we = 1'b0; tick;
    end
  endtask

  task register_chain;
    input [3:0] head;
    input [19:0] blocks;
    input [2:0] count;
    begin
      register_head = head; register_blocks = blocks; register_count = count;
      register_valid = 1'b1; tick; register_valid = 1'b0; #0.1;
    end
  endtask

  task check_lookup;
    input [3:0] id;
    input [31:0] expected;
    begin
      lookup_block = id; #0.1;
      if (lookup_word !== expected) begin
        $display("lookup block=%0d actual=%h expected=%h", id, lookup_word, expected);
        check(1'b0, "lookup membership/next fields");
      end
    end
  endtask

  task check_members;
    input [15:0] expected;
    integer k;
    begin
      for (k = 0; k < 16; k = k + 1) begin
        lookup_block = k; #0.1;
        check(lookup_word[5] === expected[k], "whole-chain membership matches ownership");
        check(lookup_word[31:6] === 26'd0, "lookup reserved bits zero");
        if (!expected[k]) check(lookup_word === 32'd0, "released/unregistered lookup is all zero");
      end
    end
  endtask

  task clear_direct_release;
    begin
      direct0_valid = 1'b0; direct1_valid = 1'b0; direct2_valid = 1'b0; #0.1;
    end
  endtask

  task return_head;
    input [3:0] head;
    input [15:0] expected_mask;
    begin
      direct0_valid = 1'b1; direct0_id = head; #0.1;
      check(free_mask === expected_mask, "head expands into entire expected sparse mask");
      tick; clear_direct_release;
    end
  endtask

  task offer;
    input [7:0] port_id;
    input [1:0] port_type;
    input [3:0] depth;
    input [3:0] head;
    input [19:0] blocks;
    input [2:0] count;
    input [13:0] app_len;
    input [10:0] legacy_len;
    input drop;
    begin
      // Emulate the parser input ownership handoff one edge before its held
      // descriptor reaches PB. Even drops/full-queue rejects own a table row.
      register_chain(head, blocks, count);
      pb_in_port = port_id; pb_in_type = port_type; pb_in_depth = depth;
      pb_in_blk = head; pb_in_plen = legacy_len; pb_in_app_len = app_len;
      pb_in_block_count = count; pb_in_drop = drop; pb_in_vld = 1'b1;
      #0.1; check(bc_in_ready && bl_in_ready, "PB accepts offered descriptor");
      tick; pb_in_vld = 1'b0; #0.1;
    end
  endtask

  task desc_read;
    input [7:0] port_id;
    input [1:0] port_type;
    begin
      hop_port = port_id; hop_type = port_type; hop_desc_rd = 1'b1;
      #0.1; check(!bc_in_ready && !bl_in_ready, "host descriptor read blocks input");
      tick; hop_desc_rd = 1'b0; #0.1;
    end
  endtask

  task message_read;
    input [7:0] port_id;
    input [1:0] port_type;
    begin
      hop_port = port_id; hop_type = port_type; hop_msg_rd = 1'b1;
      #0.1; check(!bc_in_ready && !bl_in_ready, "host message read blocks input");
      tick; hop_msg_rd = 1'b0; #0.1;
    end
  endtask

  initial begin
    #100000;
    $display("RX_CHAIN_METADATA FAIL timeout");
    $fatal(1);
  end

  initial begin
    reset_and_init; oracle_enabled = 1'b1;

    // Parser's optional inputs are deliberately omitted on dut_parse_legacy.
    parse_desc[173:163] = 11'd1479; parse_desc[162:159] = 4'd6;
    parse_desc[147:124] = 24'hABCDEF; parse_desc[15:0] = 16'h1234;
    parse_w0 = 32'h00001000; parse_port_w3 = 32'd0;
    parse_app_len = 14'd8192; parse_blocks = 20'hFEDC6; parse_block_count = 3'd5;
    parse_in_vld = 1'b1; tick; parse_in_vld = 1'b0;
    check(pl_out_vld && !pl_out_drop && pl_out_depth == 4'd1, "legacy descriptor accepted/depth zero maps to one");
    check(pl_app_len == 14'd1479 && pl_blocks == 20'h00006 && pl_block_count == 3'd1, "default sideband uses legacy length/head only");
    check(pc_app_len == 14'd8192 && pc_blocks == 20'hFEDC6 && pc_block_count == 3'd5, "all chain sidebands captured together");
    check(pc_out_plen == 11'd1479 && pc_out_ts == 24'hABCDEF, "legacy length/timestamp unchanged in chain mode");
    mark("parser_legacy_and_full8192_capture");

    parse_in_vld = 1'b1; parse_desc[173:163] = 11'd17; parse_desc[162:159] = 4'd9;
    parse_app_len = 14'd4097; parse_blocks = 20'h000D9; parse_block_count = 3'd2;
    repeat (3) begin
      #0.1; check(!pc_in_ready && !pl_in_ready, "held descriptor applies backpressure");
      tick;
      check(pc_out_blk == 4'd6 && pc_app_len == 14'd8192 && pc_blocks == 20'hFEDC6 && pc_block_count == 3'd5, "stalled sidebands remain stable despite changed inputs");
    end
    mark("parser_held_descriptor_sidebands");

    parse_out_ready = 1'b1; parse_port_w0 = 32'h80050000; parse_port_w3 = 32'd3;
    tick;
    check(pc_out_vld && pc_out_blk == 4'd9 && pc_out_type == 2'd1 && pc_out_depth == 4'd3, "turnover replaces descriptor without bubble");
    check(pc_app_len == 14'd4097 && pc_blocks == 20'h000D9 && pc_block_count == 3'd2 && pc_out_plen == 11'd17, "turnover replaces all sidebands");
    mark("parser_ready_turnover");

    parse_desc[15:0] = 16'hFFFF; parse_desc[162:159] = 4'd10;
    parse_app_len = 14'd5000; parse_blocks = 20'h000BA; parse_block_count = 3'd2; tick;
    check(pc_out_drop && pc_out_reason == 3'd4 && pc_out_blk == 4'd10, "destination-port mismatch drop");
    check(pc_app_len == 14'd5000 && pc_blocks == 20'h000BA && pc_block_count == 3'd2, "drop descriptor retains chain ownership");
    parse_in_vld = 1'b0; tick; check(!pc_out_vld && !pl_out_vld, "output consumed without input");
    mark("parser_drop_preserves_chain_ownership");

    parse_desc[15:0] = 16'h1234; parse_port_w0 = 32'h80060000; parse_in_vld = 1'b1;
    parse_sap = 1'b0; tick; check(pc_out_drop && pc_out_reason == 3'd5, "disabled SAP drop remains legacy");
    parse_sap = 1'b1; tick; check(!pc_out_drop && pc_out_type == 2'd2, "enabled SAP handoff remains legacy");
    parse_in_vld = 1'b0; tick; mark("parser_SAP_legacy_verdicts");

    reset_and_init;
    check(!pc_out_vld && pc_app_len == 14'd0 && pc_blocks == 20'd0 && pc_block_count == 3'd0, "parser reset clears sidebands");
    check(pl_app_len == 14'd0 && pl_blocks == 20'd0 && pl_block_count == 3'd0, "default sidebands reset deterministically");
    mark("parser_reset_clears_held_metadata");

    // Metadata-only tests; all expected masks/pointers are independent constants.
    direct_mode = 1'b1;
    register_chain(4'd6, 20'h00C96, 3'd3);
    register_chain(4'd7, 20'h00FA7, 3'd3);
    check_lookup(4'd6, 32'h00000039); check_lookup(4'd9, 32'h0000003C);
    check_lookup(4'd12, 32'h00000020); check_lookup(4'd7, 32'h0000003A);
    check_lookup(4'd10, 32'h0000003F); check_lookup(4'd15, 32'h00000020);
    check_members(16'h96C0); mark("metadata_sparse_two_chains_and_lookup_layout");

    direct0_valid = 1'b1; direct0_id = 4'd6; direct1_valid = 1'b1; direct1_id = 4'd7; #0.1;
    check(free_mask === 16'h96C0, "two heads simultaneously return both entire chains");
    check_lookup(4'd12, 32'h20); tick; clear_direct_release; check_members(16'd0);
    mark("metadata_two_head_atomic_release");

    register_chain(4'd8, 20'hFFFF8, 3'd1);
    check_lookup(4'd8, 32'h20); check_lookup(4'd15, 32'd0);
    direct2_valid = 1'b1; direct2_id = 4'd8; #0.1; check(free_mask === 16'h0100, "third release port handles single-block chain");
    tick; clear_direct_release; check_members(16'd0);
    direct0_valid = 1'b1; direct0_id = 4'd10; direct1_valid = 1'b1; direct1_id = 4'd5;
    direct2_valid = 1'b1; direct2_id = 4'd2; #0.1; check(free_mask === 16'h0400, "untracked head fallback and TX exclusion");
    tick; clear_direct_release; mark("metadata_release2_single_and_fallback_filter");

    register_chain(4'd6, 20'hFDB86, 3'd5);
    direct0_valid = 1'b1; direct0_id = 4'd6; direct1_valid = 1'b1; direct1_id = 4'd6;
    direct2_valid = 1'b1; direct2_id = 4'd6; #0.1; check(free_mask === 16'hA940, "three duplicate heads OR once");
    tick; #0.1; check(free_mask === 16'h0040, "after reclaim duplicate head falls back to single ID");
    clear_direct_release; check_members(16'd0); mark("metadata_five_sparse_blocks_duplicate_release");

    register_chain(4'd8, 20'h00008, 3'd1);
    register_valid = 1'b1; register_head = 4'd6; register_blocks = 20'h000F6; register_count = 3'd2;
    direct0_valid = 1'b1; direct0_id = 4'd8; #0.1; check(free_mask === 16'h0100, "disjoint register and release mask");
    tick; register_valid = 1'b0; clear_direct_release;
    check_members(16'h8040); check_lookup(4'd6, 32'h3F); check_lookup(4'd15, 32'h20);
    register_valid = 1'b1; register_head = 4'd7; register_blocks = 20'h000F7; register_count = 3'd2;
    direct0_valid = 1'b1; direct0_id = 4'd6; #0.1; check(free_mask === 16'h8040, "old head returns prior chain on conflicting registration");
    tick; register_valid = 1'b0; clear_direct_release; check_members(16'd0);
    mark("metadata_disjoint_concurrency_release_priority");

    register_chain(4'd6, 20'h000A6, 3'd2); return_head(4'd6, 16'h0440);
    register_chain(4'd6, 20'h00BD6, 3'd3);
    check_lookup(4'd6, 32'h3D); check_lookup(4'd13, 32'h3B); check_lookup(4'd11, 32'h20);
    check_lookup(4'd10, 32'd0); return_head(4'd6, 16'h2840); check_members(16'd0);
    mark("metadata_old_head_reused_without_stale_links");

    register_chain(4'd6, 20'h00006, 3'd0); check_members(16'd0);
    register_chain(4'd6, 20'hFEDC6, 3'd6); check_members(16'd0);
    register_chain(4'd6, 20'h00056, 3'd2); check_members(16'd0);
    register_chain(4'd6, 20'h00066, 3'd2); check_members(16'd0);
    register_chain(4'd7, 20'h00006, 3'd1); check_members(16'd0);
    register_chain(4'd6, 20'h00086, 3'd2);
    register_chain(4'd7, 20'h00087, 3'd2); check_members(16'h0140);
    check_lookup(4'd6, 32'h38); check_lookup(4'd8, 32'h20); return_head(4'd6, 16'h0140);
    mark("metadata_invalid_registration_atomic_ignore");

    register_chain(4'd6, 20'h00096, 3'd2);
    repeat (3) begin check_lookup(4'd6, 32'h39); check_lookup(4'd9, 32'h20); tick; end
    direct0_valid = 1'b1; direct0_id = 4'd6; rst_sync = 1'b1; #0.1;
    check(free_mask === 16'd0, "reset suppresses release mask"); check_lookup(4'd6, 32'd0);
    tick; direct0_valid = 1'b0; rst_sync = 1'b0; check_members(16'd0);
    mark("metadata_lookup_read_only_and_reset");

    reset_and_init; direct_mode = 1'b0; model_enabled = 1'b1; hop_port = 8'd0; hop_type = 2'd0;
    offer(8'd0, 2'd0, 4'd1, 4'd6, 20'hFDB86, 3'd5, 14'd8192, 11'd23, 1'b0);
    check(bc_desc_word === {1'b1,1'b1,1'b0,1'b0,4'd1,4'd6,3'd5,3'd0,14'd8192}, "chain PORT_DESC exact 8192-byte format");
    check(bl_desc_word === {1'b1,1'b1,1'b0,1'b0,4'd1,4'd6,9'd0,11'd23}, "legacy PORT_DESC exact original format");
    check_members(16'hA940); check(model_owned === 16'hA940, "conservation after first five-block sampling message");
    mark("PB_full8192_and_legacy_descriptor");

    desc_read(8'd0, 2'd0); check(!bc_desc_word[30] && !bc_desc_word[29], "descriptor read clears fresh/ovf");
    offer(8'd0, 2'd0, 4'd1, 4'd7, 20'h000A7, 3'd2, 14'd3000, 11'd31, 1'b0);
    check(!bc_free0 && !bc_free1 && free_mask == 16'd0, "seen old head remains pinned with all members");
    check(bc_desc_word === {1'b1,1'b1,1'b1,1'b1,4'd1,4'd7,3'd2,3'd0,14'd3000}, "sampling overwrite pins prior head and shows new full length");
    check_members(16'hADC0); mark("PB_sampling_seen_pins_whole_chain");

    desc_read(8'd0, 2'd0); message_read(8'd0, 2'd0);
    check(bc_free0 && bc_free0_id == 4'd6 && bc_free1 && bc_free1_id == 4'd7, "sampling release emits pinned and seen heads together");
    check(free_mask === 16'hADC0, "two PB releases expand both complete payload chains");
    tick; check_members(16'd0); check(model_owned == 16'd0 && bc_cnt_word == 4'd0, "two sampling chains completely reclaimed");
    mark("PB_sampling_two_heads_same_cycle_reclaim");

    offer(8'd0, 2'd0, 4'd1, 4'd6, 20'h00086, 3'd2, 14'd4096, 11'd40, 1'b0);
    offer(8'd0, 2'd0, 4'd1, 4'd7, 20'h00097, 3'd2, 14'd4100, 11'd41, 1'b0);
    check(bc_free0 && bc_free0_id == 4'd6 && !bc_free1 && free_mask === 16'h0140, "unseen sampling overwrite returns entire old chain");
    tick; check_members(16'h0280); check_lookup(4'd7, 32'h39);
    desc_read(8'd0, 2'd0); message_read(8'd0, 2'd0); check(free_mask === 16'h0280, "seen replacement reclaimed");
    tick; check_members(16'd0); mark("PB_sampling_unseen_overwrite_reclaims_chain");

    offer(8'd0, 2'd0, 4'd1, 4'd6, 20'h00086, 3'd2, 14'd500, 11'd50, 1'b0); desc_read(8'd0, 2'd0);
    offer(8'd0, 2'd0, 4'd1, 4'd7, 20'h00097, 3'd2, 14'd600, 11'd51, 1'b0); desc_read(8'd0, 2'd0);
    offer(8'd0, 2'd0, 4'd1, 4'd10, 20'h000CA, 3'd2, 14'd700, 11'd52, 1'b0);
    check(bc_free0 && bc_free0_id == 4'd6 && free_mask === 16'h0140, "second seen overwrite releases oldest pinned chain");
    tick; check_members(16'h1680);
    message_read(8'd0, 2'd0); check(bc_free0 && bc_free0_id == 4'd7 && !bc_free1 && free_mask === 16'h0280, "MSG_RD releases pinned chain while unseen new head stays valid");
    tick; check_members(16'h1400); check(bc_cnt_word == 4'd1 && bc_desc_word[23:20] == 4'd10, "unseen sampling message remains current");
    desc_read(8'd0, 2'd0); message_read(8'd0, 2'd0); check(free_mask === 16'h1400, "remaining sampling chain released");
    tick; check_members(16'd0); mark("PB_sampling_replaces_pin_and_retains_unseen_head");

    hop_port = 8'd1; hop_type = 2'd1;
    offer(8'd1, 2'd1, 4'd3, 4'd6, 20'h000A6, 3'd2, 14'd2007, 11'd61, 1'b0);
    offer(8'd1, 2'd1, 4'd3, 4'd7, 20'h00D97, 3'd3, 14'd8192, 11'd62, 1'b0);
    offer(8'd1, 2'd1, 4'd3, 4'd8, 20'h00008, 3'd1, 14'd17, 11'd63, 1'b0);
    check(bc_cnt_word == 4'd3 && bc_desc_word[23:20] == 4'd6 && bc_desc_word[19:17] == 3'd2 && bc_desc_word[13:0] == 14'd2007, "queue head and first full length remain stable");
    check_lookup(4'd6, 32'h3A); check_lookup(4'd7, 32'h39); check_lookup(4'd9, 32'h3D);
    check_members(16'h27C0); mark("PB_queue_multiple_messages_payload_links_independent");

    offer(8'd1, 2'd1, 4'd3, 4'd11, 20'h000FB, 3'd2, 14'd8191, 11'd64, 1'b0);
    check(bc_free0 && bc_free0_id == 4'd11 && bc_ev_drop && bc_ev_ovf && free_mask === 16'h8800, "full queue drops new head and returns whole new chain");
    check(bc_cnt_word == 4'd3 && bc_desc_word[29] && bc_qovf_cnt == 32'd1, "full queue keeps FIFO/count and marks overflow once");
    tick; check_members(16'h27C0); mark("PB_queue_full_drop_entire_new_chain");

    message_read(8'd1, 2'd1); check(free_mask === 16'h0440, "FIFO pop returns first payload chain");
    check(bc_cnt_word == 4'd2 && bc_desc_word[23:20] == 4'd7 && bc_desc_word[19:17] == 3'd3 && bc_desc_word[13:0] == 14'd8192 && bc_desc_word[30], "FIFO second message carries independent count/full8192");
    tick; check_members(16'h2380);
    message_read(8'd1, 2'd1); check(free_mask === 16'h2280, "FIFO pop returns second sparse chain");
    check(bc_cnt_word == 4'd1 && bc_desc_word[23:20] == 4'd8 && bc_desc_word[19:17] == 3'd1 && bc_desc_word[13:0] == 14'd17, "FIFO next is message head not payload next");
    tick; message_read(8'd1, 2'd1); check(free_mask === 16'h0100 && bc_cnt_word == 4'd0, "FIFO final single block pop");
    tick; check_members(16'd0); check(model_owned == 16'd0, "FIFO/drop ownership completely conserved");
    mark("PB_queue_FIFO_order_and_complete_reclaim");

    hop_port = 8'd2; hop_type = 2'd1;
    offer(8'd2, 2'd1, 4'd2, 4'd6, 20'h00C96, 3'd3, 14'd7000, 11'd70, 1'b1);
    check(bc_ev_drop && bc_free0 && bc_free0_id == 4'd6 && free_mask === 16'h1240, "parser drop reaches PB and returns all chain members");
    check(bc_cnt_word == 4'd0 && bc_port_drop_cnt == 32'd1, "parser drop doesn't enqueue and increments port drop once");
    tick; check_members(16'd0); mark("PB_parse_drop_whole_chain_return");

    offer(8'd2, 2'd1, 4'd2, 4'd6, 20'h000E6, 3'd2, 14'd8151, 11'd71, 1'b0);
    register_chain(4'd7, 20'h000F7, 3'd2);
    pb_in_port = 8'd2; pb_in_type = 2'd1; pb_in_depth = 4'd2; pb_in_blk = 4'd7;
    pb_in_plen = 11'd72; pb_in_app_len = 14'd8191; pb_in_block_count = 3'd2; pb_in_drop = 1'b0; pb_in_vld = 1'b1;
    hop_desc_rd = 1'b1; #0.1; check(!bc_in_ready, "host priority stalls arriving message");
    tick; check(bc_cnt_word == 4'd1 && !bc_ev_queue, "host read causes no duplicate acceptance");
    hop_desc_rd = 1'b0; tick; pb_in_vld = 1'b0;
    check(bc_cnt_word == 4'd2 && bc_ev_queue, "held incoming message accepted after host operation");
    message_read(8'd2, 2'd1); check(free_mask === 16'h4040, "stalled queue first head reclaim");
    tick; message_read(8'd2, 2'd1); check(free_mask === 16'h8080, "stalled queue second head reclaim");
    tick; check_members(16'd0); mark("PB_host_priority_stalls_then_accepts_once");

    // External third head release represents a SAP ownership return; no SAP RTL
    // is compiled or edited by this standalone metadata TB.
    register_chain(4'd6, 20'h000C6, 3'd2);
    direct2_valid = 1'b1; direct2_id = 4'd6; #0.1; check(free_mask === 16'h1040, "external third head return expands recorded chain");
    tick; direct2_valid = 1'b0; check_members(16'd0);
    check(model_owned == 16'd0, "all integrated chain ownership returned");
    check(bc_deliver_cnt == 32'd12 && bc_ovr_cnt == 32'd4 && bc_qovf_cnt == 32'd1 && bc_port_drop_cnt == 32'd1, "PB deliver/overwrite/full/drop statistics match event counts");
    mark("PB_external_release2_and_final_conservation_stats");

    tick;
    $display("RX_CHAIN_METADATA PASS cases=%0d cycles=%0d", cases, cycles);
    $finish;
  end
endmodule

// Frozen baseline reference: original parser, changing only the module name.
// =====================================================================
// rx_ip_udp_parse.v —— RX 后级解析与端口匹配（§7.12），v0.5.16 接入 AFDX_top
// 输入: RM forward 的描述符（DW=174：[173:163] payload_len，[162:159] blk，
//   [158:148] len，[15:0] UDP dport，其余同 rx_ic 头注释）。
// P1（IP Total Length = 28+L、UDP Length = 8+L、SN 位置、IP/UDP 校验）已由
//   mac_rx_if 在收字节时流式核对，坏帧根本不产生描述符（O-04/O-05，不先交付后
//   撤销），本模块不再回读 PMEM。
// P2 端口匹配（v0.5.16 定案，见设计书 §7.13 实现状态）:
//   port = RX_VL_CFG.w0.port_base[11:0]；须 < NUM_PORTS、端口表 w0.valid=1、
//   w0[18] dir=1（RX 端口）、w0[17:16] type ∈ {0 采样, 1 队列}、端口表
//   w1[15:0] == 帧 UDP 目的端口。SAP(type=2) 在 sap_enable 时交给顶层
//   管理面 descriptor handoff；关断时按 R_SAP 丢弃并计数；type=3 保留同 R_CFG。
// 输出: 每个输入恰好一个结果 {drop, reason, port, type, depth, blk, plen}，
//   out_vld 保持到 out_ready；drop=1 时由 rx_port_buf 归还块（不占 free_pipe）。
// 端口表字由顶层组合读出（port_w0/w1/w3 按 in_w0.port_base 索引）；BRAM 化
//   时改为 1 拍同步读 + 1 拍比较（§7.12 P2 两拍）。
// 时钟/复位: clk / rst_sync（§4.2）。
// =====================================================================
`timescale 1 ns / 1 ps
module legacy_rx_ip_udp_parse_reference #(
  parameter integer DW        = 174,
  parameter integer NUM_PORTS = 256
) (
  input  wire          clk,
  input  wire          rst_sync,
  input  wire          in_vld,
  output wire          in_ready,
  input  wire [DW-1:0] in_desc,
  input  wire [31:0]   in_w0,          // RX_VL_CFG w0 of the frame's VL
  input  wire [31:0]   port_w0,        // port table w0 @ in_w0.port_base
  input  wire [31:0]   port_w1,        // port table w1 (UDP dst port [15:0])
  input  wire [31:0]   port_w3,        // port table w3 (queue depth [3:0])
  input  wire          sap_enable,     // CTL.SNMP_EN: enable SAP -> mgmt handoff
  output reg           out_vld,
  input  wire          out_ready,
  output reg           out_drop,
  output reg  [2:0]    out_reason,
  output reg  [7:0]    out_port,
  output reg  [1:0]    out_type,
  output reg  [3:0]    out_depth,
  output reg  [3:0]    out_blk,
  output reg  [10:0]   out_plen,
  output reg  [23:0]   out_ts
);
  localparam [2:0] R_OK=3'd0, R_RANGE=3'd1, R_CFG=3'd2, R_DIR=3'd3,
                   R_DPORT=3'd4, R_SAP=3'd5;
  wire [11:0] pbase = in_w0[23:12];
  wire range_ok = (pbase < NUM_PORTS);
  reg [2:0] rsn;
  always @* begin
    if (!range_ok)                     rsn = R_RANGE;
    else if (!port_w0[31])             rsn = R_CFG;
    else if (!port_w0[18])             rsn = R_DIR;
    else if (port_w0[17:16] == 2'd2 && !sap_enable) rsn = R_SAP;
    else if (port_w0[17:16] == 2'd3)   rsn = R_CFG;
    else if (port_w1[15:0] != in_desc[15:0]) rsn = R_DPORT;
    else                               rsn = R_OK;
  end
  assign in_ready = !rst_sync && (!out_vld || out_ready);
  always @(posedge clk) begin
    if (rst_sync) begin
      out_vld <= 1'b0; out_drop <= 1'b0; out_reason <= R_OK; out_port <= 8'd0;
      out_type <= 2'd0; out_depth <= 4'd0; out_blk <= 4'd0; out_plen <= 11'd0;
      out_ts <= 24'd0;
    end else if (in_vld && in_ready) begin
      out_vld    <= 1'b1;
      out_drop   <= (rsn != R_OK);
      out_reason <= rsn;
      out_port   <= pbase[7:0];
      out_type   <= port_w0[17:16];
      out_depth  <= (port_w3[3:0] == 4'd0) ? 4'd1 : port_w3[3:0];
      out_blk    <= in_desc[162:159];
      out_plen   <= in_desc[173:163];
      out_ts     <= in_desc[147:124];
    end else if (out_ready) out_vld <= 1'b0;
  end
endmodule

// Frozen baseline reference: original PB, changing only the module name.
// =====================================================================
// rx_port_buf.v —— RX 端口缓冲：采样/队列端口、主机读取与块回收（§7.13）
// v0.5.16 接入 AFDX_top（rx_ip_udp_parse 之后）。数据不搬移：消息就是
// mac_rx_if 写好的 PMEM 块，本模块只管描述符和块的所有权。
// 主机协议（v0.5.16 定案，设计书 §7.13 实现状态 / §7.14）:
//   1) 读 PORT_DESC[p]（0x8180+p，端口表 w0[18]=1 的 RX 端口）:
//      [31] valid  [30] fresh  [29] ovf  [28] pin  [27:24] cnt
//      [23:20] blk  [19:11] 0  [10:0] 载荷字节数 L
//      读即清 fresh 与 ovf，并把当前头消息标为"主机已看见"（seen）。
//   2) 读载荷：PMEM 字地址 0x8800 + blk*0x200 + (42+i)/4，大端字节序
//      （字节 42+i 在 [31-8*((42+i)%4) -: 8]）；运行期允许读 RX 块。
//   3) 写 MSG_RD[p]（0x8380+p，数据忽略）释放:
//      采样端口 —— 释放被钉住的旧块（若有）；若头消息已 seen，再释放它并清 valid；
//      队列端口 —— 弹出头消息并释放其块，下一条成为新头（fresh=1）。
//   4) MSG_CNT[p]（0x8480+p，只读）= 当前消息数 cnt。
// 采样端口: 新消息覆盖旧消息（ovr_cnt+1、ovf=1）。若旧消息已被主机读过描述符
//   （seen，主机可能正在读载荷），旧块不立即回收而被"钉住"（pin），在下一次
//   MSG_RD 时释放；已有钉住块时先释放较早的那个。未 seen 的旧块立即回收。
// 队列端口: 深度 = 端口表 w3[3:0]（0 按 1），满则丢新帧（q_ovf+1、ovf=1、计入
//   丢弃合计），对端不可见（§7.13）。队列用块链 nxt[blk]（同 tx_port_buf）。
// 事件串行: 每拍至多一个事件；主机操作优先，解析结果顺延（in_ready=0）。
//   每个事件至多释放 2 块（free0/free1，接 rx_block_pool 的两个 pb 释放口）。
// 端口状态为寄存器阵列，由 init_sweep T_RXDESC（target 6）逐项清零；块元数据
//   （len/nxt）只在块被链入时读，不需初始化。
// 时钟/复位: clk / rst_sync（§4.2）。
// =====================================================================
`timescale 1 ns / 1 ps
module legacy_rx_port_buf_reference #(
  parameter integer NUM_PORTS = 256
) (
  input  wire        clk,
  input  wire        rst_sync,
  input  wire        init_we,
  input  wire [12:0] init_addr,
  // parse result
  input  wire        in_vld,
  output wire        in_ready,
  input  wire        in_drop,
  input  wire [7:0]  in_port,
  input  wire [1:0]  in_type,
  input  wire [3:0]  in_depth,
  input  wire [3:0]  in_blk,
  input  wire [10:0] in_plen,
  // host operations (at most one per cycle)
  input  wire        hop_desc_rd,
  input  wire        hop_msg_rd,
  input  wire [7:0]  hop_port,
  input  wire [1:0]  hop_type,      // port table w0[17:16] of hop_port
  output wire [31:0] desc_word,     // combinational, for hop_port
  output wire [3:0]  cnt_word,
  // block release
  output reg         free0,
  output reg  [3:0]  free0_id,
  output reg         free1,
  output reg  [3:0]  free1_id,
  // statistics / events
  output reg         ev_drop,       // parse drop or queue overflow (1 frame)
  output reg         ev_sample,     // v0.5.17 INT: sampling message delivered
  output reg         ev_queue,      // v0.5.17 INT: message enqueued
  output reg         ev_ovf,        // v0.5.17 INT: sampling overwrite or queue full
  output reg  [31:0] deliver_cnt,
  output reg  [31:0] port_drop_cnt,
  output reg  [31:0] ovr_cnt,
  output reg  [31:0] qovf_cnt
);
  reg [3:0]  p_cnt   [0:NUM_PORTS-1];
  reg [3:0]  p_head  [0:NUM_PORTS-1];
  reg [3:0]  p_tail  [0:NUM_PORTS-1];
  reg [3:0]  p_pinb  [0:NUM_PORTS-1];
  reg        p_fresh [0:NUM_PORTS-1];
  reg        p_ovf   [0:NUM_PORTS-1];
  reg        p_seen  [0:NUM_PORTS-1];
  reg        p_pin   [0:NUM_PORTS-1];
  reg [10:0] b_len   [0:15];
  reg [3:0]  b_nxt   [0:15];

  wire hop_any = hop_desc_rd || hop_msg_rd;
  assign in_ready = !rst_sync && !init_we && !hop_any;
  wire ev = in_vld && in_ready;

  // host view
  wire [3:0] h_cnt  = p_cnt[hop_port];
  wire [3:0] h_head = p_head[hop_port];
  assign desc_word = {(h_cnt != 4'd0), p_fresh[hop_port], p_ovf[hop_port],
                      p_pin[hop_port], h_cnt, h_head, 9'd0,
                      (h_cnt != 4'd0) ? b_len[h_head] : 11'd0};
  assign cnt_word = h_cnt;

  // frame event view
  wire [3:0] e_cnt  = p_cnt[in_port];
  wire [3:0] e_head = p_head[in_port];
  wire [3:0] e_tail = p_tail[in_port];
  wire       e_seen = p_seen[in_port];
  wire       e_pin  = p_pin[in_port];
  wire [3:0] e_pinb = p_pinb[in_port];

  always @(posedge clk) begin
    free0 <= 1'b0; free1 <= 1'b0; ev_drop <= 1'b0;
    ev_sample <= 1'b0; ev_queue <= 1'b0; ev_ovf <= 1'b0;
    if (rst_sync) begin
      free0_id <= 4'd0; free1_id <= 4'd0;
      deliver_cnt <= 32'd0; port_drop_cnt <= 32'd0; ovr_cnt <= 32'd0; qovf_cnt <= 32'd0;
    end else if (init_we) begin
      if (init_addr < NUM_PORTS) begin
        p_cnt[init_addr[7:0]] <= 4'd0;   p_fresh[init_addr[7:0]] <= 1'b0;
        p_ovf[init_addr[7:0]] <= 1'b0;   p_seen[init_addr[7:0]]  <= 1'b0;
        p_pin[init_addr[7:0]] <= 1'b0;
      end
    end else if (hop_desc_rd) begin
      p_fresh[hop_port] <= 1'b0;
      p_ovf[hop_port]   <= 1'b0;
      p_seen[hop_port]  <= (h_cnt != 4'd0);
    end else if (hop_msg_rd) begin
      if (hop_type == 2'd0) begin
        if (p_pin[hop_port]) begin
          free0 <= 1'b1; free0_id <= p_pinb[hop_port]; p_pin[hop_port] <= 1'b0;
        end
        if (p_seen[hop_port] && h_cnt != 4'd0) begin
          free1 <= 1'b1; free1_id <= h_head;
          p_cnt[hop_port] <= 4'd0; p_seen[hop_port] <= 1'b0; p_fresh[hop_port] <= 1'b0;
        end
      end else if (h_cnt != 4'd0) begin
        free0 <= 1'b1; free0_id <= h_head;
        p_head[hop_port]  <= b_nxt[h_head];
        p_cnt[hop_port]   <= h_cnt - 4'd1;
        p_fresh[hop_port] <= (h_cnt > 4'd1);
        p_seen[hop_port]  <= 1'b0;
      end
    end else if (ev) begin
      if (in_drop) begin
        free0 <= 1'b1; free0_id <= in_blk; ev_drop <= 1'b1;
        port_drop_cnt <= port_drop_cnt + 32'd1;
      end else if (in_type == 2'd0) begin
        b_len[in_blk] <= in_plen;
        deliver_cnt <= deliver_cnt + 32'd1;
        ev_sample <= 1'b1;
        if (e_cnt != 4'd0) begin
          ovr_cnt <= ovr_cnt + 32'd1; ev_ovf <= 1'b1;
          p_ovf[in_port] <= 1'b1;
          if (e_seen) begin
            if (e_pin) begin free0 <= 1'b1; free0_id <= e_pinb; end
            p_pin[in_port] <= 1'b1; p_pinb[in_port] <= e_head;
          end else begin
            free0 <= 1'b1; free0_id <= e_head;
          end
        end
        p_cnt[in_port] <= 4'd1; p_head[in_port] <= in_blk; p_tail[in_port] <= in_blk;
        p_fresh[in_port] <= 1'b1; p_seen[in_port] <= 1'b0;
      end else if (e_cnt >= in_depth) begin
        free0 <= 1'b1; free0_id <= in_blk; ev_drop <= 1'b1;
        qovf_cnt <= qovf_cnt + 32'd1; ev_ovf <= 1'b1;
        p_ovf[in_port] <= 1'b1;
      end else begin
        b_len[in_blk] <= in_plen;
        deliver_cnt <= deliver_cnt + 32'd1;
        ev_queue <= 1'b1;
        if (e_cnt == 4'd0) begin
          p_head[in_port] <= in_blk; p_fresh[in_port] <= 1'b1;
        end else b_nxt[e_tail] <= in_blk;
        p_tail[in_port] <= in_blk;
        p_cnt[in_port]  <= e_cnt + 4'd1;
      end
    end
  end
endmodule
