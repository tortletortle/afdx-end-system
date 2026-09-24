// T12c/T12r/T12s: standalone §7.9 dual-table lookup, not a top-level RX test.
// Full cases each make 100,000 ready/valid lookup attempts after loading and
// reading back every image word; small case forces all four ways of one pair.
`timescale 1 ns / 1 ps
module tb_t12_core #(
  parameter integer N=4096,
  parameter integer BUCKETS=2048,
  parameter integer CASE_NO=0,
  parameter integer LOOKUPS=100000
);
  localparam integer WORDS=4*BUCKETS;
  localparam integer LIMIT=20*LOOKUPS+10000;
  reg clk=0, rst_sync=1;
  always #4 clk=~clk;
  reg init_done=0, init_we=0, cfg_mode=0, rx_enable=0;
  reg [12:0] init_addr=0,cfg_addr=0;
  reg [15:0] seed0=0,seed1=0;
  reg cfg_wr=0,cfg_rd=0,in_vld=0,out_ready=0;
  reg [31:0] cfg_wdata=0;
  reg [162:0] in_desc=0;
  wire cfg_ready,cfg_rvalid,in_ready,out_vld,out_hit;
  wire [31:0] cfg_rdata;
  wire [11:0] out_vl;
  wire [162:0] out_desc;
  rx_vl_lookup #(.NUM_RX_VL(N),.HASH_BUCKETS(BUCKETS)) dut (
    .clk(clk),.rst_sync(rst_sync),.init_done(init_done),
    .init_we(init_we),.init_addr(init_addr),
    .cfg_mode(cfg_mode),.rx_enable(rx_enable),.seed0(seed0),.seed1(seed1),
    .cfg_wr(cfg_wr),.cfg_rd(cfg_rd),.cfg_addr(cfg_addr),.cfg_wdata(cfg_wdata),
    .cfg_ready(cfg_ready),.cfg_rvalid(cfg_rvalid),.cfg_rdata(cfg_rdata),
    .in_vld(in_vld),.in_ready(in_ready),.in_desc(in_desc),
    .out_vld(out_vld),.out_ready(out_ready),.out_hit(out_hit),
    .out_vl(out_vl),.out_desc(out_desc));
  reg [31:0] image [0:WORDS-1];
  reg [31:0] meta [0:3];
  reg [31:0] keys [0:N];  // [0]=count, entries [1..N]={4'b0,vlid,idx}
  reg ref_valid [0:65535];
  reg [11:0] ref_idx [0:65535];
  reg seen [0:N-1];
  integer way_of [0:N-1];
  reg [3:0] way_covered=0;
  integer errors=0, sent=0, retired=0, hit_count=0, miss_count=0;
  integer in_stalls=0, out_stalls=0, max_hold=0, hold_run=0;
  integer cycle_count=0, take_cycle=0, tick=0, candidate=-1;
  integer i,j,k,waitc,good_slot=-1, seen_count=0;
  reg [15:0] key_pick=0;
  reg [31:0] prng=32'hA664_12C5;
  reg score_on=0,pending=0,already_out=0,prior_blocked=0,prior_stalled=0;
  reg [162:0] expect_desc, blocked_desc, stalled_desc;
  reg expect_hit,stalled_hit;
  reg [11:0] expect_idx,stalled_idx;

  task bad;
    input [8*110-1:0] why;
    begin
      if(errors<12) $display("  [err] T12 case=%0d tick=%0d sent=%0d out=%0d: %0s",
                            CASE_NO,tick,sent,retired,why);
      errors=errors+1;
    end
  endtask

  // One scoreboard entry suffices for this serialized lookup. It is populated
  // only at *actual* input handshakes from independent key->index vectors,
  // not from the DUT image, hash, or internal state.
  always @(posedge clk) begin
    cycle_count=cycle_count+1;
    if(score_on && !rst_sync && !init_we) begin
      if(prior_blocked && (in_vld!==1'b1 || in_desc!==blocked_desc))
        bad("producer changed input before acceptance");
      prior_blocked=(in_vld && !in_ready);
      if(prior_blocked) begin
        blocked_desc=in_desc;
        in_stalls=in_stalls+1;
      end
      if(prior_stalled && (out_vld!==1'b1 || out_desc!==stalled_desc ||
                           out_hit!==stalled_hit || out_vl!==stalled_idx))
        bad("output changed while consumer stalled");
      prior_stalled=(out_vld && !out_ready);
      if(prior_stalled) begin
        stalled_desc=out_desc;stalled_hit=out_hit;stalled_idx=out_vl;
        out_stalls=out_stalls+1;
        hold_run=hold_run+1;
        if(hold_run>max_hold) max_hold=hold_run;
      end else hold_run=0;
      if(out_vld && in_ready) bad("second input while prior output pending");
      if(out_vld) begin
        if(!pending) bad("duplicate or unsolicited output");
        else begin
          if(!already_out && cycle_count-take_cycle!=2)
            bad("lookup did not produce result after fixed two clock edges");
          already_out=1;
          if(out_desc!==expect_desc || out_hit!==expect_hit || out_vl!==expect_idx)
            bad("output differs from independent key->index scoreboard");
          if(out_ready) begin pending=0;retired=retired+1;end
        end
      end
      if(in_vld && in_ready) begin
        if(pending) bad("input overwrote unconsumed lookup");
        key_pick=in_desc[123:108];
        expect_desc=in_desc;
        expect_hit=ref_valid[key_pick];
        expect_idx=expect_hit ? ref_idx[key_pick] : 12'd0;
        if(expect_hit) begin
          seen[expect_idx]=1;
          if(way_of[expect_idx]>=0) way_covered[way_of[expect_idx]]=1;
          hit_count=hit_count+1;
        end else miss_count=miss_count+1;
        take_cycle=cycle_count;
        already_out=0;
        pending=1;
        sent=sent+1;
      end
    end else begin
      prior_blocked=0;prior_stalled=0;hold_run=0;
    end
  end

  task sweep_all;
    integer a;
    begin
      init_done=0;
      for(a=0;a<WORDS;a=a+1) begin
        @(negedge clk);init_we=1;init_addr=a;
        #1;
        if(in_ready!==1'b0 || cfg_ready!==1'b0)
          bad("READY active during hash sweep");
      end
      @(negedge clk);init_we=0;init_done=1;
      for(a=0;a<BUCKETS;a=a+1)
        if(dut.table0way0[a]!==32'd0 || dut.table0way1[a]!==32'd0 ||
           dut.table1way0[a]!==32'd0 || dut.table1way1[a]!==32'd0)
          bad("sweep did not clear all four hash banks");
    end
  endtask

  task config_word;
    input integer addr;
    input [31:0] data;
    begin
      @(negedge clk);cfg_addr=addr;cfg_wdata=data;cfg_wr=1;
      #1;
      if(cfg_ready!==1'b1) bad("valid config write was not ready");
      @(posedge clk);
      @(negedge clk);cfg_wr=0;
    end
  endtask

  task manual_lookup;
    input [15:0] key;
    input should_hit;
    input [11:0] should_idx;
    integer count;
    reg [162:0] sample;
    begin
      sample={4'hA,11'd79,24'h123456,key,8'h33,1'b1,3'd2,
              32'h11003344,32'h55667788,16'hBEEF,16'h1234};
      @(negedge clk);in_vld=1;in_desc=sample;out_ready=0;
      #1;
      if(in_ready!==1'b1) bad("manual probe input not ready");
      @(posedge clk);
      @(negedge clk);in_vld=0;
      count=0;
      while(out_vld!==1'b1 && count<6) begin @(negedge clk);count=count+1;end
      if(out_vld!==1'b1 || out_desc!==sample ||
         out_hit!==should_hit || out_vl!==should_idx)
        bad("manual probe disagrees after reset/reconfiguration");
      out_ready=1;
      @(posedge clk);
      @(negedge clk);out_ready=0;
    end
  endtask

  // Generate one new descriptor per prior input handshake; hold it stable
  // across stalls. ID 0..N-1 exercises EVERY configured key at least once.
  task prepare;
    input integer id;
    integer pick;
    reg [15:0] key;
    begin
      if(id<N) key=keys[id+1][27:12];
      else if(id%5<3) begin
        if(id%31==0) pick=(id/31)%4;
        else pick=(id*73+(id/17))%N;
        key=keys[pick+1][27:12];
      end else begin
        key=(id*193+((id>>2)*71)+16'h9105)&65535;
        while(ref_valid[key]) key=key+16'd1;
      end
      in_desc={id[3:0],11'd79,id[23:0],key,id[7:0],id[0],
               3'd2,(32'hCAFE0000^id),32'h04030201,id[15:0],16'h5533};
    end
  endtask

  initial begin
    for(i=0;i<65536;i=i+1) begin ref_valid[i]=0;ref_idx[i]=0;end
    for(i=0;i<N;i=i+1) begin seen[i]=0;way_of[i]=-1;end
    if(CASE_NO==0) begin
      $readmemh("vec/t12_contig.img.hex",image);
      $readmemh("vec/t12_contig.keys.hex",keys);
      $readmemh("vec/t12_contig.meta.hex",meta);
    end else if(CASE_NO==1) begin
      $readmemh("vec/t12_random.img.hex",image);
      $readmemh("vec/t12_random.keys.hex",keys);
      $readmemh("vec/t12_random.meta.hex",meta);
    end else if(CASE_NO==2) begin
      $readmemh("vec/t12_small.img.hex",image);
      $readmemh("vec/t12_small.keys.hex",keys);
      $readmemh("vec/t12_small.meta.hex",meta);
    end else begin
      $readmemh("vec/t12_rehash.img.hex",image);
      $readmemh("vec/t12_rehash.keys.hex",keys);
      $readmemh("vec/t12_rehash.meta.hex",meta);
    end
    if(meta[2]!==N || meta[3]!==BUCKETS || keys[0]!==N) begin
      bad("generated image/key/meta length mismatch");
      $display("T12 LOOKUP FAIL (case=%0d image mismatch)",CASE_NO);$finish;
    end
    seed0=meta[0][15:0];seed1=meta[1][15:0];
    for(i=1;i<=N;i=i+1) begin
      if(ref_valid[keys[i][27:12]] || keys[i][11:0]>=N)
        bad("duplicate or invalid independent source key");
      ref_valid[keys[i][27:12]]=1;
      ref_idx[keys[i][27:12]]=keys[i][11:0];
    end
    for(i=0;i<WORDS;i=i+1) if(image[i][28]) begin
      if(good_slot<0) good_slot=i;
      if(image[i][11:0]<N && ref_valid[image[i][27:12]] &&
         ref_idx[image[i][27:12]]==image[i][11:0])
        way_of[image[i][11:0]]= (i/(2*BUCKETS))*2 + (i&1);
    end
    if(good_slot<0) bad("image contains no valid VL");

    repeat(3) @(negedge clk);
    rst_sync=0;in_vld=1; // input must be refused before/during INIT_DONE sweep
    sweep_all;
    in_vld=0;
    cfg_wr=1;cfg_wdata=32'h10001234;cfg_addr=0;
    #1;if(cfg_ready!==0) bad("config accepted without CFG_MODE");
    @(posedge clk);
    @(negedge clk);cfg_wr=0;
    if(dut.table0way0[0]!==32'd0) bad("unqualified config write changed RAM");

    cfg_mode=1;
    for(i=0;i<WORDS;i=i+1) begin
      @(negedge clk);cfg_wr=1;cfg_addr=i;cfg_wdata=image[i];
      #1;
      if(cfg_ready!==1'b1 || in_ready!==1'b0)
        bad("config load not ready or RX ready during CFG_MODE");
    end
    @(negedge clk);cfg_wr=0;
    // Neither a simultaneous read+write nor a RUN write may pass the frontdoor.
    cfg_rd=1;cfg_wr=1;cfg_addr=good_slot;cfg_wdata=0;
    #1;if(cfg_ready!==0) bad("simultaneous config read/write accepted");
    @(posedge clk);
    @(negedge clk);cfg_rd=0;cfg_wr=0;
    // Read back all words through the same synchronous RAM read port.
    cfg_rd=1;
    for(i=0;i<WORDS;i=i+1) begin
      cfg_addr=i;
      #1;if(cfg_ready!==1'b1) bad("host-style read rejected");
      @(posedge clk);
      @(negedge clk);
      if(cfg_rvalid!==1'b1 || cfg_rdata!==image[i])
        bad("frontdoor hash word readback mismatch");
    end
    cfg_rd=0;
    if(BUCKETS==32) begin
      cfg_rd=1;cfg_addr=13'd8191;
      #1;if(cfg_ready!==1'b0) bad("out-of-range config address aliased bank");
      cfg_rd=0;
    end
    cfg_mode=0;rx_enable=1;
    #1;if(in_ready!==1'b1) bad("input not ready after image load");
    // No reconfiguration may write while RUN is enabled.
    cfg_wr=1;cfg_addr=good_slot;cfg_wdata=32'hDEADBEEF;
    #1;if(cfg_ready!==1'b0) bad("CFG_MODE guard failed in RUN");
    @(posedge clk);
    @(negedge clk);cfg_wr=0;

    score_on=1;
    tick=0;
    while(retired<LOOKUPS && tick<LIMIT) begin
      @(negedge clk);
      prng={prng[30:0],prng[31]^prng[21]^prng[1]^prng[0]};
      out_ready=((tick%127)>=60) && (prng[0] || prng[2]);
      if(sent<LOOKUPS) begin
        if(candidate!=sent) begin prepare(sent);candidate=sent;end
        in_vld=1;
      end else in_vld=0;
      tick=tick+1;
    end
    @(negedge clk);in_vld=0;out_ready=0;score_on=0;
    if(sent!=LOOKUPS || retired!=LOOKUPS || pending)
      bad("lost/duplicated frames or lookup did not drain");
    if(hit_count<LOOKUPS/2 || miss_count<LOOKUPS/5 ||
       in_stalls<LOOKUPS || out_stalls<LOOKUPS/5 || max_hold<35)
      bad("stress never exercised hit/miss or long backpressure");
    for(i=0;i<N;i=i+1)
      if(!seen[i]) bad("some configured index was never looked up");
      else seen_count=seen_count+1;
    if(seen_count!=N || way_covered!==4'b1111)
      bad("coverage did not reach every index and all four RAM ways");

    // Reset *in COMPARE*, with an outstanding synchronous RAM read, must
    // cancel the transaction and mask READY even while INIT_DONE is still 1.
    @(negedge clk);in_vld=1;in_desc=163'h12AA34BC;out_ready=0;
    #1;if(in_ready!==1'b1) bad("reset-inflight setup was not accepted");
    @(posedge clk);
    @(negedge clk);in_vld=0;rst_sync=1;
    #1;if(in_ready!==1'b0) bad("READY high during reset");
    @(posedge clk);
    @(negedge clk);rst_sync=0;rx_enable=0;cfg_mode=0;init_done=0;
    if(out_vld!==1'b0 || out_hit!==1'b0 || out_vl!==12'd0 || out_desc!==163'd0)
      bad("reset did not flush pending descriptor/result");
    sweep_all; // re-use the physical BRAM, not a new phantom cleared copy
    rx_enable=1;
    manual_lookup(image[good_slot][27:12],1'b0,12'd0);
    rx_enable=0;cfg_mode=1;
    // Malformed reserved bits and invalid indices must fail closed.
    config_word(good_slot,image[good_slot] | 32'h8000_0000);
    cfg_mode=0;rx_enable=1;
    manual_lookup(image[good_slot][27:12],1'b0,12'd0);
    rx_enable=0;cfg_mode=1;
    if(N==16) begin
      config_word(good_slot,(image[good_slot]&32'hFFFF_F000) | N);
      cfg_mode=0;rx_enable=1;
      manual_lookup(image[good_slot][27:12],1'b0,12'd0);
      rx_enable=0;cfg_mode=1;
    end
    config_word(good_slot,image[good_slot]);
    cfg_mode=0;rx_enable=1;
    manual_lookup(image[good_slot][27:12],1'b1,image[good_slot][11:0]);
    repeat(4) @(negedge clk);
    if(out_vld!==1'b0) bad("stale output after manual probes");

    if(errors==0)
      $display("T12 LOOKUP PASS (case=%0d, N=%0d, buckets=%0d, image=%0d/%0d, lookups=%0d, hits=%0d misses=%0d, all_idx=%0d ways=%04b, in_stall=%0d out_stall=%0d max_hold=%0d, seed=%04h/%04h)",
        CASE_NO,N,BUCKETS,N,WORDS,LOOKUPS,hit_count,miss_count,
        seen_count,way_covered,in_stalls,out_stalls,max_hold,seed0,seed1);
    else $display("T12 LOOKUP FAIL (case=%0d errors=%0d)",CASE_NO,errors);
    $finish;
  end
  initial begin
    #20_000_000;
    $display("T12 LOOKUP FAIL: timeout case=%0d sent=%0d out=%0d",CASE_NO,sent,retired);
    $finish;
  end
endmodule
module tb_t12c_lookup; tb_t12_core #(.N(4096),.BUCKETS(2048),.CASE_NO(0),.LOOKUPS(100000)) core(); endmodule
module tb_t12r_lookup; tb_t12_core #(.N(4096),.BUCKETS(2048),.CASE_NO(1),.LOOKUPS(100000)) core(); endmodule
module tb_t12s_lookup; tb_t12_core #(.N(16),.BUCKETS(32),.CASE_NO(2),.LOOKUPS(20000)) core(); endmodule
module tb_t12h_lookup; tb_t12_core #(.N(16),.BUCKETS(32),.CASE_NO(3),.LOOKUPS(20000)) core(); endmodule
