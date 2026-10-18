// Bounded 615A LUR file parser. Input is a complete file stream AFTER TFTP
// block validation/reassembly, not UDP packets and not per-block SOP/EOP.
// All entries remain inaccessible until the whole file validates.
// 8 KiB buffer, 1..MAX_FILES entries, printable ASCII names terminated by NUL.
// Filename/part-number field lengths include their NUL, range 2..255.
// This is a project capacity/profile. It is not a complete 615A operation.
// Not connected to AFDX_top yet. Functional verification is pending.
`timescale 1 ns / 1 ps
module a615a_lur_rx #(
  parameter integer MAX_FILES = 8  // Supported elaboration range: 1..8.
) (
  input  wire        clk,
  input  wire        rst_sync,
  input  wire [15:0] expected_version,
  input  wire        in_valid,
  output wire        in_ready,
  input  wire        in_sop,
  input  wire        in_eop,
  input  wire [7:0]  in_data,
  output reg         result_valid,
  input  wire        result_ack,
  output wire        request_ok,
  output reg  [3:0]  error_code,
  output reg  [15:0] file_count,
  input  wire [2:0]  file_select,
  output reg  [7:0]  filename_length,
  output reg  [7:0]  part_number_length,
  input  wire        name_read,
  input  wire        select_part_number,
  input  wire [7:0]  name_byte_index,
  output wire [7:0]  name_byte,
  output reg         name_byte_valid
);
  localparam [2:0] S_IDLE=3'd0, S_COLLECT=3'd1, S_ISSUE=3'd2,
                   S_PARSE=3'd3, S_RESULT=3'd4, S_DROP=3'd5;
  localparam [1:0] P_NAME_LEN=2'd0, P_NAME=2'd1, P_PART_LEN=2'd2, P_PART=2'd3;
  localparam [3:0] E_LENGTH=4'd1, E_VERSION=4'd2, E_COUNT=4'd3,
                   E_STRING=4'd4, E_TRUNCATED=4'd5, E_OVERFLOW=4'd6,
                   E_SEQUENCE=4'd7, E_TRAILING=4'd8;
  reg [2:0] state;
  reg [1:0] phase;
  reg [13:0] write_count, captured_length;
  reg [12:0] parse_index;
  reg [31:0] declared_length;
  reg [15:0] version_q, declared_count;
  reg [7:0] high_byte, string_left;
  reg [2:0] entry_index;
  reg [12:0] filename_offset [0:MAX_FILES-1];
  reg [12:0] part_offset [0:MAX_FILES-1];
  reg [7:0] filename_size [0:MAX_FILES-1];
  reg [7:0] part_size [0:MAX_FILES-1];

  wire version_supported = (expected_version[15:8] == 8'h41) &&
                           (expected_version[7:0] >= 8'h31) &&
                           (expected_version[7:0] <= 8'h34);
  assign in_ready = !rst_sync && ((state==S_IDLE) || (state==S_COLLECT) || (state==S_DROP));
  assign request_ok = result_valid && (error_code==4'd0);
  wire input_fire = in_valid && in_ready;
  wire memory_write = input_fire &&
      (((state==S_IDLE) && in_sop && version_supported) ||
       ((state==S_COLLECT) && !in_sop && (write_count < 14'd8192)));
  wire [12:0] memory_write_address = (state==S_IDLE) ? 13'd0 : write_count[12:0];
  reg query_valid;
  reg [12:0] query_address;
  always @* begin
    filename_length = 8'd0;
    part_number_length = 8'd0;
    query_valid = 1'b0;
    query_address = 13'd0;
    if (request_ok && !result_ack && (file_select < MAX_FILES) && (file_select < file_count)) begin
      filename_length = filename_size[file_select];
      part_number_length = part_size[file_select];
      if (name_read && !select_part_number && (name_byte_index < filename_size[file_select])) begin
        query_address = filename_offset[file_select] + {5'd0,name_byte_index};
        query_valid = 1'b1;
      end else if (name_read && select_part_number && (name_byte_index < part_size[file_select])) begin
        query_address = part_offset[file_select] + {5'd0,name_byte_index};
        query_valid = 1'b1;
      end
    end
  end
  wire [12:0] memory_read_address = (state==S_RESULT) ? query_address : parse_index;
  wire [7:0] memory_byte;
  bram_1w1r #(.W(8),.D(8192),.RD_NEG(0)) u_file (
    .clk(clk),.wr_en(memory_write),.wr_addr(memory_write_address),.wr_data(in_data),
    .rd_addr(memory_read_address),.rd_data(memory_byte)
  );
  assign name_byte = name_byte_valid ? memory_byte : 8'd0;
  always @(posedge clk) begin
    if (rst_sync) name_byte_valid <= 1'b0;
    else name_byte_valid <= query_valid;
  end

  task reject_file;
    input [3:0] code;
    begin
      state <= S_RESULT;
      result_valid <= 1'b1;
      error_code <= code;
      file_count <= 16'd0;
    end
  endtask

  always @(posedge clk) begin
    if (rst_sync) begin
      state <= S_IDLE;
      phase <= P_NAME_LEN;
      write_count <= 14'd0;
      captured_length <= 14'd0;
      parse_index <= 13'd0;
      declared_length <= 32'd0;
      declared_count <= 16'd0;
      version_q <= 16'd0;
      high_byte <= 8'd0;
      string_left <= 8'd0;
      entry_index <= 3'd0;
      result_valid <= 1'b0;
      error_code <= 4'd0;
      file_count <= 16'd0;
    end else begin
      case (state)
        S_IDLE: if (input_fire) begin
          result_valid <= 1'b0;
          error_code <= 4'd0;
          file_count <= 16'd0;
          write_count <= 14'd1;
          declared_length <= 32'd0;
          declared_count <= 16'd0;
          version_q <= expected_version;
          parse_index <= 13'd0;
          entry_index <= 3'd0;
          phase <= P_NAME_LEN;
          if (!in_sop || !version_supported) begin
            error_code <= !in_sop ? E_SEQUENCE : E_VERSION;
            if (in_eop) reject_file(!in_sop ? E_SEQUENCE : E_VERSION);
            else state <= S_DROP;
          end else if (in_eop) begin
            reject_file(E_TRUNCATED);
          end else state <= S_COLLECT;
        end
        S_COLLECT: if (input_fire) begin
          if (in_sop) begin
            error_code <= E_SEQUENCE;
            if (in_eop) reject_file(E_SEQUENCE);
            else state <= S_DROP;
          end else begin
            write_count <= write_count + 14'd1;
            if (in_eop) begin
              captured_length <= write_count + 14'd1;
              parse_index <= 13'd0;
              state <= S_ISSUE;
              if (write_count + 14'd1 < 14'd8) reject_file(E_TRUNCATED);
            end else if (write_count == 14'd8191) begin
              error_code <= E_OVERFLOW;
              state <= S_DROP;
            end
          end
        end
        S_DROP: if (input_fire && in_eop) reject_file(error_code);
        S_ISSUE: state <= S_PARSE;  // Synchronous BRAM read at this edge.
        S_PARSE: begin
          state <= S_ISSUE;
          parse_index <= parse_index + 13'd1;
          // Only a complete final part-number field can override this failure.
          if ({1'b0,parse_index}+14'd1 >= captured_length) reject_file(E_TRUNCATED);
          if (parse_index <= 13'd3) begin
            declared_length <= {declared_length[23:0],memory_byte};
            if ((parse_index==13'd3) &&
                ({declared_length[23:0],memory_byte} != {18'd0,captured_length}))
              reject_file(E_LENGTH);
          end else if (parse_index==13'd4) begin
            high_byte <= memory_byte;
          end else if (parse_index==13'd5) begin
            if ({high_byte,memory_byte} != version_q) reject_file(E_VERSION);
          end else if (parse_index==13'd6) begin
            high_byte <= memory_byte;
          end else if (parse_index==13'd7) begin
            declared_count <= {high_byte,memory_byte};
            if (({high_byte,memory_byte}==16'd0) || ({high_byte,memory_byte}>MAX_FILES))
              reject_file(E_COUNT);
          end else begin
            case (phase)
              P_NAME_LEN: begin
                if (memory_byte < 8'd2) reject_file(E_STRING);
                else begin
                  filename_offset[entry_index] <= parse_index + 13'd1;
                  filename_size[entry_index] <= memory_byte;
                  string_left <= memory_byte;
                  phase <= P_NAME;
                end
              end
              P_NAME: begin
                string_left <= string_left - 8'd1;
                if (string_left==8'd1) begin
                  if (memory_byte!=8'd0) reject_file(E_STRING);
                  else phase <= P_PART_LEN;
                end else if ((memory_byte<8'h20) || (memory_byte>8'h7e)) reject_file(E_STRING);
              end
              P_PART_LEN: begin
                if (memory_byte < 8'd2) reject_file(E_STRING);
                else begin
                  part_offset[entry_index] <= parse_index + 13'd1;
                  part_size[entry_index] <= memory_byte;
                  string_left <= memory_byte;
                  phase <= P_PART;
                end
              end
              P_PART: begin
                string_left <= string_left - 8'd1;
                if (string_left==8'd1) begin
                  if (memory_byte!=8'd0) reject_file(E_STRING);
                  else if ({13'd0,entry_index}+16'd1==declared_count) begin
                    if ({1'b0,parse_index}+14'd1!=captured_length) reject_file(E_TRAILING);
                    else begin
                      state <= S_RESULT;
                      result_valid <= 1'b1;
                      error_code <= 4'd0;
                      file_count <= declared_count;
                    end
                  end else begin
                    entry_index <= entry_index + 3'd1;
                    phase <= P_NAME_LEN;
                  end
                end else if ((memory_byte<8'h20) || (memory_byte>8'h7e)) reject_file(E_STRING);
              end
              default: reject_file(E_SEQUENCE);
            endcase
          end
        end
        S_RESULT: if (result_ack) begin
          result_valid <= 1'b0;
          file_count <= 16'd0;
          error_code <= 4'd0;
          state <= S_IDLE;
        end
        default: begin
          state <= S_IDLE;
          result_valid <= 1'b0;
          file_count <= 16'd0;
          error_code <= 4'd0;
        end
      endcase
    end
  end
endmodule
