// =====================================================================
// a615a_tftp_dgram_rx.v — SAP 字节流 → 完整 TFTP 数据报字段（客户端接收侧）
// P05 组件（2026-10-10）。状态：新增独立模块；未接入顶层（接入在 P05 集成步骤）。
//
// 职责：消费 mgmt_sap_rx 的 UDP 载荷字节流（out_vld/sop/eop/data +
// sport/dport/srcip），在整包到达后完成字段解析与合法性检查，然后以
// 单拍描述符（rx_valid）交给 a615a_tftp_client_1350 的 rx 端口。
//
// 契约：
//   * rx_valid 前必须完成完整数据报解析与字段合法性检查（client 注释要求）；
//   * 只接受响应类操作码 DATA(3)/ACK(4)/ERROR(5)；RRQ(1)/WRQ(2)/OACK(6)、
//     首字节非 0、DATA payload>512、ACK≠4B、ERROR<4B 或缺 NUL 终止、
//     超缓冲的整包丢弃并计数，不产生 rx_valid；
//   * 完整未消费的数据报以 out_ready=0 对上游背压（P02 可停顿字节流契约），
//     data/字段在 rx_ready 前保持稳定；
//   * DATA 载荷按大端装入 [4095:4088]=第 0 字节（client 的数组约定）。
// =====================================================================
`timescale 1 ns / 1 ps
module a615a_tftp_dgram_rx #(
  parameter integer BUF_BYTES = 516   // 4B 头 + 最多 512B 载荷
) (
  input  wire        clk,
  input  wire        rst_sync,
  input  wire        en,
  // ---- 上游：SAP 字节流（可停顿）----
  input  wire        in_vld,
  input  wire        in_sop,
  input  wire        in_eop,
  input  wire [7:0]  in_data,
  input  wire [15:0] in_sport,
  input  wire [15:0] in_dport,
  input  wire [31:0] in_srcip,
  output wire        out_ready,
  // ---- 下游：client rx 端口 ----
  output reg         rx_valid,
  input  wire        rx_ready,
  output reg  [31:0] rx_src_ip,
  output reg  [15:0] rx_src_port,
  output reg  [15:0] rx_dst_port,
  output reg  [2:0]  rx_opcode,
  output reg  [15:0] rx_block,
  output reg  [9:0]  rx_data_len,
  output reg  [4095:0] rx_data,
  output reg  [15:0] rx_error_code,
  // ---- 观测 ----
  output reg  [31:0] ok_cnt,
  output reg  [31:0] drop_cnt
);
  localparam [1:0] S_IDLE = 2'd0, S_PARSE = 2'd1, S_CHECK = 2'd2, S_HOLD = 2'd3;

  reg [1:0]  state;
  reg [9:0]  bidx;          // 当前拍接收字节的索引（0 起）
  reg [9:0]  flen;          // 最终包长
  reg        over;          // 缓冲溢出
  reg        bad;           // 已判定非法
  reg [7:0]  dbuf [0:BUF_BYTES-1];
  reg [4095:0] pay;         // 载荷移位寄存器（顺序追加）
  integer pay_byte_i;

  // 解析中必须继续接收（整包以 EOP 结束）；仅在判决/保持期对上游背压。
  // en=0 时排空（整包吸收后丢弃计数），避免被禁用的引擎阻塞 SAP。
  assign out_ready = !rst_sync &&
                     (en ? ((state == S_IDLE) || (state == S_PARSE)) : 1'b1);

  wire accept = in_vld && out_ready;
  wire [2:0] opc = dbuf[1];
  wire [11:0] lane_off = (bidx - 10'd3) << 3;      // 当前字节的载荷内偏移 ×8
  wire [12:0] lane_top = 13'd4095 - {1'b0, lane_off};

  reg okf;                  // S_CHECK 组合判决
  reg last_nul;             // ERROR 末字节 NUL
  always @(*) begin
    last_nul = (opc == 3'd5) ? ((flen >= 10'd4) ? (dbuf[flen - 10'd1] == 8'h00)
                                                 : 1'b0)
                             : 1'b1;
    // 按操作码的长度规则：DATA 4..516；ACK 恰 4；ERROR ≥4 且 NUL 终止
    okf = (flen >= 10'd4) && !over && !bad &&
          ((opc == 3'd3) ? (flen <= 10'd516) :
           (opc == 3'd4) ? (flen == 10'd4)  :
           (opc == 3'd5) ? last_nul         : 1'b0);
  end

  always @(posedge clk) begin
    if (rst_sync) begin
      state <= S_IDLE; bidx <= 10'd0; flen <= 10'd0; over <= 1'b0; bad <= 1'b0;
      pay <= 4096'd0;
      rx_valid <= 1'b0; rx_src_ip <= 32'd0; rx_src_port <= 16'd0;
      rx_dst_port <= 16'd0; rx_opcode <= 3'd0; rx_block <= 16'd0;
      rx_data_len <= 10'd0; rx_data <= 4096'd0; rx_error_code <= 16'd0;
      ok_cnt <= 32'd0; drop_cnt <= 32'd0;
    end else begin
      // ---- 字节接收（仅空闲/解析态）----
      if (accept) begin
        if (in_sop) begin
          bidx <= 10'd0; over <= 1'b0; bad <= (in_data != 8'h00);
          dbuf[0] <= in_data;
          pay <= 4096'd0;
          if (in_eop) begin flen <= 10'd1; state <= S_CHECK; end
          else state <= S_PARSE;
        end else begin
          // 当前字节索引 = bidx + 1（0 起）；buf 只存到 BUF_BYTES-1
          bidx <= bidx + 10'd1;
          if (bidx <= (BUF_BYTES - 2)) dbuf[bidx + 10'd1] <= in_data;
          else over <= 1'b1;
          // 报文字节 1 = 操作码；只接受响应类 3/4/5
          if (bidx == 10'd0)
            if (in_data < 8'd3 || in_data > 8'd5) bad <= 1'b1;
          // 载荷按 client 数组约定装入：字节 j（j=索引-4）在 [4095-8j -: 8]
          if (bidx >= 10'd3 && bidx <= (BUF_BYTES - 2))
            for (pay_byte_i = 0; pay_byte_i < 512; pay_byte_i = pay_byte_i + 1) begin
              if (lane_top == (4095 - 8*pay_byte_i))
                pay[4095 - 8*pay_byte_i -: 8] <= in_data;
            end
          if (in_eop) begin
            flen <= bidx + 10'd2;
            rx_src_ip <= in_srcip; rx_src_port <= in_sport; rx_dst_port <= in_dport;
            state <= S_CHECK;
          end
        end
      end

      case (state)
        S_CHECK: begin
          if (okf && en) begin
            rx_opcode <= opc;
            rx_block  <= {dbuf[2], dbuf[3]};
            rx_data_len <= (opc == 3'd3) ? (flen - 10'd4) : 10'd0;
            rx_data   <= pay;
            rx_error_code <= (opc == 3'd5) ? {dbuf[2], dbuf[3]} : 16'd0;
            rx_valid <= 1'b1;
            ok_cnt <= ok_cnt + 32'd1;
            state <= S_HOLD;
          end else begin
            drop_cnt <= drop_cnt + 32'd1;
            state <= S_IDLE;
          end
        end
        S_HOLD: begin
          if (rx_ready || !en) begin
            rx_valid <= 1'b0;
            state <= S_IDLE;
          end
        end
        default: ;
      endcase
    end
  end
endmodule
