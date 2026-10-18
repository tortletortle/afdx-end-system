// Bridges one RFC 1350 client download block stream into a complete-file receiver.
// Standalone preparation module; not connected to a production top.
`timescale 1 ns / 1 ps
module a615a_tftp_file_rx_adapter #(
  parameter integer MAX_BYTES = 8192
) (
  input  wire          clk,
  input  wire          rst_sync,
  input  wire          start,
  output wire          start_ready,
  input  wire          client_done,       // level from this RRQ session; low before completion
  input  wire          client_failed,     // pulse from this RRQ session
  input  wire          abort_request,

  input  wire          preload_start,
  output wire          preload_start_ready,
  input  wire          preload_data_valid,
  output wire          preload_data_ready,
  input  wire [7:0]    preload_data,
  input  wire          preload_commit,
  input  wire [13:0]   preload_length,
  input  wire          preload_abort,
  output wire          preload_error,

  input  wire          upload_job_active,
  input  wire          upload_block_req,
  input  wire [15:0]   upload_block_number,
  output wire          upload_block_valid,
  input  wire          upload_block_ready,
  output wire [9:0]    upload_data_len,
  output wire [4095:0] upload_data,
  output wire          upload_block_last,
  output wire          upload_source_ready,

  input  wire          download_block_valid,
  output wire          download_block_ready,
  input  wire [9:0]    download_data_len,
  input  wire [4095:0] download_data,     // first byte at [4095:4088]
  input  wire          download_block_last,
  output wire          block_reject,      // invalid tuple is held off; caller must cancel/reset client

  output wire          file_busy,
  output wire          file_valid,
  input  wire          file_ack,
  output wire [13:0]   file_length,
  output wire [1:0]    file_error_code,
  input  wire          rd_en,
  input  wire [12:0]   rd_addr,
  output wire          rd_valid,
  output wire [7:0]    rd_data,
  output reg  [1:0]    adapter_error
);
  localparam [2:0] S_IDLE=3'd0, S_BLOCK=3'd1, S_BYTES=3'd2,
                   S_WAIT_DONE=3'd3, S_ABORT=3'd4;
  localparam [1:0] E_NONE=2'd0, E_BAD_BLOCK=2'd1, E_ABORT=2'd2;

  reg [2:0] state;
  reg [4095:0] block_buf;
  reg [9:0] block_len;
  reg block_last;
  reg [8:0] byte_pos;
  reg done_low_seen;

  // Upload reads reuse this adapter's existing 512-byte block_buf. The
  // file_rx byte read port is time-multiplexed with the host readback port.
  localparam [2:0] U_IDLE=3'd0, U_READ=3'd1, U_WAIT=3'd2, U_HOLD=3'd3;
  reg [2:0] upload_state;
  reg [12:0] upload_base;
  reg [9:0] upload_index;
  integer upload_byte_i;
  reg [9:0] upload_len_r;
  reg upload_last_r;
  wire upload_read_active = (upload_state != U_IDLE);
  wire upload_rd_en = (upload_state == U_READ);
  wire [12:0] host_rd_addr = rd_addr;

  wire rx_start_ready;
  wire rx_in_ready;
  wire rx_rd_valid;
  wire [7:0] rx_rd_data;
  wire rx_file_valid;
  wire [13:0] rx_file_length;
  wire [1:0] rx_file_error;
  wire rx_preload_start_ready, rx_preload_data_ready, rx_preload_error;
  // Keep bit 4: file 8192 reaches legal DATA block 16, whose byte offset is
  // 15*512. Truncating to [3:0] wraps block 16 to zero before subtracting.
  wire [14:0] requested_offset = ({10'd0, upload_block_number[4:0]} - 15'd1) << 9;
  wire [14:0] remaining_bytes = {1'b0, rx_file_length} - requested_offset;
  wire [12:0] upload_rd_addr = upload_base + upload_index[8:0];
  wire rx_rd_en_mux = upload_rd_en ||
                      (rd_en && !upload_job_active && !upload_read_active);
  wire [12:0] rx_rd_addr_mux = upload_rd_en ? upload_rd_addr : host_rd_addr;
  wire upload_block_fire = upload_block_valid && upload_block_ready;
  wire rx_start = start && start_ready;
  wire rx_abort = ((abort_request || client_failed) && (state != S_IDLE)) ||
                  (state == S_ABORT);
  wire rx_end = (state == S_WAIT_DONE) && done_low_seen && client_done &&
                !(abort_request || client_failed);
  wire block_fire = download_block_valid && download_block_ready;
  wire byte_valid = (state == S_BYTES);
  wire byte_fire = byte_valid && rx_in_ready;
  wire [9:0] byte_next = {1'b0, byte_pos} + 10'd1;
  wire block_shape_ok = (download_data_len <= 10'd512) &&
                        (download_block_last == (download_data_len < 10'd512));
  wire [7:0] selected_byte = block_buf[4095 - (byte_pos * 8) -: 8];

  assign start_ready = (state == S_IDLE) && rx_start_ready;
  assign block_reject = (state == S_BLOCK) && download_block_valid && !block_shape_ok;
  assign download_block_ready = (state == S_BLOCK) && file_busy && block_shape_ok &&
                                !(abort_request || client_failed);
  assign file_valid = rx_file_valid;
  assign file_length = rx_file_length;
  assign file_error_code = rx_file_error;
  assign rd_valid = rx_rd_valid && !upload_job_active && !upload_read_active;
  assign rd_data = rx_rd_data;
  assign preload_start_ready = rx_preload_start_ready;
  assign preload_data_ready = rx_preload_data_ready;
  assign preload_error = rx_preload_error;
  assign upload_source_ready = rx_file_valid;
  assign upload_block_valid = (upload_state == U_HOLD);
  assign upload_data_len = upload_len_r;
  assign upload_data = block_buf;
  assign upload_block_last = upload_last_r;

  a615a_file_rx #(.MAX_BYTES(MAX_BYTES)) u_file_rx (
    .clk(clk), .rst_sync(rst_sync),
    .file_start(rx_start), .file_start_ready(rx_start_ready),
    .in_valid(byte_valid), .in_ready(rx_in_ready), .in_data(selected_byte),
    .file_end(rx_end), .file_abort(rx_abort),
    .preload_start(preload_start), .preload_start_ready(rx_preload_start_ready),
    .preload_data_valid(preload_data_valid), .preload_data_ready(rx_preload_data_ready),
    .preload_data(preload_data), .preload_commit(preload_commit),
    .preload_length(preload_length), .preload_abort(preload_abort),
    .upload_job_active(upload_job_active), .preload_error(rx_preload_error),
    .file_busy(file_busy), .file_valid(rx_file_valid), .file_ack(file_ack),
    .file_length(rx_file_length), .error_code(rx_file_error),
    .rd_en(rx_rd_en_mux), .rd_addr(rx_rd_addr_mux),
    .rd_valid(rx_rd_valid), .rd_data(rx_rd_data)
  );

  always @(posedge clk) begin
    if (rst_sync) begin
      state <= S_IDLE;
      block_buf <= 4096'd0;
      block_len <= 10'd0;
      block_last <= 1'b0;
      byte_pos <= 9'd0;
      done_low_seen <= 1'b0;
      adapter_error <= E_NONE;
      upload_state <= U_IDLE;
      upload_base <= 13'd0;
      upload_index <= 10'd0;
      upload_len_r <= 10'd0;
      upload_last_r <= 1'b0;
    end else begin
      if (state != S_IDLE && !client_done) done_low_seen <= 1'b1;
      if (abort_request || client_failed || rst_sync) begin
        upload_state <= U_IDLE;
        upload_index <= 10'd0;
        block_buf <= 4096'd0;
      end else begin
        case (upload_state)
          U_IDLE: begin
            if (upload_block_req && upload_source_ready) begin
              block_buf <= 4096'd0;
              upload_index <= 10'd0;
              if ((upload_block_number == 16'd0) || (upload_block_number > 16'd16) ||
                  ((rx_file_length != 14'd0) && (requested_offset >= {1'b0, rx_file_length})) ||
                  ((rx_file_length == 14'd0) && (upload_block_number != 16'd1))) begin
                // The client rejects len=513 through its normal E_UPLOAD_BLOCK path.
                upload_len_r <= 10'd513;
                upload_last_r <= 1'b0;
                upload_state <= U_HOLD;
              end else if (rx_file_length == 14'd0) begin
                upload_len_r <= 10'd0;
                upload_last_r <= 1'b1;
                upload_state <= U_HOLD;
              end else begin
                upload_base <= requested_offset[12:0];
                upload_len_r <= (remaining_bytes > 15'd512) ? 10'd512 : remaining_bytes[9:0];
                upload_last_r <= (remaining_bytes <= 15'd512);
                upload_state <= U_READ;
              end
            end
          end
          U_READ: upload_state <= U_WAIT;
          U_WAIT: begin
            if (rx_rd_valid) begin
              for (upload_byte_i = 0; upload_byte_i < 512; upload_byte_i = upload_byte_i + 1) begin
                if (upload_index == upload_byte_i)
                  block_buf[4095 - 8*upload_byte_i -: 8] <= rx_rd_data;
              end
              if (upload_index + 10'd1 >= upload_len_r) begin
                upload_state <= U_HOLD;
              end else begin
                upload_index <= upload_index + 10'd1;
                upload_state <= U_READ;
              end
            end
          end
          U_HOLD: begin
            if (upload_block_fire) upload_state <= U_IDLE;
          end
          default: upload_state <= U_IDLE;
        endcase
      end
      if (rx_start) begin
        state <= S_BLOCK;
        block_buf <= 4096'd0;
        block_len <= 10'd0;
        block_last <= 1'b0;
        byte_pos <= 9'd0;
        done_low_seen <= !client_done;
        adapter_error <= E_NONE;
      end else if ((abort_request || client_failed) && (state != S_IDLE)) begin
        state <= S_IDLE;
        block_buf <= 4096'd0;
        byte_pos <= 9'd0;
        adapter_error <= E_ABORT;
      end else begin
        case (state)
          S_IDLE: begin end
          S_BLOCK: begin
            if (block_reject) adapter_error <= E_BAD_BLOCK;
            if (block_fire) begin
              begin
                block_buf <= download_data;
                block_len <= download_data_len;
                block_last <= download_block_last;
                byte_pos <= 9'd0;
                if (download_data_len == 10'd0)
                  state <= download_block_last ? S_WAIT_DONE : S_ABORT;
                else
                  state <= S_BYTES;
              end
            end
          end
          S_BYTES: begin
            if (byte_fire) begin
              if (byte_next == block_len) begin
                byte_pos <= 9'd0;
                state <= block_last ? S_WAIT_DONE : S_BLOCK;
              end else begin
                byte_pos <= byte_pos + 9'd1;
              end
            end
          end
          S_WAIT_DONE: begin
            if (done_low_seen && client_done) begin
              state <= S_IDLE;
              block_buf <= 4096'd0;
              block_len <= 10'd0;
              block_last <= 1'b0;
            end
          end
          S_ABORT: begin
            state <= S_IDLE;
            block_buf <= 4096'd0;
            block_len <= 10'd0;
            block_last <= 1'b0;
            byte_pos <= 9'd0;
          end
          default: state <= S_IDLE;
        endcase
      end
    end
  end
endmodule
