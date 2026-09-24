// =====================================================================
// rx_rm.v —— RM 双网去重（§7.11），v0.5.15 接入 AFDX_top（IC 之后）
// 输入: IC 接受（或 IC_EN=0 时 FLT PASS）的单网判决描述符。A/B 两网在
//   lookup 入口已串行化成一条流，因此 §7.11 的 2 深 A/B 等待队列在本实现里
//   由 lookup 前的两个 rx_pmem_queue 承担：B 副本进入判决时一定已看到 A 副本
//   写回的 last_sn/last_ts（同 VL 逐项读—判—写回，不存在"同拍都 forward"）。
// 判决（每 VL 一个 33 bit 表项 {seen, last_ts[23:0], last_sn[7:0]}，附录 C RM_ST）:
//   active = CTL.RM_EN && w0.rm_en && w0.net_mode==2'b11
//   !active                                  -> forward，不读写表项
//   seen && sn==last_sn && |ts-last_ts|<=Skew -> drop_dup（表项不变）
//   sn==last_sn && |ts-last_ts|>Skew          -> forward + skew 事件（异常新帧）
//   其它                                      -> forward，写 {1,ts,sn}
//   Skew = 4<<skewmax_exp μs。时差取 24 bit 有符号绝对值：两网描述符在入口
//   可能按 A 优先而非时间序出队，后判的副本时间戳可能更早，单边差会把它
//   误当新帧（回绕 2^23 μs ≈ 8.4 s 远大于 SkewMax 上限 131 ms）。
// seen 位: 若只有 32 bit {ts,sn}，上电清零后的表项与"SN=0、ts≈0"的合法首帧
//   不可区分（SkewMax 大时会误删首帧），故表项加 1 bit 已见标志 [32]，随同一
//   RAM 字由 init_sweep T_RM 清零、forward 时置 1。4096×33 bit 需 9 个 4K×4
//   块（原 32 bit 为 8 个）；本实现串行化后不需要 §7.11 的 4096 bit pending
//   位图寄存器，净省 4096 FF。
// 存储纪律: 与 rx_ic 相同，init/debug/commit 三个写源复用同一物理写口并共用
//   读写地址，保证 eLinx 推断单块 BRAM。
// 时钟/复位: clk / rst_sync（§4.2）；out_vld 保持到 out_ready（无隐式丢弃）。
// =====================================================================
`timescale 1 ns / 1 ps
module rx_rm #(
  parameter integer DW = 163,     // RX 描述符位宽（v0.5.16 顶层用 174）
  parameter integer NUM_RX_VL = 4096
) (
  input  wire         clk,
  input  wire         rst_sync,
  input  wire         init_done,
  input  wire         init_we,
  input  wire [12:0]  init_addr,       // 0 .. NUM_RX_VL-1, from init_sweep T_RM
  input  wire         rm_glb_en,       // CTL.RM_EN (bit3)
  input  wire         in_vld,
  output wire         in_ready,
  input  wire [DW-1:0] in_desc,
  input  wire [11:0]  in_vl,
  input  wire         in_rm_en,        // RX_VL_CFG w0[30]
  input  wire [1:0]   in_net_mode,     // RX_VL_CFG w0[29:28]
  input  wire [3:0]   in_skew_exp,     // RX_VL_CFG w0[27:24]
  output reg          out_vld,
  input  wire         out_ready,
  output reg          out_fwd,         // 1 = forward, 0 = drop_dup
  output reg          out_skew,        // same SN beyond SkewMax (forwarded)
  output reg  [DW-1:0] out_desc,
  output reg  [11:0]  out_vl,
  input  wire         dbg_en,
  input  wire         dbg_wr,
  input  wire [11:0]  dbg_vl,
  input  wire [32:0]  dbg_data         // {seen, last_ts, last_sn}
);
  localparam [1:0] ST_IDLE=2'd0, ST_CMP=2'd1, ST_WRITE=2'd2, ST_OUT=2'd3;

  reg [32:0] rm_mem [0:NUM_RX_VL-1];
  reg [1:0]  state;
  reg [11:0] addr_q;
  reg [32:0] st_q;
  reg [23:0] ts_q, skew_q;
  reg [7:0]  sn_q;
  reg        active_q, fwd_q, skew_ev_q;

  wire vl_ok     = (in_vl < NUM_RX_VL);
  wire dbg_vl_ok = (dbg_vl < NUM_RX_VL);
  wire sweep_we  = !rst_sync && init_we && (init_addr < NUM_RX_VL);
  wire debug_we  = !rst_sync && !init_we && init_done && (state == ST_IDLE) &&
                   dbg_en && dbg_wr && dbg_vl_ok;
  wire commit_we = !rst_sync && !init_we && (state == ST_WRITE) &&
                   active_q && fwd_q;
  wire mem_we    = sweep_we || debug_we || commit_we;
  wire [11:0] wr_addr = sweep_we ? init_addr[11:0] : debug_we ? dbg_vl : addr_q;
  wire [32:0] wr_data = sweep_we ? 33'd0 : debug_we ? dbg_data : {1'b1, ts_q, sn_q};
  wire [11:0] mem_addr = mem_we ? wr_addr : vl_ok ? in_vl : 12'd0;
  always @(posedge clk) begin
    if (mem_we) rm_mem[mem_addr] <= wr_data;
    st_q <= rm_mem[mem_addr];
  end

  assign in_ready = !rst_sync && (state == ST_IDLE) && init_done && !init_we &&
                    !(dbg_en && dbg_wr);

  // 24 bit 有符号差的绝对值（见文件头）。
  wire [23:0] dts    = ts_q - st_q[31:8];
  wire [23:0] dts_ab = dts[23] ? (~dts + 24'd1) : dts;
  wire seen_q  = st_q[32];
  wire same_sn = (sn_q == st_q[7:0]);
  wire in_win  = (dts_ab <= skew_q);

  always @(posedge clk) begin
    if (rst_sync) begin
      state <= ST_IDLE; out_vld <= 1'b0; out_fwd <= 1'b0; out_skew <= 1'b0;
      out_desc <= {DW{1'b0}}; out_vl <= 12'd0; addr_q <= 12'd0; ts_q <= 24'd0;
      skew_q <= 24'd0; sn_q <= 8'd0; active_q <= 1'b0;
      fwd_q <= 1'b0; skew_ev_q <= 1'b0;
    end else if (init_we) begin
      state <= ST_IDLE; out_vld <= 1'b0;
    end else begin
      case (state)
        ST_IDLE: if (in_vld && in_ready) begin
          out_desc <= in_desc; out_vl <= in_vl;
          addr_q   <= in_vl;
          ts_q     <= in_desc[147:124];
          sn_q     <= in_desc[107:100];
          skew_q   <= 24'd4 << in_skew_exp;
          active_q <= vl_ok && rm_glb_en && in_rm_en && (in_net_mode == 2'b11);
          state    <= ST_CMP;
        end
        ST_CMP: begin
          fwd_q     <= !(active_q && seen_q && same_sn && in_win);
          skew_ev_q <= active_q && seen_q && same_sn && !in_win;
          state     <= ST_WRITE;
        end
        ST_WRITE: begin              // commit_we 在本拍写回
          out_fwd <= fwd_q; out_skew <= skew_ev_q; out_vld <= 1'b1;
          state <= ST_OUT;
        end
        ST_OUT: if (out_ready) begin
          out_vld <= 1'b0; state <= ST_IDLE;
        end
        default: state <= ST_IDLE;
      endcase
    end
  end
endmodule
