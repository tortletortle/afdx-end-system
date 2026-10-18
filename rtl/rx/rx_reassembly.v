// =====================================================================
// rx_reassembly.v —— IPv4 分片重组（P08）
//
// 位置：rx_rm forward 之后、rx_ip_udp_parse 之前。
// 输入/输出描述符位宽 DW（顶层 RXD_W=208），位域见顶层注释。
//
// 判定模型（位图法，RFC 791 语义）：
//   * 以 8 字节为一位粒度维护 1024 位「已到达」位图（覆盖 8192 字节）。
//   * 每片按 [start,end) 置位；若与已有位图相交 → 重叠 → 拒绝并作废上下文。
//   * 收到 MF=0 的末片后，检查 [0,end) 是否全 1：全 1 才交付，否则等后续片。
//   * TIMEOUT_TICKS>0 为可选工程回收计时；0 禁用计时，不按到达间隔丢弃。
//
// 交付描述符：
//   * 基底取末片描述符；plen=整消息总长；blk=首片块号；
//     vl/src/dst/sport/dport 取首片（UDP 头来自首片）。
//
// COPY_ENABLE=1 时，本模块通过 held-valid job/done 协议请求后续片负载拷贝，
//   并在失败/超时时通过 free_blk_valid 逐块归还仍由上下文持有的块。
//   * en=0 或 is_frag=0 时透传，不占用上下文。
// =====================================================================
`timescale 1 ns / 1 ps
module rx_reassembly #(
  parameter integer DW        = 208,
  parameter integer SLOTS     = 8,
  parameter integer MAX_BYTES = 8192,
  parameter integer TIMEOUT_TICKS = 250,
  parameter integer COPY_ENABLE = 0,
  parameter integer CHECK_ENABLE = 0,
  parameter integer MAX_FRAGS = 16,
  parameter integer PMEM_BLOCK_BYTES = 2048
) (
  input  wire          clk,
  input  wire          rst_sync,
  input  wire          en,
  input  wire          in_vld,
  output wire          in_ready,
  input  wire [DW-1:0] in_desc,
  input  wire [11:0]   in_vl,
  output reg           out_vld,
  input  wire          out_ready,
  output reg           out_drop,
  output reg  [3:0]    out_reason,
  output reg  [DW-1:0] out_desc,
  output reg  [11:0]   out_vl,
  output wire         copy_req_valid,
  input  wire         copy_req_ready,
  output wire [3:0]   copy_src_blk,
  output wire [12:0]  copy_src_byte,
  output wire [3:0]   copy_dst_blk,
  output wire [12:0]  copy_dst_byte,
  output wire [13:0]  copy_len,
  input  wire         copy_done,
  output wire         check_req_valid,
  input  wire         check_req_ready,
  output wire [3:0]   check_blk,
  output wire [13:0]  check_app_len,
  output wire [31:0]  check_src_ip,
  output wire [31:0]  check_dst_ip,
  input  wire         check_done,
  input  wire         check_good,
  input  wire [1:0]   check_reason,
  output reg          free_blk_valid,
  output reg  [3:0]   free_blk_id,
  output reg  [31:0]   hit_cnt,
  output reg  [31:0]   drop_cnt,
  output wire         drain_active,
  output wire [31:0]   slot_used
);
  // 位域必须与顶层 RXD_W=208 描述符布局严格一致（见 AFDX_top.v 的
  // rx_desc_in_a 拼接顺序）：
  //   [207:192] ident, [191] mf, [190] df, [189:177] frag_off(13b,8B 单位),
  //   [176] is_frag, [175] first_frag, [174] 保留,
  //   [173:163] plen, [162:159] blk, [158:148] len, [147:124] ts,
  //   [123:108] vlid, [107:100] sn, [99] net, [98:96] ifid,
  //   [95:64] src_ip, [63:32] dst_ip, [31:16] sport, [15:0] dport
  localparam integer B_BLK_HI=162, B_BLK_LO=159;
  localparam integer B_PLEN_HI=173, B_PLEN_LO=163;
  localparam integer B_SRC_HI=95,  B_SRC_LO=64;
  localparam integer B_DST_HI=63,  B_DST_LO=32;
  localparam integer B_SPORT_HI=31, B_SPORT_LO=16;
  localparam integer B_DPORT_HI=15, B_DPORT_LO=0;
  localparam integer B_IDENT_HI=207, B_IDENT_LO=192;
  localparam integer B_MF=191;
  localparam integer B_FOFF_HI=189, B_FOFF_LO=177;
  localparam integer B_ISFRAG=176;

  localparam [3:0] E_NONE=4'd0, E_ALIGN=4'd1, E_OVERSIZE=4'd2, E_SLOT=4'd3,
                   E_TIMEOUT=4'd4, E_OVERLAP=4'd5, E_GAP=4'd6, E_FRAGCNT=4'd7,
                   E_UDP_LEN=4'd8, E_UDP_CHECK=4'd9, E_CANCEL=4'd10;
  // 超时装载值：显式 16 bit 常量。避免直接对 integer 形参做位选
  // （TIMEOUT_TICKS[15:0]），部分工具会把 integer 位选求成 0，导致槽位
  // 装载后立刻被超时循环清掉（表现为第二次进入永远 hit=0）。
  localparam [15:0] TO_LOAD = TIMEOUT_TICKS[15:0];
  localparam integer FRAG_ENTRIES = SLOTS * MAX_FRAGS;

  (* mem2reg *) reg         slot_vld  [0:SLOTS-1];
  (* mem2reg *) reg [31:0]  slot_src  [0:SLOTS-1];
  (* mem2reg *) reg [31:0]  slot_dst  [0:SLOTS-1];
  (* mem2reg *) reg [15:0]  slot_ident[0:SLOTS-1];
  (* mem2reg *) reg [11:0]  slot_vl   [0:SLOTS-1];
  (* mem2reg *) reg [3:0]   slot_blk0 [0:SLOTS-1];
  (* mem2reg *) reg [15:0]  slot_sport[0:SLOTS-1];
  (* mem2reg *) reg [15:0]  slot_dport[0:SLOTS-1];
  (* mem2reg *) reg [15:0]  slot_timer[0:SLOTS-1];
  (* mem2reg *) reg [15:0]  slot_end  [0:SLOTS-1];   // 末片结束偏移（0=未见末片）
  (* mem2reg *) reg [7:0]   slot_frag [0:SLOTS-1];   // 已收片数
  (* mem2reg *) reg         slot_has_first [0:SLOTS-1];
  (* mem2reg *) reg [4:0]   slot_src_count [0:SLOTS-1];
  (* mem2reg *) reg         slot_releasing [0:SLOTS-1];
  (* mem2reg *) reg         slot_release_first_done [0:SLOTS-1];
  (* mem2reg *) reg [4:0]   slot_release_scan [0:SLOTS-1];
  (* mem2reg *) reg [3:0]   frag_src_blk [0:FRAG_ENTRIES-1];
  (* mem2reg *) reg [12:0]  frag_wire_off [0:FRAG_ENTRIES-1];
  (* mem2reg *) reg [10:0]  frag_app_len [0:FRAG_ENTRIES-1];
  (* mem2reg *) reg         frag_src_valid [0:FRAG_ENTRIES-1];
  // Coverage is represented as at most MAX_FRAGS disjoint byte intervals.
  // This preserves the 8192-byte protocol capacity without expanding a
  // 1024-bit bitmap into hundreds of dynamically selected registers.
  (* mem2reg *) reg [15:0]  frag_iv_start [0:FRAG_ENTRIES-1];
  (* mem2reg *) reg [15:0]  frag_iv_end   [0:FRAG_ENTRIES-1];
  (* mem2reg *) reg         frag_iv_valid [0:FRAG_ENTRIES-1];
  reg copy_busy;
  reg [2:0] copy_slot_q;
  reg [4:0] copy_frag_q;
  reg copy_free_pending;
  reg [3:0] copy_free_id;
  reg complete_pending;
  reg complete_check_busy, complete_checked;
  reg drain_pending;
  wire draining = (COPY_ENABLE != 0) && (!en || drain_pending);
  assign drain_active = draining;
  reg [2:0] complete_slot_q;
  reg [DW-1:0] complete_desc_q;
  reg [11:0] complete_vl_q;
  reg stray_free_pending;
  reg [3:0] stray_free_id;
  reg releasing_any;
  reg        prep_active;
  reg        prep_done;
  reg [1:0]  prep_phase;
  reg [4:0]  prep_pass_q;
  reg [4:0]  prep_scan_q;
  reg [4:0]  coverage_scan_q;
  reg [16:0] coverage_sum;
  reg [DW-1:0] prep_desc_q;
  reg [11:0]   prep_vl_q;
  localparam [1:0] PREP_MERGE = 2'd0, PREP_COVER_SCAN = 2'd1;
  wire [DW-1:0] work_desc = prep_active ? prep_desc_q : in_desc;
  wire [11:0]   work_vl = prep_active ? prep_vl_q : in_vl;
  wire [31:0] in_src   = work_desc[B_SRC_HI:B_SRC_LO];
  wire [31:0] in_dst   = work_desc[B_DST_HI:B_DST_LO];
  wire [15:0] in_ident = work_desc[B_IDENT_HI:B_IDENT_LO];
  wire        in_mf    = work_desc[B_MF];
  wire        in_isfr  = work_desc[B_ISFRAG];
  wire [12:0] in_foff  = work_desc[B_FOFF_HI:B_FOFF_LO];
  wire [10:0] in_plen  = work_desc[B_PLEN_HI:B_PLEN_LO];
  wire [15:0] in_foff_b = {in_foff, 3'b000};
  wire        in_is_first = (in_foff_b == 16'd0);
  // MAC metadata keeps the IPv4 wire offset, whose coordinate includes the
  // UDP header in fragment zero. Reassembly lengths are application bytes:
  // later-fragment app offset = IP offset - 8 (UDP header omitted on wire).
  wire [15:0] in_start_b = (in_isfr && !in_is_first) ? (in_foff_b - 16'd8) : in_foff_b;
  wire [16:0] in_end = {1'b0,in_start_b} + {6'd0,in_plen};

  // 注意：IPv4 头中 frag offset 字段的单位即为 8 字节，故「非 8 倍数」在协议层
  // 不可能出现（原始字节的非法对齐由 mac_rx_if 在接收时判 hdr_bad）；
  // 本模块不再重复该检查，保留 oversize 与重叠两项真实风险。
  wire copy_capacity_bad = (COPY_ENABLE != 0) && in_isfr &&
                           (in_end > (PMEM_BLOCK_BYTES - 42));
  wire over_bad  = (in_end > 17'd8192) || (in_end > MAX_BYTES[16:0]) ||
                   copy_capacity_bad;

  reg        hit;  reg [2:0] hit_idx;
  reg        free_found; reg [2:0] free_idx;
  // 循环变量必须按并发块独立声明：Verilog 里多个 always 块共用同一个 integer
  // 会产生仿真竞态（同一个变量被两个进程同时改写），表现为组合判决读到的索引
  // 时对时错（例如 ident 完全相同的第 2 片偶发判为未命中）。
  integer hi_i;
  always @* begin
    hit = 1'b0; hit_idx = 3'd0; free_found = 1'b0; free_idx = 3'd0;
    for (hi_i = SLOTS-1; hi_i >= 0; hi_i = hi_i - 1) begin
      if (slot_vld[hi_i] && (slot_ident[hi_i] == in_ident) &&
          (slot_src[hi_i] == in_src) && (slot_dst[hi_i] == in_dst) &&
          (slot_vl[hi_i] == work_vl)) begin
        hit = 1'b1; hit_idx = hi_i[2:0];
      end
      if (!slot_vld[hi_i] && !slot_releasing[hi_i]) begin
        free_found = 1'b1; free_idx = hi_i[2:0];
      end
    end
  end

  reg job_found;
  reg [2:0] job_slot;
  reg [4:0] job_frag;
  integer job_i, job_k;
  always @* begin
    job_found = 1'b0; job_slot = 3'd0; job_frag = 5'd0;
    for (job_i=SLOTS-1; job_i>=0; job_i=job_i-1) begin
      for (job_k=MAX_FRAGS-1; job_k>=0; job_k=job_k-1) begin
        if (!job_found && slot_vld[job_i] && !slot_releasing[job_i] &&
            slot_has_first[job_i] &&
            frag_src_valid[(job_i*MAX_FRAGS)+job_k]) begin
          job_found = 1'b1;
          job_slot = job_i[2:0];
          job_frag = job_k[4:0];
        end
      end
    end
  end
  assign copy_req_valid = (COPY_ENABLE != 0) && en && !draining && job_found &&
                          !copy_busy && !out_vld && !copy_free_pending &&
                          !stray_free_pending && !releasing_any;
  assign copy_src_blk = frag_src_blk[(job_slot*MAX_FRAGS)+job_frag];
  assign copy_src_byte = 13'd34;
  assign copy_dst_blk = slot_blk0[job_slot];
  assign copy_dst_byte = 13'd34 + {frag_wire_off[(job_slot*MAX_FRAGS)+job_frag],3'b000};
  assign copy_len = {3'd0,frag_app_len[(job_slot*MAX_FRAGS)+job_frag]};

  reg frag_iv_free_found;
  reg [4:0] frag_iv_free_idx;
  integer frag_iv_free_i;
  always @* begin
    frag_iv_free_found = 1'b0;
    frag_iv_free_idx = 5'd0;
    for (frag_iv_free_i=MAX_FRAGS-1; frag_iv_free_i>=0; frag_iv_free_i=frag_iv_free_i-1) begin
      if (!frag_iv_free_found && !frag_iv_valid[(hit_idx*MAX_FRAGS)+frag_iv_free_i]) begin
        frag_iv_free_found = 1'b1;
        frag_iv_free_idx = frag_iv_free_i[4:0];
      end
    end
  end

  reg interval_adjacent;
  reg interval_merge_idx_set;
  reg [4:0] interval_merge_idx;
  reg [15:0] interval_merge_start;
  reg [15:0] interval_merge_end;
  reg interval_merge_drop [0:MAX_FRAGS-1];
  // The old implementation performed MAX_FRAGS passes over MAX_FRAGS
  // intervals in one combinational block.  Keep the exact scan semantics, but
  // execute the scan over time while the input remains back-pressured.
  wire prep_merge_match =
        frag_iv_valid[(hit_idx*MAX_FRAGS)+prep_scan_q] &&
        !interval_merge_drop[prep_scan_q] &&
        ((frag_iv_end[(hit_idx*MAX_FRAGS)+prep_scan_q] == interval_merge_start) ||
         (frag_iv_start[(hit_idx*MAX_FRAGS)+prep_scan_q] == interval_merge_end));

  reg src_slot_free_found;
  reg [4:0] src_slot_free_idx;
  integer src_slot_i;
  always @* begin
    src_slot_free_found = 1'b0;
    src_slot_free_idx = 5'd0;
    for (src_slot_i=MAX_FRAGS-1; src_slot_i>=0; src_slot_i=src_slot_i-1) begin
      if (!src_slot_free_found && !frag_src_valid[(hit_idx*MAX_FRAGS)+src_slot_i]) begin
        src_slot_free_found = 1'b1;
        src_slot_free_idx = src_slot_i[4:0];
      end
    end
  end

  reg complete_sources_pending;
  integer comp_i;
  always @* begin
    complete_sources_pending = 1'b0;
    for (comp_i=0; comp_i<MAX_FRAGS; comp_i=comp_i+1)
      if (frag_src_valid[(complete_slot_q*MAX_FRAGS)+comp_i])
        complete_sources_pending = 1'b1;
  end
  // The destination remains owned by its context through the full-datagram
  // check. No normal descriptor is visible before the checker verdict.
  assign check_req_valid = (CHECK_ENABLE != 0) && en && !draining && complete_pending &&
                           !complete_sources_pending && !copy_busy &&
                           !complete_check_busy && !complete_checked && !out_vld;
  assign check_blk = complete_desc_q[B_BLK_HI:B_BLK_LO];
  assign check_app_len = {3'd0, complete_desc_q[B_PLEN_HI:B_PLEN_LO]};
  assign check_src_ip = complete_desc_q[B_SRC_HI:B_SRC_LO];
  assign check_dst_ip = complete_desc_q[B_DST_HI:B_DST_LO];
  wire check_fail = (CHECK_ENABLE != 0) && complete_pending &&
                    complete_check_busy && check_done && !check_good;

  reg release_found, release_slot_active, release_first;
  reg [2:0] release_slot;
  reg [4:0] release_frag;
  reg [3:0] release_id;
  integer rel_i, rel_k;
  always @* begin
    releasing_any = 1'b0; release_slot_active = 1'b0;
    release_found = 1'b0; release_first = 1'b0;
    release_slot = 3'd0; release_frag = 5'd0; release_id = 4'd0;
    for (rel_i=0; rel_i<SLOTS; rel_i=rel_i+1) begin
      if (slot_releasing[rel_i]) begin
        releasing_any = 1'b1;
        if (!release_slot_active) begin
          release_slot_active = 1'b1;
          release_slot = rel_i[2:0];
          if (slot_has_first[rel_i] && !slot_release_first_done[rel_i]) begin
            release_found = 1'b1; release_first = 1'b1;
            release_id = slot_blk0[rel_i];
          end else begin
            for (rel_k=0; rel_k<MAX_FRAGS; rel_k=rel_k+1) begin
              if (!release_found && (rel_k >= slot_release_scan[rel_i]) &&
                  frag_src_valid[(rel_i*MAX_FRAGS)+rel_k]) begin
                release_found = 1'b1; release_frag = rel_k[4:0];
                release_id = frag_src_blk[(rel_i*MAX_FRAGS)+rel_k];
              end
            end
          end
        end
      end
    end
  end
  always @* begin
    free_blk_valid = 1'b0;
    free_blk_id = 4'd0;
    if (COPY_ENABLE != 0) begin
      if (copy_free_pending) begin
        free_blk_valid = 1'b1; free_blk_id = copy_free_id;
      end else if (stray_free_pending) begin
        free_blk_valid = 1'b1; free_blk_id = stray_free_id;
      end else if (release_found) begin
        free_blk_valid = 1'b1; free_blk_id = release_id;
      end
    end
  end

  // Intervals are half-open: [start,end). Existing intervals are guaranteed
  // disjoint, so overlap detection is a fixed MAX_FRAGS comparison fanout.
  reg overlap_r;
  integer overlap_i;
  always @* begin
    overlap_r = 1'b0;
    for (overlap_i=0; overlap_i<MAX_FRAGS; overlap_i=overlap_i+1) begin
      if (frag_iv_valid[(hit_idx*MAX_FRAGS)+overlap_i] &&
          (in_start_b < frag_iv_end[(hit_idx*MAX_FRAGS)+overlap_i]) &&
          (in_end[15:0] > frag_iv_start[(hit_idx*MAX_FRAGS)+overlap_i]))
        overlap_r = 1'b1;
    end
  end
  wire overlap = hit && overlap_r;

  // eff_end：仅命中已有上下文时读该槽的末片偏移（避免读未初始化槽）；
  // 末片已到则以末片结束偏移为准 —— 支持「末片先到、由后续中间片补齐」。
  wire [15:0] eff_end  = hit ? ((slot_end[hit_idx] != 16'd0) ? slot_end[hit_idx]
                                : (!in_mf ? in_end[15:0] : 16'd0))
                             : (in_mf ? 16'd0 : in_end[15:0]);
  wire interval_store_overflow = hit && !interval_adjacent && !frag_iv_free_found;
  wire source_store_overflow = (COPY_ENABLE != 0) && hit && !in_is_first &&
                               ((slot_src_count[hit_idx] >= MAX_FRAGS) ||
                                !src_slot_free_found);
  wire frag_store_overflow = interval_store_overflow || source_store_overflow;
  reg complete_missing_r;
  reg complete_new_missing_r;
  wire coverage_candidate = in_isfr && !over_bad && !overlap && !frag_store_overflow;
  wire [16:0] coverage_eff_end = {1'b0,eff_end};
  wire [16:0] coverage_iv_start =
        {1'b0,frag_iv_start[(hit_idx*MAX_FRAGS)+coverage_scan_q]};
  wire [16:0] coverage_iv_end =
        (frag_iv_end[(hit_idx*MAX_FRAGS)+coverage_scan_q] > eff_end) ?
        coverage_eff_end :
        {1'b0,frag_iv_end[(hit_idx*MAX_FRAGS)+coverage_scan_q]};
  wire [16:0] coverage_existing_add =
        (frag_iv_valid[(hit_idx*MAX_FRAGS)+coverage_scan_q] &&
         (coverage_iv_start < coverage_eff_end) &&
         (coverage_iv_end > coverage_iv_start)) ?
        (coverage_iv_end - coverage_iv_start) : 17'd0;
  wire [16:0] coverage_in_end = (in_end > coverage_eff_end) ?
                                 coverage_eff_end : in_end;
  wire [16:0] coverage_in_add =
        (coverage_candidate && ({1'b0,in_start_b} < coverage_eff_end) &&
         (coverage_in_end > {1'b0,in_start_b})) ?
        (coverage_in_end - {1'b0,in_start_b}) : 17'd0;
  wire complete_hit = (eff_end != 16'd0) && !complete_missing_r;
  wire complete_new = (eff_end != 16'd0) && !complete_new_missing_r;
  wire emit_now  = complete_hit && ((!in_mf) || (slot_end[hit_idx] != 16'd0)) &&
                   (slot_has_first[hit_idx] || in_is_first);  // 必须已见首片和完整范围
  wire emit_solo = !in_mf && (in_foff_b == 16'd0) && complete_new;  // 新建即完整

  wire input_base_ready =
                    ((COPY_ENABLE == 0) ? (!out_vld || out_ready) :
                     (en && !draining && !out_vld && !copy_busy && !job_found &&
                      !complete_pending && !copy_free_pending &&
                      !stray_free_pending && !releasing_any));
  wire input_needs_prep = en && in_isfr;
  // Accept a fragment once, latch it, then process it internally after the
  // sequential scan. This also handles sources that pulse valid for one cycle
  // instead of holding it through back-pressure.
  assign in_ready = !rst_sync && input_base_ready && !prep_active;
  wire take = (!rst_sync && in_vld && input_base_ready &&
               !prep_active && !input_needs_prep) ||
              (prep_active && prep_done);

  // ------------------------------------------------------------------
  // 本拍被 take 分支复用的槽位掩码（组合）。超时/递减扫描必须排除这些槽，
  // 否则「计时恰好到 0」与「本拍重新装载」在同一拍发生时会互相覆盖
  // （非阻塞赋值的后写胜出规则只保证同一 always 块内、同一变量的顺序，
  //  不能让递增型的扫描循环与装载分支形成可靠优先级）。
  // 三种复用：① hit 且未因重叠作废；② hit 且重叠作废（清槽）；③ 新建分配。
  // ------------------------------------------------------------------
  wire hit_reuse   = take && hit && !overlap && !frag_store_overflow &&
                     (slot_frag[hit_idx] != 8'd255);
  wire hit_kill    = take && hit && (overlap || frag_store_overflow ||
                                     (slot_frag[hit_idx] == 8'd255));
  wire new_reuse   = take && !hit && free_found;
  wire [SLOTS-1:0] slot_touch =
        (hit_reuse    ?  (8'd1 << hit_idx)  : 8'd0) |
        (hit_kill     ?  (8'd1 << hit_idx)  : 8'd0) |
        (new_reuse    ?  (8'd1 << free_idx) : 8'd0);

  reg  [SLOTS-1:0] to_fire;
  reg  [31:0]      to_add;
  // take 分支本拍产生的丢弃数（oversize / overlap / fragcnt / 槽耗尽）。
  // 这些分支互斥，故最多为 1；与超时回收数 to_add 合并成单次自增，
  // 避免同拍对 drop_cnt 双写导致丢计数。
  wire drop_inc = (take && en && in_isfr &&
                   (over_bad ||
                    (hit && (overlap || frag_store_overflow ||
                             (slot_frag[hit_idx] == 8'd255))) ||
                    (!hit && !over_bad && !free_found))) ? 32'd1 : 32'd0;
  integer tf_k;
  reg timeout_found;
  wire timeout_blocked = prep_active || ((COPY_ENABLE != 0) &&
                         (copy_busy || copy_req_valid || complete_pending ||
                           out_vld || releasing_any));
  always @* begin
    to_fire = {SLOTS{1'b0}}; to_add = 32'd0; timeout_found = 1'b0;
    for (tf_k = 0; tf_k < SLOTS; tf_k = tf_k + 1)
      if ((TIMEOUT_TICKS > 0) && !timeout_found && !timeout_blocked && slot_vld[tf_k] &&
          !slot_releasing[tf_k] && (slot_timer[tf_k] == 16'd0) &&
          !slot_touch[tf_k]) begin
        to_fire[tf_k] = 1'b1;
        to_add = to_add + 32'd1;
        timeout_found = 1'b1;
      end
  end

  integer sq_i;
  integer init_f;
  integer frag_iv_i;
  always @(posedge clk) begin
    if (rst_sync) begin
      out_vld <= 1'b0; out_drop <= 1'b0; out_reason <= E_NONE;
      out_desc <= {DW{1'b0}}; out_vl <= 12'd0;
      hit_cnt <= 32'd0; drop_cnt <= 32'd0;
      copy_busy <= 1'b0; copy_slot_q <= 3'd0; copy_frag_q <= 5'd0;
      copy_free_pending <= 1'b0; copy_free_id <= 4'd0;
      complete_pending <= 1'b0; complete_slot_q <= 3'd0;
      complete_check_busy <= 1'b0; complete_checked <= 1'b0;
      drain_pending <= 1'b0;
      complete_desc_q <= {DW{1'b0}}; complete_vl_q <= 12'd0;
      stray_free_pending <= 1'b0; stray_free_id <= 4'd0;
      prep_active <= 1'b0; prep_done <= 1'b0; prep_phase <= PREP_MERGE;
      prep_pass_q <= 5'd0; prep_scan_q <= 5'd0;
      coverage_scan_q <= 5'd0; coverage_sum <= 17'd0;
      prep_desc_q <= {DW{1'b0}};
      prep_vl_q <= 12'd0;
      interval_adjacent <= 1'b0;
      interval_merge_idx_set <= 1'b0;
      interval_merge_idx <= 5'd0;
      interval_merge_start <= 16'd0;
      interval_merge_end <= 16'd0;
      complete_missing_r <= 1'b0;
      complete_new_missing_r <= 1'b0;
      coverage_sum <= 17'd0;
      for (frag_iv_i = 0; frag_iv_i < MAX_FRAGS; frag_iv_i = frag_iv_i + 1)
        interval_merge_drop[frag_iv_i] <= 1'b0;
      for (sq_i = 0; sq_i < SLOTS; sq_i = sq_i + 1) begin
        slot_vld[sq_i] <= 1'b0; slot_src[sq_i] <= 32'd0; slot_dst[sq_i] <= 32'd0;
        slot_ident[sq_i] <= 16'd0; slot_vl[sq_i] <= 12'd0; slot_blk0[sq_i] <= 4'd0;
        slot_sport[sq_i] <= 16'd0; slot_dport[sq_i] <= 16'd0; slot_timer[sq_i] <= 16'd0;
        slot_end[sq_i] <= 16'd0; slot_frag[sq_i] <= 8'd0; slot_has_first[sq_i] <= 1'b0;
        slot_src_count[sq_i] <= 5'd0; slot_releasing[sq_i] <= 1'b0;
        slot_release_first_done[sq_i] <= 1'b0; slot_release_scan[sq_i] <= 5'd0;
        for (frag_iv_i = 0; frag_iv_i < MAX_FRAGS; frag_iv_i = frag_iv_i + 1) begin
          frag_iv_start[(sq_i * MAX_FRAGS) + frag_iv_i] <= 16'd0;
          frag_iv_end[(sq_i * MAX_FRAGS) + frag_iv_i] <= 16'd0;
          frag_iv_valid[(sq_i * MAX_FRAGS) + frag_iv_i] <= 1'b0;
        end
      end
      for (init_f=0; init_f<FRAG_ENTRIES; init_f=init_f+1) begin
        frag_src_blk[init_f] <= 4'd0;
        frag_wire_off[init_f] <= 13'd0;
        frag_app_len[init_f] <= 11'd0;
        frag_src_valid[init_f] <= 1'b0;
      end
    end else begin
      // Prepare fragment coverage before accepting it.  The source keeps
      // in_vld/data stable while in_ready is low, so no extra input register
      // is needed.  The two scans below reproduce the old combinational
      // MAX_FRAGS x MAX_FRAGS decisions one item per clock.
      if (!prep_active && !prep_done && in_vld && input_base_ready &&
          input_needs_prep) begin
        prep_desc_q <= in_desc;
        prep_vl_q <= in_vl;
        prep_active <= 1'b1;
        prep_done <= 1'b0;
        prep_phase <= PREP_MERGE;
        prep_pass_q <= 5'd0;
        prep_scan_q <= 5'd0;
        interval_adjacent <= 1'b0;
        interval_merge_idx_set <= 1'b0;
        interval_merge_idx <= 5'd0;
        interval_merge_start <= in_start_b;
        interval_merge_end <= in_end[15:0];
        for (frag_iv_i = 0; frag_iv_i < MAX_FRAGS; frag_iv_i = frag_iv_i + 1)
          interval_merge_drop[frag_iv_i] <= 1'b0;
      end else if (prep_active && !prep_done) begin
        if (prep_phase == PREP_MERGE) begin
          if (prep_merge_match) begin
            interval_merge_drop[prep_scan_q] <= 1'b1;
            interval_adjacent <= 1'b1;
            if (!interval_merge_idx_set) begin
              interval_merge_idx <= prep_scan_q;
              interval_merge_idx_set <= 1'b1;
            end
            if (frag_iv_end[(hit_idx*MAX_FRAGS)+prep_scan_q] == interval_merge_start)
              interval_merge_start <= frag_iv_start[(hit_idx*MAX_FRAGS)+prep_scan_q];
            if (frag_iv_start[(hit_idx*MAX_FRAGS)+prep_scan_q] == interval_merge_end)
              interval_merge_end <= frag_iv_end[(hit_idx*MAX_FRAGS)+prep_scan_q];
          end
          if (prep_scan_q == MAX_FRAGS-1) begin
            if (prep_pass_q == MAX_FRAGS-1) begin
              if (!interval_merge_idx_set && !prep_merge_match)
                interval_merge_idx <= frag_iv_free_idx;
              prep_phase <= PREP_COVER_SCAN;
              prep_pass_q <= 5'd0;
              prep_scan_q <= 5'd0;
              coverage_scan_q <= 5'd0;
              coverage_sum <= 17'd0;
              complete_missing_r <= 1'b0;
              complete_new_missing_r <= 1'b0;
            end else begin
              prep_pass_q <= prep_pass_q + 5'd1;
              prep_scan_q <= 5'd0;
            end
          end else begin
            prep_scan_q <= prep_scan_q + 5'd1;
          end
        end else if (prep_phase == PREP_COVER_SCAN) begin
          if (coverage_scan_q == MAX_FRAGS-1) begin
            complete_missing_r <=
              ((coverage_sum + coverage_existing_add + coverage_in_add) <
               coverage_eff_end);
            complete_new_missing_r <=
              ((coverage_sum + coverage_existing_add + coverage_in_add) <
               coverage_eff_end);
            prep_done <= 1'b1;
          end else begin
            coverage_sum <= coverage_sum + coverage_existing_add;
            coverage_scan_q <= coverage_scan_q + 5'd1;
          end
        end
      end

      if ((COPY_ENABLE != 0) && !en) drain_pending <= 1'b1;
      else if (drain_pending && (slot_used == 32'd0) && !out_vld &&
               !complete_pending && !copy_busy && !complete_check_busy &&
               !copy_free_pending && !stray_free_pending && !releasing_any)
        drain_pending <= 1'b0;
      if (out_vld && out_ready) begin out_vld <= 1'b0; out_drop <= 1'b0; end

      // Copy-job and descriptor barriers. A source block is released only
      // after the copy engine confirms its final destination write grant.
      if (copy_free_pending) copy_free_pending <= 1'b0;
      else if (stray_free_pending) stray_free_pending <= 1'b0;
      else if (release_slot_active) begin
        if (release_found) begin
          if (release_first) slot_release_first_done[release_slot] <= 1'b1;
          else begin
            frag_src_valid[(release_slot*MAX_FRAGS)+release_frag] <= 1'b0;
            slot_release_scan[release_slot] <= release_frag + 5'd1;
            if (slot_src_count[release_slot] != 5'd0)
              slot_src_count[release_slot] <= slot_src_count[release_slot] - 5'd1;
          end
        end else begin
          slot_releasing[release_slot] <= 1'b0;
          slot_vld[release_slot] <= 1'b0;
          slot_has_first[release_slot] <= 1'b0;
          slot_src_count[release_slot] <= 5'd0;
          slot_frag[release_slot] <= 8'd0;
          slot_end[release_slot] <= 16'd0;
          slot_timer[release_slot] <= 16'd0;
          slot_release_first_done[release_slot] <= 1'b0;
          slot_release_scan[release_slot] <= 5'd0;
        for (frag_iv_i = 0; frag_iv_i < MAX_FRAGS; frag_iv_i = frag_iv_i + 1)
          frag_iv_valid[(release_slot * MAX_FRAGS) + frag_iv_i] <= 1'b0;
        end
      end

      if (copy_req_valid && copy_req_ready) begin
        copy_busy <= 1'b1;
        copy_slot_q <= job_slot;
        copy_frag_q <= job_frag;
        slot_timer[job_slot] <= TO_LOAD;
      end
      if (copy_done && copy_busy) begin
        copy_busy <= 1'b0;
        copy_free_pending <= 1'b1;
        copy_free_id <= frag_src_blk[(copy_slot_q*MAX_FRAGS)+copy_frag_q];
        frag_src_valid[(copy_slot_q*MAX_FRAGS)+copy_frag_q] <= 1'b0;
        if (slot_src_count[copy_slot_q] != 5'd0)
          slot_src_count[copy_slot_q] <= slot_src_count[copy_slot_q] - 5'd1;
        slot_timer[copy_slot_q] <= TO_LOAD;
      end

      if (check_req_valid && check_req_ready) complete_check_busy <= 1'b1;
      if ((CHECK_ENABLE != 0) && complete_check_busy && check_done) begin
        complete_check_busy <= 1'b0;
        complete_checked <= check_good;
        if (!check_good) begin
          complete_pending <= 1'b0;
          out_desc <= complete_desc_q; out_vl <= complete_vl_q;
          out_vld <= 1'b1; out_drop <= 1'b1;
          out_reason <= (check_reason == 2'd1) ? E_UDP_LEN : E_UDP_CHECK;
          slot_releasing[complete_slot_q] <= 1'b1;
          slot_release_first_done[complete_slot_q] <= 1'b0;
          slot_release_scan[complete_slot_q] <= 5'd0;
        end
      end
      if (en && !draining && complete_pending && !out_vld && !complete_sources_pending && !copy_busy &&
          ((CHECK_ENABLE == 0) || complete_checked)) begin
        out_desc <= complete_desc_q;
        out_vl <= complete_vl_q;
        out_drop <= 1'b0; out_reason <= E_NONE; out_vld <= 1'b1;
        if (CHECK_ENABLE != 0) hit_cnt <= hit_cnt + 32'd1;
      end
      if (out_vld && out_ready && complete_pending && en && !draining) begin
        complete_pending <= 1'b0;
        complete_checked <= 1'b0;
        slot_vld[complete_slot_q] <= 1'b0;
        slot_has_first[complete_slot_q] <= 1'b0;
        slot_src_count[complete_slot_q] <= 5'd0;
        slot_frag[complete_slot_q] <= 8'd0;
        slot_end[complete_slot_q] <= 16'd0;
        for (frag_iv_i = 0; frag_iv_i < MAX_FRAGS; frag_iv_i = frag_iv_i + 1)
          frag_iv_valid[(complete_slot_q * MAX_FRAGS) + frag_iv_i] <= 1'b0;
      end

      // 超时回收 + 倒计时（先做扫描；被本拍复用的槽由下方 take 分支重新装载，
      // 两者写的是同一组数组，take 分支在源码顺序上更靠后，故复用值胜出）。
      drop_cnt <= drop_cnt + to_add + drop_inc + (check_fail ? 32'd1 : 32'd0);
      for (sq_i = 0; sq_i < SLOTS; sq_i = sq_i + 1) begin
        if (to_fire[sq_i]) begin
          slot_releasing[sq_i] <= 1'b1;
          slot_release_first_done[sq_i] <= 1'b0;
          slot_release_scan[sq_i] <= 5'd0;
          slot_timer[sq_i] <= 16'd0;
        end else if ((TIMEOUT_TICKS > 0) && slot_vld[sq_i] &&
                     (slot_timer[sq_i] != 16'd0) && !slot_touch[sq_i]) begin
          slot_timer[sq_i] <= slot_timer[sq_i] - 16'd1;
        end
      end

      // Disable drains every owned context. Let an accepted copy/check finish
      // before freeing any memory it may still access. Block new engine jobs
      // while disabled and publish no successful descriptor from this drain.
      if (draining && !copy_busy && !complete_check_busy &&
          !copy_free_pending && !stray_free_pending) begin
        complete_pending <= 1'b0; complete_checked <= 1'b0;
        if (out_vld && !out_drop) begin
          out_drop <= 1'b1; out_reason <= E_CANCEL;
          if (!complete_pending) begin
            stray_free_pending <= 1'b1;
            stray_free_id <= out_desc[B_BLK_HI:B_BLK_LO];
          end
        end
        for (sq_i=0; sq_i<SLOTS; sq_i=sq_i+1) begin
          if (slot_vld[sq_i] && !slot_releasing[sq_i]) begin
            slot_releasing[sq_i] <= 1'b1;
            slot_release_first_done[sq_i] <= 1'b0;
            slot_release_scan[sq_i] <= 5'd0;
          end
        end
      end

      if (take) begin
        prep_active <= 1'b0;
        prep_done <= 1'b0;
        if (!en || !in_isfr) begin
          out_desc <= work_desc; out_vl <= work_vl; out_drop <= 1'b0;
          out_reason <= E_NONE; out_vld <= 1'b1;
        end else if (over_bad) begin
          out_desc <= work_desc; out_vl <= work_vl; out_drop <= 1'b1;
          out_reason <= E_OVERSIZE;
          out_vld <= 1'b1;
          if (COPY_ENABLE != 0) begin
            stray_free_pending <= 1'b1;
            stray_free_id <= work_desc[B_BLK_HI:B_BLK_LO];
            if (hit) begin
              slot_releasing[hit_idx] <= 1'b1;
              slot_release_first_done[hit_idx] <= 1'b0;
              slot_release_scan[hit_idx] <= 5'd0;
            end
          end
        end else if (hit) begin
          if (overlap || frag_store_overflow || (slot_frag[hit_idx] == 8'd255)) begin
            out_desc <= work_desc; out_vl <= work_vl; out_drop <= 1'b1;
            out_reason <= overlap ? E_OVERLAP : E_FRAGCNT;
            out_vld <= 1'b1;
            if (COPY_ENABLE != 0) begin
              stray_free_pending <= 1'b1;
              stray_free_id <= work_desc[B_BLK_HI:B_BLK_LO];
              slot_releasing[hit_idx] <= 1'b1;
              slot_release_first_done[hit_idx] <= 1'b0;
              slot_release_scan[hit_idx] <= 5'd0;
            end else begin
              slot_vld[hit_idx] <= 1'b0;
              slot_has_first[hit_idx] <= 1'b0;
            end
          end           else begin
            slot_timer[hit_idx] <= TO_LOAD;
            slot_frag[hit_idx]  <= slot_frag[hit_idx] + 8'd1;
            for (frag_iv_i = 0; frag_iv_i < MAX_FRAGS; frag_iv_i = frag_iv_i + 1)
              if (interval_merge_drop[frag_iv_i])
                frag_iv_valid[(hit_idx * MAX_FRAGS) + frag_iv_i] <= 1'b0;
            frag_iv_start[(hit_idx*MAX_FRAGS)+interval_merge_idx] <= interval_merge_start;
            frag_iv_end[(hit_idx*MAX_FRAGS)+interval_merge_idx] <= interval_merge_end;
            frag_iv_valid[(hit_idx*MAX_FRAGS)+interval_merge_idx] <= 1'b1;
            if (!in_mf) slot_end[hit_idx] <= in_end[15:0];
            if ((COPY_ENABLE != 0) && !in_is_first) begin
              frag_src_blk[(hit_idx*MAX_FRAGS)+src_slot_free_idx] <=
                work_desc[B_BLK_HI:B_BLK_LO];
              frag_wire_off[(hit_idx*MAX_FRAGS)+src_slot_free_idx] <= in_foff;
              frag_app_len[(hit_idx*MAX_FRAGS)+src_slot_free_idx] <= in_plen;
              frag_src_valid[(hit_idx*MAX_FRAGS)+src_slot_free_idx] <= 1'b1;
              slot_src_count[hit_idx] <= slot_src_count[hit_idx] + 5'd1;
            end
            // 乱序场景：首片后到。此处把 UDP 端口字段补进槽位，交付时优先取
            // 「本拍到达的首片」字段（组合见下方 out_desc 赋值），否则取槽位保存值。
            if (in_is_first) begin
              slot_has_first[hit_idx] <= 1'b1;
              slot_blk0[hit_idx] <= work_desc[B_BLK_HI:B_BLK_LO];
              slot_sport[hit_idx] <= work_desc[B_SPORT_HI:B_SPORT_LO];
              slot_dport[hit_idx] <= work_desc[B_DPORT_HI:B_DPORT_LO];
            end
            if (emit_now) begin
              if (COPY_ENABLE != 0) begin
                complete_desc_q <= work_desc;
                complete_desc_q[B_PLEN_HI:B_PLEN_LO] <= eff_end[10:0];
                complete_desc_q[B_BLK_HI:B_BLK_LO] <= in_is_first ?
                  work_desc[B_BLK_HI:B_BLK_LO] : slot_blk0[hit_idx];
                complete_desc_q[B_SRC_HI:B_SRC_LO] <= in_is_first ? in_src : slot_src[hit_idx];
                complete_desc_q[B_DST_HI:B_DST_LO] <= in_is_first ? in_dst : slot_dst[hit_idx];
                complete_desc_q[B_SPORT_HI:B_SPORT_LO] <= in_is_first ?
                  work_desc[B_SPORT_HI:B_SPORT_LO] : slot_sport[hit_idx];
                complete_desc_q[B_DPORT_HI:B_DPORT_LO] <= in_is_first ?
                  work_desc[B_DPORT_HI:B_DPORT_LO] : slot_dport[hit_idx];
                complete_vl_q <= slot_vl[hit_idx];
                complete_slot_q <= hit_idx;
                complete_pending <= 1'b1;
                complete_check_busy <= 1'b0;
                complete_checked <= 1'b0;
                for (frag_iv_i = 0; frag_iv_i < MAX_FRAGS; frag_iv_i = frag_iv_i + 1)
                  frag_iv_valid[(hit_idx * MAX_FRAGS) + frag_iv_i] <= 1'b0;
                slot_end[hit_idx] <= 16'd0;
                if (CHECK_ENABLE == 0) hit_cnt <= hit_cnt + 32'd1;
              end else begin
                out_desc <= work_desc;
                out_desc[B_PLEN_HI:B_PLEN_LO] <= eff_end[10:0];
                out_desc[B_BLK_HI:B_BLK_LO] <= in_is_first ?
                  work_desc[B_BLK_HI:B_BLK_LO] : slot_blk0[hit_idx];
                out_desc[B_SRC_HI:B_SRC_LO] <= in_is_first ? in_src : slot_src[hit_idx];
                out_desc[B_DST_HI:B_DST_LO] <= in_is_first ? in_dst : slot_dst[hit_idx];
                out_desc[B_SPORT_HI:B_SPORT_LO] <= in_is_first ?
                  work_desc[B_SPORT_HI:B_SPORT_LO] : slot_sport[hit_idx];
                out_desc[B_DPORT_HI:B_DPORT_LO] <= in_is_first ?
                  work_desc[B_DPORT_HI:B_DPORT_LO] : slot_dport[hit_idx];
                out_vl <= slot_vl[hit_idx];
                out_drop <= 1'b0; out_reason <= E_NONE; out_vld <= 1'b1;
                slot_vld[hit_idx] <= 1'b0;
                for (frag_iv_i = 0; frag_iv_i < MAX_FRAGS; frag_iv_i = frag_iv_i + 1)
                  frag_iv_valid[(hit_idx * MAX_FRAGS) + frag_iv_i] <= 1'b0;
                slot_end[hit_idx] <= 16'd0;
                slot_has_first[hit_idx] <= 1'b0;
                hit_cnt <= hit_cnt + 32'd1;
              end
            end
          end
        end else if (!free_found) begin
          out_desc <= work_desc; out_vl <= work_vl; out_drop <= 1'b1;
          out_reason <= E_SLOT; out_vld <= 1'b1;
          if (COPY_ENABLE != 0) begin
            stray_free_pending <= 1'b1;
            stray_free_id <= work_desc[B_BLK_HI:B_BLK_LO];
          end
        end else begin
          slot_vld[free_idx]   <= !emit_solo;
          slot_src[free_idx]   <= in_src;
          slot_dst[free_idx]   <= in_dst;
          slot_ident[free_idx] <= in_ident;
          slot_vl[free_idx]    <= work_vl;
          slot_blk0[free_idx]  <= work_desc[B_BLK_HI:B_BLK_LO];
          // UDP 头只存在于 offset==0 的片（首片/单帧）；后续片该字段为载荷，
          // 不能写入端口槽位，否则交付时用垃圾端口号导致解析层 DPORT 拒绝。
          slot_sport[free_idx] <= in_is_first ? work_desc[B_SPORT_HI:B_SPORT_LO] : 16'd0;
          slot_dport[free_idx] <= in_is_first ? work_desc[B_DPORT_HI:B_DPORT_LO] : 16'd0;
          slot_timer[free_idx] <= TO_LOAD;
          slot_frag[free_idx]  <= 8'd1;
          for (frag_iv_i = 0; frag_iv_i < MAX_FRAGS; frag_iv_i = frag_iv_i + 1) begin
            frag_iv_start[(free_idx * MAX_FRAGS) + frag_iv_i] <= 16'd0;
            frag_iv_end[(free_idx * MAX_FRAGS) + frag_iv_i] <= 16'd0;
            frag_iv_valid[(free_idx * MAX_FRAGS) + frag_iv_i] <= 1'b0;
          end
          frag_iv_start[(free_idx * MAX_FRAGS)] <= in_start_b;
          frag_iv_end[(free_idx * MAX_FRAGS)] <= in_end[15:0];
          frag_iv_valid[(free_idx * MAX_FRAGS)] <= 1'b1;
          slot_end[free_idx]   <= in_mf ? 16'd0 : in_end[15:0];
          slot_has_first[free_idx] <= in_is_first;
          slot_src_count[free_idx] <= ((COPY_ENABLE != 0) && !in_is_first) ? 5'd1 : 5'd0;
          slot_releasing[free_idx] <= 1'b0;
          slot_release_first_done[free_idx] <= 1'b0;
          slot_release_scan[free_idx] <= 5'd0;
          if ((COPY_ENABLE != 0) && !in_is_first) begin
            frag_src_blk[(free_idx*MAX_FRAGS)] <= work_desc[B_BLK_HI:B_BLK_LO];
            frag_wire_off[(free_idx*MAX_FRAGS)] <= in_foff;
            frag_app_len[(free_idx*MAX_FRAGS)] <= in_plen;
            frag_src_valid[(free_idx*MAX_FRAGS)] <= 1'b1;
          end
          if (emit_solo) begin
            // offset=0 且 MF=0：单帧完整（被误标 is_frag）
            out_desc <= work_desc;
            out_desc[B_PLEN_HI:B_PLEN_LO] <= in_plen[10:0];
            out_vl <= work_vl; out_drop <= 1'b0; out_reason <= E_NONE;
            out_vld <= 1'b1; hit_cnt <= hit_cnt + 32'd1;
          end
        end
      end
    end
  end

  reg [31:0] used_r;
  integer ur_i;
  always @* begin
    used_r = 32'd0;
    for (ur_i = 0; ur_i < SLOTS; ur_i = ur_i + 1)
      if (slot_vld[ur_i]) used_r = used_r + 32'd1;
  end
  assign slot_used = used_r;

endmodule
