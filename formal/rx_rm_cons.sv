// rx_rm_cons.sv -- RM duplicate-drop BMC (scalar ghost; no unpacked arrays)
// Yosys turns integer-indexed arrays into huge memories + anyseq, which
// false-fails BMC. See formal/rm_bmc20_FAIL_NOTE.md.
//
// Prop (bounded): after a *primary* forward of VL0 that writes last_sn/last_ts,
// a later VL0 output with the same sn and |ts-last_ts| <= skew of THIS accept
// must have out_fwd==0.
//
// Do not latch behind-only hist fills (table last_* unchanged). Detect via
// SN-ring distance vs ghost (same rule as rx_rm.v); no hierarchical refs
// (Yosys may turn dut.wr_ent_q into anyseq).
// NUM_RX_VL=2, VL0 only. Not an unbounded proof.

`timescale 1 ns / 1 ps

module rm_formal_top (
  input  wire         clk,
  input  wire         rst_sync,
  input  wire         in_vld_raw,
  input  wire [162:0] in_desc,
  input  wire [11:0]  in_vl,
  input  wire [3:0]   in_skew_exp
);

  localparam integer DW = 163;
  localparam integer NUM_RX_VL = 2;
  localparam integer HW = 8;

  reg         init_done_r, init_we_r;
  reg [12:0]  init_addr_r;
  reg [2:0]   init_phase;

  wire        in_ready, out_vld, out_fwd, out_skew;
  wire [DW-1:0] out_desc;
  wire [11:0] out_vl;
  wire        in_vld = init_done_r && in_vld_raw && in_ready;
  wire        out_ready = 1'b1;

  rx_rm #(.DW(DW), .NUM_RX_VL(NUM_RX_VL)) dut (
    .clk(clk), .rst_sync(rst_sync),
    .init_done(init_done_r), .init_we(init_we_r), .init_addr(init_addr_r),
    .rm_glb_en(1'b1),
    .in_vld(in_vld), .in_ready(in_ready),
    .in_desc(in_desc), .in_vl(in_vl),
    .in_rm_en(1'b1), .in_net_mode(2'b11), .in_skew_exp(in_skew_exp),
    .out_vld(out_vld), .out_ready(out_ready),
    .out_fwd(out_fwd), .out_skew(out_skew),
    .out_desc(out_desc), .out_vl(out_vl),
    .dbg_en(1'b0), .dbg_wr(1'b0), .dbg_vl(12'd0), .dbg_data(33'd0)
  );

  always @(posedge clk) begin
    if (rst_sync) begin
      init_phase <= 3'd0; init_done_r <= 1'b0;
      init_we_r <= 1'b0; init_addr_r <= 13'd0;
    end else begin
      case (init_phase)
        3'd0: begin init_we_r <= 1'b1; init_addr_r <= 13'd0; init_phase <= 3'd1; end
        3'd1: begin init_we_r <= 1'b1; init_addr_r <= 13'd1; init_phase <= 3'd2; end
        3'd2: begin init_we_r <= 1'b0; init_done_r <= 1'b1; init_phase <= 3'd3; end
        default: begin init_we_r <= 1'b0; init_done_r <= 1'b1; end
      endcase
    end
  end

  always @(*) if ($initstate) assume (rst_sync == 1'b1);

  always @(posedge clk) begin
    if (init_done_r) begin
      assume (rst_sync == 1'b0);
      assume (in_vl == 12'd0);
      assume (in_skew_exp <= 4'd4);
      if (in_vld_raw && !in_ready) begin
        assume ($stable(in_desc));
        assume ($stable(in_skew_exp));
      end
    end
  end

  reg [23:0] sk1, sk2, sk3;
  reg        g_have;
  reg [7:0]  g_sn;
  reg [23:0] g_ts;

  wire [7:0]  out_sn = out_desc[107:100];
  wire [23:0] out_ts = out_desc[147:124];
  wire        out_fire = init_done_r && out_vld && out_ready && (out_vl == 12'd0);
  wire [23:0] dlt = out_ts - g_ts;
  wire [23:0] adlt = dlt[23] ? (~dlt + 24'd1) : dlt;
  wire        in_win = g_have && (out_sn == g_sn) && (adlt <= sk3);

  // Same SN-ring behind test as rx_rm.v (vs ghost last_sn).
  wire        sn_nz = (out_sn != 8'd0) && (g_sn != 8'd0);
  wire [7:0]  f_raw = out_sn - g_sn;
  wire [7:0]  f = (out_sn < g_sn) ? (f_raw - 8'd1) : f_raw;
  wire [7:0]  d_back = 8'd255 - f;
  wire        behind = g_have && sn_nz && (f >= 8'd128) && (d_back <= HW);
  wire        primary_wr = out_fwd && !behind;

  always @(posedge clk) begin
    if (rst_sync) begin
      sk1 <= 24'd0; sk2 <= 24'd0; sk3 <= 24'd0;
      g_have <= 1'b0; g_sn <= 8'd0; g_ts <= 24'd0;
    end else if (init_done_r) begin
      if (in_vld && in_ready)
        sk1 <= (24'd4 << in_skew_exp);
      else
        sk1 <= 24'd0;
      sk2 <= sk1;
      sk3 <= sk2;

      if (out_fire) begin
        if (in_win)
          assert (out_fwd == 1'b0);
        if (primary_wr) begin
          g_have <= 1'b1;
          g_sn   <= out_sn;
          g_ts   <= out_ts;
        end
      end
    end
  end

endmodule
