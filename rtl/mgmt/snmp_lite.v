// =====================================================================
// snmp_lite.v —— 轻量 SNMP v1/v2c 代理（GET / GETNEXT / SET）
// 设计书 §7.16。continue4 实现（原第 0 周空壳）。
//
// 结构：收包缓存 256 B → 逐字节 BER 解析 → 逐 VarBind 解析求值
//       → 计算全部长度 → 逐字节 BER 编码进 256 B 响应缓存。
//
// 支持的 MIB（企业前缀 1.3.6.1.4.1.4444.1）：
//   组 1（标量，OID = <pfx>.1.<leaf>.0）
//     .1  afdxEsDescr        OCTET STRING(16)  RO  "AFDX-ES eLinx v1"
//     .2  afdxEsUpTime       TimeTicks(0x43)   RO
//     .3  afdxNumTxVl        INTEGER           RO
//     .4  afdxNumRxVl        INTEGER           RO
//     .10 afdxEsRxMaxJitUs   INTEGER           RO
//     .11 afdxEsCtl          INTEGER           RW
//     .12 afdxEsDropCnt      Counter32(0x41)   RO
//     .13 afdxEsBufUtil      Gauge32(0x42)     RO
//   组 2（STATS_BLOCK 只读组，OID = <pfx>.2.<w>.0，w=0..47）
//     直接映射全局统计页 0x0100 的第 w 个字，Counter32，只读。
//   组 1 的 .5 BAG(RW)、.6 TX/.7 RX/.8 drop/.9 status(RO) 各有 128 个实例。
//   GETNEXT 按 8 个标量、5×128 个 indexed 实例及 48 个统计字共 696 项游走。
//
// 错误语义：
//   community != "public" 或 version 非 0（仅 SNMPv1）或 BER 不合法 → 静默丢弃 + 计数
//   GET/SET 到不存在对象 → noSuchName(2)，error-index = 出错 VarBind 序号
//   SET 到只读对象       → readOnly(4)
//   SET 类型非 INTEGER 或值 > 0xFFFF → badValue(3)
//   VarBind > 8 个，或响应任一长度域 > 255 → tooBig(1) + 空 VarBind 列表
//   非 tooBig 错误响应原样回抄请求 VarBindList 内容（OID、类型及值）。
//
// 覆盖边界（如实标注，未实现/不宣称）：
//   - 只支持短式长度与 0x81 单字节长式（≤255），0x82 及以上一律丢弃；
//   - 只支持 SNMPv1(version=0) 单一版本；v2c/v3 版本字段静默丢弃（计数），
//     无认证加密 / 无 Trap / 无 GETBULK；
//   - community 为编译期常量 "public"，未做运行时可配；
//   - OID 叶子号限 0..127（单字节子标识符），不支持多字节叶子；
//   - request-id 与 community 在响应中按原始字节回抄，不做重新编码；
//   - 每 VarBind 的取值在解析当拍锁存，同一响应内不保证跨对象的原子快照。
//
// 核查 20260928 修复（A01 / A02）：
//   - SET 两阶段提交（RFC 3416 §4.2.5 "as if simultaneously"）：解析阶段只校验
//     并登记每个 VarBind，全部校验通过且未判 tooBig 后才在 P_COMMIT 按请求顺序
//     每拍提交一个写；任一 VarBind 出错 → 一个都不写（此前成功前缀会先落地）。
//   - 单待处理槽 + 整包拒收计数：上游 mgmt_sap_rx 无 out_ready（顶层 in_ready
//     悬空），无法反压。req 缓存在解析/编码期间被回抄 community/request-id，
//     故仅当 st==P_IDLE 且无待处理包时才接收新包（响应等待主机取走期间可再收
//     1 包排队）；其余情况在 SOP 处整包丢弃并计入 drop_pdu_cnt，不再静默覆盖。
//     无 SOP 的游离字节不写缓存。in_ready 仅作状态指示（=可接收新包）。
//   - repair 20260928: actual received length + each enclosing TLV bound is
//     checked before consumption; oversize packets saturate/drop, no stale tail.
//     Full response capacity is checked before SET commit. Unsigned writable
//     integers must be 1..4 bytes and non-negative; BAG is 1..0x7FFFFE us so
//     BAG+1 stays below the signed half-range of the 24-bit scheduler clock.
//   - SET_ACK_EN=1: set_active serializes host configuration, one write pulse
//     is followed by set_ack before the next write/response. Default 0 keeps
//     the existing standalone pulse-sink interface. Response peer is held.
//   - 2026-10-06：请求缓存改为上升沿 8 bit BRAM（不再 RD_NEG×32）。eLinx
//     对同一阵列 posedge 写 + negedge 读常展开成数千 $dffe/$eq。解析/回抄
//     community 与 request-id 在地址稳定后插入 1 拍再消费，语义不变。
//     响应窗原 RD_NEG=1；2026-10-07 改为 RD_NEG=0（同步读），切开半周期
//     RD_NEG→pmem/rdata。主机 0xAC1B 自增读本有空拍；上线 FSM 见 MT_WARM。
// =====================================================================
`timescale 1 ns / 1 ps
module snmp_lite #(
  parameter integer NUM_TX_VL = 128,
  parameter integer NUM_RX_VL = 4096,
  parameter integer MAX_VB    = 8,
  parameter integer SET_ACK_EN = 0 // 0: legacy pulse sink; 1: wait for actual commit ack
)(
  input  wire        clk,
  input  wire        rst_sync,
  input  wire        en,
  // 请求字节流（UDP 载荷）
  input  wire        in_vld,
  input  wire        in_sop,
  input  wire        in_eop,
  input  wire [7:0]  in_data,
  input  wire [15:0] in_sport,
  output wire        in_ready,
  // MIB 数据源
  input  wire [31:0] uptime_cs,
  input  wire [15:0] ctl_val,
  input  wire [31:0] drop_total,
  input  wire [31:0] jit_max_us,
  input  wire [31:0] buf_util,
  output wire [7:0]  stats_off,
  input  wire [31:0] stats_data,
  input  wire [31:0] vl_data,
  input  wire        vl_bag_allowed,
  // SET 写回
  output reg         ctl_we,
  output reg  [15:0] ctl_wdata,
  output reg         vl_bag_we,
  output reg  [7:0]  vl_bag_index,
  output reg  [31:0] vl_bag_wdata,
  output wire [7:0]  mib_group,
  output wire [7:0]  mib_leaf,
  output wire [7:0]  mib_index,
  // Optional SET transaction integration. set_active covers validation/commit;
  // downstream acknowledges a write only when its side effects really commit.
  input  wire        set_ack,
  output wire        set_active,
  // 响应
  output reg         resp_vld,
  output reg  [10:0] resp_len,
  input  wire        resp_ack,
  input  wire [10:0] resp_rd_addr,
  output wire [7:0]  resp_byte,
  // 观测
  output reg  [31:0] rx_pdu_cnt,
  output reg  [31:0] resp_cnt,
  output reg  [31:0] drop_pdu_cnt,
  output reg  [3:0]  last_err,
  output reg  [3:0]  last_idx,
  output reg  [7:0]  last_pdu,
  output reg  [15:0] peer_port,
  output reg  [3:0]  vb_n,
  output wire [5:0]  state_o
);
  // ---------------- 常量 ----------------
  localparam [7:0] T_INT = 8'h02, T_OCT = 8'h04, T_NUL = 8'h05, T_OID = 8'h06,
                   T_SEQ = 8'h30, T_CNT = 8'h41, T_GAU = 8'h42, T_TIM = 8'h43;
  localparam [7:0] PDU_GET = 8'hA0, PDU_NXT = 8'hA1, PDU_RSP = 8'hA2, PDU_SET = 8'hA3;
  localparam integer COMM_N = 6;                      // "public"

  reg [7:0] oidb [0:15];

  // ---------------- 接收 ----------------
  reg [8:0] wp;
  reg [8:0] req_len;
  reg       have_pkt;
  reg       rx_acc;            // 当前入站包已被接收（A02）
  reg       rx_overflow, pkt_oversize;
  reg [15:0] rx_peer, req_peer; // response peer is latched when its request starts
  wire      rx_can_take;       // 可接收新包：解析空闲且无待处理包（定义见状态寄存器后）
  wire      rx_rej;            // 本拍 SOP 被整包拒收
  assign in_ready = !rst_sync && rx_can_take;

  // ---------------- 解析状态 ----------------
  localparam [6:0]
    P_IDLE=0,  P_SEQT=1,  P_SEQL=2,  P_VERT=3,  P_VERL=4,  P_VERV=5,
    P_COMT=6,  P_COML=7,  P_COMB=8,  P_PDUT=9,  P_PDUL=10, P_RIDT=11,
    P_RIDL=12, P_RIDB=13, P_EST=14,  P_ESL=15,  P_ESV=16,  P_EIT=17,
    P_EIL=18,  P_EIV=19,  P_VBLT=20, P_VBLL=21, P_VBT=22,  P_VBLN=23,
    P_OIDT=24, P_OIDL=25, P_OIDB=26, P_VALT=27, P_VALL=28, P_VALB=29,
    P_RESOLVE=30, P_BUILD=31, P_DROP=32,
    P_BUILD2=67, P_BUILD3=68, P_BUILD4=69,   // 长度计算流水（continue10 时序修复）
    P_RESOLVE2=70,                           // OID 解析结果寄存后再取值（continue10 时序修复）
    P_COMMIT=71,                             // SET 两阶段提交（核查 A01）
    P_BUILD5=72, P_COMMIT_WAIT=73,           // full response bound; commit acknowledgement
    P_RESOLVE3=74,                           // posedge BRAM：地址稳后等读出
    P_RESOLVE4=75,                           // 再一拍后采 vl_data（避免同沿 NBA 见旧值）
    P_RESOLVE1=76,                           // 2026-10-07：walk() 结果打拍，切开 oid_len→rq_l
    E_SEQT=33, E_SEQL1=34, E_SEQL2=35, E_VER0=36, E_VER1=37, E_VER2=38,
    E_COMT=39, E_COML=40, E_COMB=41, E_PDUT=42, E_PDUL1=43, E_PDUL2=44,
    E_RIDT=45, E_RIDL=46, E_RIDB=47, E_ES0=48, E_ES1=49, E_ES2=50,
    E_EI0=51,  E_EI1=52,  E_EI2=53,  E_VBLT=54, E_VBLL1=55, E_VBLL2=56,
    E_VBT=57,  E_VBL=58,  E_OIDT=59, E_OIDL=60, E_OIDB=61,
    E_VALT=62, E_VALL=63, E_VALB=64, E_NEXT=65, E_FIN=66,
    E_VBCOPY=77;                             // 错误响应回抄已校验的原始 VarBindList

  reg [6:0]  st;
  reg [3:0]  ci;               // P_COMMIT 提交序号
  assign rx_can_take = !have_pkt && !rx_acc && (st == P_IDLE);
  assign rx_rej      = en && in_vld && in_sop && !rx_can_take;
  reg [8:0]  pp;               // 解析指针
  reg [8:0]  msg_end, pdu_end, vbl_end, vb_end;
  reg [8:0]  vbl_pos, copy_pos;
  reg [7:0]  req_vbl_len;
  reg        lp;               // 长式长度待读
  reg [7:0]  ver;
  reg [8:0]  comm_pos; reg [7:0] comm_len; reg [7:0] comm_i; reg comm_ok;
  reg [7:0]  pdu_t;
  reg [8:0]  rid_pos; reg [7:0] rid_len; reg [7:0] rid_i;
  reg [7:0]  oid_len, oid_i;
  reg [7:0]  sv_tag, sv_len, sv_i;
  reg [31:0] sv_val;
  reg        sv_neg;
  reg [3:0]  nvb;
  reg [3:0]  ei;               // 当前 VarBind 序号（0 起）
  reg [3:0]  err_st, err_ix;
  reg        vb_ovf;

  reg [7:0]  vb_grp  [0:7];
  reg [7:0]  vb_leaf [0:7];
  reg [7:0]  vb_inst [0:7];
  reg [7:0]  vb_tag  [0:7];
  reg [31:0] vb_val  [0:7];
  reg        vb_str  [0:7];

  // Bound every request byte by both received length and its containing TLV.
  // Use 10-bit arithmetic BEFORE narrowing: pp + 1 + length must not wrap.
  // Single shared read mux/BRAM port: many req[pp] combo fans were ~60k LE.
  wire [7:0] req_rd_addr = (st == E_COMB) ? (comm_pos[7:0] + comm_i) :
                           (st == E_RIDB) ? (rid_pos[7:0] + rid_i) :
                           (st == E_VBCOPY) ? copy_pos[7:0] :
                           pp[7:0];
  wire       req_we = en && in_vld &&
                      ((in_sop && rx_can_take) ||
                       (!in_sop && rx_acc && (wp < 9'd256)));
  wire [7:0] req_wa = (in_sop && rx_can_take) ? 8'd0 : wp[7:0];
  // 请求窗：上升沿同步读。地址（pp / community / request-id）变化后由
  // ram_got 空一拍，再在下一拍用 req_b。禁止 RD_NEG，避免 eLinx 把 256×32
  // 展开成触发器（综合曾见 ~9k $dffe / ~10k $eq）。
  wire [7:0] req_b;
  bram_1w1r #(.W(8), .D(256), .RD_NEG(0)) u_req (
    .clk(clk), .wr_en(req_we), .wr_addr(req_wa), .wr_data(in_data),
    .rd_addr(req_rd_addr), .rd_data(req_b));
  reg ram_got;
  wire [9:0] tlv_end = {1'b0,pp} + 10'd1 + {2'd0,req_b};
  wire parse_outer = (st == P_SEQT) || (st == P_SEQL) ||
                     (st == P_VERT) || (st == P_VERL) || (st == P_VERV) ||
                     (st == P_COMT) || (st == P_COML) || (st == P_COMB) ||
                     (st == P_PDUT) || (st == P_PDUL);
  wire parse_pdu = (st == P_RIDT) || (st == P_RIDL) || (st == P_EST) ||
                   (st == P_ESL) || (st == P_ESV) || (st == P_EIT) ||
                   (st == P_EIL) || (st == P_EIV) || (st == P_VBLT) ||
                   (st == P_VBLL);
  wire parse_list = (st == P_VBT) || (st == P_VBLN);
  wire parse_vb = (st == P_OIDT) || (st == P_OIDL) || (st == P_OIDB) ||
                  (st == P_VALT) || (st == P_VALL) || (st == P_VALB);
  wire parse_byte = parse_outer || parse_pdu || parse_list || parse_vb;
  wire need_req_byte = parse_byte || (st == E_COMB) || (st == E_RIDB) ||
                       (st == E_VBCOPY);
  wire [8:0] parse_limit = (st == P_SEQT || st == P_SEQL) ? req_len :
                          parse_outer ? msg_end :
                          parse_pdu ? pdu_end :
                          parse_list ? vbl_end : vb_end;
  wire read_oob = parse_byte && (pp >= parse_limit);

  // ---------------- 编码 ----------------
  reg [8:0]  ep;               // 响应写指针
  reg [3:0]  vi, ek;
  reg [8:0]  msg_len, pdu_len, vbl_len;
  reg [7:0]  vb_tl [0:7];      // 每个 VarBind 的内容长度
  reg        emit_done;

  wire is_set = (pdu_t == PDU_SET);
  // This is a transaction lock, not an input-byte ready signal. It also
  // prevents host TX configuration writes racing a validated multi-object SET.
  assign set_active = (SET_ACK_EN != 0) && is_set && (err_st == 4'd0) &&
                      (((st >= P_PDUL) && (st <= P_BUILD)) ||
                       ((st >= P_BUILD2) && (st <= P_COMMIT_WAIT)) ||
                       (st == P_RESOLVE1) || (st == P_RESOLVE2) ||
                       (st == P_RESOLVE3) || (st == P_RESOLVE4));
  assign state_o = st[5:0];
  wire rsp_we = !rst_sync && (
    (st == E_SEQT) || (st == E_SEQL1) || (st == E_SEQL2) ||
    (st == E_VER0) || (st == E_VER1) || (st == E_VER2) ||
    (st == E_COMT) || (st == E_COML) || (st == E_COMB) ||
    (st == E_PDUT) || (st == E_PDUL1) || (st == E_PDUL2) ||
    (st == E_RIDT) || (st == E_RIDL) || (st == E_RIDB) ||
    (st == E_ES0) || (st == E_ES1) || (st == E_ES2) ||
    (st == E_EI0) || (st == E_EI1) || (st == E_EI2) ||
    (st == E_VBLT) || (st == E_VBLL1) || (st == E_VBLL2) ||
    (st == E_VBT) || (st == E_VBL) || (st == E_OIDT) ||
    (st == E_OIDL) || (st == E_OIDB) || (st == E_VALT) ||
    (st == E_VALL) || (st == E_VALB) ||
    ((st == E_VBCOPY) && ram_got));

  // ================= 工具函数 =================
  function [7:0] comm_ch; input [7:0] k;
    begin case (k) 0:comm_ch="p";1:comm_ch="u";2:comm_ch="b";3:comm_ch="l";
                   4:comm_ch="i";5:comm_ch="c"; default: comm_ch=8'h00; endcase end
  endfunction
  function [7:0] dch; input [7:0] k;   // "AFDX-ES eLinx v1"
    begin case (k) 0:dch="A";1:dch="F";2:dch="D";3:dch="X";4:dch="-";5:dch="E";
                   6:dch="S";7:dch=" ";8:dch="e";9:dch="L";10:dch="i";11:dch="n";
                   12:dch="x";13:dch=" ";14:dch="v";15:dch="1"; default:dch=8'h20; endcase end
  endfunction
  function [7:0] pfx_ch; input [7:0] k;  // 1.3.6.1.4.1.4444.1
    begin case (k) 0:pfx_ch=8'h2B;1:pfx_ch=8'h06;2:pfx_ch=8'h01;3:pfx_ch=8'h04;
                   4:pfx_ch=8'h01;5:pfx_ch=8'hA2;6:pfx_ch=8'h5C;7:pfx_ch=8'h01;
                   default: pfx_ch=8'h00; endcase end
  endfunction
  function [9:0] idx_of; input [7:0] g; input [7:0] l; input [7:0] x;
    begin
      idx_of = 10'h3FF;
      if (g == 8'd1 && x == 8'd0)
        case (l) 8'd1:idx_of=10'd0; 8'd2:idx_of=10'd1; 8'd3:idx_of=10'd2; 8'd4:idx_of=10'd3;
                 8'd10:idx_of=10'd644; 8'd11:idx_of=10'd645;
                 8'd12:idx_of=10'd646; 8'd13:idx_of=10'd647;
                 default: idx_of=10'h3FF; endcase
      else if (g == 8'd1 && l >= 8'd5 && l <= 8'd9 && x < 8'd128)
        idx_of = 10'd4 + ((l - 8'd5) * 10'd128) + x;
      else if (g == 8'd2 && l < 8'd48 && x == 8'd0)
        idx_of = 10'd648 + l;
    end
  endfunction
  function [7:0] grp_i; input [9:0] i;
    begin grp_i = (i < 10'd648) ? 8'd1 : 8'd2; end
  endfunction
  function [7:0] leaf_i; input [9:0] i;
    begin
      if (i < 10'd4) leaf_i = i + 8'd1;
      else if (i < 10'd644) leaf_i = 8'd5 + ((i - 10'd4) / 10'd128);
      else if (i < 10'd648) leaf_i = 8'd10 + (i - 10'd644);
      else leaf_i = i - 10'd648;
    end
  endfunction
  function [7:0] inst_i; input [9:0] i;
    begin inst_i = (i >= 10'd4 && i < 10'd644) ? ((i - 10'd4) % 10'd128) : 8'd0; end
  endfunction
  // GETNEXT 有序游走；indexed 对象按 instance 递增。
  // continue6: 目录是四段连续区间，直接做区间译码，避免把 696 次
  // 24-bit 比较/优先选择完全展开成一条巨型组合链。
  function [9:0] walk; input [7:0] g; input [7:0] l; input [7:0] x; input hi;
    reg [9:0] base;
    begin
      walk = 10'h3FF;
      base = 10'd0;
      if (g < 8'd1) begin
        walk = 10'd0;
      end else if (g == 8'd1) begin
        if (l < 8'd1) begin
          walk = 10'd0;
        end else if (l <= 8'd4) begin
          base = {2'd0, l} - 10'd1;
          if (!hi)        walk = base;
          else if (l < 4) walk = base + 10'd1;
          else            walk = 10'd4;
        end else if (l <= 8'd9) begin
          base = 10'd4 + ((l - 8'd5) * 10'd128);
          if (!hi)          walk = base;
          else if (x < 127) walk = base + {2'd0, x} + 10'd1;
          else if (l < 9)   walk = base + 10'd128;
          else              walk = 10'd644;
        end else if (l <= 8'd13) begin
          base = 10'd644 + (l - 8'd10);
          if (!hi)         walk = base;
          else if (l < 13) walk = base + 10'd1;
          else             walk = 10'd648;
        end else begin
          walk = 10'd648;
        end
      end else if (g == 8'd2) begin
        if (l < 8'd48) begin
          base = 10'd648 + {2'd0, l};
          if (!hi)         walk = base;
          else if (l < 47) walk = base + 10'd1;
        end
      end
    end
  endfunction
  function [3:0] ilen; input [31:0] v;       // 最小长度正整数 BER 编码长度
    begin
      if      (v < 32'h0000_0080) ilen = 4'd1;
      else if (v < 32'h0000_8000) ilen = 4'd2;
      else if (v < 32'h0080_0000) ilen = 4'd3;
      else if (v < 32'h8000_0000) ilen = 4'd4;
      else                        ilen = 4'd5;
    end
  endfunction
  function [7:0] ibyte; input [31:0] v; input [3:0] n; input [3:0] k;
    reg [5:0] sh;
    begin
      if (n == 4'd5) begin
        if (k == 4'd0) ibyte = 8'h00;
        else begin sh = 6'd8 * (4 - k); ibyte = v >> sh; end
      end else begin
        sh = 6'd8 * (n - 4'd1 - k); ibyte = v >> sh;
      end
    end
  endfunction

  // ================= 单 VarBind 组合求值 =================
  wire [7:0] o_g = (oid_len >= 8'd9)  ? oidb[8]  : 8'd0;
  wire [7:0] o_l = (oid_len >= 8'd10) ? oidb[9]  : 8'd0;
  wire [7:0] o_i = (oid_len >= 8'd11) ? oidb[10] : 8'd0;
  wire       pfx_ok = (oid_len >= 8'd8) &&
                      (oidb[0]==8'h2B)&&(oidb[1]==8'h06)&&(oidb[2]==8'h01)&&(oidb[3]==8'h04)&&
                      (oidb[4]==8'h01)&&(oidb[5]==8'hA2)&&(oidb[6]==8'h5C)&&(oidb[7]==8'h01);
  wire       has_inst = (oid_len == 8'd11);
  wire [9:0] gi  = idx_of(o_g, o_l, o_i);
  wire [9:0] wi  = walk(o_g, o_l, o_i, has_inst);
  wire       is_get = (pdu_t == PDU_GET);
  wire       is_nxt = (pdu_t == PDU_NXT);
  wire       index_obj = (o_g == 8'd1) && (o_l >= 8'd5) && (o_l <= 8'd9);
  wire       instance_ok = index_obj ? (has_inst && o_i < 8'd128)
                                     : (has_inst && o_i == 8'd0);
  wire       get_ok = pfx_ok && instance_ok && (gi != 10'h3FF);
  wire       nxt_ok = pfx_ok && (wi != 10'h3FF);
  wire [7:0] r_g = is_nxt ? grp_i(wi)  : o_g;
  wire [7:0] r_l = is_nxt ? leaf_i(wi) : o_l;
  wire [7:0] r_i = is_nxt ? inst_i(wi) : o_i;
  wire       set_rw = get_ok && ((o_g == 8'd1 && o_l == 8'd11 && o_i == 8'd0) ||
                                 (o_g == 8'd1 && o_l == 8'd5 && vl_bag_allowed));
  wire [3:0] r_err = is_nxt ? (nxt_ok ? 4'd0 : 4'd2)
                   : is_get ? (get_ok ? 4'd0 : 4'd2)
                   : (!get_ok)              ? 4'd2
                   : (!set_rw)              ? 4'd4
                   : (sv_tag != T_INT || sv_len == 8'd0 || sv_len > 8'd4 || sv_neg) ? 4'd3
                   : ((o_g == 8'd1 && o_l == 8'd5) &&
                      (sv_val == 32'd0 || sv_val > 32'h007F_FFFE)) ? 4'd3
                   : (((o_g == 8'd1 && o_l == 8'd5) && (sv_val > 32'h00FF_FFFF)) ||
                      (!(o_g == 8'd1 && o_l == 8'd5) && (sv_val > 32'h0000_FFFF))) ? 4'd3 : 4'd0;
  // 解析结果寄存：原 P_RESOLVE 一拍内 walk()→rq_* 在 post-fit 上 oid_len→rq_l
  // 为 −0.246（timing_cut_v4）。现拆 P_RESOLVE（锁 walk/oid 域）→ P_RESOLVE1
  // （leaf_i/grp_i→rq_*）→ P_RESOLVE2..4（BRAM 取值）。对外查询口仍由 rq_* 驱动。
  reg [7:0] rq_g, rq_l, rq_i;
  reg [9:0] wi_q;
  reg [7:0] o_g_q, o_l_q, o_i_q;
  reg       use_next_q;
  assign stats_off = rq_l;
  assign mib_group = rq_g;
  assign mib_leaf  = rq_l;
  assign mib_index = rq_i;
  reg [7:0]  n_tag; reg [31:0] n_val; reg n_str;
  always @(*) begin
    n_tag = T_CNT; n_val = 32'd0; n_str = 1'b0;
    if (rq_g == 8'd2) begin n_tag = T_CNT; n_val = stats_data; end
    else case (rq_l)
      8'd1:  begin n_tag = T_OCT; n_str = 1'b1; end
      8'd2:  begin n_tag = T_TIM; n_val = uptime_cs; end
      8'd3:  begin n_tag = T_INT; n_val = NUM_TX_VL[31:0]; end
      8'd4:  begin n_tag = T_INT; n_val = NUM_RX_VL[31:0]; end
      8'd5:  begin n_tag = T_INT; n_val = is_set ? sv_val : vl_data; end
      8'd6:  begin n_tag = T_INT; n_val = vl_data; end
      8'd7:  begin n_tag = T_CNT; n_val = vl_data; end
      8'd8:  begin n_tag = T_CNT; n_val = vl_data; end
      8'd9:  begin n_tag = T_CNT; n_val = vl_data; end
      8'd10: begin n_tag = T_INT; n_val = jit_max_us; end
      8'd11: begin n_tag = T_INT; n_val = is_set ? {16'd0, sv_val[15:0]} : {16'd0, ctl_val}; end
      8'd12: begin n_tag = T_CNT; n_val = drop_total; end
      8'd13: begin n_tag = T_GAU; n_val = buf_util; end
      default: begin n_tag = T_CNT; n_val = 32'd0; end
    endcase
  end

  // ================= 编码期的每 VarBind 取值 =================
  reg [7:0]  e_tag_q;
  reg        e_isstr_q;
  reg [3:0]  e_vlen_q;
  reg [31:0] e_val_q;
  wire [7:0]  e_tag   = e_tag_q;
  wire        e_isstr = e_isstr_q;
  wire [3:0]  e_vlen  = e_vlen_q;
  wire [7:0]  e_vlen8 = e_isstr ? 8'd16 : {4'd0, e_vlen};
  wire [7:0]  e_vbyte = e_isstr ? dch({4'd0, ek}) : ibyte(e_val_q, e_vlen, ek);
  wire [7:0]  e_oidb  = (ek < 4'd8) ? pfx_ch({4'd0, ek}) :
                        (ek == 4'd8) ? vb_grp[vi[2:0]] :
                        (ek == 4'd9) ? vb_leaf[vi[2:0]] : 8'h00;

  wire [7:0] e_inst_byte = vb_inst[vi[2:0]];
  reg [7:0] rsp_wd;
  always @(*) begin
    rsp_wd = 8'd0;
    case (st)
      E_SEQT:  rsp_wd = T_SEQ;
      E_SEQL1: rsp_wd = (msg_len > 9'd127) ? 8'h81 : msg_len[7:0];
      E_SEQL2: rsp_wd = msg_len[7:0];
      E_VER0:  rsp_wd = T_INT;
      E_VER1:  rsp_wd = 8'd1;
      E_VER2:  rsp_wd = ver;
      E_COMT:  rsp_wd = T_OCT;
      E_COML:  rsp_wd = comm_len;
      E_COMB:  rsp_wd = req_b;
      E_PDUT:  rsp_wd = PDU_RSP;
      E_PDUL1: rsp_wd = (pdu_len > 9'd127) ? 8'h81 : pdu_len[7:0];
      E_PDUL2: rsp_wd = pdu_len[7:0];
      E_RIDT:  rsp_wd = T_INT;
      E_RIDL:  rsp_wd = rid_len;
      E_RIDB:  rsp_wd = req_b;
      E_ES0:   rsp_wd = T_INT;
      E_ES1:   rsp_wd = 8'd1;
      E_ES2:   rsp_wd = {4'd0, err_st};
      E_EI0:   rsp_wd = T_INT;
      E_EI1:   rsp_wd = 8'd1;
      E_EI2:   rsp_wd = {4'd0, err_ix};
      E_VBLT:  rsp_wd = T_SEQ;
      E_VBLL1: rsp_wd = (vbl_len > 9'd127) ? 8'h81 : vbl_len[7:0];
      E_VBLL2: rsp_wd = vbl_len[7:0];
      E_VBT:   rsp_wd = T_SEQ;
      E_VBL:   rsp_wd = vb_tl[vi[2:0]];
      E_OIDT:  rsp_wd = T_OID;
      E_OIDL:  rsp_wd = 8'd11;
      E_OIDB:  rsp_wd = (ek == 4'd10) ? e_inst_byte : e_oidb;
      E_VALT:  rsp_wd = e_tag;
      E_VALL:  rsp_wd = e_vlen8;
      E_VALB:  rsp_wd = e_vbyte;
      E_VBCOPY: rsp_wd = req_b;
      default: rsp_wd = 8'd0;
    endcase
  end
  wire [7:0] rsp_word;
  assign resp_byte = rsp_word;
  bram_1w1r #(.W(8), .D(256), .RD_NEG(0)) u_rsp (
    .clk(clk), .wr_en(rsp_we), .wr_addr(ep[7:0]), .wr_data(rsp_wd),
    .rd_addr(resp_rd_addr[7:0]), .rd_data(rsp_word));
  // 长度计算：原 P_BUILD 在一拍内对 8 个 VarBind 做 ilen 比较 + 串行累加 + 4 级 TLV 加法，
  // post-fit 关键路径 28 级 / 12.5 ns（continue10/POST-FIT-FINDINGS.md 根因 A）。
  // 现拆为：P_BUILD 每拍处理一个 VarBind 累加到 acc_r；P_BUILD2 tooBig 判决；
  // P_BUILD3 求 vbl/pdu 长度；P_BUILD4 求 msg 长度。响应延迟增加 ≤ 11 拍，语义不变。
  reg [3:0] bi;                // 当前累加的 VarBind 序号
  reg [8:0] acc_r;             // VarBind 列表内容长度累加器
  wire [7:0] tl_w = vb_str[bi[2:0]]     ? 8'd31 :                       // + OCTET STRING(16)
                    8'd15 + {4'd0, ilen(vb_val[bi[2:0]])};             // + INTEGER(2+ilen)
  wire [8:0] vbl_tl_w = 9'd2 + ((acc_r   > 9'd127) ? 9'd1 : 9'd0) + acc_r;
  wire [8:0] pdu_tl_w = 9'd2 + ((pdu_len > 9'd127) ? 9'd1 : 9'd0) + pdu_len;
  wire [9:0] rsp_total = {1'b0,msg_len} + ((msg_len > 9'd127) ? 10'd3 : 10'd2);
`ifndef SYNTHESIS
  initial begin
    if (MAX_VB < 1 || MAX_VB > 8) $fatal(1, "snmp_lite MAX_VB must be 1..8");
  end
