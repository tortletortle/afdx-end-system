// =====================================================================
// tx_vl_scheduler.v —— BAG 许可判定 + 最早到期优先（顺序扫描版，O-14）
// 设计书 §7.2（接口/判决式）、优化增量 r1 O-14（顺序扫描 + 时戳存储器）
//
// 实现要点:
//   * 128 条 VL 只用 1 个比较器顺序扫描，128 拍 = 1.02 μs 扫完一轮；
//     next_tx[24]/bag_us[24]/port[8] 放单写单读存储阵列（可推 BRAM），valid/inflight 为 FF 位图。
//   * 判决式（§7.2）: age = tb_us - next_tx (mod 2^24)，
//     due = valid & !inflight & port_ready[port] & !age[23] —— age 最大者即"最早到期"。
//   * 一轮扫完后若有候选且构建器空闲:
//       sch_take(port) → 等 sch_ack（2 拍）→ start_vld(vl, blk, len)，并置 inflight[vl]
//       （在途 VL 不再入选）；帧真正上线（mac_tx_if.frame_start）时
//       next_tx[vl] <= tb_us + bag_us[vl] + 1，随后清 inflight。
//     BAG 因而以**线上帧起始点**计（A664P7 口径），+1 抵消 μs 量化，保证相邻帧起始间隔 ≥ BAG。
//     若入选时 age ≥ bag_us（错过整整一个 BAG 槽：配置超额或饿死）→ bag_viol 脉冲 + bag_ovf_cnt。
//   * 在途帧按 GO 顺序入 16 深队列，frame_start / builder len_err（帧未生成）各弹出一项。
//   * sch_take 后若 5 拍内无 sch_ack（消息已被取空），放弃本轮重扫（take_miss_cnt）。
//   * 配置: cfg_we 写 {valid, bag_us, port}，写入时 next_tx <= tb_us（立即到期）；
//     valid=0 写入即停用。复位只清 valid/inflight 位图（阵列内容无需清零）。
//     cfg_we 与 frame_start 同拍时 cfg 优先（CFG_MODE=1 期间不应有帧在途）。
//   * 单构建器: 以 builder busy 为唯一互斥条件（发送侧 FIFO 由 mac_tx_if 背压）。
// 时钟/复位: clk(125 MHz) / rst_sync；握手 vld/pulse（§10）
// 资源: 1 个 24 bit 减法器 + 比较器 + 128×56 bit 阵列 ≈ 0.2K LUT（原并行方案 2.2K LUT + 6.1K FF）
// =====================================================================
`timescale 1 ns / 1 ps
module tx_vl_scheduler #(
  parameter integer NUM_TX_VL = 128,
  parameter integer NUM_PORTS = 256
) (
  input  wire                  clk,
  input  wire                  rst_sync,
  input  wire                  enable,         // TX_EN 与 INIT_DONE 门控；已有在途握手仍收尾
  input  wire [23:0]           tb_us,          // μs 时基低 24 位（§8.2）
  // ---- 配置写口（host_if，CFG_MODE=1）----
  input  wire                  cfg_we,
  input  wire [6:0]            cfg_vl,
  input  wire                  cfg_valid,
  input  wire [23:0]           cfg_bag_us,
  input  wire [7:0]            cfg_port,       // port_base（P0: 1 端口/VL）
  // ---- 端口就绪位图（tx_port_buf.sch_req）----
  input  wire [NUM_PORTS-1:0]  port_ready,
  // ---- 取消息（tx_port_buf）----
  output reg                   sch_take,
  output reg  [7:0]            sch_port,
  input  wire                  sch_ack,
  input  wire [3:0]            sch_blk,
  input  wire [12:0]           sch_len,
  // ---- 启动构建器 ----
  output reg                   start_vld,
  output reg  [7:0]            start_vl,
  output reg  [3:0]            start_blk,
  output reg  [12:0]           start_len,
  input  wire                  builder_busy,
  input  wire                  builder_len_err, // 帧未生成（弹出在途项）
  input  wire                  frame_start,     // 线上帧起始（mac_tx_if A 路）
  // ---- 自检/统计 ----
  output reg                   bag_viol,       // 1 拍
  output reg  [15:0]           bag_ovf_cnt,
  output reg  [15:0]           take_miss_cnt,  // take 无 ack 次数
  output wire [7:0]            vl_valid_cnt    // 有效 VL 数（调试）
);
  // ---------------- 存储阵列 ----------------
  reg [23:0] next_tx [0:NUM_TX_VL-1];
  reg [23:0] bag_arr [0:NUM_TX_VL-1];
  reg [7:0]  port_arr[0:NUM_TX_VL-1];
  reg [NUM_TX_VL-1:0] valid_map;
  reg [NUM_TX_VL-1:0] inflight;

  // ---------------- 状态 ----------------
  localparam [1:0] ST_SCAN = 2'd0;   // 顺序扫描，一轮 128 拍
  localparam [1:0] ST_TAKE = 2'd1;   // 已发 sch_take，等 ack（最多 3 拍）
  localparam [1:0] ST_GO   = 2'd2;   // 发 start_vld、置 inflight
  reg [1:0] st;

  reg [6:0]  idx;          // 扫描地址
  reg [6:0]  idx_d;        // 上拍地址（数据对应）
  reg        rd_vld;       // idx_d 数据有效
  reg [23:0] nt_q, bag_q;
  reg [7:0]  port_q;
  reg        val_q;

  // 本轮最佳候选
  reg        best_vld;
  reg [6:0]  best_vl;
  reg [7:0]  best_port;
  reg [23:0] best_age;
  reg [23:0] best_bag;

  // 判决（stage 1，寄存读出数据）
  wire [23:0] age  = tb_us - nt_q;
  wire        due  = val_q & ~inflight[idx_d] & port_ready[port_q] & ~age[23];
  wire        better = due & (~best_vld | (age > best_age));
  wire        last_of_round = rd_vld & (idx_d == NUM_TX_VL[6:0] - 7'd1);

  reg [2:0]  ack_wait;
  reg [6:0]  go_vl;
  reg        go_viol;

  // ---------------- 有效 VL 计数（调试）----------------
  function [7:0] popcnt128;
    input [127:0] m;
    integer k;
    begin
      popcnt128 = 8'd0;
      for (k = 0; k < 128; k = k + 1) popcnt128 = popcnt128 + {7'd0, m[k]};
    end
  endfunction
  assign vl_valid_cnt = popcnt128(valid_map);   // NUM_TX_VL<128 时高位零扩展

  // ---------------- 在途队列（GO 入队；frame_start / len_err 出队）----------------
  reg [6:0] ifq [0:15];        // 深 16：FIFO 内可同时在途多帧（GMII 512 B FIFO 约 8 帧）
  reg [3:0] ifq_wr, ifq_rd;
  wire      ifq_nonempty = (ifq_wr != ifq_rd);
  wire      pop = ifq_nonempty & (frame_start | builder_len_err);
  wire [6:0] pop_vl = ifq[ifq_rd];
  wire      go_wr = (st == ST_GO);
  integer q;
  always @(posedge clk) begin
    if (rst_sync) begin
      ifq_wr <= 4'd0; ifq_rd <= 4'd0;
      for (q = 0; q < 16; q = q + 1) ifq[q] <= 7'd0;
    end else begin
      if (go_wr) begin ifq[ifq_wr] <= go_vl; ifq_wr <= ifq_wr + 4'd1; end
      if (pop) ifq_rd <= ifq_rd + 4'd1;
    end
  end

  // ---------------- 阵列写口（cfg 优先于 frame_start）----------------
  always @(posedge clk) begin
    if (cfg_we) begin
      next_tx[cfg_vl]  <= tb_us;
      bag_arr[cfg_vl]  <= cfg_bag_us;
      port_arr[cfg_vl] <= cfg_port;
    end else if (pop) begin
      next_tx[pop_vl]  <= tb_us + bag_arr[pop_vl] + 24'd1;
    end
  end
  always @(posedge clk) begin
    if (rst_sync) begin
      valid_map <= {NUM_TX_VL{1'b0}}; inflight <= {NUM_TX_VL{1'b0}};
    end else begin
      if (cfg_we) valid_map[cfg_vl] <= cfg_valid;
      if (go_wr)  inflight[go_vl]   <= 1'b1;
      if (pop)    inflight[pop_vl]  <= 1'b0;
    end
  end

  // ---------------- 阵列读口（扫描）----------------
  always @(posedge clk) if (enable) begin
    nt_q   <= next_tx[idx];
    bag_q  <= bag_arr[idx];
    port_q <= port_arr[idx];
    val_q  <= valid_map[idx];
    idx_d  <= idx;
  end

  // ---------------- 主 FSM ----------------
  always @(posedge clk) begin
    if (rst_sync) begin
      st <= ST_SCAN; idx <= 7'd0; rd_vld <= 1'b0;
      best_vld <= 1'b0; best_vl <= 7'd0; best_port <= 8'd0; best_age <= 24'd0; best_bag <= 24'd0;
      sch_take <= 1'b0; sch_port <= 8'd0; ack_wait <= 3'd0;
      start_vld <= 1'b0; start_vl <= 8'd0; start_blk <= 4'd0; start_len <= 13'd0;
      go_vl <= 7'd0; go_viol <= 1'b0;
      bag_viol <= 1'b0; bag_ovf_cnt <= 16'd0; take_miss_cnt <= 16'd0;
    end else begin
      sch_take  <= 1'b0;
      start_vld <= 1'b0;
      bag_viol  <= 1'b0;
      case (st)
        ST_SCAN: if (!enable) begin
          // 保留配置/在途状态，不对无效内存读口取数；复使能后重新扫描一整轮。
          idx <= 7'd0; rd_vld <= 1'b0; best_vld <= 1'b0;
        end else begin
          idx    <= idx + 7'd1;            // NUM_TX_VL=128 时自然回绕
          rd_vld <= 1'b1;
          if (rd_vld) begin
            if (better) begin
              best_vld <= 1'b1; best_vl <= idx_d; best_port <= port_q; best_age <= age; best_bag <= bag_q;
            end
            if (last_of_round) begin
              best_vld <= 1'b0;
              if ((best_vld | better) && !builder_busy && enable) begin
                // 最后一项恰好更优时直接用它
                go_vl    <= better ? idx_d : best_vl;
                go_viol  <= better ? (age >= bag_q) : (best_age >= best_bag);
                sch_take <= 1'b1;
                sch_port <= better ? port_q : best_port;
                ack_wait <= 3'd0; rd_vld <= 1'b0; idx <= 7'd0;
                st <= ST_TAKE;
              end
            end
          end
        end
        ST_TAKE: begin
          if (sch_ack) begin
            start_vl <= {1'b0, go_vl}; start_blk <= sch_blk; start_len <= sch_len;
            st <= ST_GO;
          end else if (ack_wait == 3'd5) begin
            take_miss_cnt <= take_miss_cnt + 16'd1;
            st <= ST_SCAN;
          end else begin
            ack_wait <= ack_wait + 3'd1;
          end
        end
        ST_GO: begin
          start_vld <= 1'b1;
          if (go_viol) begin bag_viol <= 1'b1; bag_ovf_cnt <= bag_ovf_cnt + 16'd1; end
          st <= ST_SCAN;
        end
        default: st <= ST_SCAN;
      endcase
    end
  end
endmodule
