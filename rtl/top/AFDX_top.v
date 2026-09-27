// =====================================================================
// AFDX_top.v —— AFDX 端系统顶层（第 2 周初始化/主机总线接线中）
// 设计书: §5.1（顶层端口总表）/ §4.2（复位）/ §4.3（参数表）/
//         §7.14 + 附录 A（寄存器页，doc/regs.yaml 为单一来源）/ §7.18（时基）
// 状态: 初始化扫描/前门/TX 闭环；RX 双入口/PMEM -> lookup -> FLT -> IC -> RM
//       已接线（v0.5.14：rx_ic 独占 PSN RAM；v0.5.15：rx_rm 独占 RM_ST RAM）。
//       RM forward 帧因解析/端口未实现仍只计数并回收块；后级 RX/管理面及完整
//       T05/T22 指标仍未验收。
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
  parameter integer STATS_EN      = 1,
  // continue4：管理面 SAP 端口号→服务映射（按 SAP 端口路由，不动 UDP 端口基址）
  parameter integer SNMP_SAP_PORT = 6,
  parameter integer TFTP_SAP_PORT = 7,
  parameter integer RTC_US_PER_SEC = 1000000,
  parameter integer RTC_SYNC_TO_US = 4000,
  parameter integer TFTP_TIMEOUT_US = 5000
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

  // PSN RAM 由 u_rxic 唯一持有（init_sweep T_PSN 直写其单写口）；哈希 RAM
  // 由 u_rxlookup 唯一持有；RM_ST 由 u_rxrm、RX 端口描述符由 u_rxpb 持有。
  // 其他配置字不复位；w0.valid 清零后读取未启用项返回零，避免暴露 X 内容。
  // continue2（2026-09-25）：rx_cfg_mem（2×NUM_RX_VL×32，6 个组合读口）是顶层
  // eLinx OPT_MUXTREE "bad allocation" 的决定性根因（iso_top_only 失败、
  // iso_top_rxvl64 通过）。改为 w0/w1 两张同步读 BRAM（bram_sdp 1W2R 副本），
  // 每个读口带"地址命中"握手门控：读地址与上拍寄存地址一致且上拍无写入时
  // 数据有效，消费者 in_vld/上游 ready 以此门控；主机读未命中不 ACK（保持重试）。
  // 语义不变，仅新 VL 地址首拍多 1 拍等待。
  function integer clog2_f;
    input integer value;
    integer v;
    begin
      v = value - 1;
      for (clog2_f = 0; v > 0; clog2_f = clog2_f + 1) v = v >> 1;
    end
  endfunction
  localparam integer RXA = (NUM_RX_VL <= 2) ? 1 : clog2_f(NUM_RX_VL);
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
  reg [31:0] vl_stat_mem  [0:NUM_TX_VL-1];
  reg [31:0] vl_tx_frame_cnt [0:NUM_TX_VL-1];
  reg [31:0] vl_rx_accept_cnt[0:NUM_TX_VL-1];
  reg [31:0] vl_drop_cnt     [0:NUM_TX_VL-1];

  // RX 描述符（v0.5.16 起 174 bit）：{plen[10:0], blk, len, ts, vlid, sn, net,
  // ifid, src, dst, sport, dport}；低 163 bit 布局与 rx_ic 单元测试一致。
  localparam integer RXD_W = 174;
  reg [31:0] ctl_r, int_en_r, err_r, int_st_r;
  reg [31:0] smac_r, ip_r, udp_cfg_r, dbg_ctrl_r, rdata_r;
  reg [15:0] hash_seed0_r, hash_seed1_r;
  reg hash_seed0_set, hash_seed1_set, hash_entry_seen, hash_image_valid;
  wire hash_cfg_ready, hash_cfg_rvalid;
  wire hash_rd_accept, cfg_write;
  wire [31:0] hash_cfg_rdata;
  wire lookup_in_ready, lookup_out_vld, lookup_out_hit;
  wire [11:0] lookup_out_vl;
  wire [RXD_W-1:0] lookup_out_desc;
  wire flt_in_ready, flt_out_vld, flt_out_pass;
  wire [2:0] flt_out_reason;
  wire [11:0] flt_out_vl;
  wire [RXD_W-1:0] flt_out_desc;
  wire flt_out_ready;
  reg  [31:0] flt_unconf_cnt, flt_lmax_cnt, flt_drop_total;
  wire ic_in_vld, ic_in_ready, ic_out_vld, ic_out_accept;
  wire [2:0] ic_out_reason;
  wire [11:0] ic_out_vl;
  wire [RXD_W-1:0] ic_out_desc;
  reg  [31:0] ic_drop_cnt, ic_accept_cnt;
  wire rm_in_vld, rm_in_ready, rm_out_vld, rm_out_fwd, rm_out_skew;
  wire [RXD_W-1:0] rm_in_desc, rm_out_desc;
  wire [11:0] rm_in_vl, rm_out_vl;
  reg  [31:0] rm_dup_cnt, rm_fwd_cnt, rm_skew_cnt;
  wire rm_out_ready, rm_fire, rm_dup_fire;
  wire prs_in_ready, prs_out_vld, prs_out_drop;
  // continue2：RX_VL_CFG BRAM 化后主机读直出（见 u_rxcfg_h*）
  wire host_rxc_wait;
  reg  rxc_rd_d, rxc_sel_d;
  wire [31:0] rxc_host_rdata;
  wire [31:0] rxq_host_w0, rxq_host_w1;
  wire [2:0] prs_out_reason;
  wire [7:0] prs_out_port;
  wire [1:0] prs_out_type;
  wire [3:0] prs_out_depth, prs_out_blk;
  wire [10:0] prs_out_plen;
  wire [23:0] prs_out_ts;
  wire pb_in_ready, pb_free0, pb_free1, pb_ev_drop, pb_ev_sample, pb_ev_queue, pb_ev_ovf;
  // SAP bypasses rx_port_buf only after its normal P2 validation. The
  // descriptor handoff owns its block until it requests an arbitrated return.
  wire prs_to_sap, prs_to_port, sap_in_ready, mgmt_free_req, mgmt_free_take;
  wire [3:0] mgmt_free_id;
  wire [31:0] mgmt_accept_cnt, mgmt_free_cnt, mgmt_last_desc;
  wire rx_crc_err_a, rx_crc_err_b;
  wire [3:0] pb_free0_id, pb_free1_id, rxpb_cnt_word;
  wire [31:0] rxpb_desc_word, rxpb_deliver_cnt, rxpb_port_drop_cnt,
              rxpb_ovr_cnt, rxpb_qovf_cnt;
  wire rx_desc_valid_a, rx_desc_valid_b, rx_desc_pop_a, rx_desc_pop_b;
  wire [RXD_W-1:0] rx_desc_a, rx_desc_b;
  // 前置跨区声明：Questa vlog-2730 不允许在主机译码里先使用、后声明。
  wire host_pmem_rd, desc_hit, pmem_wok, msg_valid, fb_busy, sch_take, pb_wr_valid;
  wire [7:0] desc_idx;
  wire [3:0] pb_wr_blk;
  wire [15:0] pb_free_map, sch_bag_cnt;
  wire [31:0] pmem_data_a, pb_desc_rd_data;
  wire [NUM_PORTS-1:0] pb_req;
  reg ack_r, pmem_rd_d, desc_rd_d, hash_rd_d, desc_rx_d;
  wire host_rx_rd, host_rx_rd_wait, hop_desc_rd, fb_rd_en_a;
  // continue4：全局统计页 0x0100~0x01FF 由 stats_regs 承担（前置声明，§10/vlog-2730）
  wire [31:0] stats_rdata;
  wire        stats_wr_ok;
  wire [7:0]  stats_snmp_off;
  wire [31:0] stats_snmp_rdata;
  // continue4：管理面（SNMP / A615-A TFTP / RTC）前置声明
  wire        sap_pm_req, sap_pm_gnt;
  wire [12:0] sap_pm_addr;
  wire        sap_out_vld, sap_out_sop, sap_out_eop;
  wire [7:0]  sap_out_data;
  wire [15:0] sap_out_sport, sap_out_dport;
  wire [31:0] sap_out_srcip;
  wire [31:0] mgmt_pay_cnt;
  wire [31:0] snmp_st_w, snmp_cnt_rx, snmp_cnt_tx, snmp_cnt_drop;
  wire [10:0] snmp_resp_len;
  wire        snmp_resp_vld;
  wire [7:0]  snmp_resp_byte;
  wire        snmp_ctl_we;
  wire [15:0] snmp_ctl_wdata;
  wire [7:0]  snmp_mib_group, snmp_mib_leaf, snmp_mib_index;
  wire [31:0] snmp_vl_data;
  wire        snmp_vl_bag_allowed, snmp_vl_bag_we;
  wire [7:0]  snmp_vl_bag_index;
  wire [31:0] snmp_vl_bag_wdata;
  wire [31:0] tftp_st_w, tftp_bytes, tftp_crc, tftp_pkt, tftp_de, tftp_tr, tftp_fnh;
  wire [10:0] tftp_resp_len;
  wire        tftp_resp_vld;
  wire [7:0]  tftp_resp_byte;
  wire [31:0] tftp_load_rdata;
  wire [31:0] rtc_st_w, rtc_err_w, rtc_jump_w, rtc_step_w, rtc_pps_w, rtc_phase_w;
  wire [63:0] rtc_corrected;
  wire        rtc_pps_pulse, rtc_locked, rtc_sloss;
  reg         load_rd_d;
  wire [31:0] stats_jit_max, stats_drop_total;
  reg  [15:0] snmp_ctl_shadow;
  reg  [7:0]  mgmt_bidx;
  reg  [31:0] uptime_cs;
  reg  [13:0] cs_div;
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
      desc_rx_d <= 1'b0;
    end
    else begin
      // 运行期 RX 块读与 builder 抢读口 A 时不 ACK，主机保持请求到 ACK（重试）。
      ack_r <= (hs && (!host_pmem_req || host_commit_now) && !host_rx_rd_wait &&
                !host_rxc_wait) ||
               host_commit_pending;
      pmem_rd_d <= host_pmem_rd;
      desc_rd_d <= hs && !host_we && desc_hit;
      desc_rx_d <= hop_desc_rd;
      hash_rd_d <= hash_rd_accept;
    end
  end
  assign host_ack = ack_r;
  // continue2 修复（2026-09-25，本轮）：RX_VL_CFG 改为 BRAM 同步读后 rdata_r 在
  // rx_hit 时恒为 0，主机回读必须由 rxc_host_rdata 在 ACK 拍直出。上一轮改造漏接
  // 本选择器，导致 T01/T22/T22g 的 RX CFG 回读与 T08f/T08fg 全表记分板读回 0。
  // 地址域互斥（RX_VL_CFG 0x1D80-0x3D7F 不与 hash/pmem/desc 段重叠），故插在最前
  // 不改变其他读路径优先级。
  assign host_rdata = rxc_rd_d  ? rxc_host_rdata :
                      load_rd_d ? tftp_load_rdata :
                      hash_rd_d ? hash_cfg_rdata :
                       pmem_rd_d ? pmem_data_a :
                      desc_rd_d ? (desc_rx_d ? rdata_r :
                                   pb_req[desc_idx] ? pb_desc_rd_data : 32'd0) : rdata_r;

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
  // MGMT_WIN follows VL_STATS without aliasing it. Table/window words are:
  // 0 accept count, 1 block-return count, 2 latest descriptor, 3 busy.
  wire mgmt_hit = (host_addr >= 16'hAC10 && host_addr <= 16'hAC13);
  // continue4：管理面观测窗 0xAC14~0xAC3F（SNMP/TFTP/RTC 状态与响应字节口）
  wire mgmt2_hit = (host_addr >= 16'hAC14 && host_addr <= 16'hAC3F);
  // continue4：A615-A 加载区 0xCC20~0xEC1F（8192 字 = 32 KB），同步读
  wire load_hit  = (host_addr >= 16'hCC20 && host_addr <= 16'hEC1F);
  wire pmem_hit = (host_addr >= 16'h8800 && host_addr <= 16'hA7FF);
  wire msg_wr_hit = (host_addr >= 16'h8280 && host_addr <= 16'h837F);
  // v0.5.16 RX 端口主机操作：PORT_DESC 0x8180+p（RX 端口读即清 fresh/ovf）、
  // MSG_RD 0x8380+p（写：释放）、MSG_CNT 0x8480+p（读：消息数）。三段低 8 位
  // 同为 0x80 起，端口号统一为 host_addr[7:0]-0x80。端口表 w0[18]=1 为 RX 端口。
  wire msg_rd_hit  = (host_addr >= 16'h8380 && host_addr <= 16'h847F);
  wire msg_cnt_hit = (host_addr >= 16'h8480 && host_addr <= 16'h857F);
  wire [7:0]  hop_port = host_addr[7:0] - 8'h80;
  wire [31:0] hop_w0 = port_cfg_mem[{hop_port,2'b00}];
  wire hop_is_rx = hop_w0[31] && hop_w0[18];
  assign hop_desc_rd = hs && !host_we && desc_hit && hop_is_rx && init_done;
  wire msg_rd_ok = msg_rd_hit && init_done && hop_is_rx;
  wire hop_msg_rd = we && msg_rd_ok;
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
  wire snmp_vl_valid = (snmp_mib_index < NUM_TX_VL);
  wire [9:0] snmp_vl_base = {2'd0,snmp_mib_index} * 10'd5;
  assign snmp_vl_bag_allowed = snmp_vl_valid && (snmp_mib_leaf == 8'd5);
  assign snmp_vl_data = !snmp_vl_valid ? 32'd0 :
                        (snmp_mib_leaf == 8'd5) ? {8'd0,tx_cfg_mem[snmp_vl_base+10'd1][31:8]} :
                        (snmp_mib_leaf == 8'd6) ? vl_tx_frame_cnt[snmp_mib_index] :
                        (snmp_mib_leaf == 8'd7) ? vl_rx_accept_cnt[snmp_mib_index] :
                        (snmp_mib_leaf == 8'd8) ? vl_drop_cnt[snmp_mib_index] :
                        (snmp_mib_leaf == 8'd9) ? vl_stat_mem[snmp_mib_index] : 32'd0;
  // ---- RX_VL_CFG 存储（continue2：w0/w1 分表 BRAM 副本，写口全部同源）----
  // 流水线读口（FLT w0/w1、RM 入口 w0、解析 w0）：写口 posedge、读口 negedge。
  //   读地址均为上升沿寄存的级输出（lookup_out_vl/rm_in_vl/rm_out_vl），在
  //   下降沿采样，数据于下一上升沿前稳定 → 与原组合读逐拍等价（无额外气泡）；
  //   代价：读出到消费寄存器为半周期路径（STA 须按半周期约束核对）。
  //   brams.txt: clocks 2 3 / clkpol 2 3（端口独立时钟与极性）可映射。
  // 主机读口：posedge 同步读，数据在 ACK 拍直接经 rxc_rd_d 选出（原 rdata_r 同拍）。
  wire rxc_init_we = init_we && (init_target == 3'd3);
  wire rxc_host_we = cfg_write && rx_hit;
  wire rxc_w0_we = rxc_init_we || (rxc_host_we && !rx_idx[0]);
  wire rxc_w1_we = !rxc_init_we && rxc_host_we && rx_idx[0];
  wire [RXA-1:0] rxc_waddr = rxc_init_we ? init_addr[RXA-1:0] : rx_idx[RXA:1];
  wire [31:0] rxc_wdata = rxc_init_we ? 32'd0 : host_wdata;
  wire rxc_any_we = rxc_w0_we || rxc_w1_we;
  wire [RXA-1:0] rxa_flt  = lookup_out_vl[RXA-1:0];
  wire [RXA-1:0] rxa_rm   = rm_in_vl[RXA-1:0];
  wire [RXA-1:0] rxa_prs  = rm_out_vl[RXA-1:0];
  wire [RXA-1:0] rxa_host = rx_idx[RXA:1];
  wire [31:0] rxq_flt_w0, rxq_rm_w0, rxq_prs_w0, rxq_flt_w1;
  bram_1w1r #(.W(32), .D(NUM_RX_VL), .RD_NEG(1)) u_rxcfg_flt0 (
    .clk(clk), .wr_en(rxc_w0_we), .wr_addr(rxc_waddr), .wr_data(rxc_wdata),
    .rd_addr(rxa_flt), .rd_data(rxq_flt_w0));
  bram_1w1r #(.W(32), .D(NUM_RX_VL), .RD_NEG(1)) u_rxcfg_flt1 (
    .clk(clk), .wr_en(rxc_w1_we), .wr_addr(rxc_waddr), .wr_data(rxc_wdata),
    .rd_addr(rxa_flt), .rd_data(rxq_flt_w1));
  bram_1w1r #(.W(32), .D(NUM_RX_VL), .RD_NEG(1)) u_rxcfg_rm0 (
    .clk(clk), .wr_en(rxc_w0_we), .wr_addr(rxc_waddr), .wr_data(rxc_wdata),
    .rd_addr(rxa_rm), .rd_data(rxq_rm_w0));
  bram_1w1r #(.W(32), .D(NUM_RX_VL), .RD_NEG(1)) u_rxcfg_prs0 (
    .clk(clk), .wr_en(rxc_w0_we), .wr_addr(rxc_waddr), .wr_data(rxc_wdata),
    .rd_addr(rxa_prs), .rd_data(rxq_prs_w0));
  bram_1w1r #(.W(32), .D(NUM_RX_VL), .RD_NEG(0)) u_rxcfg_h0 (
    .clk(clk), .wr_en(rxc_w0_we), .wr_addr(rxc_waddr), .wr_data(rxc_wdata),
    .rd_addr(rxa_host), .rd_data(rxq_host_w0));
  bram_1w1r #(.W(32), .D(NUM_RX_VL), .RD_NEG(0)) u_rxcfg_h1 (
    .clk(clk), .wr_en(rxc_w1_we), .wr_addr(rxc_waddr), .wr_data(rxc_wdata),
    .rd_addr(rxa_host), .rd_data(rxq_host_w1));
  // 主机读与 init 扫描写同拍（仅 INIT 期间可能）时不 ACK，主机保持重试。
  assign host_rxc_wait = hs && !host_we && rx_hit && rxc_any_we;
  always @(posedge clk) begin
    if (rst_sync) begin rxc_rd_d <= 1'b0; rxc_sel_d <= 1'b0; end
    else begin
      rxc_rd_d  <= hs && !host_we && rx_hit && !rxc_any_we;
      rxc_sel_d <= rx_idx[0];
    end
  end
  // 读未启用项（w0.valid=0）返回零，语义同原 rx_cfg_valid。
  assign rxc_host_rdata = !rxq_host_w0[31] ? 32'd0 :
                          (rxc_sel_d ? rxq_host_w1 : rxq_host_w0);
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
    // RX_VL_CFG 写口已移入 u_rxcfg_w0a/w0b/w1（见上文），扫描优先级不变。
    if (init_we && init_target == 3'd4) tx_cfg_mem[init_addr * 13'd5] <= 32'd0;
    else if (cfg_write && tx_hit) tx_cfg_mem[tx_idx] <= host_wdata;
    else if (snmp_vl_bag_we && (snmp_vl_bag_index < NUM_TX_VL))
      tx_cfg_mem[({2'd0,snmp_vl_bag_index} * 10'd5) + 10'd1][31:8] <= snmp_vl_bag_wdata[23:0];
    if (init_we && init_target == 3'd5) port_cfg_mem[init_addr * 13'd4] <= 32'd0;
    else if (cfg_write && port_hit) port_cfg_mem[port_idx] <= host_wdata;
    if (init_we && init_target == 3'd7) begin
      vl_stat_mem[init_addr] <= 32'd0;
      vl_tx_frame_cnt[init_addr] <= 32'd0;
      vl_rx_accept_cnt[init_addr] <= 32'd0;
      vl_drop_cnt[init_addr] <= 32'd0;
    end
  end

  // 时基（RTC 同步留待管理面）；静态网络发送依赖真实 rtc64[23:0]。
  wire tick_us, alive;
  wire [63:0] rtc64;
  timebase #(.TICK_US(TICK_US)) u_timebase (
    .clk(clk), .rst(rst_sync), .rtc_hold(ctl_r[11]),
    .freq_adj(16'd524), .rtc64(rtc64), .tick_us(tick_us), .alive(alive));
  // continue4：对外 RTC 走 rtc_sync 的校正结果（无对时事件时 offset=0，等于 rtc64）；
  // 片内 TX 时间戳仍直接用 rtc64，避免改变既有发送时序语义。
  assign rtc_time_us = (RTC_EN != 0) ? rtc_corrected : rtc64;
  assign pps_out     = (RTC_EN != 0) ? rtc_pps_pulse : 1'b0;

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
                  port_hit || desc_hit || vlstat_hit || mgmt_hit || mgmt2_hit ||
                  (load_hit && (TFTP_EN != 0)) || msg_cnt_hit || host_rx_rd ||
                  (pmem_hit && init_done && ctl_r[13] && !ctl_r[0] && !fb_busy);
  wire stats_wr = we && stats_hit && stats_wr_ok;   // continue4：统计页 W1C
  wire mgmt2_wr = we && mgmt2_hit;                  // continue4：观测窗控制字
  wire wr_known = (reg_page && reg_align && reg_writable) ||
                  (cfg_write && (tx_hit || rx_hit || port_hit)) ||
                  hash_wr_accept ||
                  share_wr || stats_wr || mgmt2_wr ||
                  pmem_wok || msg_valid || msg_rd_ok;
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
        // udp_csum,crc,unconf,lmax,ic,rm（§7.16）。已接 FLT unconf/lmax 与
        // IC（0x48）；其余类别仍未接线返回 0，不能当完整统计面验收。
        if (drop_k) rdata_r <= (off == 8'h40) ? flt_unconf_cnt :
                               (off == 8'h44) ? flt_lmax_cnt :
                               (off == 8'h48) ? ic_drop_cnt :
                               (off == 8'h4C) ? rm_dup_cnt : 32'd0;
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
      // 全局统计页（v0.5.16 起接 RX 端口面，其余仍读 0）：0x0100 RX 交付消息数，
      // 0x0101 解析丢弃（端口未配/方向/UDP 目的端口/SAP），0x0102 采样覆盖，
      // 0x0103 队列满丢弃。
      // continue4：整页交给 stats_regs；0x00~0x03 仍是 rx_port_buf 既有口径镜像。
      end else if (stats_hit) rdata_r <= stats_rdata;
      else if (tx_hit) rdata_r <= tx_cfg_valid ? tx_cfg_mem[tx_idx] : 32'd0;
      else if (share_hit) rdata_r <= (init_done && cfg_share_loaded[share_idx]) ?
                                   {11'd0,cfg_share_mem[share_idx]} : 32'd0;
      else if (rx_hit) rdata_r <= 32'd0;  // continue2：由 rxc_rd_d/rxc_host_rdata 直出
      else if (port_hit) rdata_r <= port_cfg_valid ? port_cfg_mem[port_idx] : 32'd0;
      else if (desc_hit) rdata_r <= hop_is_rx ? rxpb_desc_word : 32'd0;  // TX: PB 读出经 desc_rd_d 选
      else if (msg_cnt_hit) rdata_r <= hop_is_rx ? {28'd0,rxpb_cnt_word} : 32'd0;
      else if (vlstat_hit) rdata_r <= (vs_idx[2:0] == 3'd0 &&
                            ((vs_idx >> 3) < NUM_TX_VL)) ? vl_stat_mem[vs_idx >> 3] : 32'd0;
             else if (mgmt_hit) rdata_r <= (host_addr[1:0] == 2'd0) ? mgmt_accept_cnt :
                                      (host_addr[1:0] == 2'd1) ? mgmt_free_cnt :
                                      (host_addr[1:0] == 2'd2) ? mgmt_last_desc :
                                      {31'd0,mgmt_free_req};
       // continue4：管理面观测窗（只读为主，0xAC1A/0xAC1C/0xAC28 为控制字）
       else if (mgmt2_hit) begin
         case (host_addr[5:0])
           6'h14: rdata_r <= snmp_st_w;
           6'h15: rdata_r <= {21'd0, snmp_resp_len};
           6'h16: rdata_r <= snmp_cnt_rx;
           6'h17: rdata_r <= snmp_cnt_tx;
           6'h18: rdata_r <= snmp_cnt_drop;
           6'h19: rdata_r <= mgmt_pay_cnt;
           6'h1A: rdata_r <= {24'd0, mgmt_bidx};
           6'h1B: rdata_r <= {24'd0, snmp_resp_byte};
           6'h1C: rdata_r <= {31'd0, snmp_resp_vld};
           6'h1D: rdata_r <= {16'd0, sap_out_dport};
           6'h1E: rdata_r <= {16'd0, sap_out_sport};
           6'h1F: rdata_r <= sap_out_srcip;
           6'h20: rdata_r <= tftp_st_w;
           6'h21: rdata_r <= tftp_bytes;
           6'h22: rdata_r <= tftp_crc;
           6'h23: rdata_r <= tftp_pkt;
           6'h24: rdata_r <= tftp_de;
           6'h25: rdata_r <= tftp_tr;
           6'h26: rdata_r <= {20'd0, tftp_resp_vld, tftp_resp_len};
           6'h27: rdata_r <= {24'd0, tftp_resp_byte};
           6'h29: rdata_r <= tftp_fnh;
           6'h30: rdata_r <= rtc_st_w;
           6'h31: rdata_r <= rtc_err_w;
           6'h32: rdata_r <= rtc_jump_w;
           6'h33: rdata_r <= rtc_step_w;
           6'h34: rdata_r <= rtc_pps_w;
           6'h35: rdata_r <= rtc_phase_w;
           6'h36: rdata_r <= rtc_corrected[31:0];
           6'h37: rdata_r <= rtc_corrected[63:32];
           6'h38: rdata_r <= uptime_cs;
           default: rdata_r <= 32'd0;
         endcase
       end
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
      // INT_STATUS（v0.5.17）：[0] 新采样消息 [1] 队列入队 [2] 采样覆盖/队列满
      // [3] CRC 错帧（A 或 B）；事件置位优先于同拍 W1C。[4] 丢弃突增阈值寄存器
      // 未定义、[5..7] 管理面未接，恒 0。
      int_st_r <= (w1c_int ? (int_st_r & ~host_wdata) : int_st_r) |
                  {28'd0, (rx_crc_err_a | rx_crc_err_b), pb_ev_ovf, pb_ev_queue, pb_ev_sample};
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
                   msg_port_w0[31] && !msg_port_w0[18] &&
                   (msg_port_w0[17:16] != 2'd2) && msg_len_ok;
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
  // 运行期（CFG_MODE=0）主机可读 RX 块（6..15）取接收载荷；读口 A 被 builder
  // 占用的拍不读不 ACK（host_rx_rd_wait），主机按协议保持请求直到 ACK。
  assign host_rx_rd = hs && !host_we && pmem_hit && init_done && !ctl_r[13] &&
                      (host_pmem_addr[12:9] >= 4'd6);
  assign host_rx_rd_wait = host_rx_rd && fb_rd_en_a;
  assign host_pmem_rd = (hs && !host_we && pmem_hit && init_done && ctl_r[13] &&
                         !ctl_r[0] && !fb_busy) || (host_rx_rd && !fb_rd_en_a);
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
  wire fb_rd_en_b;
  wire [12:0] fb_rd_addr_a, fb_rd_addr_b;
  wire [31:0] pmem_data_b;
  bram_sdp #(.W(32), .D(PMEM_KB*256), .BYTE_EN(1)) u_pmem (
    .clk(clk), .wr_en(pmem_wr_en), .wr_addr(pmem_wr_addr),
    .wr_data(pmem_wr_data), .wr_be(pmem_wr_be),
    .rd_en_a(host_pmem_rd | fb_rd_en_a | sap_pm_gnt),
    .rd_addr_a(host_pmem_rd ? host_pmem_addr :
               fb_rd_en_a  ? fb_rd_addr_a    : sap_pm_addr), .rd_data_a(pmem_data_a),
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
  // Round-robin the primary slot on contention. Port-buffer free1 is a pulse
  // with NO ready/hold handshake: the loser must use an independent spill slot
  // or its block would be leaked. Both returns are accepted in the same clock,
  // so SAP cannot be starved by continuous port-buffer releases.
  reg sap_pb1_turn;
  always @(posedge clk) begin
    if (rst_sync) sap_pb1_turn <= 1'b0;
    else if (pb_free1 && mgmt_free_req) sap_pb1_turn <= ~sap_pb1_turn;
  end
  wire sap_uses_pb1 = mgmt_free_req && (!pb_free1 || sap_pb1_turn);
  wire pool_free_pb1 = pb_free1 || mgmt_free_req;
  wire [3:0] pool_free_pb1_id = sap_uses_pb1 ? mgmt_free_id : pb_free1_id;
  wire pool_free_spill = pb_free1 && mgmt_free_req;
  wire [3:0] pool_free_spill_id = sap_pb1_turn ? pb_free1_id : mgmt_free_id;
  assign mgmt_free_take = mgmt_free_req; // primary or spill, never dropped
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
    .free_pb0(pb_free0), .free_id_pb0(pb_free0_id),
    .free_pb1(pool_free_pb1), .free_id_pb1(pool_free_pb1_id),
    .free_spill(pool_free_spill), .free_id_spill(pool_free_spill_id),
    .free_map(rx_free_map), .exhaust_cnt(rx_exh_cnt), .borrow_cnt(rx_borrow_cnt));
  wire rxw_en_a, rxw_en_b, rxd_vld_a, rxd_vld_b;
  wire [12:0] rxw_addr_a, rxw_addr_b;
  wire [31:0] rxw_data_a, rxw_data_b;
  wire [3:0] rxw_be_a, rxw_be_b;
  wire [3:0] rxd_blk_a, rxd_blk_b;
  wire [10:0] rxd_len_a, rxd_len_b, rxd_plen_a, rxd_plen_b;
  wire [23:0] rxd_ts_a, rxd_ts_b;
  wire [15:0] rxd_vlid_a, rxd_vlid_b, rxd_sport_a, rxd_sport_b,
              rxd_dport_a, rxd_dport_b;
  wire [7:0] rxd_sn_a, rxd_sn_b, rx_drop_reason_a, rx_drop_reason_b;
  wire [2:0] rxd_ifid_a, rxd_ifid_b;
  wire [31:0] rxd_src_a, rxd_src_b, rxd_dst_a, rxd_dst_b;
  wire rxd_net_a, rxd_net_b, rx_frame_err_a, rx_frame_err_b;
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
    .desc_sport(rxd_sport_a), .desc_dport(rxd_dport_a), .desc_plen(rxd_plen_a),
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
    .desc_sport(rxd_sport_b), .desc_dport(rxd_dport_b), .desc_plen(rxd_plen_b),
    .frame_err(rx_frame_err_b), .crc_err(rx_crc_err_b),
    .drop_reason(rx_drop_reason_b), .good_cnt(), .drop_cnt(), .disabled_cnt());
  wire [RXD_W-1:0] rx_desc_in_a = {rxd_plen_a,rxd_blk_a,rxd_len_a,rxd_ts_a,rxd_vlid_a,rxd_sn_a,
                                rxd_net_a,rxd_ifid_a,rxd_src_a,rxd_dst_a,
                                rxd_sport_a,rxd_dport_a};
  wire [RXD_W-1:0] rx_desc_in_b = {rxd_plen_b,rxd_blk_b,rxd_len_b,rxd_ts_b,rxd_vlid_b,rxd_sn_b,
                                rxd_net_b,rxd_ifid_b,rxd_src_b,rxd_dst_b,
                                rxd_sport_b,rxd_dport_b};
  wire rx_ovf_a, rx_ovf_b;
  rx_pmem_queue #(.DW(RXD_W)) u_rxq_a (
    .clk(clk), .rst_sync(rst_sync), .in_wr_en(rxw_en_a), .in_wr_addr(rxw_addr_a),
    .in_wr_data(rxw_data_a), .in_wr_be(rxw_be_a),
    .in_desc_vld(rxd_vld_a), .in_desc(rx_desc_in_a), .frame_room(rx_room_a),
    .wr_valid(q_wr_a), .wr_addr(q_addr_a), .wr_data(q_data_a), .wr_be(q_be_a), .wr_pop(q_pop_a),
    .desc_valid(rx_desc_valid_a), .desc(rx_desc_a), .desc_pop(rx_desc_pop_a), .overflow(rx_ovf_a));
  rx_pmem_queue #(.DW(RXD_W)) u_rxq_b (
    .clk(clk), .rst_sync(rst_sync), .in_wr_en(rxw_en_b), .in_wr_addr(rxw_addr_b),
    .in_wr_data(rxw_data_b), .in_wr_be(rxw_be_b),
    .in_desc_vld(rxd_vld_b), .in_desc(rx_desc_in_b), .frame_room(rx_room_b),
    .wr_valid(q_wr_b), .wr_addr(q_addr_b), .wr_data(q_data_b), .wr_be(q_be_b), .wr_pop(q_pop_b),
    .desc_valid(rx_desc_valid_b), .desc(rx_desc_b), .desc_pop(rx_desc_pop_b), .overflow(rx_ovf_b));
  // 过渡切片：好帧描述符经 lookup -> rx_flt -> rx_ic 后释放 PMEM（RM/
  // 端口尚未接线，故 IC 接受帧也暂不交付消息，仅计数/释放；DROP 帧按
  // unconf/lmax/ic 归类计数）。配置期对停流前排队的描述符逐个丢弃而不是拿新
  // 映像重新解释，防止旧帧穿越换种子/重装边界。
  wire [RXD_W-1:0] lookup_in_desc = rx_desc_valid_a ? rx_desc_a : rx_desc_b;
  wire lookup_in_vld = rx_stream_en &&
                        (rx_desc_valid_a || rx_desc_valid_b);
  wire lookup_take = lookup_in_vld && lookup_in_ready;
  // drain、FLT 拒绝、IC 拒绝、RM 输出共用唯一 free_pipe 口：按拍互斥，
  // 否则同拍第二个块释放会被覆盖丢失（见下方 rx_pipe_free）。
  wire lookup_drain = !rx_stream_en && !lookup_out_vld && !flt_out_vld &&
                       !ic_out_vld && !rm_out_vld &&
                       (rx_desc_valid_a || rx_desc_valid_b);
  assign rx_desc_pop_a = rx_desc_valid_a && (lookup_take || lookup_drain);
  assign rx_desc_pop_b = !rx_desc_valid_a && rx_desc_valid_b &&
                         (lookup_take || lookup_drain);
  rx_vl_lookup #(.DW(RXD_W),.NUM_RX_VL(NUM_RX_VL),.HASH_BUCKETS(2048)) u_rxlookup (
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
  rx_flt #(.DW(RXD_W), .NUM_RX_VL(NUM_RX_VL)) u_rxflt (
    .clk(clk), .rst_sync(rst_sync), .init_we(init_we),
    .in_vld(lookup_out_vld), .in_ready(flt_in_ready),
    .in_hit(lookup_out_hit), .in_vl(lookup_out_vl),
    .in_desc(lookup_out_desc),
    .in_w0(rxq_flt_w0),
    .in_w1(rxq_flt_w1),
    .out_vld(flt_out_vld), .out_ready(flt_out_ready),
    .out_pass(flt_out_pass), .out_reason(flt_out_reason),
    .out_vl(flt_out_vl), .out_desc(flt_out_desc));
  // IC（§7.10）→ RM（§7.11）：FLT PASS 帧进入 rx_ic，按 {网, 查表索引} 读改写
  // 唯一 PSN RAM；CTL.IC_EN(bit2)=0 时 PASS 帧旁路 IC（不读写 PSN）直接进 RM。
  // IC 接受帧进入 rx_rm（唯一 RM_ST RAM，v0.5.15）；IC 拒绝帧回收块。
  // 唯一 free_pipe 口按拍互斥，优先级：RM 输出 > IC 拒绝 > FLT 拒绝 > drain；
  // 未获准的来源保持（rx_ic/rx_flt/rx_rm 输出均保持到握手）。
  // RM 进口两源：IC 接受优先，FLT 旁路仅在 IC 无输出时进入。
  wire ic_en = ctl_r[2];
  wire flt_to_ic = flt_out_pass && ic_en;
  wire flt_to_rm = flt_out_pass && !ic_en;
  wire ic_rej    = ic_out_vld && !ic_out_accept;
  wire ic_to_rm  = ic_out_vld && ic_out_accept;
  wire ic_out_ready = ic_out_accept ? rm_in_ready : !rm_out_vld;
  wire ic_fire   = ic_out_vld && ic_out_ready;
  assign ic_in_vld = flt_out_vld && flt_to_ic && !ic_out_vld;
  assign flt_out_ready = !ic_out_vld &&
                         (flt_to_ic ? ic_in_ready :
                          flt_to_rm ? rm_in_ready : !rm_out_vld);
  wire flt_fire = flt_out_vld && flt_out_ready;
  wire flt_free = flt_fire && !flt_out_pass;       // FLT 拒绝
  assign rm_in_vld  = ic_to_rm || (flt_out_vld && flt_to_rm && !ic_out_vld);
  assign rm_in_desc = ic_to_rm ? ic_out_desc : flt_out_desc;
  assign rm_in_vl   = ic_to_rm ? ic_out_vl   : flt_out_vl;
  wire [31:0] rm_in_w0 = rxq_rm_w0;
  rx_ic #(.DW(RXD_W), .NUM_RX_VL(NUM_RX_VL)) u_rxic (
    .clk(clk), .rst_sync(rst_sync), .init_done(init_done),
    .init_we(init_we && (init_target == 3'd0)), .init_addr(init_addr),
    .ic_first_any(udp_cfg_r[0]),
    .in_vld(ic_in_vld), .in_ready(ic_in_ready),
    .in_desc(flt_out_desc), .in_vl(flt_out_vl),
    .out_vld(ic_out_vld), .out_ready(ic_out_ready),
    .out_accept(ic_out_accept), .out_reason(ic_out_reason),
    .out_desc(ic_out_desc), .out_vl(ic_out_vl),
    // IC/RM 调试窗口（0xA800，DEBUG_EN）尚未实现：强制写口先 tie off。
    .dbg_en(1'b0), .dbg_wr(1'b0), .dbg_vl(12'd0), .dbg_net(1'b0), .dbg_psn(8'd0));
  rx_rm #(.DW(RXD_W), .NUM_RX_VL(NUM_RX_VL)) u_rxrm (
    .clk(clk), .rst_sync(rst_sync), .init_done(init_done),
    .init_we(init_we && (init_target == 3'd1)), .init_addr(init_addr),
    .rm_glb_en(ctl_r[3]),
    .in_vld(rm_in_vld), .in_ready(rm_in_ready),
    .in_desc(rm_in_desc), .in_vl(rm_in_vl),
    .in_rm_en(rm_in_w0[30]), .in_net_mode(rm_in_w0[29:28]),
    .in_skew_exp(rm_in_w0[27:24]),
    .out_vld(rm_out_vld), .out_ready(rm_out_ready),
    .out_fwd(rm_out_fwd), .out_skew(rm_out_skew),
    .out_desc(rm_out_desc), .out_vl(rm_out_vl),
    .dbg_en(1'b0), .dbg_wr(1'b0), .dbg_vl(12'd0), .dbg_data(33'd0));
  // RM → 解析（§7.12）→ 端口（§7.13），v0.5.16。RM forward 帧等待解析口，
  // 重复副本立即回收（free_pipe 最高优先）；解析丢弃与端口侧释放经 rx_port_buf
  // 的两个独立释放口归还，不占 free_pipe。
  assign rm_out_ready = rm_out_fwd ? prs_in_ready : 1'b1;
  assign rm_fire      = rm_out_vld && rm_out_ready;
  assign rm_dup_fire  = rm_out_vld && !rm_out_fwd;
  wire [31:0] prs_w0  = rxq_prs_w0;
  wire [7:0]  prs_pb  = prs_w0[19:12];
  rx_ip_udp_parse #(.DW(RXD_W), .NUM_PORTS(NUM_PORTS)) u_rxprs (
    .clk(clk), .rst_sync(rst_sync),
    .in_vld(rm_out_vld && rm_out_fwd), .in_ready(prs_in_ready),
    .in_desc(rm_out_desc), .in_w0(prs_w0),
    .port_w0(port_cfg_mem[{prs_pb,2'b00}]), .port_w1(port_cfg_mem[{prs_pb,2'b01}]),
    .port_w3(port_cfg_mem[{prs_pb,2'b11}]), .sap_enable(ctl_r[8]),
        .out_vld(prs_out_vld), .out_ready(prs_to_sap ? sap_in_ready : pb_in_ready),
    .out_drop(prs_out_drop), .out_reason(prs_out_reason), .out_port(prs_out_port),
    .out_type(prs_out_type), .out_depth(prs_out_depth), .out_blk(prs_out_blk),
    .out_plen(prs_out_plen), .out_ts(prs_out_ts));
    assign prs_to_sap  = prs_out_vld && !prs_out_drop && (prs_out_type == 2'd2);
  assign prs_to_port = prs_out_vld && !prs_to_sap;
  mgmt_sap_rx #(.PAY_OFF(42), .PBUF_W(160)) u_mgmt_sap (
    .pm_req(sap_pm_req), .pm_addr(sap_pm_addr), .pm_gnt(sap_pm_gnt),
    .pm_data(pmem_data_a),
    .out_vld(sap_out_vld), .out_sop(sap_out_sop), .out_eop(sap_out_eop),
    .out_data(sap_out_data), .out_sport(sap_out_sport), .out_dport(sap_out_dport),
    .out_srcip(sap_out_srcip), .out_plen(), .pay_cnt(mgmt_pay_cnt), .trunc_cnt(),
    .clk(clk), .rst_sync(rst_sync), .in_vld(prs_to_sap), .in_ready(sap_in_ready),
    .in_port(prs_out_port), .in_blk(prs_out_blk), .in_plen(prs_out_plen),
    .free_req(mgmt_free_req), .free_take(mgmt_free_take), .free_id(mgmt_free_id),
    .accept_cnt(mgmt_accept_cnt), .free_cnt(mgmt_free_cnt), .last_desc(mgmt_last_desc));
  rx_port_buf #(.NUM_PORTS(NUM_PORTS)) u_rxpb (
    .clk(clk), .rst_sync(rst_sync),
    .init_we(init_we && (init_target == 3'd6)), .init_addr(init_addr),
        .in_vld(prs_to_port), .in_ready(pb_in_ready), .in_drop(prs_out_drop),
    .in_port(prs_out_port), .in_type(prs_out_type), .in_depth(prs_out_depth),
    .in_blk(prs_out_blk), .in_plen(prs_out_plen),
    .hop_desc_rd(hop_desc_rd), .hop_msg_rd(hop_msg_rd), .hop_port(hop_port),
    .hop_type(hop_w0[17:16]), .desc_word(rxpb_desc_word), .cnt_word(rxpb_cnt_word),
    .free0(pb_free0), .free0_id(pb_free0_id), .free1(pb_free1), .free1_id(pb_free1_id),
    .ev_drop(pb_ev_drop), .ev_sample(pb_ev_sample), .ev_queue(pb_ev_queue),
    .ev_ovf(pb_ev_ovf), .deliver_cnt(rxpb_deliver_cnt),
    .port_drop_cnt(rxpb_port_drop_cnt), .ovr_cnt(rxpb_ovr_cnt), .qovf_cnt(rxpb_qovf_cnt));
  wire ic_rej_fire = ic_rej && ic_fire;
  wire rm_frame_done;
  wire [7:0] rm_done_vl;
  // DROP_CNT_K 登记 FLT 层原因（unconf 含 NET/VLID 不一致，lmax 单列）、IC
  // 拒绝（0x48）与 RM 重复副本（0x4C）；DROP_CNT 合计含全部。mac_rx_if 的
  // CRC/长度类拒绝仍由其内部计数。计数按握手拍（各级可能被反压保持多拍）。
  always @(posedge clk) begin
    if (rst_sync) begin
      flt_unconf_cnt <= 32'd0; flt_lmax_cnt <= 32'd0; flt_drop_total <= 32'd0;
      ic_drop_cnt <= 32'd0; ic_accept_cnt <= 32'd0;
      rm_dup_cnt <= 32'd0; rm_fwd_cnt <= 32'd0; rm_skew_cnt <= 32'd0;
    end else begin
      if (flt_free) begin
        if (flt_out_reason == 3'd3) flt_lmax_cnt <= flt_lmax_cnt + 32'd1;
        else flt_unconf_cnt <= flt_unconf_cnt + 32'd1;
      end
      // RM 重复 / IC 拒绝 / FLT 拒绝按拍互斥（free 口仲裁），至多 +1；端口侧
      // （解析丢弃、队列满）另一路，同拍合计至多 +2。
      flt_drop_total <= flt_drop_total +
                        {31'd0,(flt_free || ic_rej_fire || rm_dup_fire)} +
                        {31'd0,pb_ev_drop};
      if (ic_rej_fire) ic_drop_cnt <= ic_drop_cnt + 32'd1;
      if (ic_to_rm && rm_in_ready) ic_accept_cnt <= ic_accept_cnt + 32'd1;
      if (rm_dup_fire) rm_dup_cnt <= rm_dup_cnt + 32'd1;
      if (rm_frame_done && (rm_done_vl < NUM_TX_VL))
        vl_tx_frame_cnt[rm_done_vl] <= vl_tx_frame_cnt[rm_done_vl] + 32'd1;
      if ((rm_fire && rm_out_fwd) && (rm_out_vl < NUM_TX_VL))
        vl_rx_accept_cnt[rm_out_vl] <= vl_rx_accept_cnt[rm_out_vl] + 32'd1;
      if (rm_dup_fire && (rm_out_vl < NUM_TX_VL))
        vl_drop_cnt[rm_out_vl] <= vl_drop_cnt[rm_out_vl] + 32'd1;
      if (rm_fire && rm_out_fwd) rm_fwd_cnt <= rm_fwd_cnt + 32'd1;
      if (rm_fire && rm_out_skew) rm_skew_cnt <= rm_skew_cnt + 32'd1;
    end
  end
  always @(posedge clk) begin
    if (rst_sync) begin rx_pipe_free <= 1'b0; rx_pipe_free_id <= 4'd0; end
    else begin
      rx_pipe_free <= rm_dup_fire || ic_rej_fire || flt_free || lookup_drain;
      if (rm_dup_fire) rx_pipe_free_id <= rm_out_desc[162:159];
      else if (ic_rej_fire) rx_pipe_free_id <= ic_out_desc[162:159];
      else if (flt_free) rx_pipe_free_id <= flt_out_desc[162:159];
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
  wire rm_frame_start;
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
  wire [7:0] rm_a_byte, rm_b_byte;
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

  // =====================================================================
  // continue4：全局统计页 stats_regs（0x0100~0x01FF）
  // 事件源都取既有流水的握手拍，不新增反压，也不改变任何数据通路。
  // 已知边界：dmac / ip_csum / udp_csum 三类在当前 RX 链路没有独立判决源，
  // 对应计数器恒 0；同拍两网同类丢弃按单拍脉冲合并记 1。
  // =====================================================================
  reg [12:0] tx_len_q;                      // 调度器给出的本帧载荷长度
  reg        ferr_a_d, ferr_b_d;
  always @(posedge clk) begin
    if (rst_sync) begin
      tx_len_q <= 13'd0; ferr_a_d <= 1'b0; ferr_b_d <= 1'b0;
    end else begin
      if (sch_start_vld) tx_len_q <= sch_start_len;
      ferr_a_d <= rx_frame_err_a;
      ferr_b_d <= rx_frame_err_b;
    end
  end
  wire ferr_a_p = rx_frame_err_a & ~ferr_a_d;
  wire ferr_b_p = rx_frame_err_b & ~ferr_b_d;
  // mac_rx_if drop_reason: 01 CRC, 02 IP, 04 UDP, 08 HDR, 10 LEN, 20 PAD, 40 NO_BLK, 80 ABORT
  wire ev_crc  = (ferr_a_p & rx_drop_reason_a[0]) | (ferr_b_p & rx_drop_reason_b[0]);
  wire ev_ipv  = (ferr_a_p & rx_drop_reason_a[1]) | (ferr_b_p & rx_drop_reason_b[1]);
  wire ev_udpl = (ferr_a_p & rx_drop_reason_a[2]) | (ferr_b_p & rx_drop_reason_b[2]);
  wire ev_etht = (ferr_a_p & rx_drop_reason_a[3]) | (ferr_b_p & rx_drop_reason_b[3]);
  wire ev_len  = (ferr_a_p & (rx_drop_reason_a[4] | rx_drop_reason_a[5])) |
                 (ferr_b_p & (rx_drop_reason_b[4] | rx_drop_reason_b[5]));
  wire [11:0] stats_drop_evt = { rm_dup_fire,                            // [11] rm
                                 ic_rej_fire,                           // [10] ic
                                 (flt_free && (flt_out_reason == 3'd3)), // [9]  lmax
                                 (flt_free && (flt_out_reason != 3'd3)), // [8]  unconf
                                 ev_crc,                                // [7]  crc
                                 1'b0,                                  // [6]  udp_csum 未接线
                                 ev_udpl,                               // [5]  udp_len
                                 1'b0,                                  // [4]  ip_csum  未接线
                                 ev_ipv,                                // [3]  ip_ver
                                 ev_etht,                               // [2]  ethtype
                                 1'b0,                                  // [1]  dmac     未接线
                                 ev_len };                              // [0]  len
  wire stats_page_rd = hs && !host_we && stats_hit;
  wire stats_page_wr = we && stats_hit;
  generate if (STATS_EN != 0) begin : g_stats
    stats_regs u_stats (
      .clk(clk), .rst_sync(rst_sync), .freeze(dbg_ctrl_r[6]),
      .rx_in_evt(lookup_take),  .rx_in_len(lookup_in_desc[158:148]),
      .rx_acc_evt(rm_fire && rm_out_fwd),
      .rx_acc_len(rm_out_desc[158:148]),
      .rx_acc_vl(rm_out_vl),
      .rx_acc_ts(rm_out_desc[147:124]),
      .tx_evt(rm_frame_done), .tx_len(tx_len_q),
      .drop_evt(stats_drop_evt),
      .pb_deliver_cnt(rxpb_deliver_cnt), .pb_port_drop_cnt(rxpb_port_drop_cnt),
      .pb_ovr_cnt(rxpb_ovr_cnt), .pb_qovf_cnt(rxpb_qovf_cnt),
      .host_rd(stats_page_rd), .host_wr(stats_page_wr),
      .host_off(host_addr[7:0]), .host_wdata(host_wdata),
      .host_rdata(stats_rdata), .wr_ok(stats_wr_ok),
      .snmp_off(stats_snmp_off), .snmp_rdata(stats_snmp_rdata),
      .jit_max_o(stats_jit_max), .drop_total_o(stats_drop_total));
  end else begin : g_nostats
    assign stats_rdata = 32'd0;
    assign stats_wr_ok = 1'b0;
    assign stats_snmp_rdata = 32'd0;
    assign stats_jit_max = 32'd0;
    assign stats_drop_total = 32'd0;
  end endgenerate

  // =====================================================================
  // continue4：管理面（SNMP / A615-A TFTP / RTC 同步）
  // SAP 载荷按 SAP 端口号路由：SNMP_SAP_PORT → snmp_lite，TFTP_SAP_PORT →
  // a615a_tftp。其余 SAP 端口保持 continue3 的"只登记、只归还"语义。
  // 覆盖边界：两个引擎的响应只做编码并经 MGMT 观测窗读出，没有接入 TX
  // 帧构建器（管理面回包不上线），这一点在 REPORT 里单独登记。
  // =====================================================================
  assign sap_pm_gnt = sap_pm_req && !host_pmem_rd && !fb_rd_en_a;
  wire [7:0] sap_port_q = mgmt_last_desc[22:15];
  wire sap_to_snmp = (SNMP_EN != 0) && ctl_r[8] && (sap_port_q == SNMP_SAP_PORT[7:0]);
  wire sap_to_tftp = (TFTP_EN != 0) && (sap_port_q == TFTP_SAP_PORT[7:0]);
  wire load_rd = hs && !host_we && load_hit && (TFTP_EN != 0);
  wire snmp_resp_ack = we && (host_addr == 16'hAC1C);
  wire tftp_resp_ack = we && (host_addr == 16'hAC28);

  always @(posedge clk) begin
    if (rst_sync) begin
      load_rd_d <= 1'b0; mgmt_bidx <= 8'd0;
      cs_div <= 14'd0; uptime_cs <= 32'd0;
      snmp_ctl_shadow <= CTL_RST[15:0];
    end else begin
      load_rd_d <= load_rd;
      if (we && (host_addr == 16'hAC1A)) mgmt_bidx <= host_wdata[7:0];
      else if (hs && !host_we && ((host_addr == 16'hAC1B) || (host_addr == 16'hAC27)))
        mgmt_bidx <= mgmt_bidx + 8'd1;
      if (tick_us) begin
        if (cs_div >= 14'd9999) begin cs_div <= 14'd0; uptime_cs <= uptime_cs + 32'd1; end
        else cs_div <= cs_div + 14'd1;
      end
      if (snmp_ctl_we) snmp_ctl_shadow <= snmp_ctl_wdata;
    end
  end

  generate if (SNMP_EN != 0) begin : g_snmp
    wire [3:0] s_err, s_idx, s_vb;
    wire [7:0] s_pdu;
    wire [15:0] s_peer;
    snmp_lite #(.NUM_TX_VL(NUM_TX_VL), .NUM_RX_VL(NUM_RX_VL), .MAX_VB(8)) u_snmp (
      .clk(clk), .rst_sync(rst_sync), .en(ctl_r[8]),
      .in_vld(sap_out_vld && sap_to_snmp), .in_sop(sap_out_sop),
      .in_eop(sap_out_eop), .in_data(sap_out_data), .in_sport(sap_out_sport),
      .in_ready(),
      .uptime_cs(uptime_cs), .ctl_val(snmp_ctl_shadow),
      .drop_total(stats_drop_total), .jit_max_us(stats_jit_max),
      .buf_util({26'd0, popcnt16(~rx_free_map)}),
      .stats_off(stats_snmp_off), .stats_data(stats_snmp_rdata),
      .ctl_we(snmp_ctl_we), .ctl_wdata(snmp_ctl_wdata),
      .vl_data(snmp_vl_data), .vl_bag_allowed(snmp_vl_bag_allowed),
      .vl_bag_we(snmp_vl_bag_we), .vl_bag_index(snmp_vl_bag_index),
      .vl_bag_wdata(snmp_vl_bag_wdata), .mib_group(snmp_mib_group),
      .mib_leaf(snmp_mib_leaf), .mib_index(snmp_mib_index),
      .resp_vld(snmp_resp_vld), .resp_len(snmp_resp_len),
      .resp_ack(snmp_resp_ack), .resp_rd_addr({3'd0, mgmt_bidx}),
      .resp_byte(snmp_resp_byte),
      .rx_pdu_cnt(snmp_cnt_rx), .resp_cnt(snmp_cnt_tx), .drop_pdu_cnt(snmp_cnt_drop),
      .last_err(s_err), .last_idx(s_idx), .last_pdu(s_pdu),
      .peer_port(s_peer), .vb_n(s_vb), .state_o());
    // [19:12]=PDU 类型 [11:8]=VarBind 数 [7:4]=error-index [3:0]=error-status
    assign snmp_st_w = {12'd0, s_pdu, s_vb, s_idx, s_err};
  end else begin : g_nosnmp
    assign snmp_resp_vld = 1'b0; assign snmp_resp_len = 11'd0;
    assign snmp_resp_byte = 8'd0; assign snmp_st_w = 32'd0;
    assign snmp_cnt_rx = 32'd0; assign snmp_cnt_tx = 32'd0; assign snmp_cnt_drop = 32'd0;
    assign snmp_ctl_we = 1'b0; assign snmp_ctl_wdata = 16'd0;
    assign snmp_vl_bag_we = 1'b0; assign snmp_vl_bag_index = 8'd0;
    assign snmp_vl_bag_wdata = 32'd0; assign snmp_mib_group = 8'd0;
    assign snmp_mib_leaf = 8'd0; assign snmp_mib_index = 8'd0;
    assign stats_snmp_off = 8'd0;
  end endgenerate

  generate if (TFTP_EN != 0) begin : g_tftp
    wire        t_ok;
    wire [15:0] t_err, t_tid, t_blk;
    wire [31:0] t_pkt, t_dup, t_ecnt, t_to;
    wire [7:0]  t_retry;
    wire [3:0]  t_st;
    a615a_tftp #(.LOAD_WORDS(8192), .RETRY_MAX(3), .TIMEOUT_US(TFTP_TIMEOUT_US)) u_tftp (
      .clk(clk), .rst_sync(rst_sync), .en(1'b1), .tick_us(tick_us),
      .in_vld(sap_out_vld && sap_to_tftp), .in_sop(sap_out_sop),
      .in_eop(sap_out_eop), .in_data(sap_out_data), .in_sport(sap_out_sport),
      .in_ready(),
      .resp_vld(tftp_resp_vld), .resp_len(tftp_resp_len),
      .resp_ack(tftp_resp_ack), .resp_rd_addr({3'd0, mgmt_bidx}),
      .resp_byte(tftp_resp_byte),
      .host_rd(load_rd), .host_addr(host_addr - 16'hCC20),
      .host_rdata(tftp_load_rdata),
      .loaded_ok(t_ok), .err_code(t_err), .tid(t_tid), .blk_expect(t_blk),
      .bytes_rcvd(tftp_bytes), .crc32_val(tftp_crc), .pkt_cnt(t_pkt),
      .dup_cnt(t_dup), .err_cnt(t_ecnt), .timeout_cnt(t_to), .retry_cnt(t_retry),
      .fname_head(tftp_fnh), .state_o(t_st));
    assign tftp_st_w = {t_ok, 3'd0, t_st, 8'd0, t_err};
    assign tftp_pkt  = t_pkt;
    assign tftp_de   = {t_dup[7:0], t_ecnt[7:0], t_tid};
    assign tftp_tr   = {t_blk, t_to[7:0], t_retry};
  end else begin : g_notftp
    assign tftp_resp_vld = 1'b0; assign tftp_resp_len = 11'd0;
    assign tftp_resp_byte = 8'd0; assign tftp_load_rdata = 32'd0;
    assign tftp_st_w = 32'd0; assign tftp_bytes = 32'd0; assign tftp_crc = 32'd0;
    assign tftp_pkt = 32'd0; assign tftp_de = 32'd0; assign tftp_tr = 32'd0;
    assign tftp_fnh = 32'd0;
  end endgenerate

  generate if (RTC_EN != 0) begin : g_rtc
    wire [31:0] r_err, r_jmp, r_stp, r_pps, r_ph;
    rtc_sync #(.US_PER_SEC(RTC_US_PER_SEC), .SYNC_TIMEOUT(RTC_SYNC_TO_US), .LOCK_N(3))
    u_rtc (
      .clk(clk), .rst_sync(rst_sync), .en(ctl_r[10]), .hold(ctl_r[11]),
      .tick_us(tick_us), .rtc_free_us(rtc64), .pps_in(pps_in),
      .sync_vld(1'b0), .sync_master_ts(64'd0),
      .path_est_us(16'd0), .th_jump_us(8'd100), .log2_avg(4'd2),
      .rtc_time_us(rtc_corrected), .pps_out(rtc_pps_pulse),
      .sync_loss(rtc_sloss), .locked(rtc_locked), .last_err_us(r_err),
      .jump_cnt(r_jmp), .step_cnt(r_stp), .pps_cnt(r_pps), .sec_phase(r_ph));
    assign rtc_st_w    = {29'd0, rtc_pps_pulse, rtc_sloss, rtc_locked};
    assign rtc_err_w   = r_err;   assign rtc_jump_w  = r_jmp;
    assign rtc_step_w  = r_stp;   assign rtc_pps_w   = r_pps;
    assign rtc_phase_w = r_ph;
  end else begin : g_nortc
    assign rtc_corrected = rtc64; assign rtc_pps_pulse = 1'b0;
    assign rtc_sloss = 1'b0; assign rtc_locked = 1'b0;
    assign rtc_st_w = 32'd0; assign rtc_err_w = 32'd0; assign rtc_jump_w = 32'd0;
    assign rtc_step_w = 32'd0; assign rtc_pps_w = 32'd0; assign rtc_phase_w = 32'd0;
  end endgenerate

  // TODO: RX 后级与管理面仍是桩；T22 全流程需补哈希映像校验/接收回环。
  // Q20 前门判决属于 T05c 单项，不替代 T05b 的满载抖动取证。
/* verilator lint_on UNUSED */

endmodule
