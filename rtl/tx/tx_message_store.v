// Complete-message TX ownership and per-port FIFO, separate from payload chains.
// Six 2KiB TX blocks, at most four blocks per message (8192 application bytes).
// A take grants exactly one IP fragment. Non-final grants keep the queue head;
// the final grant dequeues it, but its blocks remain owned until fragment_done.
// AFDX_top selects this store with TX_MESSAGE_CHAIN_BLOCKS=4.
`timescale 1 ns / 1 ps
module tx_message_store #(
  parameter integer NUM_PORTS=256
) (
  input wire clk, rst_sync,
  input wire [7:0] tb_us,
  input wire reserve_valid,
  input wire [13:0] reserve_length,
  output wire reserve_ready,
  output reg reserve_reject,
  input wire cancel_open,
  output wire [3:0] wr_blk,
  output wire wr_valid,
  output reg [15:0] open_blocks,
  output reg [2:0] open_count,
  output reg [13:0] open_length,
  output reg reservation_active,
  output wire [15:0] open_mask,
  input wire msg_commit,
  input wire [7:0] port_id,
  input wire [15:0] length,
  input wire [1:0] port_type,
  input wire [3:0] port_depth,
  output reg commit_reject,
  input wire [7:0] desc_rd_addr,
  output reg [31:0] desc_rd_data,
  output wire [NUM_PORTS-1:0] sch_req, buf_full,
  input wire sch_take,
  input wire [7:0] sch_port,
  output reg sch_ack,
  output reg [3:0] sch_head,
  output reg [12:0] sch_length,
  output reg [13:0] sch_app_length, sch_fragment_offset,
  output reg [15:0] sch_blocks, sch_identification,
  output reg [2:0] sch_block_count,
  // Done means staged fragment EOF accepted by the next consumer. For a final
  // fragment that consumer owns its complete bytes, independent of PMEM.
  input wire fragment_done,
  // Error has priority over done. Only the currently in-flight head is valid;
  // return its entire chain, removing its FIFO node only if not yet dequeued.
  input wire fragment_error,
  input wire [3:0] done_head,
  input wire done_last,
  input wire [13:0] done_next_offset,
  output reg [15:0] free_map,
  output reg [15:0] overwrite_count, queue_overflow_count, exhaust_count,
  output reg [15:0] bad_completion_count, failed_message_count,
  output reg pending
);
  reg [NUM_PORTS-1:0] port_valid, port_full, port_sampling, port_fresh;
  reg [3:0] port_head [0:NUM_PORTS-1];
  reg [3:0] port_tail [0:NUM_PORTS-1];
  reg [3:0] port_count [0:NUM_PORTS-1];
  reg [7:0] port_age [0:NUM_PORTS-1];
  reg [15:0] message_blocks [0:5];
  reg [15:0] message_mask [0:5];
  reg [13:0] message_length [0:5];
  reg [2:0] message_count [0:5];
  reg [13:0] message_offset [0:5];
  reg [15:0] message_ident [0:5];
  reg [3:0] queue_next [0:5];
  reg [5:0] message_valid, message_inflight, message_dequeued;
  reg [7:0] message_port [0:5];
  reg [15:0] next_ident;
  reg open_valid;
  reg [15:0] open_owned_mask;
  assign wr_valid=open_valid && !rst_sync;
  assign wr_blk=open_blocks[3:0];
  assign open_mask=rst_sync ? 16'd0 : open_owned_mask;
  assign buf_full=port_full;
  // This eLinx frontend cannot index packed bits directly with a memory
  // read expression. A fixed mux retains the six valid heads and X for an
  // out-of-pool head without an unsupported nested dynamic range select.
  function inflight_at;
    input [5:0] bits;
    input [3:0] id;
    begin
      case(id)
        0:inflight_at=bits[0];1:inflight_at=bits[1];2:inflight_at=bits[2];
        3:inflight_at=bits[3];4:inflight_at=bits[4];5:inflight_at=bits[5];
        default:inflight_at=1'bx;
      endcase
    end
  endfunction
  genvar gp;
  generate for(gp=0;gp<NUM_PORTS;gp=gp+1) begin: g_requests
    assign sch_req[gp]=port_valid[gp] && !inflight_at(message_inflight,port_head[gp]) && !rst_sync;
  end endgenerate
  wire [3:0] descriptor_head=port_head[desc_rd_addr];
  wire [13:0] descriptor_length=message_length[descriptor_head];

  reg take_pending;
  reg [7:0] pending_port;
  reg request_valid, request_commit, request_open_valid, request_reserved;
  reg [7:0] request_port, request_age;
  reg [15:0] request_blocks, request_mask, request_length;
  reg [2:0] request_count;
  reg [13:0] request_reserved_length;
  reg [1:0] request_type;
  reg [3:0] request_depth;
  wire take_now=take_pending || (sch_take && !msg_commit);
  assign reserve_ready=!rst_sync && open_valid && !reservation_active &&
                        !request_valid && !msg_commit && !sch_take && !take_pending;

  function [3:0] first_block;
    input [15:0] mask;
    integer k;
    begin
      first_block=0;
      for(k=5;k>=0;k=k-1) if(mask[k]) first_block=k;
    end
  endfunction
  function [15:0] chain_mask;
    input [15:0] blocks;
    input [2:0] count;
    integer k;
    reg [3:0] id;
    begin
      chain_mask=0;
      for(k=0;k<4;k=k+1) begin
        case(k)
          0:id=blocks[3:0]; 1:id=blocks[7:4]; 2:id=blocks[11:8]; default:id=blocks[15:12];
        endcase
        if(k<count) chain_mask=chain_mask | (16'd1 << id);
      end
    end
  endfunction
  function [10:0] fragment_length;
    input [13:0] len, offset;
    reg [14:0] remaining;
    begin
      remaining={1'b0,len}+15'd8-{1'b0,offset};
      fragment_length=remaining>15'd1479 ? 11'd1472 : remaining[10:0];
    end
  endfunction
  function [15:0] increment;
    input [15:0] value;
    begin increment=value==16'hffff ? value : value+16'd1; end
  endfunction

  // Reservation picks from the prior free map atomically; a same-edge return
  // becomes available on a later edge. No partial reservation can escape.
  reg [15:0] reserve_available, reserve_blocks, reserve_mask;
  reg [3:0] reserve_id;
  reg [2:0] reserve_count;
  reg reserve_ok;
  integer ri;
  always @* begin
    reserve_count=(reserve_length+14'd2047)>>11;
    reserve_available=free_map;
    reserve_blocks={12'd0,open_blocks[3:0]};
    reserve_mask=open_owned_mask;
    reserve_id=0;
    reserve_ok=reserve_length>=1 && reserve_length<=8192 && reserve_count>=1 && reserve_count<=4;
    for(ri=1;ri<4;ri=ri+1) if(ri<reserve_count) begin
      if(reserve_available==0) reserve_ok=0;
      else begin
        reserve_id=first_block(reserve_available);
        case(ri)
          1:reserve_blocks[7:4]=reserve_id;
          2:reserve_blocks[11:8]=reserve_id;
          default:reserve_blocks[15:12]=reserve_id;
        endcase
        reserve_mask=reserve_mask | (16'd1<<reserve_id);
        reserve_available=reserve_available & ~(16'd1<<reserve_id);
      end
    end
  end

  // eLinx's Verilog frontend does not support declarations inside an
  // unnamed procedural block. These blocking-assignment helpers are assigned
  // before use on each active path; they are not additional pipeline stages.
  reg [15:0] returned_mask;
  reg [3:0] head, tail, count, old_head;
  reg [10:0] selected_length;
  reg [14:0] selected_end;
  reg accept_commit, reject_full, complete_ok;
  reg error_remove;
  reg [7:0] error_port;
  reg [3:0] error_head, error_tail, error_count;
  integer i;
  always @(posedge clk) begin

    reserve_reject<=0; commit_reject<=0; sch_ack<=0; pending<=0;
    if(rst_sync) begin
      port_valid<=0; port_full<=0; port_sampling<=0; port_fresh<=0;
      message_valid<=0; message_inflight<=0; message_dequeued<=0; next_ident<=0;
      free_map<=16'h003f; open_valid<=0; open_owned_mask<=0;
      open_blocks<=0; open_count<=0; open_length<=0; reservation_active<=0;
      take_pending<=0; pending_port<=0; request_valid<=0; request_commit<=0;
      request_open_valid<=0; request_reserved<=0; request_port<=0; request_age<=0;
      request_blocks<=0; request_mask<=0; request_length<=0; request_count<=0;
      request_reserved_length<=0; request_type<=0; request_depth<=1;
      desc_rd_data<=0; sch_head<=0; sch_length<=0; sch_app_length<=0;
      sch_fragment_offset<=0; sch_blocks<=0; sch_identification<=0; sch_block_count<=0;
      overwrite_count<=0; queue_overflow_count<=0; exhaust_count<=0; bad_completion_count<=0; failed_message_count<=0;
      for(i=0;i<NUM_PORTS;i=i+1) begin port_head[i]<=0;port_tail[i]<=0;port_count[i]<=0;port_age[i]<=0;end
      // Only validity bits are reset for message arrays.
    end else begin
      returned_mask=0;
      error_remove=0; error_port=0; error_head=0; error_tail=0; error_count=0;
      // TX descriptor preserves legacy field positions. Length bit13 is in
      // formerly reserved bit28; low13 bits remain at descriptor[20:8].
      if(desc_rd_addr<NUM_PORTS && port_valid[desc_rd_addr])
        desc_rd_data<={3'd0,descriptor_length[13],1'b1,
                       port_full[desc_rd_addr],port_fresh[desc_rd_addr],port_head[desc_rd_addr],
                       descriptor_length[12:0],port_age[desc_rd_addr]};
      else desc_rd_data<=0;

      if(fragment_error) begin
        complete_ok=0;
        if(done_head<6 && message_valid[done_head] && message_inflight[done_head]) begin
          if(message_dequeued[done_head]) complete_ok=1;
          else if(message_port[done_head]<NUM_PORTS) begin
            error_port=message_port[done_head];
            complete_ok=port_valid[error_port] && port_count[error_port]!=0 &&
                        port_head[error_port]==done_head;
            if(complete_ok) begin
              error_remove=1;
              error_head=queue_next[done_head]; error_tail=port_tail[error_port];
              error_count=port_count[error_port]-4'd1;
              port_head[error_port]<=error_head; port_count[error_port]<=error_count;
              port_valid[error_port]<=error_count!=0;
              port_full[error_port]<=0; port_fresh[error_port]<=0;
            end
          end
        end
        if(complete_ok) begin
          returned_mask=returned_mask | message_mask[done_head];
          message_valid[done_head]<=0; message_inflight[done_head]<=0;
          message_dequeued[done_head]<=0;
          failed_message_count<=increment(failed_message_count);
        end else bad_completion_count<=increment(bad_completion_count);
      end else if(fragment_done) begin
        complete_ok=0;
        if(done_head<6 && message_valid[done_head] && message_inflight[done_head]) begin
          selected_end={1'b0,message_offset[done_head]}+{4'd0,fragment_length(message_length[done_head],message_offset[done_head])};
          complete_ok=({1'b0,done_next_offset}==selected_end) &&
                      (done_last==(selected_end=={1'b0,message_length[done_head]}+15'd8));
        end
        if(complete_ok) begin
          message_inflight[done_head]<=0;
          if(done_last) begin
            returned_mask=returned_mask | message_mask[done_head];
            message_valid[done_head]<=0; message_dequeued[done_head]<=0;
          end else message_offset[done_head]<=done_next_offset;
        end else bad_completion_count<=increment(bad_completion_count);
      end

      if(request_valid) begin
        head=0;tail=0;count=0;
        if(request_port<NUM_PORTS && port_valid[request_port]) begin
          head=port_head[request_port];tail=port_tail[request_port];count=port_count[request_port];
        end
        // Fold a same-edge head removal into the request before updating FIFO
        // state. Captured commits and takes are never dropped or replayed.
        if(error_remove && request_port==error_port) begin
          head=error_head; tail=error_tail; count=error_count;
        end
        if(request_commit) begin
          reject_full=request_type!=0 && count>=request_depth;
          accept_commit=request_open_valid && request_port<NUM_PORTS &&
                        request_length>=1 && request_length<=8192 &&
                        request_count==((request_length+16'd2047)>>11) &&
                        (!request_reserved || request_reserved_length==request_length) &&
                        request_type!=3 && (request_type==1 || request_length<=1471) &&
                        // A queued chain cannot become a sampling head: that
                        // would orphan its successors or an in-flight fragment.
                        (count==0 || port_sampling[request_port]==(request_type==0)) && !reject_full;
          if(accept_commit) begin
            old_head=request_blocks[3:0];
            message_valid[old_head]<=1; message_inflight[old_head]<=0;
            message_dequeued[old_head]<=0; message_port[old_head]<=request_port;
            message_blocks[old_head]<=request_blocks; message_mask[old_head]<=request_mask;
            message_length[old_head]<=request_length[13:0]; message_count[old_head]<=request_count;
            message_offset[old_head]<=0; message_ident[old_head]<=0;
            queue_next[old_head]<=0;
            port_sampling[request_port]<=request_type==0;
            port_age[request_port]<=request_age;
            if(request_type==0 || count==0) begin
              if(request_type==0 && count!=0) begin
                // Sampling messages are single-fragment; in-flight messages
                // have already dequeued, so this is an unscheduled old head.
                returned_mask=returned_mask | message_mask[head];
                message_valid[head]<=0;
                overwrite_count<=increment(overwrite_count);
              end
              port_head[request_port]<=old_head;port_tail[request_port]<=old_head;
              port_count[request_port]<=1;port_valid[request_port]<=1;
              port_full[request_port]<=request_type!=0 && request_depth==1;
              port_fresh[request_port]<=request_type==0 && count!=0;
            end else begin
              queue_next[tail]<=old_head;port_tail[request_port]<=old_head;
              port_count[request_port]<=count+4'd1;
              port_full[request_port]<=count+4'd1>=request_depth;
            end
          end else begin
            commit_reject<=1;
            if(request_open_valid) returned_mask=returned_mask | request_mask;
            if(reject_full) begin queue_overflow_count<=increment(queue_overflow_count);port_full[request_port]<=1;end
            else exhaust_count<=increment(exhaust_count);
          end
        end else if(count!=0 && !message_inflight[head]) begin
          selected_length=fragment_length(message_length[head],message_offset[head]);
          selected_end={1'b0,message_offset[head]}+{4'd0,selected_length};
          sch_ack<=1; sch_head<=head; sch_length<={2'd0,selected_length};
          sch_app_length<=message_length[head]; sch_fragment_offset<=message_offset[head];
          sch_blocks<=message_blocks[head];sch_block_count<=message_count[head];
          message_inflight[head]<=1;
          message_dequeued[head]<=selected_end=={1'b0,message_length[head]}+15'd8;
          if(message_offset[head]==0) begin
            message_ident[head]<=next_ident;sch_identification<=next_ident;next_ident<=next_ident+16'd1;
          end else sch_identification<=message_ident[head];
          if(selected_end=={1'b0,message_length[head]}+15'd8) begin
            port_count[request_port]<=count-4'd1;port_full[request_port]<=0;port_fresh[request_port]<=0;
            if(count==1) port_valid[request_port]<=0;
            else port_head[request_port]<=queue_next[head];
          end
        end
      end

      // Capture one request. Commit has priority; a coincident take is retained.
      request_valid<=msg_commit || take_now;
      request_commit<=msg_commit;
      request_port<=msg_commit ? port_id : (take_pending ? pending_port : sch_port);
      request_open_valid<=open_valid;
      request_blocks<=open_blocks;request_mask<=open_owned_mask;request_count<=open_count;
      request_length<=length;request_reserved<=reservation_active;request_reserved_length<=open_length;
      request_type<=port_type;request_depth<=port_depth==0 ? 4'd1 : port_depth;request_age<=tb_us;
      if(msg_commit && sch_take && !take_pending) begin take_pending<=1;pending_port<=sch_port;pending<=1;end
      else if(take_pending && !msg_commit) take_pending<=0;

      if(reserve_valid && reserve_ready) begin
        if(reserve_ok) begin
          open_blocks<=reserve_blocks;open_count<=reserve_count;open_length<=reserve_length;
          open_owned_mask<=reserve_mask;reservation_active<=1;
          free_map<=(free_map | returned_mask) & ~reserve_mask;
        end else begin reserve_reject<=1;free_map<=free_map | returned_mask;exhaust_count<=increment(exhaust_count);end
      end else if(cancel_open && !msg_commit && !request_valid) begin
        free_map<=free_map | returned_mask | open_owned_mask;
        open_valid<=0;open_owned_mask<=0;open_count<=0;open_length<=0;reservation_active<=0;
      end else if(!open_valid || msg_commit) begin
        open_length<=0;reservation_active<=0;
        if(free_map!=0) begin
          open_blocks<={12'd0,first_block(free_map)};open_count<=1;open_valid<=1;
          open_owned_mask<=16'd1<<first_block(free_map);
          free_map<=(free_map | returned_mask) & ~(16'd1<<first_block(free_map));
        end else begin
          open_valid<=0;open_count<=0;open_owned_mask<=0;
          free_map<=free_map | returned_mask;
        end
      end else free_map<=free_map | returned_mask;
    end
  end
endmodule
