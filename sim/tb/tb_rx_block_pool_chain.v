// Standalone RX pool contract test. Only rx_block_pool.v is required.
// No simulation has been run while the shared heavy-tool slot is held by T43.
// free_en/free_ids slots: A, B, pipe, reasm, pb0, pb1, spill.
`timescale 1 ns / 1 ps
module tb_rx_block_pool_chain;
  reg clk = 1'b0;
  always #5 clk = ~clk;
  reg rst_sync = 1'b1;
  reg alloc_a = 1'b0, alloc_b = 1'b0, alloc_chain = 1'b0;
  reg [2:0] alloc_chain_count = 3'd0;
  reg [6:0] free_en = 7'd0;
  reg [27:0] free_ids = 28'd0;
  reg [15:0] free_chain_mask = 16'd0;
  wire l_valid_a, l_valid_b, l_valid_chain;
  wire [3:0] l_blk_a, l_blk_b;
  wire [19:0] l_chain_blocks;
  wire [2:0] l_chain_count;
  wire [15:0] l_free_map, l_exhaust_cnt, l_borrow_cnt;
  wire d_valid_a, d_valid_b, d_valid_chain;
  wire [3:0] d_blk_a, d_blk_b;
  wire [19:0] d_chain_blocks;
  wire [2:0] d_chain_count;
  wire [15:0] d_free_map, d_exhaust_cnt, d_borrow_cnt;
  wire c_valid_a, c_valid_b, c_valid_chain;
  wire [3:0] c_blk_a, c_blk_b;
  wire [19:0] c_chain_blocks;
  wire [2:0] c_chain_count;
  wire [15:0] c_free_map, c_exhaust_cnt, c_borrow_cnt;

  integer errors = 0, checked_cycles = 0;
  integer i, n, p;
  reg [15:0] covered = 16'd0;
  reg [8*96-1:0] phase_name = "startup";
  reg [15:0] model_l_map, model_c_map;
  reg [15:0] model_l_exhaust, model_c_exhaust;
  reg [15:0] model_l_borrow, model_c_borrow;
  reg pl_a, pl_b, pl_chain, pc_a, pc_b, pc_chain;
  reg [3:0] pl_blk_a, pl_blk_b, pc_blk_a, pc_blk_b;
  reg [19:0] pl_blocks, pc_blocks;
  reg [2:0] pl_count, pc_count;
  reg [15:0] next_l_map, next_c_map;
  reg [15:0] l_exhaust_delta, c_exhaust_delta;
  reg [15:0] l_borrow_delta, c_borrow_delta;
  reg last_valid_a, last_valid_b, last_valid_chain;
  reg [3:0] last_blk_a, last_blk_b;
  reg [19:0] last_blocks;
  reg [2:0] last_count;
  reg [27:0] sweep_ids;
  reg [15:0] sweep_mask;
  reg [19:0] expected_packed;

  // Explicit Z matches open optional inputs without missing-port warnings.
  rx_block_pool dut_legacy (
    .clk(clk), .rst_sync(rst_sync), .alloc_a(alloc_a), .alloc_b(alloc_b),
    .valid_a(l_valid_a), .valid_b(l_valid_b),
    .blk_a(l_blk_a), .blk_b(l_blk_b),
    .free_a(free_en[0]), .free_id_a(free_ids[3:0]),
    .free_b(free_en[1]), .free_id_b(free_ids[7:4]),
    .free_pipe(free_en[2]), .free_id_pipe(free_ids[11:8]),
    .free_reasm(free_en[3]), .free_id_reasm(free_ids[15:12]),
    .free_pb0(free_en[4]), .free_id_pb0(free_ids[19:16]),
    .free_pb1(free_en[5]), .free_id_pb1(free_ids[23:20]),
    .free_spill(free_en[6]), .free_id_spill(free_ids[27:24]),
    .free_map(l_free_map), .exhaust_cnt(l_exhaust_cnt),
    .borrow_cnt(l_borrow_cnt),
    .alloc_chain(1'bz), .alloc_chain_count(3'bzzz),
    .free_chain_mask(16'hzzzz),
    .valid_chain(l_valid_chain), .chain_blocks(l_chain_blocks),
    .chain_count(l_chain_count));

  // An explicit zero parameter must also ignore connected X inputs.
  rx_block_pool #(.CHAIN_ENABLE(0)) dut_disabled (
    .clk(clk), .rst_sync(rst_sync), .alloc_a(alloc_a), .alloc_b(alloc_b),
    .valid_a(d_valid_a), .valid_b(d_valid_b),
    .blk_a(d_blk_a), .blk_b(d_blk_b),
    .free_a(free_en[0]), .free_id_a(free_ids[3:0]),
    .free_b(free_en[1]), .free_id_b(free_ids[7:4]),
    .free_pipe(free_en[2]), .free_id_pipe(free_ids[11:8]),
    .free_reasm(free_en[3]), .free_id_reasm(free_ids[15:12]),
    .free_pb0(free_en[4]), .free_id_pb0(free_ids[19:16]),
    .free_pb1(free_en[5]), .free_id_pb1(free_ids[23:20]),
    .free_spill(free_en[6]), .free_id_spill(free_ids[27:24]),
    .free_map(d_free_map), .exhaust_cnt(d_exhaust_cnt),
    .borrow_cnt(d_borrow_cnt),
    .alloc_chain(1'bx), .alloc_chain_count(3'bxxx),
    .free_chain_mask(16'hxxxx),
    .valid_chain(d_valid_chain), .chain_blocks(d_chain_blocks),
    .chain_count(d_chain_count));

  rx_block_pool #(.CHAIN_ENABLE(1)) dut_chain (
    .clk(clk), .rst_sync(rst_sync), .alloc_a(alloc_a), .alloc_b(alloc_b),
    .valid_a(c_valid_a), .valid_b(c_valid_b),
    .blk_a(c_blk_a), .blk_b(c_blk_b),
    .free_a(free_en[0]), .free_id_a(free_ids[3:0]),
    .free_b(free_en[1]), .free_id_b(free_ids[7:4]),
    .free_pipe(free_en[2]), .free_id_pipe(free_ids[11:8]),
    .free_reasm(free_en[3]), .free_id_reasm(free_ids[15:12]),
    .free_pb0(free_en[4]), .free_id_pb0(free_ids[19:16]),
    .free_pb1(free_en[5]), .free_id_pb1(free_ids[23:20]),
    .free_spill(free_en[6]), .free_id_spill(free_ids[27:24]),
    .free_map(c_free_map), .exhaust_cnt(c_exhaust_cnt),
    .borrow_cnt(c_borrow_cnt),
    .alloc_chain(alloc_chain), .alloc_chain_count(alloc_chain_count),
    .free_chain_mask(free_chain_mask),
    .valid_chain(c_valid_chain), .chain_blocks(c_chain_blocks),
    .chain_count(c_chain_count));

  task must(input condition, input [8*128-1:0] reason);
    begin
      if (condition !== 1'b1) begin
        if (errors < 40)
          $display("[err] t=%0t cycle=%0d case=%0s: %0s; map=%h exhaust=%0d borrow=%0d",
                   $time, checked_cycles, phase_name, reason,
                   c_free_map, c_exhaust_cnt, c_borrow_cnt);
        errors = errors + 1;
      end
    end
  endtask

  task idle;
    begin
      alloc_a = 1'b0; alloc_b = 1'b0; alloc_chain = 1'b0;
      alloc_chain_count = 3'd0;
      free_en = 7'd0; free_ids = 28'd0; free_chain_mask = 16'd0;
    end
  endtask

  // Independent model: count availability before picking any chain IDs.
  // The DUT instead builds tentative candidates and commits on full count.
  task predict(
    input chain_enabled, input [15:0] old_map,
    output reg va, output reg vb, output reg vc,
    output reg [3:0] ba, output reg [3:0] bb,
    output reg [19:0] blocks, output reg [2:0] count,
    output reg [15:0] next_map,
    output reg [15:0] exhausted, output reg [15:0] borrowed);
    integer id, port_index, available, slot;
    reg [15:0] remaining;
    reg [3:0] returned_id;
    begin
      remaining = old_map;
      va = 0; vb = 0; vc = 0; ba = 0; bb = 0;
      blocks = 0; count = 0; exhausted = 0; borrowed = 0;
      for (id=6; id<16; id=id+1)
        if (alloc_a && !va && remaining[id]) begin
          va = 1; ba = id[3:0]; remaining[id] = 0;
          if (id >= 12) borrowed = borrowed + 16'd1;
        end
      for (id=6; id<16; id=id+1)
        if (alloc_b && !vb && remaining[id]) begin
          vb = 1; bb = id[3:0]; remaining[id] = 0;
          if (id >= 12) borrowed = borrowed + 16'd1;
        end
      if (alloc_a && !va) exhausted = exhausted + 16'd1;
      if (alloc_b && !vb) exhausted = exhausted + 16'd1;
      available = 0;
      for (id=6; id<16; id=id+1)
        if (remaining[id]) available = available + 1;
      if (chain_enabled && alloc_chain) begin
        if (alloc_chain_count >= 1 && alloc_chain_count <= 5 &&
            available >= alloc_chain_count) begin
          vc = 1; count = alloc_chain_count; slot = 0;
          for (id=6; id<16; id=id+1)
            if (remaining[id] && slot < alloc_chain_count) begin
              blocks[4*slot +: 4] = id[3:0]; slot = slot + 1;
              remaining[id] = 0;
              if (id >= 12) borrowed = borrowed + 16'd1;
            end
        end else exhausted = exhausted + 16'd1;
      end
      next_map = remaining;
      for (port_index=0; port_index<7; port_index=port_index+1) begin
        returned_id = free_ids[4*port_index +: 4];
        if (free_en[port_index] && returned_id >= 6)
          next_map[returned_id] = 1'b1;
      end
      if (chain_enabled) next_map = next_map | (free_chain_mask & 16'hFFC0);
    end
  endtask

  task check_registered;
    begin
      must({l_free_map,l_exhaust_cnt,l_borrow_cnt} ===
           {model_l_map,model_l_exhaust,model_l_borrow}, "default legacy registered state");
      must({d_free_map,d_exhaust_cnt,d_borrow_cnt} ===
           {model_l_map,model_l_exhaust,model_l_borrow}, "disabled X-input registered state");
      must({c_free_map,c_exhaust_cnt,c_borrow_cnt} ===
           {model_c_map,model_c_exhaust,model_c_borrow}, "enabled registered state");
      must((c_free_map & 16'h003F) === 16'd0, "TX IDs must never enter RX free_map");
    end
  endtask

  task check_outputs;
    integer slot;
    reg [15:0] seen;
    reg [3:0] id;
    begin
      must({l_valid_a,l_valid_b,l_blk_a,l_blk_b} ===
           {pl_a,pl_b,pl_blk_a,pl_blk_b}, "default legacy A/B outputs");
      must({d_valid_a,d_valid_b,d_blk_a,d_blk_b} ===
           {pl_a,pl_b,pl_blk_a,pl_blk_b}, "disabled X-input A/B outputs");
      must({l_valid_chain,l_chain_blocks,l_chain_count} === 24'd0,
           "default missing new inputs: chain outputs zero");
      must({d_valid_chain,d_chain_blocks,d_chain_count} === 24'd0,
           "disabled X inputs: chain outputs zero");
      must({c_valid_a,c_valid_b,c_blk_a,c_blk_b,c_valid_chain,c_chain_blocks,c_chain_count} ===
           {pc_a,pc_b,pc_blk_a,pc_blk_b,pc_chain,pc_blocks,pc_count}, "enabled combinational outputs");
      seen = 16'd0;
      if (c_valid_a) begin
        must(c_blk_a >= 6, "A ID range"); seen[c_blk_a] = 1'b1;
      end
      if (c_valid_b) begin
        must(c_blk_b >= 6, "B ID range");
        must(!seen[c_blk_b], "A/B alias"); seen[c_blk_b] = 1'b1;
      end
      if (c_valid_chain) begin
        must(c_chain_count >= 1 && c_chain_count <= 5, "chain count range");
        for (slot=0; slot<5; slot=slot+1) begin
          id = c_chain_blocks[4*slot +: 4];
          if (slot < c_chain_count) begin
            must(id >= 6, "chain ID range");
            must(!seen[id], "A/B/chain alias"); seen[id] = 1'b1;
          end else must(id === 4'd0, "unused chain slot must be zero");
        end
      end else must({c_chain_blocks,c_chain_count} === 23'd0,
                    "chain failure/idle must expose no partial candidates");
    end
  endtask

  task reset_pool;
    begin
      @(negedge clk); phase_name = "reset"; rst_sync = 1'b1; idle;
      @(posedge clk); #1;
      model_l_map = 16'hFFC0; model_c_map = 16'hFFC0;
      model_l_exhaust = 0; model_c_exhaust = 0;
      model_l_borrow = 0; model_c_borrow = 0;
      check_registered;
      rst_sync = 1'b0; #1;
    end
  endtask

  task cycle(
    input a, input b, input chain_request, input [2:0] request_count,
    input [6:0] returns, input [27:0] return_ids,
    input [15:0] return_mask, input [8*96-1:0] name);
    begin
      @(negedge clk);
      phase_name = name;
      alloc_a = a; alloc_b = b; alloc_chain = chain_request;
      alloc_chain_count = request_count;
      free_en = returns; free_ids = return_ids; free_chain_mask = return_mask;
      #1;
      predict(1'b0, model_l_map, pl_a, pl_b, pl_chain, pl_blk_a, pl_blk_b,
              pl_blocks, pl_count, next_l_map, l_exhaust_delta, l_borrow_delta);
      predict(1'b1, model_c_map, pc_a, pc_b, pc_chain, pc_blk_a, pc_blk_b,
              pc_blocks, pc_count, next_c_map, c_exhaust_delta, c_borrow_delta);
      check_outputs;
      last_valid_a = c_valid_a; last_valid_b = c_valid_b;
      last_blk_a = c_blk_a; last_blk_b = c_blk_b;
      last_valid_chain = c_valid_chain; last_blocks = c_chain_blocks;
      last_count = c_chain_count;
      @(posedge clk); #1;
      model_l_map = next_l_map; model_c_map = next_c_map;
      model_l_exhaust = model_l_exhaust + l_exhaust_delta;
      model_c_exhaust = model_c_exhaust + c_exhaust_delta;
      model_l_borrow = model_l_borrow + l_borrow_delta;
      model_c_borrow = model_c_borrow + c_borrow_delta;
      checked_cycles = checked_cycles + 1;
      check_registered;
      idle; #1;
      must({c_valid_chain,c_chain_blocks,c_chain_count} === 24'd0,
           "combinational chain outputs clear when request is removed");
    end
  endtask

  task drain_chain;
    begin
      cycle(0,0,1,5,0,0,0,"drain first five");
      cycle(0,0,1,5,0,0,0,"drain second five");
      must(c_free_map === 16'd0 && c_borrow_cnt === 16'd4, "drained ten blocks and four borrowed IDs");
    end
  endtask

  task mark(input integer case_id);
    begin
      covered[case_id] = 1'b1;
      $display("[CASE] %0d complete: %0s", case_id, phase_name);
    end
  endtask

  initial begin
    // 0: Original A/B allocation and stats survive omitted/Z and connected/X inputs.
    reset_pool;
    for (i=0; i<5; i=i+1)
      cycle(1,1,1,5,0,0,0,"legacy/default allocation pairs");
    must(l_free_map === 0 && l_borrow_cnt === 4 && l_exhaust_cnt === 0,
         "legacy ten IDs and exactly four shared borrows");
    cycle(1,1,1,5,0,0,16'hFFFF,"legacy ignores new free mask and chain request");
    must(l_free_map === 0 && l_exhaust_cnt === 2 && l_borrow_cnt === 4,
         "legacy exhaust increments for A/B only");
    mark(0);

    // 1: A/B consume IDs before the five-block atomic chain.
    reset_pool;
    cycle(1,1,1,5,0,0,0,"simultaneous A/B/chain non-aliasing");
    must(last_blk_a === 6 && last_blk_b === 7 && last_blocks === 20'hCBA98 &&
         last_count === 5 && c_free_map === 16'hE000 && c_borrow_cnt === 1,
         "A=6 B=7 chain=8..12, exactly one chain borrow");
    mark(1);

    // 2/3: Success for five, then insufficient five after A/B; no partial consumption.
    reset_pool;
    cycle(0,0,1,5,0,0,0,"five-block success");
    must(last_valid_chain && last_blocks === 20'hA9876 && last_count === 5 &&
         c_free_map === 16'hF800 && c_borrow_cnt === 0, "five low IDs committed");
    mark(2);
    cycle(1,1,1,5,0,0,0,"insufficient five preserves A/B allocations only");
    must(last_valid_a && last_valid_b && last_blk_a === 11 && last_blk_b === 12 &&
         !last_valid_chain && last_blocks === 0 && last_count === 0 &&
         c_free_map === 16'hE000 && c_exhaust_cnt === 1 && c_borrow_cnt === 1,
         "atomic chain failure leaves IDs 13..15 and counts A/B borrow");
    cycle(0,0,1,3,0,0,0,"consume untouched failure candidates");
    must(last_blocks === 20'h00FED && c_free_map === 0 && c_borrow_cnt === 4,
         "failed candidates remained available");
    mark(3);

    // 4: Invalid count 0/6/7 each fails once; absent request fails zero times.
    reset_pool;
    cycle(0,0,1,0,0,0,0,"illegal count zero");
    must(c_free_map === 16'hFFC0 && c_exhaust_cnt === 1, "count zero is atomic failure");
    cycle(1,1,1,6,0,0,0,"illegal count six with A/B");
    must(c_free_map === 16'hFF00 && c_exhaust_cnt === 2 && c_borrow_cnt === 0,
         "invalid chain does not undo A/B or consume extra blocks");
    cycle(0,0,1,7,0,0,0,"illegal count seven");
    cycle(0,0,0,0,0,0,0,"idle count zero");
    must(c_free_map === 16'hFF00 && c_exhaust_cnt === 3, "each invalid request adds exactly one");
    mark(4);

    // 5: A scalar return cannot satisfy any request until the next clock.
    reset_pool; drain_chain;
    cycle(1,1,1,1,7'b0000001,28'h0000006,0,"scalar return invisible to same-cycle requests");
    must(!last_valid_a && !last_valid_b && !last_valid_chain && c_free_map === 16'h0040 &&
         c_exhaust_cnt === 3, "scalar free becomes visible after failed A/B/chain");
    cycle(1,1,1,1,0,0,0,"scalar free available next cycle with A priority");
    must(last_valid_a && last_blk_a === 6 && !last_valid_b && !last_valid_chain &&
         c_free_map === 0 && c_exhaust_cnt === 5, "one returned ID cannot alias across requests");
    mark(5);

    // 6: A whole chain mask is returned atomically but all three same-cycle requests fail.
    reset_pool; drain_chain;
    cycle(1,1,1,5,0,0,16'hFFC0,"whole mask return invisible to A/B/chain this cycle");
    must(!last_valid_a && !last_valid_b && !last_valid_chain &&
         c_free_map === 16'hFFC0 && c_exhaust_cnt === 3 && c_borrow_cnt === 4,
         "entire RX mask returned after exactly three failed requests");
    cycle(1,1,1,5,0,0,0,"whole mask available next cycle");
    must(last_blk_a === 6 && last_blk_b === 7 && last_blocks === 20'hCBA98 &&
         c_free_map === 16'hE000 && c_exhaust_cnt === 3 && c_borrow_cnt === 5,
         "mask recycle keeps A/B/chain distinct and counts successful borrow");
    mark(6);

    // 7: Mask filtering protects TX 0..5, including an all-ones mask.
    reset_pool; drain_chain;
    cycle(0,0,0,0,0,0,16'h003F,"mask contains TX IDs only");
    must(c_free_map === 0 && c_borrow_cnt === 4 && c_exhaust_cnt === 0,
         "low six mask bits have no effect");
    cycle(0,0,0,0,0,0,16'hFFFF,"all-ones mask returns RX IDs only");
    must(c_free_map === 16'hFFC0, "whole mask is filtered by FFC0");
    mark(7);

    // 8: Duplicate scalar/mask frees are idempotent and produce one allocatable ID.
    reset_pool; drain_chain;
    cycle(0,0,0,0,7'h7F,28'hCCCCCCC,16'h1000,"all ports and mask return duplicate ID12");
    cycle(0,0,0,0,7'h7F,28'hCCCCCCC,16'h1000,"repeat already-free ID12");
    must(c_free_map === 16'h1000 && c_borrow_cnt === 4 && c_exhaust_cnt === 0,
         "duplicate returns are idempotent and do not change stats");
    cycle(1,1,1,1,0,0,0,"duplicate returns allow only one allocation");
    must(last_valid_a && last_blk_a === 12 && !last_valid_b && !last_valid_chain &&
         c_free_map === 0 && c_borrow_cnt === 5 && c_exhaust_cnt === 2,
         "duplicate free does not manufacture a second ID");
    mark(8);

    // 9: Every one of the seven legacy free ports contributes its distinct RX bit.
    reset_pool; drain_chain;
    cycle(1,1,1,5,7'h7F,28'hCBA9876,0,"all seven distinct legacy free ports");
    must(!last_valid_a && !last_valid_b && !last_valid_chain && c_free_map === 16'h1FC0,
         "all seven returns are ORed and unavailable in the return cycle");
    cycle(1,1,1,5,0,0,0,"consume all seven legacy returns");
    must(last_blocks === 20'hCBA98 && c_free_map === 0 && c_borrow_cnt === 5,
         "all seven legal free ports became available next cycle");
    mark(9);

    // 10: Invalid scalar IDs 0..5 are ignored, as are low mask bits.
    reset_pool; drain_chain;
    cycle(0,0,0,0,7'h7F,28'h5543210,16'h003F,"all free ports carry TX IDs");
    must(c_free_map === 0 && c_exhaust_cnt === 0 && c_borrow_cnt === 4,
         "illegal scalar frees and low mask bits cannot enter RX pool");
    mark(10);

    // 11: Sparse available IDs prove low-ID ordering and per-chain shared borrowing.
    reset_pool; drain_chain;
    cycle(0,0,0,0,0,0,16'hD240,"sparse whole-chain return 6/9/12/14/15");
    cycle(1,1,1,3,0,0,0,"sparse A/B then chain allocation");
    must(last_blk_a === 6 && last_blk_b === 9 && last_blocks === 20'h00FEC &&
         c_free_map === 0 && c_borrow_cnt === 7, "sparse chain order and three additional borrows");
    mark(11);

    // 12: Every legal count 1..5 succeeds; unused output slots are always zero.
    for (n=1; n<=5; n=n+1) begin
      reset_pool;
      cycle(0,0,1,n,0,0,0,"each legal chain count");
      case (n)
        1: expected_packed = 20'h00006;
        2: expected_packed = 20'h00076;
        3: expected_packed = 20'h00876;
        4: expected_packed = 20'h09876;
        5: expected_packed = 20'hA9876;
      endcase
      must(last_valid_chain && last_count === n[2:0] && last_blocks === expected_packed,
           "legal chain count and zero padding");
    end
    mark(12);

    // 13: Failed tentative shared IDs add no borrow count; later success adds all four.
    reset_pool;
    for (i=0; i<3; i=i+1) cycle(1,1,0,0,0,0,0,"consume dedicated IDs through A/B");
    cycle(0,0,1,5,0,0,0,"five requested from four shared IDs");
    must(!last_valid_chain && c_free_map === 16'hF000 && c_borrow_cnt === 0 &&
         c_exhaust_cnt === 1, "uncommitted shared candidates add no borrow");
    cycle(0,0,1,4,0,0,0,"four shared IDs committed as a chain");
    must(last_blocks === 20'h0FEDC && last_count === 4 && c_borrow_cnt === 4,
         "successful chain counts every shared ID");
    mark(13);

    // 14: Three independent failures in one clock add 3; a chain request alone adds 1.
    reset_pool; drain_chain;
    cycle(1,1,1,5,0,0,0,"empty A/B/chain requests");
    must(c_exhaust_cnt === 3, "A plus B plus one chain failure");
    cycle(0,0,1,5,0,0,0,"empty chain-only request");
    cycle(0,0,0,5,0,0,0,"idle chain count does not exhaust");
    must(c_exhaust_cnt === 4 && c_borrow_cnt === 4, "chain failure increments once and never borrows");
    mark(14);

    // 15: Preserve original free-wins OR semantics, then exercise mixed return/request traffic.
    reset_pool; drain_chain;
    cycle(0,0,0,0,7'b0000001,28'h000000C,0,"prepare old-free ID12");
    cycle(1,0,0,0,7'h7F,28'hCCCCCCC,16'h1000,"allocate old-free ID12 and return it in same cycle");
    must(last_valid_a && last_blk_a === 12 && c_free_map === 16'h1000 && c_borrow_cnt === 5,
         "existing free-wins OR semantics retained");
    cycle(1,0,0,0,0,0,0,"same-cycle returned old-free ID12 usable next cycle");
    must(last_blk_a === 12 && c_free_map === 0 && c_borrow_cnt === 6,
         "same ID is reusable on the next clock only");
    for (i=0; i<96; i=i+1) begin
      sweep_ids = 28'd0; sweep_mask = 16'd0;
      for (p=0; p<7; p=p+1)
        sweep_ids[4*p +: 4] = (3*i + 5*p) % 16;
      if ((i % 3) == 0) sweep_mask = 16'hFFFF;
      else if ((i % 3) == 1) sweep_mask = 16'h9240;
      else sweep_mask = 16'h003F;
      cycle((i%2),((i/2)%2),((i/4)%2),(i%8),(i%128),sweep_ids,sweep_mask,
            "mixed request/free scoreboard sweep");
    end
    mark(15);

    must(covered === 16'hFFFF, "all sixteen directed coverage groups completed");
    if (errors == 0)
      $display("RX_BLOCK_POOL_CHAIN PASS cases=16 cycles=%0d", checked_cycles);
    else $display("RX_BLOCK_POOL_CHAIN FAIL errors=%0d cases=%h", errors, covered);
    $finish;
  end

  initial begin
    #200000;
    $display("RX_BLOCK_POOL_CHAIN FAIL watchdog");
    $finish;
  end
endmodule
