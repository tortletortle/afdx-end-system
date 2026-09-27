// T08c/T08cg: executable HOST-01 contract under real dual-net RX PMEM load.
// The test is NOT a full RX delivery, T17 line-rate, or STA acceptance.
// Normal run: one outstanding PMEM write only.  The master may keep CS
// asserted until ACK or pulse it for one cycle: arbitration latches the
// address/data in either case, and each accepted write must commit once.
`timescale 1 ns / 1 ps
module tb_t08c_core #(parameter integer IF_MODE=0);
  reg clk=0, reset=1;
  always #4 clk=~clk;
  reg [7:0] rx_data=0,rx_data_b=0;
  reg rx_valid=0,rx_valid_b=0,rx_ready=0,rx_ready_b=0;
  reg host_cs=0,host_we=0;
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

  reg [31:0] vec[0:1144];
  integer errors=0,frames_a=0,frames_b=0,rx_pop_a=0,rx_pop_b=0;
  integer commit_count=0,write_count=0,delayed_count=0,held_count=0,pulse_count=0,max_wait=0;
  integer i,n,waitc;
  reg monitor_commits=0;
  reg [31:0] rd;
  function [31:0] signature;
    input integer k;
    begin signature = 32'hA36F_0000 ^ (32'h0101_0101*k) ^ (k<<19); end
  endfunction
  function [7:0] byte_at;
    input integer base,k;
    reg [31:0] w;
    begin
      w=vec[base+2+(k>>2)];
      case(k&3)
        0:byte_at=w[31:24];1:byte_at=w[23:16];
        2:byte_at=w[15:8];default:byte_at=w[7:0];
      endcase
    end
  endfunction
  task bad;
    input [8*112-1:0] reason;
    begin
      if(errors<12) $display("  [err] T08c%0d wr=%0d commit=%0d A/B=%0d/%0d: %0s",
                             IF_MODE,write_count,commit_count,rx_pop_a,rx_pop_b,reason);
      errors=errors+1;
    end
  endtask
  always @(posedge clk) if(!reset) begin
    if(dut.rx_ovf_a || dut.rx_ovf_b) bad("RX PMEM/descriptor queue overflow");
    if(dut.rx_desc_pop_a) rx_pop_a=rx_pop_a+1;
    if(dut.rx_desc_pop_b) rx_pop_b=rx_pop_b+1;
    if(monitor_commits && (dut.host_commit_now || dut.host_commit_pending))
      commit_count=commit_count+1;
  end
  task host_write;
    input [15:0] addr;
    input [31:0] data;
    begin
      @(negedge clk);host_cs=1;host_we=1;host_addr=addr;host_wdata=data;
      @(negedge clk);
      if(host_ack!==1'b1) bad("ordinary host write lost fixed ACK");
      host_cs=0;host_we=0;
    end
  endtask
  task host_read;
    input [15:0] addr;
    output [31:0] data;
    begin
      @(negedge clk);host_cs=1;host_we=0;host_addr=addr;
      @(negedge clk);
      if(host_ack!==1'b1) bad("host read lost fixed ACK");
      data=host_rdata;host_cs=0;
    end
  endtask
  task send_pair;
    integer b;
    begin
      for(b=0;b<79;b=b+1) begin
        @(negedge clk);
        rx_valid=1;rx_ready=1;rx_data=byte_at(37,b);
        rx_valid_b=1;rx_ready_b=1;rx_data_b=byte_at(37,b);
        if(IF_MODE==0) begin
          @(negedge clk);rx_valid=0;rx_valid_b=0;
          repeat(8) @(negedge clk);
        end
      end
      @(negedge clk);rx_ready=0;rx_valid=0;rx_ready_b=0;rx_valid_b=0;
      repeat(16) @(negedge clk);
    end
  endtask
  task congested_write;
    input integer k;
    reg [31:0] want;
    integer t;
    begin
      want=signature(k);
      // The real A/B ingress feeds two queued PMEM words into a *single* port.
      // Drive on its busy half-cycle; the first ACK is forbidden.
      wait(dut.rx_pmem_busy===1'b1);
      @(negedge clk);
      if(dut.rx_pmem_busy!==1'b1) bad("RX traffic not busy at selected host cycle");
      host_cs=1;host_we=1;host_addr=16'h8800+k;host_wdata=want;
      @(negedge clk);
      if(host_ack!==1'b0 || dut.host_pmem_pending!==1'b1)
        bad("early ACK or no outstanding write during RX priority");
      else delayed_count=delayed_count+1;
      if(k&1) held_count=held_count+1;
      else begin
        pulse_count=pulse_count+1;
        host_cs=0;host_we=0;
        // Once accepted, the latched transaction must not follow a changed bus.
        host_addr=16'h883F;host_wdata=~want;
      end
      t=0;
      while(host_ack!==1'b1 && t<64) begin @(negedge clk);t=t+1; end
      if(t>=64) bad("pending host write did not complete during dual RX traffic");
      if(t>max_wait) max_wait=t;
      if((k&1)!=0) begin host_cs=0;host_we=0;end
      write_count=write_count+1;
    end
  endtask
  initial begin
    $readmemh("vec/t08a_frames.hex",vec);
    if(vec[0]!==22 || vec[37][15:0]!==79 || vec[37][31:24]!==2)
      bad("independent model/zlib real frame vector missing or shifted");
    repeat(7) @(negedge clk);reset=0;
    waitc=0;
    while(dut.init_done!==1 && waitc<26000) begin @(negedge clk);waitc=waitc+1;end
    if(waitc>=26000) bad("INIT_DONE timeout");
    host_write(16'h0008,32'h2000);
    host_write(16'h883F,32'hC0FF_EE00); // idle-bus churn must not overwrite this
    // This intentionally tiny hash map is a TEST FIXTURE; HASH_IMAGE=1 is a
    // host assertion, not a hardware SHA/complete-image validation.
    host_write(16'h0078,32'h172D);
    host_write(16'h007C,32'hAB61);
    host_write(16'h42B2,32'h1010_0100);
    host_write(16'h0080,32'h1);
    host_write(16'h0008,32'h051E);
    monitor_commits=1;
    fork
      begin
        for(i=0;i<28;i=i+1) begin send_pair();frames_a=frames_a+1;frames_b=frames_b+1;end
      end
      begin
        for(n=0;n<40;n=n+1) congested_write(n);
      end
    join
    repeat(25) @(negedge clk);
    monitor_commits=0;
    if(write_count!=40 || delayed_count!=40 || held_count!=20 || pulse_count!=20 ||
       commit_count!=40 || rx_pop_a!=28 || rx_pop_b!=28 ||
       dut.rx_free_map!==16'hFFC0)
      bad("stalled/held/pulsed transaction count or RX free-map mismatch");
    host_write(16'h0008,32'h2000); // stop RX; PMEM read port A returns to host
    for(n=0;n<40;n=n+1) begin
      host_read(16'h8800+n,rd);
      if(rd!==signature(n)) bad("PMEM write dropped, repeated, shifted or data changed during stall");
    end
    host_read(16'h883F,rd); // changed idle bus never issued a request
    if(rd!==32'hC0FF_EE00) bad("idle-bus churn during pending request performed a ghost write");
    // Reset aborts an accepted-but-not-committed transaction.  This is a
    // synthetic *arbiter* stress case, not a claim of sustainable real RX load.
    host_write(16'h8850,32'hFEED_BA5E);
    @(negedge clk);force dut.rx_pmem_busy=1'b1;
    host_cs=1;host_we=1;host_addr=16'h8850;host_wdata=32'hBAD0_0001;
    @(negedge clk);
    if(host_ack!==0 || dut.host_pmem_pending!==1) bad("forced contention not pending before reset");
    host_cs=0;host_we=0;
    @(negedge clk);reset=1;
    repeat(6) @(negedge clk);
    release dut.rx_pmem_busy;
    reset=0;
    repeat(5) @(negedge clk);
    if(host_ack!==0 || dut.host_pmem_pending!==0 || dut.u_pmem.mem[13'h050]!==32'hFEED_BA5E)
      bad("reset leaked deferred ACK or committed stale pending write");
    waitc=0;
    while(dut.init_done!==1 && waitc<26000) begin @(negedge clk);waitc=waitc+1;end
    if(waitc>=26000) bad("repeat INIT_DONE timeout");
    host_write(16'h0008,32'h2000);
    host_read(16'h8850,rd);
    if(rd!==32'hFEED_BA5E) bad("reset cancelled write but corrupted existing PMEM word");
    host_read(16'h0080,rd);
    if(rd!==0) bad("hash commit survived reset");
    if(errors==0)
      $display("T08c HOST-ARBITRATION PASS (IF_MODE=%0d real_dual_frames=%0d host_writes=%0d deferred=%0d held=%0d pulse=%0d commits=%0d max_wait=%0d reset_abort=1)",
        IF_MODE,frames_a+frames_b,write_count,delayed_count,held_count,pulse_count,commit_count,max_wait);
    else $display("T08c HOST-ARBITRATION FAIL (IF_MODE=%0d errors=%0d)",IF_MODE,errors);
    $finish;
  end
  initial begin #4_000_000; $display("T08c HOST-ARBITRATION FAIL: timeout IF_MODE=%0d wr=%0d",IF_MODE,write_count);$finish;end
endmodule
module tb_t08c_host_arb; tb_t08c_core #(.IF_MODE(0)) core(); endmodule
module tb_t08cg_host_arb; tb_t08c_core #(.IF_MODE(1)) core(); endmodule
