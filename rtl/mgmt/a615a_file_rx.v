// Complete-file receive buffer between a TFTP transport client and a file parser.
// Input bytes must already be de-duplicated and ordered by the transport layer.
// file_end is a separate pulse after the final byte handshake. A file is exposed
// only after file_end and only when no capacity overflow occurred.
// MAX_BYTES is a project resource limit (default 8 KiB), not a 615A wire rule.
// Standalone preparation module; not connected to AFDX_top. Functional verification pending.
`timescale 1 ns / 1 ps
module a615a_file_rx #(
  parameter integer MAX_BYTES = 8192
) (
  input  wire        clk,
  input  wire        rst_sync,
  input  wire        file_start,
  output wire        file_start_ready,
  input  wire        in_valid,
  output wire        in_ready,
  input  wire [7:0]  in_data,
  input  wire        file_end,
  input  wire        file_abort,
  // Host preload writes the same file_mem used by the download receiver.
  input  wire        preload_start,
  output wire        preload_start_ready,
  input  wire        preload_data_valid,
  output wire        preload_data_ready,
  input  wire [7:0]  preload_data,
  input  wire        preload_commit,
  input  wire [13:0] preload_length,
  input  wire        preload_abort,
  input  wire        upload_job_active,
  output reg         preload_error,
  output reg         file_busy,
  output reg         file_valid,
  input  wire        file_ack,
  output reg  [13:0] file_length,
  output reg  [1:0]  error_code,
  input  wire        rd_en,
  input  wire [12:0] rd_addr,
  output reg         rd_valid,
  output reg  [7:0]  rd_data
);
  // error_code: 0=none, 1=capacity overflow, 2=aborted, 3=invalid MAX_BYTES.
  localparam [1:0] E_NONE = 2'd0, E_OVERFLOW = 2'd1,
                   E_ABORT = 2'd2, E_BAD_PARAM = 2'd3;
  localparam integer COUNT_W = 14;
  localparam integer SAFE_BYTES = (MAX_BYTES < 1) ? 1 :
                                  ((MAX_BYTES > 8192) ? 8192 : MAX_BYTES);
  localparam integer MEM_DEPTH = 8192;
  localparam [COUNT_W-1:0] MAX_COUNT = MAX_BYTES[COUNT_W-1:0];
  reg [COUNT_W-1:0] byte_count;
  reg overflow_seen;
  reg preload_mode;
  wire storage_available = !rst_sync && !file_busy && (!file_valid || file_ack) &&
                           !upload_job_active && (MAX_BYTES >= 1) && (MAX_BYTES <= 8192);
  wire start_fire = file_start && file_start_ready;
  wire preload_start_fire = preload_start && preload_start_ready;
  wire byte_fire = in_valid && in_ready;
  wire preload_data_fire = preload_data_valid && preload_data_ready;
  wire preload_commit_fire = preload_commit && file_busy && preload_mode && !preload_data_valid;
  wire end_fire = file_end && file_busy && !preload_mode && !in_valid;
  wire abort_fire = file_abort && file_busy && !preload_mode;
  wire preload_abort_fire = preload_abort && file_busy && preload_mode;

  wire        mem_wr_en = file_busy &&
                          ((preload_mode && preload_data_fire) ||
                           (!preload_mode && byte_fire)) &&
                          (byte_count < MAX_COUNT);
  wire [12:0] mem_wr_addr = byte_count[12:0];
  wire [7:0]  mem_wr_data = preload_mode ? preload_data : in_data;
  wire [7:0]  mem_rd_data;
  // bram_1w1r is synchronous: mem_rd_data updates one posedge after rd_addr.
  // Accept the request on cycle N, present rd_valid/rd_data on cycle N+1 so
  // consumers (adapter U_WAIT, host polls) never sample the previous address.
  reg         rd_pending;

  // Use the project's known-good synchronous 1W1R BRAM wrapper.  Keeping the
  // storage as a memory primitive avoids eLinx expanding an 8 KiB byte array
  // into registers during memory_dff/memory_collect.
  bram_1w1r #(.W(8), .D(MEM_DEPTH), .RD_NEG(0)) u_file_mem (
    .clk     (clk),
    .wr_en   (mem_wr_en),
    .wr_addr (mem_wr_addr),
    .wr_data (mem_wr_data),
    .rd_addr (rd_addr),
    .rd_data (mem_rd_data)
  );

  assign file_start_ready = storage_available && !preload_start;
  assign preload_start_ready = storage_available && !file_start;
  assign preload_data_ready = !rst_sync && file_busy && preload_mode;
  // Continue accepting bytes after overflow so the transport can drain the
  // final block; excess bytes are discarded and the file will not be published.
  assign in_ready = !rst_sync && file_busy;

  always @(posedge clk) begin
    if (rst_sync) begin
      file_busy <= 1'b0;
      file_valid <= 1'b0;
      file_length <= 14'd0;
      byte_count <= 14'd0;
      overflow_seen <= 1'b0;
      preload_mode <= 1'b0;
      preload_error <= 1'b0;
      error_code <= E_NONE;
      rd_valid <= 1'b0;
      rd_data <= 8'd0;
      rd_pending <= 1'b0;
    end else begin
      rd_pending <= rd_en && file_valid && (rd_addr < file_length);
      rd_valid <= rd_pending;
      if (rd_pending)
        rd_data <= mem_rd_data;

      if (file_ack && file_valid && !upload_job_active) file_valid <= 1'b0;

      if (start_fire) begin
        preload_mode <= 1'b0;
        file_busy <= 1'b1;
        file_valid <= 1'b0;
        file_length <= 14'd0;
        byte_count <= 14'd0;
        overflow_seen <= 1'b0;
        preload_error <= 1'b0;
        error_code <= E_NONE;
      end else if (preload_start_fire) begin
        preload_mode <= 1'b1;
        file_busy <= 1'b1;
        file_valid <= 1'b0;
        file_length <= 14'd0;
        byte_count <= 14'd0;
        overflow_seen <= 1'b0;
        preload_error <= 1'b0;
        error_code <= E_NONE;
      end else if (file_busy) begin
        if (preload_abort_fire) begin
          preload_mode <= 1'b0;
          file_busy <= 1'b0;
          file_valid <= 1'b0;
          file_length <= 14'd0;
          byte_count <= 14'd0;
          overflow_seen <= 1'b0;
          preload_error <= 1'b1;
          error_code <= E_ABORT;
        end else if (abort_fire) begin
          file_busy <= 1'b0;
          file_valid <= 1'b0;
          file_length <= 14'd0;
          error_code <= E_ABORT;
        end else if (preload_mode) begin
          if (preload_data_fire) begin
            if (byte_count < MAX_COUNT) begin
              byte_count <= byte_count + 14'd1;
            end else begin
              overflow_seen <= 1'b1;
              error_code <= E_OVERFLOW;
            end
          end
          if (preload_commit_fire) begin
            preload_mode <= 1'b0;
            file_busy <= 1'b0;
            if (overflow_seen || (preload_length > MAX_COUNT) ||
                (preload_length != byte_count)) begin
              file_valid <= 1'b0;
              file_length <= 14'd0;
              preload_error <= 1'b1;
              error_code <= overflow_seen ? E_OVERFLOW : E_BAD_PARAM;
            end else begin
              file_valid <= 1'b1;
              file_length <= preload_length;
              preload_error <= 1'b0;
              error_code <= E_NONE;
            end
          end
        end else begin
          if (byte_fire) begin
            if (byte_count < MAX_COUNT) begin
              byte_count <= byte_count + 14'd1;
            end else begin
              overflow_seen <= 1'b1;
              error_code <= E_OVERFLOW;
            end
          end
          if (end_fire) begin
            file_busy <= 1'b0;
            if (overflow_seen) begin
              file_valid <= 1'b0;
              file_length <= 14'd0;
              error_code <= E_OVERFLOW;
            end else begin
              file_valid <= 1'b1;
              file_length <= byte_count;
              error_code <= E_NONE;
            end
          end
        end
      end

      if ((MAX_BYTES < 1) || (MAX_BYTES > 8192)) begin
        file_busy <= 1'b0;
        file_valid <= 1'b0;
        error_code <= E_BAD_PARAM;
      end
    end
  end
endmodule
