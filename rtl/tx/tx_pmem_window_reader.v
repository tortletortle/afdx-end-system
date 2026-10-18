// Transactional PMEM byte reader. One PMEM word may be outstanding at a time.
// The legacy tx_pmem_byte_reader remains available for T53 compatibility.
`timescale 1 ns / 1 ps
module tx_pmem_window_reader (
  input  wire        clk,
  input  wire        rst_sync,
  input  wire        start,
  output wire        start_ready,
  input  wire [13:0] app_len,
  input  wire [2:0]  block_count,
  input  wire [15:0] blocks,       // block 0 is [3:0]
  input  wire [13:0] window_offset,
  input  wire [13:0] window_len,
  input  wire        cancel,
  output reg         start_error,
  output wire        pmem_req_valid,
  input  wire        pmem_req_grant,
  output wire [12:0] pmem_req_addr,
  input  wire        pmem_rsp_valid,
  input  wire [31:0] pmem_rsp_data,
  output wire        byte_valid,
  input  wire        byte_ready,
  output wire [7:0]  byte_data,
  output wire        byte_last,
  output reg         done
);
  localparam [2:0] IDLE=3'd0, REQUEST=3'd1, RESPONSE=3'd2,
                   EMIT=3'd3, DRAIN=3'd4;
  reg [2:0] state;
  reg [15:0] blocks_q;
  reg [13:0] app_len_q, offset_q, window_len_q, emitted;
  reg [31:0] word_q;

  function [3:0] block_at;
    input [15:0] list;
    input [1:0] idx;
    begin
      case (idx)
        2'd0: block_at=list[3:0];
        2'd1: block_at=list[7:4];
        2'd2: block_at=list[11:8];
        default: block_at=list[15:12];
      endcase
    end
  endfunction
  function blocks_valid;
    input [15:0] list;
    input [2:0] count;
    integer i,j;
    reg [3:0] a,b;
    begin
      blocks_valid = 1'b1;
      for (i=0;i<4;i=i+1) begin
        a = block_at(list,i[1:0]);
        if (i<count && a>4'd5) blocks_valid=1'b0;
        for (j=i+1;j<4;j=j+1) begin
          b = block_at(list,j[1:0]);
          if (i<count && j<count && a==b) blocks_valid=1'b0;
        end
      end
    end
  endfunction

  reg [14:0] cursor;
  reg [1:0] lane;
  reg [1:0] block_idx;
  reg [8:0] word_idx;
  always @* begin
    cursor = {1'b0, offset_q} + {1'b0, emitted};
    lane = cursor[1:0];
    block_idx = cursor[12:11];
    word_idx = cursor[10:2];
  end

  assign start_ready = (state == IDLE) && !rst_sync;
  assign pmem_req_valid = (state == REQUEST);
  assign pmem_req_addr = {block_at(blocks_q, block_idx), word_idx};
  // Cancel wins over byte transfer at the sampling edge. Hide valid in the
  // cancel cycle so an external consumer cannot accept a byte that this
  // reader simultaneously discards from its transaction accounting.
  assign byte_valid = (state == EMIT) && !cancel;
  assign byte_last = byte_valid && (emitted == window_len_q - 14'd1);
  assign byte_data = lane == 2'd0 ? word_q[31:24] :
                     lane == 2'd1 ? word_q[23:16] :
                     lane == 2'd2 ? word_q[15:8] : word_q[7:0];

  always @(posedge clk) begin
    start_error <= 1'b0;
    done <= 1'b0;
    if (rst_sync) begin
      state <= IDLE;
      blocks_q <= 16'd0;
      app_len_q <= 14'd0;
      offset_q <= 14'd0;
      window_len_q <= 14'd0;
      emitted <= 14'd0;
      word_q <= 32'd0;
    end else begin
      case (state)
        IDLE: if (start) begin
          if (app_len == 0 || app_len > 14'd8192 ||
              block_count == 0 || block_count > 4 ||
              block_count != ((app_len + 14'd2047) >> 11) ||
              !blocks_valid(blocks, block_count) ||
              window_len == 0 ||
              ({1'b0,window_offset} + {1'b0,window_len}) > {1'b0,app_len}) begin
            start_error <= 1'b1;
          end else begin
            app_len_q <= app_len;
            blocks_q <= blocks;
            offset_q <= window_offset;
            window_len_q <= window_len;
            emitted <= 14'd0;
            state <= REQUEST;
          end
        end
        REQUEST: begin
          if (pmem_req_grant) begin
            if (pmem_rsp_valid) begin
              word_q <= pmem_rsp_data;
              if (cancel) state <= IDLE;
              else state <= EMIT;
            end else if (cancel) state <= DRAIN;
            else state <= RESPONSE;
          end else if (cancel) state <= IDLE;
        end
        RESPONSE: begin
          if (cancel) begin
            if (pmem_rsp_valid) state <= IDLE;
            else state <= DRAIN;
          end
          else if (pmem_rsp_valid) begin
            word_q <= pmem_rsp_data;
            state <= EMIT;
          end
        end
        DRAIN: if (pmem_rsp_valid) state <= IDLE;
        EMIT: begin
          if (cancel) state <= IDLE;
          else if (byte_ready) begin
            if (emitted == window_len_q - 14'd1) begin
              done <= 1'b1;
              state <= IDLE;
            end else begin
              emitted <= emitted + 14'd1;
              if (cursor[1:0] == 2'd3) state <= REQUEST;
            end
          end
        end
        default: state <= IDLE;
      endcase
    end
  end
endmodule
