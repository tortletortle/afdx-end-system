`timescale 1 ns / 1 ps
module rm_probe_top (
  input wire clk, rst_sync,
  input wire in_vld_raw,
  input wire [162:0] in_desc,
  input wire [11:0] in_vl,
  input wire [3:0] in_skew_exp
);
  localparam integer DW = 163;
  localparam integer NUM_RX_VL = 2;
  reg init_done_r, init_we_r;
  reg [12:0] init_addr_r;
  reg [2:0] init_phase;
  wire in_ready, out_vld, out_fwd, out_skew;
  wire [DW-1:0] out_desc;
  wire [11:0] out_vl;
  wire in_vld = init_done_r && in_vld_raw && in_ready;

  rx_rm #(.DW(DW), .NUM_RX_VL(NUM_RX_VL)) dut (
    .clk(clk), .rst_sync(rst_sync),
    .init_done(init_done_r), .init_we(init_we_r), .init_addr(init_addr_r),
    .rm_glb_en(1'b1),
    .in_vld(in_vld), .in_ready(in_ready),
    .in_desc(in_desc), .in_vl(in_vl),
    .in_rm_en(1'b1), .in_net_mode(2'b11), .in_skew_exp(in_skew_exp),
    .out_vld(out_vld), .out_ready(1'b1),
    .out_fwd(out_fwd), .out_skew(out_skew),
    .out_desc(out_desc), .out_vl(out_vl),
    .dbg_en(1'b0), .dbg_wr(1'b0), .dbg_vl(12'd0), .dbg_data(33'd0)
  );

  always @(posedge clk) begin
    if (rst_sync) begin
      init_phase <= 3'd0; init_done_r <= 1'b0; init_we_r <= 1'b0; init_addr_r <= 13'd0;
    end else case (init_phase)
      3'd0: begin init_we_r <= 1'b1; init_addr_r <= 13'd0; init_phase <= 3'd1; end
      3'd1: begin init_we_r <= 1'b1; init_addr_r <= 13'd1; init_phase <= 3'd2; end
      3'd2: begin init_we_r <= 1'b0; init_done_r <= 1'b1; init_phase <= 3'd3; end
      default: begin init_we_r <= 1'b0; init_done_r <= 1'b1; end
    endcase
  end

  always @(*) if ($initstate) assume (rst_sync == 1'b1);
  always @(posedge clk) if (init_done_r) assume (rst_sync == 1'b0);

  // cover: at least one accepted output
  always @(posedge clk) begin
    if (init_done_r && out_vld)
      cover (out_fwd == 1'b1);
  end
endmodule
