// PHY-facing GMII to the existing DA..FCS parser. Synchronous to clk.
// RX_DV is continuous for a frame; ready is intentionally absent.
// A malformed preamble is discarded up to RX_DV falling. RX_ER during
// a body is retained and passed to the parser so even valid-CRC frames
// marked bad by the PHY can never produce a receive descriptor.
`timescale 1 ns / 1 ps
module gmii_rx_strip (
  input wire clk,
  input wire rst_sync,
  input wire [7:0] rx_data,
  input wire rx_valid,
  input wire rx_error,
  output reg [7:0] frame_data,
  output reg frame_valid,
  output reg frame_error,
  output reg [31:0] preamble_drop_count
);
  localparam [1:0] PRE = 2'd0, BODY = 2'd1, DROP = 2'd2;
  reg [1:0] state;
  reg [2:0] pre_count;
  always @(posedge clk) begin
    if (rst_sync) begin
      state <= PRE; pre_count <= 3'd0;
      frame_data <= 8'd0; frame_valid <= 1'b0;
      frame_error <= 1'b0; preamble_drop_count <= 32'd0;
    end else begin
      frame_valid <= 1'b0;
      if (!rx_valid) begin
        state <= PRE; pre_count <= 3'd0; frame_error <= 1'b0;
      end else begin
        case (state)
          PRE: begin
            if (!rx_error && pre_count < 3'd7 && rx_data == 8'h55)
              pre_count <= pre_count + 3'd1;
            else if (!rx_error && pre_count == 3'd7 && rx_data == 8'hD5)
              state <= BODY;
            else begin
              state <= DROP;
              preamble_drop_count <= preamble_drop_count + 32'd1;
            end
          end
          BODY: begin
            frame_data <= rx_data; frame_valid <= 1'b1;
            frame_error <= frame_error | rx_error;
          end
          default: ;
        endcase
      end
    end
  end
endmodule
