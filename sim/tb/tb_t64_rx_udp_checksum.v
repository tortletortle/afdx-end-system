`timescale 1 ns / 1 ps
module tb_t64_rx_udp_checksum;
  parameter integer RESP_DELAY = 1; // 0=same grant edge, otherwise delayed cycles
  localparam integer CASES=16, STRIDE=2022, VEC_BYTES=CASES*STRIDE;
  reg clk=0; always #5 clk=~clk;
  reg rst_sync=1, job_valid=0;
  wire job_ready;
  reg [3:0] job_blk=4'd3;
  reg [13:0] job_app_len=0;
  reg [31:0] job_src_ip=32'h0a000099, job_dst_ip=32'h0a000002;
  reg job_check_en=1;
  wire rd_req; wire [12:0] rd_addr;
  reg rd_grant=0; wire rd_valid; wire [31:0] rd_data;
  wire done, good; wire [1:0] reason;
  // The default branch ignores chain metadata, including open-port Z values.
  rx_udp_checksum_engine dut(.job_blocks(20'hzzzzz), .job_block_count(3'bzzz), .*);

  reg [7:0] vectors [0:VEC_BYTES-1];
  reg [7:0] mem [0:32767];
  reg pending=0, stray_valid=0, rd_valid_q=0;
  reg [12:0] pending_addr;
  reg [31:0] rd_data_q=0;
  integer delay_left=0;
  reg check_run=0, tracking=0, prev_stalled=0;
  reg [12:0] held_addr=0;
  reg [12:0] mon_held_addr=0;
  integer stall_left=0, read_count=0, expected_words=0;
  integer reads_total=0, errors=0;
  integer guard=0, cidx=0, udp_n=0, expect_good=0, expect_reason=0;
  integer k=0, cycles=0;
  assign rd_valid = (RESP_DELAY==0) ? (rd_req && rd_grant) : (rd_valid_q | stray_valid);
  assign rd_data = (RESP_DELAY==0) ?
      {mem[{rd_addr,2'b00}],mem[{rd_addr,2'b01}],mem[{rd_addr,2'b10}],mem[{rd_addr,2'b11}]} : rd_data_q;

  // PMEM model: one request can be outstanding; response latency is parameterized.
  always @(posedge clk) begin
    if (rst_sync) begin
      pending<=0; rd_valid_q<=0; delay_left<=0;
    end else if (RESP_DELAY!=0) begin
      rd_valid_q<=0;
      if (rd_req && rd_grant) begin
        pending<=1; delay_left<=RESP_DELAY; pending_addr<=rd_addr;
      end
      if (pending) begin
        if (delay_left<=1) begin
          rd_data_q<={mem[{pending_addr,2'b00}],mem[{pending_addr,2'b01}],
                      mem[{pending_addr,2'b10}],mem[{pending_addr,2'b11}]};
          rd_valid_q<=1; pending<=0; delay_left<=0;
        end else delay_left<=delay_left-1;
      end
    end
  end

  // Force two grant-stall cycles per request and check request/address hold.
  always @(negedge clk) begin
    if (rst_sync || !check_run) begin
      rd_grant=0; tracking=0; stall_left=0;
    end else if (rd_req) begin
      if (!tracking) begin
        tracking=1; held_addr=rd_addr; stall_left=2; rd_grant=0;
      end else if (stall_left>0) begin
        if (rd_addr !== held_addr || rd_req !== 1'b1) begin
          $display("T64 request/address changed while grant stalled"); errors=errors+1;
        end
        stall_left=stall_left-1; rd_grant=0;
      end else begin
        rd_grant=1; tracking=0;
      end
    end else begin
      rd_grant=0; tracking=0;
    end
  end

  always @(posedge clk) begin
    if (rst_sync) prev_stalled<=0;
    else begin
      if (rd_req && !rd_grant) begin
        if (prev_stalled && rd_addr !== mon_held_addr) begin
          $display("T64 monitor saw unstable address under stall"); errors<=errors+1;
        end
        prev_stalled<=1; mon_held_addr<=rd_addr;
      end else prev_stalled<=0;
      if (rd_req && rd_grant) begin
        if (check_run && rd_addr !== ({job_blk,9'd8}+read_count)) begin
          $display("T64 bad read address case=%0d got=%h expected=%h",cidx,rd_addr,{job_blk,9'd8}+read_count);
          errors<=errors+1;
        end
        read_count<=read_count+1; reads_total<=reads_total+1;
      end
    end
  end

  task load_vector;
    input integer index;
    integer j, off, baddr;
    begin
      off=index*STRIDE;
      job_app_len={vectors[off],vectors[off+1]};
      job_check_en=vectors[off+2][0];
      expect_good=vectors[off+3]; expect_reason=vectors[off+4];
      udp_n={vectors[off+5],vectors[off+6]};
      if(job_app_len>2006) expected_words=0;
      else expected_words=(2+8+job_app_len+3)/4;
      for(j=0;j<32768;j=j+1) mem[j]=8'hc7;
      baddr=job_blk*2048+34;
      for(j=0;j<udp_n;j=j+1) mem[baddr+j]=vectors[off+7+j];
      cidx=index;
    end
  endtask

  task run_case;
    input integer index;
    integer start_reads;
    begin
      load_vector(index);
      read_count=0; tracking=0; check_run=(job_app_len<=2006);
      start_reads=reads_total; cycles=0;
      @(negedge clk); job_valid=1;
      @(negedge clk); job_valid=0;
      if(job_app_len<=2006 && job_ready!==1'b0) begin
        $display("T64 busy job_ready high case=%0d",index); errors=errors+1;
      end
      while(!done && cycles<50000) begin
        if(!done && job_app_len<=2006 && read_count<expected_words && dut.state==3'd4) begin
          $display("T64 finish before expected read count case=%0d",index); errors=errors+1;
        end
        @(negedge clk); cycles=cycles+1;
      end
      check_run=0; rd_grant=0;
      if(!done) begin $display("T64 timeout case=%0d",index); errors=errors+1; end
      else begin
        if(good !== expect_good[0] || reason !== expect_reason[1:0]) begin
          $display("T64 verdict case=%0d got=%b/%0d expected=%0d/%0d",index,good,reason,expect_good,expect_reason);
          errors=errors+1;
        end
        if(read_count!==expected_words) begin
          $display("T64 word count case=%0d got=%0d expected=%0d",index,read_count,expected_words);
          errors=errors+1;
        end
      end
      if(index==13 && reads_total!=start_reads) begin
        $display("T64 capacity rejection issued PMEM reads"); errors=errors+1;
      end
      @(negedge clk);
      if(done!==1'b0) begin $display("T64 done wider than one cycle"); errors=errors+1; end
    end
  endtask

  initial begin
    $readmemh("vec/t64_udp_checksum.hex",vectors);
    repeat(4) @(negedge clk); rst_sync=0; repeat(2) @(negedge clk);
    for(k=0;k<CASES;k=k+1) run_case(k);

    // Reset after grant but before a delayed response, then ignore an idle stray.
    if(RESP_DELAY!=0) begin
      load_vector(0); read_count=0; check_run=1; tracking=0;
      @(negedge clk); job_valid=1; @(negedge clk); job_valid=0;
      guard=0; while(!dut.outstanding && guard<30) begin @(negedge clk); guard=guard+1; end
      if(!dut.outstanding) begin $display("T64 failed to reach outstanding read"); errors=errors+1; end
      rst_sync=1; repeat(2) @(negedge clk); rst_sync=0;
      check_run=0; rd_grant=0; stray_valid=1; @(negedge clk); stray_valid=0;
      if(done || !job_ready) begin $display("T64 reset stray response ownership"); errors=errors+1; end
    end
    run_case(0);
    if(errors==0) $display("T64 UDP_CHECKSUM PASS RESP_DELAY=%0d",RESP_DELAY);
    else $display("T64 UDP_CHECKSUM FAIL errors=%0d",errors);
    $finish;
  end
  initial begin #8000000; $display("T64 timeout RESP_DELAY=%0d",RESP_DELAY); $finish; end
endmodule

module tb_t64a_rx_udp_checksum;
  tb_t64_rx_udp_checksum #(.RESP_DELAY(0)) test();
endmodule

module tb_t64b_rx_udp_checksum;
  tb_t64_rx_udp_checksum #(.RESP_DELAY(5)) test();
endmodule
