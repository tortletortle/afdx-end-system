// =====================================================================
// rtc_sync.v —— RTC 同步（PPS 对齐 / 同步报文对时 / SYNC_LOSS）
// 设计书: §7.15。continue4 实现（原第 0 周空壳）。
// 口径：
//   - 本模块不复制时基，只维护一个 64 bit 偏移量 offset，
//     rtc_time_us = rtc_free_us + offset（timebase 仍是唯一 μs 源）。
//   - sec_phase 是"距本地整秒的 μs 数"，由 tick_us 推进，US_PER_SEC 回绕；
//     pps_out 在回绕拍拉高一拍。仿真可把 US_PER_SEC 缩小以加速。
//   - PPS 上升沿给出相位误差 err（有符号，单位 μs）：
//       |err| >  TH_JUMP  → 直接跳变（offset -= err，sec_phase 清零）
//       |err| <= TH_JUMP  → 平滑（offset -= err>>>LOG2_AVG，相位同量修正）
//   - 同步报文（§7.15 SYNC_VL 采样口）误差 = rtc_time - (master_ts + path_est)。
//   - 连续 SYNC_TIMEOUT μs 无 PPS 且无报文 → SYNC_LOSS=1，停止平滑只自由运行。
// 边界（如实标注）：分辨率就是 1 μs，locked 的含义是"连续 LOCK_N 次 |err|<=1"，
//   不宣称亚微秒；未做 PPS 输入的 CDC 签核（只有 3 拍打拍同步器）。
// =====================================================================
`timescale 1 ns / 1 ps
module rtc_sync #(
  parameter integer US_PER_SEC   = 1000000,
  parameter integer SYNC_TIMEOUT = 4000,
  parameter integer LOCK_N       = 3
)(
  input  wire        clk,
  input  wire        rst_sync,
  input  wire        en,
  input  wire        hold,
  input  wire        tick_us,
  input  wire [63:0] rtc_free_us,
  input  wire        pps_in,
  input  wire        sync_vld,
  input  wire [63:0] sync_master_ts,
  input  wire [15:0] path_est_us,
  input  wire [7:0]  th_jump_us,
  input  wire [3:0]  log2_avg,
  output wire [63:0] rtc_time_us,
  output reg         pps_out,
  output reg         sync_loss,
  output reg         locked,
  output reg  [31:0] last_err_us,
  output reg  [31:0] jump_cnt,
  output reg  [31:0] step_cnt,
  output reg  [31:0] pps_cnt,
  output reg  [31:0] sec_phase
);
  localparam [31:0] SEC_MAX  = US_PER_SEC - 1;
  localparam [31:0] SEC_HALF = US_PER_SEC / 2;

  reg  [63:0] offset;
  // continue4 目标 B（结构性打拍）：post-map STA 把 sec_phase[22] -> offset[63]
  // 认定为全局关键路径（-18.569 ns）。原来一拍里要串完
  //   sec_phase → 33 bit 有符号相减 → 取绝对值 → 与 TH_JUMP 比较 →
  //   变量算术右移(桶形移位器) → 64 bit 减法
  // 现在把"求误差"和"用误差改 offset/相位"拆成两拍：误差在 PPS/报文事件当拍
  // 锁进 err_q，下一拍才去动 offset 与 sec_phase。判决语义不变，只晚一个时钟。
  reg signed [32:0] err_q;
  reg         disc_pend, disc_q_pps;
  reg  [2:0]  pps_q;
  reg  [31:0] idle_us;
  reg  [3:0]  lock_run;
  assign rtc_time_us = rtc_free_us + offset;

  wire pps_rise = pps_q[1] & ~pps_q[2];

  // ---- PPS 相位误差（有符号 33 bit）----
  wire signed [32:0] phase_s = {1'b0, sec_phase};
  wire signed [32:0] err_pps = (sec_phase < SEC_HALF) ? phase_s
                                                      : (phase_s - $signed({1'b0, US_PER_SEC[31:0]}));
  // ---- 报文误差：rtc_time - (master + path_est)，取低 33 bit 有符号 ----
  wire [63:0] want_ts  = sync_master_ts + {48'd0, path_est_us};
  wire [63:0] diff_ts  = rtc_time_us - want_ts;
  wire signed [32:0] err_msg = $signed(diff_ts[32:0]);

  wire disc_pps = en && pps_rise;
  wire disc_msg = en && sync_vld;
  wire signed [32:0] err_new = disc_pps ? err_pps : err_msg;   // 第 1 拍：只求误差
  wire signed [32:0] err_now = err_q;                          // 第 2 拍：用锁存值
  wire signed [32:0] err_abs = (err_now < 0) ? -err_now : err_now;
  wire big_jump = (err_abs > $signed({25'd0, th_jump_us}));
  wire signed [32:0] adj = big_jump ? err_now : (err_now >>> log2_avg);

  // 相位修正后按 US_PER_SEC 取模（只可能偏出一圈）
  wire signed [33:0] phase_adj = $signed({1'b0, phase_s}) - {adj[32], adj};
  wire signed [33:0] phase_wrapped =
       (phase_adj < 0)                                  ? (phase_adj + $signed({2'd0, US_PER_SEC[31:0]})) :
       (phase_adj >= $signed({2'd0, US_PER_SEC[31:0]})) ? (phase_adj - $signed({2'd0, US_PER_SEC[31:0]})) :
                                                          phase_adj;

  always @(posedge clk) begin
    if (rst_sync) begin
      offset <= 64'd0; pps_q <= 3'd0; sec_phase <= 32'd0; pps_out <= 1'b0;
      sync_loss <= 1'b0; locked <= 1'b0; last_err_us <= 32'd0;
      jump_cnt <= 32'd0; step_cnt <= 32'd0; pps_cnt <= 32'd0;
      idle_us <= 32'd0; lock_run <= 4'd0;
      err_q <= 33'sd0; disc_pend <= 1'b0; disc_q_pps <= 1'b0;
    end else begin
      pps_q <= {pps_q[1:0], pps_in};
      pps_out <= 1'b0;
      disc_pend <= 1'b0;
      if (disc_pps || disc_msg) begin      // 第 1 拍：锁存误差与事件类型
        err_q      <= err_new;
        disc_q_pps <= disc_pps;
        disc_pend  <= 1'b1;
      end

      // ---- 本地秒相位推进 ----
      if (tick_us && !hold) begin
        if (sec_phase >= SEC_MAX) begin
          sec_phase <= 32'd0;
          pps_out   <= 1'b1;
          pps_cnt   <= pps_cnt + 32'd1;
        end else begin
          sec_phase <= sec_phase + 32'd1;
        end
      end

      // ---- 失步看门狗 ----
      if (pps_rise || sync_vld) begin
        idle_us   <= 32'd0;
        sync_loss <= 1'b0;
      end else if (tick_us) begin
        if (idle_us >= SYNC_TIMEOUT[31:0]) sync_loss <= 1'b1;
        else                               idle_us   <= idle_us + 32'd1;
      end

      // ---- 第 2 拍：对时判决（PPS 优先于报文；SYNC_LOSS 下只允许跳变重捕）----
      if (disc_pend) begin
        last_err_us <= err_now[31:0];
        if (big_jump) begin
          offset   <= offset - {{31{err_now[32]}}, err_now};
          jump_cnt <= jump_cnt + 32'd1;
          lock_run <= 4'd0;
          locked   <= 1'b0;
          if (disc_q_pps) sec_phase <= 32'd0;
        end else if (!sync_loss) begin
          offset   <= offset - {{31{adj[32]}}, adj};
          step_cnt <= step_cnt + 32'd1;
          if (disc_q_pps) sec_phase <= phase_wrapped[31:0];
          if (err_abs <= 33'sd1) begin
            if (lock_run >= LOCK_N[3:0]) locked <= 1'b1;
            else                          lock_run <= lock_run + 4'd1;
          end else begin
            lock_run <= 4'd0;
            locked   <= 1'b0;
          end
        end
      end
    end
  end
endmodule
