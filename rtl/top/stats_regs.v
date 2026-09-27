// =====================================================================
// stats_regs.v —— 全局统计页 0x0100~0x01FF（帧/字节/丢弃/抖动/直方图）
// 设计书: 附录 A `STATS_BLOCK` / §7.14 地址表 / §7.18 统计与丢弃原因 12 类
// 状态: continue4 实现（原第 0 周空壳）。页内字偏移 = host_addr[7:0]。
// 时钟/复位: clk(125 MHz) / rst_sync(§4.2)；事件输入均为单拍 pulse(§10)
//
// 兼容性约束（重要）：0x00~0x03 四个字沿用 v0.5.16 起的 rx_port_buf 口径
//   （交付 / 解析端口丢弃 / 采样覆盖 / 队列满），只读、不受读清影响，
//   现有 T08d/T08e/T08f/T10/T11 的断言语义原样保持。
//
// 覆盖边界（如实标注，勿当整机统计验收）：
//   - 12 类丢弃原因中 dmac / ip_csum / udp_csum 三类在当前 RX 链路里没有
//     独立判决源（mac_rx_if 的 drop_reason 只给 CRC/IP/UDP/HDR/LEN/PAD/
//     NO_BLK/ABORT 八档），这三个计数器恒 0 并在报告中登记为未接线。
//   - JIT_* 是"帧间到达间隔"（inter-arrival, μs）的高水位与一阶 EWMA，
//     不是 RFC3550 抖动，也不是 T05b 的线上 BAG 抖动取证。
// =====================================================================
`timescale 1 ns / 1 ps
module stats_regs (
  input  wire        clk,
  input  wire        rst_sync,
  input  wire        freeze,            // DBG_CTRL[6]：冻结统计更新

  // ---- RX 入口事件：一帧好帧进入查表级 ----
  input  wire        rx_in_evt,
  input  wire [10:0] rx_in_len,

  // ---- RX 接受事件：RM forward 握手拍 ----
  input  wire        rx_acc_evt,
  input  wire [10:0] rx_acc_len,
  input  wire [11:0] rx_acc_vl,
  input  wire [23:0] rx_acc_ts,

  // ---- TX 事件：整帧交给 MAC 完成 ----
  input  wire        tx_evt,
  input  wire [12:0] tx_len,

  // ---- 12 类丢弃原因单拍脉冲（§7.18 顺序）----
  // [0]len [1]dmac [2]ethtype [3]ip_ver [4]ip_csum [5]udp_len
  // [6]udp_csum [7]crc [8]unconf [9]lmax [10]ic [11]rm
  input  wire [11:0] drop_evt,

  // ---- 0x00~0x03 既有口径镜像（只读，语义不变）----
  input  wire [31:0] pb_deliver_cnt,
  input  wire [31:0] pb_port_drop_cnt,
  input  wire [31:0] pb_ovr_cnt,
  input  wire [31:0] pb_qovf_cnt,

  // ---- 主机口（页内偏移）----
  input  wire        host_rd,           // 本拍主机读本页
  input  wire        host_wr,           // 本拍主机写本页
  input  wire [7:0]  host_off,
  input  wire [31:0] host_wdata,
  output wire [31:0] host_rdata,       // 组合读出，由顶层在同拍寄存
  output wire        wr_ok,             // 该写地址合法（顶层并入 wr_known）

  // ---- SNMP STATS_BLOCK 只读第二端口（组合，不产生读清）----
  input  wire [7:0]  snmp_off,
  output wire [31:0] snmp_rdata,
  // ---- 给 snmp_lite 的两个标量 MIB 对象 ----
  output wire [31:0] jit_max_o,
  output wire [31:0] drop_total_o
);

  // ---- 页内字偏移 ----
  localparam [7:0] O_DELIVER   = 8'h00;
  localparam [7:0] O_PORTDROP  = 8'h01;
  localparam [7:0] O_OVR       = 8'h02;
  localparam [7:0] O_QOVF      = 8'h03;
  localparam [7:0] O_RX_FRAME  = 8'h04;
  localparam [7:0] O_RX_BYTE_L = 8'h05;
  localparam [7:0] O_RX_BYTE_H = 8'h06;
  localparam [7:0] O_RX_ACCEPT = 8'h07;
  localparam [7:0] O_TX_FRAME  = 8'h08;
  localparam [7:0] O_TX_BYTE_L = 8'h09;
  localparam [7:0] O_TX_BYTE_H = 8'h0A;
  localparam [7:0] O_DROP_TOT  = 8'h0B;
  localparam [7:0] O_JIT_MAX   = 8'h0C;
  localparam [7:0] O_JIT_LAST  = 8'h0D;
  localparam [7:0] O_JIT_MEAN  = 8'h0E;
  localparam [7:0] O_CTL       = 8'h0F;   // [0]RD_CLR_EN [1]FREEZE_SW
  localparam [7:0] O_DROP_K0   = 8'h10;   // 0x10~0x1B：12 类
  localparam [7:0] O_HIST_L0   = 8'h20;   // 0x20~0x27：帧长 8 桶
  localparam [7:0] O_HIST_V0   = 8'h28;   // 0x28~0x2F：前 8 VL 直方图

  reg [31:0] rx_frame_cnt, rx_byte_lo, rx_byte_hi, rx_acc_cnt;
  reg [31:0] tx_frame_cnt, tx_byte_lo, tx_byte_hi, drop_total;
  reg [31:0] jit_max, jit_last, jit_mean;
  reg [31:0] stats_ctl;
  reg [31:0] drop_k  [0:11];
  reg [31:0] hist_len [0:7];
  reg [31:0] hist_vl  [0:7];
  reg [23:0] ts_prev;
  reg        ts_valid;

  integer i;

  wire rd_clr_en = stats_ctl[0];
  wire upd       = !freeze && !stats_ctl[1];

  // ---- 帧长分桶（字节，含帧头，不含前导码）----
  function [2:0] len_bucket;
    input [12:0] l;
    begin
      if      (l <= 13'd64)   len_bucket = 3'd0;
      else if (l <= 13'd128)  len_bucket = 3'd1;
      else if (l <= 13'd256)  len_bucket = 3'd2;
      else if (l <= 13'd512)  len_bucket = 3'd3;
      else if (l <= 13'd768)  len_bucket = 3'd4;
      else if (l <= 13'd1024) len_bucket = 3'd5;
      else if (l <= 13'd1518) len_bucket = 3'd6;
      else                    len_bucket = 3'd7;
    end
  endfunction

  // ---- 清除掩码：W1C（写 1 清位）或读清（RD_CLR_EN=1 时读后整字清零）----
  function [31:0] clr_mask;
    input [7:0] off;
    begin
      if (host_wr && (host_off == off))                 clr_mask = host_wdata;
      else if (host_rd && rd_clr_en && (host_off == off)) clr_mask = 32'hFFFF_FFFF;
      else                                               clr_mask = 32'd0;
    end
  endfunction

  // 清零与本拍事件累加同时发生时：先清后加，事件不丢。
  function [31:0] upd_cnt;
    input [31:0] cur;
    input [31:0] mask;
    input [31:0] inc;
    begin
      upd_cnt = (cur & ~mask) + inc;
    end
  endfunction

  wire [2:0] rx_bkt = len_bucket({2'd0, rx_acc_len});
  wire [2:0] vl_bkt = rx_acc_vl[2:0];
  wire       vl_in_range = (rx_acc_vl < 12'd8);
  wire [23:0] ts_delta = rx_acc_ts - ts_prev;          // 24 bit 自然回绕
  wire [31:0] ts_delta32 = {8'd0, ts_delta};
  wire        jit_valid = rx_acc_evt && ts_valid && upd;

  // 写只对可清计数器与 STATS_CTL 合法；0x00~0x03 镜像为只读。
  wire off_clearable = (host_off >= O_RX_FRAME && host_off <= O_JIT_MEAN) ||
                       (host_off >= O_DROP_K0  && host_off <= (O_DROP_K0 + 8'd11)) ||
                       (host_off >= O_HIST_L0  && host_off <= (O_HIST_V0 + 8'd7));
  assign wr_ok = off_clearable || (host_off == O_CTL);

  always @(posedge clk) begin
    if (rst_sync) begin
      rx_frame_cnt <= 32'd0; rx_byte_lo <= 32'd0; rx_byte_hi <= 32'd0;
      rx_acc_cnt   <= 32'd0; tx_frame_cnt <= 32'd0;
      tx_byte_lo   <= 32'd0; tx_byte_hi <= 32'd0; drop_total <= 32'd0;
      jit_max <= 32'd0; jit_last <= 32'd0; jit_mean <= 32'd0;
      stats_ctl <= 32'd0; ts_prev <= 24'd0; ts_valid <= 1'b0;
      for (i = 0; i < 12; i = i + 1) drop_k[i]  <= 32'd0;
      for (i = 0; i < 8;  i = i + 1) hist_len[i] <= 32'd0;
      for (i = 0; i < 8;  i = i + 1) hist_vl[i]  <= 32'd0;
    end else begin
      // ---- STATS_CTL ----
      if (host_wr && (host_off == O_CTL)) stats_ctl <= host_wdata & 32'h3;

      // ---- 全局帧/字节 ----
      rx_frame_cnt <= upd_cnt(rx_frame_cnt, clr_mask(O_RX_FRAME),
                              (rx_in_evt && upd) ? 32'd1 : 32'd0);
      rx_acc_cnt   <= upd_cnt(rx_acc_cnt,   clr_mask(O_RX_ACCEPT),
                              (rx_acc_evt && upd) ? 32'd1 : 32'd0);
      tx_frame_cnt <= upd_cnt(tx_frame_cnt, clr_mask(O_TX_FRAME),
                              (tx_evt && upd) ? 32'd1 : 32'd0);
      drop_total   <= upd_cnt(drop_total,   clr_mask(O_DROP_TOT),
                              (upd && (|drop_evt)) ?
                                {28'd0,
                                 ({3'd0,drop_evt[0]} + {3'd0,drop_evt[1]} +
                                  {3'd0,drop_evt[2]} + {3'd0,drop_evt[3]}) +
                                 ({3'd0,drop_evt[4]} + {3'd0,drop_evt[5]} +
                                  {3'd0,drop_evt[6]} + {3'd0,drop_evt[7]}) +
                                 ({3'd0,drop_evt[8]} + {3'd0,drop_evt[9]} +
                                  {3'd0,drop_evt[10]} + {3'd0,drop_evt[11]})}
                                : 32'd0);

      // 64 bit 字节累加（低字进位到高字）
      begin : byte_acc
        reg [32:0] rx_lo_sum;
        reg [32:0] tx_lo_sum;
        rx_lo_sum = {1'b0, (rx_byte_lo & ~clr_mask(O_RX_BYTE_L))} +
                    ((rx_in_evt && upd) ? {22'd0, rx_in_len} : 33'd0);
        tx_lo_sum = {1'b0, (tx_byte_lo & ~clr_mask(O_TX_BYTE_L))} +
                    ((tx_evt && upd) ? {20'd0, tx_len} : 33'd0);
        rx_byte_lo <= rx_lo_sum[31:0];
        tx_byte_lo <= tx_lo_sum[31:0];
        rx_byte_hi <= (rx_byte_hi & ~clr_mask(O_RX_BYTE_H)) +
                      (rx_lo_sum[32] ? 32'd1 : 32'd0);
        tx_byte_hi <= (tx_byte_hi & ~clr_mask(O_TX_BYTE_H)) +
                      (tx_lo_sum[32] ? 32'd1 : 32'd0);
      end

      // ---- 12 类丢弃原因 ----
      for (i = 0; i < 12; i = i + 1)
        drop_k[i] <= upd_cnt(drop_k[i], clr_mask(O_DROP_K0 + i[7:0]),
                             (upd && drop_evt[i]) ? 32'd1 : 32'd0);

      // ---- 直方图：帧长 8 桶 + 前 8 VL ----
      for (i = 0; i < 8; i = i + 1) begin
        hist_len[i] <= upd_cnt(hist_len[i], clr_mask(O_HIST_L0 + i[7:0]),
                        (rx_acc_evt && upd && (rx_bkt == i[2:0])) ? 32'd1 : 32'd0);
        hist_vl[i]  <= upd_cnt(hist_vl[i],  clr_mask(O_HIST_V0 + i[7:0]),
                        (rx_acc_evt && upd && vl_in_range && (vl_bkt == i[2:0]))
                         ? 32'd1 : 32'd0);
      end

      // ---- 帧间到达间隔高水位 / EWMA（alpha = 1/16）----
      if (rx_acc_evt && upd) begin
        ts_prev  <= rx_acc_ts;
        ts_valid <= 1'b1;
      end
      if (jit_valid) begin
        jit_last <= ts_delta32 & ~clr_mask(O_JIT_LAST);
        jit_max  <= (ts_delta32 > (jit_max & ~clr_mask(O_JIT_MAX))) ?
                     ts_delta32 : (jit_max & ~clr_mask(O_JIT_MAX));
        jit_mean <= (jit_mean & ~clr_mask(O_JIT_MEAN)) -
                    ((jit_mean & ~clr_mask(O_JIT_MEAN)) >> 4) + (ts_delta32 >> 4);
      end else begin
        jit_last <= jit_last & ~clr_mask(O_JIT_LAST);
        jit_max  <= jit_max  & ~clr_mask(O_JIT_MAX);
        jit_mean <= jit_mean & ~clr_mask(O_JIT_MEAN);
      end
    end
  end

  // ---- 组合读出（未映射偏移读 0，与改造前一致）----
  // 两个读口各用一个独立的 always @(*)：Verilog 函数的局部变量是 static 的，
  // 若把译码做成函数再被两条连续赋值并发调用，两次求值会互相覆盖临时量，
  // 而且被函数读到的 unpacked 数组不一定进连续赋值的隐式敏感表。
  // 这里宁可把译码写两遍，也不用共享函数。
  reg [31:0] host_rd_c, snmp_rd_c;
  assign host_rdata   = host_rd_c;
  assign snmp_rdata   = snmp_rd_c;
  assign jit_max_o    = jit_max;
  assign drop_total_o = drop_total;

  always @(*) begin : host_dec
    reg [7:0] rel;
    rel = 8'd0;
    case (host_off)
      O_DELIVER:   host_rd_c = pb_deliver_cnt;
      O_PORTDROP:  host_rd_c = pb_port_drop_cnt;
      O_OVR:       host_rd_c = pb_ovr_cnt;
      O_QOVF:      host_rd_c = pb_qovf_cnt;
      O_RX_FRAME:  host_rd_c = rx_frame_cnt;
      O_RX_BYTE_L: host_rd_c = rx_byte_lo;
      O_RX_BYTE_H: host_rd_c = rx_byte_hi;
      O_RX_ACCEPT: host_rd_c = rx_acc_cnt;
      O_TX_FRAME:  host_rd_c = tx_frame_cnt;
      O_TX_BYTE_L: host_rd_c = tx_byte_lo;
      O_TX_BYTE_H: host_rd_c = tx_byte_hi;
      O_DROP_TOT:  host_rd_c = drop_total;
      O_JIT_MAX:   host_rd_c = jit_max;
      O_JIT_LAST:  host_rd_c = jit_last;
      O_JIT_MEAN:  host_rd_c = jit_mean;
      O_CTL:       host_rd_c = stats_ctl;
      default: begin
        if (host_off >= O_DROP_K0 && host_off <= (O_DROP_K0 + 8'd11)) begin
          rel = host_off - O_DROP_K0;  host_rd_c = drop_k[rel[3:0]];
        end else if (host_off >= O_HIST_L0 && host_off <= (O_HIST_L0 + 8'd7)) begin
          rel = host_off - O_HIST_L0;  host_rd_c = hist_len[rel[2:0]];
        end else if (host_off >= O_HIST_V0 && host_off <= (O_HIST_V0 + 8'd7)) begin
          rel = host_off - O_HIST_V0;  host_rd_c = hist_vl[rel[2:0]];
        end else begin
          host_rd_c = 32'd0;
        end
      end
    endcase
  end

  always @(*) begin : snmp_dec
    reg [7:0] rel2;
    rel2 = 8'd0;
    case (snmp_off)
      O_DELIVER:   snmp_rd_c = pb_deliver_cnt;
      O_PORTDROP:  snmp_rd_c = pb_port_drop_cnt;
      O_OVR:       snmp_rd_c = pb_ovr_cnt;
      O_QOVF:      snmp_rd_c = pb_qovf_cnt;
      O_RX_FRAME:  snmp_rd_c = rx_frame_cnt;
      O_RX_BYTE_L: snmp_rd_c = rx_byte_lo;
      O_RX_BYTE_H: snmp_rd_c = rx_byte_hi;
      O_RX_ACCEPT: snmp_rd_c = rx_acc_cnt;
      O_TX_FRAME:  snmp_rd_c = tx_frame_cnt;
      O_TX_BYTE_L: snmp_rd_c = tx_byte_lo;
      O_TX_BYTE_H: snmp_rd_c = tx_byte_hi;
      O_DROP_TOT:  snmp_rd_c = drop_total;
      O_JIT_MAX:   snmp_rd_c = jit_max;
      O_JIT_LAST:  snmp_rd_c = jit_last;
      O_JIT_MEAN:  snmp_rd_c = jit_mean;
      O_CTL:       snmp_rd_c = stats_ctl;
      default: begin
        if (snmp_off >= O_DROP_K0 && snmp_off <= (O_DROP_K0 + 8'd11)) begin
          rel2 = snmp_off - O_DROP_K0;  snmp_rd_c = drop_k[rel2[3:0]];
        end else if (snmp_off >= O_HIST_L0 && snmp_off <= (O_HIST_L0 + 8'd7)) begin
          rel2 = snmp_off - O_HIST_L0;  snmp_rd_c = hist_len[rel2[2:0]];
        end else if (snmp_off >= O_HIST_V0 && snmp_off <= (O_HIST_V0 + 8'd7)) begin
          rel2 = snmp_off - O_HIST_V0;  snmp_rd_c = hist_vl[rel2[2:0]];
        end else begin
          snmp_rd_c = 32'd0;
        end
      end
    endcase
  end
endmodule
