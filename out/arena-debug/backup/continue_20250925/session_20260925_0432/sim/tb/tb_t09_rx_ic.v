// T09: full-depth and reduced-parameter RX IC checks against an independent
// PSN reference model.  This is a unit test; no claim of full RX/T08/T22.
`timescale 1 ns / 1 ps
module tb_t09_core #(parameter integer N = 4096);
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

  localparam [2:0] R_OK=3'd0, R_RESET=3'd1, R_LOST_ONE=3'd2,
                   R_FIRST_ANY=3'd3, R_FIRST_FAIL=3'd4,
                   R_OUT_OF_ORDER=3'd5, R_BAD_VL=3'd6;
  reg [7:0] model_psn [0:2*N-1];
  integer err=0, frames=0, accepted=0, rejected=0;
  integer i, idx, vl_pick, j, gold_count;
  reg net_pick;
  reg [7:0] sn_pick, old_sn;
  reg [31:0] rnd=32'h8a47_05d3;
  reg [31:0] py_cases [0:5632]; // generated from sw/golden/afdx_model.py
  reg observed_accept;
  reg [2:0] observed_reason;

  task seed_psn;
    input [11:0] vl;
    input net_id;
    input [7:0] val;
    input enabled;
    integer slot;
    begin
      slot = (net_id ? N : 0) + vl;
      @(negedge clk);
      dbg_en = enabled; dbg_wr=1; dbg_net=net_id; dbg_vl=vl; dbg_psn=val;
      #1; // let the combinational in_ready interlock settle
      if(enabled && in_ready !== 1'b0) begin
        $display("  [err] debug write did not stall input"); err=err+1;
      end
      @(posedge clk);
      if(enabled && vl < N) model_psn[slot]=val;
      @(negedge clk);
      dbg_en=0; dbg_wr=0;
    end
  endtask

  task send_frame;
    input [11:0] vl;
    input net_id;
    input [7:0] sn;
    input integer hold_cycles;
    integer slot, waited, h;
    reg [7:0] prev, one, two;
    reg want_accept;
    reg [2:0] want_reason;
    reg [162:0] sample;
    begin
      slot = (net_id ? N : 0) + vl;
      prev = (vl < N) ? model_psn[slot] : 8'd0;
      one = (prev==8'd255) ? 8'd1 : prev+8'd1;
      two = (prev>=8'd254) ? prev-8'd253 : prev+8'd2;
      want_accept=0;want_reason=R_OUT_OF_ORDER;
      if(vl>=N) want_reason=R_BAD_VL;
      else if(sn==0) begin want_accept=1;want_reason=R_RESET;end
      else if(prev==0) begin
        want_accept=(sn==1) || ic_first_any;
        if(sn==1) want_reason=R_OK;
        else if(ic_first_any) want_reason=R_FIRST_ANY;
        else want_reason=R_FIRST_FAIL;
      end else if(sn==one) begin want_accept=1;want_reason=R_OK;end
      else if(sn==two) begin want_accept=1;want_reason=R_LOST_ONE;end
      // Exercise byte-exact descriptor forwarding; metadata differs each call.
      sample={frames[3:0],11'd79,frames[23:0],16'h0100+vl,sn,net_id,
              3'd2,32'h0a01_0203,32'h0a02_0304,16'h3344,16'h5566};
      @(negedge clk);
      in_vl=vl; in_desc=sample; in_vld=1;
      waited=0;
      while(in_ready !== 1'b1 && waited<12) begin @(negedge clk);waited=waited+1;end
      if(waited>=12) begin
        $display("  [err] input timeout VL=%0d net=%0d",vl,net_id);err=err+1;
        in_vld=0;
      end else begin
        @(posedge clk);
        if(want_accept) begin model_psn[slot]=sn;accepted=accepted+1;end
        else rejected=rejected+1;
        frames=frames+1;
        @(negedge clk);in_vld=0;
        waited=0;
        while(out_vld !== 1'b1 && waited<12) begin @(negedge clk);waited=waited+1;end
        if(waited>=12) begin
          $display("  [err] output timeout frame=%0d",frames);err=err+1;
        end else begin
          observed_accept=out_accept;
          observed_reason=out_reason;
          if(out_desc !== sample || out_vl !== vl ||
             out_accept !== want_accept || out_reason !== want_reason) begin
            if(err<12) $display("  [err] #%0d VL=%0d net=%0d SN=%0d PSN=%0d got=%b/%0d expected=%b/%0d desc=%b",
              frames,vl,net_id,sn,prev,out_accept,out_reason,want_accept,want_reason,out_desc===sample);
            err=err+1;
          end
          for(h=0;h<hold_cycles;h=h+1) begin
            @(negedge clk);
            if(out_vld !== 1'b1 || in_ready !== 1'b0 ||
               out_desc !== sample || out_vl !== vl ||
               out_accept !== want_accept || out_reason !== want_reason) begin
              $display("  [err] output changed under backpressure");err=err+1;
            end
          end
          out_ready=1;
          @(posedge clk);
          @(negedge clk);
          out_ready=0;
          if(out_vld !== 1'b0 || in_ready !== 1'b1) begin
            $display("  [err] output not consumed / input not ready");err=err+1;
          end
        end
      end
    end
  endtask

  initial begin
    repeat(3) @(negedge clk);
    rst_sync=0;
    if(in_ready !== 1'b0) begin $display("  [err] accepted before INIT_DONE");err=err+1;end
    for(i=0;i<2*N;i=i+1) begin
      @(negedge clk);init_we=1;init_addr=i;model_psn[i]=0;
      if(in_ready !== 1'b0) begin $display("  [err] ready during sweep");err=err+1;end
    end
    @(negedge clk);init_we=0;init_done=1;
    send_frame(12'd0,0,8'd2,0); // strict first frame rejects SN!=1
    send_frame(12'd0,0,8'd0,1); // SN=0 resets (and is accepted)
    send_frame(12'd0,0,8'd2,0);
    send_frame(12'd0,0,8'd1,2);
    send_frame(12'd0,0,8'd3,0); // lost exactly one
    send_frame(12'd0,0,8'd3,1); // duplicate: no PSN write
    send_frame(12'd0,0,8'd4,0);
    send_frame(12'd0,0,8'd7,0); // skip >=2: no PSN write
    send_frame(12'd0,0,8'd5,2);
    send_frame(12'd0,1,8'd2,0); // independent B PSN
    send_frame(12'd0,1,8'd1,0);
    send_frame(12'd0,1,8'd3,0);
    ic_first_any=1;
    send_frame(12'd1,0,8'd200,3);
    send_frame(12'd1,0,8'd202,0);
    send_frame(12'd1,1,8'd199,0);
    ic_first_any=0;
    send_frame(12'd2,0,8'd200,0);
    seed_psn(12'd3,0,8'd254,0); // DEBUG_EN=0: no mutation
    send_frame(12'd3,0,8'd1,0);
    seed_psn(12'd3,0,8'd254,1);
    send_frame(12'd3,0,8'd255,0);
    send_frame(12'd3,0,8'd1,0); // wrap 255 -> 1, never 0
    seed_psn(12'd3,0,8'd255,1);
    send_frame(12'd3,0,8'd2,0); // wrap and lose exactly one
    send_frame(12'd3,0,8'd0,0);
    send_frame(12'd3,0,8'd1,0);
    ic_first_any=1;
    fork
      send_frame(12'd5,0,8'd9,2); // snapshot IC_FIRST_ANY when accepting
      begin
        wait(in_vld && in_ready);
        @(posedge clk);
        @(negedge clk);ic_first_any=0; // change live config before compare
      end
    join
    send_frame(N-1,1,8'd1,0);   // upper physical address in B bank
    send_frame(N-1,0,8'd1,0);   // adjacent A bank stays independent
    if(N==16) begin
      send_frame(12'd16,0,8'd0,0); // out-of-range index must reject, even SN=0
      send_frame(12'd16,1,8'd1,0);
    end
    // Deterministic stress: legal next/skip, reset, duplicate and random SN.
    for(i=0;i<350;i=i+1) begin
      rnd={rnd[30:0],rnd[31]^rnd[21]^rnd[1]^rnd[0]};
      vl_pick=rnd[7:3] % 8;
      if(i%29==0) vl_pick=N-1;
      if(N==16 && i%23==0) vl_pick=N;
      net_pick=rnd[8];
      idx=(net_pick ? N : 0)+vl_pick;
      old_sn=(vl_pick<N) ? model_psn[idx] : 8'd0;
      ic_first_any=(i%5==0);
      case(rnd[11:9])
        3'd0: sn_pick=8'd0;
        3'd1,3'd2: sn_pick=(old_sn==8'd255) ? 8'd1 : old_sn+8'd1;
        3'd3: sn_pick=(old_sn>=8'd254) ? old_sn-8'd253 : old_sn+8'd2;
        3'd4: sn_pick=old_sn;
        3'd5: sn_pick=old_sn+8'd5;
        default: sn_pick=rnd[23:16];
      endcase
      send_frame(vl_pick[11:0],net_pick,sn_pick,rnd[2:1]);
    end
    // Independent Python oracle: debug-seed known PSN, then check actual RTL
    // verdict AND the real memory writeback for boundary and seeded-random cases.
    $readmemh("vec/t09_ic_cases.hex",py_cases);
    gold_count=py_cases[0];
    if(gold_count !== 32'd5632) begin
      $display("  [err] Python vector count missing/mismatch: %0d",gold_count);err=err+1;
    end else begin
      for(j=1;j<=gold_count;j=j+1) begin
        seed_psn(12'd4,1,py_cases[j][28:21],1);
        ic_first_any=py_cases[j][12];
        send_frame(12'd4,1,py_cases[j][20:13],0);
        if(observed_accept !== py_cases[j][11] ||
           observed_reason !== py_cases[j][10:8] ||
           dut.psn_mem[N+4] !== py_cases[j][7:0]) begin
          if(err<12) $display("  [err] Python oracle case %0d word=%h got=%b/%0d PSN=%h",
            j,py_cases[j],observed_accept,observed_reason,dut.psn_mem[N+4]);
          err=err+1;
        end
      end
    end
    if(accepted<30 || rejected<30) begin
      $display("  [err] insufficient accept/drop coverage %0d/%0d",accepted,rejected);err=err+1;
    end
    if(err==0) $display("T09 RX-IC PASS (N=%0d, %0d descriptors incl 5632 Python golden; accept=%0d reject=%0d; strict/first-any/reset/loss/wrap/banks/backpressure)",N,frames,accepted,rejected);
    else $display("T09 RX-IC FAIL: N=%0d errors=%0d",N,err);
    $finish;
  end
  initial begin #1_000_000; $display("T09 RX-IC FAIL: timeout N=%0d",N);$finish;end
endmodule
module tb_t09_rx_ic;  tb_t09_core #(.N(4096)) core(); endmodule
module tb_t09s_rx_ic; tb_t09_core #(.N(16)) core(); endmodule
