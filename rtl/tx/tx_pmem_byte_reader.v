// Standalone B2 primitive: stream one application payload across up to four
// 2 KiB PMEM blocks. The caller owns the blocks and PMEM read port.
`timescale 1 ns / 1 ps
module tx_pmem_byte_reader (
  input  wire        clk,
  input  wire        rst_sync,
  input  wire        start,
  output wire        start_ready,
  input  wire [13:0] start_len,
  input  wire [2:0]  start_block_count,
  // block 0 is [3:0], block 1 [7:4], block 2 [11:8], block 3 [15:12]
  input  wire [15:0] start_blocks,
  output reg         start_error,
  output wire        pmem_rd_en,
  output wire [12:0] pmem_rd_addr,
  input  wire [31:0] pmem_rd_data,
  output wire        byte_valid,
  input  wire        byte_ready,
  output reg  [7:0]  byte_data,
  output wire        byte_last,
  output reg         done
);
  localparam [1:0] S_IDLE = 2'd0, S_ISSUE = 2'd1,
                   S_CAPTURE = 2'd2, S_EMIT = 2'd3;
  reg [1:0] state;
  reg [15:0] blocks_q;
  reg [13:0] length_q;
  reg [13:0] byte_pos;
  reg [8:0] word_idx;
  reg [1:0] block_idx;
  reg [1:0] lane;
  reg [31:0] word_q;
  reg [3:0] current_block;
  wire [13:0] required_blocks = (start_len + 14'd2047) >> 11;

  function [3:0] block_at;
    input [15:0] list;
    input [1:0] index;
    begin
      case (index)
        2'd0: block_at = list[3:0];
        2'd1: block_at = list[7:4];
        2'd2: block_at = list[11:8];
        default: block_at = list[15:12];
      endcase
    end
  endfunction

  function tx_blocks_valid;
    input [15:0] list;
    input [2:0] count;
    integer i, j;
    reg [3:0] left_id, right_id;
    begin
      tx_blocks_valid = 1'b1;
      for (i = 0; i < 4; i = i + 1) begin
        left_id = block_at(list, i[1:0]);
        if (i < count && left_id > 4'd5) tx_blocks_valid = 1'b0;
        for (j = i + 1; j < 4; j = j + 1) begin
          right_id = block_at(list, j[1:0]);
          if (i < count && j < count && left_id == right_id)
            tx_blocks_valid = 1'b0;
        end
      end
    end
  endfunction

  always @* begin
    case (block_idx)
      2'd0: current_block = blocks_q[3:0];
      2'd1: current_block = blocks_q[7:4];
      2'd2: current_block = blocks_q[11:8];
      default: current_block = blocks_q[15:12];
    endcase
    case (lane)
      2'd0: byte_data = word_q[31:24];
      2'd1: byte_data = word_q[23:16];
      2'd2: byte_data = word_q[15:8];
      default: byte_data = word_q[7:0];
    endcase
  end

  assign start_ready = (state == S_IDLE) && !rst_sync;
  assign pmem_rd_en = (state == S_ISSUE);
  assign pmem_rd_addr = {current_block, word_idx};
  assign byte_valid = (state == S_EMIT);
  assign byte_last = byte_valid && (byte_pos == length_q - 14'd1);

  always @(posedge clk) begin
    start_error <= 1'b0;
    done <= 1'b0;
    if (rst_sync) begin
      state <= S_IDLE;
      blocks_q <= 16'd0;
      length_q <= 14'd0;
      byte_pos <= 14'd0;
      word_idx <= 9'd0;
      block_idx <= 2'd0;
      lane <= 2'd0;
      word_q <= 32'd0;
    end else begin
      case (state)
        S_IDLE: if (start) begin
          if (start_len == 14'd0 || start_len > 14'd8192 ||
              start_block_count == 3'd0 || start_block_count > 3'd4 ||
              required_blocks != {11'd0, start_block_count} ||
              !tx_blocks_valid(start_blocks, start_block_count)) begin
            start_error <= 1'b1;
          end else begin
            blocks_q <= start_blocks;
            length_q <= start_len;
            byte_pos <= 14'd0;
            word_idx <= 9'd0;
            block_idx <= 2'd0;
            lane <= 2'd0;
            state <= S_ISSUE;
          end
        end
        S_ISSUE: state <= S_CAPTURE;
        S_CAPTURE: begin
          word_q <= pmem_rd_data;
          state <= S_EMIT;
        end
        S_EMIT: if (byte_ready) begin
          if (byte_pos == length_q - 14'd1) begin
            done <= 1'b1;
            state <= S_IDLE;
          end else begin
            byte_pos <= byte_pos + 14'd1;
            if (lane != 2'd3) lane <= lane + 2'd1;
            else begin
              lane <= 2'd0;
              if (word_idx == 9'd511) begin
                word_idx <= 9'd0;
                block_idx <= block_idx + 2'd1;
              end else word_idx <= word_idx + 9'd1;
              state <= S_ISSUE;
            end
          end
        end
        default: state <= S_IDLE;
      endcase
    end
  end
endmodule
