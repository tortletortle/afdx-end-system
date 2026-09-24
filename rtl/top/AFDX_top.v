// =====================================================================
// AFDX_top.v —— AFDX 端系统顶层（第 2 周初始化/主机总线接线中）
// 设计书: §5.1（顶层端口总表）/ §4.2（复位）/ §4.3（参数表）/
//         §7.14 + 附录 A（寄存器页，doc/regs.yaml 为单一来源）/ §7.18（时基）
// 状态: 初始化扫描/前门/TX 闭环；RX 双入口/PMEM/lookup 过渡切片。
//       FLT 尚未接在 lookup 前，lookup 结果仍统一释放；IC/RM/端口未验收。
//       后级 RX/管理面及完整 T05/T22 指标仍未验收。
// 命名/握手: §10（信号小写下划线、参数大写下划线、vld/rdy 或 pulse）
// =====================================================================
`timescale 1 ns / 1 ps
/* verilator lint_off UNUSED */
// 骨架期: pps_in/tick_us 尚未消费
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
  parameter integer IF_MODE       = 0,
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
  // ---- 扩展端口：主机接口（§5.4 单拍流水、下一拍 ack）----
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

  // 初始化顺序扫描：每个 strobe 真正写到对应状态/valid 存储体；末笔后排空一拍。
  wire        init_we, init_done;
  wire [2:0]  init_target;
  wire [12:0] init_addr;
  init_sweep #(.NUM_RX_VL(NUM_RX_VL), .NUM_TX_VL(NUM_TX_VL), .NUM_PORTS(NUM_PORTS)) u_init (
    .clk(clk), .rst_sync(rst_sync), .init_we(init_we),
    .init_target(init_target), .init_addr(init_addr), .init_done(init_done));

  // PSN/RM 状态尚未连接 RX 判决链；哈希 RAM 已由 u_rxlookup 唯一持有。
  // 其他配置字不复位；w0.valid 清零后读取未启用项返回零，避免暴露 X 内容。
  reg [7:0]  psn_mem      [0:2*NUM_RX_VL-1];
  reg [31:0] rm_mem       [0:NUM_RX_VL-1];
  reg [31:0] rx_cfg_mem   [0:2*NUM_RX_VL-1];
  reg [31:0] tx_cfg_mem   [0:5*NUM_TX_VL-1];
  // §8.2/O-27: 与 TX w0~w4 分离的 Q20 份额表，0x0480+VL；数据 BRAM 不整片复位。
  // loaded 位复用 init_sweep 的 TXCFG 扫描清零，扫描写拍数仍为 25_344。
  reg [20:0] cfg_share_mem [0:NUM_TX_VL-1];
  reg [NUM_TX_VL-1:0] cfg_share_loaded;
  reg [27:0] cfg_sum_r;       // 128 × (2^21-1) < 2^28
  reg [7:0] cfg_missing_cnt; // 已启用 w0 且缺失/零份额的 VL 数，最大 128
  localparam [27:0] Q20_LIMIT = 28'd1048576;
  wire cfg_over = (cfg_sum_r > Q20_LIMIT);
  wire cfg_missing = (cfg_missing_cnt != 8'd0);
  reg [31:0] port_cfg_mem [0:4*NUM_PORTS-1];
  reg [31:0] rx_desc_mem  [0:NUM_PORTS-1];
  reg [31:0] vl_stat_mem  [0:NUM_TX_VL-1];

  reg [31:0] ctl_r, int_en_r, err_r, int_st_r;
  reg [31:0] smac_r, ip_r, udp_cfg_r, dbg_ctrl_r, rdata_r;
  reg [15:0] hash_seed0_r, hash_seed1_r;
  reg hash_seed0_set, hash_seed1_set, hash_entry_seen, hash_image_valid;
  wire hash_cfg_ready, hash_cfg_rvalid;
  wire hash_rd_accept, cfg_write;
  wire [31:0] hash_cfg_rdata;
  wire lookup_in_ready, lookup_out_vld, lookup_out_hit;
  wire [11:0] lookup_out_vl;
  wire [162:0] lookup_out_desc;
  wire flt_in_ready, flt_out_vld, flt_out_pass;
  wire [2:0] flt_out_reason;
  wire [11:0] flt_out_vl;
  wire [162:0] flt_out_desc;
  reg  [31:0] flt_unconf_cnt, flt_lmax_cnt, flt_drop_total;
  wire rx_desc_valid_a, rx_desc_valid_b, rx_desc_pop_a, rx_desc_pop_b;
  wire [162:0] rx_desc_a, rx_desc_b;
  // 前置跨区声明：Questa vlog-2730 不允许在主机译码里先使用、后声明。
  wire host_pmem_rd, desc_hit, pmem_wok, msg_valid, fb_busy, sch_take, pb_wr_valid;
  wire [7:0] desc_idx;
  wire [3:0] pb_wr_blk;
  wire [15:0] pb_free_map, sch_bag_cnt;
  wire [31:0] pmem_data_a, pb_desc_rd_data;
  wire [NUM_PORTS-1:0] pb_req;
  reg ack_r, pmem_rd_d, desc_rd_d, hash_rd_d;
  reg host_pmem_pending;
  reg [12:0] host_pmem_pending_addr;
  reg [31:0] host_pmem_pending_data;
  wire host_pmem_req, rx_pmem_busy, host_commit_now, host_commit_pending;
  // 无竞争时单拍流水不变。若运行期 RX 抢占单写口，锁住 1 笔主机
  // PMEM 请求直到实际落 RAM 再 ACK；争用时主机须保持至 ACK，不流水投递。
  wire hs = host_cs & ~rst_sync & ~host_pmem_pending;
  wire we = hs & host_we;
  always @(posedge clk) begin
    if (rst_sync) begin
      ack_r <= 1'b0; pmem_rd_d <= 1'b0; desc_rd_d <= 1'b0; hash_rd_d <= 1'b0;
    end
    else begin
      ack_r <= (hs && (!host_pmem_req || host_commit_now)) || host_commit_pending;
      pmem_rd_d <= host_pmem_rd;
      desc_rd_d <= hs && !host_we && desc_hit;
      hash_rd_d <= hash_rd_accept;
    end
  end
  assign host_ack = ack_r;
  assign host_rdata = hash_rd_d ? hash_cfg_rdata :
                       pmem_rd_d ? pmem_data_a :
                      desc_rd_d ? (pb_req[desc_idx] ? pb_desc_rd_data : 32'd0) : rdata_r;

  // 字地址译码：寄存器页以 4 字为间距，表/PMEM 每个字地址连续。
  wire [7:0] off = host_addr[7:0];
  wire reg_page = (host_addr[15:8] == 8'h00);
  wire reg_align = (off[1:0] == 2'b00);
  wire drop_k = (off >= 8'h20) && (off <= 8'h4C) && reg_align;
  wire stats_hit = (host_addr >= 16'h0100 && host_addr <= 16'h01FF);
  wire tx_hit = (host_addr >= 16'h0200 && host_addr <= 16'h047F) &&
                ((host_addr - 16'h0200) < 5*NUM_TX_VL);
  wire share_hit = (host_addr >= 16'h0480 && host_addr <= 16'h04FF) &&
                   ((host_addr - 16'h0480) < NUM_TX_VL);
  wire [6:0] share_idx = host_addr - 16'h0480;
  wire [9:0] share_tx_base = {3'd0, share_idx} * 10'd5;
  wire share_format_ok = (host_wdata[31:21] == 11'd0);
  wire rx_hit = (host_addr >= 16'h1D80 && host_addr <= 16'h3D7F) &&
                ((host_addr - 16'h1D80) < 2*NUM_RX_VL);
  wire hash_hit = (host_addr >= 16'h3D80 && host_addr <= 16'h5D7F);
  wire port_hit = (host_addr >= 16'h7D80 && host_addr <= 16'h817F) &&
                  ((host_addr - 16'h7D80) < 4*NUM_PORTS);
  assign desc_hit = (host_addr >= 16'h8180 && host_addr <= 16'h827F) &&
                  ((host_addr - 16'h8180) < NUM_PORTS);
  wire vlstat_hit = (host_addr >= 16'hA810 && host_addr <= 16'hAC0F);
  wire pmem_hit = (host_addr >= 16'h8800 && host_addr <= 16'hA7FF);
  wire msg_wr_hit = (host_addr >= 16'h8280 && host_addr <= 16'h837F);
  wire [9:0] tx_idx   = host_addr - 16'h0200;
  wire [12:0] rx_idx  = host_addr - 16'h1D80;
  wire [12:0] hash_idx= host_addr - 16'h3D80;
  // Empty register page words: 0x78 seed0, 0x7C seed1, 0x80 image commit.
  // Commit is a *host assertion* that an offline-verified COMPLETE image was
  // loaded/read back. Hardware cannot compute its manifest SHA-256 or prove
  // 4096 VLID-to-slot relationships; do not treat this as a secure validator.
  wire hash_seed0_addr = reg_page && reg_align && (off == 8'h78);
  wire hash_seed1_addr = reg_page && reg_align && (off == 8'h7C);
  wire hash_ctl_addr = reg_page && reg_align && (off == 8'h80);
  wire hash_seed0_wr = cfg_write && hash_seed0_addr &&
                       (host_wdata[31:16] == 16'd0);
  wire hash_seed1_wr = cfg_write && hash_seed1_addr &&
                       (host_wdata[31:16] == 16'd0);
  wire hash_ctl_wr = cfg_write && hash_ctl_addr &&
                     (host_wdata[31:1] == 31'd0) &&
                     (!host_wdata[0] ||
                      (hash_seed0_set && hash_seed1_set && hash_entry_seen));
  wire hash_format_ok = (host_wdata[31:29] == 3'd0) &&
                        (!host_wdata[28] || (host_wdata[11:0] < NUM_RX_VL));
  wire hash_wr_req = cfg_write && hash_hit && hash_format_ok;
  wire hash_rd_req = hs && !host_we && hash_hit && init_done &&
                     ctl_r[13] && !(|ctl_r[1:0]);
  wire hash_wr_accept = hash_wr_req && hash_cfg_ready;
  assign hash_rd_accept = hash_rd_req && hash_cfg_ready;
  wire [9:0] port_idx = host_addr - 16'h7D80;
  assign desc_idx = host_addr - 16'h8180;
  wire [9:0] vs_idx   = host_addr - 16'hA810;
  wire tx_cfg_valid = tx_cfg_mem[(tx_idx / 10'd5) * 10'd5][31];
  wire rx_cfg_valid = rx_cfg_mem[(rx_idx / 13'd2) * 13'd2][31];
  wire port_cfg_valid = port_cfg_mem[(port_idx / 10'd4) * 10'd4][31];
  assign cfg_write = we & init_done & ctl_r[13] & !(|ctl_r[1:0]);
  wire share_wr = cfg_write && share_hit && share_format_ok;
  always @(posedge clk) begin
    if (rst_sync) begin
      hash_seed0_r <= 16'd0; hash_seed1_r <= 16'd0;
      hash_seed0_set <= 1'b0; hash_seed1_set <= 1'b0;
      hash_entry_seen <= 1'b0; hash_image_valid <= 1'b0;
    end else begin
      if (hash_seed0_wr) begin
        hash_seed0_r <= host_wdata[15:0]; hash_seed0_set <= 1'b1;
        hash_entry_seen <= 1'b0; hash_image_valid <= 1'b0;
      end
      if (hash_seed1_wr) begin
        hash_seed1_r <= host_wdata[15:0]; hash_seed1_set <= 1'b1;
        hash_entry_seen <= 1'b0; hash_image_valid <= 1'b0;
      end
      if (hash_wr_accept) begin
        if (host_wdata[28]) hash_entry_seen <= 1'b1;
        hash_image_valid <= 1'b0;
      end
      if (cfg_write && hash_hit && !hash_format_ok) begin
        hash_entry_seen <= 1'b0; hash_image_valid <= 1'b0;
      end
      if (hash_ctl_wr) begin
        if (host_wdata[0]) hash_image_valid <= 1'b1;
        else begin
          hash_seed0_set <= 1'b0; hash_seed1_set <= 1'b0;
          hash_entry_seen <= 1'b0; hash_image_valid <= 1'b0;
        end
      end
    end
  end
  wire [6:0] budget_vl = tx_idx / 10'd5;
  wire [9:0] budget_base = {3'd0,budget_vl} * 10'd5;
  wire budget_w0_write = cfg_write && tx_hit && ((tx_idx % 10'd5) == 10'd0);
  wire budget_old_en = tx_cfg_mem[budget_base][31];
  wire budget_new_en = host_wdata[31];
  wire budget_share_ok = cfg_share_loaded[budget_vl] &&
                         (cfg_share_mem[budget_vl] != 21'd0);
  wire share_old_en = tx_cfg_mem[share_tx_base][31];
  wire share_old_missing = share_old_en &&
                           (!cfg_share_loaded[share_idx] || cfg_share_mem[share_idx] == 21'd0);
  wire share_new_missing = share_old_en && (host_wdata[20:0] == 21'd0);

  // O(1) 前门写更新，非 128 级组合扫描、非硬件除法。对 w0.valid 的翻转以及份额覆写
  // 都先移除旧贡献再加新贡献，允许任意顺序灌表、反复改配。配置期不能同时开流。
  always @(posedge clk) begin
    if (rst_sync) begin
      cfg_sum_r <= 28'd0;
      cfg_missing_cnt <= 8'd0;
    end else begin
      if (init_we && init_target == 3'd4) cfg_share_loaded[init_addr] <= 1'b0;
      else if (share_wr) begin
        cfg_share_mem[share_idx] <= host_wdata[20:0];
        cfg_share_loaded[share_idx] <= 1'b1;
      end
      if (share_wr && share_old_en) begin
        cfg_sum_r <= cfg_sum_r -
                     (cfg_share_loaded[share_idx] ? {7'd0,cfg_share_mem[share_idx]} : 28'd0) +
                     {7'd0,host_wdata[20:0]};
        cfg_missing_cnt <= cfg_missing_cnt - {7'd0,share_old_missing} +
                           {7'd0,share_new_missing};
      end else if (budget_w0_write) begin
        cfg_sum_r <= cfg_sum_r -
                     ((budget_old_en && cfg_share_loaded[budget_vl]) ?
                       {7'd0,cfg_share_mem[budget_vl]} : 28'd0) +
                     ((budget_new_en && cfg_share_loaded[budget_vl]) ?
                       {7'd0,cfg_share_mem[budget_vl]} : 28'd0);
        cfg_missing_cnt <= cfg_missing_cnt -
                     {7'd0,(budget_old_en && !budget_share_ok)} +
                     {7'd0,(budget_new_en && !budget_share_ok)};
      end
    end
  end

  // 扫描优先于配置期前门写；无同步复位整片 BRAM 的写法。
  always @(posedge clk) begin
    if (init_we && init_target == 3'd0) psn_mem[init_addr] <= 8'd0;
    if (init_we && init_target == 3'd1) rm_mem[init_addr] <= 32'd0;
    if (init_we && init_target == 3'd3) rx_cfg_mem[init_addr * 13'd2] <= 32'd0;
    else if (cfg_write && rx_hit) rx_cfg_mem[rx_idx] <= host_wdata;
    if (init_we && init_target == 3'd4) tx_cfg_mem[init_addr * 13'd5] <= 32'd0;
    else if (cfg_write && tx_hit) tx_cfg_mem[tx_idx] <= host_wdata;
    if (init_we && init_target == 3'd5) port_cfg_mem[init_addr * 13'd4] <= 32'd0;
    else if (cfg_write && port_hit) port_cfg_mem[port_idx] <= host_wdata;
    if (init_we && init_target == 3'd6) rx_desc_mem[init_addr] <= 32'd0;
    if (init_we && init_target == 3'd7) vl_stat_mem[init_addr] <= 32'd0;
  end

  // 时基（RTC 同步留待管理面）；静态网络发送依赖真实 rtc64[23:0]。
  wire tick_us, alive;
  wire [63:0] rtc64;
  timebase #(.TICK_US(TICK_US)) u_timebase (
    .clk(clk), .rst(rst_sync), .rtc_hold(ctl_r[11]),
    .freq_adj(16'd524), .rtc64(rtc64), .tick_us(tick_us), .alive(alive));
  assign rtc_time_us = rtc64;
  assign pps_out = 1'b0;

  localparam [31:0] REG_ID    = {16'hAF07, NUM_RX_VL[15:0]};
  localparam [31:0] REG_REV   = 32'h4_0000;
  localparam [31:0] CTL_RST   = 32'h51C;
  localparam [31:0] CTL_WMASK = 32'hFFFF_EF9F;  // bit5/6/12 保留、写无效
  wire early_open = we && reg_page && reg_align && off == 8'h08 &&
                    !init_done && (|host_wdata[1:0]);
  wire cfg_open_conflict = we && reg_page && reg_align && off == 8'h08 &&
                           host_wdata[13] && ((|host_wdata[1:0]) || fb_busy);
  wire cfg_open_invalid = we && reg_page && reg_align && off == 8'h08 &&
                          host_wdata[0] && init_done && (cfg_over || cfg_missing);
  wire rx_open_invalid = we && reg_page && reg_align && off == 8'h08 &&
                          host_wdata[1] && init_done && !hash_image_valid;
  wire [31:0] ctl_raw = host_wdata & CTL_WMASK &
                        (init_done ? 32'hFFFF_FFFF : 32'hFFFF_FFFC);
  wire [31:0] ctl_value = (cfg_open_conflict ?
                           (ctl_raw & 32'hFFFF_DFFC) : ctl_raw) &
                          (cfg_open_invalid ? 32'hFFFF_FFFE : 32'hFFFF_FFFF) &
                          (rx_open_invalid ? 32'hFFFF_FFFD : 32'hFFFF_FFFF);
  wire reg_known = drop_k || (off == 8'h00) || (off == 8'h04) ||
                   (off == 8'h08) || (off == 8'h0C) || (off == 8'h10) ||
                   (off == 8'h14) || (off == 8'h18) || (off == 8'h1C) ||
                   (off == 8'h50) || (off == 8'h54) || (off == 8'h58) ||
                   (off == 8'h5C) || (off == 8'h60) || (off == 8'h64) ||
                   (off == 8'h68) || (off == 8'h6C) || (off == 8'h70) ||
                   (off == 8'h74) || (off == 8'h78) || (off == 8'h7C) ||
                   (off == 8'h80) || (off == 8'hFC);
  wire reg_writable = (off == 8'h08) || (off == 8'h10) || (off == 8'h14) ||
                      (off == 8'h18) || (off == 8'h60) || (off == 8'h64) ||
                      (off == 8'h70) || (off == 8'h78) ||
                      (off == 8'h7C) || (off == 8'h80) || (off == 8'hFC);
  wire rd_known = (reg_page && reg_align && reg_known) || stats_hit ||
                  tx_hit || share_hit || rx_hit || hash_rd_accept ||
                  port_hit || desc_hit || vlstat_hit ||
                  (pmem_hit && init_done && ctl_r[13] && !ctl_r[0] && !fb_busy);
  wire wr_known = (reg_page && reg_align && reg_writable) ||
                  (cfg_write && (tx_hit || rx_hit || port_hit)) ||
                  hash_wr_accept ||
                  share_wr ||
                  pmem_wok || msg_valid;
  wire rd_miss = hs && !host_we && !rd_known;
  wire hash_reg_bad = (hash_seed0_addr && !hash_seed0_wr) ||
                      (hash_seed1_addr && !hash_seed1_wr) ||
                      (hash_ctl_addr && !hash_ctl_wr);
  wire wr_bad  = we && (!wr_known || early_open || cfg_open_conflict ||
                         cfg_open_invalid || rx_open_invalid || hash_reg_bad);
  wire w1c_err = we && reg_page && reg_align && (off == 8'h10);
  wire w1c_int = we && reg_page && reg_align && (off == 8'h18);
  function [5:0] popcnt16;
    input [15:0] m;
    integer j;
    begin
      popcnt16 = 6'd0;
      for (j=0; j<16; j=j+1) popcnt16 = popcnt16 + {5'd0,m[j]};
    end
  endfunction
  // 开放 TX 块已预留；其余 TX + RX/公共池的实时空闲块数。
  wire [15:0] rx_free_map;
  wire [5:0] pmem_free = popcnt16(pb_free_map) + popcnt16(rx_free_map);
  wire [31:0] status_word = {alive, 16'd0, cfg_over, init_done,
                             3'd0, (|sch_bag_cnt), 1'b0, pmem_free, fb_busy, sch_take};

  // 读请求拍采样；哈希同步 RAM 数据走独立 hash_rd_d 前门选择。
  always @(posedge clk) begin
    if (rst_sync) rdata_r <= 32'd0;
    else if (hs) begin
      if (reg_page && reg_align && reg_known) begin
        // DROP_CNT_K 12 类原因序：len,dmac,ethtype,ip_ver,ip_csum,udp_len,
        // udp_csum,crc,unconf,lmax,ic,rm（§7.16）。FLT 只接了 unconf/lmax；
        // 其余类别仍未接线返回 0，不能当完整统计面验收。
        if (drop_k) rdata_r <= (off == 8'h40) ? flt_unconf_cnt :
                               (off == 8'h44) ? flt_lmax_cnt : 32'd0;
        else case (off)
          8'h00: rdata_r <= REG_ID;
          8'h04: rdata_r <= REG_REV;
          8'h08: rdata_r <= ctl_r;
          8'h0C: rdata_r <= status_word;
          8'h10: rdata_r <= err_r;
          8'h14: rdata_r <= int_en_r;
          8'h18: rdata_r <= int_st_r;
          8'h1C: rdata_r <= flt_drop_total;
          8'h50: rdata_r <= rtc64[31:0];
          8'h54: rdata_r <= rtc64[63:32];
          8'h58: rdata_r <= {4'd0,cfg_sum_r};
          8'h5C: rdata_r <= {30'd0,cfg_missing,cfg_over};  // bit1 缺份额，bit0 超额
          8'h60: rdata_r <= smac_r;
          8'h64: rdata_r <= ip_r;
          8'h68: rdata_r <= 32'd0;
          8'h6C: rdata_r <= 32'd0;
          8'h70: rdata_r <= udp_cfg_r;
          8'h74: rdata_r <= {27'd0, pb_wr_valid, pb_wr_blk};
          8'h78: rdata_r <= {16'd0,hash_seed0_r};
          8'h7C: rdata_r <= {16'd0,hash_seed1_r};
          8'h80: rdata_r <= {28'd0,hash_entry_seen,hash_seed1_set,
                                      hash_seed0_set,hash_image_valid};
          8'hFC: rdata_r <= dbg_ctrl_r;
          default: rdata_r <= 32'hDEAD_BEEF;
        endcase
      end else if (stats_hit) rdata_r <= 32'd0;
      else if (tx_hit) rdata_r <= tx_cfg_valid ? tx_cfg_mem[tx_idx] : 32'd0;
      else if (share_hit) rdata_r <= (init_done && cfg_share_loaded[share_idx]) ?
                                   {11'd0,cfg_share_mem[share_idx]} : 32'd0;
      else if (rx_hit) rdata_r <= rx_cfg_valid ? rx_cfg_mem[rx_idx] : 32'd0;
      else if (port_hit) rdata_r <= port_cfg_valid ? port_cfg_mem[port_idx] : 32'd0;
      else if (desc_hit) rdata_r <= 32'd0;  // 同拍 PB 读出经 desc_rd_d 选到 host_rdata
      else if (vlstat_hit) rdata_r <= (vs_idx[2:0] == 3'd0 &&
                            ((vs_idx >> 3) < NUM_TX_VL)) ? vl_stat_mem[vs_idx >> 3] : 32'd0;
      else rdata_r <= 32'hDEAD_BEEF;
    end
  end

  // INIT_DONE/有效哈希映像前不得开 RX；TX 超配/缺份额拒绝开流。
  // ERR.BAG_OVF 对现存超配持续置位（W1C 清除后若超配未解除，下拍重新置位）。
  always @(posedge clk) begin
    if (rst_sync) begin
      ctl_r <= CTL_RST; int_en_r <= 32'd0; err_r <= 32'd0; int_st_r <= 32'd0;
      smac_r <= 32'h0001_2001; ip_r <= 32'd0; udp_cfg_r <= 32'h142; dbg_ctrl_r <= 32'd0;
    end else begin
      if (wr_bad || rd_miss) err_r <= err_r | 32'h1 | (cfg_over ? 32'h2 : 32'd0);
      else if (w1c_err)      err_r <= (err_r & ~host_wdata) & 32'hFFFF_FFF7;
      else if (cfg_over)     err_r <= err_r | 32'h2;
      if (w1c_int) int_st_r <= int_st_r & ~host_wdata;
      if (we && reg_page && reg_align) begin
        case (off)
          8'h08: ctl_r <= ctl_value;
          8'h14: int_en_r <= host_wdata & 32'hFF;
          8'h60: smac_r <= host_wdata;
          8'h64: ip_r <= host_wdata;
          8'h70: udp_cfg_r <= host_wdata;
          8'hFC: dbg_ctrl_r <= host_wdata;
          default: ;
        endcase
      end
    end
  end
  assign host_irq = ctl_r[14] | |(int_st_r & int_en_r);

  // ---- TX 闭环：与 T04 单元链相同的握手，只是配置/PMEM 改由前门提供 ----
  wire [NUM_PORTS-1:0] pb_full;
  wire [3:0] pb_sch_blk;
  wire pb_rej, pb_sch_ack, pb_pending;
  wire [7:0] sch_port;
  wire [12:0] pb_sch_len;
  wire [15:0] pb_ovr_cnt, pb_qovf_cnt, pb_exh_cnt;
  wire [7:0] msg_port = host_addr - 16'h8280;
  wire [31:0] msg_port_w0 = port_cfg_mem[{msg_port,2'b00}];
  wire [31:0] msg_port_w3 = port_cfg_mem[{msg_port,2'b00}+10'd3];
  wire msg_len_ok = (host_wdata[15:0] >= 16'd8) && (host_wdata[15:0] <= 16'd1471);
  assign msg_valid = msg_wr_hit && init_done && !ctl_r[13] &&
                   msg_port_w0[31] && (msg_port_w0[17:16] != 2'd2) && msg_len_ok;
  wire msg_commit = we && msg_valid;
  wire fb_free;
  wire [3:0] fb_free_blk;
  tx_port_buf #(.NUM_PORTS(NUM_PORTS), .TX_BLK_LO(0), .TX_BLK_N(6)) u_txbuf (
    .clk(clk), .rst_sync(rst_sync), .tb_us(rtc64[7:0]),
    .msg_commit(msg_commit), .port_id(msg_port), .len(host_wdata[15:0]),
    .port_type(msg_port_w0[17:16]), .port_depth(msg_port_w3[3:0]), .commit_rej(pb_rej),
    .wr_blk(pb_wr_blk), .wr_blk_vld(pb_wr_valid),
    .desc_rd_addr(desc_idx), .desc_rd_data(pb_desc_rd_data),
    .sch_req(pb_req), .buf_full(pb_full),
    .sch_take(sch_take), .sch_port(sch_port), .sch_ack(pb_sch_ack),
    .sch_blk(pb_sch_blk), .sch_len(pb_sch_len),
    .blk_free(fb_free), .blk_free_id(fb_free_blk),
    .free_map(pb_free_map), .ovr_cnt(pb_ovr_cnt), .q_ovf_cnt(pb_qovf_cnt),
    .pmem_exhaust_cnt(pb_exh_cnt), .pending(pb_pending));

  // 主机 PMEM 写口在配置期可扫全区；运行期仅能写当前开放 TX 块。
  // 读口 A 在 CFG_MODE=1 且 builder 空闲时让给主机读取；读口 B 保留给 builder。
  wire [12:0] host_pmem_addr = host_addr - 16'h8800;
  wire in_open_blk = (host_pmem_addr[12:9] == pb_wr_blk) && pb_wr_valid;
  assign pmem_wok = init_done && pmem_hit &&
                  ((ctl_r[13] && !ctl_r[0]) || (!ctl_r[13] && in_open_blk));
  assign host_pmem_req = we && pmem_wok;
  assign host_pmem_rd = hs && !host_we && pmem_hit && init_done && ctl_r[13] &&
                      !ctl_r[0] && !fb_busy;
  // 两网各有写 FIFO。RX 优先、双网轮换；等 RX 都暂空时落已锁存主机写。
  wire q_wr_a, q_wr_b, q_pop_a, q_pop_b;
  wire [12:0] q_addr_a, q_addr_b;
  wire [31:0] q_data_a, q_data_b;
  wire [3:0] q_be_a, q_be_b;
  reg rx_wr_rr;
  assign rx_pmem_busy = q_wr_a || q_wr_b;
  assign q_pop_a = q_wr_a && (!q_wr_b || !rx_wr_rr);
  assign q_pop_b = q_wr_b && (!q_wr_a || rx_wr_rr);
  assign host_commit_pending = host_pmem_pending && !rx_pmem_busy;
  assign host_commit_now = host_pmem_req && !host_pmem_pending && !rx_pmem_busy;
  always @(posedge clk) begin
    if (rst_sync) begin
      rx_wr_rr <= 1'b0; host_pmem_pending <= 1'b0;
      host_pmem_pending_addr <= 13'd0;
      host_pmem_pending_data <= 32'd0;
    end else begin
      if (q_pop_a) rx_wr_rr <= 1'b1;
      else if (q_pop_b) rx_wr_rr <= 1'b0;
      if (host_commit_pending) host_pmem_pending <= 1'b0;
      else if (host_pmem_req && !host_commit_now) begin
        host_pmem_pending <= 1'b1;
        host_pmem_pending_addr <= host_pmem_addr;
        host_pmem_pending_data <= host_wdata;
      end
    end
  end
  wire [12:0] pmem_wr_addr = q_pop_a ? q_addr_a : q_pop_b ? q_addr_b :
                              host_commit_pending ? host_pmem_pending_addr : host_pmem_addr;
  wire [31:0] pmem_wr_data = q_pop_a ? q_data_a : q_pop_b ? q_data_b :
                              host_commit_pending ? host_pmem_pending_data : host_wdata;
  wire [3:0] pmem_wr_be = q_pop_a ? q_be_a : q_pop_b ? q_be_b : 4'hF;
  wire pmem_wr_en = q_pop_a || q_pop_b || host_commit_pending || host_commit_now;
  wire fb_rd_en_a, fb_rd_en_b;
  wire [12:0] fb_rd_addr_a, fb_rd_addr_b;
  wire [31:0] pmem_data_b;
  bram_sdp #(.W(32), .D(PMEM_KB*256), .BYTE_EN(1)) u_pmem (
    .clk(clk), .wr_en(pmem_wr_en), .wr_addr(pmem_wr_addr),
    .wr_data(pmem_wr_data), .wr_be(pmem_wr_be),
    .rd_en_a(host_pmem_rd | fb_rd_en_a),
    .rd_addr_a(host_pmem_rd ? host_pmem_addr : fb_rd_addr_a), .rd_data_a(pmem_data_a),
    .rd_en_b(fb_rd_en_b), .rd_addr_b(fb_rd_addr_b), .rd_data_b(pmem_data_b));

  // RX 双网入口各自获块（不能给同拍两网同一块），仅好帧进入写完成标记 FIFO。
  wire rx_busy_a, rx_busy_b, rx_room_a, rx_room_b, rx_alloc_a, rx_alloc_b;
  wire rx_blk_vld_a, rx_blk_vld_b;
  wire [3:0] rx_blk_a, rx_blk_b;
  wire rx_rel_a, rx_rel_b;
  wire [3:0] rx_rel_id_a, rx_rel_id_b;
  wire [15:0] rx_exh_cnt, rx_borrow_cnt;
  reg rx_pipe_free;
  reg [3:0] rx_pipe_free_id;
  wire rx_stream_en = ctl_r[1] && hash_image_valid && init_done && !ctl_r[13];
  wire rx_first_a = rx_stream_en && rx_valid && (IF_MODE != 0 || rx_ready) && !rx_busy_a;
  wire rx_first_b = rx_stream_en && (DUAL_NET_EN != 0) && rx_valid_b &&
                     (IF_MODE != 0 || rx_ready_b) && !rx_busy_b;
  assign rx_alloc_a = rx_first_a && rx_room_a;
  assign rx_alloc_b = rx_first_b && rx_room_b;
  rx_block_pool u_rxpool (
    .clk(clk), .rst_sync(rst_sync), .alloc_a(rx_alloc_a), .alloc_b(rx_alloc_b),
    .valid_a(rx_blk_vld_a), .valid_b(rx_blk_vld_b),
    .blk_a(rx_blk_a), .blk_b(rx_blk_b),
    .free_a(rx_rel_a), .free_id_a(rx_rel_id_a),
    .free_b(rx_rel_b), .free_id_b(rx_rel_id_b),
    .free_pipe(rx_pipe_free), .free_id_pipe(rx_pipe_free_id),
    .free_map(rx_free_map), .exhaust_cnt(rx_exh_cnt), .borrow_cnt(rx_borrow_cnt));
  wire rxw_en_a, rxw_en_b, rxd_vld_a, rxd_vld_b;
  wire [12:0] rxw_addr_a, rxw_addr_b;
  wire [31:0] rxw_data_a, rxw_data_b;
  wire [3:0] rxw_be_a, rxw_be_b;
  wire [3:0] rxd_blk_a, rxd_blk_b;
  wire [10:0] rxd_len_a, rxd_len_b;
  wire [23:0] rxd_ts_a, rxd_ts_b;
  wire [15:0] rxd_vlid_a, rxd_vlid_b, rxd_sport_a, rxd_sport_b,
              rxd_dport_a, rxd_dport_b;
  wire [7:0] rxd_sn_a, rxd_sn_b, rx_drop_reason_a, rx_drop_reason_b;
  wire [2:0] rxd_ifid_a, rxd_ifid_b;
  wire [31:0] rxd_src_a, rxd_src_b, rxd_dst_a, rxd_dst_b;
  wire rxd_net_a, rxd_net_b, rx_frame_err_a, rx_frame_err_b,
       rx_crc_err_a, rx_crc_err_b;
  mac_rx_if #(.IF_MODE(IF_MODE), .FCS_MODE(FCS_MODE), .MAX_FRAME(MAX_FRAME), .NET_ID(0))
  u_mac_rx_a (
    .clk(clk), .rst_sync(rst_sync), .enable(rx_stream_en), .udp_csum_en(udp_cfg_r[1]),
    .tb_us(rtc64[23:0]), .rx_data(rx_data), .rx_valid(rx_valid), .rx_ready(rx_ready),
    .rx_blk(rx_blk_a), .rx_blk_valid(rx_blk_vld_a && rx_room_a), .frame_busy(rx_busy_a),
    .pmem_wr_en(rxw_en_a), .pmem_wr_addr(rxw_addr_a),
    .pmem_wr_data(rxw_data_a), .pmem_wr_be(rxw_be_a),
    .blk_release(rx_rel_a), .blk_release_id(rx_rel_id_a),
    .desc_vld(rxd_vld_a), .desc_blk(rxd_blk_a), .desc_len(rxd_len_a),
    .desc_ts(rxd_ts_a), .desc_vlid(rxd_vlid_a), .desc_sn(rxd_sn_a),
    .desc_net(rxd_net_a), .desc_ifid(rxd_ifid_a),
    .desc_src_ip(rxd_src_a), .desc_dst_ip(rxd_dst_a),
    .desc_sport(rxd_sport_a), .desc_dport(rxd_dport_a),
    .frame_err(rx_frame_err_a), .crc_err(rx_crc_err_a),
    .drop_reason(rx_drop_reason_a), .good_cnt(), .drop_cnt(), .disabled_cnt());
  mac_rx_if #(.IF_MODE(IF_MODE), .FCS_MODE(FCS_MODE), .MAX_FRAME(MAX_FRAME), .NET_ID(1))
  u_mac_rx_b (
    .clk(clk), .rst_sync(rst_sync), .enable(rx_stream_en && (DUAL_NET_EN != 0)),
    .udp_csum_en(udp_cfg_r[1]), .tb_us(rtc64[23:0]),
    .rx_data(rx_data_b), .rx_valid(rx_valid_b), .rx_ready(rx_ready_b),
    .rx_blk(rx_blk_b), .rx_blk_valid(rx_blk_vld_b && rx_room_b), .frame_busy(rx_busy_b),
    .pmem_wr_en(rxw_en_b), .pmem_wr_addr(rxw_addr_b),
    .pmem_wr_data(rxw_data_b), .pmem_wr_be(rxw_be_b),
    .blk_release(rx_rel_b), .blk_release_id(rx_rel_id_b),
    .desc_vld(rxd_vld_b), .desc_blk(rxd_blk_b), .desc_len(rxd_len_b),
    .desc_ts(rxd_ts_b), .desc_vlid(rxd_vlid_b), .desc_sn(rxd_sn_b),
    .desc_net(rxd_net_b), .desc_ifid(rxd_ifid_b),
    .desc_src_ip(rxd_src_b), .desc_dst_ip(rxd_dst_b),
    .desc_sport(rxd_sport_b), .desc_dport(rxd_dport_b),
    .frame_err(rx_frame_err_b), .crc_err(rx_crc_err_b),
    .drop_reason(rx_drop_reason_b), .good_cnt(), .drop_cnt(), .disabled_cnt());
  wire [162:0] rx_desc_in_a = {rxd_blk_a,rxd_len_a,rxd_ts_a,rxd_vlid_a,rxd_sn_a,
                                rxd_net_a,rxd_ifid_a,rxd_src_a,rxd_dst_a,
                                rxd_sport_a,rxd_dport_a};
  wire [162:0] rx_desc_in_b = {rxd_blk_b,rxd_len_b,rxd_ts_b,rxd_vlid_b,rxd_sn_b,
                                rxd_net_b,rxd_ifid_b,rxd_src_b,rxd_dst_b,
                                rxd_sport_b,rxd_dport_b};
  wire rx_ovf_a, rx_ovf_b;
  rx_pmem_queue u_rxq_a (
    .clk(clk), .rst_sync(rst_sync), .in_wr_en(rxw_en_a), .in_wr_addr(rxw_addr_a),
    .in_wr_data(rxw_data_a), .in_wr_be(rxw_be_a),
    .in_desc_vld(rxd_vld_a), .in_desc(rx_desc_in_a), .frame_room(rx_room_a),
    .wr_valid(q_wr_a), .wr_addr(q_addr_a), .wr_data(q_data_a), .wr_be(q_be_a), .wr_pop(q_pop_a),
    .desc_valid(rx_desc_valid_a), .desc(rx_desc_a), .desc_pop(rx_desc_pop_a), .overflow(rx_ovf_a));
  rx_pmem_queue u_rxq_b (
    .clk(clk), .rst_sync(rst_sync), .in_wr_en(rxw_en_b), .in_wr_addr(rxw_addr_b),
    .in_wr_data(rxw_data_b), .in_wr_be(rxw_be_b),
    .in_desc_vld(rxd_vld_b), .in_desc(rx_desc_in_b), .frame_room(rx_room_b),
    .wr_valid(q_wr_b), .wr_addr(q_addr_b), .wr_data(q_data_b), .wr_be(q_be_b), .wr_pop(q_pop_b),
    .desc_valid(rx_desc_valid_b), .desc(rx_desc_b), .desc_pop(rx_desc_pop_b), .overflow(rx_ovf_b));
  // 过渡切片：好帧描述符经 lookup -> rx_flt 语义过滤后释放 PMEM（IC/RM/
  // 端口尚未接线，故 PASS 帧也暂不交付消息，仅计数/释放；DROP 帧按
  // unconf/lmax 归类计数）。配置期对停流前排队的描述符逐个丢弃而不是拿新
  // 映像重新解释，防止旧帧穿越换种子/重装边界。
  wire [162:0] lookup_in_desc = rx_desc_valid_a ? rx_desc_a : rx_desc_b;
  wire lookup_in_vld = rx_stream_en &&
                        (rx_desc_valid_a || rx_desc_valid_b);
  wire lookup_take = lookup_in_vld && lookup_in_ready;
  // drain 与 FLT 输出共用唯一 free_pipe 口：FLT 在途/出结果拍禁止 drain，
  // 否则第二个排队描述符的块释放会被覆盖丢失。
  wire lookup_drain = !rx_stream_en && !lookup_out_vld && !flt_out_vld &&
                       (rx_desc_valid_a || rx_desc_valid_b);
  assign rx_desc_pop_a = rx_desc_valid_a && (lookup_take || lookup_drain);
  assign rx_desc_pop_b = !rx_desc_valid_a && rx_desc_valid_b &&
                         (lookup_take || lookup_drain);
  rx_vl_lookup #(.NUM_RX_VL(NUM_RX_VL),.HASH_BUCKETS(2048)) u_rxlookup (
    .clk(clk),.rst_sync(rst_sync),.init_done(init_done),
    .init_we(init_we && (init_target == 3'd2)),.init_addr(init_addr),
    .cfg_mode(ctl_r[13]),.rx_enable(ctl_r[1]),
    .seed0(hash_seed0_r),.seed1(hash_seed1_r),
    .cfg_wr(hash_wr_req),.cfg_rd(hash_rd_req),.cfg_addr(hash_idx),
    .cfg_wdata(host_wdata),.cfg_ready(hash_cfg_ready),
    .cfg_rvalid(hash_cfg_rvalid),.cfg_rdata(hash_cfg_rdata),
    .in_vld(lookup_in_vld),.in_ready(lookup_in_ready),
    .in_desc(lookup_in_desc),.out_vld(lookup_out_vld),
    .out_ready(flt_in_ready),.out_hit(lookup_out_hit),
    .out_vl(lookup_out_vl),.out_desc(lookup_out_desc));
  // FLT 判决（§7.8 S2）：w0/w1 与既有 rx_cfg_valid 同款组合读；BRAM 化时
  // 须与主机读口合并为同一物理口（同 rx_ic 的写口纪律），本切片先取语义。
  rx_flt #(.NUM_RX_VL(NUM_RX_VL)) u_rxflt (
    .clk(clk), .rst_sync(rst_sync), .init_we(init_we),
    .in_vld(lookup_out_vld), .in_ready(flt_in_ready),
    .in_hit(lookup_out_hit), .in_vl(lookup_out_vl),
    .in_desc(lookup_out_desc),
    .in_w0(rx_cfg_mem[{lookup_out_vl,1'b0}]),
    .in_w1(rx_cfg_mem[{lookup_out_vl,1'b1}]),
    .out_vld(flt_out_vld), .out_ready(1'b1),
    .out_pass(flt_out_pass), .out_reason(flt_out_reason),
    .out_vl(flt_out_vl), .out_desc(flt_out_desc));
  // DROP_CNT_K 目前仅登记 FLT 层原因（unconf 含 NET/VLID 不一致，lmax 单列）；
  // mac_rx_if 的 CRC/长度类拒绝仍由其内部计数，接入统计面是后续项。
  always @(posedge clk) begin
    if (rst_sync) begin
      flt_unconf_cnt <= 32'd0; flt_lmax_cnt <= 32'd0; flt_drop_total <= 32'd0;
    end else if (flt_out_vld && !flt_out_pass) begin
      flt_drop_total <= flt_drop_total + 32'd1;
      if (flt_out_reason == 3'd3) flt_lmax_cnt <= flt_lmax_cnt + 32'd1;
      else flt_unconf_cnt <= flt_unconf_cnt + 32'd1;
    end
  end
  always @(posedge clk) begin
    if (rst_sync) begin rx_pipe_free <= 1'b0; rx_pipe_free_id <= 4'd0; end
    else begin
      // PASS 帧在 IC/RM/端口接入前同样回收（过渡行为，见上注释）。
      rx_pipe_free <= flt_out_vld || lookup_drain;
      if (flt_out_vld) rx_pipe_free_id <= flt_out_desc[162:159];
      else if (lookup_drain) rx_pipe_free_id <= lookup_in_desc[162:159];
    end
  end

  // 各 VL 静态表 w0~w4 同步读，在调度器 start_vld 后 builder 真正采样前已有一拍稳定。
  wire sch_start_vld, sch_bag_viol, sch_enable;
  wire [7:0] sch_start_vl, sch_valid_cnt;
  wire [3:0] sch_start_blk;
  wire [12:0] sch_start_len;
  wire [15:0] sch_miss_cnt;
  reg [31:0] cfg_w0_q, cfg_w1_q, cfg_w2_q, cfg_w3_q, cfg_w4_q;
  reg [1:0] active_net_mode;
  wire [9:0] start_cfg_base = sch_start_vl[6:0] * 10'd5;
  reg sch_ack_d;
  always @(posedge clk) begin
    if (rst_sync) sch_ack_d <= 1'b0;
    else          sch_ack_d <= pb_sch_ack;
    // 调度器 ST_TAKE 在 ack 拍锁存 start_vl；下一拍读 5 张静态配置字，
    // builder 再下一拍收到 start_vld，首部字段在同一采样沿已稳定。
    if (sch_ack_d) begin
      cfg_w0_q <= tx_cfg_mem[start_cfg_base];
      cfg_w1_q <= tx_cfg_mem[start_cfg_base+10'd1];
      cfg_w2_q <= tx_cfg_mem[start_cfg_base+10'd2];
      cfg_w3_q <= tx_cfg_mem[start_cfg_base+10'd3];
      cfg_w4_q <= tx_cfg_mem[start_cfg_base+10'd4];
    end
    if (rst_sync) active_net_mode <= 2'b01;
    else if (sch_start_vld) active_net_mode <= DUAL_NET_EN ? cfg_w0_q[1:0] : 2'b01;
  end
  wire [6:0] cfg_sch_vl = tx_idx / 10'd5;
  wire [9:0] cfg_sch_base = {3'd0,cfg_sch_vl} * 10'd5;
  wire cfg_sch_we = budget_w0_write;
  wire [NUM_PORTS-1:0] sched_ready = sch_enable ? pb_req : {NUM_PORTS{1'b0}};
  assign sch_enable = init_done && ctl_r[0] && !ctl_r[13];
  wire fb_done, fb_len_err;
  wire rm_frame_start, rm_frame_done;
  tx_vl_scheduler #(.NUM_TX_VL(NUM_TX_VL), .NUM_PORTS(NUM_PORTS)) u_sched (
    .clk(clk), .rst_sync(rst_sync), .enable(sch_enable), .tb_us(rtc64[23:0]),
    .cfg_we(cfg_sch_we), .cfg_vl(cfg_sch_vl), .cfg_valid(host_wdata[31]),
    .cfg_bag_us(tx_cfg_mem[cfg_sch_base+10'd1][31:8]),
    .cfg_port(tx_cfg_mem[cfg_sch_base+10'd4][23:16]),
    .port_ready(sched_ready),
    .sch_take(sch_take), .sch_port(sch_port), .sch_ack(pb_sch_ack),
    .sch_blk(pb_sch_blk), .sch_len(pb_sch_len),
    .start_vld(sch_start_vld), .start_vl(sch_start_vl),
    .start_blk(sch_start_blk), .start_len(sch_start_len),
    .builder_busy(fb_busy), .builder_len_err(fb_len_err), .frame_start(rm_frame_start),
    .bag_viol(sch_bag_viol), .bag_ovf_cnt(sch_bag_cnt),
    .take_miss_cnt(sch_miss_cnt), .vl_valid_cnt(sch_valid_cnt));

  wire snap_req, snap_ack, fb_out_vld, fb_out_sof, fb_out_eof, fb_out_rdy;
  wire [7:0] snap_vl, snap, fb_cur_vl, fb_byte_a, fb_byte_b;
  wire [15:0] fb_p1_stall;
  tx_sn_gen #(.NUM_TX_VL(NUM_TX_VL)) u_sn (
    .clk(clk), .rst_sync(rst_sync), .snap_req(snap_req), .snap_vl(snap_vl),
    .snap(snap), .snap_ack(snap_ack),
    .commit(fb_done), .commit_vl(fb_cur_vl),
    .init_all(1'b0), .ovr_we(1'b0), .ovr_vl(8'd0), .ovr_val(8'd0),
    .sn_pend(), .err());
  // VLID 的 P0 集成映射暂取 0x0100+表序号；任意 VLID 映射/配置脚本留 T12/T22 完整项。
  tx_frame_builder #(.BYTE_SLOT_CYC(IF_MODE ? 1 : BYTE_SLOT_CYC)) u_builder (
    .clk(clk), .rst_sync(rst_sync),
    .start_vld(sch_start_vld), .start_vl(sch_start_vl),
    .start_blk(sch_start_blk), .start_len(sch_start_len),
    .busy(fb_busy), .done(fb_done), .cur_vl(fb_cur_vl), .len_err(fb_len_err),
    .hdr_vlid(16'h0100+{8'd0,sch_start_vl}),
    .hdr_udi(smac_r[31:16]), .hdr_ifid_a(smac_r[2:0]), .hdr_ifid_b(smac_r[14:12]),
    .hdr_tos({3'd0,cfg_w1_q[4:0]}), .hdr_ttl(8'd255), .hdr_ident(16'd0),
    .hdr_src_ip(ip_r), .hdr_dst_ip(cfg_w3_q),
    .hdr_sport(cfg_w2_q[15:0]), .hdr_dport(cfg_w2_q[31:16]),
    .hdr_udp_csum_en(udp_cfg_r[1]),
    .snap_req(snap_req), .snap_vl(snap_vl), .snap(snap), .snap_ack(snap_ack),
    .rd_en_a(fb_rd_en_a), .rd_addr_a(fb_rd_addr_a), .rd_data_a(pmem_data_a),
    .rd_en_b(fb_rd_en_b), .rd_addr_b(fb_rd_addr_b), .rd_data_b(pmem_data_b),
    .out_vld(fb_out_vld), .out_byte_a(fb_byte_a), .out_byte_b(fb_byte_b),
    .out_sof(fb_out_sof), .out_eof(fb_out_eof), .out_rdy(fb_out_rdy),
    .blk_free(fb_free), .blk_free_id(fb_free_blk), .p1_stall_cnt(fb_p1_stall));

  wire rm_a_vld, rm_b_vld, rm_a_sof, rm_a_eof, rm_b_sof, rm_b_eof;
  wire rm_a_rdy, rm_b_rdy, mac_a_start, mac_a_done, mac_b_start, mac_b_done;
  wire [7:0] rm_a_byte, rm_b_byte, rm_done_vl;
  wire [15:0] rm_frames_a, rm_frames_b;
  tx_rm u_rm (
    .clk(clk), .rst_sync(rst_sync), .net_mode(active_net_mode), .in_vl(fb_cur_vl),
    .in_vld(fb_out_vld), .in_byte_a(fb_byte_a), .in_byte_b(fb_byte_b),
    .in_sof(fb_out_sof), .in_eof(fb_out_eof), .in_rdy(fb_out_rdy),
    .a_vld(rm_a_vld), .a_byte(rm_a_byte), .a_sof(rm_a_sof), .a_eof(rm_a_eof), .a_rdy(rm_a_rdy),
    .b_vld(rm_b_vld), .b_byte(rm_b_byte), .b_sof(rm_b_sof), .b_eof(rm_b_eof), .b_rdy(rm_b_rdy),
    .a_start(mac_a_start), .b_start(mac_b_start), .a_done(mac_a_done), .b_done(mac_b_done),
    .frame_start(rm_frame_start), .frame_done(rm_frame_done), .done_vl(rm_done_vl),
    .frames_a(rm_frames_a), .frames_b(rm_frames_b));

  wire pace_en, mac_a_busy, mac_b_busy;
  wire [15:0] mac_a_underrun, mac_b_underrun;
  tx_pace #(.IF_MODE(IF_MODE), .BYTE_SLOT_CYC(IF_MODE ? 1 : BYTE_SLOT_CYC)) u_pace (
    .clk(clk), .rst_sync(rst_sync), .pace_en(pace_en));
  mac_tx_if #(.IF_MODE(IF_MODE), .FCS_MODE(FCS_MODE), .IFG_BYTES(IFG_BYTES)) u_mac_a (
    .clk(clk), .rst_sync(rst_sync),
    .in_vld(rm_a_vld), .in_byte(rm_a_byte), .in_sof(rm_a_sof), .in_eof(rm_a_eof), .in_rdy(rm_a_rdy),
    .pace_en(pace_en), .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready),
    .link_rdy(rx_ready), .frame_start(mac_a_start), .frame_done(mac_a_done),
    .busy(mac_a_busy), .underrun_cnt(mac_a_underrun));
  mac_tx_if #(.IF_MODE(IF_MODE), .FCS_MODE(FCS_MODE), .IFG_BYTES(IFG_BYTES)) u_mac_b (
    .clk(clk), .rst_sync(rst_sync),
    .in_vld(rm_b_vld), .in_byte(rm_b_byte), .in_sof(rm_b_sof), .in_eof(rm_b_eof), .in_rdy(rm_b_rdy),
    .pace_en(pace_en), .tx_data(tx_data_b), .tx_valid(tx_valid_b), .tx_ready(tx_ready_b),
    .link_rdy(rx_ready_b), .frame_start(mac_b_start), .frame_done(mac_b_done),
    .busy(mac_b_busy), .underrun_cnt(mac_b_underrun));
  assign dbg_frame_event = {2'b00, rm_frame_start, rm_frame_done};

  // TODO: RX 后级与管理面仍是桩；T22 全流程需补哈希映像校验/接收回环。
  // Q20 前门判决属于 T05c 单项，不替代 T05b 的满载抖动取证。
/* verilator lint_on UNUSED */

endmodule
