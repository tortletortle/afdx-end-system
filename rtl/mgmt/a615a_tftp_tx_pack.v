// =====================================================================
// a615a_tftp_tx_pack.v — client 发射描述符 → 完整 TFTP 报文缓冲（P05 组件）
// 状态：新增独立模块，未接入顶层（接入在 P05 集成步骤）。
//
// 职责：接收 a615a_tftp_client_1350 的发射描述符（一次 tx_fire），锁存后在
// 本地缓冲构造完整 TFTP 报文（不含 UDP/IP 封装），以"响应式"读口交给管理
// 发送路径（MT FSM 风格：pkt_vld 保持到 pkt_ack，pkt_byte 由 pkt_rd_addr 选）。
//
// 报文构造：
//   RRQ(1)/WRQ(2): 00 op | filename(fnlen) | 00 | "octet" | 00  （fnlen+9 字节）
//   DATA(3):       00 03 | block | payload(tx_data_len)          （4+dlen 字节）
//   ACK(4):        00 04 | block                                 （4 字节）
//   ERROR(5):      00 05 | code | text(tx_data_len)              （4+dlen 字节）
// 描述符字段在 tx_fire 当拍锁存（client 在 fire 后即改变组合输出）。
// 非法描述符（fnlen=0、DATA/ERROR len>512）被接受但从不出包并计入 err_cnt。
// =====================================================================
`timescale 1 ns / 1 ps
module a615a_tftp_tx_pack (
  input  wire        clk,
  input  wire        rst_sync,
  input  wire        en,
  // ---- 来自 client 的发射描述符 ----
  input  wire        tx_valid,
  output wire        tx_ready,
  input  wire [2:0]  tx_opcode,
  input  wire [15:0] tx_block,
  input  wire [15:0] tx_error_code,
  input  wire [9:0]  tx_data_len,
  input  wire [4095:0] tx_data,
  input  wire [2047:0] tx_filename,
  input  wire [7:0]  tx_filename_len,
  input  wire        tx_mode_octet,
  input  wire [31:0] tx_dst_ip,
  input  wire [15:0] tx_src_port,
  input  wire [15:0] tx_dst_port,
  // ---- 报文缓冲读口（管理发送路径消费）----
  output reg         pkt_vld,
  output reg  [10:0] pkt_len,
  output reg  [31:0] pkt_dst_ip,
  output reg  [15:0] pkt_src_port,
  output reg  [15:0] pkt_dst_port,
  input  wire [10:0] pkt_rd_addr,
  output wire [7:0]  pkt_byte,
  input  wire        pkt_ack,
  // ---- 观测 ----
  output reg  [31:0] pkt_cnt,
  output reg  [31:0] err_cnt
);
  localparam [2:0] S_IDLE = 3'd0, S_BUILD = 3'd1, S_HOLD = 3'd2;

  reg [2:0]  state;
  reg [2:0]  opc_l;
  reg [15:0] blk_l, ec_l;
  reg [9:0]  dlen_l;
  reg [4095:0] data_l;
  reg [2047:0] fn_l;
  reg [7:0]  fnlen_l;
  reg [10:0] idx;
  reg [10:0] total_l;
  reg [31:0] dst_l;      // fire 当拍锁存的目标字段（fire 后组合输出会变化）
  reg [15:0] sport_l, dport_l;

  reg [7:0] pbuf [0:519];

  // 描述符锁存（fire 当拍）
  wire tx_fire = tx_valid && tx_ready;
  assign tx_ready = !rst_sync && en && (state == S_IDLE);

  function [7:0] fnb; input [2047:0] d; input integer k;
    begin fnb = d[2047 - 8*k -: 8]; end
  endfunction
  function [7:0] datb; input [4095:0] d; input integer k;
    begin datb = d[4095 - 8*k -: 8]; end
  endfunction
  function [7:0] modech; input integer k;   // "octet"
    begin case (k) 0:modech="o";1:modech="c";2:modech="t";3:modech="e";4:modech="t";
                       default:modech=8'h00; endcase end
  endfunction

  // 当前正在构造的字节
  reg [7:0] cur;
  always @(*) begin
    cur = 8'h00;
    if (opc_l == 3'd1 || opc_l == 3'd2) begin
      if (idx == 11'd0) cur = 8'h00;
      else if (idx == 11'd1) cur = {5'd0, opc_l};
      else if (idx < {3'd0, fnlen_l} + 11'd2) cur = fnb(fn_l, idx - 11'd2);
      else if (idx == {3'd0, fnlen_l} + 11'd2) cur = 8'h00;
      else if (idx < {3'd0, fnlen_l} + 11'd8) cur = modech(idx - ({3'd0, fnlen_l} + 11'd3));
      else cur = 8'h00;
    end else begin
      if (idx == 11'd0) cur = 8'h00;
      else if (idx == 11'd1) cur = {5'd0, opc_l};
      else if (idx == 11'd2) cur = blk_l[15:8];
      else if (idx == 11'd3) cur = (opc_l == 3'd5) ? ec_l[7:0] : blk_l[7:0];
      else if (opc_l == 3'd5) cur = (idx == 11'd3) ? ec_l[7:0] : datb(data_l, idx - 11'd4);
      else cur = datb(data_l, idx - 11'd4);
    end
  end

  assign pkt_byte = pbuf[pkt_rd_addr];

  integer k;
  always @(posedge clk) begin
    if (rst_sync) begin
      state <= S_IDLE; idx <= 11'd0; total_l <= 11'd0;
      pkt_vld <= 1'b0; pkt_len <= 11'd0;
      pkt_dst_ip <= 32'd0; pkt_src_port <= 16'd0; pkt_dst_port <= 16'd0;
      pkt_cnt <= 32'd0; err_cnt <= 32'd0;
      opc_l <= 3'd0; blk_l <= 16'd0; ec_l <= 16'd0; dlen_l <= 10'd0;
      data_l <= 4096'd0; fn_l <= 2048'd0; fnlen_l <= 8'd0;
    end else begin
      case (state)
        S_IDLE: begin
          if (tx_fire) begin
            opc_l <= tx_opcode; blk_l <= tx_block; ec_l <= tx_error_code;
            dlen_l <= tx_data_len; data_l <= tx_data; fn_l <= tx_filename;
            fnlen_l <= tx_filename_len;
            dst_l <= tx_dst_ip; sport_l <= tx_src_port; dport_l <= tx_dst_port;
            // 合法性：RRQ/WRQ 需要 1..255 字节文件名；DATA/ERROR 载荷 ≤512
            if (((tx_opcode == 3'd1) || (tx_opcode == 3'd2)) &&
                (tx_filename_len >= 8'd1) && (tx_filename_len <= 8'd255)) begin
              total_l <= {3'd0, tx_filename_len} + 11'd9;
              idx <= 11'd0;  state <= S_BUILD;
            end else if ((tx_opcode == 3'd3) && (tx_data_len <= 10'd512)) begin
              total_l <= {1'b0, tx_data_len} + 11'd4;
              idx <= 11'd0;  state <= S_BUILD;
            end else if (tx_opcode == 3'd4) begin
              total_l <= 11'd4;
              idx <= 11'd0;  state <= S_BUILD;
            end else if ((tx_opcode == 3'd5) && (tx_data_len <= 10'd512)) begin
              total_l <= {1'b0, tx_data_len} + 11'd4;
              idx <= 11'd0;  state <= S_BUILD;
            end else begin
              err_cnt <= err_cnt + 32'd1;   // 非法描述符：接受但不发包
              state <= S_IDLE;
            end
          end
        end
        S_BUILD: begin
          pbuf[idx[9:0]] <= cur;
          if (idx + 11'd1 == total_l) begin
            pkt_len <= total_l;
            pkt_dst_ip <= dst_l; pkt_src_port <= sport_l; pkt_dst_port <= dport_l;
            pkt_vld <= 1'b1;
            pkt_cnt <= pkt_cnt + 32'd1;
            state <= S_HOLD;
          end else idx <= idx + 11'd1;
        end
        S_HOLD: begin
          if (pkt_ack) begin
            pkt_vld <= 1'b0;
            state <= S_IDLE;
          end
        end
        default: state <= S_IDLE;
      endcase
    end
  end
endmodule
