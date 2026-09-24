// =====================================================================
// rx_port_buf.v —— RX 端口缓冲：采样/队列端口、主机读取与块回收（§7.13）
// v0.5.16 接入 AFDX_top（rx_ip_udp_parse 之后）。数据不搬移：消息就是
// mac_rx_if 写好的 PMEM 块，本模块只管描述符和块的所有权。
// 主机协议（v0.5.16 定案，设计书 §7.13 实现状态 / §7.14）:
//   1) 读 PORT_DESC[p]（0x8180+p，端口表 w0[18]=1 的 RX 端口）:
//      [31] valid  [30] fresh  [29] ovf  [28] pin  [27:24] cnt
//      [23:20] blk  [19:11] 0  [10:0] 载荷字节数 L
//      读即清 fresh 与 ovf，并把当前头消息标为"主机已看见"（seen）。
//   2) 读载荷：PMEM 字地址 0x8800 + blk*0x200 + (42+i)/4，大端字节序
//      （字节 42+i 在 [31-8*((42+i)%4) -: 8]）；运行期允许读 RX 块。
//   3) 写 MSG_RD[p]（0x8380+p，数据忽略）释放:
//      采样端口 —— 释放被钉住的旧块（若有）；若头消息已 seen，再释放它并清 valid；
//      队列端口 —— 弹出头消息并释放其块，下一条成为新头（fresh=1）。
//   4) MSG_CNT[p]（0x8480+p，只读）= 当前消息数 cnt。
// 采样端口: 新消息覆盖旧消息（ovr_cnt+1、ovf=1）。若旧消息已被主机读过描述符
//   （seen，主机可能正在读载荷），旧块不立即回收而被"钉住"（pin），在下一次
//   MSG_RD 时释放；已有钉住块时先释放较早的那个。未 seen 的旧块立即回收。
// 队列端口: 深度 = 端口表 w3[3:0]（0 按 1），满则丢新帧（q_ovf+1、ovf=1、计入
//   丢弃合计），对端不可见（§7.13）。队列用块链 nxt[blk]（同 tx_port_buf）。
// 事件串行: 每拍至多一个事件；主机操作优先，解析结果顺延（in_ready=0）。
//   每个事件至多释放 2 块（free0/free1，接 rx_block_pool 的两个 pb 释放口）。
// 端口状态为寄存器阵列，由 init_sweep T_RXDESC（target 6）逐项清零；块元数据
//   （len/nxt）只在块被链入时读，不需初始化。
// 时钟/复位: clk / rst_sync（§4.2）。
// =====================================================================
`timescale 1 ns / 1 ps
module rx_port_buf #(
  parameter integer NUM_PORTS = 256
) (
  input  wire        clk,
  input  wire        rst_sync,
  input  wire        init_we,
  input  wire [12:0] init_addr,
  // parse result
  input  wire        in_vld,
  output wire        in_ready,
  input  wire        in_drop,
  input  wire [7:0]  in_port,
  input  wire [1:0]  in_type,
  input  wire [3:0]  in_depth,
  input  wire [3:0]  in_blk,
  input  wire [10:0] in_plen,
  // host operations (at most one per cycle)
  input  wire        hop_desc_rd,
  input  wire        hop_msg_rd,
  input  wire [7:0]  hop_port,
  input  wire [1:0]  hop_type,      // port table w0[17:16] of hop_port
  output wire [31:0] desc_word,     // combinational, for hop_port
  output wire [3:0]  cnt_word,
  // block release
  output reg         free0,
  output reg  [3:0]  free0_id,
  output reg         free1,
  output reg  [3:0]  free1_id,
  // statistics / events
  output reg         ev_drop,       // parse drop or queue overflow (1 frame)
  output reg         ev_sample,     // v0.5.17 INT: sampling message delivered
  output reg         ev_queue,      // v0.5.17 INT: message enqueued
  output reg         ev_ovf,        // v0.5.17 INT: sampling overwrite or queue full
  output reg  [31:0] deliver_cnt,
  output reg  [31:0] port_drop_cnt,
  output reg  [31:0] ovr_cnt,
  output reg  [31:0] qovf_cnt
);
  reg [3:0]  p_cnt   [0:NUM_PORTS-1];
  reg [3:0]  p_head  [0:NUM_PORTS-1];
  reg [3:0]  p_tail  [0:NUM_PORTS-1];
  reg [3:0]  p_pinb  [0:NUM_PORTS-1];
  reg        p_fresh [0:NUM_PORTS-1];
  reg        p_ovf   [0:NUM_PORTS-1];
  reg        p_seen  [0:NUM_PORTS-1];
  reg        p_pin   [0:NUM_PORTS-1];
  reg [10:0] b_len   [0:15];
  reg [3:0]  b_nxt   [0:15];

  wire hop_any = hop_desc_rd || hop_msg_rd;
  assign in_ready = !rst_sync && !init_we && !hop_any;
  wire ev = in_vld && in_ready;

  // host view
  wire [3:0] h_cnt  = p_cnt[hop_port];
  wire [3:0] h_head = p_head[hop_port];
  assign desc_word = {(h_cnt != 4'd0), p_fresh[hop_port], p_ovf[hop_port],
                      p_pin[hop_port], h_cnt, h_head, 9'd0,
                      (h_cnt != 4'd0) ? b_len[h_head] : 11'd0};
  assign cnt_word = h_cnt;

  // frame event view
  wire [3:0] e_cnt  = p_cnt[in_port];
  wire [3:0] e_head = p_head[in_port];
  wire [3:0] e_tail = p_tail[in_port];
  wire       e_seen = p_seen[in_port];
  wire       e_pin  = p_pin[in_port];
  wire [3:0] e_pinb = p_pinb[in_port];

  always @(posedge clk) begin
    free0 <= 1'b0; free1 <= 1'b0; ev_drop <= 1'b0;
    ev_sample <= 1'b0; ev_queue <= 1'b0; ev_ovf <= 1'b0;
    if (rst_sync) begin
      free0_id <= 4'd0; free1_id <= 4'd0;
      deliver_cnt <= 32'd0; port_drop_cnt <= 32'd0; ovr_cnt <= 32'd0; qovf_cnt <= 32'd0;
    end else if (init_we) begin
      if (init_addr < NUM_PORTS) begin
        p_cnt[init_addr[7:0]] <= 4'd0;   p_fresh[init_addr[7:0]] <= 1'b0;
        p_ovf[init_addr[7:0]] <= 1'b0;   p_seen[init_addr[7:0]]  <= 1'b0;
        p_pin[init_addr[7:0]] <= 1'b0;
      end
    end else if (hop_desc_rd) begin
      p_fresh[hop_port] <= 1'b0;
      p_ovf[hop_port]   <= 1'b0;
      p_seen[hop_port]  <= (h_cnt != 4'd0);
    end else if (hop_msg_rd) begin
      if (hop_type == 2'd0) begin
        if (p_pin[hop_port]) begin
          free0 <= 1'b1; free0_id <= p_pinb[hop_port]; p_pin[hop_port] <= 1'b0;
        end
        if (p_seen[hop_port] && h_cnt != 4'd0) begin
          free1 <= 1'b1; free1_id <= h_head;
          p_cnt[hop_port] <= 4'd0; p_seen[hop_port] <= 1'b0; p_fresh[hop_port] <= 1'b0;
        end
      end else if (h_cnt != 4'd0) begin
        free0 <= 1'b1; free0_id <= h_head;
        p_head[hop_port]  <= b_nxt[h_head];
        p_cnt[hop_port]   <= h_cnt - 4'd1;
        p_fresh[hop_port] <= (h_cnt > 4'd1);
        p_seen[hop_port]  <= 1'b0;
      end
    end else if (ev) begin
      if (in_drop) begin
        free0 <= 1'b1; free0_id <= in_blk; ev_drop <= 1'b1;
        port_drop_cnt <= port_drop_cnt + 32'd1;
      end else if (in_type == 2'd0) begin
        b_len[in_blk] <= in_plen;
        deliver_cnt <= deliver_cnt + 32'd1;
        ev_sample <= 1'b1;
        if (e_cnt != 4'd0) begin
          ovr_cnt <= ovr_cnt + 32'd1; ev_ovf <= 1'b1;
          p_ovf[in_port] <= 1'b1;
          if (e_seen) begin
            if (e_pin) begin free0 <= 1'b1; free0_id <= e_pinb; end
            p_pin[in_port] <= 1'b1; p_pinb[in_port] <= e_head;
          end else begin
            free0 <= 1'b1; free0_id <= e_head;
          end
        end
        p_cnt[in_port] <= 4'd1; p_head[in_port] <= in_blk; p_tail[in_port] <= in_blk;
        p_fresh[in_port] <= 1'b1; p_seen[in_port] <= 1'b0;
      end else if (e_cnt >= in_depth) begin
        free0 <= 1'b1; free0_id <= in_blk; ev_drop <= 1'b1;
        qovf_cnt <= qovf_cnt + 32'd1; ev_ovf <= 1'b1;
        p_ovf[in_port] <= 1'b1;
      end else begin
        b_len[in_blk] <= in_plen;
        deliver_cnt <= deliver_cnt + 32'd1;
        ev_queue <= 1'b1;
        if (e_cnt == 4'd0) begin
          p_head[in_port] <= in_blk; p_fresh[in_port] <= 1'b1;
        end else b_nxt[e_tail] <= in_blk;
        p_tail[in_port] <= in_blk;
        p_cnt[in_port]  <= e_cnt + 4'd1;
      end
    end
  end
endmodule
