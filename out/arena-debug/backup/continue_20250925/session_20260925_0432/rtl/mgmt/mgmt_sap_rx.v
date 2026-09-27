// =====================================================================
// mgmt_sap_rx.v -- minimal SAP descriptor handoff / block-return endpoint.
// It is deliberately not an SNMP BER or ARINC-615A application engine. A
// validated type=SAP port descriptor is captured, exposed in MGMT_WIN for
// observability, then held until the top-level RX-pool arbiter accepts its
// block return. Thus it closes ownership/accounting without pretending that
// a protocol response path exists.
// =====================================================================
`timescale 1 ns / 1 ps
module mgmt_sap_rx (
  input  wire        clk,
  input  wire        rst_sync,
  input  wire        in_vld,
  output wire        in_ready,
  input  wire [7:0]  in_port,
  input  wire [3:0]  in_blk,
  input  wire [10:0] in_plen,
  output wire        free_req,
  input  wire        free_take,
  output wire [3:0]  free_id,
  output reg  [31:0] accept_cnt,
  output reg  [31:0] free_cnt,
  output reg  [31:0] last_desc
);
  reg pending;
  reg [3:0] pending_blk;
  // One descriptor is sufficient for the minimal handoff. Backpressure
  // propagates through parser/RM while a prior descriptor awaits free_take.
  assign in_ready = !rst_sync && !pending;
  assign free_req = pending;
  assign free_id  = pending_blk;
  always @(posedge clk) begin
    if (rst_sync) begin
      pending <= 1'b0; pending_blk <= 4'd0;
      accept_cnt <= 32'd0; free_cnt <= 32'd0; last_desc <= 32'd0;
    end else begin
      if (pending && free_take) begin
        pending <= 1'b0;
        free_cnt <= free_cnt + 32'd1;
      end
      if (in_vld && in_ready) begin
        pending <= 1'b1;
        pending_blk <= in_blk;
        accept_cnt <= accept_cnt + 32'd1;
        // [31] valid; [22:15] port; [14:11] RX block; [10:0] UDP payload.
        last_desc <= {1'b1,8'd0,in_port,in_blk,in_plen};
      end
    end
  end
endmodule
