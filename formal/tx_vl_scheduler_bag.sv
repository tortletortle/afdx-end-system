// tx_vl_scheduler_bag.sv -- BAG interval BMC wrapper (no bind; no hier refs)
// Prop: same VL consecutive *start_vld* (grant) spacing >= BAG_US.
// NUM_TX_VL=4, NUM_PORTS=8, CYCLES_PER_US=1. Read-only RTL.
// bmc20 is vacuous for second-grant (cover ~27); do not cite as BAG proof.

`timescale 1 ns / 1 ps

module bag_formal_top (
  input  wire        clk,
  input  wire        rst_sync,
  input  wire [7:0]  port_ready,
  input  wire        sch_ack,
  input  wire [3:0]  sch_blk,
  input  wire [12:0] sch_len,
  input  wire        builder_busy,
  input  wire        builder_len_err,
  input  wire        frame_start
);

  localparam integer NVL = 4;
  localparam integer NPR = 8;
  localparam [23:0] BAG_US = 24'd4;

  reg [7:0] tick;
  reg       seen_run;
  wire      cfg_active = !rst_sync && (tick < 8'd4);
  wire      run        = !rst_sync && (tick >= 8'd4);
  wire      cfg_we     = cfg_active;
  wire      cfg_valid  = cfg_active;
  wire [6:0] cfg_vl    = tick[6:0];
  wire [7:0] cfg_port  = {1'b0, tick[6:0]};
  wire [23:0] cfg_bag_us = BAG_US;
  wire      enable     = run;

  always @(posedge clk) begin
    if (rst_sync) begin
      tick <= 8'd0;
      seen_run <= 1'b0;
    end else begin
      if (tick != 8'hff) tick <= tick + 8'd1;
      if (tick >= 8'd4) seen_run <= 1'b1;
    end
  end

  wire        sch_take;
  wire [7:0]  sch_port;
  wire        start_vld;
  wire [7:0]  start_vl;
  wire [3:0]  start_blk;
  wire [12:0] start_len;
  wire        frame_permit;
  wire        bag_viol;
  wire [15:0] bag_ovf_cnt, take_miss_cnt;
  wire [7:0]  vl_valid_cnt;
  wire        start_cfg_rd;

  tx_vl_scheduler #(
    .NUM_TX_VL(NVL),
    .NUM_PORTS(NPR),
    .CYCLES_PER_US(1),
    .BAG_UPDATE_EN(0),
    .PREPARE_CYCLES(0)
  ) dut (
    .clk(clk),
    .rst_sync(rst_sync),
    .enable(enable),
    .tb_us(24'd0),
    .cfg_we(cfg_we),
    .cfg_vl(cfg_vl),
    .cfg_valid(cfg_valid),
    .cfg_bag_us(cfg_bag_us),
    .cfg_port(cfg_port),
    .cfg_bag_only(1'b0),
    .port_ready(port_ready),
    .sch_take(sch_take),
    .sch_port(sch_port),
    .sch_ack(sch_ack),
    .sch_blk(sch_blk),
    .sch_len(sch_len),
    .start_vld(start_vld),
    .start_vl(start_vl),
    .start_blk(start_blk),
    .start_len(start_len),
    .builder_busy(builder_busy),
    .builder_len_err(builder_len_err),
    .frame_start(frame_start),
    .frame_permit(frame_permit),
    .bag_viol(bag_viol),
    .bag_ovf_cnt(bag_ovf_cnt),
    .take_miss_cnt(take_miss_cnt),
    .vl_valid_cnt(vl_valid_cnt),
    .start_cfg_rd(start_cfg_rd)
  );

  reg [31:0] cyc;
  always @(posedge clk) begin
    if (rst_sync) cyc <= 32'd0;
    else          cyc <= cyc + 32'd1;
  end

  // Grant-anchor ghost (no IFQ): last start_vld cycle per VL.
  reg        s0, s1, s2, s3;
  reg [31:0] l0, l1, l2, l3;
  wire [1:0] gvl = start_vl[1:0];
  wire       grant = run && start_vld && (start_vl[6:0] < NVL);
  wire       s_g = (gvl==0)?s0:(gvl==1)?s1:(gvl==2)?s2:s3;
  wire [31:0] l_g = (gvl==0)?l0:(gvl==1)?l1:(gvl==2)?l2:l3;

  always @(posedge clk) begin
    if (rst_sync) begin
      s0<=0;s1<=0;s2<=0;s3<=0;
      l0<=0;l1<=0;l2<=0;l3<=0;
    end else if (grant) begin
      case (gvl)
        2'd0: begin l0<=cyc; s0<=1'b1; end
        2'd1: begin l1<=cyc; s1<=1'b1; end
        2'd2: begin l2<=cyc; s2<=1'b1; end
        default: begin l3<=cyc; s3<=1'b1; end
      endcase
    end
  end

  always @(*) begin
    if ($initstate) assume (rst_sync == 1'b1);
  end

  always @(posedge clk) begin
    if (seen_run || run)
      assume (rst_sync == 1'b0);
    if (!rst_sync) begin
      assume (sch_len >= 13'd1 && sch_len <= 13'd64);
      assume (builder_len_err == 1'b0);
      if (cfg_active)
        assume (frame_start == 1'b0);
      if (run) begin
        assume (sch_ack == 1'b1);
        assume (builder_busy == 1'b0);
        assume (port_ready == {NPR{1'b1}});
        // Pop one cycle after grant (MAC start follows builder).
        assume (frame_start == $past(start_vld && run));
        if (grant && s_g)
          assert ((cyc - l_g) >= {1'b0, BAG_US[30:0]});
      end
    end
  end

  always @(posedge clk) begin
    cover (run);
    cover (grant);
    cover (run && grant && s_g);  // second grant of a VL (arms assert)
  end

endmodule
