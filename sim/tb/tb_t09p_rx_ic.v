// T09p: adversarial, cycle-by-cycle RX IC unit stress.  Both 4096-VL and
// 16-VL builds cover every PSN address, not just a handful of hot indices.
// This does NOT establish top-level FLT/lookup/RM or end-to-end RX behavior.
`timescale 1 ns / 1 ps
module tb_t09p_core #(parameter integer N=4096);
  localparam integer FRAMES=2*N+2048;
  localparam integer LIMIT=20*FRAMES+4096;
  localparam [2:0] R_OK=0, R_RESET=1, R_LOST_ONE=2,
                   R_FIRST_ANY=3, R_FIRST_FAIL=4, R_OUT_OF_ORDER=5, R_BAD_VL=6;
  reg clk=0, rst_sync=1;
  always #4 clk=~clk;
  reg init_done=0, init_we=0, ic_first_any=0;
  reg [12:0] init_addr=0;
  reg in_vld=0, out_ready=0;
  reg [162:0] in_desc=0;
  reg [11:0] in_vl=0;
  wire in_ready, out_vld, out_accept;
  wire [2:0] out_reason;
  wire [162:0] out_desc;
  wire [11:0] out_vl;
  reg dbg_en=0, dbg_wr=0, dbg_net=0;
  reg [11:0] dbg_vl=0;
  reg [7:0] dbg_psn=0;
  rx_ic #(.NUM_RX_VL(N)) dut (
    .clk(clk), .rst_sync(rst_sync), .init_done(init_done),
    .init_we(init_we), .init_addr(init_addr), .ic_first_any(ic_first_any),
    .in_vld(in_vld), .in_ready(in_ready), .in_desc(in_desc), .in_vl(in_vl),
    .out_vld(out_vld), .out_ready(out_ready), .out_accept(out_accept),
    .out_reason(out_reason), .out_desc(out_desc), .out_vl(out_vl),
    .dbg_en(dbg_en), .dbg_wr(dbg_wr), .dbg_vl(dbg_vl),
    .dbg_net(dbg_net), .dbg_psn(dbg_psn));

  // Oracle is deliberately expressed via modulo-255 sequence positions,
  // rather than copying the DUT's boundary-branch arithmetic.
  function [7:0] successor;
    input [7:0] prev;
    input integer delta;
    integer t;
    begin
      t=((prev==0 ? -1 : prev-1)+delta)%255;
      successor=t+1;
    end
  endfunction

  reg [7:0] model_psn [0:2*N-1];
  reg seen [0:2*N-1];
  reg [162:0] q_desc [0:FRAMES-1];
  reg [11:0] q_vl [0:FRAMES-1];
  reg q_accept [0:FRAMES-1];
  reg [2:0] q_reason [0:FRAMES-1];
  integer reason_bins [0:6];
  integer errors=0, sent=0, received=0, accepted=0, rejected=0;
  integer input_stalls=0, output_stalls=0, hold_run=0, hold_max=0;
  integer tick=0, candidate=-1;
  reg score_active=0, was_blocked=0, was_stalled=0;
  reg [162:0] blocked_desc, stalled_desc;
  reg [11:0] blocked_vl, stalled_vl;
  reg blocked_first, stalled_accept;
  reg [2:0] stalled_reason;
  reg [31:0] ready_rng=32'h9E37_79B9;
  integer slot;
  reg [7:0] previous, sn;
  reg expected_accept;
  reg [2:0] expected_reason;
  integer i, k, misses, waitc;

  task bad;
    input [8*96-1:0] why;
    begin
      if(errors<12) $display("  [err] N=%0d tick=%0d sent=%0d received=%0d: %0s",
                            N,tick,sent,received,why);
      errors=errors+1;
    end
  endtask

  // This monitor never peeks at DUT state to compute a verdict.  It samples
  // *actual* ready/valid handshakes, enqueues expected outputs, checks every
  // cycle of output stall, and audits the physical RAM at each retirement.
  always @(posedge clk) begin
    if(score_active && !rst_sync && !init_we && init_done) begin
      if(was_blocked && (in_vld !== 1'b1 || in_desc !== blocked_desc ||
                         in_vl !== blocked_vl || ic_first_any !== blocked_first))
        bad("producer changed an unaccepted descriptor");
      was_blocked=(in_vld && !in_ready);
      if(was_blocked) begin
        blocked_desc=in_desc; blocked_vl=in_vl; blocked_first=ic_first_any;
        input_stalls=input_stalls+1;
      end
      if(was_stalled && (out_vld !== 1'b1 || out_desc !== stalled_desc ||
                         out_vl !== stalled_vl || out_accept !== stalled_accept ||
                         out_reason !== stalled_reason))
        bad("output changed before handshake");
      was_stalled=(out_vld && !out_ready);
      if(was_stalled) begin
        stalled_desc=out_desc; stalled_vl=out_vl;
        stalled_accept=out_accept; stalled_reason=out_reason;
        output_stalls=output_stalls+1;
        hold_run=hold_run+1;
        if(hold_run>hold_max) hold_max=hold_run;
      end else hold_run=0;
      if(out_vld && in_ready) bad("accepted a second input with pending output");
      if(out_vld) begin
        if(received>=sent) bad("unexpected or duplicated output");
        else begin
          if(out_desc !== q_desc[received] || out_vl !== q_vl[received] ||
             out_accept !== q_accept[received] || out_reason !== q_reason[received])
            bad("output differs from ordered independent scoreboard");
          if(out_ready) begin
            if(q_vl[received]<N) begin
              slot=(q_desc[received][99] ? N : 0)+q_vl[received];
              if(dut.psn_mem[slot] !== model_psn[slot])
                bad("PSN memory differs on output retirement");
            end
            if(out_reason<=R_BAD_VL) reason_bins[out_reason]=reason_bins[out_reason]+1;
            received=received+1;
          end
        end
      end
      if(in_vld && in_ready) begin
        if(sent>=FRAMES) bad("more input handshakes than requested");
        else begin
          sn=in_desc[107:100];
          slot=(in_desc[99] ? N : 0)+in_vl;
          expected_accept=0;
          expected_reason=R_OUT_OF_ORDER;
          if(in_vl>=N) expected_reason=R_BAD_VL;
          else begin
            previous=model_psn[slot];
            seen[slot]=1;
            if(sn==0) begin
              expected_accept=1; expected_reason=R_RESET;
            end else if(previous==0) begin
              if(sn==1) begin expected_accept=1;expected_reason=R_OK;end
              else if(ic_first_any) begin expected_accept=1;expected_reason=R_FIRST_ANY;end
              else expected_reason=R_FIRST_FAIL;
            end else if(sn==successor(previous,1)) begin
              expected_accept=1; expected_reason=R_OK;
            end else if(sn==successor(previous,2)) begin
              expected_accept=1; expected_reason=R_LOST_ONE;
            end
            if(expected_accept) model_psn[slot]=sn;
          end
          q_desc[sent]=in_desc; q_vl[sent]=in_vl;
          q_accept[sent]=expected_accept; q_reason[sent]=expected_reason;
          if(expected_accept) accepted=accepted+1; else rejected=rejected+1;
          sent=sent+1;
        end
      end
    end else begin
      was_blocked=0; was_stalled=0; hold_run=0;
    end
  end

  // Reproducible producer, independent of the DUT's accept/reject decision.
  // The first 2*N frames dirty every single A/B PSN address.  Then switch to
  // hot/cold collisions, adjacent writes, illegal indices and modulo edges.
  task prepare;
    input integer id;
    integer t, vl, base;
    reg net_id, first_mode;
    reg [7:0] prev, sn_new;
    begin
      if(id<2*N) begin
        vl=id/2; net_id=(id%2)!=0; first_mode=1;
        sn_new=(vl%255)+1;
      end else begin
        t=id-2*N;
        net_id=((t ^ (t>>3)) & 1)!=0;
        first_mode=(t%3)==0;
        if(t<7) begin vl=0;net_id=0;end
        else if(N==16 && (t==7 || t%41==0)) vl=N;
        else if(t%23==0) vl=N-1;
        else if(t%11==0) vl=0;
        else if(t%11==1) vl=1;
        else if(t%11==2) vl=N/2;
        else vl=(t*2677+13)%N;
        base=(net_id ? N : 0)+vl;
        prev=(vl<N) ? model_psn[base] : 8'd0;
        if(t==0 || t==5) sn_new=0;
        else if(t==1) begin sn_new=2; first_mode=0;end
        else if(t==2) begin sn_new=1; first_mode=0;end
        else if(t==3 || t==4) sn_new=3;
        else if(t==6) begin sn_new=200;first_mode=1;end
        else case(t%11)
          0: sn_new=0;
          1,2: sn_new=(prev==0) ? 8'd1 : successor(prev,1);
          3,4: sn_new=(prev==0) ? 8'd2 : successor(prev,2);
          5: sn_new=prev;
          6: sn_new=(prev==0) ? 8'd3 : successor(prev,3);
          7: sn_new=8'd255;
          8: sn_new=8'd1;
          9: sn_new=8'd254;
          default: sn_new=(t*73+19)&255;
        endcase
      end
      ic_first_any=first_mode;
      in_vl=vl;
      // Every descriptor has an independent identity.  Network is at bit 99.
      in_desc={id[3:0],11'd79,id[23:0],vl[15:0],sn_new,net_id,
               3'd2,(32'hA5A5_0000^id),32'h0A02_0304,id[15:0],16'h5566};
    end
  endtask

  task sweep_all;
    integer a;
    begin
      init_done=0;
      for(a=0;a<2*N;a=a+1) begin
        @(negedge clk);init_we=1;init_addr=a;
        #1;
        if(in_ready!==1'b0) bad("input ready during initialization sweep");
      end
      @(negedge clk);init_we=0;init_done=1;
      for(a=0;a<2*N;a=a+1)
        if(dut.psn_mem[a] !== 8'd0) bad("sweep left nonzero or unknown PSN");
    end
  endtask

  task debug_write;
    input [11:0] vl;
    input net_id;
    input [7:0] value;
    input enabled;
    begin
      @(negedge clk);dbg_vl=vl;dbg_net=net_id;dbg_psn=value;
      dbg_en=enabled;dbg_wr=1;
      #1;
      if(enabled && in_ready!==1'b0) bad("input ready during debug write");
      @(posedge clk);
      @(negedge clk);dbg_en=0;dbg_wr=0;
    end
  endtask

  initial begin
    for(i=0;i<2*N;i=i+1) begin model_psn[i]=0;seen[i]=0;end
    for(i=0;i<7;i=i+1) reason_bins[i]=0;
    repeat(3) @(negedge clk);
    rst_sync=0;
    in_vld=1; // Must not slip through the initial sweep.
    sweep_all;
    in_vld=0;
    if(out_vld!==1'b0) bad("sweep emitted an output");

    // Keep a VALID asserted every cycle until consumed.  Ready is a seeded
    // burst-pattern with long 51-cycle stalls plus randomized open windows.
    score_active=1;
    tick=0;
    while(received<FRAMES && tick<LIMIT) begin
      @(negedge clk);
      ready_rng={ready_rng[30:0],ready_rng[31]^ready_rng[21]^ready_rng[1]^ready_rng[0]};
      out_ready=((tick%113)>=51) && (ready_rng[0] || ready_rng[2]);
      if(sent<FRAMES) begin
        if(candidate!=sent) begin prepare(sent);candidate=sent;end
        in_vld=1;
      end else in_vld=0;
      tick=tick+1;
    end
    @(negedge clk);in_vld=0;out_ready=0;score_active=0;
    if(sent!=FRAMES || received!=FRAMES) bad("deadlock, loss or unretired output");
    if(accepted<2*N+10 || rejected<100) bad("insufficient accepted/rejected traffic");
    if(input_stalls<FRAMES*2 || output_stalls<100 || hold_max<30)
      bad("backpressure did not actually stress the interface");
    for(i=0;i<2*N;i=i+1) begin
      if(!seen[i]) bad("PSN address never touched by input handshake");
      if(dut.psn_mem[i] !== model_psn[i]) bad("final PSN RAM mismatch");
    end
    for(i=0;i<6;i=i+1) if(reason_bins[i]==0) bad("missing an IC verdict class");
    if(N==16 && reason_bins[R_BAD_VL]==0) bad("invalid-VL path was not hit");

    // Probe write masks and aliasing: an invalid VL in A bank would otherwise
    // alias B's index 0 in the reduced-depth instance.
    debug_write(12'd0,1'b0,8'h31,1'b1);
    if(dut.psn_mem[0]!==8'h31) bad("debug valid write failed");
    debug_write(12'd0,1'b0,8'hA5,1'b0);
    if(dut.psn_mem[0]!==8'h31) bad("disabled debug write corrupted PSN");
    if(N==16) begin
      debug_write(12'd0,1'b1,8'h42,1'b1);
      debug_write(12'd16,1'b0,8'hD7,1'b1);
      if(dut.psn_mem[N]!==8'h42) bad("invalid debug VL aliased other bank");
    end

    // A reset between accepted input and commit must cancel the transaction;
    // when reset is asserted with INIT_DONE still high, READY must be low.
    @(negedge clk);in_vl=0;in_desc={55'd0,8'd0,100'd0};in_vld=1;
    #1;if(in_ready!==1'b1) bad("no input ready before abort test");
    @(posedge clk);
    @(negedge clk);in_vld=0;rst_sync=1;
    @(posedge clk);
    @(negedge clk);#1;
    if(in_ready!==1'b0) bad("READY high during synchronous reset");
    if(out_vld!==1'b0) bad("aborted frame produced output");
    if(dut.psn_mem[0]!==8'h31) bad("reset-aborted frame wrote PSN");
    init_done=0;rst_sync=0;
    sweep_all; // a restart must erase *all* PSN entries, not just the hot VL

    // An initialization restart also aborts a previously valid but unconsumed
    // output.  A stale descriptor must never reappear after sweep.
    @(negedge clk);in_vl=0;in_desc={55'd0,8'd1,100'd0};in_vld=1;out_ready=0;
    #1;if(in_ready!==1'b1) bad("no input ready after restart");
    @(posedge clk);
    @(negedge clk);in_vld=0;
    waitc=0;
    while(out_vld!==1'b1 && waitc<8) begin @(negedge clk);waitc=waitc+1;end
    if(out_vld!==1'b1 || dut.psn_mem[0]!==8'd1)
      bad("pending output/write not established before restart");
    init_done=0;init_we=1;init_addr=0;
    #1;if(in_ready!==1'b0) bad("READY high during restart");
    @(posedge clk);
    @(negedge clk);
    if(out_vld!==1'b0) bad("restart did not cancel pending output");
    for(k=1;k<2*N;k=k+1) begin @(negedge clk);init_addr=k;end
    @(negedge clk);init_we=0;init_done=1;
    for(k=0;k<2*N;k=k+1)
      if(dut.psn_mem[k] !== 8'd0) bad("restart sweep did not clear full table");
    repeat(8) @(negedge clk);
    if(out_vld!==1'b0) bad("stale output leaked after restart");

    if(errors==0)
      $display("T09p RX-IC PRESSURE PASS (N=%0d, frames=%0d, covered=%0d/%0d, accept=%0d reject=%0d, in_stall=%0d out_stall=%0d max_hold=%0d, bins=%0d/%0d/%0d/%0d/%0d/%0d/%0d, seed=9E3779B9)",
        N,FRAMES,2*N,2*N,accepted,rejected,input_stalls,output_stalls,hold_max,
        reason_bins[0],reason_bins[1],reason_bins[2],reason_bins[3],
        reason_bins[4],reason_bins[5],reason_bins[6]);
    else $display("T09p RX-IC PRESSURE FAIL (N=%0d errors=%0d)",N,errors);
    $finish;
  end
  initial begin #5_000_000; $display("T09p RX-IC PRESSURE FAIL: timeout N=%0d",N);$finish;end
endmodule
module tb_t09p_rx_ic;  tb_t09p_core #(.N(4096)) core(); endmodule
module tb_t09ps_rx_ic; tb_t09p_core #(.N(16)) core(); endmodule
