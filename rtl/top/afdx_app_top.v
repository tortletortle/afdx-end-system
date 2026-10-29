// =====================================================================
// afdx_app_top.v — 赛方评测封装（应用口 VLID+载荷）
// 核心 AFDX_top 不改；GMII A/B 内部回环。
// 端口名保留模板；tx_data/tx_valid=输入，rx_data/rx_valid=输出（新答疑）。
// 帧格式 / 端口预算 / 口径：out/app_top_*/DESIGN.md
// =====================================================================
`timescale 1 ns / 1 ps
module afdx_app_top #(
  parameter integer NUM_TX_VL = 128,
  parameter integer NUM_RX_VL_CFG = 126,
  parameter integer TX_PORT_BASE = 16,
  parameter integer OBSERVE_GMII = 1
) (
  input  wire        clk,
  input  wire        reset,
  // ---- 模板 8 口名；应用语义（相对指南 data/valid 方向翻转）----
  input  wire [7:0]  tx_data,     // VLID(2B)+应用数据
  output wire [7:0]  rx_data,     // VLID(2B)+应用数据（RM 去重后一次）
  input  wire        tx_valid,
  output wire        rx_valid,
  output wire        tx_ready,    // 观察用；TB 不依赖
  input  wire        rx_ready,    // 可不用
  // ---- 可选 GMII 观察（非模板口）----
  output wire [7:0]  gmii_tx_data_a,
  output wire        gmii_tx_valid_a,
  output wire [7:0]  gmii_tx_data_b,
  output wire        gmii_tx_valid_b
);

  // 同步复位给子模块
  wire rst_sync;
  rst_sync u_rst (.clk(clk), .reset(reset), .rst_sync(rst_sync));

  // ---- host 三路 ----
  wire        i_req, i_we, i_ack;
  wire [15:0] i_addr;
  wire [31:0] i_wdata, i_rdata;
  wire        t_req, t_we, t_ack;
  wire [15:0] t_addr;
  wire [31:0] t_wdata, t_rdata;
  wire        r_req, r_we, r_ack;
  wire [15:0] r_addr;
  wire [31:0] r_wdata, r_rdata;

  wire        host_cs, host_we, host_ack;
  wire [15:0] host_addr;
  wire [31:0] host_wdata, host_rdata;

  wire        cfg_done;
  wire        map_we;
  wire [6:0]  map_vl;
  wire [7:0]  map_port;

  wire [31:0] drop_cnt, submit_cnt, deliver_cnt;

  afdx_app_host_arb u_arb (
    .clk(clk), .rst(rst_sync),
    .i_req(i_req), .i_we(i_we), .i_addr(i_addr), .i_wdata(i_wdata),
    .i_ack(i_ack), .i_rdata(i_rdata),
    .t_req(t_req), .t_we(t_we), .t_addr(t_addr), .t_wdata(t_wdata),
    .t_ack(t_ack), .t_rdata(t_rdata),
    .r_req(r_req), .r_we(r_we), .r_addr(r_addr), .r_wdata(r_wdata),
    .r_ack(r_ack), .r_rdata(r_rdata),
    .host_cs(host_cs), .host_we(host_we), .host_addr(host_addr),
    .host_wdata(host_wdata), .host_rdata(host_rdata), .host_ack(host_ack)
  );

  afdx_app_init #(
    .NUM_TX_VL(NUM_TX_VL),
    .NUM_RX_VL_CFG(NUM_RX_VL_CFG),
    .TX_PORT_BASE(TX_PORT_BASE)
  ) u_init (
    .clk(clk), .rst(rst_sync), .cfg_done(cfg_done),
    .req(i_req), .we(i_we), .addr(i_addr), .wdata(i_wdata),
    .ack(i_ack), .rdata(i_rdata),
    .map_we(map_we), .map_vl(map_vl), .map_port(map_port)
  );

  wire [2:0] tx_dbg_st;
  afdx_app_tx #(
    .TX_PORT_BASE(TX_PORT_BASE)
  ) u_tx (
    .clk(clk), .rst(rst_sync), .cfg_done(cfg_done),
    .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready),
    .req(t_req), .we(t_we), .addr(t_addr), .wdata(t_wdata),
    .ack(t_ack), .rdata(t_rdata),
    .drop_cnt(drop_cnt), .submit_cnt(submit_cnt), .dbg_st(tx_dbg_st)
  );

  wire [7:0] rx_data_w;
  wire       rx_valid_w;
  afdx_app_rx #(
    .NUM_RX(NUM_RX_VL_CFG)
  ) u_rx (
    .clk(clk), .rst(rst_sync), .cfg_done(cfg_done),
    .map_we(map_we), .map_vl(map_vl), .map_port(map_port),
    .rx_data(rx_data_w), .rx_valid(rx_valid_w), .rx_ready(rx_ready),
    .req(r_req), .we(r_we), .addr(r_addr), .wdata(r_wdata),
    .ack(r_ack), .rdata(r_rdata),
    .deliver_cnt(deliver_cnt)
  );
  assign rx_data  = rx_data_w;
  assign rx_valid = rx_valid_w;

  // ---- AFDX_top + GMII 回环（与 T90 同：cfg 后 combo；复位/INIT 期间切断）----
  wire [7:0] mac_tx_a, mac_tx_b;
  wire       mac_dv_a, mac_dv_b;
  wire       mac_tx_ready_a, mac_tx_ready_b;
  wire       loop_en = cfg_done;
  wire [7:0] loop_data_a = loop_en ? mac_tx_a : 8'd0;
  wire       loop_dv_a   = loop_en ? mac_dv_a : 1'b0;
  wire [7:0] loop_data_b = loop_en ? mac_tx_b : 8'd0;
  wire       loop_dv_b   = loop_en ? mac_dv_b : 1'b0;

  assign gmii_tx_data_a  = OBSERVE_GMII ? mac_tx_a : 8'd0;
  assign gmii_tx_valid_a = OBSERVE_GMII ? mac_dv_a : 1'b0;
  assign gmii_tx_data_b  = OBSERVE_GMII ? mac_tx_b : 8'd0;
  assign gmii_tx_valid_b = OBSERVE_GMII ? mac_dv_b : 1'b0;

  AFDX_top u_es (
    .clk(clk), .reset(reset),
    .tx_data(mac_tx_a), .tx_valid(mac_dv_a), .tx_ready(mac_tx_ready_a),
    .rx_data(loop_data_a), .rx_valid(loop_dv_a), .rx_ready(1'b0), .rx_error(1'b0),
    .tx_data_b(mac_tx_b), .tx_valid_b(mac_dv_b), .tx_ready_b(mac_tx_ready_b),
    .rx_data_b(loop_data_b), .rx_valid_b(loop_dv_b), .rx_ready_b(1'b0), .rx_error_b(1'b0),
    .host_cs(host_cs), .host_we(host_we), .host_addr(host_addr),
    .host_wdata(host_wdata), .host_rdata(host_rdata), .host_ack(host_ack),
    .host_irq(),
    .pps_in(1'b0), .pps_out(), .rtc_time_us(), .dbg_frame_event()
  );

  // 防综合优化掉计数器
  // synthesis translate_off
  // 仿真可见
  // synthesis translate_on
  wire unused_ok = |drop_cnt | |submit_cnt | |deliver_cnt | mac_tx_ready_a | mac_tx_ready_b;

endmodule
