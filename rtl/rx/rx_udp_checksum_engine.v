// Standalone checksum walker for a reassembled UDP datagram in RX PMEM.
// Reads raw Ethernet byte 34 onward, one aligned PMEM word at a time.
`timescale 1 ns / 1 ps
module rx_udp_checksum_engine #(
  parameter integer CHAIN_ENABLE = 0
) (
  input wire clk,
  input wire rst_sync,
  input wire job_valid,
  output wire job_ready,
  input wire [3:0] job_blk,
  input wire [13:0] job_app_len,
  input wire [31:0] job_src_ip,
  input wire [31:0] job_dst_ip,
  input wire job_check_en,
  output wire rd_req,
  output wire [12:0] rd_addr,
  input wire rd_grant,
  input wire rd_valid,
  input wire [31:0] rd_data,
  output reg done,
  output reg good,
  output reg [1:0] reason,
  // Used only with CHAIN_ENABLE != 0; slot 0 is job_blk.
  input wire [19:0] job_blocks,
  input wire [2:0] job_block_count
);
  localparam [2:0] S_IDLE=3'd0, S_REQ=3'd1, S_RESP=3'd2,
                   S_CONSUME=3'd3, S_FINISH=3'd4;
  reg [2:0] state;
  reg [3:0] blk_q;
  reg [14:0] udp_len_q;
  reg check_q;
  reg [14:0] byte_pos;
  reg [13:0] raw_byte;
  reg [31:0] word_q;
  reg [2:0] lane_q;
  reg [31:0] sum_q;
  reg [15:0] udp_len_field;
  reg [15:0] udp_checksum_field;
  reg [1:0] err_q;
  reg outstanding;

  assign job_ready = (state == S_IDLE);
  assign rd_req = (state == S_REQ) && !outstanding;
  wire [3:0] read_blk;
  wire job_invalid;
  assign rd_addr = {read_blk, raw_byte[10:2]};

  generate
    if (CHAIN_ENABLE != 0) begin : g_chain
      reg [19:0] blocks_q;
      reg chain_ok;
      reg chain_invalid;
      integer i, j;
      wire [14:0] frame_bytes = {1'b0,job_app_len} + 15'd42;
      wire [14:0] capacity_bytes = {1'b0,job_block_count,11'd0};

      // Validate all advertised slots, including ones beyond the UDP end.
      // The 4-bit physical IDs have an implicit upper bound of 15.
      always @* begin
        chain_ok = (job_block_count >= 3'd1) && (job_block_count <= 3'd5) &&
                   (job_blocks[3:0] == job_blk) &&
                   (job_app_len <= 14'd8192) && (frame_bytes <= capacity_bytes);
        for (i = 0; i < 5; i = i + 1) begin
          if (i < job_block_count) begin
            chain_ok = chain_ok && (job_blocks[i*4 +: 4] >= 4'd6);
            for (j = 0; j < 5; j = j + 1) begin
              if (j < i)
                chain_ok = chain_ok &&
                           (job_blocks[i*4 +: 4] != job_blocks[j*4 +: 4]);
            end
          end
        end
        // Unknown enabled metadata cannot admit a PMEM read in simulation.
        chain_invalid = 1'b1;
        if (chain_ok) chain_invalid = 1'b0;
      end
      assign job_invalid = chain_invalid;
      assign read_blk = blocks_q[{raw_byte[13:11],2'b00} +: 4];

      always @(posedge clk) begin
        if (rst_sync) blocks_q <= 20'd0;
        else if (job_valid && job_ready) blocks_q <= job_blocks;
      end
    end else begin : g_single
      // Keep the legacy limit and do not reference either optional input.
      assign job_invalid = (job_app_len > 14'd2006);
      assign read_blk = blk_q;
    end
  endgenerate

  function [31:0] add16;
    input [31:0] acc;
    input [15:0] val;
    reg [32:0] wide;
    begin
      wide = {1'b0,acc} + {17'd0,val};
      add16 = wide[31:0] + {16'd0,wide[32]};
    end
  endfunction

  function [15:0] fold_sum;
    input [31:0] acc;
    reg [16:0] f1;
    reg [16:0] f2;
    begin
      f1 = {1'b0,acc[15:0]} + {1'b0,acc[31:16]};
      f2 = {1'b0,f1[15:0]} + {16'd0,f1[16]};
      fold_sum = f2[15:0];
    end
  endfunction

  reg [31:0] start_sum;
  always @* begin
    start_sum = 32'd0;
    start_sum = add16(start_sum, job_src_ip[31:16]);
    start_sum = add16(start_sum, job_src_ip[15:0]);
    start_sum = add16(start_sum, job_dst_ip[31:16]);
    start_sum = add16(start_sum, job_dst_ip[15:0]);
    start_sum = add16(start_sum, 16'h0011);
    // Explicit 16-bit pseudo-header length; 8192 + 8 = 8200 (0x2008).
    start_sum = add16(start_sum, ({2'b00,job_app_len} + 16'd8));
  end

  reg [7:0] cur_byte, next_byte;
  reg [15:0] pair_word;
  reg [31:0] sum_next;
  reg [14:0] pos_next;
  reg [15:0] len_field_next, checksum_field_next;
  reg [1:0] err_next;
  always @* begin
    cur_byte = word_q[31 - (lane_q * 8) -: 8];
    next_byte = word_q[31 - ((lane_q + 3'd1) * 8) -: 8];
    pair_word = 16'd0;
    sum_next = sum_q;
    pos_next = byte_pos;
    len_field_next = udp_len_field;
    checksum_field_next = udp_checksum_field;
    err_next = err_q;
    // Consume up to the two bytes belonging to this network-order word.
    if (byte_pos[0] == 1'b0) begin
      pair_word[15:8] = cur_byte;
      if (byte_pos + 15'd1 < udp_len_q) pair_word[7:0] = next_byte;
      else pair_word[7:0] = 8'h00;
      sum_next = add16(sum_next, pair_word);
      if (byte_pos == 15'd4) len_field_next[15:8] = cur_byte;
      if (byte_pos == 15'd5) len_field_next[7:0] = cur_byte;
      if (byte_pos == 15'd6) checksum_field_next[15:8] = cur_byte;
      if (byte_pos == 15'd7) checksum_field_next[7:0] = cur_byte;
      if (byte_pos + 15'd1 < udp_len_q) begin
        if (byte_pos + 15'd1 == 15'd4) len_field_next[15:8] = next_byte;
        if (byte_pos + 15'd1 == 15'd5) len_field_next[7:0] = next_byte;
        if (byte_pos + 15'd1 == 15'd6) checksum_field_next[15:8] = next_byte;
        if (byte_pos + 15'd1 == 15'd7) checksum_field_next[7:0] = next_byte;
      end
      pos_next = byte_pos + ((byte_pos + 15'd1 < udp_len_q) ? 15'd2 : 15'd1);
    end else begin
      // This branch is defensive: the walker advances by complete pairs.
      pair_word = {cur_byte,8'h00};
      sum_next = add16(sum_next, pair_word);
      pos_next = byte_pos + 15'd1;
    end
    if ((byte_pos <= 15'd5) && (pos_next > 15'd5) && (len_field_next != udp_len_q))
      err_next = 2'd1;
  end

  always @(posedge clk) begin
    if (rst_sync) begin
      state <= S_IDLE;
      outstanding <= 1'b0;
      done <= 1'b0; good <= 1'b0; reason <= 2'd0;
      blk_q <= 4'd0; udp_len_q <= 15'd0; check_q <= 1'b0;
      byte_pos <= 15'd0; raw_byte <= 14'd0; word_q <= 32'd0;
      lane_q <= 3'd0; sum_q <= 32'd0;
      udp_len_field <= 16'd0; udp_checksum_field <= 16'd0; err_q <= 2'd0;
    end else begin
      done <= 1'b0;
      case (state)
        S_IDLE: if (job_valid && job_ready) begin
          blk_q <= job_blk;
          udp_len_q <= {1'b0,job_app_len} + 15'd8;
          check_q <= job_check_en;
          udp_len_field <= 16'd0; udp_checksum_field <= 16'd0; err_q <= 2'd0;
          byte_pos <= 15'd0; raw_byte <= 14'd34; outstanding <= 1'b0;
          sum_q <= start_sum;
          if (job_invalid) begin
            good <= 1'b0; reason <= 2'd3; done <= 1'b1;
          end else state <= S_REQ;
        end
        S_REQ: if (rd_req && rd_grant) begin
          outstanding <= 1'b1;
          if (rd_valid) begin
            outstanding <= 1'b0; word_q <= rd_data;
            lane_q <= (raw_byte[1:0] == 2'd2) ? 3'd2 : 3'd0;
            state <= S_CONSUME;
          end else state <= S_RESP;
        end
        S_RESP: if (rd_valid && outstanding) begin
          outstanding <= 1'b0; word_q <= rd_data;
          lane_q <= (raw_byte[1:0] == 2'd2) ? 3'd2 : 3'd0;
          state <= S_CONSUME;
        end
        S_CONSUME: begin
          sum_q <= sum_next; byte_pos <= pos_next;
          udp_len_field <= len_field_next;
          udp_checksum_field <= checksum_field_next;
          err_q <= err_next;
          if (pos_next >= udp_len_q) state <= S_FINISH;
          else if (lane_q == 3'd0) begin
            lane_q <= 3'd2;
            state <= S_CONSUME;
          end else begin
            raw_byte <= {raw_byte[13:2] + 12'd1,2'b00};
            state <= S_REQ;
          end
        end
        S_FINISH: begin
          done <= 1'b1;
          if (err_q == 2'd1) begin good <= 1'b0; reason <= 2'd1; end
          else if (check_q && ((udp_checksum_field == 16'd0) ||
                               (fold_sum(sum_q) != 16'hffff))) begin
            good <= 1'b0; reason <= 2'd2;
          end else begin good <= 1'b1; reason <= 2'd0; end
          state <= S_IDLE;
        end
        default: begin state <= S_IDLE; outstanding <= 1'b0; end
      endcase
    end
  end
endmodule
