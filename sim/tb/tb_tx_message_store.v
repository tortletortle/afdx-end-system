`timescale 1 ns / 1 ps
module tb_tx_message_store;
  reg clk=0,rst_sync=1;
  always #4 clk=~clk;
  reg reserve_valid=0,cancel_open=0,msg_commit=0,sch_take=0,fragment_done=0,fragment_error=0;
  reg [13:0] reserve_length=0,done_next_offset=0;
  reg [15:0] length=0;
  reg [7:0] port_id=0,sch_port=0,desc_rd_addr=0;
  reg [1:0] port_type=1;
  reg [3:0] port_depth=3,done_head=0;
  reg done_last=0;
  wire reserve_ready,reserve_reject,commit_reject,wr_valid,reservation_active,sch_ack,pending;
  wire [3:0] wr_blk,sch_head;
  wire [15:0] open_blocks,open_mask,sch_blocks,sch_identification,free_map;
  wire [2:0] open_count,sch_block_count;
  wire [13:0] open_length,sch_app_length,sch_fragment_offset;
  wire [12:0] sch_length;
  wire [31:0] desc_rd_data;
  wire [7:0] sch_req,buf_full;
  wire [15:0] overwrite_count,queue_overflow_count,exhaust_count,bad_completion_count,failed_message_count;
  tx_message_store #(.NUM_PORTS(8)) dut (
    .clk(clk),.rst_sync(rst_sync),.tb_us(8'd7),
    .reserve_valid(reserve_valid),.reserve_length(reserve_length),.reserve_ready(reserve_ready),.reserve_reject(reserve_reject),
    .cancel_open(cancel_open),.wr_blk(wr_blk),.wr_valid(wr_valid),.open_blocks(open_blocks),.open_count(open_count),
    .open_length(open_length),.reservation_active(reservation_active),.open_mask(open_mask),
    .msg_commit(msg_commit),.port_id(port_id),.length(length),.port_type(port_type),.port_depth(port_depth),.commit_reject(commit_reject),
    .desc_rd_addr(desc_rd_addr),.desc_rd_data(desc_rd_data),.sch_req(sch_req),.buf_full(buf_full),
    .sch_take(sch_take),.sch_port(sch_port),.sch_ack(sch_ack),.sch_head(sch_head),.sch_length(sch_length),
    .sch_app_length(sch_app_length),.sch_fragment_offset(sch_fragment_offset),.sch_blocks(sch_blocks),.sch_identification(sch_identification),.sch_block_count(sch_block_count),
    .fragment_done(fragment_done),.fragment_error(fragment_error),.done_head(done_head),.done_last(done_last),.done_next_offset(done_next_offset),
    .free_map(free_map),.overwrite_count(overwrite_count),.queue_overflow_count(queue_overflow_count),.exhaust_count(exhaust_count),
    .bad_completion_count(bad_completion_count),.failed_message_count(failed_message_count),.pending(pending)
  );
  integer checks=0,errors=0,cases=0,i,j,waited;
  integer audit_port,audit_node,audit_index;
  reg [5:0] queued;
  reg [15:0] used, mask_a,mask_b,mask_c,blocks_a;
  reg [15:0] ident_a, saved_free;
  reg [3:0] head_a,head_b,head_c;
  reg [13:0] offset_a;
  task check;
    input condition;
    input [767:0] text;
    begin checks=checks+1;if(condition!==1'b1)begin errors=errors+1;$display("T81 ERROR case=%0d %0s",cases,text);end end
  endtask
  // Exhaustive ownership accounting for the six physical TX blocks on each edge.
  always @(negedge clk) if(!rst_sync) begin
    used=free_map;
    check((free_map & open_mask)==0,"open/free overlap");
    used=used | open_mask;
    for(i=0;i<6;i=i+1) if(dut.message_valid[i]) begin
      check((used & dut.message_mask[i])==0,"physical TX block has two owners");
      used=used | dut.message_mask[i];
    end
    if(dut.request_valid && dut.request_commit && dut.request_open_valid) begin
      check((used & dut.request_mask)==0,"captured commit block duplicated");
      used=used | dut.request_mask;
    end
    check(used==16'h003f,"lost or out-of-pool TX block");
    queued=0;
    for(audit_port=0;audit_port<8;audit_port=audit_port+1)begin
      check(dut.port_valid[audit_port]==(dut.port_count[audit_port]!=0),"FIFO valid/count mismatch");
      if(dut.port_valid[audit_port])begin
        check(dut.port_count[audit_port]<=6,"FIFO exceeds physical node pool");
        audit_node=dut.port_head[audit_port];
        for(audit_index=0;audit_index<6;audit_index=audit_index+1)if(audit_index<dut.port_count[audit_port])begin
          check(audit_node<6,"FIFO node out of pool");
          if(audit_node<6)begin
            check(!queued[audit_node] && dut.message_valid[audit_node] && !dut.message_dequeued[audit_node],"FIFO cycle/invalid/dequeued node");
            check(dut.message_port[audit_node]==audit_port,"FIFO message owner mismatch");
            queued[audit_node]=1;
            if(audit_index==dut.port_count[audit_port]-1)check(audit_node==dut.port_tail[audit_port],"FIFO tail unreachable");
            audit_node=dut.queue_next[audit_node];
          end
        end
      end
    end
    check(queued==(dut.message_valid & ~dut.message_dequeued),"valid queued message unreachable");
    check((dut.message_inflight & ~dut.message_valid)==0,"invalid message still in flight");
  end
  task reset_store;
    begin
      rst_sync=1;msg_commit=0;sch_take=0;fragment_done=0;fragment_error=0;reserve_valid=0;cancel_open=0;
      repeat(3)@(negedge clk);rst_sync=0;repeat(3)@(negedge clk);
      check(wr_valid && free_map==16'h003e && open_mask==1,"reset ownership");
    end
  endtask
  task reserve_message;
    input [13:0] n;
    input expected_success;
    begin
      reserve_length=n;
      check(reserve_ready,"reserve not ready");reserve_valid=1;
      @(negedge clk);reserve_valid=0;
      check(reserve_reject==!expected_success,"reserve status mismatch");
      if(expected_success)check(reservation_active && open_length==n,"reservation not retained");
      repeat(2)@(negedge clk);
    end
  endtask
  task commit_message;
    input [7:0] port;
    input [15:0] n;
    input [1:0] kind;
    input [3:0] depth;
    input expected_success;
    begin
      port_id=port;length=n;port_type=kind;port_depth=depth;msg_commit=1;
      @(negedge clk);msg_commit=0;
      @(negedge clk);check(commit_reject==!expected_success,"commit status mismatch");
      repeat(2)@(negedge clk);
    end
  endtask
  task take_fragment;
    input [7:0] port;
    input [13:0] expected_offset;
    input [13:0] expected_length;
    begin
      check(sch_req[port],"queued message not schedulable");
      sch_port=port;sch_take=1;@(negedge clk);sch_take=0;
      @(negedge clk);check(sch_ack,"take did not acknowledge");
      check(sch_fragment_offset==expected_offset && sch_app_length==expected_length,"fragment descriptor length/offset");
      check(!sch_req[port] || expected_offset+sch_length==expected_length+8,"non-final head granted twice");
      @(negedge clk);
    end
  endtask
  task complete_fragment;
    input [3:0] head;
    input last;
    input [13:0] offset;
    begin
      done_head=head;done_last=last;done_next_offset=offset;fragment_done=1;
      @(negedge clk);fragment_done=0;repeat(2)@(negedge clk);
    end
  endtask
  task fail_fragment;
    input [3:0] head;
    begin
      done_head=head;fragment_error=1;
      @(negedge clk);fragment_error=0;repeat(3)@(negedge clk);
    end
  endtask
  initial begin
    reset_store();reserve_message(8192,1);blocks_a=open_blocks;mask_a=open_mask;head_a=wr_blk;
    check(open_count==4 && mask_a==16'h000f,"four-block reservation");
    commit_message(2,8192,1,3,1);cases=cases+1;
    desc_rd_addr=2;repeat(2)@(negedge clk);
    check(desc_rd_data[28] && desc_rd_data[20:8]==0 && desc_rd_data[27],"8192 descriptor lost bit13");
    // Reserve all remaining free blocks while the large message holds four.
    reserve_message(4096,1);head_b=wr_blk;mask_b=open_mask;
    check(mask_b==16'h0030,"sparse second reservation");commit_message(3,4096,1,1,1);
    check(!wr_valid && free_map==0,"pool exhaustion did not close open writer");
    offset_a=0;
    for(j=0;j<6;j=j+1) begin
      take_fragment(2,offset_a,8192);
      check(sch_blocks==blocks_a && sch_block_count==4,"payload chain changed across fragments");
      if(j==0)ident_a=sch_identification;else check(sch_identification==ident_a,"IP ID changed across fragments");
      check(sch_length==(j<5 ? 1472 : 840),"fragment payload size");
      offset_a=offset_a+sch_length;
      if(j==1)begin
        saved_free=free_map;complete_fragment(head_a,0,offset_a+8);
        check(bad_completion_count==1 && free_map==saved_free && !sch_req[2],"malformed completion released ownership");
      end
      complete_fragment(head_a,j==5,offset_a);
      if(j<5)check(free_map==0 && sch_req[2],"non-final fragment returned payload blocks");
    end
    check(wr_valid && (free_map | open_mask)==mask_a && !sch_req[2],"final fragment failed to return chain");cases=cases+1;
    // Outstanding message B must survive A's recovery and reuse.
    take_fragment(3,0,4096);head_b=sch_head;
    complete_fragment(head_b,0,1472);take_fragment(3,1472,4096);
    complete_fragment(head_b,0,2944);take_fragment(3,2944,4096);
    check(sch_length==1160,"second message final length");complete_fragment(head_b,1,4104);
    check((free_map | open_mask)==16'h003f,"all messages did not return pool");cases=cases+1;
    // Failed atomic reserve retains the old single open block and no extras.
    commit_message(0,100,1,3,1);commit_message(1,100,1,3,1);commit_message(4,100,1,3,1);
    saved_free=free_map;mask_c=open_mask;reserve_message(8192,0);
    check(free_map==saved_free && open_mask==mask_c && open_count==1 && !reservation_active,"failed reserve partially mutated ownership");cases=cases+1;
    reset_store();reserve_message(8192,1);cancel_open=1;@(negedge clk);cancel_open=0;repeat(3)@(negedge clk);
    check((free_map | open_mask)==16'h003f && open_count==1 && !reservation_active,"cancel did not reclaim reservation");cases=cases+1;
    // Queue-full reject must return every reserved block, not just its head.
    commit_message(1,12,1,1,1);reserve_message(8192,1);mask_c=open_mask;
    commit_message(1,8192,1,1,0);check(queue_overflow_count==1,"queue full did not count");
    check((free_map | open_mask)==16'h003e,"queue reject leaked chain");
    take_fragment(1,0,12);complete_fragment(sch_head,1,20);cases=cases+1;
    // Adjacent same-port commits preserve both messages; take runs in order.
    reset_store();port_id=5;length=64;port_type=1;port_depth=3;msg_commit=1;
    head_a=wr_blk;@(negedge clk);head_b=wr_blk;length=65;
    @(negedge clk);msg_commit=0;repeat(3)@(negedge clk);
    take_fragment(5,0,64);check(sch_head==head_a,"first queue head");complete_fragment(head_a,1,72);
    take_fragment(5,0,65);check(sch_head==head_b,"second queue head");complete_fragment(head_b,1,73);cases=cases+1;
    // Commit/take collision has the original commit-first pending contract.
    reset_store();commit_message(6,100,1,3,1);
    port_id=6;length=101;msg_commit=1;sch_port=6;sch_take=1;
    @(negedge clk);check(pending,"take collision not pending");msg_commit=0;sch_take=0;
    repeat(2)@(negedge clk);check(sch_ack && sch_app_length==100,"pending take lost old queue head");
    head_a=sch_head;@(negedge clk);complete_fragment(head_a,1,108);
    take_fragment(6,0,101);complete_fragment(sch_head,1,109);cases=cases+1;
    reset_store();commit_message(7,100,0,1,1);head_a=dut.port_head[7];
    commit_message(7,101,0,1,1);check(overwrite_count==1 && !dut.message_valid[head_a],"sampling overwrite leaked old message");
    take_fragment(7,0,101);complete_fragment(sch_head,1,109);cases=cases+1;
    reset_store();reserve_message(2049,1);commit_message(0,2048,1,3,0);
    check((free_map | open_mask)==16'h003f,"mismatched commit leaked chain");cases=cases+1;
    reset_store();reserve_message(8192,1);commit_message(0,8192,1,3,1);take_fragment(0,0,8192);
    reset_store();check(sch_req==0 && bad_completion_count==0,"reset retained old message");cases=cases+1;
    // Reject a live queue -> sampling switch without orphaning either node.
    reset_store();commit_message(2,100,1,3,1);commit_message(2,101,1,3,1);
    commit_message(2,102,0,1,0);
    check(dut.port_count[2]==2 && overwrite_count==0,"type change mutated existing queue");
    take_fragment(2,0,100);complete_fragment(sch_head,1,108);
    take_fragment(2,0,101);complete_fragment(sch_head,1,109);
    check((free_map | open_mask)==16'h003f,"type rejection leaked queue successors");cases=cases+1;
    // A non-final in-flight head must survive a configuration/type change.
    reset_store();reserve_message(4096,1);commit_message(3,4096,1,3,1);
    take_fragment(3,0,4096);head_a=sch_head;commit_message(3,100,0,1,0);
    check(!sch_req[3] && dut.message_inflight[head_a],"type change replaced active fragment");
    complete_fragment(head_a,0,1472);take_fragment(3,1472,4096);
    complete_fragment(head_a,0,2944);take_fragment(3,2944,4096);complete_fragment(head_a,1,4104);
    check((free_map | open_mask)==16'h003f,"active type rejection leaked blocks");cases=cases+1;
    reset_store();commit_message(255,100,1,3,0);
    commit_message(1,100,3,3,0);reserve_message(2048,1);commit_message(1,2048,2,3,0);
    check(sch_req==0 && (free_map | open_mask)==16'h003f,"invalid port/type/SAP length published or leaked");cases=cases+1;
    // Non-final failure removes only the failed FIFO head, including a full
    // four-block message; the successor and another port remain schedulable.
    reset_store();reserve_message(8192,1);commit_message(2,8192,1,3,1);
    commit_message(2,80,1,3,1);commit_message(3,81,1,3,1);
    take_fragment(2,0,8192);head_a=sch_head;fail_fragment(head_a);
    check(failed_message_count==1 && bad_completion_count==0,"non-final failure count");
    take_fragment(2,0,80);complete_fragment(sch_head,1,88);
    take_fragment(3,0,81);complete_fragment(sch_head,1,89);
    check((free_map|open_mask)==16'h003f,"non-final error leaked chain/successor");cases=cases+1;
    // Final take already dequeued. Failure must not dequeue the new head.
    reset_store();reserve_message(2048,1);commit_message(4,2048,1,3,1);
    commit_message(4,82,1,3,1);take_fragment(4,0,2048);head_a=sch_head;
    complete_fragment(head_a,0,1472);take_fragment(4,1472,2048);fail_fragment(head_a);
    take_fragment(4,0,82);complete_fragment(sch_head,1,90);
    check((free_map|open_mask)==16'h003f && failed_message_count==1,"final error lost successor/chain");cases=cases+1;
    // Illegal, non-in-flight and duplicate error events cannot free ownership.
    reset_store();commit_message(1,83,1,3,1);head_a=dut.port_head[1];saved_free=free_map;
    fail_fragment(head_a);fail_fragment(15);
    check(bad_completion_count==2 && failed_message_count==0 && free_map==saved_free,"invalid errors released ownership");
    take_fragment(1,0,83);fail_fragment(head_a);saved_free=free_map;fail_fragment(head_a);
    check(bad_completion_count==3 && failed_message_count==1 && free_map==saved_free,"duplicate error changed ownership");cases=cases+1;
    // Captured commit and error execute on the SAME edge, with the queue full
    // before removal. Test both a sole head and a head with a successor.
    for(j=0;j<2;j=j+1)begin
      reset_store();reserve_message(2048,1);commit_message(5,2048,1,2,1);
      if(j==1)commit_message(5,84,1,2,1);
      take_fragment(5,0,2048);head_a=sch_head;
      port_id=5;length=85;port_type=1;port_depth=j+1;msg_commit=1;
      @(negedge clk);msg_commit=0;done_head=head_a;fragment_error=1;
      @(negedge clk);check(!commit_reject,"same-edge removal/commit spuriously full");fragment_error=0;
      repeat(3)@(negedge clk);
      check(dut.port_count[5]==j+1 && buf_full[5],"same-edge removal/commit queue count/full");
      if(j==1)begin take_fragment(5,0,84);complete_fragment(sch_head,1,92);end
      take_fragment(5,0,85);complete_fragment(sch_head,1,93);
      check((free_map|open_mask)==16'h003f,"same-edge error/commit leaked blocks");cases=cases+1;
    end
    // An error arriving on the COMMIT CAPTURE edge must also retain that commit.
    reset_store();reserve_message(2048,1);commit_message(6,2048,1,2,1);take_fragment(6,0,2048);head_a=sch_head;
    port_id=6;length=86;msg_commit=1;done_head=head_a;fragment_error=1;
    @(negedge clk);msg_commit=0;fragment_error=0;repeat(4)@(negedge clk);
    take_fragment(6,0,86);complete_fragment(sch_head,1,94);
    check((free_map|open_mask)==16'h003f,"error/commit capture lost ownership");cases=cases+1;
    // Pending scheduler request uses the successor after same-edge removal.
    for(j=0;j<2;j=j+1)begin
      reset_store();reserve_message(2048,1);commit_message(7,2048,1,3,1);
      if(j==1)commit_message(7,87,1,3,1);
      take_fragment(7,0,2048);head_a=sch_head;sch_port=7;sch_take=1;
      @(negedge clk);sch_take=0;done_head=head_a;fragment_error=1;
      @(negedge clk);fragment_error=0;
      check(sch_ack==(j==1),"same-edge error/take ACK mismatch");
      if(j==1)begin check(sch_app_length==87,"error/take repeated failed head");complete_fragment(sch_head,1,95);end
      repeat(4)@(negedge clk);check((free_map|open_mask)==16'h003f,"error/take leaked ownership");cases=cases+1;
    end
    // Final (already dequeued) error plus captured commit keeps a queued head.
    reset_store();commit_message(2,88,1,3,1);commit_message(2,89,1,3,1);
    take_fragment(2,0,88);head_a=sch_head;port_id=2;length=90;msg_commit=1;
    @(negedge clk);msg_commit=0;done_head=head_a;fragment_error=1;
    @(negedge clk);fragment_error=0;repeat(3)@(negedge clk);
    take_fragment(2,0,89);complete_fragment(sch_head,1,97);
    take_fragment(2,0,90);complete_fragment(sch_head,1,98);
    check((free_map|open_mask)==16'h003f,"dequeued error/commit lost queue");cases=cases+1;
    // Same-edge reserve cannot reuse the returned chain: with all six blocks
    // owned, reserve fails atomically, then succeeds on a subsequent edge.
    reset_store();reserve_message(8192,1);commit_message(1,8192,1,3,1);
    commit_message(2,91,1,3,1);take_fragment(1,0,8192);head_a=sch_head;
    check(free_map==0 && wr_valid,"reservation collision setup");
    done_head=head_a;fragment_error=1;reserve_length=8192;reserve_valid=1;
    @(negedge clk);fragment_error=0;reserve_valid=0;
    check(reserve_reject && !reservation_active && open_count==1,"reserve reused same-edge return");
    repeat(3)@(negedge clk);reserve_message(8192,1);
    cancel_open=1;@(negedge clk);cancel_open=0;repeat(3)@(negedge clk);
    take_fragment(2,0,91);complete_fragment(sch_head,1,99);
    check((free_map|open_mask)==16'h003f,"error/reserve recovery leaked chain");cases=cases+1;
    // Error wins over a coincident successful completion, once per message.
    reset_store();commit_message(0,92,1,3,1);take_fragment(0,0,92);
    done_head=sch_head;done_last=1;done_next_offset=100;fragment_error=1;fragment_done=1;
    @(negedge clk);fragment_error=0;fragment_done=0;repeat(4)@(negedge clk);
    check(failed_message_count==1 && bad_completion_count==0 && (free_map|open_mask)==16'h003f,"error/done priority/count");cases=cases+1;
    if(errors==0)$display("T81 TX_MESSAGE_STORE PASS cases=%0d checks=%0d",cases,checks);
    else $display("T81 TX_MESSAGE_STORE FAIL errors=%0d checks=%0d",errors,checks);
    $finish;
  end
  initial begin #1000000;$display("T81 TX_MESSAGE_STORE FAIL timeout");$finish;end
endmodule
