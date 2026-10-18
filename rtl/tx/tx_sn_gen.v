// =====================================================================
// tx_sn_gen.v —— 每 VL 的 8 位 SN 存储与回绕（255→1，复位 0）
// 设计书: §6.6（SN 规则）/ §7.4（接口与算法）/ §3.4（模块清单，估 90 行）
// 功能:
//   - 128 × 8 bit 寄存器阵列 sn_cur[vl]，复位后全 0（"从未发过"）。
//   - 申请（snap_req/snap_vl → snap/snap_ack）: 返回 sn_tx =
//       (sn_cur==0) ? 1 : sn_cur ——复位后首帧发 1，永不发 0（§6.6）。
//   - 提交（commit，接 mac_tx_if.frame_done）: 只在帧真正送完后才把
//       sn_cur[vl] <= sn_next(snap) = (snap==255) ? 1 : snap+1，
//       被丢弃/覆盖的帧不浪费 SN（A664P7"发送成功才递增"）。
//   - init_all: 1 拍脉冲，全部 sn_cur 清 0（等价复位语义，供 CTL 软复位）。
//   - host_override: ovr_we/ovr_vl/ovr_val 直接改写 sn_cur[vl]（调试注入，
//       配合 T09 SN 跳变；仅 DEBUG_EN 下由 host_if 使能）。
//   - sn_pend[1:0]: 未提交的 snap 数（0/1，2 = 溢出饱和）。构建器保证
//       串行，pend 期间再次 snap_req 属协议违规 → err 脉冲（§7.4 防御性检查），
//       但仍按新申请服务（不死锁）。
// 时序: snap_req 拍采样 → 下一拍 snap_ack=1 且 snap 有效（1 拍延迟，
//   与 bram_sdp/描述符读延迟对齐）。commit 与 snap_req 同拍时先提交后申请
//   （申请读到的是提交后的新值——同 VL 连发时序正确）。
// 时钟/复位: clk(125 MHz) / rst_sync(§4.2 同步高有效)；握手 pulse（§10）。
// 依赖表项: 无寄存器直读；host_override 由 host_if 经 DEBUG_EN 门控。
// 已知限制: 单 pend 槽，双网 A/B 的 frame_done 由 tx_rm 对齐为一拍（§7.5）。
// =====================================================================
`timescale 1 ns / 1 ps
module tx_sn_gen #(
  parameter integer NUM_TX_VL = 128           // §4.3
) (
  input  wire        clk,
  input  wire        rst_sync,
  // ---- 申请（来自 tx_frame_builder HDR_INIT）----
  input  wire        snap_req,
  input  wire [7:0]  snap_vl,
  output reg  [7:0]  snap,
  output reg         snap_ack,
  // ---- 提交（来自 mac_tx_if.frame_done，经 tx_rm 对齐）----
  // Cancel a failed staged fragment's snapshot without consuming an SN.
  // commit_vl also identifies the cancel owner. Cancel wins over commit;
  // a same-edge new snapshot is accepted after cancellation.
  input  wire        cancel,
  input  wire        commit,
  input  wire [7:0]  commit_vl,
  // ---- 控制/调试 ----
  input  wire        init_all,
  input  wire        ovr_we,
  input  wire [7:0]  ovr_vl,
  input  wire [7:0]  ovr_val,
  output reg  [1:0]  sn_pend,
  output reg         err
);
  localparam [7:0] SN_MAX   = 8'd255;   // §6.6: 255 之后回 1
  localparam [7:0] SN_FIRST = 8'd1;     // §6.6: 永不使用 0
  localparam [7:0] SN_RST   = 8'd0;

  reg [7:0] sn_cur [0:NUM_TX_VL-1];

  // ---- 挂起槽：snap 后、commit 前暂存本次申请的 SN 与 VL ----
  reg [7:0] pend_vl;
  reg [7:0] pend_val;

  // 申请当拍读出的现值（同拍 commit 优先旁路，保证同 VL 连发拿到新值）
  wire [7:0] cur_raw  = sn_cur[snap_vl];
  wire [7:0] next_val = (pend_val == SN_MAX) ? SN_FIRST : (pend_val + 8'd1);
  wire       cancel_hit = cancel && (sn_pend != 2'd0) && (commit_vl == pend_vl);
  wire       commit_hit = commit && !cancel_hit && (sn_pend != 2'd0) && (commit_vl == pend_vl);
  wire [7:0] cur_eff  = (commit_hit && (commit_vl == snap_vl)) ? next_val : cur_raw;
  wire [7:0] sn_tx    = (cur_eff == SN_RST) ? SN_FIRST : cur_eff;

  // ---- 存储更新：init_all > ovr_we > commit ----
  // 寄存器阵列按 VL 展开（generate）：可全体同步清零（§6.6 复位 0），
  // 且避开 Verilator 5.006 不支持的 "for 循环内非阻塞写数组"（BLKLOOPINIT）。
  genvar g;
  generate
    for (g = 0; g < NUM_TX_VL; g = g + 1) begin : g_sn
      always @(posedge clk) begin
        if (rst_sync || init_all)
          sn_cur[g] <= SN_RST;
        else if (ovr_we && (ovr_vl == g[7:0]))
          sn_cur[g] <= ovr_val;
        else if (commit_hit && (pend_vl == g[7:0]))
          sn_cur[g] <= next_val;
      end
    end
  endgenerate

  // ---- 申请/挂起/错误 ----
  always @(posedge clk) begin
    if (rst_sync) begin
      snap      <= 8'd0;
      snap_ack  <= 1'b0;
      sn_pend   <= 2'd0;
      pend_vl   <= 8'd0;
      pend_val  <= 8'd0;
      err       <= 1'b0;
    end else if (init_all) begin
      snap_ack <= 1'b0;
      sn_pend  <= 2'd0;              // 软复位：挂起一并作废
      err      <= 1'b0;
    end else begin
      snap_ack <= snap_req;
      err      <= 1'b0;
      if (snap_req) begin
        snap     <= sn_tx;
        pend_vl  <= snap_vl;
        pend_val <= sn_tx;
        // 违规: 上一次申请尚未提交（且本拍不是在提交它）
        if (sn_pend != 2'd0 && !commit_hit && !cancel_hit) begin
          err     <= 1'b1;
          sn_pend <= (sn_pend == 2'd3) ? 2'd3 : (sn_pend + 2'd1);
        end else begin
          sn_pend <= 2'd1;
        end
      end else if (cancel_hit) begin
        sn_pend <= 2'd0;
      end else if (commit_hit) begin
        sn_pend <= sn_pend - 2'd1;
      end else if (commit || cancel) begin
        err <= 1'b1;        // 无挂起或 VL 不匹配的 commit（防御性）
      end
    end
  end
endmodule
