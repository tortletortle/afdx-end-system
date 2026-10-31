// One planned fragment from a complete UDP application message in TX PMEM.
// The caller owns all message blocks until the last fragment has been copied.
// A whole fragment is staged before SOF so PMEM latency never pauses GMII.
// Not connected to AFDX_top yet: allocation, scheduling and release are external.
`timescale 1 ns / 1 ps
module tx_fragment_frame_builder (
  input wire clk, rst_sync,
  input wire start, cancel,
  output wire start_ready,
  input wire [13:0] app_len,
  input wire [15:0] blocks,
  input wire [2:0] block_count,
  // Offset in the complete IP payload, including its single UDP header.
  input wire [13:0] fragment_offset,
  input wire [15:0] identification,
  input wire [15:0] vlid, udi,
  input wire [2:0] ifid_a, ifid_b,
  input wire [7:0] tos, ttl, sequence_number,
  input wire [31:0] source_ip, destination_ip,
  input wire [15:0] source_port, destination_port,
  input wire udp_checksum_enable,
  output wire pmem_req_valid,
  input wire pmem_req_grant,
  output wire [12:0] pmem_req_addr,
  input wire pmem_rsp_valid,
  input wire [31:0] pmem_rsp_data,
  output wire out_valid,
  input wire out_ready,
  output reg [7:0] out_byte_a, out_byte_b,
  output wire out_sof, out_eof,
  output reg done, error,
  output wire busy,
  output reg last_fragment,
  output reg [13:0] next_fragment_offset,
  output reg [10:0] fragment_payload_len
);
  // 1518-byte MAC maximum: Ethernet14+IP20+payload1479+SN1+FCS4.
  // Every non-final IP payload is rounded down to 1472 (multiple of eight).
  localparam [3:0] IDLE=0, CHECK_START=1, CHECK_READ=2, CHECK_FOLD=3,
                   FILL_START=4, FILL_READ=5, HEADER=6, EMIT=7, DRAIN=8;
  reg [3:0] state;
  reg [13:0] length_q, offset_q, window_offset_q, window_length_q;
  reg [15:0] blocks_q, ident_q, vlid_q, udi_q, sport_q, dport_q;
  reg [2:0] count_q, ifid_a_q, ifid_b_q;
  reg [7:0] tos_q, ttl_q, sn_q;
  reg [31:0] source_q, destination_q;
  reg has_udp_q;
  // Single-fragment UDP: fold checksum while FILL (avoids a second full
  // PMEM window that cost ~2k cyc/frame and dropped T94 below 100 Mbps).
  // Multi-fragment first piece still needs a full-message CHECK pass.
  reg fold_during_fill_q;
  reg [31:0] udp_sum;
  reg [7:0] checksum_high;
  reg checksum_odd;
  reg [15:0] udp_checksum, ip_checksum;
  reg [10:0] fill_index, emit_index, frame_length;
  // A final later fragment may use the full 1479-byte payload allowance.
  reg [7:0] frame_data [0:1478];

  wire [14:0] total_in = {1'b0,app_len} + 15'd8;
  wire [14:0] remaining_in = total_in - {1'b0,fragment_offset};
  wire more_in = remaining_in > 15'd1479;
  wire [10:0] frag_length_in = more_in ? 11'd1472 : remaining_in[10:0];
  wire has_udp_in = fragment_offset == 0;
  wire [10:0] app_window_in = frag_length_in - (has_udp_in ? 11'd8 : 11'd0);
  wire [15:0] udp_length = {2'b0,length_q} + 16'd8;
  wire [15:0] ip_length = {5'd0,fragment_payload_len} + 16'd20;
  wire [15:0] flags_offset = {2'b00, !last_fragment, 2'b00, offset_q[13:3]};
  wire [31:0] udp_fold1 = {16'd0,udp_sum[31:16]} + {16'd0,udp_sum[15:0]};
  wire [31:0] udp_fold2 = {16'd0,udp_fold1[31:16]} + {16'd0,udp_fold1[15:0]};
  wire [15:0] checksum_complement = ~udp_fold2[15:0];

  wire reader_ready, reader_error, reader_valid, reader_last, reader_done;
  wire [7:0] reader_byte;
  wire reader_start = !cancel && (state == CHECK_START || state == FILL_START);
  wire reader_accept = !cancel && (state == CHECK_READ || state == FILL_READ);
  tx_pmem_window_reader u_reader (
    .clk(clk), .rst_sync(rst_sync), .start(reader_start), .start_ready(reader_ready),
    .app_len(length_q), .blocks(blocks_q), .block_count(count_q),
    .window_offset(state == CHECK_START ? 14'd0 : window_offset_q),
    .window_len(state == CHECK_START ? length_q : window_length_q),
    .cancel(cancel || state == DRAIN), .start_error(reader_error),
    .pmem_req_valid(pmem_req_valid), .pmem_req_grant(pmem_req_grant),
    .pmem_req_addr(pmem_req_addr), .pmem_rsp_valid(pmem_rsp_valid), .pmem_rsp_data(pmem_rsp_data),
    .byte_valid(reader_valid), .byte_ready(reader_accept), .byte_data(reader_byte),
    .byte_last(reader_last), .done(reader_done)
  );

  assign start_ready = state == IDLE && !rst_sync && !cancel;
  assign busy = state != IDLE;
  assign out_valid = state == EMIT && !rst_sync && !cancel;
  assign out_sof = out_valid && emit_index == 0;
  assign out_eof = out_valid && emit_index == frame_length - 11'd1;

  function [15:0] ip_sum;
    input [7:0] t, life;
    input [15:0] n, id, flags;
    input [31:0] src, dst;
    reg [31:0] sum, folded;
    begin
      sum = {16'd0,8'h45,t} + {16'd0,n} + {16'd0,id} + {16'd0,flags}
          + {16'd0,life,8'h11} + {16'd0,src[31:16]} + {16'd0,src[15:0]}
          + {16'd0,dst[31:16]} + {16'd0,dst[15:0]};
      folded = {16'd0,sum[15:0]} + {16'd0,sum[31:16]};
      folded = {16'd0,folded[15:0]} + {16'd0,folded[31:16]};
      ip_sum = ~folded[15:0];
    end
  endfunction

  reg [7:0] header_byte;
  reg [10:0] ip_payload_index, application_index;
  always @* begin
    header_byte = 8'd0;
    case (emit_index)
      0: header_byte=8'h03; 1: header_byte=8'h00; 2: header_byte=8'h00; 3: header_byte=8'h00;
      4: header_byte=vlid_q[15:8]; 5: header_byte=vlid_q[7:0];
      6: header_byte=8'h02; 7: header_byte=8'h00; 8: header_byte=8'h00;
      9: header_byte=udi_q[15:8]; 10: header_byte=udi_q[7:0];
      11: header_byte={ifid_a_q,5'd0}; 12: header_byte=8'h08; 13: header_byte=8'h00;
      14: header_byte=8'h45; 15: header_byte=tos_q;
      16: header_byte=ip_length[15:8]; 17: header_byte=ip_length[7:0];
      18: header_byte=ident_q[15:8]; 19: header_byte=ident_q[7:0];
      20: header_byte=flags_offset[15:8]; 21: header_byte=flags_offset[7:0];
      22: header_byte=ttl_q; 23: header_byte=8'h11;
      24: header_byte=ip_checksum[15:8]; 25: header_byte=ip_checksum[7:0];
      26: header_byte=source_q[31:24]; 27: header_byte=source_q[23:16];
      28: header_byte=source_q[15:8]; 29: header_byte=source_q[7:0];
      30: header_byte=destination_q[31:24]; 31: header_byte=destination_q[23:16];
      32: header_byte=destination_q[15:8]; 33: header_byte=destination_q[7:0];
      default: header_byte=8'd0;
    endcase
    ip_payload_index = emit_index - 11'd34;
    application_index = ip_payload_index - (has_udp_q ? 11'd8 : 11'd0);
    out_byte_a = header_byte;
    if (emit_index >= 34) begin
      if (emit_index == frame_length-11'd1) out_byte_a = sn_q;
      else if (ip_payload_index >= fragment_payload_len) out_byte_a = 8'd0;
      else if (has_udp_q && ip_payload_index < 8) begin
        case (ip_payload_index)
          0: out_byte_a=sport_q[15:8]; 1: out_byte_a=sport_q[7:0];
          2: out_byte_a=dport_q[15:8]; 3: out_byte_a=dport_q[7:0];
          4: out_byte_a=udp_length[15:8]; 5: out_byte_a=udp_length[7:0];
          6: out_byte_a=udp_checksum[15:8]; default: out_byte_a=udp_checksum[7:0];
        endcase
      end else out_byte_a = frame_data[application_index];
    end
    out_byte_b = emit_index == 11 ? {ifid_b_q,5'd0} : out_byte_a;
  end

  always @(posedge clk) begin
    done <= 1'b0;
    error <= 1'b0;
    if (rst_sync) begin
      state<=IDLE; length_q<=0; offset_q<=0; window_offset_q<=0; window_length_q<=0;
      blocks_q<=0; count_q<=0; ident_q<=0; vlid_q<=0; udi_q<=0;
      sport_q<=0; dport_q<=0; ifid_a_q<=0; ifid_b_q<=0;
      tos_q<=0; ttl_q<=0; sn_q<=0; source_q<=0; destination_q<=0;
      has_udp_q<=0; fold_during_fill_q<=0; udp_sum<=0; checksum_high<=0; checksum_odd<=0;
      udp_checksum<=0; ip_checksum<=0; fill_index<=0; emit_index<=0; frame_length<=0;
      last_fragment<=0; next_fragment_offset<=0; fragment_payload_len<=0;
    end else begin
      case (state)
        IDLE: if (start && !cancel) begin
          if (app_len == 0 || app_len > 14'd8192 || ttl == 0 ||
              fragment_offset[2:0] != 0 || {1'b0,fragment_offset} >= total_in ||
              (!has_udp_in && fragment_offset < 14'd8)) error<=1'b1;
          else begin
            length_q<=app_len; blocks_q<=blocks; count_q<=block_count;
            offset_q<=fragment_offset; ident_q<=identification; vlid_q<=vlid; udi_q<=udi;
            sport_q<=source_port; dport_q<=destination_port; ifid_a_q<=ifid_a; ifid_b_q<=ifid_b;
            tos_q<=tos; ttl_q<=ttl; sn_q<=sequence_number; source_q<=source_ip; destination_q<=destination_ip;
            has_udp_q<=has_udp_in;
            last_fragment<=!more_in; next_fragment_offset<=fragment_offset+{3'd0,frag_length_in};
            fragment_payload_len<=frag_length_in;
            window_offset_q<=has_udp_in ? 14'd0 : fragment_offset-14'd8;
            window_length_q<={3'd0,app_window_in};
            frame_length<=(frag_length_in < 11'd25) ? 11'd60 : frag_length_in+11'd35;
            fill_index<=0; emit_index<=0; udp_checksum<=0; checksum_odd<=0;
            fold_during_fill_q<=udp_checksum_enable && has_udp_in && !more_in;
            // All terms are explicitly widened so no intermediate carry is lost.
            udp_sum<={16'd0,source_ip[31:16]}+{16'd0,source_ip[15:0]}
                    +{16'd0,destination_ip[31:16]}+{16'd0,destination_ip[15:0]}
                    +32'd17+{17'd0,total_in}+{17'd0,total_in}
                    +{16'd0,source_port}+{16'd0,destination_port};
            // Multi-fragment + UDP csum: full-message CHECK, then FILL this window.
            // Single-fragment + UDP csum: FILL folds csum in one pass (T94 path).
            state<=(udp_checksum_enable && has_udp_in && more_in) ? CHECK_START : FILL_START;
          end
        end
        CHECK_START: if (reader_ready) state<=CHECK_READ;
        CHECK_READ: begin
          if (reader_valid) begin
            checksum_odd<=!checksum_odd;
            if (!checksum_odd) begin
              checksum_high<=reader_byte;
              if (reader_last) udp_sum<=udp_sum+{16'd0,reader_byte,8'd0};
            end else udp_sum<=udp_sum+{16'd0,checksum_high,reader_byte};
            if (reader_last) state<=CHECK_FOLD;
          end
        end
        CHECK_FOLD: begin
          udp_checksum<=checksum_complement == 0 ? 16'hffff : checksum_complement;
          // After multi-frag CHECK → FILL; after single-frag merged FILL → HEADER.
          state<=fold_during_fill_q ? HEADER : FILL_START;
        end
        FILL_START: if (reader_ready) state<=FILL_READ;
        FILL_READ: if (reader_valid) begin
          if (fold_during_fill_q) begin
            checksum_odd<=!checksum_odd;
            if (!checksum_odd) begin
              checksum_high<=reader_byte;
              if (reader_last) udp_sum<=udp_sum+{16'd0,reader_byte,8'd0};
            end else udp_sum<=udp_sum+{16'd0,checksum_high,reader_byte};
          end
          frame_data[fill_index]<=reader_byte;
          fill_index<=fill_index+11'd1;
          if (reader_last) state<=fold_during_fill_q ? CHECK_FOLD : HEADER;
        end
        HEADER: begin
          ip_checksum<=ip_sum(tos_q,ttl_q,ip_length,ident_q,flags_offset,source_q,destination_q);
          state<=EMIT;
        end
        EMIT: if (out_ready) begin
          if (out_eof) begin state<=IDLE; done<=1'b1; end
          else emit_index<=emit_index+11'd1;
        end
        DRAIN: if (reader_ready) state<=IDLE;
        default: state<=IDLE;
      endcase
      if (reader_error) begin state<=IDLE; error<=1'b1; end
      if (cancel && state != IDLE) begin state<=DRAIN; done<=1'b0; end
    end
  end
endmodule
