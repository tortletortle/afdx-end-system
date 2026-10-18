// SAP chain mode: fixed raw Ethernet/IPv4/UDP layout, network byte order.
// One PMEM read is outstanding at a time.  A granted read is captured on
// the next rising edge; the head is returned only after the final capture.
// The top side table expands this one head return into the ownership mask.
// PBUF_W in the parent remains a legacy-only setting.  This buffer holds
// ceil((18 + 8192) / 4) = 2053 words beginning at logical raw word 6.

`timescale 1 ns / 1 ps
module mgmt_sap_rx_chain (
  input  wire        clk,
  input  wire        rst_sync,
  input  wire        in_vld,
  output wire        in_ready,
  input  wire [7:0]  in_port,
  input  wire [3:0]  in_blk,
  input  wire [10:0] in_plen,
  input  wire [13:0] in_app_len,
  input  wire [19:0] in_blocks,
  input  wire [2:0]  in_block_count,
  output wire        pm_req,
  output wire [12:0] pm_addr,
  input  wire        pm_gnt,
  input  wire [31:0] pm_data,
  output reg         out_vld,
  output reg         out_sop,
  output reg         out_eop,
  output reg  [7:0]  out_data,
  output reg  [15:0] out_sport,
  output reg  [15:0] out_dport,
  output reg  [31:0] out_srcip,
  output reg  [10:0] out_plen,
  output reg  [13:0] out_app_len,
  input  wire        out_ready,
  output wire        free_req,
  input  wire        free_take,
  output wire [3:0]  free_id,
  output reg  [31:0] accept_cnt,
  output reg  [31:0] free_cnt,
  output reg  [31:0] last_desc,
  output reg  [31:0] pay_cnt,
  output reg  [31:0] trunc_cnt
);
  localparam [2:0] S_IDLE = 3'd0, S_READ = 3'd1, S_CAPTURE = 3'd2,
                   S_STREAM = 3'd3, S_WAIT = 3'd4;
  localparam integer PBUF_WORDS = 2053;
  localparam [11:0] W_START = 12'd6;
  localparam [13:0] PAY_OFF = 14'd42;

  reg [31:0] pbuf [0:PBUF_WORDS-1];
  reg [2:0]  st;
  reg [3:0]  pending_blk;
  reg [19:0] pending_blocks;
  reg [2:0]  pending_block_count;
  reg [11:0] wa, wp, wlast;
  reg [13:0] bcur, blast;
  reg        freed;

  wire [2:0] slot = wa[11:9];
  wire [3:0] physical_blk = pending_blocks[slot*4 +: 4];
  wire [13:0] rel = bcur - 14'd24;
  wire [31:0] wsel = pbuf[rel[13:2]];
  wire [7:0] bsel = (rel[1:0] == 2'd0) ? wsel[31:24] :
                    (rel[1:0] == 2'd1) ? wsel[23:16] :
                    (rel[1:0] == 2'd2) ? wsel[15:8] : wsel[7:0];
  wire [14:0] accepted_last_byte = 15'd41 + {1'b0, in_app_len};

  assign in_ready = !rst_sync && (st == S_IDLE);
  assign pm_req = !rst_sync && (st == S_READ);
  assign pm_addr = {physical_blk, wa[8:0]};
  assign free_req = !rst_sync && !freed &&
                    ((st == S_STREAM) || (st == S_WAIT));
  assign free_id = pending_blk;

  // Only active slots are validated.  Unused tail nibbles are ignored.
  // Widths explicitly cover 42+16383 and 5*2048 without wraparound.
  function descriptor_ok;
    input [3:0] head;
    input [13:0] app_len;
    input [19:0] blocks;
    input [2:0] block_count;
    reg [14:0] raw_bytes, capacity;
    reg [3:0] id_i, id_j;
    integer i, j;
    begin
      raw_bytes = 15'd42 + {1'b0, app_len};
      capacity = {1'b0, block_count, 11'd0};
      descriptor_ok = 1'b1;
      if ((app_len > 14'd8192) || (block_count < 3'd1) ||
          (block_count > 3'd5) || (head != blocks[3:0]) ||
          (raw_bytes > capacity)) descriptor_ok = 1'b0;
      for (i = 0; i < 5; i = i + 1) begin
        if (i < block_count) begin
          id_i = blocks[i*4 +: 4];
          if (id_i < 4'd6) descriptor_ok = 1'b0;
          for (j = 0; j < 5; j = j + 1) begin
            if (j < i) begin
              id_j = blocks[j*4 +: 4];
              if (id_i == id_j) descriptor_ok = 1'b0;
            end
          end
        end
      end
    end
  endfunction

  always @(posedge clk) begin
    if (rst_sync) begin
      st <= S_IDLE;
      pending_blk <= 4'd0; pending_blocks <= 20'd0;
      pending_block_count <= 3'd0;
      wa <= 12'd0; wp <= 12'd0; wlast <= 12'd0;
      bcur <= 14'd0; blast <= 14'd0; freed <= 1'b0;
      out_vld <= 1'b0; out_sop <= 1'b0; out_eop <= 1'b0;
      out_data <= 8'd0; out_sport <= 16'd0; out_dport <= 16'd0;
      out_srcip <= 32'd0; out_plen <= 11'd0; out_app_len <= 14'd0;
      accept_cnt <= 32'd0; free_cnt <= 32'd0; last_desc <= 32'd0;
      pay_cnt <= 32'd0; trunc_cnt <= 32'd0;
    end else begin
      out_vld <= 1'b0; out_sop <= 1'b0; out_eop <= 1'b0;
      if (free_req && free_take) begin
        freed <= 1'b1;
        free_cnt <= free_cnt + 32'd1;
      end
      case (st)
        S_IDLE: if (in_vld && in_ready) begin
          pending_blk <= in_blk;
          pending_blocks <= in_blocks;
          pending_block_count <= in_block_count;
          out_app_len <= in_app_len;
          out_plen <= in_app_len[10:0];
          accept_cnt <= accept_cnt + 32'd1;
          // Preserve the legacy diagnostic layout with the 11-bit projection.
          last_desc <= {1'b1, 8'd0, in_port, in_blk, in_app_len[10:0]};
          out_sport <= 16'd0; out_dport <= 16'd0; out_srcip <= 32'd0;
          wa <= W_START; wp <= 12'd0;
          wlast <= accepted_last_byte[13:2];
          bcur <= 14'd24; blast <= accepted_last_byte[13:0];
          freed <= 1'b0;
          if (descriptor_ok(in_blk, in_app_len, in_blocks, in_block_count))
            st <= S_READ;
          else begin
            // Reject atomically: no PMEM read and no successful byte stream.
            // The owner still returns the descriptor head through the side table.
            trunc_cnt <= trunc_cnt + 32'd1;
            st <= S_WAIT;
          end
        end
        S_READ: if (pm_req && pm_gnt) st <= S_CAPTURE;
        S_CAPTURE: begin
          pbuf[wp] <= pm_data;
          if (wa == wlast) st <= S_STREAM;
          else begin
            wa <= wa + 12'd1;
            wp <= wp + 12'd1;
            st <= S_READ;
          end
        end
        S_STREAM: begin
          if (!(out_vld && !out_ready)) begin
            case (bcur)
              14'd26, 14'd27, 14'd28, 14'd29:
                out_srcip <= {out_srcip[23:0], bsel};
              14'd34, 14'd35: out_sport <= {out_sport[7:0], bsel};
              14'd36, 14'd37: out_dport <= {out_dport[7:0], bsel};
              default: ;
            endcase
            out_data <= bsel;
            if (bcur >= PAY_OFF) begin
              out_vld <= 1'b1;
              out_sop <= (bcur == PAY_OFF);
              out_eop <= (bcur == blast);
              // Count newly presented payload bytes, once per byte, like legacy.
              pay_cnt <= pay_cnt + 32'd1;
            end
            bcur <= bcur + 14'd1;
            if (bcur == blast) st <= S_WAIT;
          end else begin
            out_vld <= 1'b1; out_sop <= out_sop; out_eop <= out_eop;
          end
        end
        S_WAIT: begin
          if (out_vld && !out_ready) begin
            out_vld <= 1'b1; out_sop <= out_sop; out_eop <= out_eop;
          end else if (freed) st <= S_IDLE;
        end
        default: st <= S_IDLE;
      endcase
    end
  end
endmodule
