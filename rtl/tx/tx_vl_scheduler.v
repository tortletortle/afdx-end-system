// =====================================================================
// tx_vl_scheduler.v —— BAG 许可判定 + 最早到期优先（8 路并行分组扫描）
// 设计书 §7.2（接口/判决式）、O-14 时戳存储器
//
// 实现要点:
//   * 每拍并行比较 8 条 VL，128 条 VL 用 16 拍扫完一轮；
//     next_tx[32]/bag_cycles[31]/port[8] 为时戳阵列，valid/inflight 为 FF 位图。
//   * 判决式（§7.2）: age = cycle_count + PREPARE_CYCLES - next_tx (mod 2^32)，
//     due = valid & !inflight & port_ready[port] & !age[31] —— age 最大者即"最早到期"。
//   * 一轮扫完后若有候选且构建器空闲:
//       sch_take(port) → 等 sch_ack（2 拍）→ start_vld(vl, blk, len)，并置 inflight[vl]
//       （在途 VL 不再入选）；帧真正上线（mac_tx_if.frame_start）时
//       next_tx[vl] <= cycle_count + bag_cycles[vl]，随后清 inflight。
//     BAG 以线上MAC帧起始周期计，截止点使用整周期。PREPARE_CYCLES=0保持旧到期入选；
//     PHY可提前准备，但frame_permit仍按队头原截止点判定，MAC必须据此门控起帧。
//     若入选时 age ≥ bag_cycles（错过整整一个 BAG 槽：配置超额或饿死）→ bag_viol 脉冲 + bag_ovf_cnt。
//   * 在途帧按 GO 顺序入 16 深队列，frame_start / builder len_err（帧未生成）各弹出一项。
//   * sch_take 后若 5 拍内无 sch_ack（消息已被取空），放弃本轮重扫（take_miss_cnt）。
//   * 配置: cfg_we 写 {valid, bag_us, port}，写入时 next_tx <= cycle_count（立即到期）；
//     valid=0 写入即停用。复位只清 valid/inflight 位图（阵列内容无需清零）。
//     cfg_we 与 frame_start 同拍时 cfg 优先（CFG_MODE=1 期间不应有帧在途）。
//   * BAG-only updates (BAG_UPDATE_EN=1) preserve valid/port and rebase the
//     next deadline to commit_time + new_BAG in clk cycles. Top suppresses new grants
//     while SET owns configuration; already-granted
//     frames finish normally. A later frame_start re-bases from the actual start
//     using the new BAG, so link-down cannot hold the SET indefinitely.
//   * 单构建器: 以 builder busy 为唯一互斥条件（发送侧 FIFO 由 mac_tx_if 背压）。
// 时钟/复位: clk(125 MHz) / rst_sync；握手 vld/pulse（§10）
// 资源: 8 路 32 bit 年龄比较 + 128×71 bit 时戳阵列。
// =====================================================================
`timescale 1 ns / 1 ps
module tx_vl_scheduler #(
  parameter integer NUM_TX_VL = 128,
  parameter integer NUM_PORTS = 256,
  parameter integer CYCLES_PER_US = 125,
  parameter integer BAG_UPDATE_EN = 0,
  // Prepare near-deadline frames ahead of time; the MAC must consume
  // frame_permit only in its idle-to-frame transition when this is nonzero.
  parameter integer PREPARE_CYCLES = 0
) (
  input  wire                  clk,
  input  wire                  rst_sync,
  input  wire                  enable,         // TX_EN 与 INIT_DONE 门控；已有在途握手仍收尾
  input  wire [23:0]           tb_us,          // legacy monitor input; BAG deadlines use cycle_count
  // ---- 配置写口（host_if，CFG_MODE=1）----
  input  wire                  cfg_we,
  input  wire [6:0]            cfg_vl,
  input  wire                  cfg_valid,
  input  wire [23:0]           cfg_bag_us,
  input  wire [7:0]            cfg_port,       // port_base（P0: 1 端口/VL）
  // Optional BAG-only commit. Top pauses new grants while SET is active.
  input  wire                  cfg_bag_only,
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
  output wire                  frame_permit,    // head frame reached its original BAG deadline
  // ---- 自检/统计 ----
  output reg                   bag_viol,       // 1 拍
  output reg  [15:0]           bag_ovf_cnt,
  output reg  [15:0]           take_miss_cnt,  // take 无 ack 次数
  output wire [7:0]            vl_valid_cnt,   // 有效 VL 数（调试）
  // ST_HOLD 与 ST_GO：顶层 TX 表读口切到 start_vl。start_vld 在 GO 拍拉高，
  // 构建器下一拍采样；GO 拍必须仍读该 VL，否则会被 host_addr 算出的 budget_vl 污染。
  output wire                  start_cfg_rd
);
  // ---------------- 存储阵列 ----------------
  reg [31:0] next_tx [0:NUM_TX_VL-1];
  reg [30:0] bag_arr [0:NUM_TX_VL-1];
  reg [7:0]  port_arr[0:NUM_TX_VL-1];
  // eLinx does not accept a packed-vector dynamic bit select such as
  // port_ready[port_arr[scan_addr]]. Mirror the fixed-width input into an
  // unpacked array; dynamic reads of the existing register arrays are
  // supported by the frontend and preserve the same hardware function.
  wire       port_ready_by_num [0:NUM_PORTS-1];
  genvar     port_ready_g;
  generate
    for (port_ready_g = 0; port_ready_g < NUM_PORTS; port_ready_g = port_ready_g + 1) begin : g_port_ready_by_num
      assign port_ready_by_num[port_ready_g] = port_ready[port_ready_g];
    end
  endgenerate
  reg [NUM_TX_VL-1:0] valid_map;
  reg [NUM_TX_VL-1:0] inflight;

  // BAG deadlines use exact clk cycles. With a 32-bit modulo counter,
  // every supported BAG stays below the half-range used by age[31].
  reg [31:0] cycle_count;
  always @(posedge clk) begin
    if (rst_sync) cycle_count <= 32'd0;
    else          cycle_count <= cycle_count + 32'd1;
  end
  wire [31:0] cfg_bag_cycles = {8'd0, cfg_bag_us} * CYCLES_PER_US;

  // ---------------- 状态 ----------------
  localparam [1:0] ST_SCAN = 2'd0;   // 8 路并行分组扫描，一轮 16 拍
  localparam [1:0] ST_TAKE = 2'd1;   // 已发 sch_take，等 ack（最多 5 拍）
  localparam [1:0] ST_HOLD = 2'd3;   // ack 后多一拍，给 posedge BRAM 读出 VL 表
  localparam [1:0] ST_GO   = 2'd2;   // 发 start_vld、置 inflight
  reg [1:0] st;

  localparam integer SCAN_LANES = 8;
  localparam integer SCAN_GROUPS = (NUM_TX_VL + SCAN_LANES - 1) / SCAN_LANES;
  reg [3:0] group_idx;

  // 本轮最佳候选
  reg        best_vld;
  reg [6:0]  best_vl;
  reg [7:0]  best_port;
  reg [31:0] best_age;
  reg [30:0] best_bag;

  // 每拍并行比较一个 8-VL 分组；一轮结束时仍选 age 最大的最早到期项。
  reg         scan_best_vld;
  reg [6:0]   scan_best_vl;
  reg [7:0]   scan_best_port;
  reg [31:0]  scan_best_age;
  reg [30:0]  scan_best_bag;
  integer     scan_lane;
  integer     scan_addr;
  reg [31:0]  scan_age;
  always @(*) begin
    scan_best_vld  = 1'b0;
    scan_best_vl   = 7'd0;
    scan_best_port = 8'd0;
    scan_best_age  = 32'd0;
    scan_best_bag  = 31'd0;
    scan_addr      = 0;
    scan_age       = 32'd0;
    for (scan_lane = 0; scan_lane < SCAN_LANES; scan_lane = scan_lane + 1) begin
      scan_addr = (group_idx * SCAN_LANES) + scan_lane;
      if (scan_addr < NUM_TX_VL) begin
        scan_age = cycle_count + PREPARE_CYCLES - next_tx[scan_addr];
        if (valid_map[scan_addr] && !inflight[scan_addr] &&
            port_ready_by_num[port_arr[scan_addr]] && !scan_age[31] &&
            (!scan_best_vld || scan_age > scan_best_age)) begin
          scan_best_vld  = 1'b1;
          scan_best_vl   = scan_addr[6:0];
          scan_best_port = port_arr[scan_addr];
          scan_best_age  = scan_age;
          scan_best_bag  = bag_arr[scan_addr];
        end
      end
    end
  end
  wire        better = scan_best_vld & (~best_vld | (scan_best_age > best_age));
  wire        last_of_round = (group_idx == SCAN_GROUPS - 1);

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
  assign start_cfg_rd = (st == ST_HOLD) || (st == ST_GO);

  // ---------------- 在途队列（GO 入队；frame_start / len_err 出队）----------------
  reg [6:0] ifq [0:15];        // 深 16：FIFO 内可同时在途多帧（GMII 512 B FIFO 约 8 帧）
  reg [3:0] ifq_wr, ifq_rd;
  wire      ifq_nonempty = (ifq_wr != ifq_rd);
  wire      pop = ifq_nonempty & (frame_start | builder_len_err);
  wire [6:0] pop_vl = ifq[ifq_rd];
  wire [31:0] head_age = cycle_count - next_tx[pop_vl];
  // Keep the eligibility deadline unmodified. Preparing early never grants
  // permission to send early, including after a BAG-only configuration commit.
  assign frame_permit = (PREPARE_CYCLES == 0) ? 1'b1 :
                         (ifq_nonempty && !head_age[31]);
  wire      go_wr = (st == ST_GO);
  wire      bag_only = (BAG_UPDATE_EN != 0) && cfg_bag_only;
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
      next_tx[cfg_vl]  <= bag_only ? cycle_count + cfg_bag_cycles : cycle_count;
      bag_arr[cfg_vl]  <= cfg_bag_cycles[30:0];
      if (!bag_only) port_arr[cfg_vl] <= cfg_port;
    end else if (pop) begin
      next_tx[pop_vl]  <= cycle_count + {1'b0, bag_arr[pop_vl]};
    end
  end
  always @(posedge clk) begin
    if (rst_sync) begin
      valid_map <= {NUM_TX_VL{1'b0}}; inflight <= {NUM_TX_VL{1'b0}};
    end else begin
      if (cfg_we && !bag_only) valid_map[cfg_vl] <= cfg_valid;
      if (go_wr)  inflight[go_vl]   <= 1'b1;
      if (pop)    inflight[pop_vl]  <= 1'b0;
    end
  end

  // ---------------- 主 FSM ----------------
  always @(posedge clk) begin
    if (rst_sync) begin
      st <= ST_SCAN; group_idx <= 4'd0;
      best_vld <= 1'b0; best_vl <= 7'd0; best_port <= 8'd0; best_age <= 32'd0; best_bag <= 31'd0;
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
          group_idx <= 4'd0; best_vld <= 1'b0;
        end else begin
          if (last_of_round) group_idx <= 4'd0;
          else               group_idx <= group_idx + 4'd1;
          if (better) begin
            best_vld <= 1'b1; best_vl <= scan_best_vl; best_port <= scan_best_port;
            best_age <= scan_best_age; best_bag <= scan_best_bag;
          end
          if (last_of_round) begin
            best_vld <= 1'b0;
            if ((best_vld | scan_best_vld) && !builder_busy && enable) begin
              // Last group may contain a better candidate than all prior groups.
              go_vl    <= better ? scan_best_vl : best_vl;
              go_viol  <= better ? (scan_best_age >= {1'b0,scan_best_bag} + PREPARE_CYCLES) :
                                  (best_age >= {1'b0,best_bag} + PREPARE_CYCLES);
              sch_take <= 1'b1;
              sch_port <= better ? scan_best_port : best_port;
              ack_wait <= 3'd0; group_idx <= 4'd0;
              st <= ST_TAKE;
            end
          end
        end
        ST_TAKE: begin
          if (sch_ack) begin
            start_vl <= {1'b0, go_vl}; start_blk <= sch_blk; start_len <= sch_len;
            st <= ST_HOLD;
          end else if (ack_wait == 3'd5) begin
            take_miss_cnt <= take_miss_cnt + 16'd1;
            st <= ST_SCAN;
          end else begin
            ack_wait <= ack_wait + 3'd1;
          end
        end
        ST_HOLD: st <= ST_GO;
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
