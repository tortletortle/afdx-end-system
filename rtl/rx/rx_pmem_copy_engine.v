// Serial byte-range copy engine for the shared RX packet memory.
// Source and destination byte lanes must match. IPv4 fragment offsets are
// multiples of eight, so the RX reassembly path satisfies this contract.
`timescale 1 ns / 1 ps
module rx_pmem_copy_engine (
  input  wire        clk,
  input  wire        rst_sync,
  input  wire        job_valid,
  output wire        job_ready,
  input  wire [3:0]  job_src_blk,
  input  wire [12:0] job_src_byte,
  input  wire [3:0]  job_dst_blk,
  input  wire [12:0] job_dst_byte,
  input  wire [13:0] job_len,
  output reg         rd_req,
  output wire [12:0] rd_addr,
  input  wire        rd_grant,
  input  wire        rd_valid,
  input  wire [31:0] rd_data,
  output reg         wr_valid,
  output reg  [12:0] wr_addr,
  output reg  [31:0] wr_data,
  output reg  [3:0]  wr_be,
  input  wire        wr_grant,
  output reg         done
);
  localparam [1:0] S_IDLE = 2'd0, S_READ = 2'd1,
                   S_WAIT = 2'd2, S_WRITE = 2'd3;
  reg [1:0] state;
  reg [3:0] src_blk, dst_blk;
  reg [12:0] src_byte, dst_byte;
  reg [13:0] remain;
  reg [2:0] word_bytes;
  reg [3:0] be_q;
  reg [12:0] dst_addr_q;
  reg [31:0] data_q;
  integer lane_i;

  always @* begin
    if (remain >= (14'd4 - {12'd0,src_byte[1:0]}))
      word_bytes = 3'd4 - {1'b0,src_byte[1:0]};
    else
      word_bytes = remain[2:0];
  end

  always @* begin
    be_q = 4'b0000;
    for (lane_i=0; lane_i<4; lane_i=lane_i+1)
      if ((lane_i >= src_byte[1:0]) &&
          (lane_i < (src_byte[1:0] + word_bytes))) be_q[3-lane_i] = 1'b1;
  end

  assign job_ready = (state == S_IDLE);
  assign rd_addr = {src_blk,src_byte[10:2]};

  always @* begin
    rd_req = (state == S_READ);
    wr_valid = (state == S_WRITE);
    wr_addr = dst_addr_q;
    wr_data = data_q;
    wr_be = be_q;
  end

  always @(posedge clk) begin
    if (rst_sync) begin
      state <= S_IDLE;
      src_blk <= 4'd0; dst_blk <= 4'd0;
      src_byte <= 13'd0; dst_byte <= 13'd0; remain <= 14'd0;
      dst_addr_q <= 13'd0; data_q <= 32'd0; done <= 1'b0;
    end else begin
      done <= 1'b0;
      case (state)
        S_IDLE: if (job_valid && job_ready) begin
          if ((job_len == 14'd0) || (job_src_byte[1:0] != job_dst_byte[1:0])) begin
            done <= 1'b1;
          end else begin
            src_blk <= job_src_blk; dst_blk <= job_dst_blk;
            src_byte <= job_src_byte; dst_byte <= job_dst_byte;
            remain <= job_len;
            state <= S_READ;
          end
        end
        S_READ: if (rd_req && rd_grant) begin
          dst_addr_q <= {dst_blk,dst_byte[10:2]};
          state <= S_WAIT;
        end
        S_WAIT: if (rd_valid) begin
          data_q <= rd_data;
          state <= S_WRITE;
        end
        S_WRITE: if (wr_valid && wr_grant) begin
          if (remain <= {11'd0,word_bytes}) begin
            remain <= 14'd0;
            state <= S_IDLE;
            done <= 1'b1;
          end else begin
            remain <= remain - {11'd0,word_bytes};
            src_byte <= src_byte + {10'd0,word_bytes};
            dst_byte <= dst_byte + {10'd0,word_bytes};
            state <= S_READ;
          end
        end
        default: state <= S_IDLE;
      endcase
    end
  end
endmodule
