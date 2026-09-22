// =====================================================================
// AFDX_top.v —— AFDX 端系统顶层（第 0/1 周骨架版）
// 设计书: §5.1（顶层端口总表）/ §4.2（复位）/ §4.3（参数表）/
//         §7.14 + 附录 A（寄存器页，doc/regs.yaml 为单一来源）/ §7.18（时基）
// 状态: 寄存器页 + 时基 + 复位为真实实现；tx/rx/mgmt 子系按 §13 于
//       第 2~5 周实例化（见下方 TODO）。空壳 AFDX_top 须 ModelSim 与
//       eLinx 双双通过（§13 第 1 周出口条件）。
// 命名/握手: §10（信号小写下划线、参数大写下划线、vld/rdy 或 pulse）
// =====================================================================
`timescale 1 ns / 1 ps
/* verilator lint_off UNUSED */
// 骨架期: rx_data*/rx_valid*/rx_ready*/pps_in/tick_us 尚未消费
// （第 3 周起子系统例化后消费，届时删除本开关与下方 lint_on）
module AFDX_top #(
  // ---- §4.3 参数表 ----
  parameter integer NUM_TX_VL     = 128,
  parameter integer NUM_RX_VL     = 4096,
  parameter integer NUM_PORTS     = 256,
  parameter integer PMEM_KB       = 32,
  parameter integer MAX_FRAME     = 1518,
  parameter integer CLK_FREQ_HZ   = 125_000_000,
  parameter integer BYTE_SLOT_CYC = 10,
  parameter integer IFG_BYTES     = 12,
  parameter integer DUAL_NET_EN   = 1,
  parameter integer FCS_MODE      = 2,
  parameter integer IC_EN         = 1,
  parameter integer RM_EN         = 1,
  parameter integer SNMP_EN       = 1,
  parameter integer TFTP_EN       = 1,
  parameter integer RTC_EN        = 1,
  parameter integer SUBVL_MAX     = 8,
  parameter integer TICK_US       = 1,
  parameter integer STATS_EN      = 1
) (
  // ---- 模板 8 端口（§5.2: 保留原样，方向与位宽不动）----
  input  wire        clk,
  input  wire        reset,
  output wire [7:0]  tx_data,
  input  wire [7:0]  rx_data,
  output wire        tx_valid,
  input  wire        rx_valid,
  output wire        tx_ready,
  input  wire        rx_ready,
  // ---- 扩展端口：网络 B（DUAL_NET_EN，§5.2 追加在模板之后）----
  output wire [7:0]  tx_data_b,
  output wire        tx_valid_b,
  output wire        tx_ready_b,
  input  wire [7:0]  rx_data_b,
  input  wire        rx_valid_b,
  input  wire        rx_ready_b,
  // ---- 扩展端口：主机接口（§5.4 两拍协议）----
  input  wire        host_cs,
  input  wire        host_we,
  input  wire [15:0] host_addr,
  input  wire [31:0] host_wdata,
  output wire [31:0] host_rdata,
  output wire        host_ack,
  output wire        host_irq,
  // ---- 扩展端口：时基 / 调试（§5.1，dbg_* 综合时可 tie off）----
  input  wire        pps_in,
  output wire        pps_out,
  output wire [63:0] rtc_time_us,
  output wire [3:0]  dbg_frame_event
);

  // ---- 复位同步（§4.2）----
  wire rst_sync;
  rst_sync u_rstsync (.clk(clk), .reset(reset), .rst_sync(rst_sync));

  // 寄存器页存储（声明须先于使用时序：timebase 的 rtc_hold 引 ctl_r[11]）
  reg [31:0] ctl_r, int_en_r, err_r, int_st_r;
  reg [31:0] smac_r, ip_r, udp_cfg_r, burst_addr_r, burst_len_r, burst_data_r, dbg_ctrl_r;
  reg [31:0] rdata_r;

  // ---- 时基（§7.18）----
  wire        tick_us;
  wire [63:0] rtc64;
  wire        alive;
  // FREQ_ADJ 名义值 = 2^16 × 1e6/CLK_FREQ_HZ @125 MHz = 524（rtc64 计 μs）
  // 注: 文档 §7.18 的 100e6/CLK_FREQ_HZ 写法疑 100 倍笔误，见 doc_第0周问题清单
  localparam [15:0] FREQ_ADJ_NOM = 16'd524;
  timebase #(
    .TICK_US     (TICK_US)
  ) u_timebase (
    .clk      (clk),
    .rst      (rst_sync),
    .rtc_hold (ctl_r[11]),        // CTL.RTC_HOLD（bit11，§7.14）
    .freq_adj (FREQ_ADJ_NOM),     // TODO 第 5 周: 由 rtc_sync 按 pps_in 微调
    .rtc64    (rtc64),
    .tick_us  (tick_us),
    .alive    (alive)
  );
  assign rtc_time_us = rtc64;
  assign pps_out     = 1'b0;      // TODO 第 5 周: rtc_sync 生成秒脉冲（§7.15）

  // ---- 寄存器页（§7.14 0x0000~0x00FF，位域见附录 A / doc/regs.yaml）----
  localparam [31:0] REG_ID    = {16'hAF07, NUM_RX_VL[15:0]}; // A.1: [31:16]=0xAF07, [15:0]=NUM_RX_VL
  localparam [31:0] REG_REV   = 32'h4_0000;                  // v4.0 build 0
  localparam [31:0] CTL_RST   = 32'h51C;                     // A.1: bit2/3/4/8/10 默认 1
  localparam [31:0] CTL_WMASK = 32'hFFFF_EFDF;               // 保留位 bit5/bit12 写无效、读回 0（~0x1020）

  // 主机总线两拍协议（§5.4）: 第 1 拍 cs+地址/数据，第 2 拍 ack+rdata
  reg cs_d;
  always @(posedge clk)
    cs_d <= host_cs;
  wire hs = host_cs & ~cs_d;                    // 第 1 拍（cs 上升沿窗口）
  wire we = host_we & hs;                       // 第 1 拍写使能
  assign host_rdata = rdata_r;                  // 第 2 拍有效（§5.4）
  reg ack_r;
  always @(posedge clk)
    if (rst_sync) ack_r <= 1'b0;
    else          ack_r <= hs;
  assign host_ack = ack_r;

  wire [7:0] off      = host_addr[7:0];
  wire page_hi       = (host_addr[15:8] != 8'h00);
  wire drop_k        = (off >= 8'h20) && (off <= 8'h4C) && (off[1:0] == 2'b00); // DROP_CNT_K[0..11]
  wire misaligned    = (off[1:0] != 2'b00);
  wire ro_hit = (off == 8'h00 || off == 8'h04 || off == 8'h0C || off == 8'h1C ||
                 off == 8'h50 || off == 8'h54 || off == 8'h58 || off == 8'h5C ||
                 off == 8'h68 || off == 8'h6C);

  // 读 mux（第 1 拍采样、第 2 拍有效；未列出地址 → DEAD_BEEF，§7.14）
  // 读未命中（未列出地址 / 非字对齐）→ DEAD_BEEF 并置 ERR.ACC（§7.14）
  wire rd_miss = hs & ~we & (page_hi || misaligned);
  // 写未命中或 R/W 属性违规 → ERR.ACC（§7.14）
  wire wr_bad  = we & (page_hi || drop_k || misaligned || ro_hit);

  always @(posedge clk) begin
    if (hs) begin
      if (page_hi || misaligned)
        rdata_r <= 32'hDEAD_BEEF;
      else if (drop_k)
        rdata_r <= 32'd0;                        // DROP_CNT_K（TODO 第 4 周: 分原因计数）
      else
        case (off)
          8'h00: rdata_r <= REG_ID;
          8'h04: rdata_r <= REG_REV;
          8'h08: rdata_r <= ctl_r;
          8'h0C: rdata_r <= {alive, 18'h0,
                             2'b00,              // OVF_CNT_MAX
                             1'b0,               // CRC_ERR
                             1'b0,               // BAG_VIOL
                             1'b0,               // DROP_STORM
                             6'd16,              // PMEM_FREE = 16 块全空闲
                             1'b0,               // BUILDER_BUSY
                             1'b0};              // SCHED_BUSY
          8'h10: rdata_r <= err_r;
          8'h14: rdata_r <= int_en_r;
          8'h18: rdata_r <= int_st_r;
          8'h1C: rdata_r <= 32'd0;               // DROP_CNT 合计（TODO 第 4 周）
          8'h50: rdata_r <= rtc64[31:0];         // TB_CNT_US
          8'h54: rdata_r <= rtc64[63:32];        // TB_CNT_US_HI
          8'h58: rdata_r <= 32'd0;               // CFG_SUM（TODO 第 2 周: CFG_MODE 下判决写入）
          8'h5C: rdata_r <= 32'd0;               // CFG_ERR
          8'h60: rdata_r <= smac_r;
          8'h64: rdata_r <= ip_r;
          8'h68: rdata_r <= 32'd0;               // TFTP_PEER_PORT（TODO 第 5 周）
          8'h6C: rdata_r <= 32'd0;               // SNMP_PEER_IP（TODO 第 5 周）
          8'h70: rdata_r <= udp_cfg_r;
          8'hF0: rdata_r <= burst_addr_r;
          8'hF4: rdata_r <= burst_len_r;
          8'hF8: rdata_r <= burst_data_r;
          8'hFC: rdata_r <= dbg_ctrl_r;
          default: rdata_r <= 32'hDEAD_BEEF;
        endcase
    end
  end

  // 写 mux（§7.14: 未列出地址或 R/W 属性违规 → ERR.ACC；W1C 单独处理）
  wire w1c_err = we & ~page_hi & ~misaligned & (off == 8'h10);
  wire w1c_int = we & ~page_hi & ~misaligned & (off == 8'h18);
  always @(posedge clk) begin
    if (rst_sync) begin
      ctl_r        <= CTL_RST;
      int_en_r     <= 32'd0;
      err_r        <= 32'd0;
      int_st_r     <= 32'd0;
      smac_r       <= 32'd0;
      ip_r         <= 32'd0;
      udp_cfg_r    <= 32'h140;             // regs.yaml 复位值
      burst_addr_r <= 32'd0;
      burst_len_r  <= 32'd0;
      burst_data_r <= 32'd0;
      dbg_ctrl_r   <= 32'd0;
    end else begin
      if (wr_bad || rd_miss)
        err_r <= (err_r | 32'h1) & (w1c_err ? ~host_wdata : 32'hFFFF_FFFF);  // ERR.ACC（与 W1C 同拍时先置后清不冲突：W1C 写 0x10 本身合法不触发 wr_bad）
      else if (w1c_err)
        err_r <= err_r & ~host_wdata;                          // W1C
      if (w1c_int)
        int_st_r <= int_st_r & ~host_wdata;                    // W1C
      if (we)
        case (off)
          8'h08: ctl_r        <= host_wdata & CTL_WMASK;
          8'h14: int_en_r     <= host_wdata;
          8'h60: smac_r       <= host_wdata;
          8'h64: ip_r         <= host_wdata;
          8'h70: udp_cfg_r    <= host_wdata;
          8'hF0: burst_addr_r <= host_wdata;
          8'hF4: burst_len_r  <= host_wdata;                   // WO（TODO 第 4 周: 突发搬运）
          8'hF8: burst_data_r <= host_wdata;
          8'hFC: dbg_ctrl_r   <= host_wdata;
          default: ;
        endcase
    end
  end

  // 中断（§7.14: host_irq = |INT_STATUS & ~INT_ENABLE；CTL bit14 IRQ_SW 软件自测，T01 用）
  assign host_irq = ctl_r[14] | |(int_st_r & ~int_en_r);

  // ---- tx / rx / mgmt 子系 ----
  // TODO 第 2 周: tx_port_buf / tx_sn_gen / tx_frame_builder（§7.1/7.4/7.3）
  // TODO 第 3 周: tx_vl_scheduler / tx_rm / mac_tx_if / mac_rx_if / rx_flt / rx_vl_lookup
  // TODO 第 4 周: rx_ic / rx_rm / rx_ip_udp_parse / rx_port_buf / host_if / stats_regs
  // TODO 第 5 周: rtc_sync / snmp_lite / a615a_tftp
  assign tx_data     = 8'h00;
  assign tx_valid    = 1'b0;
  assign tx_ready    = 1'b0;     // §5.3: 低电平 = "正在构建下一帧或对端不可收"
  assign tx_data_b   = 8'h00;
  assign tx_valid_b  = 1'b0;
  assign tx_ready_b  = 1'b0;
  assign dbg_frame_event = 4'h0;     // TODO 第 3 周: 帧事件（发/收/丢弃/错误）
/* verilator lint_on UNUSED */

endmodule
