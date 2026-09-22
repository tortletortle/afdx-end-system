// =====================================================================
// tx_frame_builder.v —— 消息 → 完整帧（首部合成、IP/UDP 校验和、SN、填充）
// 设计书: §7.3（功能/端口/状态机）/ §6.1~6.6（帧格式）/ §8.4（pass1）/
//         §5.3（字节流时序，由 mac_tx_if 掌握节拍）/ §3.4（估 640 行）
// 性能口径（与 §7.3 原文的差异，已记工作记录，属"更快"方向）:
//   1) pass1 校验和不按 8 拍/字节读，而是走 PMEM 读口 A **1 字(4 B)/拍**：
//      L=1471 → 368 拍 ≈ 2.9 μs（原 11 768 拍 = 117.7 μs）。
//   2) pass1 与 pass2 **重叠**：pass2 走读口 B，从 SETUP 结束立刻开始发首部；
//      UDP 校验和在偏移 40 才需要，40 B × BYTE_SLOT_CYC(10) = 400 拍 > 368 拍，
//      故正常情况下不等待。若节拍更快（BYTE_SLOT_CYC 小）导致 pass1 未完，
//      在偏移 40 处暂停 out_vld 并 p1_stall_cnt+1（哨兵，T03 断言为 0）。
//      → TX 首字节延迟 ≈ SETUP 14 拍 ≈ 0.11 μs（原轻载 3.5 μs / 满载 118.7 μs）。
//   3) 首部不用 64×16 header buffer：42 字节由字段寄存器经 off 索引的组合
//      mux 直接产生，只保存两个校验和结果。省约 1 K FF。
//   4) 载荷双字预取（cur/nxt）：允许 out_rdy 每拍连续（TB 压力用），
//      正常 10 拍/字节时读口 B 占空比 2.5%。
// 帧布局（按 §6.1 表 + 黄金模型 afdx_model.build_frame，与 §7.3 文字
//   "填充在 SN 之前" 不一致——以可执行裁判为准，已记问题清单）:
//   DMAC6 SMAC6 ET2 IP20 UDP8 | payload L | SN 1 | pad 0..(17-L) | (FCS 由 mac_tx_if)
//   IP total = 28+L+1, UDP len = 8+L+1, 帧长(不含 FCS) = max(60, 43+L)。
// PMEM 字节序: 消息字节 j 在块内字 j/4 的 [31-8*(j%4) -: 8]（网络序，主机
//   按大端打包）。读地址 = {blk[3:0], j[10:2]}（块 512 字，L≤1471 → ≤368 字）。
// 握手: start_vld/busy（pulse+电平）；snap_req→snap_ack（tx_sn_gen）；
//   out_vld/out_rdy（vld 保持到 rdy）；blk_free 在末载荷字节被接收时发出
//   （块尽早归还，比 frame_done 更早）；done 脉冲 = 末字节被接收（§10）。
// 时钟/复位: clk / rst_sync（§4.2）。
// 依赖表项: VL 表 w0~w4、端口表 w0.sp、SMAC_CFG/IP_CFG/UDP_CFG 由上层在
//   start_vld 拍给出（hdr_* 输入），本模块锁存。IP ident 由上层维护（每 VL 计数）。
// 已知限制: 不做 IP 分片（P2）；L 须 8..1471，越界置 len_err 并按 IDLE 退出。
// =====================================================================
`timescale 1 ns / 1 ps
module tx_frame_builder #(
  parameter integer BYTE_SLOT_CYC = 10       // 仅用于注释口径，节拍由 out_rdy 给
) (
  input  wire        clk,
  input  wire        rst_sync,
  // ---- 启动（来自调度器 / tx_port_buf.sch_ack）----
  input  wire        start_vld,
  input  wire [7:0]  start_vl,
  input  wire [3:0]  start_blk,
  input  wire [12:0] start_len,        // L 字节
  output reg         busy,
  output reg         done,             // 末字节被 mac 接收（1 拍）
  output reg         len_err,          // L 越界（1 拍）
  // ---- 首部参数（start_vld 拍有效）----
  input  wire [15:0] hdr_vlid,
  input  wire [7:0]  hdr_udi,
  input  wire [3:0]  hdr_ifid,
  input  wire [3:0]  hdr_net_a,        // A 网 net_id（§6.2: 1）
  input  wire [3:0]  hdr_net_b,        // B 网 net_id（2）
  input  wire [7:0]  hdr_tos,
  input  wire [7:0]  hdr_ttl,
  input  wire [15:0] hdr_ident,
  input  wire [31:0] hdr_src_ip,
  input  wire [31:0] hdr_dst_ip,
  input  wire [15:0] hdr_sport,
  input  wire [15:0] hdr_dport,
  input  wire        hdr_udp_csum_en,  // UDP_CFG.UDP_CSUM_MODE
  // ---- SN（tx_sn_gen）----
  output reg         snap_req,
  output reg  [7:0]  snap_vl,
  input  wire [7:0]  snap,
  input  wire        snap_ack,
  // ---- PMEM 读口 A（pass1 校验和）/ B（pass2 发送）----
  output reg         rd_en_a,
  output reg  [12:0] rd_addr_a,
  input  wire [31:0] rd_data_a,
  output reg         rd_en_b,
  output reg  [12:0] rd_addr_b,
  input  wire [31:0] rd_data_b,
  // ---- 字节流输出（→ tx_rm → mac_tx_if）----
  output reg         out_vld,
  output wire [7:0]  out_byte_a,       // A 网字节
  output wire [7:0]  out_byte_b,       // B 网字节（仅 SMAC[4] 低 4 位不同）
  output wire        out_sof,
  output wire        out_eof,
  input  wire        out_rdy,
  // ---- 块归还（→ tx_port_buf.blk_free）----
  output reg         blk_free,
  output reg  [3:0]  blk_free_id,
  // ---- 统计 ----
  output reg  [15:0] p1_stall_cnt      // 偏移 40 处等待 pass1 的帧数（应为 0）
);
  // ---- §6.1 常量 ----
  localparam [12:0] L_MIN      = 13'd8;
  localparam [12:0] L_MAX      = 13'd1471;
  localparam [10:0] HDR_LEN    = 11'd42;     // 14 + 20 + 8
  localparam [10:0] FRAME_MIN  = 11'd60;     // 不含 FCS
  localparam [10:0] OFF_UDPCS  = 11'd40;     // UDP 校验和首字节偏移
  localparam [7:0]  IP_PROTO_UDP = 8'd17;
  localparam [15:0] IP_FLAGS_DF  = 16'h4000;

  // ---- 状态机（§10 三段式；ST_*）----
  localparam [1:0] ST_IDLE  = 2'd0;   // 进入: 复位/DONE；退出: start_vld
  localparam [1:0] ST_SETUP = 2'd1;   // 进入: start；退出: 首部校验和折叠完成（约 14 拍）
  localparam [1:0] ST_EMIT  = 2'd2;   // 进入: SETUP 完成；退出: 末字节被接收
  reg [1:0] st, st_n;

  // ---- 锁存参数 ----
  reg [3:0]  blk;
  reg [12:0] L;
  reg [15:0] vlid, ident, sport, dport;
  reg [7:0]  udi, tos, ttl, sn;
  reg [3:0]  ifid, net_a, net_b;
  reg [31:0] src_ip, dst_ip;
  reg        udp_csum_en;
  wire [15:0] ip_total = 16'd29 + {3'b0, L};   // 20 + 8 + L + 1
  wire [15:0] udp_len  = 16'd9  + {3'b0, L};   // 8 + L + 1
  wire [10:0] body_len = HDR_LEN + L[10:0] + 11'd1;       // 42 + L + 1（含 SN）
  wire [10:0] frame_len = (body_len < FRAME_MIN) ? FRAME_MIN : body_len;

  // =====================================================================
  // SETUP: 顺序累加 IP 首部 10 个 16 位字 + UDP 伪首部/首部常量项，然后折叠
  // =====================================================================
  reg  [3:0]  su_k;          // 0..9 累加，10 折叠 1，11 折叠 2，12 取反
  reg  [31:0] ip_acc, udp_acc;
  reg  [15:0] ip_csum;       // 回填 hb[24:25]
  reg  [31:0] udp_pre;       // 伪首部 + UDP 首部常量项之和（未折叠）
  reg         su_done;

  // IP 首部第 k 个 16 位字（校验和字段按 0）
  reg [15:0] ipw;
  always @(*) begin
    case (su_k)
      4'd0: ipw = {8'h45, tos};
      4'd1: ipw = ip_total;
      4'd2: ipw = ident;
      4'd3: ipw = IP_FLAGS_DF;
      4'd4: ipw = {ttl, IP_PROTO_UDP};
      4'd5: ipw = 16'h0000;
      4'd6: ipw = src_ip[31:16];
      4'd7: ipw = src_ip[15:0];
      4'd8: ipw = dst_ip[31:16];
      4'd9: ipw = dst_ip[15:0];
      default: ipw = 16'h0000;
    endcase
  end
  // UDP 伪首部 + 首部常量项（k=0..7）
  reg [15:0] udw;
  always @(*) begin
    case (su_k)
      4'd0: udw = src_ip[31:16];
      4'd1: udw = src_ip[15:0];
      4'd2: udw = dst_ip[31:16];
      4'd3: udw = dst_ip[15:0];
      4'd4: udw = {8'h00, IP_PROTO_UDP};
      4'd5: udw = udp_len;            // 伪首部长度
      4'd6: udw = sport;
      4'd7: udw = dport;
      4'd8: udw = udp_len;            // UDP 首部长度字段
      default: udw = 16'h0000;
    endcase
  end
  wire [31:0] ip_fold1  = {16'h0, ip_acc[31:16]} + {16'h0, ip_acc[15:0]};

  // =====================================================================
  // pass1: 读口 A 1 字/拍，反码累加载荷（大端 16 位对）
  // =====================================================================
  reg         p1_run;          // 读请求阶段
  reg         p1_done;
  reg  [8:0]  p1_widx;         // 发出的字序号
  reg  [8:0]  p1_nw;           // 总字数 = ceil(L/4)
  reg  [1:0]  p1_tail;         // L%4（0 表示整字）
  reg         p1_dv;           // 上拍发了读 → 本拍 rd_data_a 有效
  reg         p1_last_dv;
  reg  [31:0] p1_acc;
  wire [8:0]  nw_calc   = L[12:2] + {8'b0, |L[1:0]};
  // 末字掩码: tail=1 → 只保留 [31:24]；2 → [31:16]；3 → [31:8]
  wire [31:0] p1_mask   = (!p1_last_dv || p1_tail == 2'd0) ? 32'hFFFF_FFFF :
                          (p1_tail == 2'd1) ? 32'hFF00_0000 :
                          (p1_tail == 2'd2) ? 32'hFFFF_0000 : 32'hFFFF_FF00;
  wire [31:0] p1_word   = rd_data_a & p1_mask;
  // SN 项: L 偶 → SN 在高字节；L 奇 → SN 在低字节（与 pass1 大端配对衔接）
  wire [15:0] sn_term   = L[0] ? {8'h00, sn} : {sn, 8'h00};
  wire [31:0] udp_sum   = udp_pre + p1_acc + {16'h0, sn_term};
  wire [31:0] udp_fold1 = {16'h0, udp_sum[31:16]} + {16'h0, udp_sum[15:0]};
  wire [15:0] udp_fold2 = udp_fold1[15:0] + {15'h0, udp_fold1[16]};
  wire [15:0] udp_csum  = udp_csum_en ? ~udp_fold2 : 16'h0000;

  // =====================================================================
  // pass2: 逐字节发送
  // =====================================================================
  reg  [10:0] off;             // 当前字节偏移（DMAC 起算）
  reg  [31:0] cur_w, nxt_w;    // 载荷双字预取
  reg         pf_pending;      // rd_en_b 的 1 拍延迟：本拍 rd_data_b → nxt_w
  reg  [8:0]  pf_widx;         // 下一个要请求的字序号
  reg         pf_init;         // 预取初始化阶段计数（2 字）
  reg  [1:0]  pf_init_k;
  wire        is_hdr   = (off < HDR_LEN);
  wire [10:0] pl_off   = off - HDR_LEN;                    // 载荷内偏移
  wire        is_pl    = !is_hdr && (pl_off < L[10:0]);
  wire        is_sn    = (pl_off == L[10:0]);
  wire        is_last  = (off == frame_len - 11'd1);
  wire        need_wait = (off == OFF_UDPCS) && !p1_done;  // 哨兵
  wire        xfer     = out_vld & out_rdy;
  wire        need_wait_next = (off == OFF_UDPCS - 11'd1) && !p1_done; // 传走 39 后若 pass1 未完，下拍不能 vld
  reg         snap_ack_seen;
  reg         stall_seen;

  // 首部字节 mux（§6.1~6.4）
  reg [7:0] hb;
  always @(*) begin
    case (off[5:0])
      6'd0:  hb = 8'h03;  6'd1:  hb = 8'h00;  6'd2:  hb = 8'h00;  6'd3:  hb = 8'h00;
      6'd4:  hb = vlid[15:8];                 6'd5:  hb = vlid[7:0];
      6'd6:  hb = 8'h02;  6'd7:  hb = 8'h00;  6'd8:  hb = 8'h00;  6'd9:  hb = udi;
      6'd10: hb = {ifid, net_a};              6'd11: hb = 8'h00;
      6'd12: hb = 8'h08;  6'd13: hb = 8'h00;
      6'd14: hb = 8'h45;  6'd15: hb = tos;
      6'd16: hb = ip_total[15:8];             6'd17: hb = ip_total[7:0];
      6'd18: hb = ident[15:8];                6'd19: hb = ident[7:0];
      6'd20: hb = IP_FLAGS_DF[15:8];          6'd21: hb = IP_FLAGS_DF[7:0];
      6'd22: hb = ttl;                        6'd23: hb = IP_PROTO_UDP;
      6'd24: hb = ip_csum[15:8];              6'd25: hb = ip_csum[7:0];
      6'd26: hb = src_ip[31:24]; 6'd27: hb = src_ip[23:16]; 6'd28: hb = src_ip[15:8]; 6'd29: hb = src_ip[7:0];
      6'd30: hb = dst_ip[31:24]; 6'd31: hb = dst_ip[23:16]; 6'd32: hb = dst_ip[15:8]; 6'd33: hb = dst_ip[7:0];
      6'd34: hb = sport[15:8];                6'd35: hb = sport[7:0];
      6'd36: hb = dport[15:8];                6'd37: hb = dport[7:0];
      6'd38: hb = udp_len[15:8];              6'd39: hb = udp_len[7:0];
      6'd40: hb = udp_csum[15:8];             6'd41: hb = udp_csum[7:0];
      default: hb = 8'h00;
    endcase
  end
  reg [7:0] plb;
  always @(*) begin
    case (pl_off[1:0])
      2'd0: plb = cur_w[31:24];
      2'd1: plb = cur_w[23:16];
      2'd2: plb = cur_w[15:8];
      default: plb = cur_w[7:0];
    endcase
  end
  wire [7:0] byte_a = is_hdr ? hb : is_pl ? plb : is_sn ? sn : 8'h00;
  assign out_byte_a = byte_a;
  assign out_byte_b = (off == 11'd10) ? {ifid, net_b} : byte_a;
  assign out_sof    = (off == 11'd0);
  assign out_eof    = is_last;

  // ---- 次态 ----
  always @(*) begin
    st_n = st;
    case (st)
      ST_IDLE:  if (start_vld && start_len >= L_MIN && start_len <= L_MAX) st_n = ST_SETUP;
      ST_SETUP: if (su_done && snap_ack_seen) st_n = ST_EMIT;
      ST_EMIT:  if (xfer && is_last) st_n = ST_IDLE;
      default:  st_n = ST_IDLE;
    endcase
  end
  // ---- 时序 ----
  always @(posedge clk) begin
    if (rst_sync) begin
      st <= ST_IDLE;
      busy <= 1'b0; done <= 1'b0; len_err <= 1'b0;
      snap_req <= 1'b0; snap_vl <= 8'd0; snap_ack_seen <= 1'b0; sn <= 8'd0;
      blk <= 4'd0; L <= 13'd0;
      vlid <= 16'd0; ident <= 16'd0; sport <= 16'd0; dport <= 16'd0;
      udi <= 8'd0; tos <= 8'd0; ttl <= 8'd0; ifid <= 4'd0; net_a <= 4'd1; net_b <= 4'd2;
      src_ip <= 32'd0; dst_ip <= 32'd0; udp_csum_en <= 1'b0;
      su_k <= 4'd0; ip_acc <= 32'd0; udp_acc <= 32'd0; ip_csum <= 16'd0; udp_pre <= 32'd0; su_done <= 1'b0;
      p1_run <= 1'b0; p1_done <= 1'b0; p1_widx <= 9'd0; p1_nw <= 9'd0; p1_tail <= 2'd0;
      p1_dv <= 1'b0; p1_last_dv <= 1'b0; p1_acc <= 32'd0;
      rd_en_a <= 1'b0; rd_addr_a <= 13'd0; rd_en_b <= 1'b0; rd_addr_b <= 13'd0;
      off <= 11'd0; cur_w <= 32'd0; nxt_w <= 32'd0; pf_pending <= 1'b0; pf_widx <= 9'd0;
      pf_init <= 1'b0; pf_init_k <= 2'd0; out_vld <= 1'b0;
      blk_free <= 1'b0; blk_free_id <= 4'd0; p1_stall_cnt <= 16'd0;
    end else begin
      st <= st_n;
      done <= 1'b0; len_err <= 1'b0; snap_req <= 1'b0; blk_free <= 1'b0;
      rd_en_a <= 1'b0; rd_en_b <= 1'b0;
      p1_dv <= rd_en_a; p1_last_dv <= rd_en_a && (p1_widx == p1_nw);   // widx 已 +1
      if (snap_ack) begin sn <= snap; snap_ack_seen <= 1'b1; end

      case (st)
        // -------------------------------------------------------------
        ST_IDLE: begin
          busy <= 1'b0; out_vld <= 1'b0; su_done <= 1'b0; p1_done <= 1'b0; snap_ack_seen <= 1'b0;
          if (start_vld) begin
            if (start_len < L_MIN || start_len > L_MAX) begin
              len_err <= 1'b1;
            end else begin
              busy <= 1'b1;
              blk <= start_blk; L <= start_len;
              vlid <= hdr_vlid; udi <= hdr_udi; ifid <= hdr_ifid; net_a <= hdr_net_a; net_b <= hdr_net_b;
              tos <= hdr_tos; ttl <= hdr_ttl; ident <= hdr_ident; src_ip <= hdr_src_ip; dst_ip <= hdr_dst_ip;
              sport <= hdr_sport; dport <= hdr_dport; udp_csum_en <= hdr_udp_csum_en;
              snap_req <= 1'b1; snap_vl <= start_vl;
              su_k <= 4'd0; ip_acc <= 32'd0; udp_acc <= 32'd0;
              // pass1 启动
              p1_run <= 1'b1; p1_widx <= 9'd0; p1_acc <= 32'd0;
              // pass2 预取启动
              pf_init <= 1'b1; pf_init_k <= 2'd0; pf_widx <= 9'd0; pf_pending <= 1'b0;
              off <= 11'd0;
            end
          end
        end
        // -------------------------------------------------------------
        ST_SETUP: begin
          // 首部累加（k=0..9），折叠（10、11），取反（12）
          if (su_k <= 4'd9) begin
            ip_acc  <= ip_acc  + {16'h0, ipw};
            udp_acc <= udp_acc + {16'h0, udw};
            su_k <= su_k + 4'd1;
          end else if (su_k == 4'd10) begin
            ip_acc  <= ip_fold1;
            udp_pre <= udp_acc;
            su_k <= su_k + 4'd1;
          end else if (su_k == 4'd11) begin
            ip_csum <= ~(ip_acc[15:0] + {15'h0, ip_acc[16]});
            su_k <= su_k + 4'd1;
            su_done <= 1'b1;
          end
        end
        // -------------------------------------------------------------
        ST_EMIT: begin
          out_vld <= !need_wait;
          if (xfer) begin
            off <= off + 11'd1;
            if (is_last) begin
              out_vld <= 1'b0; done <= 1'b1; busy <= 1'b0;
            end else if (need_wait_next) begin
              out_vld <= 1'b0;
            end
            // 末载荷字节被接收 → 归还块（SN/pad 不再读 PMEM）
            if (is_pl && (pl_off == L[10:0] - 11'd1)) begin
              blk_free <= 1'b1; blk_free_id <= blk;
            end
            // 载荷字边界: 换字 + 预取下下字
            if (is_pl && pl_off[1:0] == 2'd3) begin
              cur_w <= nxt_w;
              if (pf_widx < p1_nw) begin
                rd_en_b <= 1'b1; rd_addr_b <= {blk, pf_widx};
                pf_widx <= pf_widx + 9'd1;
              end
            end
          end
        end
        default: ;
      endcase

      // ---- SETUP 首拍锁存字数（L 已在 IDLE 拍写入，此处用寄存值）----
      if (st == ST_SETUP && su_k == 4'd0) begin
        p1_nw   <= nw_calc;
        p1_tail <= L[1:0];
      end

      // ---- pass1 读请求（与 SETUP/EMIT 并行）----
      // 首拍（su_k==0）p1_nw 尚未就绪，用 nw_calc 直接比较
      if (p1_run) begin
        if (p1_widx < ((st == ST_SETUP && su_k == 4'd0) ? nw_calc : p1_nw)) begin
          rd_en_a <= 1'b1; rd_addr_a <= {blk, p1_widx};
          p1_widx <= p1_widx + 9'd1;
        end else begin
          p1_run <= 1'b0;
        end
      end
      // pass1 累加（数据滞后 1 拍）
      if (p1_dv) begin
        p1_acc <= p1_acc + {16'h0, p1_word[31:16]} + {16'h0, p1_word[15:0]};
        if (p1_last_dv) p1_done <= 1'b1;
      end
      // 哨兵统计（进入等待的那一拍计一次）
      if (st == ST_EMIT && need_wait && !stall_seen) p1_stall_cnt <= p1_stall_cnt + 16'd1;

      // ---- pass2 预取初始化: 字 0 → cur_w，字 1 → nxt_w ----
      if (pf_init) begin
        if (pf_init_k == 2'd0) begin
          rd_en_b <= 1'b1; rd_addr_b <= {blk, 9'd0}; pf_init_k <= 2'd1;
        end else if (pf_init_k == 2'd1) begin
          rd_en_b <= 1'b1; rd_addr_b <= {blk, 9'd1}; pf_init_k <= 2'd2;
        end else if (pf_init_k == 2'd2) begin
          cur_w <= rd_data_b; pf_init_k <= 2'd3;         // 字 0 到达
        end else begin
          nxt_w <= rd_data_b; pf_init <= 1'b0; pf_widx <= 9'd2;   // 字 1 到达
        end
      end else begin
        // rd_en_b 寄存后 1 拍 BRAM 出数：rd_en_b=1 的下一拍锁存
        pf_pending <= rd_en_b;
        if (pf_pending) nxt_w <= rd_data_b;
      end
    end
  end

  // 停顿只计一次
  always @(posedge clk) begin
    if (rst_sync || st != ST_EMIT) stall_seen <= 1'b0;
    else if (need_wait) stall_seen <= 1'b1;
  end
endmodule
