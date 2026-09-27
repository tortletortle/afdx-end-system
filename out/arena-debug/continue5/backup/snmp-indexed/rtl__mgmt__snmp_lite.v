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
//     .11 afdxEsCtl          INTEGER           RW  （唯一可写对象）
//     .12 afdxEsDropCnt      Counter32(0x41)   RO
//     .13 afdxEsBufUtil      Gauge32(0x42)     RO
//   组 2（STATS_BLOCK 只读组，OID = <pfx>.2.<w>.0，w=0..47）
//     直接映射全局统计页 0x0100 的第 w 个字，Counter32，只读。
//   GETNEXT 在"组 1 的 8 个标量 → 组 2 的 48 个字"共 56 项上做有序游走。
//
// 错误语义：
//   community != "public" 或 version 非 0/1 或 BER 不合法 → 静默丢弃 + 计数
//   GET/SET 到不存在对象 → noSuchName(2)，error-index = 出错 VarBind 序号
//   SET 到只读对象       → readOnly(4)
//   SET 类型非 INTEGER 或值 > 0xFFFF → badValue(3)
//   VarBind > 8 个，或响应任一长度域 > 255 → tooBig(1) + 空 VarBind 列表
//
// 覆盖边界（如实标注，未实现/不宣称）：
//   - 只支持短式长度与 0x81 单字节长式（≤255），0x82 及以上一律丢弃；
//   - 只支持 SNMPv1(0)/v2c(1)，无 v3 / 无认证加密 / 无 Trap / 无 GETBULK；
//   - community 为编译期常量 "public"，未做运行时可配；
//   - OID 叶子号限 0..127（单字节子标识符），不支持多字节叶子；
//   - request-id 与 community 在响应中按原始字节回抄，不做重新编码；
//   - 每 VarBind 的取值在解析当拍锁存，同一响应内不保证跨对象的原子快照。
// =====================================================================
`timescale 1 ns / 1 ps
module snmp_lite #(
  parameter integer NUM_TX_VL = 128,
  parameter integer NUM_RX_VL = 4096,
  parameter integer MAX_VB    = 8
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
  // SET 写回
  output reg         ctl_we,
  output reg  [15:0] ctl_wdata,
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

  reg [7:0] req  [0:255];
  reg [7:0] rsp  [0:255];
  reg [7:0] oidb [0:15];

  // ---------------- 接收 ----------------
  reg [8:0] wp;
  reg [8:0] req_len;
  reg       have_pkt;
  assign in_ready = 1'b1;

  // ---------------- 解析状态 ----------------
  localparam [6:0]
    P_IDLE=0,  P_SEQT=1,  P_SEQL=2,  P_VERT=3,  P_VERL=4,  P_VERV=5,
    P_COMT=6,  P_COML=7,  P_COMB=8,  P_PDUT=9,  P_PDUL=10, P_RIDT=11,
    P_RIDL=12, P_RIDB=13, P_EST=14,  P_ESL=15,  P_ESV=16,  P_EIT=17,
    P_EIL=18,  P_EIV=19,  P_VBLT=20, P_VBLL=21, P_VBT=22,  P_VBLN=23,
    P_OIDT=24, P_OIDL=25, P_OIDB=26, P_VALT=27, P_VALL=28, P_VALB=29,
    P_RESOLVE=30, P_BUILD=31, P_DROP=32,
    E_SEQT=33, E_SEQL1=34, E_SEQL2=35, E_VER0=36, E_VER1=37, E_VER2=38,
    E_COMT=39, E_COML=40, E_COMB=41, E_PDUT=42, E_PDUL1=43, E_PDUL2=44,
    E_RIDT=45, E_RIDL=46, E_RIDB=47, E_ES0=48, E_ES1=49, E_ES2=50,
    E_EI0=51,  E_EI1=52,  E_EI2=53,  E_VBLT=54, E_VBLL1=55, E_VBLL2=56,
    E_VBT=57,  E_VBL=58,  E_OIDT=59, E_OIDL=60, E_OIDB=61,
    E_VALT=62, E_VALL=63, E_VALB=64, E_NEXT=65, E_FIN=66;

  reg [6:0]  st;
  reg [8:0]  pp;               // 解析指针
  reg [8:0]  msg_end, pdu_end, vbl_end;
  reg        lp;               // 长式长度待读
  reg [7:0]  ver;
  reg [8:0]  comm_pos; reg [7:0] comm_len; reg [7:0] comm_i; reg comm_ok;
  reg [7:0]  pdu_t;
  reg [8:0]  rid_pos; reg [7:0] rid_len; reg [7:0] rid_i;
  reg [7:0]  oid_len, oid_i;
  reg [7:0]  sv_tag, sv_len, sv_i;
  reg [31:0] sv_val;
  reg [3:0]  nvb;
  reg [3:0]  ei;               // 当前 VarBind 序号（0 起）
  reg [3:0]  err_st, err_ix;
  reg        vb_ovf;

  reg [7:0]  vb_grp  [0:7];
  reg [7:0]  vb_leaf [0:7];
  reg [7:0]  vb_tag  [0:7];
  reg [31:0] vb_val  [0:7];
  reg        vb_str  [0:7];

  // ---------------- 编码 ----------------
  reg [8:0]  ep;               // 响应写指针
  reg [3:0]  vi, ek;
  reg [8:0]  msg_len, pdu_len, vbl_len;
  reg [7:0]  vb_tl [0:7];      // 每个 VarBind 的内容长度
  reg        emit_done;

  assign state_o = st[5:0];
  assign resp_byte = rsp[resp_rd_addr[7:0]];

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
  function [6:0] idx_of; input [7:0] g; input [7:0] l;
    begin
      if (g == 8'd1)
        case (l) 8'd1:idx_of=7'd0; 8'd2:idx_of=7'd1; 8'd3:idx_of=7'd2; 8'd4:idx_of=7'd3;
                 8'd10:idx_of=7'd4; 8'd11:idx_of=7'd5; 8'd12:idx_of=7'd6; 8'd13:idx_of=7'd7;
                 default: idx_of=7'h7F; endcase
      else if (g == 8'd2 && l < 8'd48) idx_of = 7'd8 + l[6:0];
      else idx_of = 7'h7F;
    end
  endfunction
  function [7:0] grp_i; input [6:0] i;
    begin grp_i = (i < 7'd8) ? 8'd1 : 8'd2; end
  endfunction
  function [7:0] leaf_i; input [6:0] i;
    begin
      if (i < 7'd8)
        case (i) 7'd0:leaf_i=8'd1; 7'd1:leaf_i=8'd2; 7'd2:leaf_i=8'd3; 7'd3:leaf_i=8'd4;
                 7'd4:leaf_i=8'd10; 7'd5:leaf_i=8'd11; 7'd6:leaf_i=8'd12;
                 default: leaf_i=8'd13; endcase
      else leaf_i = {1'b0, i - 7'd8};
    end
  endfunction
  // GETNEXT 有序游走：返回首个 (grp,leaf) 严格大于 (g,l)（hi=0 时允许相等）的表项
  function [6:0] walk; input [7:0] g; input [7:0] l; input hi;
    integer k; reg found; reg [15:0] key, cur;
    begin
      walk = 7'h7F; found = 1'b0; key = {g, l};
      for (k = 0; k < 56; k = k + 1) begin
        cur = {grp_i(k[6:0]), leaf_i(k[6:0])};
        if (!found && ((cur > key) || (!hi && cur == key))) begin
          walk = k[6:0]; found = 1'b1;
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
  wire       pfx_ok = (oid_len >= 8'd8) &&
                      (oidb[0]==8'h2B)&&(oidb[1]==8'h06)&&(oidb[2]==8'h01)&&(oidb[3]==8'h04)&&
                      (oidb[4]==8'h01)&&(oidb[5]==8'hA2)&&(oidb[6]==8'h5C)&&(oidb[7]==8'h01);
  wire       has_inst = (oid_len == 8'd11) && (oidb[10] == 8'h00);
  wire [6:0] gi  = idx_of(o_g, o_l);
  wire [6:0] wi  = walk(o_g, o_l, has_inst);
  wire       is_get = (pdu_t == PDU_GET);
  wire       is_nxt = (pdu_t == PDU_NXT);
  wire       is_set = (pdu_t == PDU_SET);
  wire       get_ok = pfx_ok && has_inst && (gi != 7'h7F);
  wire       nxt_ok = pfx_ok && (wi != 7'h7F);
  wire [7:0] r_g = is_nxt ? grp_i(wi)  : o_g;
  wire [7:0] r_l = is_nxt ? leaf_i(wi) : o_l;
  wire       set_rw = get_ok && (o_g == 8'd1) && (o_l == 8'd11);
  wire [3:0] r_err = is_nxt ? (nxt_ok ? 4'd0 : 4'd2)
                   : is_get ? (get_ok ? 4'd0 : 4'd2)
                   : (!get_ok)              ? 4'd2
                   : (!set_rw)              ? 4'd4
                   : (sv_tag != T_INT)      ? 4'd3
                   : (sv_val > 32'h0000_FFFF) ? 4'd3 : 4'd0;
  assign stats_off = r_l;
  reg [7:0]  n_tag; reg [31:0] n_val; reg n_str;
  always @(*) begin
    n_tag = T_CNT; n_val = 32'd0; n_str = 1'b0;
    if (r_g == 8'd2) begin n_tag = T_CNT; n_val = stats_data; end
    else case (r_l)
      8'd1:  begin n_tag = T_OCT; n_str = 1'b1; end
      8'd2:  begin n_tag = T_TIM; n_val = uptime_cs; end
      8'd3:  begin n_tag = T_INT; n_val = NUM_TX_VL[31:0]; end
      8'd4:  begin n_tag = T_INT; n_val = NUM_RX_VL[31:0]; end
      8'd10: begin n_tag = T_INT; n_val = jit_max_us; end
      8'd11: begin n_tag = T_INT; n_val = is_set ? {16'd0, sv_val[15:0]} : {16'd0, ctl_val}; end
      8'd12: begin n_tag = T_CNT; n_val = drop_total; end
      8'd13: begin n_tag = T_GAU; n_val = buf_util; end
      default: begin n_tag = T_CNT; n_val = 32'd0; end
    endcase
  end

  // ================= 编码期的每 VarBind 取值 =================
  wire        e_err   = (err_st != 4'd0);
  wire [7:0]  e_tag   = e_err ? T_NUL : vb_tag[vi[2:0]];
  wire        e_isstr = !e_err && vb_str[vi[2:0]];
  wire [3:0]  e_vlen  = e_err   ? 4'd0 :
                        e_isstr ? 4'd0 : ilen(vb_val[vi[2:0]]);
  wire [7:0]  e_vlen8 = e_isstr ? 8'd16 : {4'd0, e_vlen};
  wire [7:0]  e_vbyte = e_isstr ? dch({4'd0, ek}) : ibyte(vb_val[vi[2:0]], e_vlen, ek);
  wire [7:0]  e_oidb  = (ek < 4'd8) ? pfx_ch({4'd0, ek}) :
                        (ek == 4'd8) ? vb_grp[vi[2:0]] :
                        (ek == 4'd9) ? vb_leaf[vi[2:0]] : 8'h00;

  integer j;
  reg [8:0] acc, vbl_l, vbl_tl, pdu_l, pdu_tl, msg_l;
  reg [7:0] tl;

  always @(posedge clk) begin
    if (rst_sync) begin
      wp <= 9'd0; req_len <= 9'd0; have_pkt <= 1'b0; st <= P_IDLE;
      resp_vld <= 1'b0; resp_len <= 11'd0; ctl_we <= 1'b0; ctl_wdata <= 16'd0;
      rx_pdu_cnt <= 32'd0; resp_cnt <= 32'd0; drop_pdu_cnt <= 32'd0;
      last_err <= 4'd0; last_idx <= 4'd0; last_pdu <= 8'd0; peer_port <= 16'd0;
      vb_n <= 4'd0; nvb <= 4'd0; ei <= 4'd0; err_st <= 4'd0; err_ix <= 4'd0;
      lp <= 1'b0; pp <= 9'd0; ep <= 9'd0; vi <= 4'd0; ek <= 4'd0;
      comm_ok <= 1'b0; vb_ovf <= 1'b0; emit_done <= 1'b0;
      msg_len <= 9'd0; pdu_len <= 9'd0; vbl_len <= 9'd0;
    end else begin
      ctl_we <= 1'b0;
      if (resp_ack && resp_vld) resp_vld <= 1'b0;

      // ---------- 收包 ----------
      if (en && in_vld) begin
        if (in_sop) begin req[0] <= in_data; wp <= 9'd1; end
        else if (wp < 9'd256) begin req[wp[7:0]] <= in_data; wp <= wp + 9'd1; end
        if (in_eop) begin
          req_len  <= in_sop ? 9'd1 : (wp + 9'd1);
          have_pkt <= 1'b1;
          peer_port <= in_sport;
        end
      end

      case (st)
        // =============== 解析 ===============
        P_IDLE: if (have_pkt && !resp_vld) begin
          have_pkt <= 1'b0; pp <= 9'd0; lp <= 1'b0; st <= P_SEQT;
          nvb <= 4'd0; ei <= 4'd0; err_st <= 4'd0; err_ix <= 4'd0; vb_ovf <= 1'b0;
          rx_pdu_cnt <= rx_pdu_cnt + 32'd1;
        end
        P_SEQT: begin
          if (req[pp[7:0]] != T_SEQ) st <= P_DROP;
          else begin pp <= pp + 9'd1; st <= P_SEQL; end
        end
        P_SEQL: begin
          if (lp) begin msg_end <= pp + 9'd1 + {1'b0, req[pp[7:0]]}; lp <= 1'b0;
                        pp <= pp + 9'd1; st <= P_VERT; end
          else if (req[pp[7:0]] < 8'h80) begin
                        msg_end <= pp + 9'd1 + {1'b0, req[pp[7:0]]};
                        pp <= pp + 9'd1; st <= P_VERT; end
          else if (req[pp[7:0]] == 8'h81) begin lp <= 1'b1; pp <= pp + 9'd1; end
          else st <= P_DROP;
        end
        P_VERT: begin
          if (req[pp[7:0]] != T_INT) st <= P_DROP;
          else begin pp <= pp + 9'd1; st <= P_VERL; end
        end
        P_VERL: begin
          if (req[pp[7:0]] != 8'd1) st <= P_DROP;
          else begin pp <= pp + 9'd1; st <= P_VERV; end
        end
        P_VERV: begin
          ver <= req[pp[7:0]];
          if (req[pp[7:0]] > 8'd1) st <= P_DROP;
          else begin pp <= pp + 9'd1; st <= P_COMT; end
        end
        P_COMT: begin
          if (req[pp[7:0]] != T_OCT) st <= P_DROP;
          else begin pp <= pp + 9'd1; st <= P_COML; end
        end
        P_COML: begin
          comm_len <= req[pp[7:0]];
          comm_pos <= pp + 9'd1;
          comm_i   <= 8'd0;
          comm_ok  <= (req[pp[7:0]] == COMM_N[7:0]);
          pp <= pp + 9'd1;
          st <= (req[pp[7:0]] == 8'd0) ? P_DROP : P_COMB;
        end
        P_COMB: begin
          if (req[pp[7:0]] != comm_ch(comm_i)) comm_ok <= 1'b0;
          comm_i <= comm_i + 8'd1;
          pp <= pp + 9'd1;
          if (comm_i + 8'd1 >= comm_len) st <= P_PDUT;
        end
        P_PDUT: begin
          pdu_t    <= req[pp[7:0]];
          last_pdu <= req[pp[7:0]];
          if (!comm_ok) st <= P_DROP;
          else if (req[pp[7:0]] != PDU_GET && req[pp[7:0]] != PDU_NXT &&
                   req[pp[7:0]] != PDU_SET) st <= P_DROP;
          else begin pp <= pp + 9'd1; st <= P_PDUL; end
        end
        P_PDUL: begin
          if (lp) begin pdu_end <= pp + 9'd1 + {1'b0, req[pp[7:0]]}; lp <= 1'b0;
                        pp <= pp + 9'd1; st <= P_RIDT; end
          else if (req[pp[7:0]] < 8'h80) begin
                        pdu_end <= pp + 9'd1 + {1'b0, req[pp[7:0]]};
                        pp <= pp + 9'd1; st <= P_RIDT; end
          else if (req[pp[7:0]] == 8'h81) begin lp <= 1'b1; pp <= pp + 9'd1; end
          else st <= P_DROP;
        end
        P_RIDT: begin
          if (req[pp[7:0]] != T_INT) st <= P_DROP;
          else begin pp <= pp + 9'd1; st <= P_RIDL; end
        end
        P_RIDL: begin
          rid_len <= req[pp[7:0]];
          rid_pos <= pp + 9'd1;
          if (req[pp[7:0]] == 8'd0 || req[pp[7:0]] > 8'd5) st <= P_DROP;
          else begin pp <= pp + 9'd1 + {1'b0, req[pp[7:0]]}; st <= P_EST; end
        end
        P_EST:  begin if (req[pp[7:0]] != T_INT) st <= P_DROP;
                      else begin pp <= pp + 9'd1; st <= P_ESL; end end
        P_ESL:  begin if (req[pp[7:0]] != 8'd1) st <= P_DROP;
                      else begin pp <= pp + 9'd1; st <= P_ESV; end end
        P_ESV:  begin pp <= pp + 9'd1; st <= P_EIT; end
        P_EIT:  begin if (req[pp[7:0]] != T_INT) st <= P_DROP;
                      else begin pp <= pp + 9'd1; st <= P_EIL; end end
        P_EIL:  begin if (req[pp[7:0]] != 8'd1) st <= P_DROP;
                      else begin pp <= pp + 9'd1; st <= P_EIV; end end
        P_EIV:  begin pp <= pp + 9'd1; st <= P_VBLT; end
        P_VBLT: begin if (req[pp[7:0]] != T_SEQ) st <= P_DROP;
                      else begin pp <= pp + 9'd1; st <= P_VBLL; end end
        P_VBLL: begin
          if (lp) begin vbl_end <= pp + 9'd1 + {1'b0, req[pp[7:0]]}; lp <= 1'b0;
                        pp <= pp + 9'd1;
                        st <= (req[pp[7:0]] == 8'd0) ? P_BUILD : P_VBT; end
          else if (req[pp[7:0]] < 8'h80) begin
                        vbl_end <= pp + 9'd1 + {1'b0, req[pp[7:0]]};
                        pp <= pp + 9'd1;
                        st <= (req[pp[7:0]] == 8'd0) ? P_BUILD : P_VBT; end
          else if (req[pp[7:0]] == 8'h81) begin lp <= 1'b1; pp <= pp + 9'd1; end
          else st <= P_DROP;
        end
        P_VBT:  begin if (req[pp[7:0]] != T_SEQ) st <= P_DROP;
                      else begin pp <= pp + 9'd1; st <= P_VBLN; end end
        P_VBLN: begin
          if (req[pp[7:0]] >= 8'h80) st <= P_DROP;
          else begin pp <= pp + 9'd1; st <= P_OIDT; end
        end
        P_OIDT: begin if (req[pp[7:0]] != T_OID) st <= P_DROP;
                      else begin pp <= pp + 9'd1; st <= P_OIDL; end end
        P_OIDL: begin
          oid_len <= req[pp[7:0]]; oid_i <= 8'd0;
          if (req[pp[7:0]] == 8'd0 || req[pp[7:0]] > 8'd16) st <= P_DROP;
          else begin pp <= pp + 9'd1; st <= P_OIDB; end
        end
        P_OIDB: begin
          oidb[oid_i[3:0]] <= req[pp[7:0]];
          oid_i <= oid_i + 8'd1;
          pp <= pp + 9'd1;
          if (oid_i + 8'd1 >= oid_len) st <= P_VALT;
        end
        P_VALT: begin sv_tag <= req[pp[7:0]]; sv_val <= 32'd0;
                      pp <= pp + 9'd1; st <= P_VALL; end
        P_VALL: begin
          sv_len <= req[pp[7:0]]; sv_i <= 8'd0;
          if (req[pp[7:0]] >= 8'h80) st <= P_DROP;
          else begin
            pp <= pp + 9'd1;
            st <= (req[pp[7:0]] == 8'd0) ? P_RESOLVE : P_VALB;
          end
        end
        P_VALB: begin
          if (sv_i < 8'd4) sv_val <= {sv_val[23:0], req[pp[7:0]]};
          sv_i <= sv_i + 8'd1;
          pp <= pp + 9'd1;
          if (sv_i + 8'd1 >= sv_len) st <= P_RESOLVE;
        end
        P_RESOLVE: begin
          if (ei >= MAX_VB[3:0]) begin
            vb_ovf <= 1'b1;
            st <= P_BUILD;
          end else begin
            vb_grp [ei[2:0]] <= r_g;
            vb_leaf[ei[2:0]] <= r_l;
            vb_tag [ei[2:0]] <= n_tag;
            vb_val [ei[2:0]] <= n_val;
            vb_str [ei[2:0]] <= n_str;
            if (r_err != 4'd0 && err_st == 4'd0) begin
              err_st <= r_err; err_ix <= ei + 4'd1;
            end
            if (r_err == 4'd0 && is_set && set_rw) begin
              ctl_we <= 1'b1; ctl_wdata <= sv_val[15:0];
            end
            nvb <= ei + 4'd1;
            ei  <= ei + 4'd1;
            st  <= (pp >= vbl_end) ? P_BUILD : P_VBT;
          end
        end
        // =============== 长度计算 ===============
        P_BUILD: begin
          acc = 9'd0;
          for (j = 0; j < 8; j = j + 1) begin
            if (j < nvb) begin
              if (err_st != 4'd0)      tl = 8'd15;                      // OID TLV(13) + NULL TLV(2)
              else if (vb_str[j[2:0]]) tl = 8'd31;                      // + OCTET STRING(16)
              else                     tl = 8'd15 + {4'd0, ilen(vb_val[j[2:0]])};
              vb_tl[j[2:0]] <= tl;
              acc = acc + 9'd2 + {1'b0, tl};
            end
          end
          if (vb_ovf || acc > 9'd255) begin                             // tooBig：空 VarBind 列表
            err_st <= 4'd1; err_ix <= 4'd0; nvb <= 4'd0; acc = 9'd0;
          end
          vbl_l  = acc;
          vbl_tl = 9'd2 + ((acc   > 9'd127) ? 9'd1 : 9'd0) + acc;
          pdu_l  = 9'd2 + {1'b0, rid_len} + 9'd3 + 9'd3 + vbl_tl;
          pdu_tl = 9'd2 + ((pdu_l > 9'd127) ? 9'd1 : 9'd0) + pdu_l;
          msg_l  = 9'd3 + 9'd2 + {1'b0, comm_len} + pdu_tl;
          vbl_len <= vbl_l; pdu_len <= pdu_l; msg_len <= msg_l;
          ep <= 9'd0; vi <= 4'd0; ek <= 4'd0;
          st <= E_SEQT;
        end
        P_DROP: begin
          drop_pdu_cnt <= drop_pdu_cnt + 32'd1;
          st <= P_IDLE;
        end
        // =============== 编码 ===============
        E_SEQT:  begin rsp[ep[7:0]] <= T_SEQ; ep <= ep + 9'd1; st <= E_SEQL1; end
        E_SEQL1: begin
          if (msg_len > 9'd127) begin rsp[ep[7:0]] <= 8'h81; ep <= ep + 9'd1; st <= E_SEQL2; end
          else begin rsp[ep[7:0]] <= msg_len[7:0]; ep <= ep + 9'd1; st <= E_VER0; end
        end
        E_SEQL2: begin rsp[ep[7:0]] <= msg_len[7:0]; ep <= ep + 9'd1; st <= E_VER0; end
        E_VER0:  begin rsp[ep[7:0]] <= T_INT; ep <= ep + 9'd1; st <= E_VER1; end
        E_VER1:  begin rsp[ep[7:0]] <= 8'd1;  ep <= ep + 9'd1; st <= E_VER2; end
        E_VER2:  begin rsp[ep[7:0]] <= ver;   ep <= ep + 9'd1; st <= E_COMT; end
        E_COMT:  begin rsp[ep[7:0]] <= T_OCT; ep <= ep + 9'd1; st <= E_COML; end
        E_COML:  begin rsp[ep[7:0]] <= comm_len; ep <= ep + 9'd1; comm_i <= 8'd0; st <= E_COMB; end
        E_COMB:  begin
          rsp[ep[7:0]] <= req[comm_pos[7:0] + comm_i];
          ep <= ep + 9'd1; comm_i <= comm_i + 8'd1;
          if (comm_i + 8'd1 >= comm_len) st <= E_PDUT;
        end
        E_PDUT:  begin rsp[ep[7:0]] <= PDU_RSP; ep <= ep + 9'd1; st <= E_PDUL1; end
        E_PDUL1: begin
          if (pdu_len > 9'd127) begin rsp[ep[7:0]] <= 8'h81; ep <= ep + 9'd1; st <= E_PDUL2; end
          else begin rsp[ep[7:0]] <= pdu_len[7:0]; ep <= ep + 9'd1; st <= E_RIDT; end
        end
        E_PDUL2: begin rsp[ep[7:0]] <= pdu_len[7:0]; ep <= ep + 9'd1; st <= E_RIDT; end
        E_RIDT:  begin rsp[ep[7:0]] <= T_INT; ep <= ep + 9'd1; st <= E_RIDL; end
        E_RIDL:  begin rsp[ep[7:0]] <= rid_len; ep <= ep + 9'd1; rid_i <= 8'd0; st <= E_RIDB; end
        E_RIDB:  begin
          rsp[ep[7:0]] <= req[rid_pos[7:0] + rid_i];
          ep <= ep + 9'd1; rid_i <= rid_i + 8'd1;
          if (rid_i + 8'd1 >= rid_len) st <= E_ES0;
        end
        E_ES0:   begin rsp[ep[7:0]] <= T_INT; ep <= ep + 9'd1; st <= E_ES1; end
        E_ES1:   begin rsp[ep[7:0]] <= 8'd1;  ep <= ep + 9'd1; st <= E_ES2; end
        E_ES2:   begin rsp[ep[7:0]] <= {4'd0, err_st}; ep <= ep + 9'd1; st <= E_EI0; end
        E_EI0:   begin rsp[ep[7:0]] <= T_INT; ep <= ep + 9'd1; st <= E_EI1; end
        E_EI1:   begin rsp[ep[7:0]] <= 8'd1;  ep <= ep + 9'd1; st <= E_EI2; end
        E_EI2:   begin rsp[ep[7:0]] <= {4'd0, err_ix}; ep <= ep + 9'd1; st <= E_VBLT; end
        E_VBLT:  begin rsp[ep[7:0]] <= T_SEQ; ep <= ep + 9'd1; st <= E_VBLL1; end
        E_VBLL1: begin
          if (vbl_len > 9'd127) begin rsp[ep[7:0]] <= 8'h81; ep <= ep + 9'd1; st <= E_VBLL2; end
          else begin
            rsp[ep[7:0]] <= vbl_len[7:0]; ep <= ep + 9'd1;
            vi <= 4'd0; ek <= 4'd0;
            st <= (nvb == 4'd0) ? E_FIN : E_VBT;
          end
        end
        E_VBLL2: begin
          rsp[ep[7:0]] <= vbl_len[7:0]; ep <= ep + 9'd1;
          vi <= 4'd0; ek <= 4'd0;
          st <= (nvb == 4'd0) ? E_FIN : E_VBT;
        end
        E_VBT:   begin rsp[ep[7:0]] <= T_SEQ; ep <= ep + 9'd1; st <= E_VBL; end
        E_VBL:   begin rsp[ep[7:0]] <= vb_tl[vi[2:0]]; ep <= ep + 9'd1; st <= E_OIDT; end
        E_OIDT:  begin rsp[ep[7:0]] <= T_OID; ep <= ep + 9'd1; st <= E_OIDL; end
        E_OIDL:  begin rsp[ep[7:0]] <= 8'd11; ep <= ep + 9'd1; ek <= 4'd0; st <= E_OIDB; end
        E_OIDB:  begin
          rsp[ep[7:0]] <= e_oidb; ep <= ep + 9'd1; ek <= ek + 4'd1;
          if (ek >= 4'd10) begin ek <= 4'd0; st <= E_VALT; end
        end
        E_VALT:  begin rsp[ep[7:0]] <= e_tag; ep <= ep + 9'd1; st <= E_VALL; end
        E_VALL:  begin
          rsp[ep[7:0]] <= e_vlen8; ep <= ep + 9'd1; ek <= 4'd0;
          st <= (e_vlen8 == 8'd0) ? E_NEXT : E_VALB;
        end
        E_VALB:  begin
          rsp[ep[7:0]] <= e_vbyte; ep <= ep + 9'd1; ek <= ek + 4'd1;
          if ({4'd0, ek} + 8'd1 >= e_vlen8) st <= E_NEXT;
        end
        E_NEXT:  begin
          vi <= vi + 4'd1; ek <= 4'd0;
          st <= ((vi + 4'd1) >= nvb) ? E_FIN : E_VBT;
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
endmodule
