// afdx_app_host_arb.v — 封装内主机总线仲裁（init > tx > rx）
// 单拍请求：src_*_req 保持到 grant+ack 完成；rdata 在 ack 拍锁存给获得者。
//
// 重要：host_cs 在 host_ack 为高时组合拉低。AFDX_top 的 msg_commit=we&&msg_valid
// 是电平敏感；若 ACK 拍仍拉着 CS，会在下一拍再次 commit，把刚开的空块封进
// 队列（采样口覆盖），builder 读到未写 PMEM → 载荷/FCS 全 X。T90 用 negedge
// 清 CS 避开；本仲裁器对等处理。
`timescale 1 ns / 1 ps
module afdx_app_host_arb (
  input  wire        clk,
  input  wire        rst,
  // init
  input  wire        i_req,
  input  wire        i_we,
  input  wire [15:0] i_addr,
  input  wire [31:0] i_wdata,
  output wire        i_ack,
  output wire [31:0] i_rdata,
  // tx
  input  wire        t_req,
  input  wire        t_we,
  input  wire [15:0] t_addr,
  input  wire [31:0] t_wdata,
  output wire        t_ack,
  output wire [31:0] t_rdata,
  // rx
  input  wire        r_req,
  input  wire        r_we,
  input  wire [15:0] r_addr,
  input  wire [31:0] r_wdata,
  output wire        r_ack,
  output wire [31:0] r_rdata,
  // to AFDX_top
  output wire        host_cs,
  output reg         host_we,
  output reg  [15:0] host_addr,
  output reg  [31:0] host_wdata,
  input  wire [31:0] host_rdata,
  input  wire        host_ack
);
  localparam [1:0] SEL_IDLE = 2'd0, SEL_I = 2'd1, SEL_T = 2'd2, SEL_R = 2'd3;
  reg [1:0] sel, sel_n;
  reg       pend;
  reg       host_cs_r;

  // ACK 拍组合去 CS，避免 msg_commit 双拍
  assign host_cs = host_cs_r & ~host_ack;

  always @(*) begin
    sel_n = sel;
    if (!pend) begin
      if (i_req) sel_n = SEL_I;
      else if (t_req) sel_n = SEL_T;
      else if (r_req) sel_n = SEL_R;
      else sel_n = SEL_IDLE;
    end
  end

  always @(posedge clk) begin
    if (rst) begin
      sel <= SEL_IDLE;
      pend <= 1'b0;
      host_cs_r <= 1'b0;
      host_we <= 1'b0;
      host_addr <= 16'd0;
      host_wdata <= 32'd0;
    end else begin
      if (!pend) begin
        sel <= sel_n;
        if (sel_n != SEL_IDLE) begin
          pend <= 1'b1;
          host_cs_r <= 1'b1;
          case (sel_n)
            SEL_I: begin host_we <= i_we; host_addr <= i_addr; host_wdata <= i_wdata; end
            SEL_T: begin host_we <= t_we; host_addr <= t_addr; host_wdata <= t_wdata; end
            SEL_R: begin host_we <= r_we; host_addr <= r_addr; host_wdata <= r_wdata; end
            default: begin host_we <= 1'b0; host_addr <= 16'd0; host_wdata <= 32'd0; end
          endcase
        end else begin
          host_cs_r <= 1'b0;
          host_we <= 1'b0;
        end
      end else if (host_ack) begin
        pend <= 1'b0;
        host_cs_r <= 1'b0;
        host_we <= 1'b0;
        sel <= SEL_IDLE;
      end
    end
  end

  wire ack_pulse = pend && host_ack;
  assign i_ack = ack_pulse && (sel == SEL_I);
  assign t_ack = ack_pulse && (sel == SEL_T);
  assign r_ack = ack_pulse && (sel == SEL_R);
  assign i_rdata = host_rdata;
  assign t_rdata = host_rdata;
  assign r_rdata = host_rdata;
endmodule
