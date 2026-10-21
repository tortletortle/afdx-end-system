// =====================================================================
// AFDX_top_chipsim.v —— 芯片仿真缩配包装
// 例化满配源 AFDX_top，只覆盖规模参数。默认综合/70 项回归仍以 AFDX_top 为顶。
//
// 刻意保持 PMEM_KB=32：块池按 16×2 KB 写死，缩 PMEM 会让块号越出 RAM。
// HASH_BUCKETS 必须为 2 的幂（lookup 用低位作桶号）。
// 2026-10-21 P1.1：补 rx_error/rx_error_b 并接到 u_es（漏接会悬空成 z，
// gmii_rx_strip 遇 x 进 DROP）。对照见 T88a 修复前后日志。
// =====================================================================
`timescale 1 ns / 1 ps
module AFDX_top_chipsim (
  input  wire        clk,
  input  wire        reset,
  output wire [7:0]  tx_data,
  input  wire [7:0]  rx_data,
  output wire        tx_valid,
  input  wire        rx_valid,
  output wire        tx_ready,
  input  wire        rx_ready,
  output wire [7:0]  tx_data_b,
  output wire        tx_valid_b,
  output wire        tx_ready_b,
  input  wire [7:0]  rx_data_b,
  input  wire        rx_valid_b,
  input  wire        rx_ready_b,
  input  wire        host_cs,
  input  wire        host_we,
  input  wire [15:0] host_addr,
  input  wire [31:0] host_wdata,
  output wire [31:0] host_rdata,
  output wire        host_ack,
  output wire        host_irq,
  input  wire        pps_in,
  output wire        pps_out,
  output wire [63:0] rtc_time_us,
  output wire [3:0]  dbg_frame_event,
  input  wire        rx_error,
  input  wire        rx_error_b
);
  AFDX_top #(
    .NUM_TX_VL(16),
    .NUM_RX_VL(64),
    .NUM_PORTS(16),
    .PMEM_KB(32),
    .HASH_BUCKETS(64),
    .LOAD_WORDS(256),
    .SNMP_EN(0),
    .TFTP_EN(0),
    .STATS_EN(0),
    .RTC_EN(1),
    .DUAL_NET_EN(0)
  ) u_es (
    .clk(clk), .reset(reset),
    .tx_data(tx_data), .rx_data(rx_data),
    .tx_valid(tx_valid), .rx_valid(rx_valid),
    .tx_ready(tx_ready), .rx_ready(rx_ready),
    .tx_data_b(tx_data_b), .tx_valid_b(tx_valid_b), .tx_ready_b(tx_ready_b),
    .rx_data_b(rx_data_b), .rx_valid_b(rx_valid_b), .rx_ready_b(rx_ready_b),
    .rx_error(rx_error), .rx_error_b(rx_error_b),
    .host_cs(host_cs), .host_we(host_we), .host_addr(host_addr),
    .host_wdata(host_wdata), .host_rdata(host_rdata),
    .host_ack(host_ack), .host_irq(host_irq),
    .pps_in(pps_in), .pps_out(pps_out), .rtc_time_us(rtc_time_us),
    .dbg_frame_event(dbg_frame_event)
  );
endmodule
