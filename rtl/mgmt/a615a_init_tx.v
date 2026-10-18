// 615A initialization-file layout, not a complete 615A/TFTP endpoint.
// LUI/LCI/LND/LNO share: uint32 length, 2-byte version, uint16 status,
// uint8 description length. This bounded encoder emits an empty description.
// The caller supplies the WIRE tag; "A4" is not inferred from edition 615A-4.
// Connected to AFDX_top initialization-source preload; T46 checks encoding.
// Wire transfer remains an explicit host WRQ job, not a full 615A operation.
`timescale 1 ns / 1 ps
module a615a_init_tx (
  input  wire        clk,
  input  wire        rst_sync,
  input  wire        start,
  input  wire [15:0] version,
  input  wire [15:0] status,
  output wire        start_ready,
  output reg         file_valid,
  input  wire        file_ack,
  output wire [15:0] file_length,
  input  wire [3:0]  byte_address,
  output reg  [7:0]  byte_data
);
  reg [15:0] version_q, status_q;
  assign start_ready = !rst_sync && (!file_valid || file_ack);
  assign file_length = 16'd9;
  always @(posedge clk) begin
    if (rst_sync) begin
      file_valid <= 1'b0;
      version_q <= 16'd0;
      status_q <= 16'd0;
    end else begin
      if (file_ack) file_valid <= 1'b0;
      if (start && start_ready) begin
        version_q <= version;
        status_q <= status;
        file_valid <= 1'b1;
      end
    end
  end
  always @* begin
    byte_data = 8'd0;
    if (file_valid) begin
      case (byte_address)
        4'd3: byte_data = 8'd9;
        4'd4: byte_data = version_q[15:8];
        4'd5: byte_data = version_q[7:0];
        4'd6: byte_data = status_q[15:8];
        4'd7: byte_data = status_q[7:0];
        default: byte_data = 8'd0;
      endcase
    end
  end
endmodule
