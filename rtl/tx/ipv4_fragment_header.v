// Standalone IPv4 base-header formatter for one already-planned fragment.
// Emits exactly 20 bytes; payload bytes and all lower-layer framing are external.
// Project bound: offset*8 + payload_len must not exceed an 8200-byte UDP datagram.
// A final MF=0 fragment may be shorter than 8 bytes; MF=1 fragments are aligned.
// Functional verification pending; not connected to the production TX builder.
`timescale 1 ns / 1 ps
module ipv4_fragment_header (
  input  wire        clk,
  input  wire        rst_sync,
  input  wire        start,
  output wire        start_ready,
  input  wire [7:0]  dscp_ecn,
  input  wire [13:0] payload_len,
  input  wire [15:0] identification,
  input  wire        more_fragments,
  input  wire [12:0] fragment_offset_units,
  input  wire [7:0]  ttl,
  input  wire [7:0]  protocol,
  input  wire [31:0] source_ip,
  input  wire [31:0] destination_ip,
  output wire        header_valid,
  input  wire        header_ready,
  output reg  [7:0]  header_byte,
  output wire        header_last,
  output reg         busy,
  output reg         done,
  output reg         error
);
  reg [7:0] dscp_ecn_reg;
  reg [15:0] total_length_reg;
  reg [15:0] identification_reg;
  reg [15:0] flags_offset_reg;
  reg [7:0] ttl_reg;
  reg [7:0] protocol_reg;
  reg [31:0] source_ip_reg;
  reg [31:0] destination_ip_reg;
  reg [15:0] checksum_reg;
  reg [4:0] byte_index;

  function [15:0] ipv4_checksum;
    input [7:0] dscp;
    input [15:0] total_length;
    input [15:0] identification_value;
    input [15:0] flags_offset;
    input [7:0] ttl_value;
    input [7:0] protocol_value;
    input [31:0] source_value;
    input [31:0] destination_value;
    reg [31:0] sum;
    reg [17:0] folded;
    begin
      sum = {16'd0, 8'h45, dscp} + {16'd0, total_length} +
            {16'd0, identification_value} + {16'd0, flags_offset} +
            {16'd0, ttl_value, protocol_value} +
            {16'd0, source_value[31:16]} + {16'd0, source_value[15:0]} +
            {16'd0, destination_value[31:16]} + {16'd0, destination_value[15:0]};
      folded = {2'b0, sum[15:0]} + sum[31:16];
      folded = {2'b0, folded[15:0]} + folded[17:16];
      ipv4_checksum = ~folded[15:0];
    end
  endfunction

  wire start_fire = start && start_ready;
  wire header_fire = header_valid && header_ready;
  wire [15:0] flags_offset_in = {2'b00, more_fragments, fragment_offset_units};
  wire [15:0] total_length_in = 16'd20 + {2'b00, payload_len};
  wire [16:0] fragment_end_in = {1'b0, fragment_offset_units, 3'b000} +
                                {3'b000, payload_len};
  assign start_ready = !rst_sync && !busy;
  assign header_valid = busy;
  assign header_last = header_valid && (byte_index == 5'd19);

  always @* begin
    case (byte_index)
      5'd0:  header_byte = 8'h45;
      5'd1:  header_byte = dscp_ecn_reg;
      5'd2:  header_byte = total_length_reg[15:8];
      5'd3:  header_byte = total_length_reg[7:0];
      5'd4:  header_byte = identification_reg[15:8];
      5'd5:  header_byte = identification_reg[7:0];
      5'd6:  header_byte = flags_offset_reg[15:8];
      5'd7:  header_byte = flags_offset_reg[7:0];
      5'd8:  header_byte = ttl_reg;
      5'd9:  header_byte = protocol_reg;
      5'd10: header_byte = checksum_reg[15:8];
      5'd11: header_byte = checksum_reg[7:0];
      5'd12: header_byte = source_ip_reg[31:24];
      5'd13: header_byte = source_ip_reg[23:16];
      5'd14: header_byte = source_ip_reg[15:8];
      5'd15: header_byte = source_ip_reg[7:0];
      5'd16: header_byte = destination_ip_reg[31:24];
      5'd17: header_byte = destination_ip_reg[23:16];
      5'd18: header_byte = destination_ip_reg[15:8];
      default: header_byte = destination_ip_reg[7:0];
    endcase
  end

  always @(posedge clk) begin
    if (rst_sync) begin
      dscp_ecn_reg <= 8'd0;
      total_length_reg <= 16'd0;
      identification_reg <= 16'd0;
      flags_offset_reg <= 16'd0;
      ttl_reg <= 8'd0;
      protocol_reg <= 8'd0;
      source_ip_reg <= 32'd0;
      destination_ip_reg <= 32'd0;
      checksum_reg <= 16'd0;
      byte_index <= 5'd0;
      busy <= 1'b0;
      done <= 1'b0;
      error <= 1'b0;
    end else begin
      done <= 1'b0;
      error <= 1'b0;
      if (start_fire) begin
        byte_index <= 5'd0;
        if ((payload_len == 14'd0) || (ttl == 8'd0) ||
            (fragment_end_in > 17'd8200) ||
            (more_fragments && ((payload_len < 14'd8) ||
                                (payload_len[2:0] != 3'b000)))) begin
          busy <= 1'b0;
          error <= 1'b1;
        end else begin
          dscp_ecn_reg <= dscp_ecn;
          total_length_reg <= total_length_in;
          identification_reg <= identification;
          flags_offset_reg <= flags_offset_in;
          ttl_reg <= ttl;
          protocol_reg <= protocol;
          source_ip_reg <= source_ip;
          destination_ip_reg <= destination_ip;
          checksum_reg <= ipv4_checksum(dscp_ecn, total_length_in,
                                         identification, flags_offset_in,
                                         ttl, protocol, source_ip,
                                         destination_ip);
          busy <= 1'b1;
        end
      end else if (header_fire) begin
        if (byte_index == 5'd19) begin
          busy <= 1'b0;
          byte_index <= 5'd0;
          done <= 1'b1;
        end else begin
          byte_index <= byte_index + 5'd1;
        end
      end
    end
  end
endmodule
