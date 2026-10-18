// Standalone SAP acceptance.  Compile only frozen snapshots with the supplied runner.
// Chain expectations come from the descriptor and this independent byte fixture.
// The legacy tops compare the default branch against the original baseline every cycle.
// No production hierarchy, parser, side table, regress or golden input is required.
`timescale 1 ns / 1 ps
module tb_mgmt_sap_rx_chain;
  localparam integer EXPECT_CASES = 47;
  reg clk = 1'b0;
  always #5 clk = ~clk;
  reg rst_sync = 1'b1;
  reg in_vld = 1'b0;
  wire in_ready;
  reg [7:0] in_port = 8'd0;
  reg [3:0] in_blk = 4'd0;
  reg [10:0] in_plen = 11'd0;
  reg [13:0] in_app_len = 14'd0;
  reg [19:0] in_blocks = 20'd0;
  reg [2:0] in_block_count = 3'd0;
  wire pm_req;
  wire [12:0] pm_addr;
  reg pm_gnt = 1'b0;
  reg [31:0] pm_data = 32'd0;
  reg [31:0] pmem [0:8191];
  wire out_vld, out_sop, out_eop;
  wire [7:0] out_data;
  wire [15:0] out_sport, out_dport;
  wire [31:0] out_srcip;
  wire [10:0] out_plen;
  wire [13:0] out_app_len;
  reg out_ready = 1'b1;
  wire free_req;
  reg free_take = 1'b0;
  wire [3:0] free_id;
  wire [31:0] accept_cnt, free_cnt, last_desc, pay_cnt, trunc_cnt;
  mgmt_sap_rx #(.CHAIN_ENABLE(1)) dut (
    .clk(clk), .rst_sync(rst_sync), .in_vld(in_vld), .in_ready(in_ready),
    .in_port(in_port), .in_blk(in_blk), .in_plen(in_plen),
    .in_app_len(in_app_len), .in_blocks(in_blocks), .in_block_count(in_block_count),
    .pm_req(pm_req), .pm_addr(pm_addr), .pm_gnt(pm_gnt), .pm_data(pm_data),
    .out_vld(out_vld), .out_sop(out_sop), .out_eop(out_eop), .out_data(out_data),
    .out_sport(out_sport), .out_dport(out_dport), .out_srcip(out_srcip),
    .out_plen(out_plen), .out_app_len(out_app_len), .out_ready(out_ready),
    .free_req(free_req), .free_take(free_take), .free_id(free_id),
    .accept_cnt(accept_cnt), .free_cnt(free_cnt), .last_desc(last_desc),
    .pay_cnt(pay_cnt), .trunc_cnt(trunc_cnt)
  );

  integer errors = 0, case_id = 0, case_errors = 0, cycles = 0;
  string case_name = "idle", case_kind = "normal";
  reg active = 1'b0, valid_descriptor = 1'b0, first_free_checked = 1'b0;
  integer length = 0, block_count = 0, fixture_seed = 0;
  reg [19:0] blocks = 20'd0;
  reg [3:0] head = 4'd0;
  reg [7:0] port_id = 8'd0;
  integer expected_reads = 0, expected_bytes = 0, expected_frees = 1;
  integer reads = 0, captures = 0, got = 0, frees = 0, accepts = 0;
  integer req_stalls = 0, eop_stalls = 0, free_stalls = 0;
  integer boundaries = 0, boundary_bytes = 0, last_capture_cycle = -1;
  reg [3:0] lane_mask = 4'd0;
  integer grant_mode = 0, free_delay = 0, payload_mode = 0;
  integer request_age = 0, free_age = 0, sop_age = 0, mid_age = 0, eop_age = 0;
  integer base_accept = 0, base_free = 0, base_pay = 0, base_trunc = 0;
  reg response_pending = 1'b0;
  reg [12:0] response_addr = 13'd0;
  reg request_held = 1'b0, release_held = 1'b0, payload_held = 1'b0;
  reg [12:0] held_addr = 13'd0;
  reg [3:0] held_free_id = 4'd0;
  reg [98:0] held_payload = 99'd0;
  reg [31:0] held_pay_cnt = 32'd0;
  integer monitor_i, logical_word, address_integer;

  // Independent fixture: block-sensitive pattern and explicit network-order header.
  function [7:0] image_byte;
    input integer raw_index;
    input integer seed;
    input integer app_len;
    integer mixed, sport, dport, udp_len, ip_len;
    begin
      mixed = raw_index*37 + (raw_index/4)*11 + (raw_index/2048)*67 +
              (raw_index/128)*19 + seed*23;
      sport = 16'h3100 + seed; dport = 16'h5800 + seed*5;
      udp_len = app_len + 8; ip_len = app_len + 28;
      case (raw_index)
        12: image_byte = 8'h08; 13: image_byte = 8'h00;
        14: image_byte = 8'h45;
        16: image_byte = (ip_len >> 8) & 255;
        17: image_byte = ip_len & 255;
        24: image_byte = 8'd64; 25: image_byte = 8'd17;
        26: image_byte = 8'hac; 27: image_byte = (seed ^ 8'h5a) & 255;
        28: image_byte = 8'ha7; 29: image_byte = (seed*3 + 11) & 255;
        34: image_byte = (sport >> 8) & 255; 35: image_byte = sport & 255;
        36: image_byte = (dport >> 8) & 255; 37: image_byte = dport & 255;
        38: image_byte = (udp_len >> 8) & 255; 39: image_byte = udp_len & 255;
        40, 41: image_byte = 8'd0;
        default: image_byte = mixed & 255;
      endcase
    end
  endfunction
  function [31:0] image_word;
    input integer logical_word;
    input integer seed;
    input integer app_len;
    begin
      image_word = {image_byte(logical_word*4, seed, app_len),
                    image_byte(logical_word*4+1, seed, app_len),
                    image_byte(logical_word*4+2, seed, app_len),
                    image_byte(logical_word*4+3, seed, app_len)};
    end
  endfunction
  function [31:0] expected_ip;
    input integer seed;
    input integer app_len;
    begin
      expected_ip = {image_byte(26,seed,app_len), image_byte(27,seed,app_len),
                     image_byte(28,seed,app_len), image_byte(29,seed,app_len)};
    end
  endfunction
  function [15:0] expected_sport;
    input integer seed;
    input integer app_len;
    begin expected_sport = {image_byte(34,seed,app_len), image_byte(35,seed,app_len)}; end
  endfunction
  function [15:0] expected_dport;
    input integer seed;
    input integer app_len;
    begin expected_dport = {image_byte(36,seed,app_len), image_byte(37,seed,app_len)}; end
  endfunction

  // Deliberately use arithmetic division/modulo, rather than the DUT bit slices.
  function integer physical_address;
    input integer logical_word_arg;
    input [19:0] vector_arg;
    integer slot_arg, id_arg;
    begin
      slot_arg = logical_word_arg / 512;
      id_arg = (vector_arg >> (slot_arg*4)) & 15;
      physical_address = id_arg*512 + (logical_word_arg % 512);
    end
  endfunction
  task check;
    input condition;
    input string message;
    begin
      if (condition !== 1'b1) begin
        errors = errors + 1;
        if (errors < 65) $display("RX8K_SAP_ERROR case=%0d name=%0s %0s",case_id,case_name,message);
      end
    end
  endtask

  // Inputs are changed only on falling edges.  The fixed one-cycle PMEM model
  // updates pm_data by NBA at a grant, so the next rising edge sees that word.
  // Data is poisoned in every non-granted cycle to expose early/late capture.
  always @(negedge clk) begin
    if (rst_sync || !active) begin
      pm_gnt = 1'b0; free_take = 1'b0; out_ready = 1'b1;
    end else begin
      if (pm_req) begin
        if (grant_mode == 0) pm_gnt = 1'b1;
        else if (grant_mode == 2) pm_gnt = (request_age >= 1000);
        else pm_gnt = (request_age >= (2 + ((reads+fixture_seed) % 5)));
        request_age = request_age + 1;
      end else begin
        pm_gnt = 1'b0; request_age = 0;
      end
      if (free_req) begin
        free_take = (free_age >= free_delay);
        free_age = free_age + 1;
      end else free_take = 1'b0;
      out_ready = 1'b1;
      if ((payload_mode != 0) && out_vld) begin
        if (out_eop && (eop_age < 7)) begin out_ready = 1'b0; eop_age = eop_age+1; end
        else if (out_sop && (sop_age < 5)) begin out_ready = 1'b0; sop_age = sop_age+1; end
        else if ((got >= length/2) && (mid_age < 5)) begin out_ready = 1'b0; mid_age = mid_age+1; end
        else if (((cycles + fixture_seed) % 11) < 3) out_ready = 1'b0;
      end
    end
  end

  // All scoreboard counters have this one rising-edge owner while active.
  always @(posedge clk) begin
    cycles = cycles + 1;
    if (rst_sync) begin
      pm_data <= 32'hbad0_cafe;
      response_pending = 1'b0;
      request_held = 1'b0; release_held = 1'b0; payload_held = 1'b0;
    end else begin
      if (active) begin
        if (request_held) begin
          check(pm_req === 1'b1, "withdrawn_ungranted_request");
          check(pm_addr === held_addr, "ungranted_address_changed");
        end
        if (release_held) begin
          check(free_req === 1'b1, "withdrawn_free_request");
          check(free_id === held_free_id, "free_id_changed_under_backpressure");
        end
        if (payload_held) begin
          check(out_vld === 1'b1, "valid_changed_under_payload_backpressure");
          check({out_data,out_sop,out_eop,out_srcip,out_sport,out_dport,out_plen,out_app_len} === held_payload,
                "payload_or_metadata_changed_under_backpressure");
          check(pay_cnt === held_pay_cnt, "pay_counter_recounted_stalled_byte");
        end
        if (response_pending) begin
          check(captures < expected_reads, "extra_read_response");
          check(pm_data === image_word(6+captures,fixture_seed,length), "one_cycle_read_data");
          check(response_addr === physical_address(6+captures,blocks), "response_address_order");
          captures = captures + 1;
          last_capture_cycle = cycles;
        end
        if (pm_req) begin
          check(valid_descriptor, "invalid_descriptor_issued_read");
          check(reads < expected_reads, "extra_pmem_request");
          check(pm_addr === physical_address(6+reads,blocks), "logical_to_sparse_physical_address");
          if (!pm_gnt) req_stalls = req_stalls + 1;
          else begin
            if (((6+reads) % 512) == 0) boundaries = boundaries + 1;
            reads = reads + 1;
          end
        end
        if (free_req) begin
          check(frees == 0, "head_released_more_than_once");
          check(free_id === head, "release_did_not_use_latched_head");
          check(reads == expected_reads && captures == expected_reads,
                "free_before_all_required_reads_and_captures");
          if (expected_reads != 0) check(last_capture_cycle < cycles, "free_on_uncaptured_response_edge");
          if (!first_free_checked) begin
            // Inspect the copy destination only for this timing/copy assertion.
            // Payload and header oracles are independent of DUT storage.
            for (monitor_i=0; monitor_i<expected_reads; monitor_i=monitor_i+1)
              check(dut.g_chain.u_chain.pbuf[monitor_i] === image_word(6+monitor_i,fixture_seed,length),
                    $sformatf("pbuf_incomplete_at_first_free_word_%0d",monitor_i));
            first_free_checked = 1'b1;
          end
          if (!free_take) free_stalls = free_stalls + 1;
          else begin
            frees = frees + 1;
            // Returning the head lets the pool overwrite every owned block.
            // All subsequent bytes must therefore come from the local copy.
            for (monitor_i=0; monitor_i<8192; monitor_i=monitor_i+1)
              pmem[monitor_i] = 32'hdead_0000 ^ monitor_i;
          end
        end
        if (out_vld) begin
          check(valid_descriptor && length != 0, "rejected_or_empty_packet_streamed");
          check(captures == expected_reads, "payload_before_complete_copy");
          check(out_app_len === length[13:0], "full_application_length");
          check(out_plen === length[10:0], "legacy_length_projection");
          check(out_srcip === expected_ip(fixture_seed,length), "network_order_source_ip");
          check(out_sport === expected_sport(fixture_seed,length), "network_order_source_port");
          check(out_dport === expected_dport(fixture_seed,length), "network_order_destination_port");
          if (out_eop && !out_ready) eop_stalls = eop_stalls + 1;
          if (out_ready) begin
            check(got < expected_bytes, "extra_payload_byte");
            check(out_data === image_byte(42+got,fixture_seed,length), $sformatf("payload_byte_%0d",got));
            check(out_sop === (got == 0), "sop_position");
            check(out_eop === (got == expected_bytes-1), "eop_position");
            lane_mask[(42+got)%4] = 1'b1;
            if (((42+got) % 2048) == 0 || ((42+got) % 2048) == 2047)
              boundary_bytes = boundary_bytes + 1;
            got = got + 1;
          end
        end
        if (in_ready && accepts != 0) begin
          check(got == expected_bytes && frees == expected_frees && captures == expected_reads,
                "ready_before_packet_and_release_complete");
        end
        // in_ready on the first handshake advertises admission, not completion.
        // Check the prior accepted task before counting this edge's admission.
        if (in_vld && in_ready) accepts = accepts + 1;
        request_held = pm_req && !pm_gnt; held_addr = pm_addr;
        release_held = free_req && !free_take; held_free_id = free_id;
        payload_held = out_vld && !out_ready;
        held_payload = {out_data,out_sop,out_eop,out_srcip,out_sport,out_dport,out_plen,out_app_len};
        held_pay_cnt = pay_cnt;
      end
      response_pending = pm_req && pm_gnt;
      response_addr = pm_addr;
      if (pm_req && pm_gnt) pm_data <= pmem[pm_addr];
      else pm_data <= 32'hbad0_cafe ^ cycles;
    end
  end

  task begin_case;
    input string name_arg;
    input integer len_arg, count_arg;
    input [19:0] vector_arg;
    input [3:0] head_arg;
    input integer seed_arg, grant_arg, free_arg, payload_arg;
    input valid_arg;
    integer i, w, timeout;
    begin
      timeout = 0;
      while (!in_ready && timeout < 300000) begin @(negedge clk); #1; timeout=timeout+1; end
      check(in_ready, "idle_timeout_before_case");
      @(negedge clk); #1;
      case_id=case_id+1; case_name=name_arg; case_kind=valid_arg ? "normal" : "reject";
      case_errors=errors; length=len_arg; block_count=count_arg; blocks=vector_arg;
      head=head_arg; fixture_seed=seed_arg; port_id=(seed_arg+7)&255;
      valid_descriptor=valid_arg;
      expected_reads=valid_arg ? ((41+len_arg)/4-6+1) : 0;
      expected_bytes=valid_arg ? len_arg : 0; expected_frees=1;
      reads=0; captures=0; got=0; frees=0; accepts=0;
      req_stalls=0; eop_stalls=0; free_stalls=0; boundaries=0; boundary_bytes=0;
      lane_mask=0; last_capture_cycle=-1; first_free_checked=0;
      request_held=0; release_held=0; payload_held=0; response_pending=0;
      grant_mode=grant_arg; free_delay=free_arg; payload_mode=payload_arg;
      request_age=0; free_age=0; sop_age=0; mid_age=0; eop_age=0;
      base_accept=accept_cnt; base_free=free_cnt; base_pay=pay_cnt; base_trunc=trunc_cnt;
      for (i=0;i<8192;i=i+1) pmem[i]=32'hd00d_0000 ^ (i*17+seed_arg);
      if (valid_arg)
        for (w=0;w<count_arg*512;w=w+1)
          pmem[physical_address(w,vector_arg)]=image_word(w,seed_arg,len_arg);
      active=1;
      in_port=port_id; in_blk=head_arg;
      // Deliberately disagree with the chain length: this projection is not the source.
      in_plen=len_arg[10:0] ^ 11'h355;
      in_app_len=len_arg[13:0]; in_blocks=vector_arg; in_block_count=count_arg[2:0];
      in_vld=1;
      @(negedge clk); #1;
      check(accepts == 1, "descriptor_not_accepted_once");
      in_vld=0;
      // Mutating every descriptor field after acceptance must be harmless.
      in_port=8'hfe; in_blk=4'd2; in_plen=11'h777;
      in_app_len=14'h3fff; in_blocks=20'h01234; in_block_count=3'd0;
    end
  endtask

  task emit_case;
    begin
      $display("RX8K_SAP_CASE id=%0d name=%0s kind=%0s len=%0d count=%0d reads=%0d captures=%0d bytes=%0d frees=%0d expected_reads=%0d expected_captures=%0d expected_bytes=%0d expected_frees=%0d req_stalls=%0d eop_stalls=%0d free_stalls=%0d boundaries=%0d errors=%0d verdict=%0s",
               case_id,case_name,case_kind,length,block_count,reads,captures,got,frees,
               expected_reads,expected_reads,expected_bytes,expected_frees,
               req_stalls,eop_stalls,free_stalls,boundaries,errors-case_errors,
               (errors==case_errors) ? "OK" : "BAD");
      active=0;
    end
  endtask
  task run_case;
    input string name_arg;
    input integer len_arg, count_arg;
    input [19:0] vector_arg;
    input [3:0] head_arg;
    input integer seed_arg, grant_arg, free_arg, payload_arg;
    input valid_arg;
    integer timeout;
    begin
      begin_case(name_arg,len_arg,count_arg,vector_arg,head_arg,seed_arg,grant_arg,free_arg,payload_arg,valid_arg);
      timeout=0;
      while (!in_ready && timeout<300000) begin @(negedge clk); #1; timeout=timeout+1; end
      check(in_ready, "case_completion_timeout");
      check(accepts==1 && accept_cnt==base_accept+1, "accept_counter");
      check(reads==expected_reads && captures==expected_reads, "exact_read_capture_count");
      check(got==expected_bytes && frees==1 && free_cnt==base_free+1, "exact_payload_and_single_release");
      check(pay_cnt==base_pay+expected_bytes, "payload_counter_counts_each_emission_once");
      check(trunc_cnt==base_trunc+(valid_arg ? 0 : 1), "rejection_counter");
      check(out_app_len===len_arg[13:0] && out_plen===len_arg[10:0], "latched_length_sidebands");
      check(last_desc==={1'b1,8'd0,port_id,head_arg,len_arg[10:0]}, "legacy_last_desc_layout");
      if (valid_arg) begin
        check(out_srcip===expected_ip(seed_arg,len_arg) && out_sport===expected_sport(seed_arg,len_arg) &&
              out_dport===expected_dport(seed_arg,len_arg), "header_parse_including_zero_length");
        check(boundaries==((41+len_arg)/2048), "every_sparse_block_boundary_read");
        check(boundary_bytes==((42+len_arg)/2048)+((41+len_arg)/2048), "payload_lanes_on_both_sides_of_block_boundary");
        if (len_arg>=4) check(lane_mask==4'b1111, "all_network_byte_lanes");
        if (grant_arg==1) check(req_stalls>0, "missing_request_backpressure_coverage");
        if (payload_arg!=0 && len_arg!=0) check(eop_stalls>=7, "missing_last_byte_stall_coverage");
      end
      if (free_arg>0) check(free_stalls>=free_arg, "missing_free_take_backpressure_coverage");
      emit_case;
    end
  endtask

  task reset_case;
    input string name_arg;
    input integer phase_arg;
    integer timeout, saved_reads, saved_captures, saved_bytes, saved_frees;
    begin
      begin_case(name_arg, (phase_arg<3) ? 8192 : ((phase_arg==3) ? 64 : 7),
                 (phase_arg<3) ? 5 : 1,20'h9c7f6,4'd6,70+phase_arg,
                 (phase_arg==0) ? 2 : 0,0,(phase_arg==4) ? 1 : 0,1'b1);
      case_kind="reset"; timeout=0;
      while (timeout<300000 &&
             !((phase_arg==0 && req_stalls>=4) ||
               (phase_arg==1 && reads==1 && captures==0) ||
               (phase_arg==2 && captures==3) ||
               (phase_arg==3 && got==5) ||
               (phase_arg==4 && eop_stalls>=3))) begin
        @(negedge clk); #1; timeout=timeout+1;
      end
      check(timeout<300000, "reset_phase_timeout");
      saved_reads=reads; saved_captures=captures; saved_bytes=got; saved_frees=frees;
      case (phase_arg)
        0: check(reads==0 && captures==0 && got==0 && frees==0, "reset_held_request_checkpoint");
        1: check(reads==1 && captures==0 && got==0 && frees==0, "reset_pending_response_checkpoint");
        2: check(reads==3 && captures==3 && got==0 && frees==0, "reset_partial_copy_checkpoint");
        3: check(reads==expected_reads && captures==expected_reads && got==5 && frees==1, "reset_stream_checkpoint");
        4: check(reads==expected_reads && captures==expected_reads && got==6 && frees==1, "reset_stalled_eop_checkpoint");
      endcase
      rst_sync=1; in_vld=0; active=0;
      repeat (3) begin
        @(negedge clk); #1;
        check(!pm_req && !free_req && !out_vld && !in_ready, "chain_reset_quiescence");
        check(accept_cnt==0 && free_cnt==0 && pay_cnt==0 && trunc_cnt==0 && last_desc==0,
              "reset_counters_and_descriptor");
      end
      check(reads==saved_reads && captures==saved_captures && got==saved_bytes && frees==saved_frees,
            "reset_did_not_complete_or_release_old_job");
      rst_sync=0;
      repeat (5) begin
        @(negedge clk); #1;
        check(in_ready && !pm_req && !free_req && !out_vld, "no_stale_work_after_reset");
      end
      // Reset rows have strict checkpoint expectations rather than successful full-job counts.
      expected_reads=(phase_arg==0) ? 0 : ((phase_arg==1) ? 1 : ((phase_arg==2) ? 3 : saved_reads));
      expected_bytes=(phase_arg==3) ? 5 : ((phase_arg==4) ? 6 : 0);
      expected_frees=(phase_arg>=3) ? 1 : 0;
      $display("RX8K_SAP_CASE id=%0d name=%0s kind=reset len=%0d count=%0d reads=%0d captures=%0d bytes=%0d frees=%0d expected_reads=%0d expected_captures=%0d expected_bytes=%0d expected_frees=%0d req_stalls=%0d eop_stalls=%0d free_stalls=%0d boundaries=%0d errors=%0d verdict=%0s",
               case_id,case_name,length,block_count,reads,captures,got,frees,expected_reads,
               (phase_arg==1) ? 0 : expected_reads,expected_bytes,expected_frees,
               req_stalls,eop_stalls,free_stalls,boundaries,errors-case_errors,
               (errors==case_errors) ? "OK" : "BAD");
      active=0;
    end
  endtask

  initial begin
    repeat (4) @(negedge clk);
    #1; rst_sync=0;
    run_case("zero_header",0,1,20'h00006,6,1,1,9,0,1);
    run_case("lane_len1_unused_tail",1,1,20'h01236,6,2,1,3,1,1);
    run_case("lane_len2",2,1,20'h9c7f6,6,3,0,0,1,1);
    run_case("lane_len3",3,1,20'h9c7f6,6,4,1,5,1,1);
    run_case("lane_len4",4,1,20'h9c7f6,6,5,0,0,1,1);
    run_case("lane_len5",5,1,20'h9c7f6,6,6,1,7,1,1);
    run_case("lane_len7",7,1,20'h9c7f6,6,7,0,0,1,1);
    run_case("lane_len8",8,1,20'h9c7f6,6,8,1,0,1,1);
    run_case("free_wait_after_payload",31,1,20'h9c7f6,6,9,1,250,1,1);
    run_case("legacy_capacity622",622,1,20'h9c7f6,6,10,0,0,1,1);
    run_case("chain_full623",623,1,20'h9c7f6,6,11,1,13,1,1);
    run_case("boundary2006",2006,1,20'h9c7f6,6,12,1,17,1,1);
    run_case("boundary2007",2007,2,20'h9c7f6,6,13,1,19,1,1);
    run_case("boundary8150",8150,4,20'h9c7f6,6,14,1,23,1,1);
    run_case("boundary8151",8151,5,20'h9c7f6,6,15,1,29,1,1);
    run_case("full8191",8191,5,20'h9c7f6,6,16,1,31,1,1);
    run_case("full8192",8192,5,20'h9c7f6,6,17,1,37,1,1);
    run_case("full8192_sparse_head13",8192,5,20'hb8e6d,13,18,1,41,1,1);
    run_case("overallocated2006",2006,5,20'h9c7f6,6,19,1,11,1,1);
    run_case("zero_five_blocks",0,5,20'hb8e6d,13,20,1,15,0,1);
    run_case("full8192_no_stalls",8192,5,20'h9c7f6,6,21,0,0,0,1);
    run_case("boundary2007_head15",2007,2,20'h9b6ef,15,22,1,9,1,1);
    run_case("two_block_exact4054",4054,2,20'h9c7f6,6,23,1,13,1,1);
    run_case("three_block_start4055",4055,3,20'h9c7f6,6,24,1,7,1,1);
    run_case("three_block_exact6102",6102,3,20'h9c7f6,6,25,1,17,1,1);
    run_case("four_block_start6103",6103,4,20'h9c7f6,6,26,1,19,1,1);
    run_case("reject_len8193",8193,5,20'h9c7f6,6,27,1,7,0,0);
    run_case("reject_len16383",16383,5,20'h9c7f6,6,28,1,11,0,0);
    run_case("reject_count0_zero",0,0,20'h9c7f6,6,29,1,5,0,0);
    run_case("reject_count6",32,6,20'h9c7f6,6,30,1,7,0,0);
    run_case("reject_count7",32,7,20'h9c7f6,6,31,1,9,0,0);
    run_case("reject_head_mismatch",32,1,20'h9c7f6,7,32,1,11,0,0);
    run_case("reject_head_id0",32,1,20'h9c7f0,0,33,1,13,0,0);
    run_case("reject_active_id5",2007,2,20'h9c756,6,34,1,15,0,0);
    run_case("reject_tail_active_id0",8192,5,20'h0c7f6,6,35,1,17,0,0);
    run_case("reject_alias_slot1",2007,2,20'h9c766,6,36,1,19,0,0);
    run_case("reject_alias_slot4",8192,5,20'h6c7f6,6,37,1,21,0,0);
    run_case("reject_capacity2007",2007,1,20'h9c7f6,6,38,1,23,0,0);
    run_case("reject_capacity8151",8151,4,20'h9c7f6,6,39,1,25,0,0);
    run_case("reject_capacity8192",8192,4,20'h9c7f6,6,40,1,27,0,0);
    run_case("reject_zero_capacity8192",8192,0,20'h9c7f6,6,41,1,29,0,0);
    reset_case("reset_held_request",0);
    reset_case("reset_granted_response",1);
    reset_case("reset_partial_copy",2);
    reset_case("reset_mid_stream",3);
    reset_case("reset_stalled_eop",4);
    run_case("recovery_full8192",8192,5,20'hb8e6d,13,90,1,31,1,1);
    check(case_id==EXPECT_CASES, "planned_case_count");
    $display("RX8K_SAP_CHAIN %0s mode=chain cases=%0d errors=%0d",
             (errors==0) ? "PASS" : "FAIL",case_id,errors);
    $finish;
  end
  initial begin
    #100000000;
    $display("RX8K_SAP_ERROR watchdog_timeout");
    $fatal(1,"RX8K_SAP_CHAIN FAIL watchdog");
  end
endmodule

// This top is parameterized only for the two new-input wiring protections.
// The reference module is generated by renaming the pinned original baseline.
module sap_legacy_equivalence #(
  parameter integer CONNECT_NEW = 0
);
  localparam integer EXPECT_CASES = 15;
  reg clk = 1'b0;
  always #5 clk = ~clk;
  reg rst_sync = 1'b1;
  reg in_vld = 1'b0;
  reg [7:0] in_port = 8'd7;
  reg [3:0] in_blk = 4'd6;
  reg [10:0] in_plen = 11'd0;
  reg [13:0] poison_len = 14'hxxxx;
  reg [19:0] poison_blocks = 20'hxxxxx;
  reg [2:0] poison_count = 3'bxxx;
  wire in_ready, r_in_ready, pm_req, r_pm_req;
  wire [12:0] pm_addr, r_pm_addr;
  reg pm_gnt = 1'b0;
  reg [31:0] pm_data = 32'd0;
  reg [31:0] pmem [0:8191];
  wire out_vld,out_sop,out_eop,r_out_vld,r_out_sop,r_out_eop;
  wire [7:0] out_data,r_out_data;
  wire [15:0] out_sport,out_dport,r_out_sport,r_out_dport;
  wire [31:0] out_srcip,r_out_srcip;
  wire [10:0] out_plen,r_out_plen;
  wire [13:0] out_app_len;
  reg out_ready = 1'b1;
  wire free_req,r_free_req;
  reg free_take = 1'b0;
  wire [3:0] free_id,r_free_id;
  wire [31:0] accept_cnt,free_cnt,last_desc,pay_cnt,trunc_cnt;
  wire [31:0] r_accept_cnt,r_free_cnt,r_last_desc,r_pay_cnt,r_trunc_cnt;
  wire [1:0] legacy_st;
  wire legacy_cap_v;
  wire [31:0] legacy_pbuf0;

  // CHAIN_ENABLE is deliberately omitted: this tests the actual default.
  generate
    if (CONNECT_NEW == 0) begin : g_open
      mgmt_sap_rx dut (
      .clk(clk), .rst_sync(rst_sync), .in_vld(in_vld), .in_ready(in_ready),
      .in_port(in_port), .in_blk(in_blk), .in_plen(in_plen),
      .pm_req(pm_req), .pm_addr(pm_addr), .pm_gnt(pm_gnt), .pm_data(pm_data),
      .out_vld(out_vld), .out_sop(out_sop), .out_eop(out_eop), .out_data(out_data),
      .out_sport(out_sport), .out_dport(out_dport), .out_srcip(out_srcip),
      .out_plen(out_plen), .out_app_len(out_app_len), .out_ready(out_ready),
      .free_req(free_req), .free_take(free_take), .free_id(free_id),
      .accept_cnt(accept_cnt), .free_cnt(free_cnt), .last_desc(last_desc),
      .pay_cnt(pay_cnt), .trunc_cnt(trunc_cnt),
      .in_app_len(14'bz), .in_blocks(20'hzzzzz), .in_block_count(3'bzzz)
      );
      assign legacy_st = dut.st;
      assign legacy_cap_v = dut.cap_v;
      assign legacy_pbuf0 = dut.pbuf[0];
    end else begin : g_poison
      mgmt_sap_rx dut (
      .clk(clk), .rst_sync(rst_sync), .in_vld(in_vld), .in_ready(in_ready),
      .in_port(in_port), .in_blk(in_blk), .in_plen(in_plen),
      .pm_req(pm_req), .pm_addr(pm_addr), .pm_gnt(pm_gnt), .pm_data(pm_data),
      .out_vld(out_vld), .out_sop(out_sop), .out_eop(out_eop), .out_data(out_data),
      .out_sport(out_sport), .out_dport(out_dport), .out_srcip(out_srcip),
      .out_plen(out_plen), .out_app_len(out_app_len), .out_ready(out_ready),
      .free_req(free_req), .free_take(free_take), .free_id(free_id),
      .accept_cnt(accept_cnt), .free_cnt(free_cnt), .last_desc(last_desc),
      .pay_cnt(pay_cnt), .trunc_cnt(trunc_cnt),
        .in_app_len(poison_len), .in_blocks(poison_blocks), .in_block_count(poison_count)
      );
      assign legacy_st = dut.st;
      assign legacy_cap_v = dut.cap_v;
      assign legacy_pbuf0 = dut.pbuf[0];
    end
  endgenerate
  mgmt_sap_rx_legacy_reference ref_dut (
      .clk(clk), .rst_sync(rst_sync), .in_vld(in_vld), .in_ready(r_in_ready),
      .in_port(in_port), .in_blk(in_blk), .in_plen(in_plen),
      .pm_req(r_pm_req), .pm_addr(r_pm_addr), .pm_gnt(pm_gnt), .pm_data(pm_data),
      .out_vld(r_out_vld), .out_sop(r_out_sop), .out_eop(r_out_eop), .out_data(r_out_data),
      .out_sport(r_out_sport), .out_dport(r_out_dport), .out_srcip(r_out_srcip),
      .out_plen(r_out_plen), .out_ready(out_ready),
      .free_req(r_free_req), .free_take(free_take), .free_id(r_free_id),
      .accept_cnt(r_accept_cnt), .free_cnt(r_free_cnt), .last_desc(r_last_desc),
      .pay_cnt(r_pay_cnt), .trunc_cnt(r_trunc_cnt)
  );

  integer errors=0, case_errors=0, case_id=0, cycles=0, compared_cycles=0;
  string case_name="legacy_idle";
  reg active=1'b0;
  integer length=0, fixture_seed=0, expected_bytes=0, expected_reads=0;
  integer reads=0, captures=0, got=0, frees=0, accepts=0;
  integer req_stalls=0, eop_stalls=0, free_stalls=0;
  integer grant_mode=0, free_delay=0, payload_mode=0;
  integer free_age=0, sop_age=0, mid_age=0, eop_age=0;
  integer base_accept=0,base_free=0,base_pay=0,base_trunc=0;
  reg response_pending=1'b0;
  reg request_held=1'b0,payload_held=1'b0,release_held=1'b0;
  reg [12:0] held_addr=13'd0;
  reg [3:0] held_free_id=4'd0;
  reg [98:0] held_payload=99'd0;
  integer i;

  // Independent fixture: block-sensitive pattern and explicit network-order header.
  function [7:0] image_byte;
    input integer raw_index;
    input integer seed;
    input integer app_len;
    integer mixed, sport, dport, udp_len, ip_len;
    begin
      mixed = raw_index*37 + (raw_index/4)*11 + (raw_index/2048)*67 +
              (raw_index/128)*19 + seed*23;
      sport = 16'h3100 + seed; dport = 16'h5800 + seed*5;
      udp_len = app_len + 8; ip_len = app_len + 28;
      case (raw_index)
        12: image_byte = 8'h08; 13: image_byte = 8'h00;
        14: image_byte = 8'h45;
        16: image_byte = (ip_len >> 8) & 255;
        17: image_byte = ip_len & 255;
        24: image_byte = 8'd64; 25: image_byte = 8'd17;
        26: image_byte = 8'hac; 27: image_byte = (seed ^ 8'h5a) & 255;
        28: image_byte = 8'ha7; 29: image_byte = (seed*3 + 11) & 255;
        34: image_byte = (sport >> 8) & 255; 35: image_byte = sport & 255;
        36: image_byte = (dport >> 8) & 255; 37: image_byte = dport & 255;
        38: image_byte = (udp_len >> 8) & 255; 39: image_byte = udp_len & 255;
        40, 41: image_byte = 8'd0;
        default: image_byte = mixed & 255;
      endcase
    end
  endfunction
  function [31:0] image_word;
    input integer logical_word;
    input integer seed;
    input integer app_len;
    begin
      image_word = {image_byte(logical_word*4, seed, app_len),
                    image_byte(logical_word*4+1, seed, app_len),
                    image_byte(logical_word*4+2, seed, app_len),
                    image_byte(logical_word*4+3, seed, app_len)};
    end
  endfunction
  function [31:0] expected_ip;
    input integer seed;
    input integer app_len;
    begin
      expected_ip = {image_byte(26,seed,app_len), image_byte(27,seed,app_len),
                     image_byte(28,seed,app_len), image_byte(29,seed,app_len)};
    end
  endfunction
  function [15:0] expected_sport;
    input integer seed;
    input integer app_len;
    begin expected_sport = {image_byte(34,seed,app_len), image_byte(35,seed,app_len)}; end
  endfunction
  function [15:0] expected_dport;
    input integer seed;
    input integer app_len;
    begin expected_dport = {image_byte(36,seed,app_len), image_byte(37,seed,app_len)}; end
  endfunction

  task check;
    input condition;
    input string message;
    begin
      if (condition !== 1'b1) begin
        errors=errors+1;
        if (errors<65) $display("RX8K_SAP_ERROR case=%0d name=%0s legacy_connect=%0d %0s",case_id,case_name,CONNECT_NEW,message);
      end
    end
  endtask

  // Drive the baseline and candidate with the SAME arbitration/data trace.
  // A diverging request is an error, never given an independent PMEM oracle.
  always @(negedge clk) begin
    if (CONNECT_NEW != 0) begin
      case (cycles % 4)
        0: begin poison_len=14'hxxxx; poison_blocks=20'hxxxxx; poison_count=3'bxxx; end
        1: begin poison_len=14'hzzzz; poison_blocks=20'hzzzzz; poison_count=3'bzzz; end
        2: begin poison_len=14'd8192; poison_blocks=20'h9c7f6; poison_count=3'd5; end
        3: begin poison_len=14'h3fff; poison_blocks=20'h00000; poison_count=3'd7; end
      endcase
    end
    if (rst_sync || !active) begin pm_gnt=0; free_take=0; out_ready=1; end
    else begin
      // Legacy pipelines back-to-back reads, so use a time-based grant mask.
      pm_gnt=(grant_mode==0) || ((cycles % 7)==1) || ((cycles % 7)==4);
      if (r_free_req) begin free_take=(free_age>=free_delay); free_age=free_age+1; end
      else free_take=0;
      out_ready=1;
      if (payload_mode!=0 && r_out_vld) begin
        if (r_out_eop && eop_age<7) begin out_ready=0; eop_age=eop_age+1; end
        else if (r_out_sop && sop_age<5) begin out_ready=0; sop_age=sop_age+1; end
        else if (got>=expected_bytes/2 && mid_age<5) begin out_ready=0; mid_age=mid_age+1; end
        else if (((cycles+fixture_seed)%11)<3) out_ready=0;
      end
    end
  end
  always @(posedge clk) begin
    cycles=cycles+1;
    if (rst_sync) begin
      pm_data<=32'hbad0_cafe; response_pending=0;
      request_held=0;payload_held=0;release_held=0;
    end else begin
      if (active) begin
        if (in_vld && in_ready) accepts=accepts+1;
        if (response_pending) captures=captures+1;
        if (request_held) begin check(pm_req,"legacy_request_withdrawn");check(pm_addr===held_addr,"legacy_address_hold");end
        if (release_held) begin check(free_req,"legacy_free_withdrawn");check(free_id===held_free_id,"legacy_free_id_hold");end
        if (payload_held) begin
          check(out_vld,"legacy_valid_hold");
          check({out_data,out_sop,out_eop,out_srcip,out_sport,out_dport,out_plen,out_app_len}===held_payload,
                "legacy_payload_metadata_hold");
        end
        if (pm_req) begin
          check(pm_addr==in_blk*512+6+reads,"legacy_exact_request_address");
          if (pm_gnt) reads=reads+1; else req_stalls=req_stalls+1;
        end
        if (free_req) begin
          check(reads==expected_reads && captures==expected_reads,"legacy_free_after_copy");
          if (!free_take) free_stalls=free_stalls+1;
          else begin
            frees=frees+1;
            for(i=0;i<8192;i=i+1) pmem[i]=32'hface_0000 ^ i;
          end
        end
        if (out_vld) begin
          check(out_srcip===expected_ip(fixture_seed,length) && out_sport===expected_sport(fixture_seed,length) &&
                out_dport===expected_dport(fixture_seed,length),"legacy_header");
          if (out_eop && !out_ready) eop_stalls=eop_stalls+1;
          if(out_ready) begin
            check(got<expected_bytes,"legacy_extra_byte");
            check(out_data===image_byte(42+got,fixture_seed,length),$sformatf("legacy_payload_byte_%0d",got));
            check(out_sop===(got==0) && out_eop===(got==expected_bytes-1),"legacy_sop_eop");
            got=got+1;
          end
        end
        request_held=pm_req && !pm_gnt;held_addr=pm_addr;
        release_held=free_req && !free_take;held_free_id=free_id;
        payload_held=out_vld && !out_ready;
        held_payload={out_data,out_sop,out_eop,out_srcip,out_sport,out_dport,out_plen,out_app_len};
      end
      response_pending=r_pm_req && pm_gnt;
      if(r_pm_req && pm_gnt) pm_data<=pmem[r_pm_addr];
      else pm_data<=32'hbad0_cafe ^ cycles;
    end
    // Delay only the comparator until after all sequential NBAs have settled.
    #1;
    compared_cycles=compared_cycles+1;
    check({in_ready,pm_req,pm_addr,out_vld,out_sop,out_eop,out_data,out_sport,out_dport,out_srcip,out_plen,
           free_req,free_id,accept_cnt,free_cnt,last_desc,pay_cnt,trunc_cnt} ===
          {r_in_ready,r_pm_req,r_pm_addr,r_out_vld,r_out_sop,r_out_eop,r_out_data,r_out_sport,r_out_dport,
           r_out_srcip,r_out_plen,r_free_req,r_free_id,r_accept_cnt,r_free_cnt,r_last_desc,r_pay_cnt,r_trunc_cnt},
          "default_outputs_not_cycle_equivalent_to_baseline");
    check(out_app_len==={3'd0,out_plen},"default_full_length_is_zero_extension");
    check(legacy_st===ref_dut.st && legacy_cap_v===ref_dut.cap_v,"legacy_state_hierarchy_or_timing");
    check(legacy_pbuf0===ref_dut.pbuf[0],"legacy_pbuf_hierarchy_or_copy");
  end

  task run_case;
    input string name_arg;
    input integer len_arg,seed_arg,grant_arg,free_arg,payload_arg;
    integer timeout, last_word;
    begin
      timeout=0;
      while(!in_ready && timeout<200000) begin @(negedge clk);#1;timeout=timeout+1;end
      check(in_ready,"legacy_idle_timeout");
      @(negedge clk);#1;
      case_id=case_id+1;case_name=name_arg;case_errors=errors;
      length=len_arg;fixture_seed=seed_arg;
      expected_bytes=(len_arg>622) ? 622 : len_arg;
      last_word=(41+len_arg)/4;
      if(last_word>165) last_word=165;
      expected_reads=(len_arg==0) ? 0 : last_word-6+1;
      reads=0;captures=0;got=0;frees=0;accepts=0;req_stalls=0;eop_stalls=0;free_stalls=0;
      grant_mode=grant_arg;free_delay=free_arg;payload_mode=payload_arg;
      free_age=0;sop_age=0;mid_age=0;eop_age=0;
      request_held=0;release_held=0;payload_held=0;response_pending=0;
      base_accept=accept_cnt;base_free=free_cnt;base_pay=pay_cnt;base_trunc=trunc_cnt;
      for(i=0;i<8192;i=i+1) pmem[i]=32'hd00d_0000 ^ (i*31+seed_arg);
      for(i=0;i<512;i=i+1) pmem[6*512+i]=image_word(i,seed_arg,len_arg);
      active=1;in_port=(seed_arg+7)&255;in_blk=6;in_plen=len_arg[10:0];in_vld=1;
      @(negedge clk);#1;in_vld=0;
      timeout=0;
      while(!in_ready && timeout<200000) begin @(negedge clk);#1;timeout=timeout+1;end
      check(in_ready,"legacy_completion_timeout");
      check(accepts==1 && accept_cnt==base_accept+1,"legacy_accept_count");
      check(reads==expected_reads && captures==expected_reads && got==expected_bytes,
            "legacy_read_capture_payload_counts");
      check(frees==1 && free_cnt==base_free+1,"legacy_single_free");
      check(pay_cnt==base_pay+expected_bytes,"legacy_emission_counter");
      check(trunc_cnt==base_trunc+((len_arg>622)?1:0),"legacy_truncation_preserved");
      check(out_plen===len_arg[10:0] && out_app_len==={3'd0,len_arg[10:0]},"legacy_length_projection");
      if(grant_arg!=0 && len_arg!=0) check(req_stalls>0,"legacy_request_stall_coverage");
      if(payload_arg!=0 && len_arg!=0) check(eop_stalls>=7,"legacy_last_byte_stall_coverage");
      if(free_arg>0) check(free_stalls>=free_arg,"legacy_release_stall_coverage");
      $display("RX8K_SAP_CASE id=%0d name=%0s kind=legacy len=%0d count=1 reads=%0d captures=%0d bytes=%0d frees=%0d expected_reads=%0d expected_captures=%0d expected_bytes=%0d expected_frees=1 req_stalls=%0d eop_stalls=%0d free_stalls=%0d boundaries=0 errors=%0d verdict=%0s",
               case_id,case_name,length,reads,captures,got,frees,expected_reads,expected_reads,expected_bytes,
               req_stalls,eop_stalls,free_stalls,errors-case_errors,(errors==case_errors)?"OK":"BAD");
      active=0;
    end
  endtask

  task reset_case;
    input string name_arg;
    input integer stream_arg;
    integer timeout,saved_reads,saved_captures,saved_got,saved_frees;
    begin
      @(negedge clk);#1;
      case_id=case_id+1;case_name=name_arg;case_errors=errors;
      length=512;fixture_seed=80+stream_arg;expected_bytes=512;expected_reads=(41+512)/4-6+1;
      reads=0;captures=0;got=0;frees=0;accepts=0;req_stalls=0;eop_stalls=0;free_stalls=0;
      free_age=0;sop_age=0;mid_age=0;eop_age=0;
      grant_mode=0;free_delay=0;payload_mode=0;
      response_pending=0;request_held=0;payload_held=0;release_held=0;
      for(i=0;i<512;i=i+1) pmem[6*512+i]=image_word(i,fixture_seed,length);
      active=1;in_port=8'd19;in_blk=6;in_plen=512;in_vld=1;
      @(negedge clk);#1;in_vld=0;timeout=0;
      while(timeout<200000 && !((stream_arg==0 && captures>=3) || (stream_arg!=0 && got==5))) begin
        @(negedge clk);#1;timeout=timeout+1;
      end
      check(timeout<200000,"legacy_reset_checkpoint_timeout");
      if(stream_arg==0) check(got==0 && frees==0 && reads==4 && captures==3,"legacy_copy_reset_checkpoint");
      else check(got==5 && frees==1 && reads==expected_reads && captures==expected_reads,"legacy_stream_reset_checkpoint");
      saved_reads=reads;saved_captures=captures;saved_got=got;saved_frees=frees;
      active=0;rst_sync=1;
      repeat(3) begin @(negedge clk);#1;check(accept_cnt==0 && free_cnt==0 && pay_cnt==0 && trunc_cnt==0,"legacy_reset_counters");end
      rst_sync=0;
      repeat(4) begin @(negedge clk);#1;check(in_ready && !pm_req && !free_req && !out_vld,"legacy_reset_recovery_idle");end
      $display("RX8K_SAP_CASE id=%0d name=%0s kind=reset len=512 count=1 reads=%0d captures=%0d bytes=%0d frees=%0d expected_reads=%0d expected_captures=%0d expected_bytes=%0d expected_frees=%0d req_stalls=%0d eop_stalls=%0d free_stalls=%0d boundaries=0 errors=%0d verdict=%0s",
               case_id,case_name,saved_reads,saved_captures,saved_got,saved_frees,
               (stream_arg==0)?4:133,(stream_arg==0)?3:133,(stream_arg==0)?0:5,(stream_arg==0)?0:1,req_stalls,eop_stalls,free_stalls,
               errors-case_errors,(errors==case_errors)?"OK":"BAD");
    end
  endtask
  initial begin
    repeat(4) @(negedge clk);#1;rst_sync=0;
    run_case("legacy_zero",0,1,0,11,0);
    run_case("legacy_lane1",1,2,1,7,1);
    run_case("legacy_lane2",2,3,0,0,1);
    run_case("legacy_lane3",3,4,1,9,1);
    run_case("legacy_lane4",4,5,0,0,1);
    run_case("legacy_511",511,6,1,13,1);
    run_case("legacy_tftp512",512,7,1,17,1);
    run_case("legacy_621",621,8,0,0,1);
    run_case("legacy_capacity622",622,9,1,19,1);
    run_case("legacy_truncate623",623,10,1,23,1);
    run_case("legacy_truncate2006",2006,11,1,29,1);
    run_case("legacy_truncate2047",2047,12,1,31,1);
    reset_case("legacy_reset_copy",0);
    reset_case("legacy_reset_stream",1);
    run_case("legacy_recovery512",512,90,1,11,1);
    check(case_id==EXPECT_CASES,"legacy_planned_case_count");
    $display("RX8K_SAP_CHAIN %0s mode=legacy legacy_connect=%0d cases=%0d errors=%0d cycles=%0d",
             (errors==0)?"PASS":"FAIL",CONNECT_NEW,case_id,errors,compared_cycles);
    $finish;
  end
  initial begin
    #100000000;
    $display("RX8K_SAP_ERROR legacy_watchdog_timeout");
    $fatal(1,"RX8K_SAP_CHAIN FAIL legacy watchdog");
  end
endmodule
module tb_mgmt_sap_rx_legacy_open;
  sap_legacy_equivalence #(.CONNECT_NEW(0)) bench ();
endmodule
module tb_mgmt_sap_rx_legacy_poison;
  sap_legacy_equivalence #(.CONNECT_NEW(1)) bench ();
endmodule
