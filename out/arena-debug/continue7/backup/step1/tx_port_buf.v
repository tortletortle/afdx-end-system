// =====================================================================
// tx_port_buf.v —— 端口缓冲与消息描述符、写覆盖/入队规则（PMEM 块分配，§7.1）
// 设计书: §7.1（接口与算法）/ §8.6（PMEM 三池）/ §3.4（模块清单，估 320 行）
// 功能:
//   容纳主机提交的消息，向调度器提供 sch_req 位图（"该端口有数据"），
//   向帧构建器提供消息所在 PMEM 块号与字节数，管理 TX 池空闲块。
// 存储模型（§7.1 "统一按块分配"）:
//   - 主机不直接选块：本模块始终预留一个"开放块" wr_blk（从空闲位图分配），
//     主机把消息字节写到 PMEM 块基址 0x8800 + wr_blk×0x200，然后写
//     MSG_WR[port]（→ msg_commit + len）封口；封口后立即开一个新块。
//     wr_blk 无块可开时 wr_blk_vld=0，此时 commit 被拒并 pmem_exhaust +1。
//   - 描述符 desc[256]×28 bit = {valid, q_full, fresh, blk[3:0], len[12:0], age[7:0]}
//     （§7.1 字段），主机经 0x8180 只读；valid 位另有并行位图 sch_req。
//   - 队列端口不另设 per-port FIFO RAM：每条消息占一个块，队列 = 经
//     next[blk] 链起来的块链（头在 desc.blk，尾/计数在 qst[port]），
//     容量天然受块数上限约束，深度上限来自 port_depth（port_cfg.w3.depth）。
//   - 空闲块用 16 bit 位图（alloc = 最低位优先编码，free = 置位；同拍多路
//     释放只是按位或，无写冲突）。TX 池 = 块 TX_BLK_LO ~ +TX_BLK_N-1；
//     公共池借用（pmem_borrow）留第 4 周与 rx_port_buf 统一仲裁。
// 事件流水（每拍最多处理 1 个描述符事件，避免 desc 双写口）:
//   S0 采样事件（commit / take）并读 desc/qst → S1 计算并回写（含 S1→S0 旁路）。
//   commit 与 sch_take 同拍: commit 优先，take 挂起 1 拍（§7.1 T17 "pending 位"），
//   sch_ack 指示 take 实际完成、sch_blk/sch_len 有效。
// 端口类型（port_type，来自端口表 w0，由 host_if 随 commit 送入）:
//   0 采样: 单槽，覆盖旧消息（旧块立即回收、fresh=1、ovr_cnt+1）
//   1 队列 / 2 SAP: 先进先出，满则拒（q_ovf+1、commit_rej、q_full 位）
//   SAP 的来源保护在 host_if 译码（§7.1），本模块不区分 1/2。
// 时钟/复位: clk / rst_sync（§4.2）；握手 pulse（§10）。BRAM 类阵列不复位，
//   靠 valid 位图判定内容有效。
// 依赖表项: 端口表 w0.type / w3.depth（只读入）；STATUS.BUF_FULL 由 commit_rej
//   驱动；统计 ovr_cnt / q_ovf_cnt / pmem_exhaust_cnt 供 stats_regs。
// 已知限制: 一个 take 最多挂起 1 拍，调度器须在 sch_ack 前保持 sch_take 为 0。
// =====================================================================
`timescale 1 ns / 1 ps
module tx_port_buf #(
  parameter integer NUM_PORTS = 256,      // §4.3
  parameter integer TX_BLK_LO = 0,        // TX 池首块（§8.6: 0x8800 起）
  parameter integer TX_BLK_N  = 6         // TX 池块数（§8.6: 6 块）
) (
  input  wire                  clk,
  input  wire                  rst_sync,
  input  wire [7:0]            tb_us,        // 时基低 8 位 → age
  // ---- 主机侧（host_if）----
  input  wire                  msg_commit,   // 写 MSG_WR[port]，1 拍脉冲
  input  wire [7:0]            port_id,
  input  wire [15:0]           len,          // 字节数（有效 1~8191）
  input  wire [1:0]            port_type,    // 0 采样 / 1 队列 / 2 SAP
  input  wire [3:0]            port_depth,   // 队列深度 1~8（采样口忽略）
  output reg                   commit_rej,   // commit 后 2 拍: 拒写（队列满/无块）
  output wire [3:0]            wr_blk,       // 当前开放块号（主机写 PMEM 用）
  output wire                  wr_blk_vld,
  input  wire [7:0]            desc_rd_addr, // 描述符只读口（0x8180 + port）
  output reg  [31:0]           desc_rd_data, // 1 拍延迟
  // ---- 调度器 / 构建器侧 ----
  output wire [NUM_PORTS-1:0]  sch_req,      // 位图: 有待发消息
  output wire [NUM_PORTS-1:0]  buf_full,     // 位图: 队列端口满
  input  wire                  sch_take,     // 取走 port 的队头消息（1 拍脉冲）
  input  wire [7:0]            sch_port,
  output reg                   sch_ack,      // take 完成，sch_blk/sch_len 有效
  output reg  [3:0]            sch_blk,
  output reg  [12:0]           sch_len,
  input  wire                  blk_free,     // 构建器 frame_done 后归还块
  input  wire [3:0]            blk_free_id,
  // ---- 状态 / 统计 ----
  output reg  [15:0]           free_map,     // 空闲块位图（STATUS.PMEM_FREE 取 popcount）
  output reg  [15:0]           ovr_cnt,      // 采样口覆盖次数
  output reg  [15:0]           q_ovf_cnt,    // 队列口满拒写次数
  output reg  [15:0]           pmem_exhaust_cnt,
  output reg                   pending       // T17: commit/take 同拍，take 挂起中
);
  // ---- 描述符位域（§7.1）----
  localparam integer D_W      = 28;
  localparam integer B_VALID  = 27;
  localparam integer B_QFULL  = 26;
  localparam integer B_FRESH  = 25;
  localparam integer B_BLK_HI = 24, B_BLK_LO = 21;
  localparam integer B_LEN_HI = 20, B_LEN_LO = 8;
  localparam integer B_AGE_HI = 7,  B_AGE_LO = 0;
  localparam [1:0]   TYPE_SAMPLING = 2'd0;
  localparam [D_W-1:0] M_VALID = (28'h1 << B_VALID);
  localparam [D_W-1:0] M_QFULL = (28'h1 << B_QFULL);
  localparam [D_W-1:0] M_FRESH = (28'h1 << B_FRESH);

  // ---- 存储 ----
  reg [D_W-1:0] desc [0:NUM_PORTS-1];   // 描述符（不复位）
  reg [7:0]     qst  [0:NUM_PORTS-1];   // {tail[3:0], cnt[3:0]}（不复位）
  reg [12:0]    len_tab [0:15];         // 每块消息字节数（队列非队头项用）
  reg [3:0]     next_tab [0:15];        // 块链
  reg [NUM_PORTS-1:0] valid_map;        // = sch_req
  reg [NUM_PORTS-1:0] qfull_map;        // = buf_full
  reg [NUM_PORTS-1:0] smp_map;          // 端口是采样口（commit 时锁存，take 时用）
  assign sch_req  = valid_map;
  assign buf_full = qfull_map;

  // ---- TX 池初始位图 ----
  function [15:0] pool_mask;
    input integer lo; input integer n;
    integer k;
    begin
      pool_mask = 16'h0;
      for (k = 0; k < 16; k = k + 1)
        if (k >= lo && k < lo + n) pool_mask[k] = 1'b1;
    end
  endfunction
  localparam [15:0] TX_POOL = pool_mask(TX_BLK_LO, TX_BLK_N);

  // ---- 空闲块分配（最低位优先）----
  function [3:0] lowest_one;
    input [15:0] m;
    integer k;
    begin
      lowest_one = 4'd0;
      for (k = 15; k >= 0; k = k - 1)
        if (m[k]) lowest_one = k[3:0];
    end
  endfunction
  wire        any_free = |free_map;
  wire [3:0]  alloc_id = lowest_one(free_map);

  // 开放块
  reg  [3:0] open_blk;
  reg        open_vld;
  assign wr_blk     = open_blk;
  assign wr_blk_vld = open_vld;

  // =====================================================================
  // S0: 事件采样。commit 优先；take 与 commit 同拍则挂起 1 拍（pending）。
  // =====================================================================
  reg        tk_pend;
  reg  [7:0] tk_pend_port;
  wire       take_now = tk_pend | (sch_take & ~msg_commit);
  wire [7:0] take_port = tk_pend ? tk_pend_port : sch_port;
  // commit 本拍即可判定"无块可用"→ 拒（不进流水）
  wire       commit_go  = msg_commit & open_vld;
  wire       ev_commit  = commit_go;
  wire       ev_take    = take_now & ~commit_go;
  wire [7:0] ev_port    = ev_commit ? port_id : take_port;
  wire       ev_vld     = ev_commit | ev_take;

  // S0 读 + S1 旁路
  reg            s1_vld, s1_is_commit;
  reg  [7:0]     s1_port;
  reg  [D_W-1:0] s1_desc;
  reg  [7:0]     s1_qst;
  reg  [12:0]    s1_len;
  reg  [1:0]     s1_type;
  reg  [3:0]     s1_depth;
  reg  [3:0]     s1_blk;        // commit: 本次封口的开放块
  reg  [7:0]     s1_age;
  reg            s1_rej_now;   // commit 时无开放块（对齐到 S1 与 rej_q 同拍）
  // S1 回写值（组合，见下）
  reg  [D_W-1:0] wb_desc;
  reg  [7:0]     wb_qst;
  reg            wb_we;
  wire bypass = s1_vld & wb_we & (s1_port == ev_port);

  always @(posedge clk) begin
    if (rst_sync) begin
      s1_vld       <= 1'b0;
      s1_is_commit <= 1'b0;
      s1_port      <= 8'd0;
      s1_desc      <= {D_W{1'b0}};
      s1_qst       <= 8'd0;
      s1_len       <= 13'd0;
      s1_type      <= 2'd0;
      s1_depth     <= 4'd1;
      s1_blk       <= 4'd0;
      s1_age       <= 8'd0;
      s1_rej_now   <= 1'b0;
      tk_pend      <= 1'b0;
      tk_pend_port <= 8'd0;
      pending      <= 1'b0;
    end else begin
      s1_vld       <= ev_vld;
      s1_is_commit <= ev_commit;
      s1_port      <= ev_port;
      s1_desc      <= bypass ? wb_desc : desc[ev_port];
      s1_qst       <= bypass ? wb_qst  : qst[ev_port];
      s1_len       <= len[12:0];
      s1_type      <= port_type;
      s1_depth     <= (port_depth == 4'd0) ? 4'd1 : port_depth;
      s1_blk       <= open_blk;
      s1_age       <= tb_us;
      s1_rej_now   <= msg_commit & ~open_vld;
      // take 挂起: 与 commit 撞拍时记下，下一拍补做
      if (sch_take & msg_commit & ~tk_pend) begin
        tk_pend      <= 1'b1;
        tk_pend_port <= sch_port;
      end else if (tk_pend & ~commit_go) begin
        tk_pend      <= 1'b0;
      end
      pending <= sch_take & msg_commit;
    end
  end

  // =====================================================================
  // S1: 计算回写。一次只有一种事件，desc/qst 单写口。
  // =====================================================================
  // valid 取自可复位位图（desc/qst 阵列不复位，§4.2: 靠 valid 判定内容有效）
  wire        d_valid = valid_map[s1_port];
  wire [3:0]  d_blk   = s1_desc[B_BLK_HI:B_BLK_LO];
  wire [3:0]  q_tail  = s1_qst[7:4];
  wire [3:0]  q_cnt   = d_valid ? s1_qst[3:0] : 4'd0;
  // 类型: commit 用随 commit 送入的 port_type；take 用该端口锁存的类型
  wire        is_smp  = s1_is_commit ? (s1_type == TYPE_SAMPLING) : smp_map[s1_port];
  wire        q_is_full = (q_cnt >= s1_depth);
  wire [3:0]  q_cnt_inc = q_cnt + 4'd1;
  wire [3:0]  q_cnt_dec = q_cnt - 4'd1;
  wire [3:0]  d_next  = next_tab[d_blk];

  // 事件结果（组合）
  reg  free_old;            // 采样口覆盖 → 回收旧块
  reg  rej_q;               // 队列满拒写
  reg  accept;              // commit 被接受（封口、开新块）
  reg  set_valid, clr_valid, set_qfull, clr_qfull;
  reg  link_we;             // next_tab[q_tail] <= s1_blk
  reg  [3:0]  new_head;
  reg  [12:0] new_len;

  always @(*) begin
    wb_desc   = s1_desc;
    wb_qst    = s1_qst;
    wb_we     = 1'b0;
    free_old  = 1'b0;
    rej_q     = 1'b0;
    accept    = 1'b0;
    set_valid = 1'b0; clr_valid = 1'b0;
    set_qfull = 1'b0; clr_qfull = 1'b0;
    link_we   = 1'b0;
    new_head  = d_next;
    new_len   = len_tab[d_next];
    if (s1_vld && s1_is_commit) begin
      if (is_smp) begin
        // 采样口: 覆盖语义（§7.1）
        accept    = 1'b1;
        free_old  = d_valid;
        wb_we     = 1'b1;
        wb_desc   = {1'b1, 1'b0, d_valid, s1_blk, s1_len, s1_age};
        wb_qst    = {s1_blk, 4'd1};
        set_valid = 1'b1;
        clr_qfull = 1'b1;
      end else if (d_valid && q_is_full) begin
        rej_q     = 1'b1;
        wb_we     = 1'b1;
        wb_desc   = s1_desc | M_QFULL;
        set_qfull = 1'b1;
      end else if (!d_valid) begin
        // 空队列: 新消息即队头
        accept    = 1'b1;
        wb_we     = 1'b1;
        wb_desc   = {1'b1, (s1_depth == 4'd1), 1'b0, s1_blk, s1_len, s1_age};
        wb_qst    = {s1_blk, 4'd1};
        set_valid = 1'b1;
        if (s1_depth == 4'd1) set_qfull = 1'b1; else clr_qfull = 1'b1;
      end else begin
        // 非空队列: 挂到尾部
        accept    = 1'b1;
        link_we   = 1'b1;
        wb_we     = 1'b1;
        wb_desc   = s1_desc;
        wb_desc[B_QFULL] = (q_cnt_inc >= s1_depth);
        wb_qst    = {s1_blk, q_cnt_inc};
        if (q_cnt_inc >= s1_depth) set_qfull = 1'b1;
      end
    end else if (s1_vld) begin
      // take: 队头出队
      wb_we = 1'b1;
      if (!d_valid) begin
        wb_desc = s1_desc;                      // 空取: 无操作（防御）
      end else if (is_smp || q_cnt <= 4'd1) begin
        wb_desc = s1_desc & ~(M_VALID | M_FRESH | M_QFULL);
        wb_qst  = {q_tail, 4'd0};
        clr_valid = 1'b1;
        clr_qfull = 1'b1;
      end else begin
        wb_desc = s1_desc;
        wb_desc[B_QFULL]           = 1'b0;
        wb_desc[B_FRESH]           = 1'b0;
        wb_desc[B_BLK_HI:B_BLK_LO] = new_head;
        wb_desc[B_LEN_HI:B_LEN_LO] = new_len;
        wb_qst  = {q_tail, q_cnt_dec};
        clr_qfull = 1'b1;
      end
    end
  end

  // ---- 回写 desc / qst / 链表 / len_tab ----
  always @(posedge clk) begin
    if (wb_we) begin
      desc[s1_port] <= wb_desc;
      qst[s1_port]  <= wb_qst;
    end
  end
  always @(posedge clk) begin
    if (link_we) next_tab[q_tail] <= s1_blk;
  end
  always @(posedge clk) begin
    if (accept) len_tab[s1_blk] <= s1_len;
  end
  always @(posedge clk) begin
    if (rst_sync) begin
      valid_map <= {NUM_PORTS{1'b0}};
      qfull_map <= {NUM_PORTS{1'b0}};
      smp_map   <= {NUM_PORTS{1'b0}};
    end else begin
      if (s1_vld & s1_is_commit) smp_map[s1_port] <= (s1_type == TYPE_SAMPLING);
      if (set_valid) valid_map[s1_port] <= 1'b1;
      if (clr_valid) valid_map[s1_port] <= 1'b0;
      if (set_qfull) qfull_map[s1_port] <= 1'b1;
      if (clr_qfull) qfull_map[s1_port] <= 1'b0;
    end
  end

  // ---- take 结果输出 ----
  always @(posedge clk) begin
    if (rst_sync) begin
      sch_ack <= 1'b0;
      sch_blk <= 4'd0;
      sch_len <= 13'd0;
    end else begin
      sch_ack <= s1_vld & ~s1_is_commit & d_valid;
      sch_blk <= d_blk;
      sch_len <= s1_desc[B_LEN_HI:B_LEN_LO];
    end
  end

  // ---- 开放块与空闲位图 ----
  // 开放块在 S0 commit_go 当拍即被"占用"（s1_blk 记住），同拍开新块。
  // 释放来源: 构建器归还 / 采样口覆盖旧块 / 队列满拒写时退回已封口的块
  wire [15:0] free_set = ({16{blk_free}} & (16'h1 << blk_free_id))
                       | ({16{free_old}} & (16'h1 << d_blk))
                       | ({16{rej_q}}    & (16'h1 << s1_blk));
  wire        need_open = ~open_vld | commit_go;
  always @(posedge clk) begin
    if (rst_sync) begin
      free_map <= TX_POOL;
      open_blk <= 4'd0;
      open_vld <= 1'b0;
    end else begin
      if (need_open & any_free) begin
        open_blk <= alloc_id;
        open_vld <= 1'b1;
        free_map <= (free_map | free_set) & ~(16'h1 << alloc_id);
      end else begin
        if (need_open) open_vld <= 1'b0;
        free_map <= free_map | free_set;
      end
    end
  end

  // ---- 拒写与统计 ----
  always @(posedge clk) begin
    if (rst_sync) begin
      commit_rej       <= 1'b0;
      ovr_cnt          <= 16'd0;
      q_ovf_cnt        <= 16'd0;
      pmem_exhaust_cnt <= 16'd0;
    end else begin
      // 两种拒写统一在 commit 后 2 拍给出（与 sch_ack 同延迟；host_if 在 ack 拍采样）
      commit_rej <= rej_q | s1_rej_now;
      if (s1_rej_now && pmem_exhaust_cnt != 16'hFFFF) pmem_exhaust_cnt <= pmem_exhaust_cnt + 16'd1;
      if (rej_q   && q_ovf_cnt        != 16'hFFFF) q_ovf_cnt        <= q_ovf_cnt + 16'd1;
      if (free_old && ovr_cnt         != 16'hFFFF) ovr_cnt          <= ovr_cnt + 16'd1;
    end
  end

  // ---- 描述符主机只读口（§7.14 0x8180，1 拍延迟）----
  always @(posedge clk) begin
    desc_rd_data <= {4'h0, desc[desc_rd_addr]};
  end
endmodule
