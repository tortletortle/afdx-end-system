// Opt-in RX reassembly: independent five-block destinations, immediate scatter.
// No arrival timeout. Source and context ownership survive accepted PMEM jobs.
`timescale 1ns/1ps
module rx_reassembly_chain #(
  parameter integer DW=208,
  parameter integer SLOTS=8,
  parameter integer MAX_FRAGS=8
)(
  input wire clk, rst_sync, en,
  input wire in_vld, output wire in_ready,
  input wire [DW-1:0] in_desc, input wire [11:0] in_vl,
  output wire out_vld, input wire out_ready,
  output reg out_drop, output reg [3:0] out_reason,
  output reg [DW-1:0] out_desc, output reg [11:0] out_vl,
  output reg [13:0] out_app_len,
  output reg [19:0] out_blocks, output reg [2:0] out_block_count,
  output wire alloc_chain, output wire [2:0] alloc_chain_count,
  input wire valid_chain, input wire [19:0] chain_blocks,
  input wire [2:0] chain_count,
  output wire copy_req_valid, input wire copy_req_ready,
  output wire [3:0] copy_src_blk,
  output wire [10:0] copy_src_byte,
  output wire [19:0] copy_dst_blocks, output wire [2:0] copy_dst_count,
  output wire [13:0] copy_dst_byte, copy_len,
  input wire copy_done, copy_error,
  output wire check_req_valid, input wire check_req_ready,
  output wire [3:0] check_blk, output wire [19:0] check_blocks,
  output wire [2:0] check_block_count,
  output wire [13:0] check_app_len,
  output wire [31:0] check_src_ip, check_dst_ip,
  input wire check_done, check_good, input wire [1:0] check_reason,
  output reg free_blk_valid, output reg [3:0] free_blk_id,
  output wire drain_active,
  output reg [31:0] hit_cnt, drop_cnt,
  output wire [31:0] slot_used
);
  localparam [3:0] IDLE=0, ALLOC=1, COPY_REQ=2, COPY_WAIT=3,
    SOURCE_FREE=4, AFTER_COPY=5, CHECK_REQ=6, CHECK_WAIT=7,
    TRIM=8, EMIT=9, RELEASE=10;
  localparam [3:0] E_ALIGN=1,E_SIZE=2,E_SLOT=3,E_OVERLAP=5,
    E_GAP=6,E_FRAGS=7,E_UDP_LEN=8,E_CHECK=9,E_CANCEL=10,E_COPY=11;
  reg [3:0] state;
  reg slot_valid[0:SLOTS-1];
  reg slot_first[0:SLOTS-1], slot_last[0:SLOTS-1];
  reg [31:0] slot_src[0:SLOTS-1],slot_dst[0:SLOTS-1];
  reg [15:0] slot_ident[0:SLOTS-1];
  reg [11:0] slot_vl[0:SLOTS-1];
  // Interval table replaces 8x1024-bit combo bitmap (eLinx MEMORY_COLLECT OOM).
  // Units are 8-byte granules of the reassembled application payload.
  reg [10:0] slot_iv_lo[0:SLOTS-1][0:MAX_FRAGS-1];
  reg [10:0] slot_iv_hi[0:SLOTS-1][0:MAX_FRAGS-1];
  reg [13:0] slot_end[0:SLOTS-1];
  reg [7:0] slot_frags[0:SLOTS-1];
  reg [19:0] slot_blocks[0:SLOTS-1];
  reg [2:0] slot_count[0:SLOTS-1];
  reg [DW-1:0] slot_first_desc[0:SLOTS-1];
  integer active_slot;
  reg [DW-1:0] source_desc;
  reg [11:0] source_vl;
  reg source_owned;
  // True only while this transaction owns a reassembly context.
  // An invalid unmatched fragment and a single-block message own no slot.
  reg active_context;
  reg source_first;
  reg [13:0] source_dst, source_len;
  reg source_reject;
  reg [3:0] reject_reason;
  // Fixed field selects avoid a nested dynamic part-select on a memory word,
  // which the native eLinx frontend cannot lower. Valid indices are 0..4.
  function [3:0] chain_block_at;
    input [19:0] blocks;
    input [3:0] index;
    begin
      case(index)
        4'd0: chain_block_at=blocks[3:0];
        4'd1: chain_block_at=blocks[7:4];
        4'd2: chain_block_at=blocks[11:8];
        4'd3: chain_block_at=blocks[15:12];
        4'd4: chain_block_at=blocks[19:16];
        default: chain_block_at=4'bxxxx;
      endcase
    end
  endfunction
  reg [3:0] release_cursor;
  reg cancel_pending;

  wire is_frag=in_desc[176];
  wire is_first=(in_desc[189:177]==13'd0);
  wire [15:0] wire_start={in_desc[189:177],3'b000};
  wire [15:0] app_start=is_first ? 16'd0 : wire_start-16'd8;
  wire [16:0] app_end={1'b0,app_start}+{6'd0,in_desc[173:163]};
  wire [10:0] frag_plen=in_desc[173:163];
  wire [10:0] new_lo=app_start[13:3];
  wire [10:0] new_hi=(app_end+17'd7)>>3;
  integer hit_slot,empty_slot,scan_i,iv_i,iv_n;
  reg hit_found,empty_found,overlap,beyond_end;
  reg [13:0] merged_end;
  reg merged_first,merged_last;
  reg [3:0] input_reason;
  // slot_used was combo-assigned into an output reg (latch farm). Keep a wire sum.
  assign slot_used = {29'd0,slot_valid[0]} + {29'd0,slot_valid[1]} + {29'd0,slot_valid[2]}
                   + {29'd0,slot_valid[3]} + {29'd0,slot_valid[4]} + {29'd0,slot_valid[5]}
                   + {29'd0,slot_valid[6]} + {29'd0,slot_valid[7]};
  always @* begin
    hit_slot=0;empty_slot=0;hit_found=0;empty_found=0;
    for(scan_i=SLOTS-1;scan_i>=0;scan_i=scan_i-1) begin
      if(slot_valid[scan_i]) begin
        if(slot_src[scan_i]==in_desc[95:64] && slot_dst[scan_i]==in_desc[63:32] &&
           slot_ident[scan_i]==in_desc[207:192] && slot_vl[scan_i]==in_vl) begin
          hit_found=1;hit_slot=scan_i;
        end
      end else begin empty_found=1;empty_slot=scan_i;end
    end
    overlap=0;beyond_end=0;
    merged_first=(hit_found && slot_first[hit_slot]) || is_first;
    merged_last=(hit_found && slot_last[hit_slot]) || !in_desc[191];
    merged_end=(hit_found && slot_last[hit_slot]) ? slot_end[hit_slot] : app_end[13:0];
    iv_n=hit_found ? slot_frags[hit_slot] : 8'd0;
    // Dead 'complete' coverage merge removed: original bitmap path never fed input_reason.
    if(hit_found) begin
      for(iv_i=0;iv_i<MAX_FRAGS;iv_i=iv_i+1) if(iv_i<iv_n) begin
        if(!(new_hi<=slot_iv_lo[hit_slot][iv_i] || new_lo>=slot_iv_hi[hit_slot][iv_i]))
          overlap=1;
        if(slot_iv_hi[hit_slot][iv_i]>new_hi) beyond_end=1;
      end
    end
    input_reason=0;
    if(app_end>17'd8192 || (!is_first && wire_start<16'd8) ||
       (is_first && ({1'b0,frag_plen}+12'd42)>12'd2048) ||
       (!is_first && ({1'b0,frag_plen}+12'd34)>12'd2048)) input_reason=E_SIZE;
    else if(frag_plen==0 || (in_desc[191] && app_end[2:0]!=0)) input_reason=E_ALIGN;
    else if(overlap) input_reason=E_OVERLAP;
    else if(hit_found && slot_frags[hit_slot]>=MAX_FRAGS) input_reason=E_FRAGS;
    else if(hit_found && slot_last[hit_slot] &&
            (app_end>{3'd0,slot_end[hit_slot]} ||
             (!in_desc[191] && app_end!={3'd0,slot_end[hit_slot]}) ||
             (in_desc[191] && app_end=={3'd0,slot_end[hit_slot]}))) input_reason=E_GAP;
    else if(!in_desc[191] && beyond_end) input_reason=E_GAP;
    else if(!hit_found && !empty_found) input_reason=E_SLOT;
  end

  // Coverage of the active slot: first/last plus contiguous sorted intervals.
  integer ready_i;
  reg ready_complete, any_owned;
  reg [10:0] r_cursor,r_need;
  reg [7:0] ready_n;
  always @* begin
    ready_n=slot_frags[active_slot];
    ready_complete=slot_valid[active_slot] && slot_first[active_slot] && slot_last[active_slot]
                 && (ready_n!=0) && (slot_iv_lo[active_slot][0]==11'd0);
    r_need=({3'd0,slot_end[active_slot]}+17'd7)>>3;
    r_cursor=slot_iv_hi[active_slot][0];
    for(ready_i=1;ready_i<MAX_FRAGS;ready_i=ready_i+1) if(ready_i<ready_n) begin
      if(slot_iv_lo[active_slot][ready_i]>r_cursor) ready_complete=0;
      if(slot_iv_hi[active_slot][ready_i]>r_cursor) r_cursor=slot_iv_hi[active_slot][ready_i];
    end
    if(r_cursor<r_need) ready_complete=0;
    any_owned = slot_valid[0]|slot_valid[1]|slot_valid[2]|slot_valid[3]
              | slot_valid[4]|slot_valid[5]|slot_valid[6]|slot_valid[7];
  end
  wire draining=cancel_pending || !en;
  assign drain_active=draining && (any_owned || state!=IDLE);
  assign in_ready=(state==IDLE) && en && !cancel_pending && !rst_sync;
  assign out_vld=(state==EMIT) && en && !cancel_pending && !rst_sync;
  assign alloc_chain=(state==ALLOC) && en && !cancel_pending;
  assign alloc_chain_count=3'd5;
  assign copy_req_valid=(state==COPY_REQ) && !draining;
  assign copy_src_blk=source_desc[162:159];
  assign copy_src_byte=source_first ? 11'd0 : 11'd34;
  assign copy_dst_blocks=slot_blocks[active_slot];
  assign copy_dst_count=slot_count[active_slot];
  assign copy_dst_byte=source_dst;
  assign copy_len=source_len;
  assign check_req_valid=(state==CHECK_REQ) && !draining;
  assign check_blk=slot_blocks[active_slot][3:0];
  assign check_blocks=slot_blocks[active_slot];
  assign check_block_count=slot_count[active_slot];
  assign check_app_len=slot_end[active_slot];
  assign check_src_ip=slot_src[active_slot];
  assign check_dst_ip=slot_dst[active_slot];
  wire [2:0] needed_count=({1'b0,slot_end[active_slot]}+15'd2089)>>11;

  integer reset_i,drain_i,ins_i,ins_pos;
  reg [7:0] ins_cnt;
  reg [3:0] ins_slot;
  always @(posedge clk) begin
    free_blk_valid<=0;
    if(rst_sync) begin
      state<=IDLE;active_slot<=0;source_owned<=0;active_context<=0;cancel_pending<=0;
      source_desc<=0;source_vl<=0;source_first<=0;source_dst<=0;source_len<=0;
      source_reject<=0;reject_reason<=0;release_cursor<=0;
      out_drop<=0;out_reason<=0;out_desc<=0;out_vl<=0;
      out_app_len<=0;out_blocks<=0;out_block_count<=0;
      free_blk_id<=0;hit_cnt<=0;drop_cnt<=0;
      for(reset_i=0;reset_i<SLOTS;reset_i=reset_i+1) begin
        slot_valid[reset_i]<=0;slot_first[reset_i]<=0;slot_last[reset_i]<=0;
        slot_src[reset_i]<=0;slot_dst[reset_i]<=0;slot_ident[reset_i]<=0;
        slot_vl[reset_i]<=0;slot_end[reset_i]<=0;
        slot_frags[reset_i]<=0;slot_blocks[reset_i]<=0;slot_count[reset_i]<=0;
        slot_first_desc[reset_i]<=0;
        // Do not clear slot_iv_* here: nested SLOTS*MAX_FRAGS resets blow
        // eLinx MEMORY_COLLECT. slot_valid/slot_frags=0 hide stale intervals.
      end
    end else begin
      if(!en) cancel_pending<=1;
      case(state)
        IDLE: begin
          if(draining) begin
            if(!any_owned) cancel_pending<=0;
            else begin
              for(drain_i=SLOTS-1;drain_i>=0;drain_i=drain_i-1)
                if(slot_valid[drain_i]) active_slot<=drain_i;
              active_context<=1;release_cursor<=0;state<=RELEASE;
              drop_cnt<=drop_cnt+32'd1;
            end
          end else if(in_vld && in_ready) begin
            source_desc<=in_desc;source_vl<=in_vl;source_owned<=1;active_context<=0;
            source_first<=is_first;
            source_dst<=is_first ? 14'd0 : 14'd34+wire_start[13:0];
            source_len<=is_first ? 14'd42+{3'd0,frag_plen} : {3'd0,frag_plen};
            out_drop<=0;out_reason<=0;
            if(!is_frag) begin
              out_desc<=in_desc;out_vl<=in_vl;out_app_len<={3'd0,frag_plen};
              out_blocks<={16'd0,in_desc[162:159]};out_block_count<=1;
              state<=EMIT;
            end else if(input_reason!=0) begin
              source_reject<=1;reject_reason<=input_reason;
              active_slot<=hit_found ? hit_slot : empty_slot;
              active_context<=hit_found;
              // A missing matching context must never release another context.
              if(!hit_found) begin source_reject<=0; end
              state<=SOURCE_FREE;drop_cnt<=drop_cnt+32'd1;
              out_drop<=1;out_reason<=input_reason;
            end else begin
              active_slot<=hit_found ? hit_slot : empty_slot;active_context<=1;
              slot_valid[hit_found ? hit_slot : empty_slot]<=1;
              slot_first[hit_found ? hit_slot : empty_slot]<=merged_first;
              slot_last[hit_found ? hit_slot : empty_slot]<=merged_last;
              // Keep intervals sorted by lo so combo coverage stays a linear walk.
              ins_slot=hit_found ? hit_slot : empty_slot;
              ins_cnt=hit_found ? slot_frags[hit_slot] : 0;
              ins_pos=ins_cnt;
              for(ins_i=MAX_FRAGS-1;ins_i>=0;ins_i=ins_i-1)
                if(ins_i<ins_cnt && slot_iv_lo[ins_slot][ins_i]>new_lo) ins_pos=ins_i;
              for(ins_i=MAX_FRAGS-2;ins_i>=0;ins_i=ins_i-1)
                if(ins_i<ins_cnt && ins_i>=ins_pos) begin
                  slot_iv_lo[ins_slot][ins_i+1]<=slot_iv_lo[ins_slot][ins_i];
                  slot_iv_hi[ins_slot][ins_i+1]<=slot_iv_hi[ins_slot][ins_i];
                end
              slot_iv_lo[ins_slot][ins_pos]<=new_lo;
              slot_iv_hi[ins_slot][ins_pos]<=new_hi;
              slot_end[hit_found ? hit_slot : empty_slot]<=merged_end;
              slot_frags[hit_found ? hit_slot : empty_slot]<=hit_found ? slot_frags[hit_slot]+8'd1 : 8'd1;
              if(is_first) slot_first_desc[hit_found ? hit_slot : empty_slot]<=in_desc;
              source_reject<=0;
              if(hit_found) state<=COPY_REQ;
              else begin
                slot_src[empty_slot]<=in_desc[95:64];slot_dst[empty_slot]<=in_desc[63:32];
                slot_ident[empty_slot]<=in_desc[207:192];slot_vl[empty_slot]<=in_vl;
                slot_count[empty_slot]<=0;slot_blocks[empty_slot]<=0;
                state<=ALLOC;
              end
            end
          end
        end
        ALLOC: begin
          if(draining) begin source_reject<=1;state<=SOURCE_FREE;end
          else if(valid_chain && chain_count==3'd5) begin
            slot_blocks[active_slot]<=chain_blocks;slot_count[active_slot]<=chain_count;
            state<=COPY_REQ;
          end else begin
            source_reject<=1;reject_reason<=E_SLOT;out_drop<=1;out_reason<=E_SLOT;
            drop_cnt<=drop_cnt+32'd1;state<=SOURCE_FREE;
          end
        end
        COPY_REQ: begin
          if(draining) begin source_reject<=1;state<=SOURCE_FREE;end
          else if(copy_req_valid && copy_req_ready) state<=COPY_WAIT;
        end
        COPY_WAIT: if(copy_done) begin
          if(copy_error || draining) begin
            source_reject<=1;reject_reason<=copy_error ? E_COPY : E_CANCEL;
            if(copy_error && !draining) begin drop_cnt<=drop_cnt+32'd1;out_drop<=1;out_reason<=E_COPY;end
          end
          state<=SOURCE_FREE;
        end
        SOURCE_FREE: begin
          if(source_owned) begin free_blk_valid<=1;free_blk_id<=source_desc[162:159];source_owned<=0;end
          if((source_reject || draining) && active_context) begin release_cursor<=0;state<=RELEASE;end
          else if(!active_context || out_drop) state<=IDLE;
          else state<=AFTER_COPY;
        end
        AFTER_COPY: begin
          if(draining) begin release_cursor<=0;state<=RELEASE;end
          else if(ready_complete) state<=CHECK_REQ;
          else state<=IDLE;
        end
        CHECK_REQ: begin
          if(draining) begin release_cursor<=0;state<=RELEASE;end
          else if(check_req_valid && check_req_ready) state<=CHECK_WAIT;
        end
        CHECK_WAIT: if(check_done) begin
          if(draining || !check_good) begin
            if(!draining) begin
              out_drop<=1;out_reason<=check_reason==2'd1 ? E_UDP_LEN : E_CHECK;
              drop_cnt<=drop_cnt+32'd1;
            end
            release_cursor<=0;state<=RELEASE;
          end else begin
            out_desc<=slot_first_desc[active_slot];out_vl<=slot_vl[active_slot];
            out_desc[173:163]<=slot_end[active_slot][10:0];
            out_desc[162:159]<=slot_blocks[active_slot][3:0];
            out_app_len<=slot_end[active_slot];out_blocks<=slot_blocks[active_slot];
            out_block_count<=needed_count;out_drop<=0;out_reason<=0;
            release_cursor<={1'b0,needed_count};state<=TRIM;
          end
        end
        TRIM: begin
          if(draining) begin release_cursor<=0;state<=RELEASE;end
          else if(slot_count[active_slot]>needed_count) begin
            // Trim from the tail and reduce ownership immediately. A disable
            // during trim must not return an already released tail twice.
            free_blk_valid<=1;free_blk_id<=chain_block_at(slot_blocks[active_slot],{1'b0,slot_count[active_slot]}-4'd1);
            slot_count[active_slot]<=slot_count[active_slot]-3'd1;
          end else state<=EMIT;
        end
        EMIT: begin
          if(draining) begin
            if(active_context) begin release_cursor<=0;state<=RELEASE;end
            else begin out_drop<=1;source_reject<=0;state<=SOURCE_FREE;end
          end else if(out_vld && out_ready) begin
            if(active_context) slot_valid[active_slot]<=0;
            active_context<=0;source_owned<=0;
            hit_cnt<=hit_cnt+32'd1;state<=IDLE;
          end
        end
        RELEASE: begin
          if(slot_valid[active_slot] && release_cursor<slot_count[active_slot]) begin
            free_blk_valid<=1;free_blk_id<=chain_block_at(slot_blocks[active_slot],release_cursor);
            release_cursor<=release_cursor+4'd1;
          end else begin
            slot_valid[active_slot]<=0;slot_count[active_slot]<=0;
            source_reject<=0;active_context<=0;state<=IDLE;
          end
        end
        default: state<=IDLE;
      endcase
    end
  end
endmodule
