// =====================================================================
// mac_tx_if.v —— 线速节拍、tx_ready 包络、IFG、FCS 附加、对端背压（§7.6 / §5.3）
// 设计书 v0.5.5：IF_MODE 双模式（O-09）、FCS_MODE（§5.5）、节拍来自共享 tx_pace（§7.5）
//
// 输入: 来自 tx_rm 的 {byte, sof, eof} 字节流（vld/rdy 握手），内部 FIFO_D×9 FIFO。
// 输出（模板端口语义 §5.3）:
//   IF_MODE=0 帧包络: tx_ready 在首字节前 PRE_CYC(=2) 拍拉高、末字节后 1 拍拉低；
//     帧内每个 pace_en 槽发 1 字节（tx_valid 1 拍），字节间固定 BYTE_SLOT_CYC 拍；
//     帧后 IFG_BYTES 个槽包络保持低（IFG）。
//   IF_MODE=1 GMII 风格连续字节仿真：tx_valid 整帧连续为高、每拍 1 字节；帧间低 ≥ IFG_BYTES 拍；
//     tx_ready = 「可接收新消息」状态（空闲=1）。
//     为保证帧内无空拍，帧首在 FIFO 累积 ≥ START_THRESH 字节或已含 eof 后才开始
//     （builder 偏移 40 处等待 pass1 的空洞由此吸收；之后 builder 可持续 1 B/拍）。
// FCS: FCS_MODE≥1 时末字节后附加 4 字节 CRC32（802.3：寄存器值异或 FFFF_FFFF 后
//   低字节先发，即 crc_final[7:0], [15:8], [23:16], [31:24]）；FCS_MODE=0 不附加。
// 背压: link_rdy=0 时在字节边界暂停（tx_valid=0、包络维持），§5.3 规则 5。
// frame_start: 首字节 tx_valid 拍；frame_done: 末字节（含 FCS）tx_valid 拍，各 1 拍脉冲。
// START_GUARD_EN: start_permit只门控IDLE退出，含已缓冲完整帧；帧内下降不暂停DV。
// 时钟/复位: clk(125 MHz) / rst_sync；握手仅 vld/rdy 与 pulse（§10）
// =====================================================================
`timescale 1 ns / 1 ps
module mac_tx_if #(
  parameter integer IF_MODE      = 0,
  parameter integer PREAMBLE_EN  = 0,      // PHY GMII: seven 55 bytes, then D5
  parameter integer FCS_MODE     = 2,
  parameter integer IFG_BYTES    = 12,
  parameter integer FIFO_D       = 64,     // 2 的幂；IF_MODE=1 建议 ≥ 64
  parameter integer START_THRESH = 48,     // 仅 IF_MODE=1：起帧所需 FIFO 字节数（> 41）
  parameter integer PRE_CYC      = 2,      // IF_MODE=0：包络先于首字节的拍数（≥2）
  parameter integer START_GUARD_EN = 0    // optional BAG gate; never stalls a started frame
) (
  input  wire       clk,
  input  wire       rst_sync,
  // ---- 来自 tx_rm ----
  input  wire       in_vld,
  input  wire [7:0] in_byte,
  input  wire       in_sof,
  input  wire       in_eof,
  output wire       in_rdy,
  // ---- 共享节拍 ----
  input  wire       pace_en,
  input  wire       start_permit,
  // ---- 对 MAC（模板端口）----
  output reg  [7:0] tx_data,
  output reg        tx_valid,
  output reg        tx_ready,
  input  wire       link_rdy,      // 对端背压（无对端时接 1）
  // ---- 给 builder / scheduler / tx_rm ----
  output wire       frame_start,    // 首字节 tx_valid 拍
  output wire       frame_done,     // 末字节（含 FCS）tx_valid 拍
  output wire       busy,
  // ---- 统计 ----
  output reg  [15:0] underrun_cnt  // 帧内槽到但 FIFO 空的次数（应为 0）
);
  // ---------------- FIFO（寄存器阵列，带计数）----------------
  localparam integer AW = (FIFO_D <= 2) ? 1 : (FIFO_D <= 4) ? 2 : (FIFO_D <= 8) ? 3 :
                          (FIFO_D <= 16) ? 4 : (FIFO_D <= 32) ? 5 : (FIFO_D <= 64) ? 6 :
                          (FIFO_D <= 128) ? 7 : (FIFO_D <= 256) ? 8 : (FIFO_D <= 512) ? 9 : 10;
  reg [8:0]  mem [0:FIFO_D-1];             // {eof, byte}
  reg [AW:0] wr_ptr, rd_ptr, cnt;
  reg [AW:0] eof_cnt;                      // FIFO 内 eof 个数（GMII 起帧条件）
  wire       f_full  = (cnt == FIFO_D[AW:0]);
  wire       f_empty = (cnt == {(AW+1){1'b0}});
  wire       f_wr    = in_vld & ~f_full;
  assign     in_rdy  = ~f_full;
  reg        f_rd;                         // 本拍弹出（组合）
  reg [8:0]  rd_q;                         // 弹出数据（下一拍有效）

  always @(posedge clk) begin
    if (rst_sync) begin
      wr_ptr <= {(AW+1){1'b0}}; rd_ptr <= {(AW+1){1'b0}};
      cnt <= {(AW+1){1'b0}}; eof_cnt <= {(AW+1){1'b0}};
    end else begin
      if (f_wr) begin
        mem[wr_ptr[AW-1:0]] <= {in_eof, in_byte};
        wr_ptr <= wr_ptr + 1'b1;
      end
      if (f_rd) begin
        rd_q   <= mem[rd_ptr[AW-1:0]];
        rd_ptr <= rd_ptr + 1'b1;
      end
      cnt     <= cnt + {{AW{1'b0}}, f_wr} - {{AW{1'b0}}, f_rd};
      eof_cnt <= eof_cnt + {{AW{1'b0}}, (f_wr & in_eof)} - {{AW{1'b0}}, (f_rd & mem[rd_ptr[AW-1:0]][8])};
    end
  end

  // ---------------- CRC ----------------
  wire [31:0] crc_final;
  reg         crc_init, crc_dv;
  reg  [7:0]  crc_din;
  crc32 u_crc (.clk(clk), .rst(rst_sync), .init(crc_init), .data_valid(crc_dv),
               .data(crc_din), .crc_out(), .crc_final(crc_final));

  // ---------------- 状态机 ----------------
  localparam [2:0] ST_IDLE = 3'd0;   // 等 FIFO 有数据（连续字节模式：够阈值）+ IFG 已满足
  localparam [2:0] ST_PRE  = 3'd1;   // IF_MODE=0：包络先拉高 PRE_CYC 拍
  localparam [2:0] ST_DATA = 3'd2;   // 逐槽发数据字节，直到 eof
  localparam [2:0] ST_FCS  = 3'd3;   // 4 字节 FCS
  localparam [2:0] ST_POST = 3'd4;   // IF_MODE=0：末字节后包络多保持 1 拍
  localparam [2:0] ST_IFG  = 3'd5;   // 帧间隙 IFG_BYTES 槽
  reg [2:0]  st;
  reg [7:0]  pre_cnt;
  reg [1:0]  fcs_idx;
  reg [7:0]  ifg_cnt;
  reg        o_dat_vld;              // 上拍弹了 FIFO → 本拍 tx 输出数据字节
  reg        o_fcs_vld;              // 本拍输出 FCS 字节
  reg [1:0]  o_fcs_idx;
  reg        o_last;                 // 本拍输出的是帧末字节
  reg        o_first;
  reg        o_pre_vld;
  reg [7:0]  o_pre_byte;
  reg        first_pending;          // 帧首字节尚未发出

  wire start_ok = (IF_MODE != 0) ? ((cnt >= START_THRESH[AW:0]) || (eof_cnt != {(AW+1){1'b0}}))
                                 : ~f_empty;
  // PHY GMII has no ready handshake. Keep legacy MAC-user backpressure
  // confined to the two original byte-stream modes.
  wire slot     = pace_en & ((PREAMBLE_EN != 0) || link_rdy);
  wire fcs_en   = (FCS_MODE != 0);
  wire [7:0] fcs_byte = (o_fcs_idx == 2'd0) ? crc_final[7:0]  :
                        (o_fcs_idx == 2'd1) ? crc_final[15:8] :
                        (o_fcs_idx == 2'd2) ? crc_final[23:16] : crc_final[31:24];

  assign busy = (st != ST_IDLE) && (st != ST_IFG);
  assign frame_start = o_first;
  assign frame_done  = o_last;

  // 弹出条件（组合）
  always @(*) begin
    f_rd = 1'b0;
    if (st == ST_DATA && slot && !f_empty) f_rd = 1'b1;
  end

  // 输出级：寄存的选择 + 组合 mux（FCS 字节须用本拍 crc_r，见 crc32 1 拍更新）
  always @(*) begin
    tx_data  = o_pre_vld ? o_pre_byte : (o_fcs_vld ? fcs_byte : rd_q[7:0]);
    tx_valid = o_pre_vld | o_dat_vld | o_fcs_vld;
    crc_dv   = o_dat_vld;
    crc_din  = rd_q[7:0];
  end

  always @(posedge clk) begin
    if (rst_sync) begin
      st <= ST_IDLE; pre_cnt <= 8'd0; fcs_idx <= 2'd0; ifg_cnt <= 8'd0;
      o_dat_vld <= 1'b0; o_fcs_vld <= 1'b0; o_fcs_idx <= 2'd0; o_last <= 1'b0; o_first <= 1'b0;
      o_pre_vld <= 1'b0; o_pre_byte <= 8'd0;
      first_pending <= 1'b1; tx_ready <= 1'b0;
      crc_init <= 1'b0; underrun_cnt <= 16'd0;
    end else begin
      // 默认脉冲
      o_dat_vld <= 1'b0; o_fcs_vld <= 1'b0; o_last <= 1'b0; o_first <= 1'b0;
      o_pre_vld <= 1'b0;
      crc_init  <= 1'b0;
      case (st)
        ST_IDLE: begin
          tx_ready <= (IF_MODE != 0);                 // 连续字节模式：空闲 = 可接收新消息
          if (start_ok && ((START_GUARD_EN == 0) || start_permit)) begin
            crc_init <= 1'b1; first_pending <= 1'b1;
            if (PREAMBLE_EN != 0) begin st <= ST_PRE; pre_cnt <= 8'd0; tx_ready <= 1'b0; end
            else if (IF_MODE != 0) begin st <= ST_DATA; tx_ready <= 1'b0; end
            else begin st <= ST_PRE; pre_cnt <= 8'd0; tx_ready <= 1'b1; end
          end
        end
        ST_PRE: begin
          pre_cnt <= pre_cnt + 8'd1;
          if (PREAMBLE_EN != 0) begin
            // The first DATA byte is registered in the cycle immediately
            // after SFD. Preamble is deliberately excluded from CRC32.
            o_pre_vld <= 1'b1;
            o_pre_byte <= (pre_cnt == 8'd7) ? 8'hD5 : 8'h55;
            if (pre_cnt == 8'd7) st <= ST_DATA;
          end else if (pre_cnt >= PRE_CYC[7:0] - 8'd1) st <= ST_DATA;
        end
        ST_DATA: begin
          if (slot) begin
            if (!f_empty) begin
              o_dat_vld <= 1'b1;
              o_first   <= first_pending; first_pending <= 1'b0;
              if (mem[rd_ptr[AW-1:0]][8]) begin          // eof 字节
                if (fcs_en) begin st <= ST_FCS; fcs_idx <= 2'd0; end
                else begin o_last <= 1'b1; st <= (IF_MODE != 0) ? ST_IFG : ST_POST; ifg_cnt <= 8'd0; end
              end
            end else begin
              underrun_cnt <= underrun_cnt + 16'd1;
            end
          end
        end
        ST_FCS: begin
          if (slot) begin
            o_fcs_vld <= 1'b1; o_fcs_idx <= fcs_idx; fcs_idx <= fcs_idx + 2'd1;
            if (fcs_idx == 2'd3) begin
              o_last <= 1'b1; st <= (IF_MODE != 0) ? ST_IFG : ST_POST; ifg_cnt <= 8'd0;
            end
          end
        end
        ST_POST: begin                                  // 本拍 = 末字节 tx_valid 拍；下拍包络落
          if (o_last) begin tx_ready <= 1'b0; st <= ST_IFG; ifg_cnt <= 8'd0; end
        end
        ST_IFG: begin
          if (pace_en) begin
            ifg_cnt <= ifg_cnt + 8'd1;
            if (ifg_cnt >= IFG_BYTES[7:0] - 8'd1) st <= ST_IDLE;
          end
        end
        default: st <= ST_IDLE;
      endcase
    end
  end
endmodule
