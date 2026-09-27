// T17/T17g stress slice: real 64-byte A/B frames plus sustained host PMEM
// writes and interleaved reads.  This deliberately reports its finite 512-pair
// sample size; the design-book 100k-frame campaign remains a separate closure.
`timescale 1 ns / 1 ps
module tb_t17_core #(parameter integer IF_MODE=0);
  localparam integer FRAME_PAIRS = 512;
  localparam integer HOST_WRITES = 4096;
  localparam integer WORDS       = 128;
  localparam integer READ_STRIDE = 16;

  reg clk=0, reset=1;
  always #4 clk=~clk;
  reg [7:0] rx_data=0, rx_data_b=0;
  reg rx_valid=0, rx_valid_b=0, rx_ready=0, rx_ready_b=0;
  reg host_cs=0, host_we=0;
  reg [15:0] host_addr=0;
  reg [31:0] host_wdata=0;
  wire [31:0] host_rdata;
  wire host_ack;

  AFDX_top #(.IF_MODE(IF_MODE),.FCS_MODE(2)) dut (
    .clk(clk),.reset(reset),.tx_data(),.tx_valid(),.tx_ready(),
    .rx_data(rx_data),.rx_valid(rx_valid),.rx_ready(rx_ready),
    .tx_data_b(),.tx_valid_b(),.tx_ready_b(),
    .rx_data_b(rx_data_b),.rx_valid_b(rx_valid_b),.rx_ready_b(rx_ready_b),
    .host_cs(host_cs),.host_we(host_we),.host_addr(host_addr),
    .host_wdata(host_wdata),.host_rdata(host_rdata),.host_ack(host_ack),
    .host_irq(),.pps_in(1'b0),.pps_out(),.rtc_time_us(),.dbg_frame_event());

  reg [31:0] vec [0:1144];
  integer errors=0, i, n, b, t, waitc, last_txn;
  integer pop_a=0, pop_b=0, commits=0, writes=0, reads=0;
  integer deferred=0, pulse_writes=0, held_writes=0, max_wait=0;
  integer before_bad_pop;
  reg monitor_commits=0;
  reg [31:0] rd;

  function [31:0] signature;
    input integer k;
    begin signature = 32'h5A17_0000 ^ (32'h0101_0101*k) ^ (k<<11); end
  endfunction

  function [7:0] min_frame_byte;
    input integer off;
    reg [31:0] w;
    begin
      // case 0 starts at vec[1], has its 64-byte payload at vec[3].
      w=vec[3+(off>>2)];
      case(off&3)
        0:min_frame_byte=w[31:24]; 1:min_frame_byte=w[23:16];
        2:min_frame_byte=w[15:8];  default:min_frame_byte=w[7:0];
      endcase
    end
  endfunction

  task bad;
    input [8*112-1:0] reason;
    begin
      if(errors<16)
        $display("  [err] T17%0d wr=%0d rd=%0d popA/B=%0d/%0d: %0s",
                 IF_MODE,writes,reads,pop_a,pop_b,reason);
      errors=errors+1;
    end
  endtask

  always @(posedge clk) if(!reset) begin
    if(dut.rx_ovf_a || dut.rx_ovf_b) bad("RX PMEM/descriptor queue overflow");
    if(dut.rx_desc_pop_a) pop_a=pop_a+1;
    if(dut.rx_desc_pop_b) pop_b=pop_b+1;
    if(monitor_commits && (dut.host_commit_now || dut.host_commit_pending))
      commits=commits+1;
  end

  task host_write_cfg;
    input [15:0] addr;
    input [31:0] data;
    begin
      @(negedge clk); host_cs=1; host_we=1; host_addr=addr; host_wdata=data;
      @(negedge clk);
      if(host_ack!==1'b1) bad("configuration host write ACK missing");
      host_cs=0; host_we=0;
    end
  endtask

  task host_read;
    input [15:0] addr;
    output [31:0] data;
    begin
      @(negedge clk); host_cs=1; host_we=0; host_addr=addr;
      @(negedge clk);
      if(host_ack!==1'b1) bad("host read ACK missing");
      data=host_rdata; host_cs=0;
    end
  endtask

  task congested_write;
    input integer k;
    reg [31:0] want;
    begin
      want=signature(k);
      // Select a real RX-owned write cycle.  The request must first become
      // pending, then ACK only when the deferred PMEM write actually commits.
      wait(dut.rx_pmem_busy===1'b1);
      @(negedge clk);
      host_cs=1; host_we=1; host_addr=16'h8800+(k%WORDS); host_wdata=want;
      @(negedge clk);
      if(host_ack!==1'b0 || dut.host_pmem_pending!==1'b1)
        bad("early ACK or missing pending write under RX priority");
      else deferred=deferred+1;
      if(k&1) held_writes=held_writes+1;
      else begin
        pulse_writes=pulse_writes+1;
        host_cs=0; host_we=0;
        // A pulsed request proves that the accepted address/data were latched.
        host_addr=16'h887F; host_wdata=~want;
      end
      t=0;
      while(host_ack!==1'b1 && t<32) begin @(negedge clk); t=t+1; end
      if(t>=32) bad("deferred host write exceeded 32-cycle sample bound");
      if(t>max_wait) max_wait=t;
      if(k&1) begin host_cs=0; host_we=0; end
      writes=writes+1;
    end
  endtask

  task interleaved_read;
    begin
      host_read(16'h0014,rd);             // INT_ENABLE: reset value remains zero
      if(rd!==32'd0) bad("interleaved register read returned unexpected value");
      reads=reads+1;
    end
  endtask

  task drive_pair;
    begin
      for(b=0;b<64;b=b+1) begin
        @(negedge clk);
        rx_ready=1; rx_valid=1; rx_data=min_frame_byte(b);
        rx_ready_b=1; rx_valid_b=1; rx_data_b=min_frame_byte(b);
        if(IF_MODE==0) begin
          @(negedge clk); rx_valid=0; rx_valid_b=0;
          repeat(8) @(negedge clk);
        end
      end
      @(negedge clk); rx_ready=0; rx_valid=0; rx_ready_b=0; rx_valid_b=0;
      if(IF_MODE!=0) repeat(12) @(negedge clk); // 64B + 12B IFG
    end
  endtask

  task drive_bad_crc_a;
    begin
      for(b=0;b<64;b=b+1) begin
        @(negedge clk);
        rx_ready=1; rx_valid=1;
        rx_data=(b==10) ? (min_frame_byte(b)^8'h01) : min_frame_byte(b);
        if(IF_MODE==0) begin
          @(negedge clk); rx_valid=0;
          repeat(8) @(negedge clk);
        end
      end
      @(negedge clk); rx_ready=0; rx_valid=0;
    end
  endtask

  initial begin
    $readmemh("vec/t08a_frames.hex",vec);
    if(vec[0]!==22 || vec[1][15:0]!==16'd64 || vec[1][23:16]!==8'd0 || vec[2]!==32'h7)
      bad("64-byte independent T08a golden vector missing or shifted");
    repeat(7) @(negedge clk); reset=0;
    waitc=0;
    while(dut.init_done!==1 && waitc<26000) begin @(negedge clk); waitc=waitc+1; end
    if(waitc>=26000) bad("INIT_DONE timeout");
    host_write_cfg(16'h0008,32'h2000);
    host_write_cfg(16'h883F,32'hC0FF_EE00);
    // Same real A/B RX fixture as T08c; this test exercises ingress/PMEM
    // arbitration, not a claim of full port delivery or 100k-frame closure.
    host_write_cfg(16'h0078,32'h172D);
    host_write_cfg(16'h007C,32'hAB61);
    host_write_cfg(16'h42B2,32'h1010_0100);
    host_write_cfg(16'h0080,32'h1);
    host_write_cfg(16'h0008,32'h051E);
    monitor_commits=1;
    fork
      begin
        for(i=0;i<FRAME_PAIRS;i=i+1) drive_pair();
      end
      begin
        for(n=0;n<HOST_WRITES;n=n+1) begin
          congested_write(n);
          if((n%READ_STRIDE)==(READ_STRIDE-1)) interleaved_read();
        end
      end
    join
    repeat(500) @(negedge clk);
    monitor_commits=0;
    if(writes!=HOST_WRITES || deferred!=HOST_WRITES || commits!=HOST_WRITES ||
       held_writes!=(HOST_WRITES/2) || pulse_writes!=(HOST_WRITES/2) ||
       reads!=(HOST_WRITES/READ_STRIDE) || pop_a!=FRAME_PAIRS || pop_b!=FRAME_PAIRS)
      bad("transaction, read/write mix, or dual-net descriptor count mismatch");
    if(max_wait>16) bad("observed host PMEM wait exceeded 16 cycles");
    if(dut.rx_free_map!==16'hFFC0) bad("RX free-map leaked after long dual-net run");
    before_bad_pop=pop_a;
    drive_bad_crc_a();
    repeat(160) @(negedge clk);
    if(pop_a!==before_bad_pop || dut.u_mac_rx_a.drop_cnt!==16'd1 ||
       dut.u_mac_rx_b.drop_cnt!==16'd0)
      bad("bad-CRC minimum frame entered descriptor path or wrong drop count");
    if(dut.rx_free_map!==16'hFFC0) bad("bad-CRC frame leaked an RX block");
    host_write_cfg(16'h0008,32'h2000);
    for(i=0;i<WORDS;i=i+1) begin
      host_read(16'h8800+i,rd);
      last_txn=i+WORDS*((HOST_WRITES-1-i)/WORDS);
      if(rd!==signature(last_txn)) bad("PMEM final scoreboard mismatch");
    end
    host_read(16'h883F,rd);
    if(rd!==32'hC0FF_EE00) bad("changed pending-request bus made a ghost write");
    if(errors==0)
      $display("T17 MIN-FRAME STRESS PASS (IF_MODE=%0d pairs=%0d host_writes=%0d reads=%0d deferred=%0d max_wait=%0d crc_reject=1 free=FFC0)",
        IF_MODE,FRAME_PAIRS,writes,reads,deferred,max_wait);
    else
      $display("T17 MIN-FRAME STRESS FAIL (IF_MODE=%0d errors=%0d)",IF_MODE,errors);
    $finish;
  end
  initial begin
    #80_000_000;
    $display("T17 MIN-FRAME STRESS FAIL: timeout IF_MODE=%0d wr=%0d",IF_MODE,writes);
    $finish;
  end
endmodule

module tb_t17_min_frame_stress;  tb_t17_core #(.IF_MODE(0)) core(); endmodule
module tb_t17g_min_frame_stress; tb_t17_core #(.IF_MODE(1)) core(); endmodule
