// =====================================================================
// AFDX_top.v —— AFDX 端系统顶层
// 设计书: §5.1（顶层端口总表）/ §4.2（复位）/ §4.3（参数表）/
//         §7.14 + 附录 A（寄存器页，doc/regs.yaml 为单一来源）/ §7.18（时基）
// 状态: 主机译码在本文件（host_if.v 空壳未例化）。TX/RX/IC/RM/管理面已接线。
//       70/70 是 2026-10-03 冻结包；此后面积改动未宣称全量仍绿。综合后整帧未验收。
//       芯片仿真缩配顶层为 AFDX_top_chipsim（参数覆盖，本模块默认满配不变）。
// 命名/握手: §10（信号小写下划线、参数大写下划线、vld/rdy 或 pulse）
// =====================================================================
`timescale 1 ns / 1 ps
/* verilator lint_off UNUSED */
module AFDX_top #(
  // ---- §4.3 参数表 ----
  parameter integer NUM_TX_VL     = 128,
  parameter integer NUM_RX_VL     = 4096,
  parameter integer NUM_PORTS     = 256,
  parameter integer PMEM_KB       = 32,
  parameter integer MAX_FRAME     = 1518,
  parameter integer CLK_FREQ_HZ   = 125_000_000,
  parameter integer BYTE_SLOT_CYC = 10,
  // 2 = PHY-facing GMII (final contest interface); 0/1 retain the
  // historical envelope/raw-MAC byte streams for regression compatibility.
  parameter integer IF_MODE       = 2,
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
  parameter integer HASH_BUCKETS  = 2048,   // 满配默认；芯片仿真包装另给缩配
  parameter integer LOAD_WORDS    = 8192,   // TFTP 加载区字数；TFTP_EN=0 时不例化
  // continue4：管理面 SAP 端口号→服务映射（按 SAP 端口路由，不动 UDP 端口基址）
  parameter integer SNMP_SAP_PORT = 6,
  parameter integer TFTP_SAP_PORT = 7,
  parameter integer RTC_US_PER_SEC = 1000000,
  parameter integer RTC_SYNC_TO_US = 2500000,   // 核查 20260928：仅 PPS 对时须 > RTC_US_PER_SEC（原 4000 每秒误判失步）
  parameter integer TFTP_TIMEOUT_US = 5000,
  // P05: 615A 主动取件引擎（默认启用；无作业时对既有路径透明）
  parameter integer A615A_EN        = 1,
  parameter integer A615A_MAX_RETRIES = 5,
  // 1 keeps the legacy single-block RX path; 5 enables 8192-byte app data.
  parameter integer RX_REASM_CHAIN_BLOCKS = 1,
  // Four-block TX message store and per-fragment scheduler grants (opt-in).
  parameter integer TX_MESSAGE_CHAIN_BLOCKS = 1,
  // Project endpoint identifier; override for the selected target identity.
  parameter [255:0] LUR_TFTP_FILENAME = {"TARGET.LUR",176'd0},
  parameter integer LUR_TFTP_FILENAME_LEN = 10
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
  output wire [3:0]  dbg_frame_event,
  input  wire        rx_error,
  input  wire        rx_error_b
);

  localparam integer RX_CHAIN_ENABLE = (RX_REASM_CHAIN_BLOCKS == 5);
  localparam integer TX_CHAIN_ENABLE = (TX_MESSAGE_CHAIN_BLOCKS == 4);

  // ---- 复位同步（§4.2）----
  wire rst_sync;
  rst_sync u_rstsync (.clk(clk), .reset(reset), .rst_sync(rst_sync));

  // ---- P05: 615A 取件引擎接口（声明必须先于使用；本工具链不接受隐式前向网）----
  wire        fe_busy, fe_done, fe_failed, fe_sap_ready, fe_start_ready;
  wire        fe_preload_start_ready, fe_preload_data_ready, fe_preload_error;
  wire [3:0]  fe_fcode;
  wire        fe_pkt_vld;
  wire [10:0] fe_pkt_len;
  wire [31:0] fe_pkt_dst_ip;
  wire [15:0] fe_pkt_src_port, fe_pkt_dst_port;
  wire [7:0]  fe_pkt_byte;
  wire        fe_file_valid, fe_file_busy, fe_rd_valid;
  wire [13:0] fe_file_len;
  wire [1:0]  fe_file_err;
  wire [7:0]  fe_rd_data;
  wire [31:0] fe_rx_bytes, fe_ok_cnt, fe_drop_cnt;
  wire        fe_sap_route;
  wire        fe_rd_en;
  reg  [31:0] fetch_ip;
  reg  [15:0] fetch_tid, fetch_ticks;
  reg  [255:0] fetch_fn;
  reg  [7:0]  fetch_fnlen;
  reg         fetch_start_p, fetch_abort_p, fetch_ack_p, fetch_up_mode;
  reg         fetch_preload_start_p, fetch_preload_data_valid_p;
  reg         fetch_preload_commit_p, fetch_preload_abort_p;
  reg  [7:0]  fetch_preload_data_r;
  reg  [13:0] fetch_preload_length_r;
  // Explicit nine-byte initialization source. It publishes into the existing
  // host-owned upload buffer; AC40 still chooses the peer/name and starts WRQ.
  reg [31:0] init_file_fields;
  reg init_file_start_p, init_file_abort_p;
  reg [2:0] init_file_state;
  reg [3:0] init_file_index;
  reg init_file_done, init_file_error;
  wire init_file_valid;
  wire [7:0] init_file_byte;
  wire init_file_busy = (init_file_state != 0) || init_file_start_p;
  wire init_file_cancel;
  wire init_file_ready;
  wire init_preload_start, init_preload_data, init_preload_commit;
  wire init_preload_abort;
  reg  [12:0] fe_rd_addr;
  assign fe_rd_en = (A615A_EN != 0) && fe_file_valid;

  // ---- P05: 615A LUR（清单上传 + 逐文件编排）接口 ----
  // AC87[1] selects complete TFTP WRQ control reception; bit1=0 retains
  // the legacy raw-SAP parser input for compatibility tests.
  wire        lur_up_vld, lur_up_rdy, lur_up_sop, lur_up_eop;
  wire [7:0]  lur_up_byte;
  wire        lur_up_route;          // 本拍 SAP 字节归 LUR 上传通道
  reg         lur_upload_mode;       // 宿主置位：进入 LUR 上传接收态
  reg         lur_tftp_mode, lur_transport_abort;
  wire        lur_control_valid, lur_control_busy, lur_control_ack;
  wire        lur_control_rd;
  wire [12:0] lur_control_addr;
  reg [2:0]   lur_pump_state;
  reg [13:0]  lur_pump_index, lur_pump_length;
  reg [31:0]  lur_pump_word;
  reg         lur_transport_length_error;
  wire        lur_raw_route;
  wire        lur_transport_lost = (lur_pump_state!=0) && !lur_control_valid;
  wire        lur_result_vld;
  reg         lur_result_ack;
  wire        lur_ok;
  wire [3:0]  lur_err;
  wire [15:0] lur_file_count;
  reg  [2:0]  lur_name_sel;
  wire [7:0]  lur_name_len_w, lur_part_len_w;
  wire [7:0]  lur_name_byte;
  wire        lur_name_byte_vld;
  // lur_rx 的名字读口为「单口」：编排器在搬运期间独占（lur_name_read/index），
  // 宿主观测在编排器空闲时借用（lur_host_read/index）。二者按 lur_busy 互斥。
  // 0xAC8B 写 1 只产生 lur_host_read 的「一拍脉冲」，而 lur_rx 的 name_byte 是
  // 寄存输出（name_byte_valid <= query_valid），故须把该脉冲展宽，等待寄存输出
  // 对齐后再一次采样进 lur_host_byte_r 供 0xAC89 读回。
  reg  [1:0]     lur_host_rd_pipe;
  reg  [7:0]     lur_host_byte_r;
  wire [2:0]  lur_file_select_w;
  wire        lur_name_read;
  wire [7:0]  lur_name_index;
  reg  [7:0]  lur_host_index;
  // lur_host_read 在下方 lur_hit 声明之后驱动（需引用 we/lur_hit）。
  wire        lur_host_read;

  // 编排器 ↔ 取件引擎 的作业通道
  wire        lur_busy, lur_done, lur_failed;
  wire [3:0]  lur_fcode;
  wire [2:0]  lur_cur;
  wire [15:0] lur_ok_cnt, lur_fail_cnt;
  wire [31:0] lur_bytes;
  wire        lur_job_start, lur_job_rdy, lur_job_abort, lur_job_up;
  wire [31:0] lur_job_ip;
  wire [15:0] lur_job_tid, lur_job_ticks;
  wire [2047:0] lur_job_fn;
  wire [7:0]  lur_job_fnlen;
  wire        lur_active;            // 编排器持有取件引擎所有权
  wire        lur_up_busy;
  wire        lur_file_ack_w;
  wire        lur_orch_ack;          // 编排器的 file_ack 输出（消费完成）
  reg         lur_auto_ack;
  reg         lur_hold_files;
  wire        lur_wait_file_ack;
  reg         lur_start_p, lur_abort_p, lur_skip_p;
  reg         lur_up_mode;

  wire        lur_name_read_mux  = lur_busy ? lur_name_read  : lur_host_read;
  wire [7:0]  lur_name_index_mux = lur_busy ? lur_name_index : lur_host_index;
  // 条目选择同理：编排器运行期间由 lur_file_select 驱动（逐文件递增），
  // 空闲时回到宿主 0xAC88 写入的 lur_name_sel。
  wire [2:0]  lur_sel_mux = lur_busy ? lur_file_select_w : lur_name_sel;

  // 取件引擎参数源：LUR 编排取件时由编排器驱动，否则由宿主寄存器驱动。
  wire [31:0] fe_src_ip    = lur_active ? lur_job_ip    : fetch_ip;
  wire [15:0] fe_src_tid   = lur_active ? lur_job_tid   : fetch_tid;
  wire [15:0] fe_src_ticks = lur_active ? lur_job_ticks : fetch_ticks;
  wire [2047:0] fe_src_fn  = lur_active ? lur_job_fn    : {fetch_fn, 1792'd0};
  wire [7:0]  fe_src_fnlen = lur_active ? lur_job_fnlen : fetch_fnlen;
  wire        fe_src_start = !init_file_busy && (lur_active ? lur_job_start : fetch_start_p);
  // A terminal transition relinquishes ownership on the same edge as its
  // registered abort pulse. Route that final pulse independently of busy.
  wire        fe_src_abort = lur_job_abort || (!lur_active && fetch_abort_p);
  // When the host starts and selects WRQ in one AC40 write, evaluate
  // start_ready against that requested direction before accepting the write.
  // The registered mode then remains stable when the one-cycle start pulse
  // reaches the engine on the following cycle.
  wire        fe_src_write = lur_active ? lur_job_up :
                             ((host_cs && host_we && (host_addr == 16'hAC40)) ?
                              host_wdata[2] : fetch_up_mode);
  // file_ack 源：LUR 编排期间由编排器消费确认；否则由宿主 0xAC4D 驱动。
  // An abort may drop lur_busy on the edge that raises its final release
  // pulse. Keep that pulse routed even after the orchestrator relinquishes ownership.
  wire        fe_file_ack_src = lur_orch_ack || (!lur_active && fetch_ack_p) ||
                                (init_file_busy && init_file_cancel && fe_file_valid);

  wire [7:0] rx_mac_data_a, rx_mac_data_b;
  wire rx_mac_valid_a, rx_mac_valid_b, rx_mac_error_a, rx_mac_error_b;
  generate if (IF_MODE == 2) begin : g_phy_gmii
    gmii_rx_strip u_strip_a (
      .clk(clk), .rst_sync(rst_sync), .rx_data(rx_data),
      .rx_valid(rx_valid), .rx_error(rx_error),
      .frame_data(rx_mac_data_a), .frame_valid(rx_mac_valid_a),
      .frame_error(rx_mac_error_a), .preamble_drop_count());
    gmii_rx_strip u_strip_b (
      .clk(clk), .rst_sync(rst_sync), .rx_data(rx_data_b),
      .rx_valid(rx_valid_b), .rx_error(rx_error_b),
      .frame_data(rx_mac_data_b), .frame_valid(rx_mac_valid_b),
      .frame_error(rx_mac_error_b), .preamble_drop_count());
  end else begin : g_legacy_mac_stream
    assign rx_mac_data_a = rx_data; assign rx_mac_valid_a = rx_valid;
    assign rx_mac_data_b = rx_data_b; assign rx_mac_valid_b = rx_valid_b;
    assign rx_mac_error_a = 1'b0; assign rx_mac_error_b = 1'b0;
  end endgenerate

  // 初始化顺序扫描：每个 strobe 真正写到对应状态/valid 存储体；末笔后排空一拍。
  wire        init_we, init_done;
  wire [2:0]  init_target;
  wire [12:0] init_addr;
  init_sweep #(.NUM_RX_VL(NUM_RX_VL), .NUM_TX_VL(NUM_TX_VL), .NUM_PORTS(NUM_PORTS),
               .HASH_BUCKETS(HASH_BUCKETS)) u_init (
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
  localparam integer TXA = (NUM_TX_VL <= 2) ? 1 : clog2_f(NUM_TX_VL);
  localparam integer PA  = (NUM_PORTS <= 2) ? 1 : clog2_f(NUM_PORTS);
  // TX/PORT 配置表改为 BRAM 副本（OPT-12）：热路径用影子寄存器，禁止 640:1/1024:1 组合读。
  // §8.2/O-27: 与 TX w0~w4 分离的 Q20 份额表，0x0480+VL；数据 BRAM 不整片复位。
  // loaded 位复用 init_sweep 的 TXCFG 扫描清零，扫描写拍数仍为 25_344。
  reg [20:0] cfg_share_mem [0:NUM_TX_VL-1];
  reg [NUM_TX_VL-1:0] cfg_share_loaded;
  reg [27:0] cfg_sum_r;       // 128 × (2^21-1) < 2^28
  reg [7:0] cfg_missing_cnt; // 已启用 w0 且缺失/零份额的 VL 数，最大 128
  localparam [27:0] Q20_LIMIT = 28'd1048576;
  wire cfg_over = (cfg_sum_r > Q20_LIMIT);
  wire cfg_missing = (cfg_missing_cnt != 8'd0);
  // continue11 时序：影子寄存器，写条件/优先级与 TX/PORT 配置表完全一致，
  // 取代原先对 FF 大表的宽组合读（POST-FIT-FINDINGS 根因 B：1024:1 / 640:1 读 mux）。
  //   tx_w0_en[vl]     = tx_cfg_mem[vl*5][31]
  //   port_w0_sh[p]    = {port_cfg_mem[p*4][31], [18], [17:16]}
  //   port_w3_dep[p]   = port_cfg_mem[p*4+3][3:0]
  reg [NUM_TX_VL-1:0] tx_w0_en;
  reg [7:0]           tx_w1_lo    [0:NUM_TX_VL-1];
  reg [3:0]           port_w0_sh  [0:NUM_PORTS-1];
  reg [15:0]          port_w1_dport [0:NUM_PORTS-1];
  reg [3:0]           port_w3_dep [0:NUM_PORTS-1];
  reg [31:0] vl_stat_mem  [0:NUM_TX_VL-1];
  reg [31:0] vl_tx_frame_cnt [0:NUM_TX_VL-1];
  reg [31:0] vl_rx_accept_cnt[0:NUM_TX_VL-1];
  reg [31:0] vl_drop_cnt     [0:NUM_TX_VL-1];

  // RX 描述符（v0.5.16 起 174 bit）：{plen[10:0], blk, len, ts, vlid, sn, net,
  // ifid, src, dst, sport, dport}；低 163 bit 布局与 rx_ic 单元测试一致。
  // P08（2026-10-11）：新增 [207:174] 分片元数据区，高位放置以保持既有位索引
  // 全部不变。布局：[207:192]=ident [191]=mf [190]=df [189:177]=frag_off(8B 单位)
  // [176]=is_frag [175]=first_frag [174]=保留。
  localparam integer RXD_BASE_W = 174;
  localparam integer RXD_W = 208;
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
  wire [31:0] flt_out_w0;
  wire flt_out_ready;
  reg  [31:0] ic_hold_w0, rm_hold_w0;
  reg  [31:0] flt_unconf_cnt, flt_lmax_cnt, flt_drop_total;
  wire ic_in_vld, ic_in_ready, ic_out_vld, ic_out_accept;
  wire [2:0] ic_out_reason;
  wire [11:0] ic_out_vl;
  wire [RXD_W-1:0] ic_out_desc;
  reg  [31:0] ic_drop_cnt, ic_accept_cnt;
  wire rm_in_vld, rm_in_ready, rm_out_vld, rm_out_fwd, rm_out_skew;
  // P08：IPv4 分片重组级（rx_rm forward → 重组 → 解析）外部连线与状态。
  // 提前声明以便下方 mgmt2 观测窗（0xAC2A~0xAC2F）引用。
  wire             reasm_en;
  wire             reasm_in_vld, reasm_in_ready;
  wire [RXD_W-1:0] reasm_out_desc;
  wire [11:0]      reasm_out_vl;
  wire             reasm_out_vld, reasm_out_drop;
  wire             reasm_draining;
  wire [3:0]       reasm_out_reason;
  wire [31:0]      reasm_hit_cnt, reasm_drop_cnt, reasm_slot_used;
  wire             reasm_copy_valid, reasm_copy_ready, reasm_copy_done;
  wire [3:0]       reasm_copy_src_blk, reasm_copy_dst_blk;
  wire [12:0]      reasm_copy_src_byte, reasm_copy_dst_byte;
  wire [13:0]      reasm_copy_len;
  wire             reasm_free_valid;
  wire [3:0]       reasm_free_id;
  wire             copy_rd_req, copy_rd_grant, copy_rd_valid;
  wire [12:0]      copy_rd_addr;
  wire             copy_wr_valid, copy_wr_grant;
  wire [12:0]      copy_wr_addr;
  wire [31:0]      copy_wr_data;
  wire [3:0]       copy_wr_be;
  reg              copy_rd_valid_q;
  wire             reasm_check_valid, reasm_check_ready, reasm_check_done;
  wire             reasm_check_good;
  wire [1:0]       reasm_check_reason;
  wire [3:0]       reasm_check_blk;
  wire [13:0]      reasm_check_app_len;
  wire [31:0]      reasm_check_src_ip, reasm_check_dst_ip;
  wire [13:0] reasm_out_app_len, chain_out_app_len;
  wire [19:0] reasm_out_blocks, chain_out_blocks, reasm_copy_dst_blocks, reasm_check_blocks;
  wire [2:0] reasm_out_block_count, chain_out_block_count, reasm_copy_dst_count, reasm_check_block_count;
  wire [13:0] chain_copy_dst_byte;
  wire [10:0] chain_copy_src_byte;
  wire reasm_chain_alloc, reasm_chain_valid;
  wire [19:0] reasm_chain_alloc_blocks;
  wire [2:0] reasm_chain_alloc_count;
  wire [15:0] rx_chain_free_mask;
  wire [31:0] rx_chain_lookup_word;
  wire [RXD_W-1:0] legacy_reasm_desc, chain_reasm_desc;
  wire [11:0] legacy_reasm_vl, chain_reasm_vl;
  wire legacy_reasm_vld, legacy_reasm_drop, legacy_reasm_drain;
  wire chain_reasm_vld, chain_reasm_drop, chain_reasm_drain;
  wire [3:0] legacy_reasm_reason, chain_reasm_reason;
  wire legacy_reasm_ready, chain_reasm_ready;
  wire legacy_copy_valid, chain_copy_valid, legacy_check_valid, chain_check_valid;
  wire [3:0] legacy_copy_src, legacy_copy_dst, chain_copy_src, legacy_check_blk, chain_check_blk;
  wire [12:0] legacy_copy_src_byte, legacy_copy_dst_byte;
  wire [13:0] legacy_copy_len, chain_copy_len, legacy_check_len, chain_check_len;
  wire [31:0] legacy_check_src, legacy_check_dst, chain_check_src, chain_check_dst;
  wire legacy_free_valid, chain_free_valid;
  wire [3:0] legacy_free_id, chain_free_id;
  wire [31:0] legacy_hit_cnt, legacy_drop_cnt, legacy_slot_used;
  wire [31:0] chain_hit_cnt, chain_drop_cnt, chain_slot_used;
  wire legacy_copy_done, chain_copy_done, chain_copy_error;
  wire legacy_copy_rd_req, chain_copy_rd_req, legacy_copy_wr_valid, chain_copy_wr_valid;
  wire [12:0] legacy_copy_rd_addr, chain_copy_rd_addr, legacy_copy_wr_addr, chain_copy_wr_addr;
  wire [31:0] legacy_copy_wr_data, chain_copy_wr_data;
  wire [3:0] legacy_copy_wr_be, chain_copy_wr_be;
  wire legacy_copy_ready, chain_copy_ready;
  wire             check_rd_req, check_rd_grant;
  wire [12:0]      check_rd_addr;
  reg              check_rd_valid_q;
  reg [31:0]       reasm_hold_w0;
  reg [2:0]        aux_rd_wait, copy_wr_wait;
  wire             aux_rd_req = copy_rd_req || check_rd_req;
  wire             aux_rd_turn = aux_rd_req && (aux_rd_wait == 3'd7);
  wire             copy_wr_turn = copy_wr_valid && (copy_wr_wait == 3'd7);
  wire [RXD_W-1:0] rm_in_desc, rm_out_desc;
  wire [11:0] rm_in_vl, rm_out_vl;
  reg  [31:0] rm_dup_cnt, rm_fwd_cnt, rm_skew_cnt;
  wire rm_out_ready, rm_fire, rm_dup_fire;
  wire prs_in_ready, prs_out_vld, prs_out_drop;
  wire [RXD_W-1:0] prs_in_desc_sel;
  wire [13:0] prs_in_app_len;
  wire [19:0] prs_in_blocks;
  wire [2:0] prs_in_block_count;
  wire prs_in_vld_sel;
  // continue2：RX_VL_CFG BRAM 化后主机读直出（见 u_rxcfg_h*）
  wire host_rxc_wait, host_txc_wait, host_pcc_wait;
  wire sch_start_cfg_rd;
  reg  rxc_rd_d, rxc_sel_d, txc_rd_d, pcc_rd_d;
  reg  [2:0] txc_ws_d;
  reg        txc_vld_d;
  reg  [1:0] pcc_ws_d;
  reg        pcc_vld_d;
  wire [31:0] rxc_host_rdata, txc_host_rdata, pcc_host_rdata;
  wire [31:0] rxq_host_w0, rxq_host_w1;
  wire [31:0] txq_h0, txq_h1, txq_h2, txq_h3, txq_h4;
  wire [31:0] txq_b0, txq_b1, txq_b2, txq_b3, txq_b4;
  wire [31:0] txq_bag, txq_bag_s, txq_port_w;
  wire [31:0] pcq_h0, pcq_h1, pcq_h2, pcq_h3;
  wire [2:0] prs_out_reason;
  wire [7:0] prs_out_port;
  wire [1:0] prs_out_type;
  wire [3:0] prs_out_depth, prs_out_blk;
  wire [10:0] prs_out_plen;
  wire [13:0] prs_out_app_len;
  wire [19:0] prs_out_blocks;
  wire [2:0] prs_out_block_count;
  wire [23:0] prs_out_ts;
  wire pb_in_ready, pb_free0, pb_free1, pb_ev_drop, pb_ev_sample, pb_ev_queue, pb_ev_ovf;
  // SAP bypasses rx_port_buf only after its normal P2 validation. The
  // descriptor handoff owns its block until it requests an arbitrated return.
  wire prs_to_sap, prs_to_port, sap_in_ready, sap_core_in_ready, sap_engine_ready;
  wire sap_engine_vld;
  wire mgmt_free_req, mgmt_free_take;
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
  wire [15:0] tx_open_blocks,tx_open_mask;
  wire [2:0] tx_open_count;
  wire [13:0] tx_open_length;
  wire tx_reserved,tx_reserve_ready,tx_reserve_reject;
  reg tx_reserve_reject_sticky;
  wire tx_reserve_command,tx_cancel_command;
  wire tx_fragment_done,tx_fragment_error,tx_fragment_last;
  wire [15:0] tx_bad_completion_count,tx_failed_message_count;
  wire [3:0] tx_fragment_head;
  wire [13:0] tx_fragment_next;
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
  wire [15:0] snmp_peer_port;   // §7.1.1/§7.16：最近合法请求的源端口，响应反转用
  wire        snmp_in_ready;
  wire        snmp_ctl_we;
  wire        snmp_set_active, snmp_set_ack, snmp_bag_commit;
  wire        host_snmp_wait;
  wire [15:0] snmp_ctl_wdata;
  wire [7:0]  snmp_mib_group, snmp_mib_leaf, snmp_mib_index;
  wire [31:0] snmp_vl_data;
  wire        snmp_vl_bag_allowed, snmp_vl_bag_we;
  wire [7:0]  snmp_vl_bag_index;
  wire [31:0] snmp_vl_bag_wdata;
  wire [31:0] tftp_st_w, tftp_bytes, tftp_crc, tftp_pkt, tftp_de, tftp_tr, tftp_fnh;
  wire [15:0] tftp_resp_tid;    // 当前响应目的 TID；ERROR(5) 回到触发该错误的请求端口
  wire [31:0] tftp_resp_peer_ip;
  wire [10:0] tftp_resp_len;
  wire        tftp_resp_vld;
  wire [7:0]  tftp_resp_byte;
  wire        tftp_resp_byte_sync;
  wire        tftp_in_ready;
  wire [31:0] tftp_load_rdata;
  wire [31:0] rtc_st_w, rtc_err_w, rtc_jump_w, rtc_step_w, rtc_pps_w, rtc_phase_w;
  wire [63:0] rtc_corrected;
  wire        rtc_pps_pulse, rtc_locked, rtc_sloss;
  reg         load_rd_d;
  wire [31:0] stats_jit_max, stats_drop_total;
  reg  [15:0] snmp_ctl_shadow;
  reg  [10:0] mgmt_bidx;          // step3：11 位，覆盖 516 B 的 TFTP DATA 响应（原 8 位只到 255）
  reg  [2:0]  mt_state;           // 提前声明，供主机写请求与管理面互斥
  reg         host_tx_build_lock; // 主机写开放块至 MSG_WR 之间，管理面不得占用同一块
  reg  [31:0] uptime_cs;
  reg  [13:0] cs_div;
  reg host_pmem_pending;
  reg [12:0] host_pmem_pending_addr;
  reg [31:0] host_pmem_pending_data;
  wire host_pmem_req, rx_pmem_busy, host_commit_now, host_commit_pending;
  wire msg_commit;
  wire host_mgmt_write_req = host_cs && host_we &&
      ((host_addr >= 16'h8280 && host_addr <= 16'h837F) ||
       ((host_addr >= 16'h8800) &&
        ((host_addr - 16'h8800) < (PMEM_KB*256))));
  wire host_mgmt_write_stall = (mt_state != 3'd0) && host_mgmt_write_req;
  // AC55/AC56/AC57 preload writes are accepted only when the shared file
  // buffer can consume them. A standalone fetch start is blocked while LUR
  // owns the engine or the selected RRQ/WRQ source is not ready.
  wire host_fetch_start_stall = host_cs && host_we && (host_addr == 16'hAC40) &&
                                host_wdata[0] &&
                                ((A615A_EN == 0) || !ctl_r[9] || lur_active || init_file_busy || !fe_start_ready);
  wire host_preload_start_stall = host_cs && host_we && (host_addr == 16'hAC57) &&
                                  host_wdata[0] &&
                                  ((A615A_EN == 0) || !ctl_r[9] || !fe_preload_start_ready);
  wire host_preload_data_stall = host_cs && host_we && (host_addr == 16'hAC55) &&
                                 ((A615A_EN == 0) || !ctl_r[9] || !fe_preload_data_ready);
  wire host_preload_commit_stall = host_cs && host_we && (host_addr == 16'hAC56) &&
                                   ((A615A_EN == 0) || !ctl_r[9] || !fe_preload_data_ready);
  wire host_init_start_stall = host_cs && host_we && (host_addr == 16'hAC58) &&
                               host_wdata[0] && !host_wdata[1] && !init_file_ready;
  wire host_init_owner_stall = host_cs && host_we && init_file_busy &&
      ((host_addr >= 16'hAC55 && host_addr <= 16'hAC57) ||
       ((host_addr == 16'hAC4D) && host_wdata[0]) ||
       ((host_addr == 16'hAC80) && host_wdata[0]));
  wire host_fetch_stall = host_fetch_start_stall || host_preload_start_stall ||
                          host_preload_data_stall || host_preload_commit_stall ||
                          host_init_start_stall || host_init_owner_stall;
  // 无竞争时单拍流水不变。若运行期 RX 抢占单写口，锁住 1 笔主机
  // PMEM 请求直到实际落 RAM 再 ACK；争用时主机须保持至 ACK，不流水投递。
  wire hs = host_cs & ~rst_sync & ~host_pmem_pending & ~host_snmp_wait &
            ~host_mgmt_write_stall & ~host_fetch_stall;
  wire we = hs & host_we;
  always @(posedge clk) begin
    if (rst_sync) begin
      ack_r <= 1'b0; pmem_rd_d <= 1'b0; desc_rd_d <= 1'b0; hash_rd_d <= 1'b0;
      desc_rx_d <= 1'b0;
    end
    else begin
      // 运行期 RX 块读与 builder 抢读口 A 时不 ACK，主机保持请求到 ACK（重试）。
      ack_r <= (hs && (!host_pmem_req || host_commit_now) && !host_rx_rd_wait &&
                !host_rxc_wait && !host_txc_wait && !host_pcc_wait) ||
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
                      txc_rd_d  ? txc_host_rdata :
                      pcc_rd_d  ? pcc_host_rdata :
                      load_rd_d ? tftp_load_rdata :
                      hash_rd_d ? hash_cfg_rdata :
                       pmem_rd_d ? pmem_data_a :
                      desc_rd_d ? (desc_rx_d ? rdata_r : TX_CHAIN_ENABLE ? pb_desc_rd_data :
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
  wire hash_hit = (host_addr >= 16'h3D80) &&
                ((host_addr - 16'h3D80) < (4*HASH_BUCKETS));
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
  // P05: 615A 取件寄存器窗 0xAC40~0xAC7F
  wire fetch_hit = (host_addr >= 16'hAC40 && host_addr <= 16'hAC7F);
  // P05: 615A LUR（清单上传 + 逐文件编排取件）宿主窗 0xAC80~0xACBF
  //   独立窗口，避免与 fetch 语义混淆（见 P05_LUR接入方案_20261010.md §2.4）。
  wire lur_hit   = (host_addr >= 16'hAC80 && host_addr <= 16'hACBF);
  // 宿主 LUR 名字观测读时序（0xAC8B → 0xAC89）：
  // 写 0xAC8B=1 产生一拍组合请求 lur_host_rd_req（本拍即送入 lur_rx）；
  // lur_rx 的 name_byte 为寄存输出（name_byte_valid <= query_valid，
  // 见 a615a_lur_rx.v:88-91），需再等 1 拍寄存输出才对齐，故：
  //   - lur_host_read 展宽 2 拍（本拍 + 下拍），保证 lur_rx 持续看到有效请求；
  //   - lur_host_rd_capt（下一拍）锁存对齐后的 name_byte 进 lur_host_byte_r，
  //     宿主任意时刻读 0xAC89 都拿到本次请求的字节。
  wire        lur_host_rd_req  = we && lur_hit && (host_addr[5:0] == 6'h0B);
  wire        lur_host_rd_capt = lur_host_rd_pipe[0];
  assign lur_host_read = lur_host_rd_pipe[0] | lur_host_rd_pipe[1] | lur_host_rd_req;
  always @(posedge clk) begin
    if (rst_sync) begin
      lur_host_rd_pipe <= 2'd0;
      lur_host_byte_r  <= 8'd0;
    end else begin
      lur_host_rd_pipe <= {lur_host_rd_pipe[0], lur_host_rd_req};
      if (lur_host_rd_capt) lur_host_byte_r <= lur_name_byte;
    end
  end
  // continue4：A615-A 加载区自 0xCC20 起 LOAD_WORDS 字（满配 8192 = 32 KB）
  wire load_hit  = (host_addr >= 16'hCC20) &&
                   ((host_addr - 16'hCC20) < LOAD_WORDS);
  // load_hit 已保证偏移小于 LOAD_WORDS（满配 8192 字）；先保留 16 位减法，
  // 再显式取 13 位传给 TFTP RAM 地址口，避免子模块连接处隐式缩窄。
  wire [15:0] tftp_load_offset = host_addr - 16'hCC20;
  wire [12:0] tftp_host_word_addr = tftp_load_offset[12:0];
  wire pmem_hit = (host_addr >= 16'h8800) &&
                  ((host_addr - 16'h8800) < (PMEM_KB*256));
  wire msg_wr_hit = (host_addr >= 16'h8280 && host_addr <= 16'h837F);
  // v0.5.16 RX 端口主机操作：PORT_DESC 0x8180+p（RX 端口读即清 fresh/ovf）、
  // MSG_RD 0x8380+p（写：释放）、MSG_CNT 0x8480+p（读：消息数）。三段低 8 位
  // 同为 0x80 起，端口号统一为 host_addr[7:0]-0x80。端口表 w0[18]=1 为 RX 端口。
  wire msg_rd_hit  = (host_addr >= 16'h8380 && host_addr <= 16'h847F);
  wire msg_cnt_hit = (host_addr >= 16'h8480 && host_addr <= 16'h857F);
  wire rx_chain_hit = RX_CHAIN_ENABLE && (host_addr >= 16'h8580 && host_addr <= 16'h858F);
  wire tx_chain_hit = TX_CHAIN_ENABLE && (host_addr >= 16'h8590 && host_addr <= 16'h8594);
  wire [7:0]  hop_port = host_addr[7:0] - 8'h80;
  wire [3:0]  hop_sh = port_w0_sh[hop_port];
  wire [31:0] hop_w0 = {hop_sh[3], 12'd0, hop_sh[2], hop_sh[1:0], 16'd0};  // 仅 [31]/[18]/[17:16] 有消费者
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
  wire tx_cfg_valid = tx_w0_en[tx_idx / 10'd5];
  wire snmp_vl_valid = (snmp_mib_index < NUM_TX_VL);
  wire [9:0] snmp_vl_base = {2'd0,snmp_mib_index} * 10'd5;
  assign snmp_vl_bag_allowed = snmp_vl_valid && (snmp_mib_leaf == 8'd5);
  // BAG GET：地址先寄存，避免 combo index 把 128×32 落成 LUT。
  reg [TXA-1:0] snmp_bag_raddr;
  always @(posedge clk) snmp_bag_raddr <= snmp_mib_index[TXA-1:0];
  assign snmp_vl_data = !snmp_vl_valid ? 32'd0 :
                        (snmp_mib_leaf == 8'd5) ? {8'd0,txq_bag[31:8]} :
                        (snmp_mib_leaf == 8'd6) ? vl_tx_frame_cnt[snmp_mib_index] :
                        (snmp_mib_leaf == 8'd7) ? vl_rx_accept_cnt[snmp_mib_index] :
                        (snmp_mib_leaf == 8'd8) ? vl_drop_cnt[snmp_mib_index] :
                        (snmp_mib_leaf == 8'd9) ? vl_stat_mem[snmp_mib_index] : 32'd0;
  // ---- RX_VL_CFG 存储（continue2：w0/w1 分表 BRAM 副本，写口全部同源）----
  // 流水线读口只要 FLT 的 w0/w1（RD_NEG）。RM/解析不再各镜像一份 4096×32：
  // FLT 把 w0 锁进 out_w0，顶层随 IC/RM 一深在途寄存器下传（与「数据一份、
  // 描述符随帧走」同一纪律）。主机读口仍独立 posedge 副本。
  wire rxc_init_we = init_we && (init_target == 3'd3);
  wire rxc_host_we = cfg_write && rx_hit;
  wire rxc_w0_we = rxc_init_we || (rxc_host_we && !rx_idx[0]);
  wire rxc_w1_we = !rxc_init_we && rxc_host_we && rx_idx[0];
  wire [RXA-1:0] rxc_waddr = rxc_init_we ? init_addr[RXA-1:0] : rx_idx[RXA:1];
  wire [31:0] rxc_wdata = rxc_init_we ? 32'd0 : host_wdata;
  wire rxc_any_we = rxc_w0_we || rxc_w1_we;
  wire [RXA-1:0] rxa_flt  = lookup_out_vl[RXA-1:0];
  wire [RXA-1:0] rxa_host = rx_idx[RXA:1];
  wire [31:0] rxq_flt_w0, rxq_flt_w1;
  bram_1w1r #(.W(32), .D(NUM_RX_VL), .RD_NEG(1)) u_rxcfg_flt0 (
    .clk(clk), .wr_en(rxc_w0_we), .wr_addr(rxc_waddr), .wr_data(rxc_wdata),
    .rd_addr(rxa_flt), .rd_data(rxq_flt_w0));
  bram_1w1r #(.W(32), .D(NUM_RX_VL), .RD_NEG(1)) u_rxcfg_flt1 (
    .clk(clk), .wr_en(rxc_w1_we), .wr_addr(rxc_waddr), .wr_data(rxc_wdata),
    .rd_addr(rxa_flt), .rd_data(rxq_flt_w1));
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
  wire port_cfg_valid = port_w0_sh[port_idx[9:2]][3];
  // A validated SNMP SET owns TX configuration until all writes acknowledge.
  // Unrelated host reads/operations remain available; held writes ACK once only.
  assign host_snmp_wait = snmp_set_active && host_we &&
                          (tx_hit || share_hit || (reg_page && reg_align && off == 8'h08));
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
  wire budget_old_en = tx_w0_en[budget_vl];
  wire budget_new_en = host_wdata[31];
  wire budget_share_ok = cfg_share_loaded[budget_vl] &&
                         (cfg_share_mem[budget_vl] != 21'd0);
  wire share_old_en = tx_w0_en[share_idx];
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
  // continue11：SNMP 改 BAG 写口打一拍，地址 vl*5+1 预先算好，切断
  // vl_bag_index → 乘加 → 译码 → 上万 FF 使能 的组合链。SNMP 为慢路径，无线速要求。
  reg        snmp_bag_we_q;
  reg [9:0]  snmp_bag_addr_q;
  reg [23:0] snmp_bag_wdata_q;
  reg [6:0]  snmp_bag_vl_q;
  always @(posedge clk) begin
    if (rst_sync) begin
      snmp_bag_we_q <= 1'b0; snmp_bag_addr_q <= 10'd0;
      snmp_bag_wdata_q <= 24'd0; snmp_bag_vl_q <= 7'd0;
    end else begin
      if (snmp_bag_commit) snmp_bag_we_q <= 1'b0;
      if (snmp_vl_bag_we && (snmp_vl_bag_index < NUM_TX_VL)) begin
        snmp_bag_we_q <= 1'b1;
        snmp_bag_vl_q <= snmp_vl_bag_index[6:0];
        snmp_bag_addr_q <= ({2'd0,snmp_vl_bag_index} * 10'd5) + 10'd1;
        snmp_bag_wdata_q <= snmp_vl_bag_wdata[23:0];
      end
    end
  end
  // 影子寄存器写口：与 TX/PORT BRAM 写口同条件、同优先级。
  always @(posedge clk) begin
    if (init_we && init_target == 3'd4) tx_w0_en[init_addr] <= 1'b0;
    else if (cfg_write && tx_hit && ((tx_idx % 10'd5) == 10'd0)) tx_w0_en[tx_idx / 10'd5] <= host_wdata[31];
    if (cfg_write && tx_hit && ((tx_idx % 10'd5) == 10'd1)) tx_w1_lo[tx_idx / 10'd5] <= host_wdata[7:0];
    if (init_we && init_target == 3'd5) port_w0_sh[init_addr] <= 4'd0;
    else if (cfg_write && port_hit && port_idx[1:0] == 2'd0)
      port_w0_sh[port_idx[9:2]] <= {host_wdata[31], host_wdata[18], host_wdata[17:16]};
    if (!(init_we && init_target == 3'd5) && cfg_write && port_hit && port_idx[1:0] == 2'd1)
      port_w1_dport[port_idx[9:2]] <= host_wdata[15:0];
    if (!(init_we && init_target == 3'd5) && cfg_write && port_hit && port_idx[1:0] == 2'd3)
      port_w3_dep[port_idx[9:2]] <= host_wdata[3:0];
  end
  wire txc_init_we = init_we && (init_target == 3'd4);
  wire txc_host_we = cfg_write && tx_hit;
  wire pcc_init_we = init_we && (init_target == 3'd5);
  wire pcc_host_we = cfg_write && port_hit;
  wire [2:0] txc_ws = tx_idx % 10'd5;
  wire [TXA-1:0] txc_waddr = txc_init_we ? init_addr[TXA-1:0] :
                             (snmp_bag_commit ? snmp_bag_vl_q[TXA-1:0] : budget_vl[TXA-1:0]);
  wire txc_we0 = txc_init_we || (txc_host_we && (txc_ws == 3'd0));
  wire txc_we1 = !txc_init_we && ((txc_host_we && (txc_ws == 3'd1)) || snmp_bag_commit);
  wire txc_we2 = !txc_init_we && txc_host_we && (txc_ws == 3'd2);
  wire txc_we3 = !txc_init_we && txc_host_we && (txc_ws == 3'd3);
  wire txc_we4 = !txc_init_we && txc_host_we && (txc_ws == 3'd4);
  wire txc_any_we = txc_we0 || txc_we1 || txc_we2 || txc_we3 || txc_we4;
  wire [31:0] txc_w0_data = txc_init_we ? 32'd0 : host_wdata;
  wire [31:0] txc_w1_data = snmp_bag_commit ? {snmp_bag_wdata_q, tx_w1_lo[snmp_bag_vl_q]} :
                            host_wdata;
  wire [PA-1:0] pcc_waddr = pcc_init_we ? init_addr[PA-1:0] : port_idx[9:2];
  wire pcc_we0 = pcc_init_we || (pcc_host_we && (port_idx[1:0] == 2'd0));
  wire pcc_we1 = !pcc_init_we && pcc_host_we && (port_idx[1:0] == 2'd1);
  wire pcc_we2 = !pcc_init_we && pcc_host_we && (port_idx[1:0] == 2'd2);
  wire pcc_we3 = !pcc_init_we && pcc_host_we && (port_idx[1:0] == 2'd3);
  wire pcc_any_we = pcc_we0 || pcc_we1 || pcc_we2 || pcc_we3;
  wire [31:0] pcc_wdata = pcc_init_we ? 32'd0 : host_wdata;
  assign host_txc_wait = hs && !host_we && tx_hit && (txc_any_we || sch_start_cfg_rd);
  assign host_pcc_wait = hs && !host_we && port_hit && pcc_any_we;
  always @(posedge clk) begin
    if (rst_sync) begin
      txc_rd_d <= 1'b0; txc_ws_d <= 3'd0; txc_vld_d <= 1'b0;
      pcc_rd_d <= 1'b0; pcc_ws_d <= 2'd0; pcc_vld_d <= 1'b0;
    end else begin
      txc_rd_d  <= hs && !host_we && tx_hit && !txc_any_we;
      txc_ws_d  <= txc_ws;
      txc_vld_d <= tx_w0_en[budget_vl];
      pcc_rd_d  <= hs && !host_we && port_hit && !pcc_any_we;
      pcc_ws_d  <= port_idx[1:0];
      pcc_vld_d <= port_w0_sh[port_idx[9:2]][3];
    end
  end
  assign txc_host_rdata = !txc_vld_d ? 32'd0 :
                          (txc_ws_d == 3'd0) ? txq_h0 :
                          (txc_ws_d == 3'd1) ? txq_h1 :
                          (txc_ws_d == 3'd2) ? txq_h2 :
                          (txc_ws_d == 3'd3) ? txq_h3 : txq_h4;
  assign pcc_host_rdata = !pcc_vld_d ? 32'd0 :
                          (pcc_ws_d == 2'd0) ? pcq_h0 :
                          (pcc_ws_d == 2'd1) ? pcq_h1 :
                          (pcc_ws_d == 2'd2) ? pcq_h2 : pcq_h3;
  always @(posedge clk) begin
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
  // 位分配（v0.5.17 P08）：bit7 = RX_REASM_EN（IPv4 分片重组使能，0=旁路）。
  // 选 bit7 的理由：CTL_RST(0x51C) 中 bit7=0（复位旁路，不改变上电行为），
  // 且不在 CTL_WMASK 的保留位(5/6/12)中、未被既有逻辑占用。
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
                  fetch_hit || lur_hit ||
                  (load_hit && (TFTP_EN != 0)) || msg_cnt_hit || rx_chain_hit || tx_chain_hit || host_rx_rd ||
                  (pmem_hit && init_done && ctl_r[13] && !ctl_r[0] && !fb_busy);
  wire stats_wr = we && stats_hit && stats_wr_ok;   // continue4：统计页 W1C
  wire mgmt2_wr = we && mgmt2_hit;                  // continue4：观测窗控制字
  wire wr_known = (reg_page && reg_align && reg_writable) ||
                  (cfg_write && (tx_hit || rx_hit || port_hit)) ||
                  hash_wr_accept ||
                  share_wr || stats_wr || mgmt2_wr || (we && fetch_hit) ||
                  (we && lur_hit) ||
                  pmem_wok || msg_valid || msg_rd_ok || tx_reserve_command || tx_cancel_command;
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
      else if (tx_hit) rdata_r <= 32'd0;
      else if (share_hit) rdata_r <= (init_done && cfg_share_loaded[share_idx]) ?
                                   {11'd0,cfg_share_mem[share_idx]} : 32'd0;
      else if (rx_hit) rdata_r <= 32'd0;  // continue2：由 rxc_rd_d/rxc_host_rdata 直出
      else if (port_hit) rdata_r <= 32'd0;
      else if (desc_hit) rdata_r <= hop_is_rx ? rxpb_desc_word : 32'd0;  // TX: PB 读出经 desc_rd_d 选
      else if (msg_cnt_hit) rdata_r <= hop_is_rx ? {28'd0,rxpb_cnt_word} : 32'd0;
      else if (rx_chain_hit) rdata_r <= rx_chain_lookup_word;
      else if (tx_chain_hit) begin
        case(host_addr[2:0])
          0:rdata_r<={11'd0,tx_reserve_reject_sticky,tx_reserve_ready,tx_reserved,pb_wr_valid,tx_open_count,tx_open_length};
          1:rdata_r<={16'd0,tx_open_blocks};
          2:rdata_r<={pb_free_map,tx_open_mask};
          3:rdata_r<={30'd0,tx_reserve_reject_sticky,tx_reserved};
          default:rdata_r<={tx_bad_completion_count,tx_failed_message_count};
        endcase
      end
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
           6'h1A: rdata_r <= {21'd0, mgmt_bidx};
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
           // P08：IPv4 分片重组状态（只读）
           6'h2A: rdata_r <= {31'd0, reasm_en};
           6'h2B: rdata_r <= reasm_hit_cnt;
           6'h2C: rdata_r <= reasm_drop_cnt;
           6'h2D: rdata_r <= reasm_slot_used;
           6'h2E: rdata_r <= reasm_out_vld ? 32'd1 : 32'd0;
           6'h2F: rdata_r <= {28'd0, reasm_out_reason};
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
       else if (fetch_hit) begin
         case (host_addr[5:0])
           6'h00: rdata_r <= {28'd0, fe_done, fe_failed, fe_busy, 1'b0};
           6'h01: rdata_r <= fetch_ip;
           6'h0A: rdata_r <= {24'd0, fetch_fnlen};
           6'h0B: rdata_r <= {16'd0, fetch_ticks};
           6'h0C: rdata_r <= {16'd0, fe_file_err, fe_file_len};
           6'h0D: rdata_r <= {31'd0, fe_file_valid};
           6'h0F: rdata_r <= {24'd0, fe_rd_data};
           6'h10: rdata_r <= fe_rx_bytes;
           6'h11: rdata_r <= {28'd0, fe_fcode};
           6'h12: rdata_r <= fe_ok_cnt;
           6'h13: rdata_r <= fe_drop_cnt;
           6'h14: rdata_r <= {16'd0, fetch_tid};
           6'h15: rdata_r <= {24'd0, fetch_preload_data_r};
           6'h16: rdata_r <= {18'd0, fetch_preload_length_r};
           6'h17: rdata_r <= {28'd0, fetch_up_mode, fe_preload_error,
                               fe_preload_data_ready, fe_preload_start_ready};
           6'h18: rdata_r <= {20'd0, init_file_index, 4'd0, init_file_ready,
                               init_file_error, init_file_done, init_file_busy};
           6'h19: rdata_r <= init_file_fields;
           default: rdata_r <= 32'd0;
         endcase
       end
       // P05: LUR 宿主窗 0xAC80~0xACBF（只读观测 + 0xAC80 控制字）
       else if (lur_hit) begin
         case (host_addr[5:0])
           6'h00: rdata_r <= {28'd0, lur_up_busy, lur_skip_p, lur_abort_p, lur_start_p};
           6'h01: rdata_r <= {16'd0, lur_fail_cnt, lur_ok_cnt};
           6'h02: rdata_r <= {24'd0, lur_cur, lur_fcode, lur_failed, lur_done, lur_busy};
           6'h03: rdata_r <= lur_bytes;
           6'h04: rdata_r <= {16'd0, lur_file_count};
           6'h05: rdata_r <= {28'd0, lur_err, lur_result_vld, lur_ok, lur_up_busy};
           6'h06: rdata_r <= {24'd0, lur_name_len_w};
           6'h07: rdata_r <= {30'd0, lur_tftp_mode, lur_upload_mode};
           6'h08: rdata_r <= {29'd0, lur_name_sel};
           6'h09: rdata_r <= {24'd0, lur_host_byte_r};
           6'h0A: rdata_r <= {24'd0, lur_host_index};
           6'h0B: rdata_r <= {31'd0, lur_host_read};
           6'h0C: rdata_r <= {31'd0, lur_auto_ack};
           6'h0D: rdata_r <= {30'd0,lur_wait_file_ack,lur_hold_files};
           6'h0E: rdata_r <= {27'd0,lur_transport_length_error,(lur_pump_state!=0),
                                  lur_control_valid,lur_control_busy,lur_tftp_mode};
           6'h0F: rdata_r <= tftp_bytes;
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
      if (wr_bad || rd_miss || tx_reserve_reject) err_r <= err_r | 32'h1 | (cfg_over ? 32'h2 : 32'd0);
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
  wire [3:0]  msg_port_sh = port_w0_sh[msg_port];
  wire [31:0] msg_port_w0 = {msg_port_sh[3], 12'd0, msg_port_sh[2], msg_port_sh[1:0], 16'd0};
  wire [31:0] msg_port_w3 = {28'd0, port_w3_dep[msg_port]};
  wire msg_len_ok = (host_wdata[15:0] >= 16'd8) &&
                   ((TX_CHAIN_ENABLE && tx_reserved && msg_port_w0[17:16]==2'd1)
                     ? (host_wdata[15:0]<=16'd8192 && host_wdata[13:0]==tx_open_length)
                     : host_wdata[15:0]<=16'd1471);
  assign msg_valid = msg_wr_hit && init_done && !ctl_r[13] &&
                   msg_port_w0[31] && !msg_port_w0[18] &&
                   (msg_port_w0[17:16] != 2'd2) && msg_len_ok;
  // ==========================================================================
  // 管理面 TX 上线（设计书 §7.1.1，v0.5.20 补充；本轮实现）
  //
  // 把 snmp_lite / a615a_tftp 产生的响应字节流搬进 PMEM 开放块，随后拉一次
  // SAP 端口的 msg_commit；之后完全复用 tx_port_buf 的描述符分配、tx_frame_builder
  // 的封装与 tx_vl_scheduler 的 BAG 调度——管理面不另设队列、不新增 TX 通路。
  //
  // 字节序：PMEM 内大端（字节 4i+0 在 [31:24]），与 §7.1 块内布局一致。
  // 写口优先级：RX 双网 > 主机 > 管理面（最低），管理面绝不抢占数据面。
  // 取字节：SNMP rsp 为 RD_NEG BRAM，地址由本 FSM 驱动；TFTP 仍为组合/同步读。
  // resp_ack 只在整帧取完后给一次，避免引擎提前清 resp_vld。
  //
  // 前置条件：主机须已把某个 TX VL 的 cfg_port 配成该 SAP 端口号
  // （SNMP_SAP_PORT / TFTP_SAP_PORT），否则调度器不会选中该 VL——这与主机
  // 自己用 MSG_WR 发流的配置要求一致，不新增配置项。
  // ==========================================================================
  // MT_WARM：SNMP/TFTP 响应口同步读后，地址驱动后再等 1 拍取字节
  localparam [2:0] MT_IDLE = 3'd0, MT_BYTE = 3'd1, MT_COMMIT = 3'd2,
                   MT_WARM = 3'd3, MT_WAIT_RESULT = 3'd4, MT_RETRY = 3'd5;
  reg  [7:0]  mt_sel_port;    // 本帧提交的 SAP 端口号
  reg         mt_sel_tftp;   // 本帧锁定响应源，传输期间不能跟随另一引擎切换
  reg         mt_sel_cli;    // P05: 本帧来自 615A 取件引擎的发射缓冲
  wire [7:0]  tfetch_sap_port = TFTP_SAP_PORT[7:0];  // 取件报文按 TFTP SAP 端口类别提交
  reg  [31:0] mt_peer_ip;    // 与响应一起锁存的对端地址
  reg  [15:0] mt_peer_port;  // 与响应一起锁存的对端 TID/UDP 端口
  reg  [10:0] mt_len;         // 实际 UDP 载荷长度，不把 Ethernet pad 算进来
  reg  [10:0] mt_byte_idx;    // 已取字节数
  reg  [31:0] mt_word;        // 正在拼装的字（大端）
  reg  [1:0]  mt_be_cnt;      // 已装入当前字的字节数 0..3
  reg  [3:0]  mt_blk;         // 本帧锁定的开放块（防止中途换块）
  reg  [1:0]  mt_result_wait; // tx_port_buf 的 R/X/W 结果比 commit 脉冲晚两拍
  reg         mt_fin;         // 取字节完成，等一次写回
  reg [15:0]  mgmt_meta_valid;
  reg [31:0]  mgmt_meta_ip [0:15];
  reg [15:0]  mgmt_meta_port [0:15];

  wire        mt_pick_tftp  = tftp_resp_vld && (TFTP_EN != 0);
  wire        mt_pick_snmp  = snmp_resp_vld && (SNMP_EN != 0) && !mt_pick_tftp;
  // P05: 第三源——615A 取件引擎的请求/ACK 缓冲（最低优先级）
  wire        mt_pick_cli   = (A615A_EN != 0) && fe_pkt_vld &&
                              !mt_pick_tftp && !mt_pick_snmp;
  wire        mt_pick_vld   = mt_pick_tftp || mt_pick_snmp || mt_pick_cli;
  wire [10:0] mt_pick_len   = mt_pick_tftp ? tftp_resp_len :
                              (mt_pick_snmp ? snmp_resp_len : fe_pkt_len);
  wire        mt_active_vld = mt_sel_tftp ? tftp_resp_vld :
                              (mt_sel_cli ? fe_pkt_vld : snmp_resp_vld);
  wire [7:0]  mt_active_byte= mt_sel_tftp ? tftp_resp_byte :
                              (mt_sel_cli ? fe_pkt_byte : snmp_resp_byte);
  // 长度合法性：上限与主机路径同款（§7.1 msg_len_ok，1471 B）；管理协议载荷
  // 允许 1..7 B。RFC 1350 ACK(0)/ACK(k) 是 4 B，Ethernet pad 在 builder 内另处理。
  wire        mt_len_ok     = (mt_pick_len >= 11'd1) && (mt_pick_len <= 11'd1471);
  // Ethernet 最小帧填充由 tx_frame_builder 放在 UDP 载荷之后、AFDX SN 之前；
  // 这里保留 RFC 1350 的真实 4B ACK 长度，不把物理帧填充写进 UDP 数据。
  // MGMT_TX_EN（CTL[9]，复位默认 0）：管理面响应自动上线的总开关。
  // CTL_WMASK 的 bit12 与 bit5/6 为写无效保留位，不可用于主机配置；bit9 可写
  // 且 CTL_RST(0x51C) 中为 0，故取 bit9 作该开关，不与既有位冲突。
  // 关闭时行为与本节实现前完全一致——响应只留在观测窗由主机按 mgmt_bidx 读走，
  // T15/T16 等既有用例依赖该路径。开启后由本 FSM 接管字节流并提交上线。
  // 两条路径互斥：开关为 0 时 FSM 全程停在 MT_IDLE，resp_rd_addr 归主机。
  wire        mt_tx_en      = ctl_r[9];
  wire        mt_can_start  = mt_tx_en && !ctl_r[13] && mt_pick_vld && pb_wr_valid && !tx_reserved &&
                              mt_len_ok && init_done && !host_tx_build_lock &&
                              !host_pmem_pending && !host_pmem_req && !msg_commit &&
                              !tx_reserve_command && !tx_cancel_command;

  // 取字节期间接管 resp_rd_addr；空闲时交还主机观测窗。
  // MT_WARM/MT_BYTE 都驱动地址：WARM 让同步响应 BRAM 先采一拍。
  wire        mt_addr_drive = (mt_state == MT_WARM) || (mt_state == MT_BYTE);

  // PMEM 写请求：块基址 + 字偏移；大端拼装，满字或末字节时写一拍
  // mt_byte_idx = 已提交（写入或正写入）的字节数；取字节时用它作 resp 下标。
  wire [12:0] mt_wr_addr    = {mt_blk, 9'd0} + {4'd0, mt_byte_idx[10:2]};
  wire [7:0]  mt_byte_data  = mt_active_vld ? mt_active_byte : 8'h00;
  wire [31:0] mt_word_next  = (mt_be_cnt == 2'd0) ? {mt_byte_data, 24'd0} :
                              (mt_be_cnt == 2'd1) ? {mt_word[31:24], mt_byte_data, 16'd0} :
                              (mt_be_cnt == 2'd2) ? {mt_word[31:16], mt_byte_data, 8'd0} :
                                                    {mt_word[31:8], mt_byte_data};
  wire        mt_will_full  = (mt_be_cnt == 2'd3);                 // 本拍凑满 4 字节
  wire        mt_will_last  = (mt_byte_idx + 11'd1 >= mt_len);      // 本拍是最后一字节
  wire        mt_will_write_candidate = (mt_state == MT_BYTE) && mt_active_vld && init_done &&
                                       (mt_will_full || mt_will_last);
  wire        mt_pmem_grant;
  wire        mt_do_pick    = (mt_state == MT_BYTE) && mt_active_vld && init_done &&
                             (!mt_will_write_candidate || mt_pmem_grant);
  // SNMP's response RAM is synchronous: while consuming byte N, request N+1.
  // If PMEM backpressure stalls a word boundary, reread N so its byte remains
  // stable. TFTP keeps its visible index at N for combinational headers; its
  // unload RAM gets a separate next-byte prefetch only on an accepted consume.
  wire [10:0] mgmt_bidx_mux = mt_addr_drive ?
      ((!mt_sel_tftp && !mt_sel_cli && (mt_state == MT_BYTE)) ?
        (mt_byte_idx + (mt_do_pick ? 11'd1 : 11'd0)) : mt_byte_idx) : mgmt_bidx;
  wire        tftp_rd_ahead = (mt_state == MT_BYTE) && mt_sel_tftp && mt_do_pick &&
                              tftp_resp_byte_sync && (mt_byte_idx >= 11'd3);
  wire        mt_wr_go      = mt_do_pick && (mt_will_full || mt_will_last);
  wire [31:0] mt_wr_data    = mt_word_next;
  // 不满一字的末拍：高位先填，BE 对应已装字节数（含本拍）
  wire [3:0]  mt_wr_be      = mt_will_full ? 4'b1111 :
                             (mt_be_cnt == 2'd0) ? 4'b1000 :
                             (mt_be_cnt == 2'd1) ? 4'b1100 :
                             (mt_be_cnt == 2'd2) ? 4'b1110 : 4'b1111;
  // 管理面 commit 脉冲与端口/长度
  assign msg_commit = we && msg_valid;
  wire        mgmt_commit   = (mt_state == MT_COMMIT) && !msg_commit;
  wire [7:0]  mt_port_eff   = mt_sel_port;
  wire [15:0] mt_len_eff    = {5'd0, mt_len}; // 不可写 mt_len[15:0]：mt_len 仅 [10:0]，越界位为 X
  wire        mgmt_port_pend= mgmt_commit;

  always @(posedge clk) begin
    if (rst_sync) begin
      mt_state    <= MT_IDLE;
      mt_sel_port <= 8'd0;
      mt_sel_tftp <= 1'b0;
      mt_sel_cli  <= 1'b0;
      mt_peer_ip  <= 32'd0;
      mt_peer_port<= 16'd0;
      mt_len      <= 11'd0;
      mt_byte_idx <= 11'd0;
      mt_word     <= 32'd0;
      mt_be_cnt   <= 2'd0;
      mt_blk      <= 4'd0;
      mt_result_wait <= 2'd0;
      mt_fin      <= 1'b0;
    end else begin
      case (mt_state)
        MT_IDLE: begin
          if (mt_can_start) begin
            mt_sel_port <= mt_pick_tftp ? TFTP_SAP_PORT[7:0] :
                           (mt_pick_snmp ? SNMP_SAP_PORT[7:0] : tfetch_sap_port);
            mt_sel_tftp <= mt_pick_tftp;
            mt_sel_cli  <= mt_pick_cli;
            mt_peer_ip  <= mt_pick_tftp ? tftp_resp_peer_ip :
                           (mt_pick_snmp ? sap_out_srcip : fe_pkt_dst_ip);
            mt_peer_port<= mt_pick_tftp ? tftp_resp_tid :
                           (mt_pick_snmp ? snmp_peer_port : fe_pkt_dst_port);
            mt_len      <= mt_pick_len;
            mt_byte_idx <= 11'd0;
            mt_word     <= 32'd0;
            mt_be_cnt   <= 2'd0;
            mt_blk      <= pb_wr_blk;
            mt_state    <= MT_WARM; // 先驱动 resp_rd_addr=0，等同步读
          end
        end
        MT_WARM: begin
          // SNMP u_rsp / TFTP rbuf 均为同步读；本拍地址已在 mux 上，下拍取字节
          if (mt_active_vld && init_done) mt_state <= MT_BYTE;
        end
        MT_BYTE: begin
          if (mt_do_pick) begin
            // 每拍消费 1 个响应字节；满字或末字节时顺带写 PMEM
            mt_byte_idx <= mt_byte_idx + 11'd1;
            if (mt_will_full || mt_will_last) begin
              mt_word   <= 32'd0;
              mt_be_cnt <= 2'd0;
              if (mt_will_last) begin
                mt_fin   <= 1'b1;
                mt_state <= MT_COMMIT;
              end
            end else begin
              mt_word   <= mt_word_next;
              mt_be_cnt <= mt_be_cnt + 2'd1;
            end
          end
        end
        MT_COMMIT: begin
          // 主机与管理面共用 port-buffer 单事件口；主机同拍提交时让管理面让拍。
          // commit_rej 在 tx_port_buf 的结果阶段才有效，响应源在此之前不能 ACK。
          if (!msg_commit) begin
            mt_fin         <= 1'b0;
            mt_result_wait <= 2'd0;
            mt_state       <= MT_WAIT_RESULT;
          end
        end
        MT_WAIT_RESULT: begin
          if (mt_result_wait == 2'd0) begin
            mt_result_wait <= 2'd1;
          end else if (pb_rej) begin
            // 被拒描述符对应块由 tx_port_buf 退回；响应仍保持有效，等开放块后重拷。
            mt_result_wait <= 2'd0;
            mt_state       <= MT_RETRY;
          end else begin
            mt_result_wait <= 2'd0;
            mt_state       <= MT_IDLE;
          end
        end
        MT_RETRY: begin
          if (pb_wr_valid) begin
            mt_blk      <= pb_wr_blk;
            mt_byte_idx <= 11'd0;
            mt_word     <= 32'd0;
            mt_be_cnt   <= 2'd0;
            mt_state    <= MT_WARM;
          end
        end
        default: mt_state <= MT_IDLE;
      endcase
    end
  end

  // 引擎 ack：管理面路径下由本 FSM 在 MT_COMMIT 给一次；主机观测窗路径维持原样。
  // snmp/tftp 的 resp_ack 原本由 host_addr 译码产生，这里做或以支持两条消费路径。
  wire mgmt_ack_snmp = (mt_state == MT_WAIT_RESULT) && (mt_result_wait == 2'd1) &&
                       !pb_rej && !mt_sel_tftp && !mt_sel_cli;
  wire mgmt_ack_tftp = (mt_state == MT_WAIT_RESULT) && (mt_result_wait == 2'd1) &&
                       !pb_rej && mt_sel_tftp;
  wire mgmt_ack_cli  = (mt_state == MT_WAIT_RESULT) && (mt_result_wait == 2'd1) &&
                       !pb_rej && mt_sel_cli;

  wire fb_free;
  wire [3:0] fb_free_blk;
  // msg_commit：主机路径（msg_commit）与管理面路径（mgmt_commit）二选一进入
  // tx_port_buf。两者共用同一描述符/块分配，故不会互相覆盖开放块。
  wire pb_commit_any = msg_commit || mgmt_commit;
  wire [7:0] pb_port_eff = mgmt_commit ? mt_port_eff : msg_port;
  wire [15:0] pb_len_eff  = mgmt_commit ? mt_len_eff : host_wdata[15:0];
  // §7.1 规定管理面提交为 SAP 端口（type=2）：主机路径的 msg_port_w0/w3 来自主机
  // MSG_WR 的译码（msg_port 由 host_addr-0x8280 得到），对 mgmt 提交无意义且
  // 此时是未初始化值——若沿用，r_depth 变成 X 会污染 desc/qst（描述符 len 读出 X、
  // qfull 判定失效），调度器随后拿到 blk=0/len=X 的坏描述符并永久卡住 inflight。
  // 故管理面提交按其真实 SAP 端口号取深度：SNMP_SAP_PORT / TFTP_SAP_PORT。
  wire [1:0] pb_type_eff  = mgmt_commit ? 2'd2 : msg_port_w0[17:16];
  wire [3:0] pb_depth_eff = mgmt_commit
      ? ((port_w3_dep[mt_sel_port] == 4'd0) ? 4'd1 : port_w3_dep[mt_sel_port])
      : msg_port_w3[3:0];
  wire legacy_pb_rej,legacy_pb_wr_valid,legacy_pb_sch_ack,legacy_pb_pending;
  wire [3:0] legacy_pb_wr_blk,legacy_pb_sch_blk;
  wire [12:0] legacy_pb_sch_len;
  wire [31:0] legacy_pb_desc_rd_data;
  wire [NUM_PORTS-1:0] legacy_pb_req,legacy_pb_full;
  wire [15:0] legacy_pb_free_map,legacy_pb_ovr_cnt,legacy_pb_qovf_cnt,legacy_pb_exh_cnt;
  wire chain_pb_rej,chain_pb_wr_valid,chain_pb_sch_ack,chain_pb_pending;
  wire [3:0] chain_pb_wr_blk,chain_pb_sch_blk;
  wire [12:0] chain_pb_sch_len;
  wire [31:0] chain_pb_desc_rd_data;
  wire [NUM_PORTS-1:0] chain_pb_req,chain_pb_full;
  wire [15:0] chain_pb_free_map,chain_pb_ovr_cnt,chain_pb_qovf_cnt,chain_pb_exh_cnt;
  wire [13:0] tx_sch_app_len,tx_sch_offset;
  wire [15:0] tx_sch_blocks,tx_sch_id;
  wire [2:0] tx_sch_count;
  assign tx_reserve_command=we && TX_CHAIN_ENABLE && host_addr==16'h8590 &&
                           init_done && !ctl_r[13] && mt_state==MT_IDLE && !host_pmem_pending &&
                           tx_reserve_ready && host_wdata[31:14]==0;
  assign tx_cancel_command=we && TX_CHAIN_ENABLE && host_addr==16'h8593 && host_wdata==32'd1 &&
                          init_done && !ctl_r[13] && mt_state==MT_IDLE && !host_pmem_pending;
  // Retain the reserve result long enough for a later public host read.
  // A new accepted attempt or cancel clears it; rejection wins on its edge.
  always @(posedge clk) begin
    if(rst_sync) tx_reserve_reject_sticky<=1'b0;
    else if(tx_reserve_reject || (we && TX_CHAIN_ENABLE && host_addr==16'h8590 && !tx_reserve_command))
      tx_reserve_reject_sticky<=1'b1;
    else if(tx_reserve_command || tx_cancel_command) tx_reserve_reject_sticky<=1'b0;
  end
  generate if(TX_CHAIN_ENABLE) begin: g_tx_store
    tx_message_store #(.NUM_PORTS(NUM_PORTS)) u_store (
      .clk(clk),.rst_sync(rst_sync),.tb_us(rtc64[7:0]),
      .reserve_valid(tx_reserve_command),.reserve_length(host_wdata[13:0]),.reserve_ready(tx_reserve_ready),.reserve_reject(tx_reserve_reject),
      .cancel_open(tx_cancel_command),.wr_blk(chain_pb_wr_blk),.wr_valid(chain_pb_wr_valid),
      .open_blocks(tx_open_blocks),.open_count(tx_open_count),.open_length(tx_open_length),.reservation_active(tx_reserved),.open_mask(tx_open_mask),
      .msg_commit(pb_commit_any),.port_id(pb_port_eff),.length(pb_len_eff),.port_type(pb_type_eff),.port_depth(pb_depth_eff),.commit_reject(chain_pb_rej),
      .desc_rd_addr(desc_idx),.desc_rd_data(chain_pb_desc_rd_data),.sch_req(chain_pb_req),.buf_full(chain_pb_full),
      .sch_take(sch_take),.sch_port(sch_port),.sch_ack(chain_pb_sch_ack),.sch_head(chain_pb_sch_blk),.sch_length(chain_pb_sch_len),
      .sch_app_length(tx_sch_app_len),.sch_fragment_offset(tx_sch_offset),.sch_blocks(tx_sch_blocks),.sch_identification(tx_sch_id),.sch_block_count(tx_sch_count),
      .fragment_done(tx_fragment_done),.fragment_error(tx_fragment_error),.done_head(tx_fragment_head),.done_last(tx_fragment_last),.done_next_offset(tx_fragment_next),
      .free_map(chain_pb_free_map),.overwrite_count(chain_pb_ovr_cnt),.queue_overflow_count(chain_pb_qovf_cnt),.exhaust_count(chain_pb_exh_cnt),
      .bad_completion_count(tx_bad_completion_count),.failed_message_count(tx_failed_message_count),.pending(chain_pb_pending)
    );
  end else begin: g_tx_store_disabled
    assign tx_bad_completion_count=0;assign tx_failed_message_count=0;
    assign tx_open_blocks=0;assign tx_open_count=0;assign tx_open_length=0;assign tx_open_mask=0;
    assign tx_reserved=0;assign tx_reserve_ready=0;assign tx_reserve_reject=0;
    assign tx_sch_app_len=0;assign tx_sch_offset=0;assign tx_sch_blocks=0;assign tx_sch_count=0;assign tx_sch_id=0;
    assign chain_pb_rej=0;assign chain_pb_wr_blk=0;assign chain_pb_wr_valid=0;assign chain_pb_sch_ack=0;assign chain_pb_pending=0;
    assign chain_pb_sch_blk=0;assign chain_pb_sch_len=0;assign chain_pb_desc_rd_data=0;assign chain_pb_req=0;assign chain_pb_full=0;
    assign chain_pb_free_map=0;assign chain_pb_ovr_cnt=0;assign chain_pb_qovf_cnt=0;assign chain_pb_exh_cnt=0;
  end endgenerate
  assign pb_rej=TX_CHAIN_ENABLE ? chain_pb_rej : legacy_pb_rej;
  assign pb_wr_blk=TX_CHAIN_ENABLE ? chain_pb_wr_blk : legacy_pb_wr_blk;
  assign pb_wr_valid=TX_CHAIN_ENABLE ? chain_pb_wr_valid : legacy_pb_wr_valid;
  assign pb_sch_ack=TX_CHAIN_ENABLE ? chain_pb_sch_ack : legacy_pb_sch_ack;
  assign pb_sch_blk=TX_CHAIN_ENABLE ? chain_pb_sch_blk : legacy_pb_sch_blk;
  assign pb_sch_len=TX_CHAIN_ENABLE ? chain_pb_sch_len : legacy_pb_sch_len;
  assign pb_desc_rd_data=TX_CHAIN_ENABLE ? chain_pb_desc_rd_data : legacy_pb_desc_rd_data;
  assign pb_req=TX_CHAIN_ENABLE ? chain_pb_req : legacy_pb_req;
  assign pb_full=TX_CHAIN_ENABLE ? chain_pb_full : legacy_pb_full;
  assign pb_free_map=TX_CHAIN_ENABLE ? chain_pb_free_map : legacy_pb_free_map;
  assign pb_ovr_cnt=TX_CHAIN_ENABLE ? chain_pb_ovr_cnt : legacy_pb_ovr_cnt;
  assign pb_qovf_cnt=TX_CHAIN_ENABLE ? chain_pb_qovf_cnt : legacy_pb_qovf_cnt;
  assign pb_exh_cnt=TX_CHAIN_ENABLE ? chain_pb_exh_cnt : legacy_pb_exh_cnt;
  assign pb_pending=TX_CHAIN_ENABLE ? chain_pb_pending : legacy_pb_pending;
  tx_port_buf #(.NUM_PORTS(NUM_PORTS), .TX_BLK_LO(0), .TX_BLK_N(6)) u_txbuf (
    .clk(clk), .rst_sync(rst_sync), .tb_us(rtc64[7:0]),
    .msg_commit(pb_commit_any && !TX_CHAIN_ENABLE), .port_id(pb_port_eff), .len(pb_len_eff),
    .port_type(pb_type_eff), .port_depth(pb_depth_eff), .commit_rej(legacy_pb_rej),
    .wr_blk(legacy_pb_wr_blk), .wr_blk_vld(legacy_pb_wr_valid),
    .desc_rd_addr(desc_idx), .desc_rd_data(legacy_pb_desc_rd_data),
    .sch_req(legacy_pb_req), .buf_full(legacy_pb_full),
    .sch_take(sch_take && !TX_CHAIN_ENABLE), .sch_port(sch_port), .sch_ack(legacy_pb_sch_ack),
    .sch_blk(legacy_pb_sch_blk), .sch_len(legacy_pb_sch_len),
    .blk_free(fb_free && !TX_CHAIN_ENABLE), .blk_free_id(fb_free_blk),
    .free_map(legacy_pb_free_map), .ovr_cnt(legacy_pb_ovr_cnt), .q_ovf_cnt(legacy_pb_qovf_cnt),
    .pmem_exhaust_cnt(legacy_pb_exh_cnt), .pending(legacy_pb_pending));

  // Per-block peer metadata follows a management response through the TX queue.
  // The live SAP parser fields may already describe a later request by the time
  // the scheduler launches this descriptor.
  always @(posedge clk) begin
    // The valid bitmap is reset; metadata contents are don't-care while invalid
    // and are written on the same edge that marks a committed block valid.
    if (rst_sync) mgmt_meta_valid <= 16'd0;
    else begin
      if (mgmt_commit) begin
        mgmt_meta_valid[mt_blk] <= 1'b1;
        mgmt_meta_ip[mt_blk] <= mt_peer_ip;
        mgmt_meta_port[mt_blk] <= mt_peer_port;
      end
      if ((mt_state == MT_WAIT_RESULT) && (mt_result_wait == 2'd1) && pb_rej)
        mgmt_meta_valid[mt_blk] <= 1'b0;
      if (fb_free) mgmt_meta_valid[fb_free_blk] <= 1'b0;
    end
  end

  // 主机 PMEM 写口在配置期可扫全区；运行期仅能写当前开放 TX 块。
  // 读口 A 在 CFG_MODE=1 且 builder 空闲时让给主机读取；读口 B 保留给 builder。
  wire [12:0] host_pmem_addr = host_addr - 16'h8800;
  wire in_open_blk = pb_wr_valid && (TX_CHAIN_ENABLE ? tx_open_mask[host_pmem_addr[12:9]] :
                                                   host_pmem_addr[12:9]==pb_wr_blk);
  assign pmem_wok = init_done && pmem_hit &&
                  ((ctl_r[13] && !ctl_r[0]) || (!ctl_r[13] && in_open_blk));
  assign host_pmem_req = we && pmem_wok;
  // 运行期（CFG_MODE=0）主机可读 RX 块（6..15）取接收载荷；读口 A 被 builder
  // 占用的拍不读不 ACK（host_rx_rd_wait），主机按协议保持请求直到 ACK。
  assign host_rx_rd = hs && !host_we && pmem_hit && init_done && !ctl_r[13] &&
                      (host_pmem_addr[12:9] >= 4'd6);
  wire host_pmem_rd_candidate = (hs && !host_we && pmem_hit && init_done && ctl_r[13] &&
                                 !ctl_r[0] && !fb_busy) || (host_rx_rd && !fb_rd_en_a);
  assign host_pmem_rd = host_pmem_rd_candidate && !aux_rd_turn;
  assign host_rx_rd_wait = (host_rx_rd && fb_rd_en_a) ||
                            (host_pmem_rd_candidate && aux_rd_turn);
  // 两网各有写 FIFO。RX 优先、双网轮换；等 RX 都暂空时落已锁存主机写。
  wire q_wr_a, q_wr_b, q_pop_a, q_pop_b;
  wire [12:0] q_addr_a, q_addr_b;
  wire [31:0] q_data_a, q_data_b;
  wire [3:0] q_be_a, q_be_b;
  reg rx_wr_rr;
  assign rx_pmem_busy = q_wr_a || q_wr_b;
  assign q_pop_a = q_wr_a && (!q_wr_b || !rx_wr_rr) && !copy_wr_turn;
  assign q_pop_b = q_wr_b && (!q_wr_a || rx_wr_rr) && !copy_wr_turn;
  assign host_commit_pending = host_pmem_pending && !rx_pmem_busy && !copy_wr_turn;
  assign host_commit_now = host_pmem_req && !host_pmem_pending && !rx_pmem_busy && !copy_wr_turn;
  assign mt_pmem_grant = !q_pop_a && !q_pop_b && !host_commit_pending &&
                         !host_commit_now && !copy_wr_valid;
  assign copy_wr_grant = copy_wr_valid && !q_pop_a && !q_pop_b &&
                         !host_commit_pending && !host_commit_now;
  always @(posedge clk) begin
    if (rst_sync) host_tx_build_lock <= 1'b0;
    else if (tx_reserve_reject) host_tx_build_lock <= 1'b0;
    else if (tx_cancel_command) host_tx_build_lock <= 1'b0;
    else if (tx_reserve_command) host_tx_build_lock <= 1'b1;
    else if (we && msg_wr_hit) host_tx_build_lock <= 1'b0;
    else if (!ctl_r[13] && host_pmem_req && in_open_blk) host_tx_build_lock <= 1'b1;
  end
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
                              host_commit_pending ? host_pmem_pending_addr :
                              host_commit_now ? host_pmem_addr :
                              copy_wr_grant ? copy_wr_addr : mt_wr_addr;
  wire [31:0] pmem_wr_data = q_pop_a ? q_data_a : q_pop_b ? q_data_b :
                              host_commit_pending ? host_pmem_pending_data :
                              host_commit_now ? host_wdata :
                              copy_wr_grant ? copy_wr_data : mt_wr_data;
  wire [3:0] pmem_wr_be = q_pop_a ? q_be_a : q_pop_b ? q_be_b :
                         host_commit_pending ? 4'hF :
                         host_commit_now ? 4'hF :
                         copy_wr_grant ? copy_wr_be : mt_wr_be;
  wire pmem_wr_en = q_pop_a || q_pop_b || host_commit_pending || host_commit_now ||
                    copy_wr_grant || mt_wr_go;
  wire fb_rd_en_b;
  wire [12:0] fb_rd_addr_a, fb_rd_addr_b;
  wire [31:0] pmem_data_b;
  bram_sdp #(.W(32), .D(PMEM_KB*256), .BYTE_EN(1)) u_pmem (
    .clk(clk), .wr_en(pmem_wr_en), .wr_addr(pmem_wr_addr),
    .wr_data(pmem_wr_data), .wr_be(pmem_wr_be),
    .rd_en_a(host_pmem_rd | fb_rd_en_a | sap_pm_gnt | copy_rd_grant | check_rd_grant),
    .rd_addr_a(host_pmem_rd ? host_pmem_addr :
               fb_rd_en_a  ? fb_rd_addr_a    :
               sap_pm_gnt ? sap_pm_addr :
               copy_rd_grant ? copy_rd_addr : check_rd_addr), .rd_data_a(pmem_data_a),
    .rd_en_b(fb_rd_en_b), .rd_addr_b(fb_rd_addr_b), .rd_data_b(pmem_data_b));
  assign copy_rd_grant = copy_rd_req && !host_pmem_rd && !fb_rd_en_a &&
                          (!sap_pm_req || aux_rd_turn);
  assign copy_rd_valid = copy_rd_valid_q;
  assign check_rd_grant = check_rd_req && !host_pmem_rd && !fb_rd_en_a &&
                          (!sap_pm_req || aux_rd_turn) && !copy_rd_req;
  always @(posedge clk) begin
    if (rst_sync) begin
      copy_rd_valid_q <= 1'b0;
      check_rd_valid_q <= 1'b0;
      aux_rd_wait <= 3'd0;
      copy_wr_wait <= 3'd0;
    end else begin
      copy_rd_valid_q <= copy_rd_grant;
      check_rd_valid_q <= check_rd_grant;
      // One auxiliary read in each eight available port-A cycles under
      // continuous host/SAP traffic. Legacy builder reads cannot be stalled
      // by this adapter, so the bound excludes cycles owned by that reader.
      if (!aux_rd_req || copy_rd_grant || check_rd_grant) aux_rd_wait <= 3'd0;
      else if (!fb_rd_en_a && aux_rd_wait != 3'd7) aux_rd_wait <= aux_rd_wait + 3'd1;
      // The RX write FIFOs hold data when pop is low. Reserve a copy write
      // after seven competing writes instead of starving behind host/RX.
      if (!copy_wr_valid || copy_wr_grant) copy_wr_wait <= 3'd0;
      else if (copy_wr_wait != 3'd7) copy_wr_wait <= copy_wr_wait + 3'd1;
    end
  end

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
  wire rx_first_a = rx_stream_en && rx_mac_valid_a && (IF_MODE != 0 || rx_ready) && !rx_busy_a;
  wire rx_first_b = rx_stream_en && (DUAL_NET_EN != 0) && rx_mac_valid_b &&
                     (IF_MODE != 0 || rx_ready_b) && !rx_busy_b;
  assign rx_alloc_a = rx_first_a && rx_room_a;
  assign rx_alloc_b = rx_first_b && rx_room_b;
  rx_block_pool #(.CHAIN_ENABLE(RX_CHAIN_ENABLE)) u_rxpool (
    .clk(clk), .rst_sync(rst_sync), .alloc_a(rx_alloc_a), .alloc_b(rx_alloc_b),
    .valid_a(rx_blk_vld_a), .valid_b(rx_blk_vld_b),
    .blk_a(rx_blk_a), .blk_b(rx_blk_b),
    .free_a(rx_rel_a), .free_id_a(rx_rel_id_a),
    .free_b(rx_rel_b), .free_id_b(rx_rel_id_b),
    .free_pipe(rx_pipe_free), .free_id_pipe(rx_pipe_free_id),
    .free_reasm(reasm_free_valid), .free_id_reasm(reasm_free_id),
    .free_pb0(pb_free0 && !RX_CHAIN_ENABLE), .free_id_pb0(pb_free0_id),
    .free_pb1(pool_free_pb1 && !RX_CHAIN_ENABLE), .free_id_pb1(pool_free_pb1_id),
    .free_spill(pool_free_spill && !RX_CHAIN_ENABLE), .free_id_spill(pool_free_spill_id),
    .alloc_chain(reasm_chain_alloc), .alloc_chain_count(3'd5),
    .valid_chain(reasm_chain_valid), .chain_blocks(reasm_chain_alloc_blocks),
    .chain_count(reasm_chain_alloc_count), .free_chain_mask(rx_chain_free_mask),
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
  // P08：分片元数据（来自 mac_rx_if）
  wire [15:0] rxd_ident_a, rxd_ident_b;
  wire        rxd_mf_a, rxd_mf_b, rxd_df_a, rxd_df_b;
  wire [12:0] rxd_foff_a, rxd_foff_b;
  wire        rxd_isfrag_a, rxd_isfrag_b, rxd_first_a, rxd_first_b;
  wire rxd_net_a, rxd_net_b, rx_frame_err_a, rx_frame_err_b;
  mac_rx_if #(.IF_MODE(IF_MODE), .FCS_MODE(FCS_MODE), .MAX_FRAME(MAX_FRAME), .NET_ID(0), .PHY_ERROR_EN(IF_MODE == 2 ? 1 : 0))
  u_mac_rx_a (
    .clk(clk), .rst_sync(rst_sync), .enable(rx_stream_en), .udp_csum_en(udp_cfg_r[1]),
    .tb_us(rtc64[23:0]), .rx_data(rx_mac_data_a), .rx_valid(rx_mac_valid_a), .rx_ready(rx_ready),
    .rx_frame_error(rx_mac_error_a),
    .rx_blk(rx_blk_a), .rx_blk_valid(rx_blk_vld_a && rx_room_a), .frame_busy(rx_busy_a),
    .pmem_wr_en(rxw_en_a), .pmem_wr_addr(rxw_addr_a),
    .pmem_wr_data(rxw_data_a), .pmem_wr_be(rxw_be_a),
    .blk_release(rx_rel_a), .blk_release_id(rx_rel_id_a),
    .desc_vld(rxd_vld_a), .desc_blk(rxd_blk_a), .desc_len(rxd_len_a),
    .desc_ts(rxd_ts_a), .desc_vlid(rxd_vlid_a), .desc_sn(rxd_sn_a),
    .desc_net(rxd_net_a), .desc_ifid(rxd_ifid_a),
    .desc_src_ip(rxd_src_a), .desc_dst_ip(rxd_dst_a),
    .desc_sport(rxd_sport_a), .desc_dport(rxd_dport_a), .desc_plen(rxd_plen_a),
    .desc_ident(rxd_ident_a), .desc_mf(rxd_mf_a), .desc_df(rxd_df_a),
    .desc_frag_off(rxd_foff_a), .desc_is_frag(rxd_isfrag_a), .desc_first_frag(rxd_first_a),
    .frame_err(rx_frame_err_a), .crc_err(rx_crc_err_a),
    .drop_reason(rx_drop_reason_a), .good_cnt(), .drop_cnt(), .disabled_cnt());
  mac_rx_if #(.IF_MODE(IF_MODE), .FCS_MODE(FCS_MODE), .MAX_FRAME(MAX_FRAME), .NET_ID(1), .PHY_ERROR_EN(IF_MODE == 2 ? 1 : 0))
  u_mac_rx_b (
    .clk(clk), .rst_sync(rst_sync), .enable(rx_stream_en && (DUAL_NET_EN != 0)),
    .udp_csum_en(udp_cfg_r[1]), .tb_us(rtc64[23:0]),
    .rx_data(rx_mac_data_b), .rx_valid(rx_mac_valid_b), .rx_ready(rx_ready_b),
    .rx_frame_error(rx_mac_error_b),
    .rx_blk(rx_blk_b), .rx_blk_valid(rx_blk_vld_b && rx_room_b), .frame_busy(rx_busy_b),
    .pmem_wr_en(rxw_en_b), .pmem_wr_addr(rxw_addr_b),
    .pmem_wr_data(rxw_data_b), .pmem_wr_be(rxw_be_b),
    .blk_release(rx_rel_b), .blk_release_id(rx_rel_id_b),
    .desc_vld(rxd_vld_b), .desc_blk(rxd_blk_b), .desc_len(rxd_len_b),
    .desc_ts(rxd_ts_b), .desc_vlid(rxd_vlid_b), .desc_sn(rxd_sn_b),
    .desc_net(rxd_net_b), .desc_ifid(rxd_ifid_b),
    .desc_src_ip(rxd_src_b), .desc_dst_ip(rxd_dst_b),
    .desc_sport(rxd_sport_b), .desc_dport(rxd_dport_b), .desc_plen(rxd_plen_b),
    .desc_ident(rxd_ident_b), .desc_mf(rxd_mf_b), .desc_df(rxd_df_b),
    .desc_frag_off(rxd_foff_b), .desc_is_frag(rxd_isfrag_b), .desc_first_frag(rxd_first_b),
    .frame_err(rx_frame_err_b), .crc_err(rx_crc_err_b),
    .drop_reason(rx_drop_reason_b), .good_cnt(), .drop_cnt(), .disabled_cnt());
  wire [RXD_W-1:0] rx_desc_in_a = {rxd_ident_a, rxd_mf_a, rxd_df_a, rxd_foff_a, rxd_isfrag_a,
                                rxd_first_a, 1'b0,
                                rxd_plen_a,rxd_blk_a,rxd_len_a,rxd_ts_a,rxd_vlid_a,rxd_sn_a,
                                rxd_net_a,rxd_ifid_a,rxd_src_a,rxd_dst_a,
                                rxd_sport_a,rxd_dport_a};
  wire [RXD_W-1:0] rx_desc_in_b = {rxd_ident_b, rxd_mf_b, rxd_df_b, rxd_foff_b, rxd_isfrag_b,
                                rxd_first_b, 1'b0,
                                rxd_plen_b,rxd_blk_b,rxd_len_b,rxd_ts_b,rxd_vlid_b,rxd_sn_b,
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
  rx_vl_lookup #(.DW(RXD_W),.NUM_RX_VL(NUM_RX_VL),.HASH_BUCKETS(HASH_BUCKETS)) u_rxlookup (
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
  // FLT 判决（§7.8 S2）：w0/w1 来自 u_rxcfg_flt*（RD_NEG）；out_w0 随帧下传。
  rx_flt #(.DW(RXD_W), .NUM_RX_VL(NUM_RX_VL)) u_rxflt (
    .clk(clk), .rst_sync(rst_sync), .init_we(init_we),
    .in_vld(lookup_out_vld), .in_ready(flt_in_ready),
    .in_hit(lookup_out_hit), .in_vl(lookup_out_vl),
    .in_desc(lookup_out_desc),
    .in_w0(rxq_flt_w0),
    .in_w1(rxq_flt_w1),
    .out_vld(flt_out_vld), .out_ready(flt_out_ready),
    .out_pass(flt_out_pass), .out_reason(flt_out_reason),
    .out_vl(flt_out_vl), .out_desc(flt_out_desc), .out_w0(flt_out_w0));
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
  wire [31:0] rm_in_w0 = ic_to_rm ? ic_hold_w0 : flt_out_w0;
  always @(posedge clk) begin
    if (rst_sync) begin
      ic_hold_w0 <= 32'd0; rm_hold_w0 <= 32'd0;
    end else begin
      if (ic_in_vld && ic_in_ready) ic_hold_w0 <= flt_out_w0;
      if (rm_in_vld && rm_in_ready) rm_hold_w0 <= rm_in_w0;
    end
  end
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
  // -------------------------------------------------------------------
  // P08：IPv4 分片重组（rx_rm forward → 重组 → 解析）
  // 控制位 ctl_r[7] = RX_REASM_EN：
  //   0 → 本模块旁路，RM 输出直连解析（与接线前逐拍等价，既有回归不受影响）；
  //   1 → 分片在此汇聚，完整后才交付解析；单帧（is_frag=0）仍直通。
  // 状态/连线已在文件头声明（供 0xAC2A~0xAC2F 观测窗引用）。
  // -------------------------------------------------------------------
  assign reasm_en     = ctl_r[7];
  assign reasm_in_vld = reasm_en && rm_out_vld && rm_out_fwd;
  // Local P7 (2005), attachment 2, printed p119: fixed reassembly timeout
  // is not applicable ("Time out is not used for reassembly"). Disable the
  // optional engineering timer; the former 65535-cycle setting expired in
  // 524 us, before even a 1 ms BAG. Incomplete contexts remain bounded by
  // the slot/block pools; completion/error/disable/system reset reclaim them.
  // Contest P7 edition is unspecified; do not claim edition certification.
  rx_reassembly #(.DW(RXD_W), .SLOTS(8), .MAX_BYTES(8192), .TIMEOUT_TICKS(0),
                  .COPY_ENABLE(1), .CHECK_ENABLE(1), .MAX_FRAGS(16), .PMEM_BLOCK_BYTES(2048))
  u_rxreasm (
    .clk(clk), .rst_sync(rst_sync), .en(reasm_en && !RX_CHAIN_ENABLE),
    .in_vld(reasm_in_vld && !RX_CHAIN_ENABLE), .in_ready(legacy_reasm_ready),
    .in_desc(rm_out_desc), .in_vl(rm_out_vl),
    .out_vld(legacy_reasm_vld),
    .out_ready((reasm_out_drop || reasm_draining) ? 1'b1 : prs_in_ready),
    .out_drop(legacy_reasm_drop), .out_reason(legacy_reasm_reason),
    .out_desc(legacy_reasm_desc), .out_vl(legacy_reasm_vl),
    .copy_req_valid(legacy_copy_valid), .copy_req_ready(legacy_copy_ready),
    .copy_src_blk(legacy_copy_src), .copy_src_byte(legacy_copy_src_byte),
    .copy_dst_blk(legacy_copy_dst), .copy_dst_byte(legacy_copy_dst_byte),
    .copy_len(legacy_copy_len), .copy_done(legacy_copy_done),
    .check_req_valid(legacy_check_valid), .check_req_ready(reasm_check_ready),
    .check_blk(legacy_check_blk), .check_app_len(legacy_check_len),
    .check_src_ip(legacy_check_src), .check_dst_ip(legacy_check_dst),
    .check_done(reasm_check_done), .check_good(reasm_check_good),
    .check_reason(reasm_check_reason),
    .free_blk_valid(legacy_free_valid), .free_blk_id(legacy_free_id),
    .hit_cnt(legacy_hit_cnt), .drop_cnt(legacy_drop_cnt),
    .drain_active(legacy_reasm_drain),
    .slot_used(legacy_slot_used));
  rx_pmem_copy_engine u_rxpmemcopy (
    .clk(clk), .rst_sync(rst_sync),
    .job_valid(legacy_copy_valid && !RX_CHAIN_ENABLE), .job_ready(legacy_copy_ready),
    .job_src_blk(legacy_copy_src), .job_src_byte(legacy_copy_src_byte),
    .job_dst_blk(legacy_copy_dst), .job_dst_byte(legacy_copy_dst_byte),
    .job_len(legacy_copy_len),
    .rd_req(legacy_copy_rd_req), .rd_addr(legacy_copy_rd_addr), .rd_grant(copy_rd_grant && !RX_CHAIN_ENABLE),
    .rd_valid(copy_rd_valid && !RX_CHAIN_ENABLE), .rd_data(pmem_data_a),
    .wr_valid(legacy_copy_wr_valid), .wr_addr(legacy_copy_wr_addr), .wr_data(legacy_copy_wr_data),
    .wr_be(legacy_copy_wr_be), .wr_grant(copy_wr_grant && !RX_CHAIN_ENABLE), .done(legacy_copy_done));
  rx_udp_checksum_engine #(.CHAIN_ENABLE(RX_CHAIN_ENABLE)) u_rxudpcheck (
    .clk(clk), .rst_sync(rst_sync),
    .job_valid(reasm_check_valid), .job_ready(reasm_check_ready),
    .job_blk(reasm_check_blk), .job_app_len(reasm_check_app_len),
    .job_blocks(reasm_check_blocks), .job_block_count(reasm_check_block_count),
    .job_src_ip(reasm_check_src_ip), .job_dst_ip(reasm_check_dst_ip),
    .job_check_en(udp_cfg_r[1]),
    .rd_req(check_rd_req), .rd_addr(check_rd_addr), .rd_grant(check_rd_grant),
    .rd_valid(check_rd_valid_q), .rd_data(pmem_data_a),
    .done(reasm_check_done), .good(reasm_check_good), .reason(reasm_check_reason));
  generate if (RX_CHAIN_ENABLE) begin : g_rx_chain
    rx_reassembly_chain #(.DW(RXD_W), .SLOTS(8), .MAX_FRAGS(16)) u_reasm (
      .clk(clk), .rst_sync(rst_sync), .en(reasm_en),
      .in_vld(reasm_in_vld), .in_ready(chain_reasm_ready),
      .in_desc(rm_out_desc), .in_vl(rm_out_vl),
      .out_vld(chain_reasm_vld), .out_ready(prs_in_ready),
      .out_drop(chain_reasm_drop), .out_reason(chain_reasm_reason),
      .out_desc(chain_reasm_desc), .out_vl(chain_reasm_vl),
      .out_app_len(chain_out_app_len), .out_blocks(chain_out_blocks), .out_block_count(chain_out_block_count),
      .alloc_chain(reasm_chain_alloc), .alloc_chain_count(), .valid_chain(reasm_chain_valid),
      .chain_blocks(reasm_chain_alloc_blocks), .chain_count(reasm_chain_alloc_count),
      .copy_req_valid(chain_copy_valid), .copy_req_ready(chain_copy_ready),
      .copy_src_blk(chain_copy_src), .copy_src_byte(chain_copy_src_byte),
      .copy_dst_blocks(reasm_copy_dst_blocks), .copy_dst_count(reasm_copy_dst_count),
      .copy_dst_byte(chain_copy_dst_byte), .copy_len(chain_copy_len),
      .copy_done(chain_copy_done), .copy_error(chain_copy_error),
      .check_req_valid(chain_check_valid), .check_req_ready(reasm_check_ready),
      .check_blk(chain_check_blk), .check_blocks(reasm_check_blocks), .check_block_count(reasm_check_block_count),
      .check_app_len(chain_check_len), .check_src_ip(chain_check_src), .check_dst_ip(chain_check_dst),
      .check_done(reasm_check_done), .check_good(reasm_check_good), .check_reason(reasm_check_reason),
      .free_blk_valid(chain_free_valid), .free_blk_id(chain_free_id), .drain_active(chain_reasm_drain),
      .hit_cnt(chain_hit_cnt), .drop_cnt(chain_drop_cnt), .slot_used(chain_slot_used));
    rx_pmem_scatter_copy u_copy (
      .clk(clk), .reset(rst_sync), .cancel(1'b0),
      .job_valid(chain_copy_valid), .job_ready(chain_copy_ready),
      .src_blk(chain_copy_src), .src_byte(chain_copy_src_byte),
      .dst_blocks(reasm_copy_dst_blocks), .dst_count(reasm_copy_dst_count),
      .dst_byte(chain_copy_dst_byte), .len(chain_copy_len),
      .done(chain_copy_done), .error(chain_copy_error), .cancelled(),
      .rd_req(chain_copy_rd_req), .rd_grant(copy_rd_grant), .rd_valid(copy_rd_valid),
      .rd_data(pmem_data_a), .rd_addr(chain_copy_rd_addr),
      .wr_valid(chain_copy_wr_valid), .wr_grant(copy_wr_grant),
      .wr_addr(chain_copy_wr_addr), .wr_data(chain_copy_wr_data), .wr_be(chain_copy_wr_be));
    rx_chain_metadata u_metadata (
      .clk(clk), .rst_sync(rst_sync),
      .register_valid(prs_in_vld_sel && prs_in_ready),
      .register_head(prs_in_desc_sel[162:159]),
      .register_blocks(prs_in_blocks), .register_count(prs_in_block_count),
      .release0_valid(pb_free0), .release0_id(pb_free0_id),
      .release1_valid(pb_free1), .release1_id(pb_free1_id),
      .release2_valid(mgmt_free_req && mgmt_free_take), .release2_id(mgmt_free_id),
      .free_mask(rx_chain_free_mask), .lookup_block(host_addr[3:0]), .lookup_word(rx_chain_lookup_word));
  end else begin : g_rx_chain_off
    assign chain_reasm_ready=1'b0;
    assign chain_reasm_vld=1'b0; assign chain_reasm_drop=1'b0; assign chain_reasm_reason=4'd0;
    assign chain_reasm_desc={RXD_W{1'b0}}; assign chain_reasm_vl=12'd0; assign chain_reasm_drain=1'b0;
    assign chain_out_app_len=14'd0; assign chain_out_blocks=20'd0; assign chain_out_block_count=3'd0;
    assign reasm_chain_alloc=1'b0;
    assign chain_copy_valid=1'b0; assign chain_copy_src=4'd0; assign chain_copy_src_byte=11'd0;
    assign reasm_copy_dst_blocks=20'd0; assign reasm_copy_dst_count=3'd0;
    assign chain_copy_dst_byte=14'd0; assign chain_copy_len=14'd0;
    assign chain_copy_ready=1'b0; assign chain_copy_done=1'b0; assign chain_copy_error=1'b0;
    assign chain_check_valid=1'b0; assign chain_check_blk=4'd0; assign chain_check_len=14'd0;
    assign reasm_check_blocks=20'd0; assign reasm_check_block_count=3'd0;
    assign chain_check_src=32'd0; assign chain_check_dst=32'd0;
    assign chain_free_valid=1'b0; assign chain_free_id=4'd0;
    assign chain_hit_cnt=32'd0; assign chain_drop_cnt=32'd0; assign chain_slot_used=32'd0;
    assign chain_copy_rd_req=1'b0; assign chain_copy_rd_addr=13'd0;
    assign chain_copy_wr_valid=1'b0; assign chain_copy_wr_addr=13'd0;
    assign chain_copy_wr_data=32'd0; assign chain_copy_wr_be=4'd0;
    assign rx_chain_free_mask=16'd0; assign rx_chain_lookup_word=32'd0;
  end endgenerate
  assign reasm_in_ready=RX_CHAIN_ENABLE ? chain_reasm_ready : legacy_reasm_ready;
  assign reasm_out_vld=RX_CHAIN_ENABLE ? chain_reasm_vld : legacy_reasm_vld;
  assign reasm_out_drop=RX_CHAIN_ENABLE ? chain_reasm_drop : legacy_reasm_drop;
  assign reasm_out_reason=RX_CHAIN_ENABLE ? chain_reasm_reason : legacy_reasm_reason;
  assign reasm_out_desc=RX_CHAIN_ENABLE ? chain_reasm_desc : legacy_reasm_desc;
  assign reasm_out_vl=RX_CHAIN_ENABLE ? chain_reasm_vl : legacy_reasm_vl;
  assign reasm_draining=RX_CHAIN_ENABLE ? chain_reasm_drain : legacy_reasm_drain;
  assign reasm_out_app_len=RX_CHAIN_ENABLE ? chain_out_app_len : {3'd0,legacy_reasm_desc[173:163]};
  assign reasm_out_blocks=RX_CHAIN_ENABLE ? chain_out_blocks : {16'd0,legacy_reasm_desc[162:159]};
  assign reasm_out_block_count=RX_CHAIN_ENABLE ? chain_out_block_count : 3'd1;
  assign reasm_copy_valid=RX_CHAIN_ENABLE ? chain_copy_valid : legacy_copy_valid;
  assign reasm_copy_ready=RX_CHAIN_ENABLE ? chain_copy_ready : legacy_copy_ready;
  assign reasm_copy_done=RX_CHAIN_ENABLE ? chain_copy_done : legacy_copy_done;
  assign reasm_copy_src_blk=RX_CHAIN_ENABLE ? chain_copy_src : legacy_copy_src;
  assign reasm_copy_src_byte=RX_CHAIN_ENABLE ? {2'd0,chain_copy_src_byte} : legacy_copy_src_byte;
  assign reasm_copy_dst_blk=RX_CHAIN_ENABLE ? reasm_copy_dst_blocks[3:0] : legacy_copy_dst;
  assign reasm_copy_dst_byte=RX_CHAIN_ENABLE ? chain_copy_dst_byte[12:0] : legacy_copy_dst_byte;
  assign reasm_copy_len=RX_CHAIN_ENABLE ? chain_copy_len : legacy_copy_len;
  assign reasm_check_valid=RX_CHAIN_ENABLE ? chain_check_valid : legacy_check_valid;
  assign reasm_check_blk=RX_CHAIN_ENABLE ? chain_check_blk : legacy_check_blk;
  assign reasm_check_app_len=RX_CHAIN_ENABLE ? chain_check_len : legacy_check_len;
  assign reasm_check_src_ip=RX_CHAIN_ENABLE ? chain_check_src : legacy_check_src;
  assign reasm_check_dst_ip=RX_CHAIN_ENABLE ? chain_check_dst : legacy_check_dst;
  assign reasm_free_valid=RX_CHAIN_ENABLE ? chain_free_valid : legacy_free_valid;
  assign reasm_free_id=RX_CHAIN_ENABLE ? chain_free_id : legacy_free_id;
  assign reasm_hit_cnt=RX_CHAIN_ENABLE ? chain_hit_cnt : legacy_hit_cnt;
  assign reasm_drop_cnt=RX_CHAIN_ENABLE ? chain_drop_cnt : legacy_drop_cnt;
  assign reasm_slot_used=RX_CHAIN_ENABLE ? chain_slot_used : legacy_slot_used;
  assign copy_rd_req=RX_CHAIN_ENABLE ? chain_copy_rd_req : legacy_copy_rd_req;
  assign copy_rd_addr=RX_CHAIN_ENABLE ? chain_copy_rd_addr : legacy_copy_rd_addr;
  assign copy_wr_valid=RX_CHAIN_ENABLE ? chain_copy_wr_valid : legacy_copy_wr_valid;
  assign copy_wr_addr=RX_CHAIN_ENABLE ? chain_copy_wr_addr : legacy_copy_wr_addr;
  assign copy_wr_data=RX_CHAIN_ENABLE ? chain_copy_wr_data : legacy_copy_wr_data;
  assign copy_wr_be=RX_CHAIN_ENABLE ? chain_copy_wr_be : legacy_copy_wr_be;
  always @(posedge clk) begin
    if (rst_sync) reasm_hold_w0 <= 32'd0;
    else if (reasm_in_vld && reasm_in_ready) reasm_hold_w0 <= rm_hold_w0;
  end
  // 旁路/使能二选一：旁路时 RM 输出直连解析，使能时由重组级馈送。
  // 使能路径下 RM 必须等重组级就绪，故 rm_out_ready 取 reasm_in_ready；
  // 旁路路径下 reasm_in_ready 恒 1（en=0 时组合展开为 1），等价于原 prs_in_ready。
  assign prs_in_desc_sel = reasm_en ? reasm_out_desc : rm_out_desc;
  assign prs_in_app_len = reasm_en ? reasm_out_app_len : {3'd0,rm_out_desc[173:163]};
  assign prs_in_blocks = reasm_en ? reasm_out_blocks : {16'd0,rm_out_desc[162:159]};
  assign prs_in_block_count = reasm_en ? reasm_out_block_count : 3'd1;
  assign prs_in_vld_sel = reasm_en ? (reasm_out_vld && !reasm_out_drop && !reasm_draining)
                                              : (rm_out_vld && rm_out_fwd);
  // RM may accept the following descriptor while copy/check holds this one.
  // Capture the closing fragment's configuration at the reassembly handshake.
  wire [31:0] prs_w0  = reasm_en ? reasm_hold_w0 : rm_hold_w0;
  // RM → 重组（P08）→ 解析（§7.12）→ 端口（§7.13），v0.5.16。RM forward 帧等待
  // 重组级，重复副本立即回收（free_pipe 最高优先）；解析丢弃与端口侧释放经
  // rx_port_buf 的两个独立释放口归还，不占 free_pipe。
  assign rm_out_ready = rm_out_fwd ? (reasm_en ? reasm_in_ready : prs_in_ready) : 1'b1;
  assign rm_fire      = rm_out_vld && rm_out_ready;
  assign rm_dup_fire  = rm_out_vld && !rm_out_fwd;
  wire [7:0]  prs_pb  = prs_w0[19:12];
  // mgmt_sap_rx exports one shared source-IP register. Keep new SAP
  // descriptors behind both protocol engines until they can accept another
  // request and no previous response is pending; otherwise a later request
  // can replace the peer address before the prior response is committed/read.
  assign sap_engine_ready = ((SNMP_EN == 0) || (snmp_in_ready && !snmp_resp_vld)) &&
                            ((TFTP_EN == 0) ||
                             (fe_sap_route ? fe_sap_ready : tftp_in_ready));
  assign sap_in_ready = sap_core_in_ready && sap_engine_ready;
  // mgmt_sap_rx exposes only its local state as in_ready. If the protocol
  // engine vetoes a descriptor, suppress valid at that boundary too; otherwise
  // the held parser descriptor can be sampled repeatedly while sap_core_in_ready
  // returns high between payload copies.
  assign sap_engine_vld = prs_to_sap && sap_engine_ready;
  rx_ip_udp_parse #(.DW(RXD_W), .NUM_PORTS(NUM_PORTS), .CHAIN_ENABLE(RX_CHAIN_ENABLE)) u_rxprs (
    .clk(clk), .rst_sync(rst_sync),
    .in_vld(prs_in_vld_sel), .in_ready(prs_in_ready),
    .in_desc(prs_in_desc_sel), .in_w0(prs_w0),
    .port_w0({port_w0_sh[prs_pb][3], 12'd0, port_w0_sh[prs_pb][2], port_w0_sh[prs_pb][1:0], 16'd0}),
    .port_w1({16'd0, port_w1_dport[prs_pb]}),
    .port_w3({28'd0, port_w3_dep[prs_pb]}), .sap_enable(ctl_r[8]),
        .out_vld(prs_out_vld), .out_ready(prs_to_sap ? sap_in_ready : pb_in_ready),
    .out_drop(prs_out_drop), .out_reason(prs_out_reason), .out_port(prs_out_port),
    .out_type(prs_out_type), .out_depth(prs_out_depth), .out_blk(prs_out_blk),
    .out_plen(prs_out_plen), .out_ts(prs_out_ts),
    .in_app_len(prs_in_app_len), .in_blocks(prs_in_blocks), .in_block_count(prs_in_block_count),
    .out_app_len(prs_out_app_len), .out_blocks(prs_out_blocks), .out_block_count(prs_out_block_count));
    assign prs_to_sap  = prs_out_vld && !prs_out_drop && (prs_out_type == 2'd2);
  assign prs_to_port = prs_out_vld && !prs_to_sap;
  // P02：SAP 字节级背压（驱动器在管理面小节，见 sap_out_ready assign）。
  wire sap_out_ready;
  mgmt_sap_rx #(.PAY_OFF(42), .PBUF_W(160), .CHAIN_ENABLE(RX_CHAIN_ENABLE)) u_mgmt_sap (
    .pm_req(sap_pm_req), .pm_addr(sap_pm_addr), .pm_gnt(sap_pm_gnt),
    .pm_data(pmem_data_a),
    .out_vld(sap_out_vld), .out_sop(sap_out_sop), .out_eop(sap_out_eop),
    .out_data(sap_out_data), .out_sport(sap_out_sport), .out_dport(sap_out_dport),
    .out_srcip(sap_out_srcip), .out_plen(), .out_app_len(), .out_ready(sap_out_ready),
    .pay_cnt(mgmt_pay_cnt), .trunc_cnt(),
    .clk(clk), .rst_sync(rst_sync), .in_vld(sap_engine_vld), .in_ready(sap_core_in_ready),
    .in_port(prs_out_port), .in_blk(prs_out_blk), .in_plen(prs_out_plen),
    .in_app_len(prs_out_app_len), .in_blocks(prs_out_blocks), .in_block_count(prs_out_block_count),
    .free_req(mgmt_free_req), .free_take(mgmt_free_take), .free_id(mgmt_free_id),
    .accept_cnt(mgmt_accept_cnt), .free_cnt(mgmt_free_cnt), .last_desc(mgmt_last_desc));
  rx_port_buf #(.NUM_PORTS(NUM_PORTS), .CHAIN_ENABLE(RX_CHAIN_ENABLE)) u_rxpb (
    .clk(clk), .rst_sync(rst_sync),
    .init_we(init_we && (init_target == 3'd6)), .init_addr(init_addr),
        .in_vld(prs_to_port), .in_ready(pb_in_ready), .in_drop(prs_out_drop),
    .in_port(prs_out_port), .in_type(prs_out_type), .in_depth(prs_out_depth),
    .in_blk(prs_out_blk), .in_plen(prs_out_plen),
    .in_app_len(prs_out_app_len), .in_block_count(prs_out_block_count),
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

  // ST_TAKE 的 ack 沿锁存 start_vl；ST_HOLD 一拍把 TX 表读口切到该 VL；
  // ST_GO/start_vld 用上一拍读出的 txq_h*（与构建器共用，不再镜像 b*）。
  wire sch_start_vld, sch_bag_viol, sch_enable;
  wire [7:0] sch_start_vl, sch_valid_cnt;
  wire [3:0] sch_start_blk;
  wire [12:0] sch_start_len;
  wire [15:0] sch_miss_cnt;
  reg [1:0] active_net_mode;
  wire [9:0] start_cfg_base = sch_start_vl[6:0] * 10'd5;
  always @(posedge clk) begin
    if (rst_sync) active_net_mode <= 2'b01;
    else if (sch_start_vld) active_net_mode <= DUAL_NET_EN ? txq_b0[1:0] : 2'b01;
  end
  // continue11：调度器配置写打一拍（VL 号、基址、valid 先寄存），读 w1/w4 的地址
  // 来自寄存器而非 host_addr 减法/除 5/乘 5。寄存拍内 tx_cfg_mem 的新写要到下一沿
  // 才生效，故读到的 w1/w4 与原先 w0 写拍读到的值相同（配置期，调度器未使能）。
  reg [6:0] cfg_sch_vl;
  reg [9:0] cfg_sch_base;
  reg       cfg_sch_we, cfg_sch_valid;
  always @(posedge clk) begin
    if (rst_sync) cfg_sch_we <= 1'b0;
    else          cfg_sch_we <= budget_w0_write;
    cfg_sch_vl    <= tx_idx / 10'd5;
    cfg_sch_base  <= {3'd0, budget_vl} * 10'd5;
    cfg_sch_valid <= host_wdata[31];
  end
  reg       cfg_sch_we_d, cfg_sch_we_d2;
  reg [6:0] cfg_sch_vl_d;
  reg       cfg_sch_valid_d;
  always @(posedge clk) begin
    if (rst_sync) begin
      cfg_sch_we_d  <= 1'b0;
      cfg_sch_we_d2 <= 1'b0;
    end else begin
      cfg_sch_we_d  <= cfg_sch_we;
      cfg_sch_we_d2 <= cfg_sch_we_d;
    end
    cfg_sch_vl_d    <= cfg_sch_vl;
    cfg_sch_valid_d <= cfg_sch_valid;
  end
  // TX w0–w4：一份 128×32。主机用 budget_vl（仅 tx_hit 时有意义）。
  // HOLD+GO 两拍切到 start_vl：构建器在 start_vld 后一拍采样，不能让
  // MSG_WR 等非表地址污染 budget_vl。删 u_txcfg_b0..b4。
  wire [TXA-1:0] txc_rd_addr = sch_start_cfg_rd ? sch_start_vl[TXA-1:0]
                                               : budget_vl[TXA-1:0];
  bram_1w1r #(.W(32), .D(NUM_TX_VL), .RD_NEG(0)) u_txcfg_h0 (
    .clk(clk), .wr_en(txc_we0), .wr_addr(txc_waddr), .wr_data(txc_w0_data),
    .rd_addr(txc_rd_addr), .rd_data(txq_h0));
  bram_1w1r #(.W(32), .D(NUM_TX_VL), .RD_NEG(0)) u_txcfg_h1 (
    .clk(clk), .wr_en(txc_we1), .wr_addr(txc_waddr), .wr_data(txc_w1_data),
    .rd_addr(txc_rd_addr), .rd_data(txq_h1));
  bram_1w1r #(.W(32), .D(NUM_TX_VL), .RD_NEG(0)) u_txcfg_h2 (
    .clk(clk), .wr_en(txc_we2), .wr_addr(txc_waddr), .wr_data(host_wdata),
    .rd_addr(txc_rd_addr), .rd_data(txq_h2));
  bram_1w1r #(.W(32), .D(NUM_TX_VL), .RD_NEG(0)) u_txcfg_h3 (
    .clk(clk), .wr_en(txc_we3), .wr_addr(txc_waddr), .wr_data(host_wdata),
    .rd_addr(txc_rd_addr), .rd_data(txq_h3));
  bram_1w1r #(.W(32), .D(NUM_TX_VL), .RD_NEG(0)) u_txcfg_h4 (
    .clk(clk), .wr_en(txc_we4), .wr_addr(txc_waddr), .wr_data(host_wdata),
    .rd_addr(txc_rd_addr), .rd_data(txq_h4));
  assign txq_b0 = txq_h0;
  assign txq_b1 = txq_h1;
  assign txq_b2 = txq_h2;
  assign txq_b3 = txq_h3;
  assign txq_b4 = txq_h4;
  // BAG / port：32-bit 同相读。Passkey 对 RD_NEG=1 窄口常落 LUT。
  // SNMP GET 与调度写配置已各加一拍，读数据在消费沿之前稳定。
  bram_1w1r #(.W(32), .D(NUM_TX_VL), .RD_NEG(0)) u_txcfg_bag_n (
    .clk(clk), .wr_en(txc_we1), .wr_addr(txc_waddr), .wr_data(txc_w1_data),
    .rd_addr(snmp_bag_raddr), .rd_data(txq_bag));
  bram_1w1r #(.W(32), .D(NUM_TX_VL), .RD_NEG(0)) u_txcfg_bag_s (
    .clk(clk), .wr_en(txc_we1), .wr_addr(txc_waddr), .wr_data(txc_w1_data),
    .rd_addr(cfg_sch_vl[TXA-1:0]), .rd_data(txq_bag_s));
  bram_1w1r #(.W(32), .D(NUM_TX_VL), .RD_NEG(0)) u_txcfg_port (
    .clk(clk), .wr_en(txc_we4), .wr_addr(txc_waddr), .wr_data(host_wdata),
    .rd_addr(cfg_sch_vl[TXA-1:0]), .rd_data(txq_port_w));
  bram_1w1r #(.W(32), .D(NUM_PORTS), .RD_NEG(0)) u_pcfg_h0 (
    .clk(clk), .wr_en(pcc_we0), .wr_addr(pcc_waddr), .wr_data(pcc_wdata),
    .rd_addr(port_idx[PA+1:2]), .rd_data(pcq_h0));
  bram_1w1r #(.W(32), .D(NUM_PORTS), .RD_NEG(0)) u_pcfg_h1 (
    .clk(clk), .wr_en(pcc_we1), .wr_addr(pcc_waddr), .wr_data(pcc_wdata),
    .rd_addr(port_idx[PA+1:2]), .rd_data(pcq_h1));
  bram_1w1r #(.W(32), .D(NUM_PORTS), .RD_NEG(0)) u_pcfg_h2 (
    .clk(clk), .wr_en(pcc_we2), .wr_addr(pcc_waddr), .wr_data(pcc_wdata),
    .rd_addr(port_idx[PA+1:2]), .rd_data(pcq_h2));
  bram_1w1r #(.W(32), .D(NUM_PORTS), .RD_NEG(0)) u_pcfg_h3 (
    .clk(clk), .wr_en(pcc_we3), .wr_addr(pcc_waddr), .wr_data(pcc_wdata),
    .rd_addr(port_idx[PA+1:2]), .rd_data(pcq_h3));
  // Commit to the table AND scheduler on the same accepted edge. Previously
  // only tx_cfg_mem changed and the scheduler kept its old BAG indefinitely.
  assign snmp_bag_commit = snmp_bag_we_q && init_done && !rst_sync &&
                           !cfg_sch_we && !(cfg_write && tx_hit);
  assign snmp_set_ack = snmp_ctl_we || snmp_bag_commit;
  wire [NUM_PORTS-1:0] sched_ready = sch_enable ? pb_req : {NUM_PORTS{1'b0}};
  assign sch_enable = init_done && ctl_r[0] && !ctl_r[13];
  wire fb_done, fb_len_err;
  wire rm_frame_start;
  wire sch_frame_permit;
  tx_vl_scheduler #(.NUM_TX_VL(NUM_TX_VL), .NUM_PORTS(NUM_PORTS),
                    .CYCLES_PER_US(CLK_FREQ_HZ / 1000000), .BAG_UPDATE_EN(1),
                    .PREPARE_CYCLES(IF_MODE == 2 ? 128 : 0)) u_sched (
    .clk(clk), .rst_sync(rst_sync), .enable(sch_enable && !snmp_set_active && !snmp_bag_we_q), .tb_us(rtc64[23:0]),
    .cfg_we(cfg_sch_we_d2 || snmp_bag_commit),
    .cfg_vl(snmp_bag_commit ? snmp_bag_vl_q : cfg_sch_vl_d), .cfg_valid(cfg_sch_valid_d),
    .cfg_bag_only(snmp_bag_commit),
    .cfg_bag_us(snmp_bag_commit ? snmp_bag_wdata_q : txq_bag_s[31:8]),
    .cfg_port(txq_port_w[23:16]),
    .port_ready(sched_ready),
    .sch_take(sch_take), .sch_port(sch_port), .sch_ack(pb_sch_ack),
    .sch_blk(pb_sch_blk), .sch_len(pb_sch_len),
    .start_vld(sch_start_vld), .start_vl(sch_start_vl),
    .start_blk(sch_start_blk), .start_len(sch_start_len),
    .builder_busy(fb_busy), .builder_len_err(fb_len_err), .frame_start(rm_frame_start),
    .frame_permit(sch_frame_permit),
    .bag_viol(sch_bag_viol), .bag_ovf_cnt(sch_bag_cnt),
    .take_miss_cnt(sch_miss_cnt), .vl_valid_cnt(sch_valid_cnt),
    .start_cfg_rd(sch_start_cfg_rd));

  wire snap_req, snap_ack, fb_out_vld, fb_out_sof, fb_out_eof, fb_out_rdy;
  wire [7:0] snap_vl, snap, fb_cur_vl, fb_byte_a, fb_byte_b;
  wire [15:0] fb_p1_stall;
  wire legacy_fb_busy,legacy_fb_done,legacy_fb_len_err,legacy_snap_req;
  wire legacy_fb_rd_en_a,legacy_fb_rd_en_b,legacy_fb_out_vld,legacy_fb_out_sof,legacy_fb_out_eof,legacy_fb_free;
  wire [7:0] legacy_fb_cur_vl,legacy_snap_vl,legacy_fb_byte_a,legacy_fb_byte_b;
  wire [12:0] legacy_fb_rd_addr_a,legacy_fb_rd_addr_b;
  wire [3:0] legacy_fb_free_blk;
  wire [15:0] legacy_fb_p1_stall;
  wire chain_fb_busy,chain_fb_done,chain_fb_error,chain_snap_req,chain_fb_req;
  wire chain_fb_vld,chain_fb_sof,chain_fb_eof;
  wire [7:0] chain_fb_vl,chain_snap_vl,chain_fb_byte_a,chain_fb_byte_b;
  wire [12:0] chain_fb_addr;
  assign fb_busy=TX_CHAIN_ENABLE ? chain_fb_busy : legacy_fb_busy;
  assign fb_done=TX_CHAIN_ENABLE ? chain_fb_done : legacy_fb_done;
  assign fb_len_err=TX_CHAIN_ENABLE ? chain_fb_error : legacy_fb_len_err;
  assign fb_cur_vl=TX_CHAIN_ENABLE ? chain_fb_vl : legacy_fb_cur_vl;
  assign snap_req=TX_CHAIN_ENABLE ? chain_snap_req : legacy_snap_req;
  assign snap_vl=TX_CHAIN_ENABLE ? chain_snap_vl : legacy_snap_vl;
  assign fb_rd_en_a=TX_CHAIN_ENABLE ? chain_fb_req : legacy_fb_rd_en_a;
  assign fb_rd_addr_a=TX_CHAIN_ENABLE ? chain_fb_addr : legacy_fb_rd_addr_a;
  assign fb_rd_en_b=TX_CHAIN_ENABLE ? 1'b0 : legacy_fb_rd_en_b;
  assign fb_rd_addr_b=TX_CHAIN_ENABLE ? 13'd0 : legacy_fb_rd_addr_b;
  assign fb_out_vld=TX_CHAIN_ENABLE ? chain_fb_vld : legacy_fb_out_vld;
  assign fb_out_sof=TX_CHAIN_ENABLE ? chain_fb_sof : legacy_fb_out_sof;
  assign fb_out_eof=TX_CHAIN_ENABLE ? chain_fb_eof : legacy_fb_out_eof;
  assign fb_byte_a=TX_CHAIN_ENABLE ? chain_fb_byte_a : legacy_fb_byte_a;
  assign fb_byte_b=TX_CHAIN_ENABLE ? chain_fb_byte_b : legacy_fb_byte_b;
  assign fb_free=TX_CHAIN_ENABLE ? (chain_fb_done && tx_fragment_last) : legacy_fb_free;
  assign fb_free_blk=TX_CHAIN_ENABLE ? tx_fragment_head : legacy_fb_free_blk;
  assign fb_p1_stall=TX_CHAIN_ENABLE ? 16'd0 : legacy_fb_p1_stall;
  assign tx_fragment_done=TX_CHAIN_ENABLE && chain_fb_done;
  assign tx_fragment_error=TX_CHAIN_ENABLE && chain_fb_error;
  tx_sn_gen #(.NUM_TX_VL(NUM_TX_VL)) u_sn (
    .clk(clk), .rst_sync(rst_sync), .snap_req(snap_req), .snap_vl(snap_vl),
    .snap(snap), .snap_ack(snap_ack),
    .cancel(tx_fragment_error), .commit(fb_done), .commit_vl(fb_cur_vl),
    .init_all(1'b0), .ovr_we(1'b0), .ovr_vl(8'd0), .ovr_val(8'd0),
    .sn_pend(), .err());
  // VLID 的 P0 集成映射暂取 0x0100+表序号；任意 VLID 映射/配置脚本留 T12/T22 完整项。
  // §7.1.1 步 4：SAP 端口上的管理面响应，目的 IP/端口从最近请求反转；
  // sport 取该 SAP 端口表 w1 的管理 UDP 端口（与入向 DPORT 判决一致）。
  wire [7:0]  fb_cfg_port   = txq_b4[23:16];
  wire        fb_is_snmp    = (fb_cfg_port == SNMP_SAP_PORT[7:0]);
  wire        fb_is_tftp    = (fb_cfg_port == TFTP_SAP_PORT[7:0]);
  wire        fb_is_mgmt    = fb_is_snmp || fb_is_tftp;
  wire [15:0] fb_sap_dport  = port_w1_dport[fb_cfg_port];
  wire        fb_mgmt_meta  = mgmt_meta_valid[sch_start_blk];
  wire [31:0] fb_dst_ip     = fb_is_mgmt
                            ? (fb_mgmt_meta ? mgmt_meta_ip[sch_start_blk] : sap_out_srcip)
                            : txq_b3;
  wire [15:0] fb_dport      = (fb_is_mgmt && fb_mgmt_meta) ? mgmt_meta_port[sch_start_blk] :
                              fb_is_snmp ? snmp_peer_port :
                              fb_is_tftp ? tftp_resp_tid : txq_b2[31:16];
  wire [15:0] fb_sport      = fb_is_mgmt ? fb_sap_dport : txq_b2[15:0];
  generate if(TX_CHAIN_ENABLE) begin: g_tx_fragment
    tx_fragment_launch u_launch (
      .clk(clk),.rst_sync(rst_sync),.start(sch_start_vld),.start_vl(sch_start_vl),.start_head(sch_start_blk),
      .app_length(tx_sch_app_len),.fragment_offset(tx_sch_offset),.blocks(tx_sch_blocks),.identification(tx_sch_id),.block_count(tx_sch_count),
      .vlid(16'h0100+{8'd0,sch_start_vl}),.udi(smac_r[31:16]),.sport(fb_sport),.dport(fb_dport),
      .ifid_a(smac_r[2:0]),.ifid_b(smac_r[14:12]),.tos({3'd0,txq_b1[4:0]}),.ttl(8'd255),
      .src_ip(ip_r),.dst_ip(fb_dst_ip),.checksum_enable(udp_cfg_r[1]),
      .busy(chain_fb_busy),.done(chain_fb_done),.error(chain_fb_error),.current_vl(chain_fb_vl),.current_head(tx_fragment_head),
      .last_fragment(tx_fragment_last),.next_offset(tx_fragment_next),
      .snap_req(chain_snap_req),.snap_vl(chain_snap_vl),.snap(snap),.snap_ack(snap_ack),
      .pmem_req(chain_fb_req),.pmem_addr(chain_fb_addr),.pmem_grant(chain_fb_req && !rst_sync),.pmem_data(pmem_data_a),
      .out_valid(chain_fb_vld),.out_sof(chain_fb_sof),.out_eof(chain_fb_eof),
      .out_byte_a(chain_fb_byte_a),.out_byte_b(chain_fb_byte_b),.out_ready(fb_out_rdy)
    );
  end else begin: g_tx_fragment_disabled
    assign chain_fb_busy=0;assign chain_fb_done=0;assign chain_fb_error=0;assign chain_fb_vl=0;
    assign chain_snap_req=0;assign chain_snap_vl=0;assign chain_fb_req=0;assign chain_fb_addr=0;
    assign chain_fb_vld=0;assign chain_fb_sof=0;assign chain_fb_eof=0;assign chain_fb_byte_a=0;assign chain_fb_byte_b=0;
    assign tx_fragment_head=0;assign tx_fragment_last=0;assign tx_fragment_next=0;
  end endgenerate
  tx_frame_builder #(.BYTE_SLOT_CYC(IF_MODE ? 1 : BYTE_SLOT_CYC)) u_builder (
    .clk(clk), .rst_sync(rst_sync),
    .start_vld(sch_start_vld && !TX_CHAIN_ENABLE), .start_vl(sch_start_vl),
    .start_blk(sch_start_blk), .start_len(sch_start_len),
    .busy(legacy_fb_busy), .done(legacy_fb_done), .cur_vl(legacy_fb_cur_vl), .len_err(legacy_fb_len_err),
    .hdr_vlid(16'h0100+{8'd0,sch_start_vl}),
    .hdr_udi(smac_r[31:16]), .hdr_ifid_a(smac_r[2:0]), .hdr_ifid_b(smac_r[14:12]),
    .hdr_tos({3'd0,txq_b1[4:0]}), .hdr_ttl(8'd255), .hdr_ident(16'd0),
    .hdr_src_ip(ip_r), .hdr_dst_ip(fb_dst_ip),
    .hdr_sport(fb_sport), .hdr_dport(fb_dport),
    .hdr_udp_csum_en(udp_cfg_r[1]),
    .snap_req(legacy_snap_req), .snap_vl(legacy_snap_vl), .snap(snap), .snap_ack(snap_ack),
    .rd_en_a(legacy_fb_rd_en_a), .rd_addr_a(legacy_fb_rd_addr_a), .rd_data_a(pmem_data_a),
    .rd_en_b(legacy_fb_rd_en_b), .rd_addr_b(legacy_fb_rd_addr_b), .rd_data_b(pmem_data_b),
    .out_vld(legacy_fb_out_vld), .out_byte_a(legacy_fb_byte_a), .out_byte_b(legacy_fb_byte_b),
    .out_sof(legacy_fb_out_sof), .out_eof(legacy_fb_out_eof), .out_rdy(fb_out_rdy),
    .blk_free(legacy_fb_free), .blk_free_id(legacy_fb_free_blk), .p1_stall_cnt(legacy_fb_p1_stall));

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
  mac_tx_if #(.IF_MODE(IF_MODE), .FCS_MODE(FCS_MODE), .IFG_BYTES(IFG_BYTES), .PREAMBLE_EN(IF_MODE == 2), .START_GUARD_EN(IF_MODE == 2)) u_mac_a (
    .clk(clk), .rst_sync(rst_sync),
    .in_vld(rm_a_vld), .in_byte(rm_a_byte), .in_sof(rm_a_sof), .in_eof(rm_a_eof), .in_rdy(rm_a_rdy),
    .pace_en(pace_en), .start_permit(sch_frame_permit), .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready),
    .link_rdy(rx_ready), .frame_start(mac_a_start), .frame_done(mac_a_done),
    .busy(mac_a_busy), .underrun_cnt(mac_a_underrun));
  mac_tx_if #(.IF_MODE(IF_MODE), .FCS_MODE(FCS_MODE), .IFG_BYTES(IFG_BYTES), .PREAMBLE_EN(IF_MODE == 2), .START_GUARD_EN(IF_MODE == 2)) u_mac_b (
    .clk(clk), .rst_sync(rst_sync),
    .in_vld(rm_b_vld), .in_byte(rm_b_byte), .in_sof(rm_b_sof), .in_eof(rm_b_eof), .in_rdy(rm_b_rdy),
    .pace_en(pace_en), .start_permit(sch_frame_permit), .tx_data(tx_data_b), .tx_valid(tx_valid_b), .tx_ready(tx_ready_b),
    .link_rdy(rx_ready_b), .frame_start(mac_b_start), .frame_done(mac_b_done),
    .busy(mac_b_busy), .underrun_cnt(mac_b_underrun));
  assign dbg_frame_event = {2'b00, rm_frame_start, rm_frame_done};

  // =====================================================================
  // continue4：全局统计页 stats_regs（0x0100~0x01FF）
  // 事件源都取既有流水的握手拍，不新增反压，也不改变任何数据通路。
  // 已知边界：dmac / ip_csum / udp_csum 三类在当前 RX 链路没有独立判决源，
  // 对应计数器恒 0；同拍两网同类丢弃按单拍脉冲合并记 1。
  // =====================================================================
  reg [12:0] tx_len_q; // Current builder's application bytes in this fragment.
  // Mirror tx_rm's 16-entry frame-order queue at accepted SOF. The next
  // builder may start before the previous MAC completes, so a single length
  // register cannot associate stats with the physical completion event.
  reg [207:0] tx_stats_lengths;
  reg [3:0] tx_stats_wr,tx_stats_rd;
  wire [12:0] tx_done_length=tx_stats_lengths[13*tx_stats_rd +: 13];
  reg        ferr_a_d, ferr_b_d;
  always @(posedge clk) begin
    if (rst_sync) begin
      tx_len_q <= 13'd0; ferr_a_d <= 1'b0; ferr_b_d <= 1'b0;
      tx_stats_lengths<=208'd0;tx_stats_wr<=0;tx_stats_rd<=0;
    end else begin
      if (sch_start_vld) tx_len_q <= sch_start_len -
          ((TX_CHAIN_ENABLE && tx_sch_offset==0) ? 13'd8 : 13'd0);
      if(fb_out_vld && fb_out_rdy && fb_out_sof) begin
        tx_stats_lengths[13*tx_stats_wr +: 13]<=tx_len_q;
        tx_stats_wr<=tx_stats_wr+4'd1;
      end
      if(rm_frame_done) tx_stats_rd<=tx_stats_rd+4'd1;
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
      .tx_evt(rm_frame_done), .tx_len(tx_done_length),
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
  // CTL[9] 开启后，两个引擎的响应通过 MT_* 搬进 PMEM 并复用 TX 调度路径。
  // TFTP 的即时响应与重传各自携带锁定的目的 IP+TID，不能借用最近 SAP 的 IP。
  // =====================================================================
  assign sap_pm_gnt = sap_pm_req && !host_pmem_rd && !fb_rd_en_a && !aux_rd_turn;
  wire [7:0] sap_port_q = mgmt_last_desc[22:15];
  wire sap_to_snmp = (SNMP_EN != 0) && ctl_r[8] && (sap_port_q == SNMP_SAP_PORT[7:0]);
  wire sap_to_tftp = (TFTP_EN != 0) && (sap_port_q == TFTP_SAP_PORT[7:0]);
  // P02（2026-10-10）：SAP 字节流背压。TFTP 逐字节消费（其 in_ready 会在
  // 超时响应/卸载复制期间下降），SAP 端必须能停住并保持 data/vld/SOP/EOP
  // 与待消费位置；SNMP 的 in_ready 只表示"可接收新包"（字节在 SOP 后无
  // 条件消费），对 SNMP 不设逐字节停顿，避免中途停摆。
  // P05：取件作业期间 TFTP 端口的 SAP 流量归客户端引擎；作业外归服务端引擎。
  // （单会话 profile：目标端主动取件时，装载端不再同时走服务端路径）
  // Raw compatibility mode bypasses the server. Control-file mode uses
  // the server and pumps its published image after all DATA blocks complete.
  assign fe_sap_route = (A615A_EN != 0) && fe_busy;
  assign lur_raw_route = (A615A_EN != 0) && !lur_tftp_mode &&
                        (lur_upload_mode || lur_result_vld) && !fe_busy;
  assign lur_up_route = lur_raw_route;
  assign sap_out_ready = sap_to_tftp ?
                         (lur_up_route ? lur_up_rdy :
                          (fe_sap_route ? fe_sap_ready : tftp_in_ready)) : 1'b1;
  // LUR 上传通道取 SAP 字节流（服务端 TFTP 引擎此时被旁路，字节不双消费）。
  assign lur_up_vld = lur_tftp_mode ? (lur_pump_state==3 && lur_control_valid) :
                       (sap_out_vld && sap_to_tftp && lur_raw_route);
  assign lur_up_sop = lur_tftp_mode ? (lur_pump_index==0) : sap_out_sop;
  assign lur_up_eop = lur_tftp_mode ? (lur_pump_index+14'd1==lur_pump_length) : sap_out_eop;
  assign lur_up_byte = lur_tftp_mode ?
                        (lur_pump_word >> ((3-lur_pump_index[1:0])*8)) : sap_out_data;
  wire load_rd = hs && !host_we && load_hit && (TFTP_EN != 0);
  assign lur_control_rd = lur_pump_state==1 && !load_rd;
  assign lur_control_addr = {1'b0,lur_pump_index[13:2]};
  assign lur_control_ack = lur_result_vld && lur_result_ack && lur_pump_state==4;
  wire snmp_resp_ack = we && (host_addr == 16'hAC1C);
  wire tftp_resp_ack = we && (host_addr == 16'hAC28);
  // AC28 remains available to the host in observation/manual mode. Once the
  // automatic management TX FSM owns a TFTP response, or is taking it in this
  // cycle, only the FSM's commit-result path may acknowledge that response.
  wire mt_owns_tftp_resp = (mt_state != MT_IDLE) && mt_sel_tftp;
  wire mt_takes_tftp_resp = (mt_state == MT_IDLE) && mt_can_start && mt_pick_tftp;
  wire tftp_resp_ack_host = tftp_resp_ack &&
                            !mt_owns_tftp_resp && !mt_takes_tftp_resp;

  always @(posedge clk) begin
    if (rst_sync) begin
      load_rd_d <= 1'b0; mgmt_bidx <= 11'd0;
      cs_div <= 14'd0; uptime_cs <= 32'd0;
      snmp_ctl_shadow <= CTL_RST[15:0];
    end else begin
      load_rd_d <= load_rd;
      if (we && (host_addr == 16'hAC1A)) mgmt_bidx <= host_wdata[10:0];
      else if (hs && !host_we && ((host_addr == 16'hAC1B) || (host_addr == 16'hAC27)))
        mgmt_bidx <= mgmt_bidx + 11'd1;
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
    snmp_lite #(.NUM_TX_VL(NUM_TX_VL), .NUM_RX_VL(NUM_RX_VL), .MAX_VB(8), .SET_ACK_EN(1)) u_snmp (
      .clk(clk), .rst_sync(rst_sync), .en(ctl_r[8]),
      .in_vld(sap_out_vld && sap_to_snmp), .in_sop(sap_out_sop),
      .in_eop(sap_out_eop), .in_data(sap_out_data), .in_sport(sap_out_sport),
      .in_ready(snmp_in_ready),
      .uptime_cs(uptime_cs), .ctl_val(snmp_ctl_shadow),
      .drop_total(stats_drop_total), .jit_max_us(stats_jit_max),
      .buf_util({26'd0, popcnt16(~rx_free_map)}),
      .stats_off(stats_snmp_off), .stats_data(stats_snmp_rdata),
      .ctl_we(snmp_ctl_we), .ctl_wdata(snmp_ctl_wdata),
      .vl_data(snmp_vl_data), .vl_bag_allowed(snmp_vl_bag_allowed),
      .vl_bag_we(snmp_vl_bag_we), .vl_bag_index(snmp_vl_bag_index),
      .vl_bag_wdata(snmp_vl_bag_wdata), .mib_group(snmp_mib_group),
      .mib_leaf(snmp_mib_leaf), .mib_index(snmp_mib_index),
      .set_ack(snmp_set_ack), .set_active(snmp_set_active),
      .resp_vld(snmp_resp_vld), .resp_len(snmp_resp_len),
      .resp_ack(snmp_resp_ack | mgmt_ack_snmp), .resp_rd_addr(mgmt_bidx_mux),
      .resp_byte(snmp_resp_byte),
      .rx_pdu_cnt(snmp_cnt_rx), .resp_cnt(snmp_cnt_tx), .drop_pdu_cnt(snmp_cnt_drop),
      .last_err(s_err), .last_idx(s_idx), .last_pdu(s_pdu),
      .peer_port(s_peer), .vb_n(s_vb), .state_o());
    // [19:12]=PDU 类型 [11:8]=VarBind 数 [7:4]=error-index [3:0]=error-status
    assign snmp_st_w = {12'd0, s_pdu, s_vb, s_idx, s_err};
    assign snmp_peer_port = s_peer;
  end else begin : g_nosnmp
    assign snmp_set_active = 1'b0;
    assign snmp_resp_vld = 1'b0; assign snmp_resp_len = 11'd0;
    assign snmp_in_ready = 1'b1;
    assign snmp_resp_byte = 8'd0; assign snmp_st_w = 32'd0;
    assign snmp_cnt_rx = 32'd0; assign snmp_cnt_tx = 32'd0; assign snmp_cnt_drop = 32'd0;
    assign snmp_ctl_we = 1'b0; assign snmp_ctl_wdata = 16'd0;
    assign snmp_vl_bag_we = 1'b0; assign snmp_vl_bag_index = 8'd0;
    assign snmp_vl_bag_wdata = 32'd0; assign snmp_mib_group = 8'd0;
    assign snmp_mib_leaf = 8'd0; assign snmp_mib_index = 8'd0;
    assign stats_snmp_off = 8'd0;
    assign snmp_peer_port = 16'd0;
  end endgenerate

  generate if (TFTP_EN != 0) begin : g_tftp
    wire        t_ok;
    wire [15:0] t_err, t_tid, t_blk;
    wire [31:0] t_pkt, t_dup, t_ecnt, t_to;
    wire [7:0]  t_retry;
    wire [3:0]  t_st;
    a615a_tftp #(.LOAD_WORDS(LOAD_WORDS), .RETRY_MAX(3), .TIMEOUT_US(TFTP_TIMEOUT_US),
                 .BIND_PEER_IP(1), .CONTROL_FILENAME(LUR_TFTP_FILENAME),
                 .CONTROL_FILENAME_LEN(LUR_TFTP_FILENAME_LEN)) u_tftp (
      .clk(clk), .rst_sync(rst_sync), .en(1'b1), .tick_us(tick_us),
      .control_mode((A615A_EN!=0) && lur_tftp_mode && (lur_upload_mode || lur_control_busy)),
      .control_ack(lur_control_ack), .control_abort(lur_transport_abort),
      .control_file_valid(lur_control_valid), .control_busy(lur_control_busy),
      .in_vld(sap_out_vld && sap_to_tftp && !fe_sap_route && !lur_up_route), .in_sop(sap_out_sop),
      .in_eop(sap_out_eop), .in_data(sap_out_data), .in_sport(sap_out_sport),
      .in_srcip(sap_out_srcip),
      .in_ready(tftp_in_ready),
      .resp_vld(tftp_resp_vld), .resp_len(tftp_resp_len),
      .resp_tid(tftp_resp_tid), .resp_peer_ip(tftp_resp_peer_ip),
      .resp_ack(tftp_resp_ack_host | mgmt_ack_tftp), .resp_rd_addr(mgmt_bidx_mux),
      .resp_rd_ahead(tftp_rd_ahead), .resp_byte(tftp_resp_byte),
      .resp_byte_sync(tftp_resp_byte_sync),
      .host_rd(load_rd || lur_control_rd),
      .host_addr(load_rd ? tftp_host_word_addr : lur_control_addr),
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
    assign lur_control_valid=1'b0; assign lur_control_busy=1'b0;
    assign tftp_resp_vld = 1'b0; assign tftp_resp_len = 11'd0;
    assign tftp_resp_tid = 16'd0; assign tftp_resp_peer_ip = 32'd0;
    assign tftp_in_ready = 1'b1;
    assign tftp_resp_byte = 8'd0; assign tftp_load_rdata = 32'd0;
    assign tftp_resp_byte_sync = 1'b0;
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

  // =====================================================================
  // P05: 615A 取件作业寄存器（宿主窗 0xAC40~0xAC7F）
  //   0xAC40 W:[0]=start [1]=abort [2]=WRQ/upload mode   R:{done,failed,busy}
  //   0xAC41 server_ip   0xAC42..0xAC49 filename(32B 词)  0xAC4A fnlen
  //   0xAC4B timeout_ticks   0xAC4C R:{file_err,file_len}  0xAC4D W:[0]=file_ack
  //   0xAC4E W:file 读索引   0xAC4F R:读数据   0xAC50 rx_bytes  0xAC51 fcode
  //   0xAC52/0xAC53 观测计数  0xAC54 TID
  //   0xAC55 W:上传源字节  0xAC56 W:长度并 commit  0xAC57 W:[0]=preload start [1]=abort
  //   0xAC57 R:{upload mode, preload_error, data_ready, start_ready}
  // =====================================================================
  always @(posedge clk) begin
    if (rst_sync) begin
      fetch_ip <= 32'd0; fetch_tid <= 16'h3001; fetch_fn <= 256'd0;
      fetch_fnlen <= 8'd0; fetch_ticks <= 16'd50;
      fetch_start_p <= 1'b0; fetch_abort_p <= 1'b0; fetch_ack_p <= 1'b0;
      fetch_up_mode <= 1'b0;
      fetch_preload_start_p <= 1'b0; fetch_preload_data_valid_p <= 1'b0;
      fetch_preload_commit_p <= 1'b0; fetch_preload_abort_p <= 1'b0;
      fetch_preload_data_r <= 8'd0; fetch_preload_length_r <= 14'd0;
      init_file_fields <= 32'd0;
      init_file_start_p <= 1'b0; init_file_abort_p <= 1'b0;
      fe_rd_addr <= 13'd0;
    end else begin
      fetch_start_p <= 1'b0; fetch_abort_p <= 1'b0; fetch_ack_p <= 1'b0;
      fetch_preload_start_p <= 1'b0; fetch_preload_data_valid_p <= 1'b0;
      fetch_preload_commit_p <= 1'b0; fetch_preload_abort_p <= 1'b0;
      init_file_start_p <= 1'b0; init_file_abort_p <= 1'b0;
      if (we && fetch_hit) begin
        case (host_addr[5:0])
          6'h00: begin
            fetch_start_p <= host_wdata[0]; fetch_abort_p <= host_wdata[1];
            fetch_up_mode <= host_wdata[2];
          end
          6'h01: fetch_ip <= host_wdata;
          6'h02: fetch_fn[255:224] <= host_wdata;
          6'h03: fetch_fn[223:192] <= host_wdata;
          6'h04: fetch_fn[191:160] <= host_wdata;
          6'h05: fetch_fn[159:128] <= host_wdata;
          6'h06: fetch_fn[127:96]  <= host_wdata;
          6'h07: fetch_fn[95:64]   <= host_wdata;
          6'h08: fetch_fn[63:32]   <= host_wdata;
          6'h09: fetch_fn[31:0]    <= host_wdata;
          6'h0A: fetch_fnlen <= host_wdata[7:0];
          6'h0B: fetch_ticks <= host_wdata[15:0];
          6'h0D: fetch_ack_p <= host_wdata[0];
          6'h0E: fe_rd_addr <= host_wdata[12:0];
          6'h14: fetch_tid <= host_wdata[15:0];
          6'h15: begin
            fetch_preload_data_r <= host_wdata[7:0];
            fetch_preload_data_valid_p <= 1'b1;
          end
          6'h16: begin
            fetch_preload_length_r <= host_wdata[13:0];
            fetch_preload_commit_p <= 1'b1;
          end
          6'h17: begin
            fetch_preload_start_p <= host_wdata[0];
            fetch_preload_abort_p <= host_wdata[1] && !host_wdata[0];
          end
          6'h18: begin
            init_file_start_p <= host_wdata[0] && !host_wdata[1];
            init_file_abort_p <= host_wdata[1];
          end
          6'h19: init_file_fields <= host_wdata;
          default: ;
        endcase
      end
    end
  end

  // =====================================================================
  // P05: LUR（Load/Unload Request）宿主寄存器 0xAC80~0xACBF
  //   0xAC80 W:[0]=start [1]=abort [2]=skip [3]=up_mode
  //         R:{up_busy, skip, abort, start}
  //   0xAC81 R:{fail_files, ok_files}      0xAC82 R:{cur,fcode,failed,done,busy}
  //   0xAC83 R:total_bytes                 0xAC84 R:file_count
  //   0xAC85 R:{err, result_vld, ok, upload_vld}
  //   0xAC86 R:{name_len}                  0xAC87 W:上传接收态开/关
  //   0xAC88 W:清单条目选择(0..7)           0xAC89 R:名字字节  0xAC8A W:名字字节索引
  // =====================================================================
  reg  [7:0] lur_name_index_r;
  always @(posedge clk) begin
    if (rst_sync) begin
      lur_start_p <= 1'b0; lur_abort_p <= 1'b0; lur_skip_p <= 1'b0;
      lur_up_mode <= 1'b0; lur_name_sel <= 3'd0;
      lur_name_index_r <= 8'd0; lur_result_ack <= 1'b0;
      lur_upload_mode <= 1'b0; lur_host_index <= 8'd0;
      lur_auto_ack <= 1'b0;
      lur_hold_files <= 1'b0;
      lur_tftp_mode <= 1'b0; lur_transport_abort <= 1'b0;
    end else begin
      lur_start_p <= 1'b0; lur_abort_p <= 1'b0; lur_skip_p <= 1'b0;
      lur_result_ack <= 1'b0; lur_auto_ack <= 1'b0;
      lur_transport_abort <= 1'b0;
      if (we && lur_hit) begin
        case (host_addr[5:0])
          6'h00: begin
            lur_start_p <= host_wdata[0];
            lur_abort_p <= host_wdata[1];
            lur_skip_p  <= host_wdata[2];
            lur_up_mode <= host_wdata[3];
          end
          6'h07: begin
            if (!lur_busy) lur_upload_mode <= host_wdata[0];
            // Transport selection cannot change underneath an owned image,
            // an active orchestrator, or an unconsumed parser result.
            if (!lur_busy && !lur_control_busy && lur_pump_state==0 && !lur_result_vld)
              lur_tftp_mode <= host_wdata[1];
          end
          6'h08: lur_name_sel   <= host_wdata[2:0];
          6'h0A: lur_host_index <= host_wdata[7:0];
          // 0xAC8B 的读请求不在此处寄存（见上方 lur_host_rd_req 组合脉冲 +
          // lur_host_rd_pipe 展宽逻辑），否则会与展宽路径重复驱动。
          // AC8D bit0 configures file hold for the next orchestrated session.
          // AC8C write1 confirms a currently published/held file only.
          6'h0C: lur_auto_ack <= host_wdata[0];
          6'h0D: lur_hold_files <= host_wdata[0];
          6'h0F: if(!lur_busy) lur_transport_abort <= host_wdata[0];
          default: ;
        endcase
      end
      // 结果握手：宿主写 0xAC85 完成一次 result 确认。
      if (we && lur_hit && (host_addr[5:0] == 6'h05) && !lur_busy) lur_result_ack <= 1'b1;
    end
  end

  generate if (A615A_EN != 0) begin : g_lur
    // The server holds a validated, complete TFTP image while this word-to-
    // byte pump feeds exactly one file SOP/EOP to the parser. Public load
    // reads take priority; a pending parser byte remains stable under stall.
    always @(posedge clk) begin
      if (rst_sync || lur_transport_abort || lur_transport_lost) begin
        lur_pump_state<=0; lur_pump_index<=0; lur_pump_length<=0;
        lur_pump_word<=0; lur_transport_length_error<=0;
      end else begin
        case(lur_pump_state)
          0: if(lur_tftp_mode && lur_control_valid) begin
            lur_pump_index<=0; lur_pump_length<=tftp_bytes[13:0];
            if(tftp_bytes==0 || tftp_bytes>8192) begin
              lur_transport_length_error<=1; lur_pump_state<=5;
            end else begin lur_transport_length_error<=0; lur_pump_state<=1; end
          end
          1: if(lur_control_rd) lur_pump_state<=2;
          2: begin lur_pump_word<=tftp_load_rdata; lur_pump_state<=3; end
          3: if(lur_up_vld && lur_up_rdy) begin
            if(lur_pump_index+14'd1==lur_pump_length) lur_pump_state<=4;
            else begin
              lur_pump_index<=lur_pump_index+14'd1;
              if(lur_pump_index[1:0]==3) lur_pump_state<=1;
            end
          end
          4,5: if(!lur_control_valid) lur_pump_state<=0;
          default: lur_pump_state<=0;
        endcase
      end
    end
    // ---- Complete-file parser (or legacy raw-SAP compatibility input) ----
    a615a_lur_rx #(.MAX_FILES(8)) u_lur (
      .clk(clk), .rst_sync(rst_sync || lur_transport_abort || lur_transport_lost), .expected_version(16'h4131),
      .in_valid(lur_up_vld), .in_ready(lur_up_rdy),
      .in_sop(lur_up_sop), .in_eop(lur_up_eop), .in_data(lur_up_byte),
      .result_valid(lur_result_vld), .result_ack(lur_result_ack),
      .request_ok(lur_ok), .error_code(lur_err), .file_count(lur_file_count),
      .file_select(lur_sel_mux),
      .filename_length(lur_name_len_w), .part_number_length(lur_part_len_w),
      .name_read(lur_name_read_mux), .select_part_number(1'b0),
      .name_byte_index(lur_name_index_mux), .name_byte(lur_name_byte),
      .name_byte_valid(lur_name_byte_vld));

    // ---- 编排器：逐文件取件 ----
    a615a_lur_orchestrator #(.MAX_FILES(8), .DEF_TICKS(50)) u_lur_orch (
      .clk(clk), .rst_sync(rst_sync),
      .host_start(lur_start_p), .host_abort(lur_abort_p), .host_skip(lur_skip_p),
      .host_server_ip(fetch_ip), .host_local_tid(fetch_tid),
      .host_timeout_ticks(fetch_ticks), .host_up_mode(lur_up_mode),
      .host_hold_files(lur_hold_files),.host_file_ack(lur_auto_ack),.waiting_file_ack(lur_wait_file_ack),
      .lur_ok(lur_ok), .lur_file_count(lur_file_count),
      .lur_name_len(lur_name_len_w), .lur_name_byte(lur_name_byte),
      .lur_name_read(lur_name_read), .lur_name_index(lur_name_index),
      .lur_file_select(lur_file_select_w),
      .job_start(lur_job_start), .job_start_ready(lur_job_rdy),
      .job_server_ip(lur_job_ip), .job_local_tid(lur_job_tid),
      .job_filename(lur_job_fn), .job_filename_len(lur_job_fnlen),
      .job_timeout_ticks(lur_job_ticks), .job_abort(lur_job_abort),
      .job_up_mode(lur_job_up),
      .job_done(fe_done), .job_failed(fe_failed), .job_failure_code(fe_fcode),
      .file_ack(lur_orch_ack), .file_valid(fe_file_valid),
      .file_length(fe_file_len),
      .busy(lur_busy), .done(lur_done), .failed(lur_failed),
      .failure_code(lur_fcode), .cur_file(lur_cur), .ok_files(lur_ok_cnt),
      .fail_files(lur_fail_cnt), .total_bytes(lur_bytes));

    assign lur_job_rdy = fe_start_ready && !init_file_busy;
    assign lur_active = lur_busy || lur_upload_mode;
    assign lur_up_busy = lur_upload_mode;
  end else begin : g_nolur
    always @(posedge clk) begin
      lur_pump_state<=0; lur_pump_index<=0; lur_pump_length<=0;
      lur_pump_word<=0; lur_transport_length_error<=0;
    end
    assign lur_job_rdy = 1'b1;
    assign lur_wait_file_ack = 1'b0;
    assign lur_active = 1'b0;
    assign lur_up_busy = 1'b0;
    assign lur_up_rdy = 1'b1;
    assign lur_result_vld = 1'b0;
    assign lur_ok = 1'b0;
    assign lur_err = 4'd0;
    assign lur_file_count = 16'd0;
    assign lur_name_len_w = 8'd0;
    assign lur_part_len_w = 8'd0;
    assign lur_name_byte = 8'd0;
    assign lur_name_byte_vld = 1'b0;
    assign lur_busy = 1'b0;
    assign lur_done = 1'b0;
    assign lur_failed = 1'b0;
    assign lur_fcode = 4'd0;
    assign lur_cur = 3'd0;
    assign lur_ok_cnt = 16'd0;
    assign lur_fail_cnt = 16'd0;
    assign lur_bytes = 32'd0;
    assign lur_job_start = 1'b0;
    assign lur_job_abort = 1'b0;
    assign lur_job_ip = 32'd0;
    assign lur_job_tid = 16'd0;
    assign lur_job_ticks = 16'd0;
    assign lur_job_fn = 2048'd0;
    assign lur_job_fnlen = 8'd0;
    assign lur_job_up = 1'b0;
    assign lur_file_select_w = 3'd0;
  end endgenerate

  // Reserve the shared file buffer before its first byte, including pending
  // registered host requests. No reset of the whole transport is required.
  assign init_file_ready = (A615A_EN != 0) && !rst_sync && ctl_r[9] &&
      !init_file_busy && !lur_active && !lur_start_p && !fe_busy &&
      !fetch_start_p && !fetch_preload_start_p && !fetch_preload_data_valid_p &&
      !fetch_preload_commit_p && !fetch_preload_abort_p && fe_preload_start_ready;
  assign init_file_cancel = !ctl_r[9] || init_file_abort_p ||
      (host_cs && host_we && host_addr == 16'hAC58 && host_wdata[1]);
  assign init_preload_start = (init_file_state == 1) && !init_file_cancel;
  assign init_preload_data = (init_file_state == 2) && init_file_valid && !init_file_cancel;
  assign init_preload_commit = (init_file_state == 3) && !init_file_cancel;
  assign init_preload_abort = init_file_busy && init_file_cancel;
  a615a_init_tx u_init_file (
    .clk(clk), .rst_sync(rst_sync), .start(init_file_start_p && !init_file_cancel),
    .version(init_file_fields[31:16]), .status(init_file_fields[15:0]),
    .start_ready(), .file_valid(init_file_valid),
    .file_ack((init_file_state == 4) || init_file_cancel), .file_length(),
    .byte_address(init_file_index), .byte_data(init_file_byte));
  always @(posedge clk) begin
    if (rst_sync) begin
      init_file_state <= 0; init_file_index <= 0;
      init_file_done <= 0; init_file_error <= 0;
    end else if (init_file_busy && init_file_cancel) begin
      init_file_state <= 0; init_file_index <= 0;
      init_file_done <= 0; init_file_error <= 1;
    end else begin
      case (init_file_state)
        0: if (init_file_start_p) begin
          init_file_state <= 1; init_file_index <= 0;
          init_file_done <= 0; init_file_error <= 0;
        end
        1: if (fe_preload_start_ready) init_file_state <= 2;
        2: if (init_file_valid && fe_preload_data_ready) begin
          if (init_file_index == 8) init_file_state <= 3;
          else init_file_index <= init_file_index + 1'b1;
        end
        3: if (fe_preload_data_ready) init_file_state <= 4;
        4: begin
          init_file_done <= fe_file_valid && (fe_file_len == 9);
          init_file_error <= !fe_file_valid || (fe_file_len != 9);
          init_file_state <= 0;
        end
        default: init_file_state <= 0;
      endcase
    end
  end
  generate if (A615A_EN != 0) begin : g_a615a
    a615a_fetch_engine u_fetch (
      .clk(clk), .rst_sync(rst_sync), .en(ctl_r[9]),
      .sap_vld(sap_out_vld && sap_to_tftp && fe_sap_route),
      .sap_sop(sap_out_sop), .sap_eop(sap_out_eop), .sap_data(sap_out_data),
      .sap_sport(sap_out_sport), .sap_dport(sap_out_dport), .sap_srcip(sap_out_srcip),
      .sap_ready(fe_sap_ready),
      .pkt_vld(fe_pkt_vld), .pkt_len(fe_pkt_len), .pkt_dst_ip(fe_pkt_dst_ip),
      .pkt_src_port(fe_pkt_src_port), .pkt_dst_port(fe_pkt_dst_port),
      .pkt_rd_addr(mgmt_bidx_mux), .pkt_byte(fe_pkt_byte), .pkt_ack(mgmt_ack_cli),
      .start(fe_src_start), .start_ready(fe_start_ready), .start_write(fe_src_write),
      .server_ip(fe_src_ip), .local_tid(fe_src_tid),
      .filename(fe_src_fn), .filename_len(fe_src_fnlen),
      .timeout_ticks(fe_src_ticks), .timeout_tick(tick_us), .abort(fe_src_abort),
      .preload_start(init_file_busy ? init_preload_start : fetch_preload_start_p),
      .preload_start_ready(fe_preload_start_ready),
      .preload_data_valid(init_file_busy ? init_preload_data : fetch_preload_data_valid_p),
      .preload_data_ready(fe_preload_data_ready),
      .preload_data(init_file_busy ? init_file_byte : fetch_preload_data_r),
      .preload_commit(init_file_busy ? init_preload_commit : fetch_preload_commit_p),
      .preload_length(init_file_busy ? 14'd9 : fetch_preload_length_r),
      .preload_abort(init_preload_abort || fetch_preload_abort_p), .preload_error(fe_preload_error),
      .upload_block_req(), .upload_block_number(),
      .busy(fe_busy), .done(fe_done), .failed(fe_failed), .failure_code(fe_fcode),
      .rx_bytes(fe_rx_bytes), .file_busy(fe_file_busy), .file_valid(fe_file_valid),
      .file_ack(fe_file_ack_src), .file_length(fe_file_len), .file_error_code(fe_file_err),
      .rd_en(fe_rd_en), .rd_addr(fe_rd_addr), .rd_valid(fe_rd_valid), .rd_data(fe_rd_data),
      .ok_cnt(fe_ok_cnt), .drop_cnt(fe_drop_cnt));
  end else begin : g_noa615a
    assign fe_pkt_vld = 1'b0;  assign fe_pkt_len = 11'd0;
    assign fe_pkt_dst_ip = 32'd0; assign fe_pkt_src_port = 16'd0;
    assign fe_pkt_dst_port = 16'd0; assign fe_pkt_byte = 8'd0;
    assign fe_sap_ready = 1'b1; assign fe_start_ready = 1'b0; assign fe_busy = 1'b0;
    assign fe_preload_start_ready = 1'b0; assign fe_preload_data_ready = 1'b0;
    assign fe_preload_error = 1'b0;
    assign fe_done = 1'b0; assign fe_failed = 1'b0; assign fe_fcode = 4'd0;
    assign fe_rx_bytes = 32'd0; assign fe_file_valid = 1'b0;
    assign fe_file_len = 14'd0; assign fe_file_err = 2'd0;
    assign fe_file_busy = 1'b0; assign fe_rd_data = 8'd0; assign fe_rd_valid = 1'b0;
    assign fe_ok_cnt = 32'd0; assign fe_drop_cnt = 32'd0;
  end endgenerate

endmodule
