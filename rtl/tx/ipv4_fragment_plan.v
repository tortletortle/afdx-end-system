// Standalone IPv4 fragment-boundary planner for one already-sized UDP datagram.
// total_ip_payload_len includes the single UDP header and entire UDP payload.
// max_ip_payload is the per-fragment IPv4 payload limit supplied by the caller.
// Non-final fragment lengths are rounded down to an 8-byte multiple as required
// by the IPv4 fragment-offset unit. This module does not build headers/checksums,
// read message memory, schedule frames, or reassemble RX traffic.
// Maximum supported datagram payload is 8200 bytes (8 KiB application + UDP hdr),
// a project limit for the planned A664 path, not an assertion of full compliance.
// Standalone module; not connected to AFDX_top. Functional verification pending.
`timescale 1 ns / 1 ps
module ipv4_fragment_plan (
  input  wire        clk,
  input  wire        rst_sync,
  input  wire        start,
  output wire        start_ready,
  input  wire [13:0] total_ip_payload_len,
  input  wire [13:0] max_ip_payload,
  output wire        frag_valid,
  input  wire        frag_ready,
  output wire [12:0] frag_offset_units,
  output wire [13:0] frag_payload_len,
  output wire        frag_mf,
  output wire        frag_has_udp_header,
  output reg         done,
  output reg         error
);
  reg active;
  reg [13:0] total_len;
  reg [13:0] chunk_limit;
  reg [13:0] max_payload;
  reg [13:0] next_offset;
  wire [13:0] remaining = total_len - next_offset;
  wire more_fragments = active && (remaining > max_payload);
  wire [13:0] selected_len = more_fragments ? chunk_limit : remaining;
  wire frag_fire = frag_valid && frag_ready;
  wire [13:0] rounded_limit = {max_ip_payload[13:3], 3'b000};

  assign start_ready = !rst_sync && !active;
  assign frag_valid = active && (remaining != 14'd0);
  assign frag_offset_units = next_offset[13:3];
  assign frag_payload_len = selected_len;
  assign frag_mf = more_fragments;
  assign frag_has_udp_header = (next_offset == 14'd0);

  always @(posedge clk) begin
    if (rst_sync) begin
      active <= 1'b0;
      total_len <= 14'd0;
      chunk_limit <= 14'd0;
      max_payload <= 14'd0;
      next_offset <= 14'd0;
      done <= 1'b0;
      error <= 1'b0;
    end else begin
      done <= 1'b0;
      error <= 1'b0;
      if (start && start_ready) begin
        if ((total_ip_payload_len < 14'd8) || (total_ip_payload_len > 14'd8200) ||
            (rounded_limit < 14'd8)) begin
          active <= 1'b0;
          error <= 1'b1;
        end else begin
          active <= 1'b1;
          total_len <= total_ip_payload_len;
          chunk_limit <= rounded_limit;
          max_payload <= max_ip_payload;
          next_offset <= 14'd0;
        end
      end else if (frag_fire) begin
        if (more_fragments) begin
          next_offset <= next_offset + selected_len;
        end else begin
          active <= 1'b0;
          next_offset <= 14'd0;
          done <= 1'b1;
        end
      end
    end
  end
endmodule
