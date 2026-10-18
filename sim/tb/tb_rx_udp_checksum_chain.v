// Standalone checksum tests. No top, bind, regress, or golden dependency.
// Compile/run only after the owner releases the heavy-tool slot.
`timescale 1 ns / 1 ps
module tb_rx_udp_checksum_chain;
  parameter integer CHAIN_MODE = 1;
  parameter integer LEGACY_CONNECT = 0;
  localparam [31:0] SRC_IP = 32'h0a000099, DST_IP = 32'h0a000002;
  localparam [19:0] SPARSE = 20'h9c7f6; // logical slots: 6,15,7,12,9
  localparam integer ZERO_CHECKSUM=1, BAD_PAYLOAD=2, BAD_LENGTH=4,
                     BAD_CHECKSUM=8, WIRE_FFFF=16, WRONG_SRC_IP=32;

  reg clk=0;
  always #5 clk=~clk;
  reg rst_sync=1, job_valid=0;
  wire job_ready;
  reg [3:0] job_blk=0;
  reg [19:0] job_blocks=0;
  reg [2:0] job_block_count=0;
  reg [13:0] job_app_len=0;
  reg [31:0] job_src_ip=SRC_IP, job_dst_ip=DST_IP;
  reg job_check_en=1;
  wire rd_req;
  wire [12:0] rd_addr;
  reg rd_grant=0, rd_valid=0;
  reg [31:0] rd_data=0;
  wire done, good;
  wire [1:0] reason;

  generate
    if (CHAIN_MODE != 0) begin : g_chain
      rx_udp_checksum_engine #(.CHAIN_ENABLE(1)) dut (
        .clk(clk), .rst_sync(rst_sync), .job_valid(job_valid), .job_ready(job_ready),
        .job_blk(job_blk), .job_app_len(job_app_len), .job_src_ip(job_src_ip),
        .job_dst_ip(job_dst_ip), .job_check_en(job_check_en),
        .rd_req(rd_req), .rd_addr(rd_addr), .rd_grant(rd_grant),
        .rd_valid(rd_valid), .rd_data(rd_data), .done(done), .good(good),
        .reason(reason), .job_blocks(job_blocks), .job_block_count(job_block_count)
      );
    end else if (LEGACY_CONNECT != 0) begin : g_legacy_poison
      // Use the default parameter and drive optional metadata to X/Z.
      rx_udp_checksum_engine dut (
        .clk(clk), .rst_sync(rst_sync), .job_valid(job_valid), .job_ready(job_ready),
        .job_blk(job_blk), .job_app_len(job_app_len), .job_src_ip(job_src_ip),
        .job_dst_ip(job_dst_ip), .job_check_en(job_check_en),
        .rd_req(rd_req), .rd_addr(rd_addr), .rd_grant(rd_grant),
        .rd_valid(rd_valid), .rd_data(rd_data), .done(done), .good(good),
        .reason(reason), .job_blocks(job_blocks), .job_block_count(job_block_count)
      );
    end else begin : g_legacy_open
      // Explicit Z preserves the electrical value of open optional ports.
      rx_udp_checksum_engine dut (
        .clk(clk), .rst_sync(rst_sync), .job_valid(job_valid), .job_ready(job_ready),
        .job_blk(job_blk), .job_app_len(job_app_len), .job_src_ip(job_src_ip),
        .job_dst_ip(job_dst_ip), .job_check_en(job_check_en),
        .rd_req(rd_req), .rd_addr(rd_addr), .rd_grant(rd_grant),
        .rd_valid(rd_valid), .rd_data(rd_data), .done(done), .good(good), .reason(reason),
        .job_blocks(20'hzzzzz), .job_block_count(3'bzzz)
      );
    end
  endgenerate

  reg [7:0] mem [0:32767];
  reg [7:0] datagram [0:8199];
  reg [7:0] pseudo [0:11];
  reg [19:0] case_blocks=0;
  reg [3:0] case_head=0;
  reg [2:0] case_count=0;
  integer case_len=0, expected_words=0;
  reg expected_good=0;
  reg [1:0] expected_reason=0;
  reg case_active=0, case_accepted=0, idle_stray=0;
  integer response_delay=0, final_response_delay=0;
  integer errors=0, cases=0, case_id=0, tick=0;
  integer read_count=0, response_count=0, done_count=0, last_response_tick=-1;
  integer stall_samples=0, stray_samples=0;
  reg awaiting_reply=0, previous_stall=0;
  reg [12:0] monitor_held_addr=0;

  // Address oracle uses division/modulo on saved job metadata, not DUT state.
  function [14:0] physical_byte;
    input integer raw;
    reg [3:0] block_id;
    begin
      if (CHAIN_MODE != 0) block_id=case_blocks[(raw/2048)*4 +: 4];
      else block_id=case_head;
      physical_byte=block_id*2048+(raw%2048);
    end
  endfunction

  function [31:0] memory_word;
    input [12:0] address;
    integer base;
    begin
      base=address*4;
      memory_word={mem[base],mem[base+1],mem[base+2],mem[base+3]};
    end
  endfunction

  // Independent oracle: sum complete network-order bytes, then fold in a loop.
  function [15:0] reference_fold;
    input [31:0] accumulator;
    reg [31:0] temporary;
    begin
      temporary=accumulator;
      while (temporary>32'hffff)
        temporary=(temporary & 32'hffff)+(temporary >> 16);
      reference_fold=temporary[15:0];
    end
  endfunction

  task fail;
    input [8*112-1:0] message;
    begin
      $display("RX8K_CHECKSUM_ERROR id=%0d name=%0s",case_id,message);
      errors=errors+1;
    end
  endtask

  reg model_pending=0, grant_tracking=0;
  reg [12:0] model_pending_addr=0;
  integer delay_left=0, stall_left=0;
  // Drive before the sampling edge. Mix same-edge and delayed responses.
  // Every request has 2..4 grant-stall cycles with unsolicited data pulses.
  always @(negedge clk) begin
    rd_grant=0;
    rd_valid=0;
    rd_data=32'hdeadc0de;
    if (rst_sync || !case_active) begin
      model_pending=0;
      grant_tracking=0;
      delay_left=0;
      stall_left=0;
      if (!rst_sync && idle_stray) rd_valid=1;
    end else begin
      if (model_pending) begin
        if (delay_left<=1) begin
          rd_valid=1;
          rd_data=memory_word(model_pending_addr);
          model_pending=0;
        end else delay_left=delay_left-1;
      end
      if (rd_req) begin
        if (!grant_tracking) begin
          grant_tracking=1;
          stall_left=2+(read_count%3);
        end
        if (stall_left>0) begin
          stall_left=stall_left-1;
          // A response before ownership must be ignored by S_REQ.
          rd_valid=1;
          rd_data=32'h5aa53cc3;
        end else begin
          rd_grant=1;
          grant_tracking=0;
          if (response_delay==0 && final_response_delay==0) begin
            rd_valid=1;
            rd_data=memory_word(rd_addr);
          end else begin
            delay_left=response_delay;
            if (read_count==expected_words-1 && final_response_delay>0)
              delay_left=final_response_delay;
            if (delay_left==0) begin
              rd_valid=1;
              rd_data=memory_word(rd_addr);
            end else begin
              model_pending=1;
              model_pending_addr=rd_addr;
            end
          end
        end
      end else grant_tracking=0;
    end
  end

  integer logical_raw=0, last_word_bytes=0, minimum_finish_delay=0;
  reg [12:0] expected_address=0;
  // Monitor external handshakes and every completion; no hierarchical peeks.
  always @(posedge clk) begin
    tick=tick+1;
    if (rst_sync) begin
      previous_stall=0;
      awaiting_reply=0;
    end else if (case_active) begin
      if (job_valid && job_ready) begin
        if (case_accepted) fail("accepted another job before completing this job");
        case_accepted=1;
      end
      if (previous_stall && (rd_req!==1'b1 || rd_addr!==monitor_held_addr))
        fail("request or address changed while grant was stalled");
      previous_stall=(rd_req===1'b1 && rd_grant!==1'b1);
      if (previous_stall) begin
        monitor_held_addr=rd_addr;
        stall_samples=stall_samples+1;
      end
      if (awaiting_reply && rd_req) fail("new read before the previous response");
      if (rd_req && expected_words==0) fail("invalid job asserted a PMEM request");
      if (rd_req && rd_grant) begin
        if (read_count>=expected_words) fail("read beyond the UDP end");
        logical_raw=32+read_count*4;
        expected_address=physical_byte(logical_raw)/4;
        if (rd_addr!==expected_address) begin
          $display("RX8K_CHECKSUM_ADDR id=%0d read=%0d got=%h expected=%h raw=%0d",
                   case_id,read_count,rd_addr,expected_address,logical_raw);
          fail("PMEM address disagrees with the saved sparse chain");
        end
        read_count=read_count+1;
        if (rd_valid) begin
          response_count=response_count+1;
          last_response_tick=tick;
        end else awaiting_reply=1;
      end else if (rd_valid && awaiting_reply) begin
        response_count=response_count+1;
        last_response_tick=tick;
        awaiting_reply=0;
      end else if (rd_valid) stray_samples=stray_samples+1;
    end
    // Evaluate outputs after nonblocking DUT updates.
    #1;
    if (!rst_sync && case_active && case_accepted) begin
      if (done===1'b1) begin
        done_count=done_count+1;
        if (read_count!=expected_words || response_count!=expected_words || awaiting_reply)
          fail("done before all expected words have returned");
        if (expected_words>0) begin
          last_word_bytes=42+case_len-(32+(expected_words-1)*4);
          minimum_finish_delay=(last_word_bytes+1)/2+1;
          if (tick<last_response_tick+minimum_finish_delay)
            fail("done before every final-word byte was consumed and verified");
        end
        if (job_ready!==1'b1) fail("completion did not return the job interface to idle");
      end else if (expected_words>0 && job_ready!==1'b0)
        fail("job_ready rose before verification completed");
    end
  end

  task build_datagram;
    input integer app_len;
    input integer flags;
    integer k, udp_n, field_n;
    reg [31:0] reference_sum;
    reg [15:0] checksum_value, old_payload_word, patch_word;
    begin
      udp_n=app_len+8;
      field_n=udp_n+((flags & BAD_LENGTH)!=0);
      for (k=0;k<32768;k=k+1) mem[k]=(k*37+(k/2048)*23+167)&255;
      datagram[0]=8'h2e; datagram[1]=8'he1; // source port 12001
      datagram[2]=8'h13; datagram[3]=8'h88; // destination port 5000
      datagram[4]=(field_n>>8)&255; datagram[5]=field_n&255;
      datagram[6]=0; datagram[7]=0;
      for (k=0;k<app_len;k=k+1)
        datagram[8+k]=(k*73+(k/7)*29+(k%4)*19+61+case_id*11)&255;
      pseudo[0]=SRC_IP[31:24]; pseudo[1]=SRC_IP[23:16];
      pseudo[2]=SRC_IP[15:8]; pseudo[3]=SRC_IP[7:0];
      pseudo[4]=DST_IP[31:24]; pseudo[5]=DST_IP[23:16];
      pseudo[6]=DST_IP[15:8]; pseudo[7]=DST_IP[7:0];
      pseudo[8]=0; pseudo[9]=17;
      pseudo[10]=(udp_n>>8)&255; pseudo[11]=udp_n&255;
      reference_sum=0;
      for (k=0;k<12;k=k+2)
        reference_sum=reference_sum+pseudo[k]*256+pseudo[k+1];
      for (k=0;k<udp_n;k=k+2) begin
        reference_sum=reference_sum+datagram[k]*256;
        if (k+1<udp_n) reference_sum=reference_sum+datagram[k+1];
      end
      if ((flags & WIRE_FFFF)!=0) begin
        // Force the calculated checksum to zero; encode that as 16'hffff.
        old_payload_word={datagram[8],datagram[9]};
        reference_sum=reference_sum-old_payload_word;
        patch_word=~reference_fold(reference_sum);
        datagram[8]=patch_word[15:8]; datagram[9]=patch_word[7:0];
        reference_sum=reference_sum+patch_word;
        if (reference_fold(reference_sum)!==16'hffff)
          fail("independent oracle could not produce the wire-ffff case");
      end
      checksum_value=~reference_fold(reference_sum);
      if (checksum_value==0) checksum_value=16'hffff;
      if ((flags & ZERO_CHECKSUM)!=0) checksum_value=0;
      if ((flags & BAD_CHECKSUM)!=0) begin
        checksum_value=checksum_value^16'h0001;
        if (checksum_value==0) checksum_value=16'h0002;
      end
      datagram[6]=checksum_value[15:8]; datagram[7]=checksum_value[7:0];
      if ((flags & BAD_PAYLOAD)!=0) datagram[udp_n-1]=datagram[udp_n-1]^8'h80;
      for (k=0;k<udp_n;k=k+1) mem[physical_byte(34+k)]=datagram[k];
      // The first read contains two non-UDP lanes; odd tails see nonzero pad.
      mem[physical_byte(32)]=8'hb6; mem[physical_byte(33)]=8'h7d;
      for (k=0;k<4;k=k+1) mem[physical_byte(34+udp_n+k)]=8'hd3+k;
    end
  endtask

  task run_case;
    input [8*72-1:0] label;
    input integer app_len;
    input [2:0] count;
    input [19:0] blocks;
    input [3:0] head;
    input integer check_enable, flags, want_good, want_reason, latency, last_latency;
    integer start_errors, cycles;
    reg actual_good;
    reg [1:0] actual_reason;
    begin
      case_id=cases+1;
      start_errors=errors;
      case_len=app_len; case_blocks=blocks; case_head=head; case_count=count;
      expected_good=want_good[0]; expected_reason=want_reason[1:0];
      if (want_reason==3) expected_words=0;
      else expected_words=(2+8+app_len+3)/4;
      read_count=0; response_count=0; done_count=0; last_response_tick=-1;
      stall_samples=0; stray_samples=0; awaiting_reply=0; previous_stall=0;
      response_delay=latency; final_response_delay=last_latency;
      case_accepted=0;
      if (expected_words>0) build_datagram(app_len,flags);
      job_blk=head; job_blocks=blocks; job_block_count=count; job_app_len=app_len;
      job_src_ip=SRC_IP; job_dst_ip=DST_IP; job_check_en=check_enable[0];
      if ((flags & WRONG_SRC_IP)!=0) job_src_ip=SRC_IP^32'h00010000;
      if (CHAIN_MODE==0) begin
        job_blocks=20'hxxxxx;
        job_block_count=3'bzzz;
      end
      if (job_ready!==1'b1) fail("job interface was not idle at case start");
      case_active=1;
      @(negedge clk); #1; job_valid=1;
      @(negedge clk); #1; job_valid=0;
      // Mutate every input after acceptance; the active job must be latched.
      job_blk=4'd2; job_blocks=20'h01234; job_block_count=0;
      job_app_len=14'h3fff; job_src_ip=~SRC_IP; job_dst_ip=~DST_IP;
      job_check_en=~check_enable[0];
      cycles=0;
      while (done!==1'b1 && cycles<100000) begin
        @(negedge clk); #1; cycles=cycles+1;
        // Pulse a second job while a long read is in flight; ready must stay low.
        job_valid=(app_len==8192 && expected_words>0 && cycles==8);
      end
      job_valid=0;
      if (done!==1'b1) begin
        fail("case timed out");
        $display("RX8K_CHECKSUM_CHAIN FAIL mode=%0d legacy_connect=%0d cases=%0d errors=%0d",
                 CHAIN_MODE,LEGACY_CONNECT,cases,errors);
        $finish;
      end
      actual_good=good; actual_reason=reason;
      if (good!==expected_good || reason!==expected_reason) fail("wrong good or reason verdict");
      if (read_count!=expected_words || response_count!=expected_words)
        fail("wrong request or owned-response count");
      if (done_count!=1) fail("completion was missing or duplicated");
      if (expected_words>0 && (stall_samples==0 || stray_samples==0))
        fail("grant stalls or pre-grant stray responses were not exercised");
      case_active=0;
      @(negedge clk); #1;
      if (done!==1'b0) fail("done pulse exceeded one cycle");
      if (job_ready!==1'b1 || rd_req!==1'b0) fail("job did not settle to idle");
      $display("RX8K_CHECKSUM_CASE id=%0d name=%0s verdict=%0s len=%0d count=%0d expected=%0d/%0d actual=%0d/%0d reads=%0d responses=%0d expected_reads=%0d errors=%0d",
               case_id,label,(errors==start_errors)?"OK":"BAD",app_len,count,
               expected_good,expected_reason,actual_good,actual_reason,
               read_count,response_count,expected_words,errors-start_errors);
      cases=cases+1;
    end
  endtask

  task probe_idle_response;
    integer k;
    begin
      idle_stray=1;
      for (k=0;k<3;k=k+1) begin
        @(negedge clk); #1;
        if (done!==1'b0 || job_ready!==1'b1 || rd_req!==1'b0)
          fail("idle stray response changed completion or readiness");
      end
      idle_stray=0;
      @(negedge clk); #1;
    end
  endtask

  initial begin
    repeat (4) @(negedge clk);
    #1; rst_sync=0;
    repeat (2) @(negedge clk);
    #1;
    probe_idle_response();
    if (CHAIN_MODE!=0) begin
      run_case("max_8192_late_final",8192,5,SPARSE,6,1,0,1,0,1,40);
      run_case("odd_8191",8191,5,SPARSE,6,1,0,1,0,7,0);
      run_case("four_block_exact_8150",8150,4,SPARSE,6,1,0,1,0,0,0);
      run_case("fifth_block_first_byte_8151",8151,5,SPARSE,6,1,0,1,0,1,0);
      run_case("one_block_exact_2006",2006,1,20'h05006,6,1,0,1,0,0,0);
      run_case("second_block_first_byte_2007",2007,2,20'h055f6,6,1,0,1,0,5,0);
      run_case("two_block_exact_4054",4054,2,SPARSE,6,1,0,1,0,0,0);
      run_case("third_block_first_byte_4055",4055,3,20'h057f6,6,1,0,1,0,3,0);
      run_case("three_block_exact_6102",6102,3,SPARSE,6,1,0,1,0,1,0);
      run_case("fourth_block_first_byte_6103",6103,4,SPARSE,6,1,0,1,0,5,0);
      run_case("alternate_sparse_head_15",8192,5,20'hd6c8f,15,1,0,1,0,2,0);
      run_case("unused_alias_slots_ignored",35,1,20'h66666,6,1,0,1,0,1,0);
      run_case("lanes_empty",0,1,SPARSE,6,1,0,1,0,0,0);
      run_case("lanes_odd_one",1,1,SPARSE,6,1,0,1,0,1,0);
      run_case("lanes_even_two",2,1,SPARSE,6,1,0,1,0,7,0);
      run_case("lanes_odd_three",3,1,SPARSE,6,1,0,1,0,0,0);
      run_case("lanes_even_four",4,1,SPARSE,6,1,0,1,0,1,0);
      run_case("lanes_odd_five",5,1,SPARSE,6,1,0,1,0,5,0);
      run_case("zero_checksum_allowed_disabled",8191,5,SPARSE,6,0,ZERO_CHECKSUM,1,0,7,20);
      run_case("zero_checksum_rejected_enabled",1,1,SPARSE,6,1,ZERO_CHECKSUM,0,2,1,0);
      run_case("bad_checksum_enabled",8192,5,SPARSE,6,1,BAD_CHECKSUM,0,2,1,0);
      run_case("bad_payload_odd_enabled",8191,5,SPARSE,6,1,BAD_PAYLOAD,0,2,5,0);
      run_case("bad_payload_allowed_disabled",8191,5,SPARSE,6,0,BAD_PAYLOAD,1,0,1,0);
      run_case("bad_udp_length_enabled",8191,5,SPARSE,6,1,BAD_LENGTH,0,1,1,0);
      run_case("bad_udp_length_disabled",8151,5,SPARSE,6,0,BAD_LENGTH,0,1,5,0);
      run_case("length_reason_precedes_checksum",35,1,SPARSE,6,1,BAD_LENGTH+BAD_CHECKSUM,0,1,1,0);
      run_case("pseudo_header_wrong_src_ip",35,1,SPARSE,6,1,WRONG_SRC_IP,0,2,1,0);
      run_case("computed_zero_encoded_ffff",2,1,SPARSE,6,1,WIRE_FFFF,1,0,0,0);
      run_case("reject_app_8193",8193,5,SPARSE,6,1,0,0,3,1,0);
      run_case("reject_app_16383_no_wrap",16383,5,SPARSE,6,1,0,0,3,1,0);
      run_case("reject_8151_four_blocks",8151,4,SPARSE,6,1,0,0,3,1,0);
      run_case("reject_8192_four_blocks",8192,4,SPARSE,6,1,0,0,3,1,0);
      run_case("reject_2007_one_block",2007,1,SPARSE,6,0,0,0,3,1,0);
      run_case("reject_count_zero",0,0,SPARSE,6,1,0,0,3,1,0);
      run_case("reject_count_six",0,6,SPARSE,6,1,0,0,3,1,0);
      run_case("reject_count_seven",0,7,SPARSE,6,1,0,0,3,1,0);
      run_case("reject_head_mismatch",1,5,SPARSE,15,1,0,0,3,1,0);
      run_case("reject_tx_head_five",1,5,20'h9c7f5,5,1,0,0,3,1,0);
      run_case("reject_tx_head_zero",1,1,20'h9c7f0,0,1,0,0,3,1,0);
      run_case("reject_tail_id_five",0,5,20'h5c7f6,6,1,0,0,3,1,0);
      run_case("reject_middle_id_zero",32,5,20'h9c0f6,6,1,0,0,3,1,0);
      run_case("reject_head_tail_alias",2007,5,20'h6c7f6,6,1,0,0,3,1,0);
      run_case("reject_middle_alias",35,5,20'h9cff6,6,1,0,0,3,1,0);
      run_case("reject_unread_tail_alias",1,5,20'hcc7f6,6,1,0,0,3,1,0);
      run_case("reject_unknown_tail_id",35,5,20'hxc7f6,6,1,0,0,3,1,0);
    end else begin
      run_case("legacy_2006_block_three",2006,0,0,3,1,0,1,0,0,0);
      run_case("legacy_reject_2007",2007,5,SPARSE,3,1,0,0,3,1,0);
      run_case("legacy_empty_block_zero",0,0,0,0,1,0,1,0,1,0);
      run_case("legacy_odd_block_fifteen",1,0,0,15,1,0,1,0,7,20);
      run_case("legacy_lane_two",2,0,0,3,1,0,1,0,1,0);
      run_case("legacy_lane_three",3,0,0,3,1,0,1,0,0,0);
      run_case("legacy_lane_five",5,0,0,3,1,0,1,0,5,0);
      run_case("legacy_zero_disabled",1,0,0,3,0,ZERO_CHECKSUM,1,0,1,0);
      run_case("legacy_zero_enabled",1,0,0,3,1,ZERO_CHECKSUM,0,2,1,0);
      run_case("legacy_bad_checksum",2006,0,0,3,1,BAD_CHECKSUM,0,2,5,0);
      run_case("legacy_bad_payload_disabled",35,0,0,3,0,BAD_PAYLOAD,1,0,1,0);
      run_case("legacy_bad_length_enabled",35,0,0,3,1,BAD_LENGTH,0,1,1,0);
      run_case("legacy_bad_length_disabled",35,0,0,3,0,BAD_LENGTH,0,1,1,0);
      run_case("legacy_computed_zero_ffff",2,0,0,3,1,WIRE_FFFF,1,0,0,0);
      run_case("legacy_reject_8192",8192,5,SPARSE,3,1,0,0,3,1,0);
      run_case("legacy_reject_16383",16383,5,SPARSE,3,1,0,0,3,1,0);
    end
    probe_idle_response();
    if (cases!=((CHAIN_MODE!=0)?45:16)) fail("testcase inventory changed unexpectedly");
    if (errors==0)
      $display("RX8K_CHECKSUM_CHAIN PASS mode=%0d legacy_connect=%0d cases=%0d errors=0",
               CHAIN_MODE,LEGACY_CONNECT,cases);
    else
      $display("RX8K_CHECKSUM_CHAIN FAIL mode=%0d legacy_connect=%0d cases=%0d errors=%0d",
               CHAIN_MODE,LEGACY_CONNECT,cases,errors);
    $finish;
  end

  initial begin
    #20000000;
    $display("RX8K_CHECKSUM_CHAIN FAIL watchdog mode=%0d legacy_connect=%0d cases=%0d errors=%0d",
             CHAIN_MODE,LEGACY_CONNECT,cases,errors);
    $finish;
  end
endmodule

module tb_rx_udp_checksum_legacy;
  tb_rx_udp_checksum_chain #(.CHAIN_MODE(0),.LEGACY_CONNECT(0)) test();
endmodule

module tb_rx_udp_checksum_legacy_poison;
  tb_rx_udp_checksum_chain #(.CHAIN_MODE(0),.LEGACY_CONNECT(1)) test();
endmodule
