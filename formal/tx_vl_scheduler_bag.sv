// =============================================================================
// tx_vl_scheduler_bag.sv — BAG 间隔不变式（SVA / formal bind）
//
// 待 tx_vl_scheduler 时序刀定稿后对最终版运行；本文件按当前接口信号编写，
// 若 FSM 改动需同步。
//
// 命题（项目语言）：
//   同一 VL 的两次 frame_start 之间，cycle_count 增量 ≥ 该 VL 的 bag_arr[vl]。
//
// 相关 DUT 信号（rtl/tx/tx_vl_scheduler.v，以定稿后行为准）：
//   cycle_count  — 自由计数器（posedge clk 自增）
//   bag_arr[vl]  — 该 VL 的 BAG 周期数（cfg 写入；30 bit）
//   next_tx[vl]  — 下次允许到期点（pop 后写 cycle + bag）
//   frame_start  — 线上 MAC 帧起始（A 路）
//   ifq / pop    — GO 入队；frame_start | builder_len_err 出队
//   go_vl        — GO 拍入队的 VL
//
// 断言思路：
//   仅在「frame_start 且 ifq 非空」时锚定 VL（= pop 且非纯 len_err 路径）。
//   记录该 VL 上次锚定的 cycle_count；下次再锚定时断言差值 ≥ bag_arr[vl]
//  （取当前拍 bag_arr[pop_vl]；若中间 cfg 改 BAG，语义见文末边界）。
//
// 本文件只写、不跑证明。对旧版或改到一半的 RTL 跑 formal 结论作废。
// =============================================================================

`timescale 1 ns / 1 ps

module tx_vl_scheduler_bag_props #(
  parameter integer NUM_TX_VL = 128
) (
  input  wire        clk,
  input  wire        rst_sync,
  input  wire        frame_start,
  input  wire        builder_len_err,
  input  wire        ifq_nonempty,
  input  wire        pop,
  input  wire [6:0]  pop_vl,
  input  wire [31:0] cycle_count,
  input  wire [30:0] bag_now   // = bag_arr[pop_vl]，在 bind 端口表于 DUT 作用域求值
);

  // frame_start 触发的出队才计入 BAG 锚点；纯 builder_len_err 出队不更新锚点。
  wire bag_anchor = frame_start && ifq_nonempty && pop;

  reg        seen     [0:NUM_TX_VL-1];
  reg [31:0] last_cyc [0:NUM_TX_VL-1];
  integer    i;

  always @(posedge clk) begin
    if (rst_sync) begin
      for (i = 0; i < NUM_TX_VL; i = i + 1) begin
        seen[i]     <= 1'b0;
        last_cyc[i] <= 32'd0;
      end
    end else if (bag_anchor) begin
      // 第二次及以后起帧：差值须 ≥ 当前 bag_arr[vl]
      if (seen[pop_vl]) begin
        // cycle_count 为自由计数；BAG ≪ 2^31，无符号减法足够
        assert ((cycle_count - last_cyc[pop_vl]) >= {1'b0, bag_now})
          else $error("BAG interval violated: VL=%0d delta=%0d bag=%0d",
                      pop_vl, (cycle_count - last_cyc[pop_vl]), bag_now);
      end
      last_cyc[pop_vl] <= cycle_count;
      seen[pop_vl]     <= 1'b1;
    end
  end

  // ---------------------------------------------------------------------------
  // 边界（跑证明前必须写成 assume / 文档门口，本文件不宣称已处理）：
  // 1) bag_arr 在两次 frame_start 之间被 cfg 改写时，用「当前 bag_now」与 RTL
  //    「上次 pop 锁存的 pop_bag_r」可能不一致；定稿后按需改成锁存上次 bag。
  // 2) 未对 NUM_TX_VL=128 全量同时证明；可先缩配 NUM_TX_VL 或单 VL 切片。
  // 3) 不证明 WCTT / 端到端 2 ms / 抖动合规；只证明本模块 BAG 周期间隔下界。
  // ---------------------------------------------------------------------------

endmodule

// bind：端口连接表达式在 tx_vl_scheduler 实例作用域求值。
// 若时序刀改名 ifq_nonempty / pop / pop_vl / bag_arr，须同步本 bind。
bind tx_vl_scheduler tx_vl_scheduler_bag_props #(
  .NUM_TX_VL(NUM_TX_VL)
) u_bag_props (
  .clk           (clk),
  .rst_sync      (rst_sync),
  .frame_start   (frame_start),
  .builder_len_err(builder_len_err),
  .ifq_nonempty  (ifq_nonempty),
  .pop           (pop),
  .pop_vl        (pop_vl),
  .cycle_count   (cycle_count),
  .bag_now       (bag_arr[pop_vl])
);
