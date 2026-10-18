// Production reassembly, scatter, pool and checksum integration.
// Independent byte oracle and allocation ledger; only external PMEM timing is modeled.
`timescale 1ns/1ps
module tb_rx_reassembly_chain;
  reg clk=0; always #5 clk=~clk;
  reg rst=1,en=1,iv=0,ordy=0,alloc_src=0;
  reg [207:0] idesc=0; reg [11:0] ivl=1;
  wire ir,ov,od,alloc_c,vc,sv,cd,ce,qv,qr,qd,qg,drain;
  wire [3:0] reason,sblk,free_id,csrc,qblk;
  wire [207:0] odesc; wire [11:0] ovl;
  wire [13:0] olen,cdst,clen,qlen;
  wire [19:0] oblocks,pblocks,cblocks,qblocks;
  wire [2:0] ocnt,pcnt,acnt,ccnt,qcnt;
  wire [10:0] csbyte;
  wire cv,cr,fr,cwv;
  wire [1:0] qreason;
  wire [31:0] qsrc,qdst,hits,drops,slots;
  wire [15:0] fmap;
  reg [15:0] return_mask=0;
  reg hold_copy=0,hold_check=0,copy_fault=0,checksum_check=1;
  wire c_ready,q_ready;
  wire crr,qrr,cwg; wire [12:0] cra,qra,cwa;
  wire [31:0] cwd; wire [3:0] cbe;
  reg read_valid=0; reg [31:0] read_data=0;
  reg pending=0; integer latency=1,left=0;
  reg [12:0] read_address;
  integer cycles=0,cases=0,copy_jobs=0,check_jobs=0,returns=0;
  reg [15:0] owned=0; reg [15:0] background=0;
  reg [31:0] mem[0:8191]; reg [7:0] expected[0:10239];
  integer lane,mi,ci,bi; integer size_now=0,seed=0;
  assign cr=c_ready && !hold_copy;
  assign qr=q_ready && !hold_check;
  wire read_allow=!pending && !rst && ((cycles%5)!=0);
  wire cg=crr && read_allow;
  wire qgrant=qrr && !crr && read_allow;
  assign cwg=!rst && ((cycles%7)!=0);
  rx_reassembly_chain #(.SLOTS(1),.MAX_FRAGS(6)) dut(
    .clk(clk),.rst_sync(rst),.en(en),.in_vld(iv),.in_ready(ir),.in_desc(idesc),.in_vl(ivl),
    .out_vld(ov),.out_ready(ordy),.out_drop(od),.out_reason(reason),.out_desc(odesc),.out_vl(ovl),
    .out_app_len(olen),.out_blocks(oblocks),.out_block_count(ocnt),
    .alloc_chain(alloc_c),.alloc_chain_count(acnt),.valid_chain(vc),.chain_blocks(pblocks),.chain_count(pcnt),
    .copy_req_valid(cv),.copy_req_ready(cr),.copy_src_blk(csrc),.copy_src_byte(csbyte),
    .copy_dst_blocks(cblocks),.copy_dst_count(ccnt),.copy_dst_byte(cdst),.copy_len(clen),.copy_done(cd),.copy_error(ce|copy_fault),
    .check_req_valid(qv),.check_req_ready(qr),.check_blk(qblk),.check_blocks(qblocks),.check_block_count(qcnt),
    .check_app_len(qlen),.check_src_ip(qsrc),.check_dst_ip(qdst),.check_done(qd),.check_good(qg),.check_reason(qreason),
    .free_blk_valid(fr),.free_blk_id(free_id),.drain_active(drain),.hit_cnt(hits),.drop_cnt(drops),.slot_used(slots));
  rx_block_pool #(.CHAIN_ENABLE(1)) pool(.clk(clk),.rst_sync(rst),.alloc_a(alloc_src),.alloc_b(1'b0),
    .valid_a(sv),.valid_b(),.blk_a(sblk),.blk_b(),
    .free_a(1'b0),.free_b(1'b0),.free_pipe(1'b0),.free_reasm(fr),
    .free_id_a(4'd0),.free_id_b(4'd0),.free_id_pipe(4'd0),.free_id_reasm(free_id),
    .free_pb0(1'b0),.free_pb1(1'b0),.free_spill(1'b0),.free_id_pb0(4'd0),.free_id_pb1(4'd0),.free_id_spill(4'd0),
    .free_map(fmap),.exhaust_cnt(),.borrow_cnt(),.alloc_chain(alloc_c),.alloc_chain_count(acnt),
    .valid_chain(vc),.chain_blocks(pblocks),.chain_count(pcnt),.free_chain_mask(return_mask));
  rx_pmem_scatter_copy copier(.clk(clk),.reset(rst),.cancel(1'b0),.job_valid(cv && !hold_copy),.job_ready(c_ready),
    .src_blk(csrc),.src_byte(csbyte),.dst_blocks(cblocks),.dst_count(ccnt),.dst_byte(cdst),.len(clen),
    .done(cd),.error(ce),.cancelled(),.rd_req(crr),.rd_grant(cg),.rd_valid(read_valid),.rd_data(read_data),.rd_addr(cra),
    .wr_valid(cwv),.wr_grant(cwg),.wr_addr(cwa),.wr_data(cwd),.wr_be(cbe));
  rx_udp_checksum_engine #(.CHAIN_ENABLE(1)) udp_checker(.clk(clk),.rst_sync(rst),.job_valid(qv && !hold_check),.job_ready(q_ready),
    .job_blk(qblk),.job_app_len(qlen),.job_src_ip(qsrc),.job_dst_ip(qdst),.job_check_en(checksum_check),
    .rd_req(qrr),.rd_addr(qra),.rd_grant(qgrant),.rd_valid(read_valid),.rd_data(read_data),
    .done(qd),.good(qg),.reason(qreason),.job_blocks(qblocks),.job_block_count(qcnt));
  task fail; input [1023:0] msg; begin $display("RX_REASSEMBLY_CHAIN FAIL case=%0d cycles=%0d state=%0d %0s",cases,cycles,dut.state,msg); $fatal(1); end endtask
  always @(posedge clk) begin
    cycles=cycles+1;
    if(rst) begin owned=0;pending<=0;read_valid<=0;end
    else begin
      if(fr) begin
        if(free_id<6 || !owned[free_id] || fmap[free_id]) fail("duplicate/unowned scalar release");
        if((copier.state!=0) && (free_id==csrc)) fail("source returned before accepted copy completed");
        for(ci=0;ci<qcnt;ci=ci+1) if(udp_checker.state!=0 && free_id==((qblocks>>(4*ci))&15)) fail("destination returned before accepted checksum completed");
        owned[free_id]=0;returns=returns+1;
      end
      for(bi=6;bi<16;bi=bi+1) if(return_mask[bi]) begin
        if(!owned[bi] || fmap[bi]) fail("unowned external return"); owned[bi]=0;
      end
      if(alloc_src && sv) begin if(owned[sblk]) fail("source allocation alias"); owned[sblk]=1;end
      if(alloc_c && vc) for(ci=0;ci<pcnt;ci=ci+1) begin
        bi=(pblocks>>(4*ci))&15;
        if(owned[bi]) fail("destination allocation alias"); owned[bi]=1;
      end
      if(cv && cr) copy_jobs=copy_jobs+1;
      if(qv && qr) check_jobs=check_jobs+1;
      read_valid<=0;
      if(pending) begin
        if(left==0) begin read_valid<=1;read_data<=mem[read_address];pending<=0;end
        else left<=left-1;
      end
      if(cg || qgrant) begin
        if(pending) fail("more than one outstanding memory request");
        pending<=1;left<=latency-1;read_address<=cg?cra:qra;
        if(fmap[(cg?cra:qra)>>9] || !owned[(cg?cra:qra)>>9]) fail("read from unowned or returned block");
      end
      if(cwv && cwg) begin
        if(!owned[cwa[12:9]] || fmap[cwa[12:9]]) fail("write to unowned destination");
        for(lane=0;lane<4;lane=lane+1) if(cbe[lane]) mem[cwa][lane*8+:8]<=cwd[lane*8+:8];
      end
    end
  end
  task tick; begin @(posedge clk);#1;end endtask
  task begin_case; input [511:0] name; begin cases=cases+1;$display("RX_REASSEMBLY_CHAIN CASE %0d %0s",cases,name);end endtask
  task reset_all; begin
    @(negedge clk);rst=1;iv=0;ordy=0;en=1;alloc_src=0;return_mask=0;hold_copy=0;hold_check=0;copy_fault=0;background=0;
    repeat(3) tick();@(negedge clk);rst=0;repeat(3) tick();
    if(fmap!==16'hffc0 || slots!==0 || ov || drain) fail("reset did not clear pool/context"); checksum_check=1;
  end endtask
  task wait_ready; integer guard;begin
    guard=0;while(!ir && !ov) begin tick();guard=guard+1;if(guard>100000) fail("ready/output timeout");end
  end endtask
  task wait_state; input [3:0] wanted;integer guard;begin
    guard=0;while(dut.state!==wanted) begin tick();guard=guard+1;if(guard>100000) fail("state timeout");end
  end endtask
  task check_full;begin repeat(3) tick();if(fmap!==(16'hffc0 & ~background) || owned!==background) fail("pool conservation");end endtask
  task get_source; output integer block_id;begin
    @(negedge clk);alloc_src=1;#1;if(!sv) fail("source pool exhausted unexpectedly");block_id=sblk;
    tick();@(negedge clk);alloc_src=0;
  end endtask
  task release_background;begin @(negedge clk);return_mask=background;tick();@(negedge clk);return_mask=0;background=0;check_full();end endtask
  task reserve_sparse;integer b,j;begin
    // Occupy alternating IDs; the five destination slots cannot be contiguous.
    for(j=0;j<5;j=j+1) begin get_source(b);background[b]=1;end
    @(negedge clk);return_mask=16'h0280;tick();@(negedge clk);return_mask=0;background=background & ~16'h0280;
  end endtask
  task prepare_image; input integer app_len,tag,mode;integer j,acc,udp,c;begin
    size_now=app_len;seed=tag;
    for(j=0;j<10240;j=j+1) expected[j]=8'hd7;
    for(j=0;j<42;j=j+1) expected[j]=(j*11+tag)&255;
    expected[26]=8'h0a;expected[27]=0;expected[28]=0;expected[29]=1;
    expected[30]=8'h0a;expected[31]=0;expected[32]=0;expected[33]=2;
    expected[34]=8'h12;expected[35]=8'h34;expected[36]=8'h56;expected[37]=8'h78;
    udp=app_len+8;expected[38]=udp>>8;expected[39]=udp&255;expected[40]=0;expected[41]=0;
    for(j=0;j<app_len;j=j+1) expected[42+j]=(j*29+(j>>3)+tag)&255;
    acc=16'h0a00+1+16'h0a00+2+17+udp;
    for(j=0;j<udp;j=j+2) acc=acc+(expected[34+j]<<8)+((j+1<udp)?expected[35+j]:0);
    while(acc>65535) acc=(acc&65535)+(acc>>16);
    c=(~acc)&65535;if(c==0)c=65535;
    expected[40]=c>>8;expected[41]=c;
    if(mode==1) expected[41]=expected[41]^8'h01;
    if(mode==2) expected[39]=expected[39]^8'h01;
    if(mode==3) begin expected[40]=0;expected[41]=0;end
  end endtask
  task submit_fragment; input integer start_byte,n,mf,ident,vl,fragmented;integer b,j,w,raw;reg [31:0] val;begin
    while(!ir) tick();get_source(b);
    for(w=0;w<512;w=w+1) mem[b*512+w]=32'hcdcdcdcd;
    raw=(start_byte==0)?42:34;
    if(start_byte==0) for(j=0;j<42;j=j+1) mem[b*512+j/4][24-8*(j%4)+:8]=expected[j];
    for(j=0;j<n && raw+j<2048;j=j+1) mem[b*512+(raw+j)/4][24-8*((raw+j)%4)+:8]=expected[42+start_byte+j];
    idesc=0;idesc[207:192]=ident;idesc[191]=mf;idesc[189:177]=(start_byte==0)?0:((start_byte+8)>>3);
    idesc[176]=fragmented;idesc[173:163]=n;idesc[162:159]=b;
    idesc[95:64]=32'h0a000001;idesc[63:32]=32'h0a000002;
    ivl=vl;iv=1;tick();@(negedge clk);iv=0;
  end endtask
  task send_fragment;input integer start_byte,n,mf,ident,vl;begin submit_fragment(start_byte,n,mf,ident,vl,1);wait_ready();end endtask
  task drain_all;integer guard;begin
    guard=0;while(drain || dut.state!=0 || slots!=0) begin tick();guard=guard+1;if(guard>100000)fail("drain timeout");end
    check_full();@(negedge clk);en=1;repeat(3)tick();
  end endtask
  task expect_drop; input integer why;begin wait_ready();if(!od || reason!==why[3:0] || ov) fail("expected precise reject reason");check_full();end endtask
  task check_output;input integer app_len,tag;integer j,b,c;reg [207:0] held_desc;reg [19:0] held_blocks;reg [13:0] held_len;reg [2:0] held_count;begin
    wait_ready();c=(app_len+42+2047)/2048;
    if(!ov || od || olen!==app_len[13:0] || ocnt!==c[2:0] || odesc[173:163]!==app_len[10:0] || odesc[162:159]!==oblocks[3:0]) fail("output descriptor/full length/count");
    for(j=0;j<app_len+42;j=j+1) begin
      b=(oblocks>>(4*(j/2048)))&15;
      if(!owned[b] || fmap[b]) fail("output block no longer owned");
      if(mem[b*512+(j%2048)/4][24-8*(j%4)+:8]!==expected[j]) begin $display("byte=%0d got=%02h expected=%02h block=%0d",j,mem[b*512+(j%2048)/4][24-8*(j%4)+:8],expected[j],b);fail("PMEM byte oracle");end
    end
    held_desc=odesc;held_blocks=oblocks;held_len=olen;held_count=ocnt;
    repeat(17) begin tick();if(!ov || odesc!==held_desc || oblocks!==held_blocks || olen!==held_len || ocnt!==held_count) fail("output changed under backpressure");end
    @(negedge clk);ordy=1;tick();@(negedge clk);ordy=0;
    return_mask=0;for(j=0;j<c;j=j+1) return_mask[(held_blocks>>(4*j))&15]=1;
    tick();@(negedge clk);return_mask=0;check_full();
  end endtask
  integer lens[0:5],offsets[0:7],sizes[0:7];integer li,order,j,n,pos,take,before_checks;
  task full_datagram; input integer app_len,reverse,mode,ident;begin
    prepare_image(app_len,ident,mode);n=0;pos=0;
    while(pos<app_len) begin take=(pos==0)?1000:1992;if(take>app_len-pos)take=app_len-pos;offsets[n]=pos;sizes[n]=take;pos=pos+take;n=n+1;end
    for(j=0;j<n;j=j+1) begin
      li=reverse?(n-1-j):j;
      send_fragment(offsets[li],sizes[li],(offsets[li]+sizes[li]<app_len),ident,1);
    end
  end endtask
  initial begin
    for(mi=0;mi<8192;mi=mi+1)mem[mi]=32'hcdcdcdcd;
    lens[0]=2006;lens[1]=2007;lens[2]=8150;lens[3]=8151;lens[4]=8191;lens[5]=8192;
    for(order=0;order<2;order=order+1) for(mi=0;mi<6;mi=mi+1) begin
      begin_case(order?"last_first_sparse_boundary":"ordered_sparse_boundary");reset_all();reserve_sparse();latency=order?3:1;
      full_datagram(lens[mi],order,0,100+mi+10*order);check_output(lens[mi],100+mi+10*order);release_background();
    end
    begin_case("gap_then_fill_odd_end_and_no_arrival_timeout");reset_all();prepare_image(17,31,0);
    send_fragment(0,8,1,31,1);send_fragment(16,1,0,31,1);before_checks=check_jobs;repeat(2000)tick();
    if(slots!==1 || ov || check_jobs!=before_checks)fail("gap delivered or timed out");send_fragment(8,8,1,31,1);check_output(17,31);
    begin_case("UDP_checksum_reject_reclaims_all");reset_all();full_datagram(2007,1,1,40);expect_drop(9);
    begin_case("UDP_length_reject_reclaims_all");reset_all();full_datagram(2007,0,2,41);expect_drop(8);
    begin_case("UDP_zero_checksum_allowed_when_validation_disabled");reset_all();checksum_check=0;full_datagram(2007,0,3,42);check_output(2007,42);checksum_check=1;
    begin_case("overlap_reject_reclaims_all");reset_all();prepare_image(64,43,0);send_fragment(0,32,1,43,1);send_fragment(16,16,1,43,1);expect_drop(5);
    begin_case("alignment_reject");reset_all();prepare_image(64,44,0);send_fragment(0,7,1,44,1);expect_drop(1);
    begin_case("first_source_size_reject");reset_all();prepare_image(2048,45,0);send_fragment(0,2007,1,45,1);expect_drop(2);
    begin_case("application_size_reject");reset_all();prepare_image(8192,46,0);send_fragment(8192,1,0,46,1);expect_drop(2);
    begin_case("maximum_fragment_reject");reset_all();prepare_image(64,47,0);for(j=0;j<6;j=j+1)send_fragment(j*8,8,1,47,1);send_fragment(48,8,1,47,1);expect_drop(7);
    begin_case("contradictory_terminal_reject");reset_all();prepare_image(64,48,0);send_fragment(16,8,0,48,1);send_fragment(24,8,0,48,1);expect_drop(6);
    begin_case("bytes_beyond_terminal_reject");reset_all();prepare_image(64,49,0);send_fragment(32,8,1,49,1);send_fragment(16,8,0,49,1);expect_drop(6);
    begin_case("VL_key_and_unmatched_full_slot_ownership");reset_all();prepare_image(64,50,0);send_fragment(0,32,1,50,1);send_fragment(32,32,0,50,2);
    if(!od || reason!=3 || slots!=1 || fmap==16'hffc0)fail("unmatched fragment released other VL");send_fragment(32,32,0,50,1);check_output(64,50);
    begin_case("atomic_pool_exhaustion");reset_all();for(j=0;j<7;j=j+1)begin get_source(li);background[li]=1;end
    prepare_image(64,51,0);send_fragment(0,32,1,51,1);expect_drop(3);release_background();
    begin_case("copy_error_reclaims_source_and_destinations");reset_all();prepare_image(64,52,0);copy_fault=1;send_fragment(0,32,1,52,1);expect_drop(11);
    begin_case("disable_before_copy_accept");reset_all();prepare_image(64,53,0);hold_copy=1;submit_fragment(0,32,1,53,1,1);wait_state(2);@(negedge clk);en=0;drain_all();
    begin_case("disable_waits_accepted_copy");reset_all();prepare_image(64,54,0);latency=3;submit_fragment(0,32,1,54,1,1);wait_state(3);@(negedge clk);en=0;drain_all();
    begin_case("disable_before_checksum_accept");reset_all();prepare_image(64,55,0);send_fragment(0,32,1,55,1);hold_check=1;submit_fragment(32,32,0,55,1,1);wait_state(6);@(negedge clk);en=0;drain_all();
    begin_case("disable_waits_accepted_checksum");reset_all();prepare_image(64,56,0);send_fragment(0,32,1,56,1);submit_fragment(32,32,0,56,1,1);wait_state(7);@(negedge clk);en=0;drain_all();
    begin_case("disable_after_tail_trim_no_double_free");reset_all();prepare_image(64,57,0);send_fragment(0,32,1,57,1);submit_fragment(32,32,0,57,1,1);wait_state(8);tick();@(negedge clk);en=0;drain_all();
    begin_case("disable_fragmented_held_output");reset_all();prepare_image(64,58,0);send_fragment(0,32,1,58,1);send_fragment(32,32,0,58,1);if(!ov)fail("missing held output");@(negedge clk);en=0;drain_all();
    begin_case("disable_single_message_preserves_distinct_context_ownership");reset_all();prepare_image(64,59,0);send_fragment(0,32,1,59,1);submit_fragment(0,16,0,60,1,0);wait_state(9);@(negedge clk);en=0;drain_all();
    begin_case("disable_unmatched_error_does_not_use_stale_slot");reset_all();prepare_image(64,61,0);send_fragment(0,32,1,61,1);submit_fragment(0,7,1,62,1,1);wait_state(4);@(negedge clk);en=0;drain_all();
    begin_case("reset_during_copy_and_recover");reset_all();prepare_image(64,63,0);submit_fragment(0,32,1,63,1,1);wait_state(3);reset_all();full_datagram(2007,0,0,64);check_output(2007,64);
    begin_case("reset_during_checksum_and_recover");reset_all();prepare_image(64,65,0);send_fragment(0,32,1,65,1);submit_fragment(32,32,0,65,1,1);wait_state(7);reset_all();full_datagram(2007,1,0,66);check_output(2007,66);
    begin_case("reset_held_output_and_recover");reset_all();full_datagram(2007,0,0,67);if(!ov)fail("missing reset output");reset_all();full_datagram(2007,0,0,68);check_output(2007,68);
    if(cases!=37)fail("case inventory mismatch");
    $display("RX_REASSEMBLY_CHAIN PASS cases=%0d cycles=%0d copy_jobs=%0d check_jobs=%0d releases=%0d",cases,cycles,copy_jobs,check_jobs,returns);$finish;
  end
  initial begin #10000000;fail("global timeout");end
endmodule