`endif

  always @(posedge clk) begin
    if (rst_sync) begin
      wp <= 9'd0; req_len <= 9'd0; have_pkt <= 1'b0; st <= P_IDLE;
      rx_acc <= 1'b0; ci <= 4'd0;
      rx_overflow <= 1'b0; pkt_oversize <= 1'b0;
      rx_peer <= 16'd0; req_peer <= 16'd0;
      msg_end <= 9'd0; pdu_end <= 9'd0; vbl_end <= 9'd0; vb_end <= 9'd0;
      vbl_pos <= 9'd0; copy_pos <= 9'd0; req_vbl_len <= 8'd0;
      sv_neg <= 1'b0;
      resp_vld <= 1'b0; resp_len <= 11'd0; ctl_we <= 1'b0; ctl_wdata <= 16'd0;
      vl_bag_we <= 1'b0; vl_bag_index <= 8'd0; vl_bag_wdata <= 32'd0;
      rx_pdu_cnt <= 32'd0; resp_cnt <= 32'd0; drop_pdu_cnt <= 32'd0;
      last_err <= 4'd0; last_idx <= 4'd0; last_pdu <= 8'd0; peer_port <= 16'd0;
      vb_n <= 4'd0; nvb <= 4'd0; ei <= 4'd0; err_st <= 4'd0; err_ix <= 4'd0;
      lp <= 1'b0; pp <= 9'd0; ep <= 9'd0; vi <= 4'd0; ek <= 4'd0;
      ram_got <= 1'b0;
      comm_ok <= 1'b0; vb_ovf <= 1'b0; emit_done <= 1'b0;
      msg_len <= 9'd0; pdu_len <= 9'd0; vbl_len <= 9'd0;
      bi <= 4'd0; acc_r <= 9'd0;
      rq_g <= 8'd0; rq_l <= 8'd0; rq_i <= 8'd0;
      wi_q <= 10'd0; o_g_q <= 8'd0; o_l_q <= 8'd0; o_i_q <= 8'd0; use_next_q <= 1'b0;
      e_tag_q <= T_NUL; e_isstr_q <= 1'b0; e_vlen_q <= 4'd0; e_val_q <= 32'd0;
    end else begin
      ctl_we <= 1'b0;
      vl_bag_we <= 1'b0;
      if (resp_ack && resp_vld) resp_vld <= 1'b0;

      // ---------- 收包（A02：单待处理槽，忙则整包拒收并计数）----------
      if (en && in_vld) begin
        if (in_sop) begin
          if (rx_can_take) begin
            wp <= 9'd1;
            rx_acc <= !in_eop; rx_overflow <= 1'b0; rx_peer <= in_sport;
            if (in_eop) begin
              req_len <= 9'd1; have_pkt <= 1'b1; req_peer <= in_sport;
              pkt_oversize <= 1'b0;
            end
          end else begin
            rx_acc <= 1'b0;                        // 本包其余字节全部忽略
          end
        end else if (rx_acc) begin
          if (wp < 9'd256) begin wp <= wp + 9'd1; end
          else rx_overflow <= 1'b1; // saturate the pointer, never wrap a long PDU
          if (in_eop) begin
            req_len  <= (wp < 9'd256) ? wp + 9'd1 : 9'd256;
            pkt_oversize <= rx_overflow || (wp >= 9'd256);
            have_pkt <= 1'b1; req_peer <= rx_peer;
            rx_acc   <= 1'b0;
          end
        end
      end
      // 解析非法（P_DROP）与忙拒收可能同拍发生，合并累加
      drop_pdu_cnt <= drop_pdu_cnt + {31'd0, rx_rej} + {31'd0, (st == P_DROP)};

      if (read_oob) begin
        ram_got <= 1'b0;
        st <= P_DROP; // no request read, metadata update, or SET side effect
      end else if (need_req_byte && !ram_got) begin
        ram_got <= 1'b1;
      end else begin
      ram_got <= 1'b0;
      case (st)
        // =============== 解析 ===============
        P_IDLE: if (have_pkt && !resp_vld) begin
          have_pkt <= 1'b0; pp <= 9'd0; lp <= 1'b0;
          st <= (pkt_oversize || req_len < 9'd2 || req_len > 9'd256) ? P_DROP : P_SEQT;
          peer_port <= req_peer;
          bi <= 4'd0; acc_r <= 9'd0; ci <= 4'd0;
          nvb <= 4'd0; ei <= 4'd0; err_st <= 4'd0; err_ix <= 4'd0; vb_ovf <= 1'b0;
          rx_pdu_cnt <= rx_pdu_cnt + 32'd1;
        end
        P_SEQT: begin
          if (req_b != T_SEQ) st <= P_DROP;
          else begin pp <= pp + 9'd1; st <= P_SEQL; end
        end
        P_SEQL: begin
          if (!lp && req_b == 8'h81) begin lp <= 1'b1; pp <= pp + 9'd1; end
          else if (lp || req_b < 8'h80) begin
            lp <= 1'b0;
            if (!(tlv_end == {1'b0,req_len})) st <= P_DROP;
            else begin
              msg_end <= tlv_end[8:0];
              pp <= pp + 9'd1; st <= P_VERT;
            end
          end else st <= P_DROP;
        end
        P_VERT: begin
          if (req_b != T_INT) st <= P_DROP;
          else begin pp <= pp + 9'd1; st <= P_VERL; end
        end
        P_VERL: begin
          if (!lp && req_b == 8'h81) begin lp <= 1'b1; pp <= pp + 9'd1; end
          else if (lp || req_b < 8'h80) begin
            lp <= 1'b0;
            if (!(req_b == 8'd1 && tlv_end <= {1'b0,msg_end})) st <= P_DROP;
            else begin
              
              pp <= pp + 9'd1; st <= P_VERV;
            end
          end else st <= P_DROP;
        end
        P_VERV: begin
          ver <= req_b;
          // P04（2026-10-10）单一版本范围：只接受 SNMPv1（version=0）。
          // 比赛未指定版本；错误语义（noSuchName/readOnly/badValue）为 v1 风格，
          // 因此不再接受 v2c(1)——version≠0 一律静默丢弃并计入 drop_pdu_cnt，
          // 使接受范围、实现与测试/报告一致。如需 v2c 例外语义须另行实现。
          if (req_b != 8'd0) st <= P_DROP;
          else begin pp <= pp + 9'd1; st <= P_COMT; end
        end
        P_COMT: begin
          if (req_b != T_OCT) st <= P_DROP;
          else begin pp <= pp + 9'd1; st <= P_COML; end
        end
        P_COML: begin
          if (!lp && req_b == 8'h81) begin lp <= 1'b1; pp <= pp + 9'd1; end
          else if (lp || req_b < 8'h80) begin
            lp <= 1'b0;
            if (!(req_b == COMM_N[7:0] && tlv_end <= {1'b0,msg_end})) st <= P_DROP;
            else begin
              comm_len <= req_b; comm_pos <= pp + 9'd1; comm_i <= 8'd0; comm_ok <= 1'b1;
              pp <= pp + 9'd1; st <= P_COMB;
            end
          end else st <= P_DROP;
        end
        P_COMB: begin
          if (req_b != comm_ch(comm_i)) comm_ok <= 1'b0;
          comm_i <= comm_i + 8'd1;
          pp <= pp + 9'd1;
          if (comm_i + 8'd1 >= comm_len) st <= P_PDUT;
        end
        P_PDUT: begin
          pdu_t    <= req_b;
          last_pdu <= req_b;
          if (!comm_ok) st <= P_DROP;
          else if (req_b != PDU_GET && req_b != PDU_NXT &&
                   req_b != PDU_SET) st <= P_DROP;
          else begin pp <= pp + 9'd1; st <= P_PDUL; end
        end
        P_PDUL: begin
          if (!lp && req_b == 8'h81) begin lp <= 1'b1; pp <= pp + 9'd1; end
          else if (lp || req_b < 8'h80) begin
            lp <= 1'b0;
            if (!(tlv_end == {1'b0,msg_end})) st <= P_DROP;
            else begin
              pdu_end <= tlv_end[8:0];
              pp <= pp + 9'd1; st <= P_RIDT;
            end
          end else st <= P_DROP;
        end
        P_RIDT: begin
          if (req_b != T_INT) st <= P_DROP;
          else begin pp <= pp + 9'd1; st <= P_RIDL; end
        end
        P_RIDL: begin
          if (!lp && req_b == 8'h81) begin lp <= 1'b1; pp <= pp + 9'd1; end
          else if (lp || req_b < 8'h80) begin
            lp <= 1'b0;
            if (req_b == 8'd0 || req_b > 8'd5 || tlv_end > {1'b0,pdu_end}) st <= P_DROP;
            else begin rid_len <= req_b; rid_pos <= pp + 9'd1;
              pp <= tlv_end[8:0]; st <= P_EST; end
          end else st <= P_DROP;
        end
        P_EST:  begin if (req_b != T_INT) st <= P_DROP;
                      else begin pp <= pp + 9'd1; st <= P_ESL; end end
        P_ESL: begin
          if (!lp && req_b == 8'h81) begin lp <= 1'b1; pp <= pp + 9'd1; end
          else if (lp || req_b < 8'h80) begin
            lp <= 1'b0;
            if (!(req_b == 8'd1 && tlv_end <= {1'b0,pdu_end})) st <= P_DROP;
            else begin
              
              pp <= pp + 9'd1; st <= P_ESV;
            end
          end else st <= P_DROP;
        end
        P_ESV:  begin pp <= pp + 9'd1; st <= P_EIT; end
        P_EIT:  begin if (req_b != T_INT) st <= P_DROP;
                      else begin pp <= pp + 9'd1; st <= P_EIL; end end
        P_EIL: begin
          if (!lp && req_b == 8'h81) begin lp <= 1'b1; pp <= pp + 9'd1; end
          else if (lp || req_b < 8'h80) begin
            lp <= 1'b0;
            if (!(req_b == 8'd1 && tlv_end <= {1'b0,pdu_end})) st <= P_DROP;
            else begin
              
              pp <= pp + 9'd1; st <= P_EIV;
            end
          end else st <= P_DROP;
        end
        P_EIV:  begin pp <= pp + 9'd1; st <= P_VBLT; end
        P_VBLT: begin if (req_b != T_SEQ) st <= P_DROP;
                      else begin pp <= pp + 9'd1; st <= P_VBLL; end end
        P_VBLL: begin
          if (!lp && req_b == 8'h81) begin lp <= 1'b1; pp <= pp + 9'd1; end
          else if (lp || req_b < 8'h80) begin
            lp <= 1'b0;
            if (!(tlv_end == {1'b0,pdu_end})) st <= P_DROP;
            else begin
              vbl_end <= tlv_end[8:0];
              vbl_pos <= pp + 9'd1; req_vbl_len <= req_b;
              pp <= pp + 9'd1; st <= (req_b == 8'd0) ? P_BUILD : P_VBT;
            end
          end else st <= P_DROP;
        end
        P_VBT:  begin if (req_b != T_SEQ) st <= P_DROP;
                      else begin pp <= pp + 9'd1; st <= P_VBLN; end end
        P_VBLN: begin
          if (!lp && req_b == 8'h81) begin lp <= 1'b1; pp <= pp + 9'd1; end
          else if (lp || req_b < 8'h80) begin
            lp <= 1'b0;
            if (!(req_b != 8'd0 && tlv_end <= {1'b0,vbl_end})) st <= P_DROP;
            else begin
              vb_end <= tlv_end[8:0];
              pp <= pp + 9'd1; st <= P_OIDT;
            end
          end else st <= P_DROP;
        end
        P_OIDT: begin if (req_b != T_OID) st <= P_DROP;
                      else begin pp <= pp + 9'd1; st <= P_OIDL; end end
        P_OIDL: begin
          if (!lp && req_b == 8'h81) begin lp <= 1'b1; pp <= pp + 9'd1; end
          else if (lp || req_b < 8'h80) begin
            lp <= 1'b0;
            if (!(req_b != 8'd0 && req_b <= 8'd16 && tlv_end <= {1'b0,vb_end})) st <= P_DROP;
            else begin
              oid_len <= req_b; oid_i <= 8'd0;
              pp <= pp + 9'd1; st <= P_OIDB;
            end
          end else st <= P_DROP;
        end
        P_OIDB: begin
          oidb[oid_i[3:0]] <= req_b;
          oid_i <= oid_i + 8'd1;
          pp <= pp + 9'd1;
          if (oid_i + 8'd1 >= oid_len) st <= P_VALT;
        end
        P_VALT: begin sv_tag <= req_b; sv_val <= 32'd0; sv_neg <= 1'b0;
                      pp <= pp + 9'd1; st <= P_VALL; end
        P_VALL: begin
          if (!lp && req_b == 8'h81) begin lp <= 1'b1; pp <= pp + 9'd1; end
          else if (lp || req_b < 8'h80) begin
            lp <= 1'b0;
            if (!(tlv_end == {1'b0,vb_end} && (sv_tag != T_NUL || req_b == 8'd0))) st <= P_DROP;
            else begin
              sv_len <= req_b; sv_i <= 8'd0;
              pp <= pp + 9'd1; st <= (req_b == 8'd0) ? P_RESOLVE : P_VALB;
            end
          end else st <= P_DROP;
        end
        P_VALB: begin
          if (sv_i == 8'd0) sv_neg <= req_b[7];
          if (sv_i < 8'd4) sv_val <= {sv_val[23:0], req_b};
          sv_i <= sv_i + 8'd1;
          pp <= pp + 9'd1;
          if (sv_i + 8'd1 >= sv_len) st <= P_RESOLVE;
        end
        P_RESOLVE: begin
          if (ei >= MAX_VB[3:0]) begin
            vb_ovf <= 1'b1;
            st <= (pp == vbl_end) ? P_BUILD : P_VBT; // validate all excess TLVs, no writes
          end else begin
            // 本拍只锁 walk/OID 域，避免 oid_len→leaf_i→rq_l 单周期长链
            wi_q <= wi; o_g_q <= o_g; o_l_q <= o_l; o_i_q <= o_i;
            use_next_q <= is_nxt && nxt_ok;
            st <= P_RESOLVE1;
          end
        end
        P_RESOLVE1: begin
          // 终止/非法 GETNEXT 保留原 OID，禁止把 walk 的 3FF 哨兵当作对象。
          rq_g <= use_next_q ? grp_i(wi_q) : o_g_q;
          rq_l <= use_next_q ? leaf_i(wi_q) : o_l_q;
          rq_i <= use_next_q ? inst_i(wi_q) : o_i_q;
          st <= P_RESOLVE2;
        end
        P_RESOLVE2: st <= P_RESOLVE3; // rq_* 已稳，本拍 BRAM 采地址
        P_RESOLVE3: st <= P_RESOLVE4; // 读数据在本拍上升沿更新
        P_RESOLVE4: begin
          vb_grp [ei[2:0]] <= rq_g;
          vb_leaf[ei[2:0]] <= rq_l;
          vb_inst[ei[2:0]] <= rq_i;
          vb_tag [ei[2:0]] <= n_tag;
          vb_val [ei[2:0]] <= n_val;
          vb_str [ei[2:0]] <= n_str;
          if (r_err != 4'd0 && err_st == 4'd0) begin
            err_st <= r_err; err_ix <= ei + 4'd1;
          end
          nvb <= ei + 4'd1;
          ei  <= ei + 4'd1;
          st  <= (pp == vbl_end) ? P_BUILD : P_VBT;
        end
        // =============== 长度计算 ===============
        P_BUILD: begin
          // 每拍一个 VarBind（bi 与 acc_r 在复位及 P_BUILD4 退出时清零，进入时恒为 0）
          if (err_st != 4'd0) begin
            // RFC 1157 4.1.2/4.1.3/4.1.5: error VarBinds retain the
            // request OID, syntax and value, including values wider than 32 bits.
            // Bounds/TLV validation has completed before this byte-copy path.
            acc_r <= {1'b0, req_vbl_len};
            st <= P_BUILD2;
          end else if (bi < nvb) begin
            vb_tl[bi[2:0]] <= tl_w;
            acc_r <= acc_r + 9'd2 + {1'b0, tl_w};
            bi    <= bi + 4'd1;
          end else begin
            st <= P_BUILD2;
          end
        end
        P_BUILD2: begin
          if (vb_ovf || acc_r > 9'd255) begin                           // tooBig：空 VarBind 列表
            err_st <= 4'd1; err_ix <= 4'd0; nvb <= 4'd0; acc_r <= 9'd0;
          end
          ci <= 4'd0;
          st <= P_BUILD3;
        end
        P_COMMIT: begin
          // 此拍 err_st/nvb 已含 tooBig 判决。仅无错 SET 提交，每拍一个 VarBind。
          if (is_set && err_st == 4'd0 && ci < nvb) begin
            if (vb_grp[ci[2:0]] == 8'd1 && vb_leaf[ci[2:0]] == 8'd5) begin
              vl_bag_we <= 1'b1; vl_bag_index <= vb_inst[ci[2:0]]; vl_bag_wdata <= vb_val[ci[2:0]];
            end else begin
              ctl_we <= 1'b1; ctl_wdata <= vb_val[ci[2:0]][15:0];
            end
            if (SET_ACK_EN != 0) st <= P_COMMIT_WAIT;
            else ci <= ci + 4'd1;
          end else begin
            ci <= 4'd0;
            st <= E_SEQT;
          end
        end
        P_COMMIT_WAIT: if (set_ack) begin
          ci <= ci + 4'd1; st <= P_COMMIT;
        end
        P_BUILD3: begin
          vbl_len <= acc_r;
          pdu_len <= 9'd2 + {1'b0, rid_len} + 9'd3 + 9'd3 + vbl_tl_w;
          st <= P_BUILD4;
        end
        P_BUILD4: begin
          msg_len <= 9'd3 + 9'd2 + {1'b0, comm_len} + pdu_tl_w;
          bi <= 4'd0; acc_r <= 9'd0;
          ep <= 9'd0; vi <= 4'd0; ek <= 4'd0;
          st <= P_BUILD5;
        end
        P_BUILD5: begin
          // Validate EVERY response length before any SET write. If it cannot
          // fit, rebuild the bounded empty-list tooBig response and never commit.
          if (vbl_len > 9'd255 || pdu_len > 9'd255 || msg_len > 9'd255 || rsp_total > 10'd256) begin
            err_st <= 4'd1; err_ix <= 4'd0; nvb <= 4'd0; acc_r <= 9'd0;
            st <= P_BUILD3;
          end else begin ci <= 4'd0; st <= P_COMMIT; end
        end
        P_DROP: begin
          st <= P_IDLE;                             // drop_pdu_cnt 在 case 外统一累加
        end
        // =============== 编码 ===============
        E_SEQT:  begin ep <= ep + 9'd1; st <= E_SEQL1; end
        E_SEQL1: begin
          if (msg_len > 9'd127) begin ep <= ep + 9'd1; st <= E_SEQL2; end
          else begin ep <= ep + 9'd1; st <= E_VER0; end
        end
        E_SEQL2: begin ep <= ep + 9'd1; st <= E_VER0; end
        E_VER0:  begin ep <= ep + 9'd1; st <= E_VER1; end
        E_VER1:  begin ep <= ep + 9'd1; st <= E_VER2; end
        E_VER2:  begin ep <= ep + 9'd1; st <= E_COMT; end
        E_COMT:  begin ep <= ep + 9'd1; st <= E_COML; end
        E_COML:  begin ep <= ep + 9'd1; comm_i <= 8'd0; st <= E_COMB; end
        E_COMB:  begin
          ep <= ep + 9'd1; comm_i <= comm_i + 8'd1;
          if (comm_i + 8'd1 >= comm_len) st <= E_PDUT;
        end
        E_PDUT:  begin ep <= ep + 9'd1; st <= E_PDUL1; end
        E_PDUL1: begin
          if (pdu_len > 9'd127) begin ep <= ep + 9'd1; st <= E_PDUL2; end
          else begin ep <= ep + 9'd1; st <= E_RIDT; end
        end
        E_PDUL2: begin ep <= ep + 9'd1; st <= E_RIDT; end
        E_RIDT:  begin ep <= ep + 9'd1; st <= E_RIDL; end
        E_RIDL:  begin ep <= ep + 9'd1; rid_i <= 8'd0; st <= E_RIDB; end
        E_RIDB:  begin
          ep <= ep + 9'd1; rid_i <= rid_i + 8'd1;
          if (rid_i + 8'd1 >= rid_len) st <= E_ES0;
        end
        E_ES0:   begin ep <= ep + 9'd1; st <= E_ES1; end
        E_ES1:   begin ep <= ep + 9'd1; st <= E_ES2; end
        E_ES2:   begin ep <= ep + 9'd1; st <= E_EI0; end
        E_EI0:   begin ep <= ep + 9'd1; st <= E_EI1; end
        E_EI1:   begin ep <= ep + 9'd1; st <= E_EI2; end
        E_EI2:   begin ep <= ep + 9'd1; st <= E_VBLT; end
        E_VBLT:  begin ep <= ep + 9'd1; st <= E_VBLL1; end
        E_VBLL1: begin
          if (vbl_len > 9'd127) begin ep <= ep + 9'd1; st <= E_VBLL2; end
          else begin
            ep <= ep + 9'd1;
            vi <= 4'd0; ek <= 4'd0;
            copy_pos <= vbl_pos;
            st <= (nvb == 4'd0) ? E_FIN : ((err_st != 4'd0) ? E_VBCOPY : E_VBT);
          end
        end
        E_VBLL2: begin
          ep <= ep + 9'd1;
          vi <= 4'd0; ek <= 4'd0;
          copy_pos <= vbl_pos;
          st <= (nvb == 4'd0) ? E_FIN : ((err_st != 4'd0) ? E_VBCOPY : E_VBT);
        end
        E_VBT:   begin
          ep <= ep + 9'd1; st <= E_VBL;
          e_tag_q   <= vb_tag[vi[2:0]];
          e_isstr_q <= vb_str[vi[2:0]];
          e_vlen_q  <= vb_str[vi[2:0]] ? 4'd0 : ilen(vb_val[vi[2:0]]);
          e_val_q   <= vb_val[vi[2:0]];
        end
        E_VBL:   begin ep <= ep + 9'd1; st <= E_OIDT; end
        E_OIDT:  begin ep <= ep + 9'd1; st <= E_OIDL; end
        E_OIDL:  begin ep <= ep + 9'd1; ek <= 4'd0; st <= E_OIDB; end
        E_OIDB:  begin
          ep <= ep + 9'd1; ek <= ek + 4'd1;
          if (ek >= 4'd10) begin ek <= 4'd0; st <= E_VALT; end
        end
        E_VALT:  begin ep <= ep + 9'd1; st <= E_VALL; end
        E_VALL:  begin
          ep <= ep + 9'd1; ek <= 4'd0;
          st <= (e_vlen8 == 8'd0) ? E_NEXT : E_VALB;
        end
        E_VALB:  begin
          ep <= ep + 9'd1; ek <= ek + 4'd1;
          if ({4'd0, ek} + 8'd1 >= e_vlen8) st <= E_NEXT;
        end
        E_NEXT:  begin
          vi <= vi + 4'd1; ek <= 4'd0;
          st <= ((vi + 4'd1) >= nvb) ? E_FIN : E_VBT;
        end
        E_VBCOPY: begin
          ep <= ep + 9'd1; copy_pos <= copy_pos + 9'd1;
          if (copy_pos + 9'd1 >= vbl_end) st <= E_FIN;
        end
        E_FIN:   begin
          resp_len <= {2'd0, ep};
          resp_vld <= 1'b1;
          resp_cnt <= resp_cnt + 32'd1;
          last_err <= err_st; last_idx <= err_ix; vb_n <= nvb;
          st <= P_IDLE;
        end
        default: st <= P_IDLE;
      endcase
      end

    end
  end
endmodule
