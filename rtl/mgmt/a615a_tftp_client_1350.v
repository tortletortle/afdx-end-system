// Packet-level TFTP client core for RFC 1350 octet RRQ/WRQ without options.
// The UDP adapter parses/builds complete TFTP datagrams; filename and DATA
// bytes use packed byte arrays with byte 0 in the most-significant byte.
// Standalone preparation RTL. It does not define any 615A operation sequence.
`timescale 1 ns / 1 ps
module a615a_tftp_client_1350 #(
  parameter integer MAX_RETRIES = 5
) (
  input  wire          clk,
  input  wire          rst_sync,
  input  wire          start,
  output wire          start_ready,
  input  wire          start_write,        // 0=RRQ download, 1=WRQ upload
  input  wire [31:0]   server_ip,
  input  wire [15:0]   local_tid,
  input  wire [2047:0] filename,
  input  wire [7:0]    filename_len,       // 1..255 bytes, no NUL included
  input  wire          timeout_tick,       // caller supplies one tick per timeout unit
  input  wire [15:0]   timeout_ticks,      // nonzero

  // Complete decoded UDP/TFTP datagram from the shared receive router.
  input  wire          rx_valid,
  output wire          rx_ready,
  input  wire [31:0]   rx_src_ip,
  input  wire [15:0]   rx_src_port,
  input  wire [15:0]   rx_dst_port,        // UDP adapter must preserve destination TID
  input  wire [2:0]    rx_opcode,
  input  wire [15:0]   rx_block,
  input  wire [9:0]    rx_data_len,        // DATA payload only: 0..512
  input  wire [4095:0] rx_data,            // byte 0 at [4095:4088]
  input  wire [15:0]   rx_error_code,

  // Packet descriptor to the UDP/TFTP packet builder. For RRQ/WRQ, filename
  // and filename_len are valid with opcode 1/2 and mode is always octet.
  output wire          tx_valid,
  input  wire          tx_ready,
  output wire [31:0]   tx_dst_ip,
  output wire [15:0]   tx_src_port,
  output wire [15:0]   tx_dst_port,
  output reg  [2:0]    tx_opcode,
  output reg  [15:0]   tx_block,
  output reg  [15:0]   tx_error_code,
  output reg  [9:0]    tx_data_len,
  output reg  [4095:0] tx_data,
  output wire [2047:0] tx_filename,
  output wire [7:0]    tx_filename_len,
  output wire          tx_mode_octet,

  // Upload source provides one complete block per request. Non-final blocks
  // must contain 512 bytes; a final block may contain 0..512 bytes.
  output wire          upload_block_req,
  output reg  [15:0]   upload_block_number,
  input  wire          upload_block_valid,
  output wire          upload_block_ready,
  input  wire [9:0]    upload_data_len,
  input  wire [4095:0] upload_data,
  input  wire          upload_block_last,

  // Download sink accepts one complete DATA block before its ACK is emitted.
  output reg           download_block_valid,
  input  wire          download_block_ready,
  output reg  [15:0]   download_block_number,
  output reg  [9:0]    download_data_len,
  output reg  [4095:0] download_data,
  output reg           download_block_last,

  output reg           peer_tid_valid,
  output reg  [15:0]   peer_tid,
  output reg           busy,
  output reg           done,
  output reg           failed,
  output reg  [3:0]    failure_code,
  output reg  [15:0]   server_error_code
);
  localparam [3:0] S_IDLE=4'd0, S_SEND_REQ=4'd1, S_WAIT_FIRST=4'd2,
                   S_WAIT_DATA=4'd3, S_DELIVER=4'd4, S_SEND_ACK=4'd5,
                   S_WAIT_UPLOAD=4'd6, S_SEND_DATA=4'd7, S_WAIT_ACK=4'd8,
                   S_DALLY=4'd9, S_DONE=4'd10, S_FAILED=4'd11;
  localparam [2:0] OP_RRQ=3'd1, OP_WRQ=3'd2, OP_DATA=3'd3,
                   OP_ACK=3'd4, OP_ERROR=3'd5;
  localparam [3:0] E_BAD_START=4'd1, E_TIMEOUT=4'd2,
                   E_SERVER=4'd3, E_UPLOAD_BLOCK=4'd4;

  reg [3:0] state;
  reg write_mode;
  reg [31:0] server_ip_reg;
  reg [15:0] local_tid_reg;
  reg [2047:0] filename_reg;
  reg [7:0] filename_len_reg;
  reg [15:0] timeout_ticks_reg;
  reg [15:0] timer_count;
  reg [15:0] retry_count;
  reg [15:0] expected_block;
  reg [15:0] ack_block;
  reg ack_block_valid;
  reg [15:0] upload_block;
  reg [9:0] upload_len;
  reg [4095:0] upload_buf;
  reg upload_last;
  reg ack_return_dally;
  reg ack_return_wait;
  reg final_upload_zero_pending;
  reg tid_error_pending;
  reg [31:0] tid_error_ip;
  reg [15:0] tid_error_port;

  wire start_fire = start && start_ready;
  wire tx_fire = tx_valid && tx_ready;
  wire rx_fire = rx_valid && rx_ready;
  wire wait_state = (state == S_WAIT_FIRST) || (state == S_WAIT_DATA) ||
                    (state == S_WAIT_ACK);
  wire timeout_hit = timeout_tick && (timer_count + 16'd1 >= timeout_ticks_reg);
  wire rx_from_server = (rx_src_ip == server_ip_reg) &&
                        (rx_dst_port == local_tid_reg);
  wire rx_tid_ok = !peer_tid_valid || (rx_src_port == peer_tid);
  wire rx_error_for_session = rx_valid && rx_from_server && rx_tid_ok &&
                              (rx_opcode == OP_ERROR);
  wire rx_first_ok = rx_valid && rx_from_server && !peer_tid_valid &&
                     (rx_src_port != 16'd0) &&
                     ((!write_mode && (rx_opcode == OP_DATA) &&
                       (rx_block == 16'd1) && (rx_data_len <= 10'd512)) ||
                      (write_mode && (rx_opcode == OP_ACK) &&
                       (rx_block == 16'd0)));
  wire rx_data_ok = rx_valid && rx_from_server && peer_tid_valid &&
                    (rx_src_port == peer_tid) && !write_mode &&
                    (state == S_WAIT_DATA) && (rx_opcode == OP_DATA) &&
                    (rx_data_len <= 10'd512) &&
                    ((rx_block == expected_block) ||
                     (ack_block_valid && (rx_block == ack_block)));
  wire rx_ack_ok = rx_valid && rx_from_server && peer_tid_valid &&
                   (rx_src_port == peer_tid) && write_mode &&
                   (state == S_WAIT_ACK) && (rx_opcode == OP_ACK) &&
                   (rx_block == upload_block);
  wire rx_dally_ok = rx_valid && rx_from_server && peer_tid_valid &&
                     (rx_src_port == peer_tid) && !write_mode &&
                     (state == S_DALLY) && (rx_opcode == OP_DATA) &&
                     download_block_last &&
                     (rx_block == download_block_number) &&
                     (rx_data_len < 10'd512);
  // Timer progress requires a consumed datagram; a valid-but-backpressured
  // input must not keep an owner session alive (e.g. while ERROR(5) is sent).
  wire rx_progress = rx_fire && (rx_error_for_session || rx_first_ok ||
                                 rx_data_ok || rx_ack_ok || rx_dally_ok);
  wire download_sink_fire = download_block_valid && download_block_ready;
  wire upload_source_fire = (state == S_WAIT_UPLOAD) &&
                            !final_upload_zero_pending && upload_block_valid &&
                            upload_block_ready;
  wire upload_zero_fire = (state == S_WAIT_UPLOAD) && final_upload_zero_pending;
  wire owner_tx_fire = tx_fire && !tid_error_pending;
  wire timer_reset_event = rx_progress || download_sink_fire ||
                           upload_source_fire || upload_zero_fire || owner_tx_fire;

  assign start_ready = (state == S_IDLE) || (state == S_DONE) || (state == S_FAILED);
  assign rx_ready = !tid_error_pending &&
                    ((state == S_WAIT_FIRST) || (state == S_WAIT_DATA) ||
                     (state == S_WAIT_ACK) || (state == S_DALLY));
  assign tx_valid = tid_error_pending || (state == S_SEND_REQ) ||
                    (state == S_SEND_ACK) || (state == S_SEND_DATA);
  assign tx_dst_ip = tid_error_pending ? tid_error_ip : server_ip_reg;
  assign tx_src_port = local_tid_reg;
  assign tx_dst_port = tid_error_pending ? tid_error_port :
                       (peer_tid_valid ? peer_tid : 16'd69);
  assign tx_filename = filename_reg;
  assign tx_filename_len = filename_len_reg;
  assign tx_mode_octet = 1'b1;
  assign upload_block_req = (state == S_WAIT_UPLOAD) && !final_upload_zero_pending;
  assign upload_block_ready = (state == S_WAIT_UPLOAD) && !final_upload_zero_pending;

  always @* begin
    tx_opcode = 3'd0;
    tx_block = 16'd0;
    tx_error_code = 16'd0;
    tx_data_len = 10'd0;
    tx_data = 4096'd0;
    if (tid_error_pending) begin
      tx_opcode = OP_ERROR;
      tx_error_code = 16'd5;
      tx_data_len = 10'd20;
      // Byte 0 is tx_data[4095:4088]; ERROR text is exactly 20 bytes.
      tx_data[4095:4032] = {8'h55,8'h6e,8'h6b,8'h6e,8'h6f,8'h77,8'h6e,8'h20};
      tx_data[4031:3968] = {8'h74,8'h72,8'h61,8'h6e,8'h73,8'h66,8'h65,8'h72};
      tx_data[3967:3936] = {8'h20,8'h49,8'h44,8'h00};
    end else case (state)
      S_SEND_REQ: tx_opcode = write_mode ? OP_WRQ : OP_RRQ;
      S_SEND_ACK: begin
        tx_opcode = OP_ACK;
        tx_block = ack_block;
      end
      S_SEND_DATA: begin
        tx_opcode = OP_DATA;
        tx_block = upload_block;
        tx_data_len = upload_len;
        tx_data = upload_buf;
      end
      default: begin end
    endcase
  end

  task fail_client;
    input [3:0] code;
    begin
      state <= S_FAILED;
      busy <= 1'b0;
      failed <= 1'b1;
      failure_code <= code;
      download_block_valid <= 1'b0;
    end
  endtask

  always @(posedge clk) begin
    if (rst_sync) begin
      state <= S_IDLE;
      write_mode <= 1'b0;
      server_ip_reg <= 32'd0;
      local_tid_reg <= 16'd0;
      filename_reg <= 2048'd0;
      filename_len_reg <= 8'd0;
      timeout_ticks_reg <= 16'd0;
      timer_count <= 16'd0;
      retry_count <= 16'd0;
      expected_block <= 16'd1;
      ack_block <= 16'd0;
      ack_block_valid <= 1'b0;
      upload_block <= 16'd0;
      upload_len <= 10'd0;
      upload_buf <= 4096'd0;
      upload_last <= 1'b0;
      ack_return_dally <= 1'b0;
      ack_return_wait <= 1'b0;
      final_upload_zero_pending <= 1'b0;
      tid_error_pending <= 1'b0;
      tid_error_ip <= 32'd0;
      tid_error_port <= 16'd0;
      peer_tid_valid <= 1'b0;
      peer_tid <= 16'd0;
      busy <= 1'b0;
      done <= 1'b0;
      failed <= 1'b0;
      failure_code <= 4'd0;
      server_error_code <= 16'd0;
      download_block_valid <= 1'b0;
      download_block_number <= 16'd0;
      download_data_len <= 10'd0;
      download_data <= 4096'd0;
      download_block_last <= 1'b0;
    end else begin
      done <= 1'b0;
      failed <= 1'b0;

      if (start_fire) begin
        peer_tid_valid <= 1'b0;
        peer_tid <= 16'd0;
        server_error_code <= 16'd0;
        download_block_valid <= 1'b0;
        ack_block_valid <= 1'b0;
        tid_error_pending <= 1'b0;
        final_upload_zero_pending <= 1'b0;
        if ((server_ip == 32'd0) || (local_tid == 16'd0) ||
            (filename_len == 8'd0) || (timeout_ticks == 16'd0) ||
            (MAX_RETRIES < 1)) begin
          failure_code <= E_BAD_START;
          failed <= 1'b1;
          busy <= 1'b0;
          state <= S_FAILED;
        end else begin
          state <= S_SEND_REQ;
          write_mode <= start_write;
          server_ip_reg <= server_ip;
          local_tid_reg <= local_tid;
          filename_reg <= filename;
          filename_len_reg <= filename_len;
          timeout_ticks_reg <= timeout_ticks;
          timer_count <= 16'd0;
          retry_count <= 16'd0;
          expected_block <= 16'd1;
          ack_block <= 16'd0;
          upload_block <= 16'd0;
          peer_tid_valid <= 1'b0;
          peer_tid <= 16'd0;
          server_error_code <= 16'd0;
          download_block_valid <= 1'b0;
          final_upload_zero_pending <= 1'b0;
          busy <= 1'b1;
          failure_code <= 4'd0;
        end
      end else begin
        if (download_block_valid && download_block_ready) begin
          download_block_valid <= 1'b0;
          ack_block <= download_block_number;
          ack_block_valid <= 1'b1;
          ack_return_dally <= download_block_last;
          ack_return_wait <= !download_block_last;
          if (!download_block_last)
            expected_block <= download_block_number + 16'd1;
          state <= S_SEND_ACK;
          timer_count <= 16'd0;
          retry_count <= 16'd0;
        end

        if (state == S_WAIT_UPLOAD && !final_upload_zero_pending &&
            upload_block_valid && upload_block_ready) begin
          if ((upload_data_len > 10'd512) ||
              (!upload_block_last && (upload_data_len != 10'd512))) begin
            fail_client(E_UPLOAD_BLOCK);
          end else begin
            upload_buf <= upload_data;
            upload_len <= upload_data_len;
            upload_last <= upload_block_last;
            upload_block <= upload_block_number;
            state <= S_SEND_DATA;
            timer_count <= 16'd0;
            retry_count <= 16'd0;
          end
        end else if (state == S_WAIT_UPLOAD && final_upload_zero_pending) begin
          upload_buf <= 4096'd0;
          upload_len <= 10'd0;
          upload_last <= 1'b1;
          upload_block <= upload_block_number;
          final_upload_zero_pending <= 1'b0;
          state <= S_SEND_DATA;
          timer_count <= 16'd0;
          retry_count <= 16'd0;
        end

        if (tx_fire && tid_error_pending) begin
          // ERROR(5) is an out-of-band reply. It must not alter the locked
          // peer TID, current packet, retry count, or session timer.
          tid_error_pending <= 1'b0;
        end else if (tx_fire) begin
          timer_count <= 16'd0;
          case (state)
            S_SEND_REQ: state <= S_WAIT_FIRST;
            S_SEND_ACK: begin
              if (ack_return_dally) state <= S_DALLY;
              else if (ack_return_wait) state <= S_WAIT_DATA;
              // Preserve retry_count for timeout-driven ACK retransmissions.
              // New DATA consumption resets it at the download sink handshake.
            end
            S_SEND_DATA: state <= S_WAIT_ACK;
            default: begin end
          endcase
        end

        if (rx_fire && rx_from_server) begin
          if (peer_tid_valid && (rx_src_port != peer_tid)) begin
            // RFC 1350 unknown-TID response is independent of this session.
            tid_error_pending <= 1'b1;
            tid_error_ip <= rx_src_ip;
            tid_error_port <= rx_src_port;
          end else if (rx_opcode == OP_ERROR) begin
            if (!peer_tid_valid || (rx_src_port == peer_tid)) begin
              server_error_code <= rx_error_code;
              fail_client(E_SERVER);
            end
          end else if (state == S_WAIT_FIRST) begin
            if (!peer_tid_valid && (rx_src_port != 16'd0)) begin
              if ((!write_mode && (rx_opcode == OP_DATA) &&
                   (rx_block == 16'd1) && (rx_data_len <= 10'd512)) ||
                  (write_mode && (rx_opcode == OP_ACK) &&
                   (rx_block == 16'd0))) begin
                peer_tid <= rx_src_port;
                peer_tid_valid <= 1'b1;
                retry_count <= 16'd0;
                timer_count <= 16'd0;
                if (write_mode) begin
                  upload_block_number <= 16'd1;
                  state <= S_WAIT_UPLOAD;
                end else begin
                  download_block_number <= rx_block;
                  download_data_len <= rx_data_len;
                  download_data <= rx_data;
                  download_block_last <= (rx_data_len < 10'd512);
                  download_block_valid <= 1'b1;
                  state <= S_DELIVER;
                end
              end
            end
          end else if (peer_tid_valid && (rx_src_port == peer_tid)) begin
            if ((state == S_WAIT_DATA) && !write_mode && (rx_opcode == OP_DATA)) begin
              if (rx_data_len <= 10'd512 && (rx_block == expected_block)) begin
                download_block_number <= rx_block;
                download_data_len <= rx_data_len;
                download_data <= rx_data;
                download_block_last <= (rx_data_len < 10'd512);
                download_block_valid <= 1'b1;
                state <= S_DELIVER;
                timer_count <= 16'd0;
                retry_count <= 16'd0;
              end else if (ack_block_valid && (rx_data_len <= 10'd512) &&
                           (rx_block == ack_block)) begin
                retry_count <= 16'd0; // consumed duplicate DATA is peer activity
                ack_return_dally <= 1'b0;
                ack_return_wait <= 1'b1;
                state <= S_SEND_ACK;
              end
            end else if ((state == S_WAIT_ACK) && write_mode && (rx_opcode == OP_ACK)) begin
              if (rx_block == upload_block) begin
                retry_count <= 16'd0;
                timer_count <= 16'd0;
                if (upload_last && (upload_len < 10'd512)) begin
                  state <= S_DONE;
                  busy <= 1'b0;
                  done <= 1'b1;
                end else if (upload_last && (upload_len == 10'd512)) begin
                  upload_block_number <= upload_block + 16'd1;
                  final_upload_zero_pending <= 1'b1;
                  state <= S_WAIT_UPLOAD;
                end else begin
                  upload_block_number <= upload_block + 16'd1;
                  state <= S_WAIT_UPLOAD;
                end
              end
            end else if ((state == S_DALLY) && !write_mode &&
                         (rx_opcode == OP_DATA) && download_block_last &&
                         (rx_block == download_block_number) &&
                         (rx_data_len < 10'd512)) begin
              ack_block <= download_block_number;
              ack_return_dally <= 1'b1;
              ack_return_wait <= 1'b0;
              state <= S_SEND_ACK;
            end
          end
        end

        if (wait_state && timeout_hit && !rx_progress) begin
          timer_count <= 16'd0;
          if (retry_count < MAX_RETRIES) begin
            retry_count <= retry_count + 16'd1;
            if (state == S_WAIT_FIRST) state <= S_SEND_REQ;
            else if (state == S_WAIT_DATA) begin
              ack_block <= expected_block - 16'd1;
              ack_return_dally <= 1'b0;
              ack_return_wait <= 1'b1;
              state <= S_SEND_ACK;
            end else if (state == S_WAIT_ACK) state <= S_SEND_DATA;
          end else begin
            fail_client(E_TIMEOUT);
          end
        end

        if ((state == S_DALLY) && timeout_hit && !rx_progress) begin
          state <= S_DONE;
          busy <= 1'b0;
          done <= 1'b1;
          timer_count <= 16'd0;
        end else if (timeout_tick && (state != S_IDLE) && (state != S_DONE) &&
                     (state != S_FAILED) && !timeout_hit && !timer_reset_event) begin
          timer_count <= timer_count + 16'd1;
        end
        // A newly accepted start from S_DONE owns this cycle; do not reassert old done.
        if ((state == S_DONE) && !start_fire) begin
          busy <= 1'b0;
          done <= 1'b1;
        end
      end
    end
  end
endmodule
