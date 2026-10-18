// =====================================================================
// mgmt_sap_rx.v -- SAP 描述符接收 + UDP 载荷取回 + 字节流分发
//
// continue4 之前：只做描述符登记与 RX 块归还（不解析任何协议）。
// continue4 起  ：在同一个端点里增加"取载荷"，但**不推迟块归还**：
//   1) COPY  阶段：用最低优先级的 PMEM A 口，以 1 字/拍把该帧从字 6
//      （帧字节 24）到载荷末字整段搬进本地缓冲 pbuf；
//   2) 搬完立刻 free_req，块归还时序与改造前基本一致（T23 的
//      "pending 期间与 PB1 抢占""≤1 拍被授权"语义得以保持）；
//   3) STREAM 阶段：从 pbuf 以 1 字节/拍发出 UDP 载荷，并抽出
//      srcip / sport / dport 交给 snmp_lite / a615a_tftp。
//
// 帧内布局假定（与 rx_ip_udp_parse 的固定头一致）：
//   0..13 以太头, 14..33 IPv4 定长头, 34..41 UDP 头, 42.. 载荷
//   PMEM 每块 512 字，字内大端（字节 4i+0 在 [31:24]）。
//
// 覆盖边界（如实标注）：
//   - 不支持 IP 选项（IHL>5）与分片重组；
//   - 本地缓冲 PBUF_W 字（默认 160 字 = 640 B，够 512 B 的 TFTP DATA 块），
//     超出部分被截断并置 trunc_cnt，不做静默丢弃以外的处理；
//   - 载荷分发期间该 SAP 端点对新描述符反压（in_ready=0）。
//
// P02（2026-10-10）：字节流改为可停顿握手。
//   旧行为：S_STREAM 每拍无条件推进 bcur，下游未接收也照样前进；
//   下游（a615a_tftp）的 ready 在超时响应/卸载复制期间下降时，字节被
//   跳过丢失，造成包中途静默截断（源码审查风险）。
//   现行为：out_ready=0 时保持 data/vld/SOP/EOP 与 bcur（待消费位置）
//   不变；out_ready=1 才推进。上一字节被接收与发射下一字节同拍完成，
//   因此无停顿路径的时序与旧实现完全一致。
//   PMEM 块在 S_COPY 全部搬入 pbuf 之后、进入 S_STREAM 时归还
//   （最后一次使用 = 复制阶段），分发停顿不改变归还时机；
//   free_req 只发一次（!freed 门控），无重复释放。
// =====================================================================
`timescale 1 ns / 1 ps
module mgmt_sap_rx #(
  parameter integer PAY_OFF = 42,
  parameter integer PBUF_W  = 160,
  parameter integer CHAIN_ENABLE = 0
)(
  input  wire        clk,
  input  wire        rst_sync,
  input  wire        in_vld,
  output wire        in_ready,
  input  wire [7:0]  in_port,
  input  wire [3:0]  in_blk,
  input  wire [10:0] in_plen,
  // ---- PMEM A 口（顶层按最低优先级仲裁）----
  output wire        pm_req,
  output wire [12:0] pm_addr,
  input  wire        pm_gnt,
  input  wire [31:0] pm_data,
  // ---- 载荷字节流 ----
  output reg         out_vld,
  output reg         out_sop,
  output reg         out_eop,
  output reg  [7:0]  out_data,
  output reg  [15:0] out_sport,
  output reg  [15:0] out_dport,
  output reg  [31:0] out_srcip,
  output reg  [10:0] out_plen,
  // P02：下游字节级接受指示。0 时保持当前字节与消费位置（内部背压，
  // 不影响 GMII 外部字节流；pbuf 已完整持有本包载荷）。
  input  wire        out_ready,
  // ---- 块归还与观测 ----
  output wire        free_req,
  input  wire        free_take,
  output wire [3:0]  free_id,
  output reg  [31:0] accept_cnt,
  output reg  [31:0] free_cnt,
  output reg  [31:0] last_desc,
  output reg  [31:0] pay_cnt,
  output reg  [31:0] trunc_cnt,
  // Chain sideband: ignored by the default legacy generate branch.
  input  wire [13:0] in_app_len,
  input  wire [19:0] in_blocks,
  input  wire [2:0]  in_block_count,
  output wire [13:0] out_app_len
);
  localparam [1:0] S_IDLE = 2'd0, S_COPY = 2'd1, S_STREAM = 2'd2, S_WAIT = 2'd3;
  localparam integer W_START = 6;                 // 帧字节 24 所在的字

  reg [31:0] pbuf [0:PBUF_W-1];

  reg [1:0]  st;
  reg [3:0]  pending_blk;
  reg [8:0]  wa;                                  // 下一个要请求的 PMEM 字
  reg [8:0]  wp;                                  // 下一个要落地的 pbuf 字
  reg [8:0]  wlast;                               // 最后一个需要的 PMEM 字
  reg        req_done, cap_v, freed;
  reg [10:0] bcur, blast;

  wire [10:0] rel  = bcur - 11'd24;               // pbuf 内的字节序号
  wire [31:0] wsel = pbuf[rel[9:2]];
  wire [7:0]  bsel = (rel[1:0] == 2'd0) ? wsel[31:24] :
                     (rel[1:0] == 2'd1) ? wsel[23:16] :
                     (rel[1:0] == 2'd2) ? wsel[15:8]  : wsel[7:0];

  // 需要的最后一个字：min(载荷末字, 缓冲容量)
  function [8:0] last_word;
    input [10:0] plen;
    reg [12:0] lb;
    begin
      lb = PAY_OFF[12:0] - 13'd1 + {2'd0, plen};
      if ((lb >> 2) > (W_START + PBUF_W - 1)) last_word = (W_START + PBUF_W - 1);
      else                                    last_word = lb[10:2];
    end
  endfunction
  function [10:0] last_byte;
    input [10:0] plen;
    reg [12:0] lb;
    begin
      lb = PAY_OFF[12:0] - 13'd1 + {2'd0, plen};
      if ((lb >> 2) > (W_START + PBUF_W - 1))
        last_byte = ((W_START + PBUF_W) * 4) - 1;
      else
        last_byte = lb[10:0];
    end
  endfunction

  // Only this branch elaborates the original implementation.  Keeping
  // the declarations above preserves dut.pbuf / dut.st / dut.cap_v.
  generate
    if (CHAIN_ENABLE == 0) begin : g_legacy
  assign in_ready = !rst_sync && (st == S_IDLE);
  assign pm_req   = (st == S_COPY) && !req_done;
  assign pm_addr  = {pending_blk, wa};
  assign free_req = ((st == S_STREAM) || (st == S_WAIT)) && !freed;
  assign free_id  = pending_blk;

  assign out_app_len = {3'd0, out_plen};

  always @(posedge clk) begin
    if (rst_sync) begin
      st <= S_IDLE; pending_blk <= 4'd0; wa <= 9'd0; wp <= 9'd0; wlast <= 9'd0;
      req_done <= 1'b0; cap_v <= 1'b0; freed <= 1'b0;
      bcur <= 11'd0; blast <= 11'd0;
      out_vld <= 1'b0; out_sop <= 1'b0; out_eop <= 1'b0; out_data <= 8'd0;
      out_sport <= 16'd0; out_dport <= 16'd0; out_srcip <= 32'd0; out_plen <= 11'd0;
      accept_cnt <= 32'd0; free_cnt <= 32'd0; last_desc <= 32'd0;
      pay_cnt <= 32'd0; trunc_cnt <= 32'd0;
    end else begin
      out_vld <= 1'b0; out_sop <= 1'b0; out_eop <= 1'b0; cap_v <= 1'b0;

      // ---- 块归还：STREAM 一开始就可以还 ----
      if (free_req && free_take) begin
        freed    <= 1'b1;
        free_cnt <= free_cnt + 32'd1;
      end

      case (st)
        S_IDLE: if (in_vld && in_ready) begin
          pending_blk <= in_blk;
          out_plen    <= in_plen;
          accept_cnt  <= accept_cnt + 32'd1;
          // [31] valid; [22:15] port; [14:11] RX block; [10:0] UDP payload.
          last_desc   <= {1'b1, 8'd0, in_port, in_blk, in_plen};
          out_sport <= 16'd0; out_dport <= 16'd0; out_srcip <= 32'd0;
          wa <= W_START[8:0]; wp <= 9'd0;
          wlast <= last_word(in_plen);
          blast <= last_byte(in_plen);
          bcur  <= 11'd24;
          req_done <= 1'b0; freed <= 1'b0;
          if ({1'b0, PAY_OFF[10:0]} - 12'd1 + {1'b0, in_plen} >
              {1'b0, last_byte(in_plen)})
            trunc_cnt <= trunc_cnt + 32'd1;
          st <= (in_plen == 11'd0) ? S_WAIT : S_COPY;
          if (in_plen == 11'd0) freed <= 1'b0;
        end

        // ---- 1 字/拍整段搬运 ----
        S_COPY: begin
          if (pm_req && pm_gnt) begin
            cap_v <= 1'b1;
            if (wa >= wlast) req_done <= 1'b1;
            else             wa <= wa + 9'd1;
          end
          if (cap_v) begin
            pbuf[wp[7:0]] <= pm_data;
            wp <= wp + 9'd1;
            if (req_done && (wp >= (wlast - W_START[8:0]))) st <= S_STREAM;
          end
        end

        // ---- 1 字节/拍分发（P02：out_ready=0 时保持当前字节）----
        S_STREAM: begin
          if (!(out_vld && !out_ready)) begin
            // 无在途字节或上一字节已被接收：发射下一字节并推进位置
            case (bcur)
              11'd26, 11'd27, 11'd28, 11'd29: out_srcip <= {out_srcip[23:0], bsel};
              11'd34, 11'd35:                 out_sport <= {out_sport[7:0], bsel};
              11'd36, 11'd37:                 out_dport <= {out_dport[7:0], bsel};
              default: ;
            endcase
            out_data <= bsel;
            if (bcur >= PAY_OFF[10:0]) begin
              out_vld <= 1'b1;
              out_sop <= (bcur == PAY_OFF[10:0]);
              out_eop <= (bcur >= blast);
              pay_cnt <= pay_cnt + 32'd1;
            end
            bcur <= bcur + 11'd1;
            if (bcur >= blast) st <= S_WAIT;
          end else begin
            // 下游未接收：保持 data/valid/SOP/EOP 与待消费位置不变
            out_vld <= 1'b1;
            out_sop <= out_sop;
            out_eop <= out_eop;
          end
        end

        // 末字节在 S_STREAM 最后一拍发射、本状态首拍呈现；应用同样的保持
        // 规则，直到末字节被实际接收（否则 EOP 字节会被默认清零丢一拍）。
        S_WAIT: begin
          if (out_vld && !out_ready) begin
            out_vld <= 1'b1;
            out_sop <= out_sop;
            out_eop <= out_eop;
          end else if (freed) st <= S_IDLE;
        end
        default: st <= S_IDLE;
      endcase
    end
  end
    end else begin : g_chain
      wire c_out_vld;
      wire c_out_sop;
      wire c_out_eop;
      wire [7:0] c_out_data;
      wire [15:0] c_out_sport;
      wire [15:0] c_out_dport;
      wire [31:0] c_out_srcip;
      wire [10:0] c_out_plen;
      wire [31:0] c_accept_cnt;
      wire [31:0] c_free_cnt;
      wire [31:0] c_last_desc;
      wire [31:0] c_pay_cnt;
      wire [31:0] c_trunc_cnt;
      mgmt_sap_rx_chain u_chain (
        .clk(clk),
        .rst_sync(rst_sync),
        .in_vld(in_vld),
        .in_ready(in_ready),
        .in_port(in_port),
        .in_blk(in_blk),
        .in_plen(in_plen),
        .in_app_len(in_app_len),
        .in_blocks(in_blocks),
        .in_block_count(in_block_count),
        .pm_req(pm_req),
        .pm_addr(pm_addr),
        .pm_gnt(pm_gnt),
        .pm_data(pm_data),
        .out_vld(c_out_vld),
        .out_sop(c_out_sop),
        .out_eop(c_out_eop),
        .out_data(c_out_data),
        .out_sport(c_out_sport),
        .out_dport(c_out_dport),
        .out_srcip(c_out_srcip),
        .out_plen(c_out_plen),
        .out_app_len(out_app_len),
        .out_ready(out_ready),
        .free_req(free_req),
        .free_take(free_take),
        .free_id(free_id),
        .accept_cnt(c_accept_cnt),
        .free_cnt(c_free_cnt),
        .last_desc(c_last_desc),
        .pay_cnt(c_pay_cnt),
        .trunc_cnt(c_trunc_cnt)
      );
      // Mutually exclusive with the legacy sequential output drivers.
      always @* begin
        out_vld = c_out_vld;
        out_sop = c_out_sop;
        out_eop = c_out_eop;
        out_data = c_out_data;
        out_sport = c_out_sport;
        out_dport = c_out_dport;
        out_srcip = c_out_srcip;
        out_plen = c_out_plen;
        accept_cnt = c_accept_cnt;
        free_cnt = c_free_cnt;
        last_desc = c_last_desc;
        pay_cnt = c_pay_cnt;
        trunc_cnt = c_trunc_cnt;
      end
    end
  endgenerate
endmodule
