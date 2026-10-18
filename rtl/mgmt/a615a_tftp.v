// =====================================================================
// a615a_tftp.v —— 数据加载 TFTP 引擎（RFC 1350 子集；不是完整 ARINC 615A）
// 设计书 §7.17。continue4 实现（原第 0 周空壳）。
//
// 已实现（新增 IP 绑定/重传修复尚待功能仿真）：
//   * WRQ(2)  : 文件名白名单 + mode 必须为 octet，通过→ACK(0) 开会话；
//               白名单不中→ERROR(2) 访问违规；mode 非 octet→ERROR(0)。
//   * DATA(3) : 块号 == 期望 → 写入加载区、累计字节与 CRC32、ACK(blk)；
//               块号 == 期望-1 → 重复块，只补发 ACK，不重复写（dup_cnt）；
//               其它块号 → ERROR(0)；TID(源端口) 不符 → ERROR(5)。
//               末块（载荷<512 B）→ loaded_ok=1，会话结束。
//               DATA 超过512 B → ERROR(4)，不写/不计超出的字节；
//               超出加载区容量 → ERROR(3) 磁盘满；同拍最后字节溢出也即时判定。
//   * RRQ(1)  : "STATUS" → 32 B 状态文件 DATA(1)（末块）；
//               "UPLOAD" → 卸载（step3 20260928）：已完成加载（loaded_ok=1）时
//               按 512 B/块回送加载区镜像 DATA(1..N)，末块 <512 B；镜像长度为
//               512 的整数倍时以 0 字节 DATA 结束（RFC 1350 §6）。无镜像 → ERROR(1)。
//   * ACK(4)  : STATUS 会话收到 ACK(1) → 结束；卸载会话收到 ACK(k) 且 k 为
//               当前块 → 发 DATA(k+1)，k 为末块 → 结束；重复 ACK(k-1) 不重发
//               （RFC 1350 "Sorcerer's Apprentice"，只计 dup_cnt，由超时路径重发）；
//               外来 TID 的 ACK → ERROR(5)，会话继续（RFC 1350 §4）。
//   * ERROR(5): 记录对端错误码并终止会话。
//   * 超时重传：TIMEOUT_US 无后续报文则重发上一条响应（卸载会话恢复为当前
//               DATA 块，即使其间插入过发给外来 TID 的 ERROR(5)），
//               retry_cnt > RETRY_MAX → 本地 ERROR(4) 并终止。
//               即时响应使用请求方 IP/TID；超时恢复为会话所有者 IP/TID。
//               顶层启用 BIND_PEER_IP=1；默认 0 只用于旧单元 TB 兼容。
//               未建立写会话或 IP/TID 不匹配的 DATA 不写加载区/CRC。
//               STATUS 使用 RRQ 接收时的固定快照，重传不随计数器变化。
//   * step3 修复（20260928）：块号低字节在 bidx==3 才写入 blk_num，而 4 字节
//     报文（ACK / 0 字节 DATA / ERROR 头）的 EOP 恰在同一拍判定，旧实现读到的
//     是陈旧块号：单元级 4 B ACK(1) 结束不了 RRQ 会话（之后超时重发）、0 字节
//     末块被判块号错回 ERROR(0)、字节计数 paylen+1 对空块多记 1。现 EOP 判定一律
//     用 blk_now（bidx==3 时并入当拍 in_data）与 pay_now（<=512精确，>512判超限）。
//   * 容量边界：若最后一个 DATA 字节越过 LOAD_BYTES 且同拍 EOP，不能只检查
//     上一拍登记的 ovf；data_byte_over_capacity 会把当前字节也纳入 ERROR(3) 判决。
//     顶层按 resp_len 原样上线；4 B ACK 的 Ethernet 最小帧填充由帧构建器置于
//     UDP 载荷之后、AFDX SN 之前，不改变 UDP Length 或 TFTP 报文内容。
//   * 卸载数据通路：加载区是 32 KB 同步读 BRAM。每发一块前先把该 512 B 复制到
//     128 字响应缓冲 rbuf（bram_1w1r 同步读，约 130 拍），复制完成才置 resp_vld。
//     复制与主机读口分时复用同一加载区读端口（主机优先）。2026-10-07：rbuf 由
//     组合 LUT 阵列改为同步 BRAM，卸载载荷字节相对 resp_rd_addr 晚 1 拍；ACK/
//     ERROR/STATUS 头与 STATUS 载荷仍组合（短路径）。顶层 0xAC27 自增读之间本
//     就有空拍，晚 1 拍与主机观测窗兼容；单元级 T16u 本就按 2 拍采样。
//
// 覆盖边界（如实标注，未实现/不宣称）：
//   - RRQ 只服务 "STATUS" 与 "UPLOAD"（最近一次加载的镜像），无文件系统/多文件；
//   - TFTP 只支持单会话；顶层外来 IP/TID 的 ERROR(5) 回到错误请求方，
//     后续超时重传仍回到已建立会话的 IP/TID；
//   - OACK/blksize/tsize/timeout negotiation is unsupported; option-bearing requests are rejected with ERROR(4).
//   - Top has a separate active client. Optional control_mode accepts the
//     explicitly configured LUR WRQ name, holds the complete image until
//     control_ack/abort, and protects it from replacement. LUI/LUS workflow
//     and standard loading/unloading semantics remain outside this server.
//   - 同一所有者重复 WRQ 的重开行为、末块 ACK 丢失后的 dally 尚未补齐；
//   - CRC32 为标准反射 CRC-32（poly EDB88320，初值 FFFFFFFF，末尾取反），
//     仅覆盖 DATA 载荷字节，不含 TFTP 头。
// P02（2026-10-10）接收契约：
//   - in_ready 是逐字节消费门（响应在线/卸载复制期间为 0）；上游 mgmt_sap_rx
//     在 in_ready=0 时保持当前字节与消费位置，不再跳过字节；
//   - 超时与包处理同拍的优先关系：若同拍消费到 EOP，超时判决推迟到下一
//     tick（包处理优先）；超时响应在线期间的包字节由上游背压保持。
// P02/T25（2026-10-10）会话接管：
//   - 新 RRQ/WRQ 是会话请求：不同 IP/TID 的新请求不再按"外来 TID"回
//     ERROR(5)，而是按单会话设计接管会话（重开、按新对端应答）；
//   - 外来 DATA/ACK/ERROR 仍回 ERROR(5) 且不扰动已建立会话状态；
//     该行为差异来自 T25 peer-isolation 场景复验（详见测试报告）。
// =====================================================================
`timescale 1 ns / 1 ps
module a615a_tftp #(
  parameter integer LOAD_WORDS = 8192,          // 32 KB 加载区
  parameter integer RETRY_MAX  = 3,
  parameter integer TIMEOUT_US = 5000,
  parameter integer BIND_PEER_IP = 0,          // AFDX_top enables IP+port binding.
  // Explicit project endpoint name, MSB-first, 1..32 bytes (no NUL).
  parameter [255:0] CONTROL_FILENAME = {"TARGET.LUR",176'd0},
  parameter integer CONTROL_FILENAME_LEN = 10
)(
  input  wire        clk,
  input  wire        rst_sync,
  input  wire        en,
  input  wire        tick_us,
  // 请求字节流（UDP 载荷）
  input  wire        in_vld,
  input  wire        in_sop,
  input  wire        in_eop,
  input  wire [7:0]  in_data,
  input  wire [15:0] in_sport,
  output wire        in_ready,
  // 响应字节流（由上层封装成 UDP 回包 / 或由主机读走）
  output reg         resp_vld,
  output reg  [10:0] resp_len,
  output reg  [15:0] resp_tid,
  input  wire        resp_ack,
  input  wire [10:0] resp_rd_addr,
  input  wire        resp_rd_ahead,
  output wire [7:0]  resp_byte,
  output wire        resp_byte_sync,
  // 加载区主机读口（同步读，上层需打一拍选通）
  input  wire        host_rd,
  input  wire [12:0] host_addr,
  output reg  [31:0] host_rdata,
  // 状态 / 观测
  output reg         loaded_ok,
  output reg  [15:0] err_code,
  output reg  [15:0] tid,
  output reg  [15:0] blk_expect,
  output reg  [31:0] bytes_rcvd,
  output reg  [31:0] crc32_val,
  output reg  [31:0] pkt_cnt,
  output reg  [31:0] dup_cnt,
  output reg  [31:0] err_cnt,
  output reg  [31:0] timeout_cnt,
  output reg  [7:0]  retry_cnt,
  output reg  [31:0] fname_head,
  output wire [3:0]  state_o,
  input  wire [31:0] in_srcip,
  output reg  [31:0] resp_peer_ip,
  input  wire        control_mode,
  input  wire        control_ack,
  input  wire        control_abort,
  output reg         control_file_valid,
  output wire        control_busy
);
  localparam [1:0] K_NONE = 2'd0, K_ACK = 2'd1, K_ERR = 2'd2, K_DATA = 2'd3;
  localparam integer LOAD_BYTES = LOAD_WORDS * 4;
  localparam integer STAT_LEN   = 32;

  reg [31:0] load_mem [0:LOAD_WORDS-1];

  reg [15:0] opc, blk_num, bidx;
  reg [1:0]  ph;                 // RRQ/WRQ: 0=filename 1=mode 2=tail
  reg [7:0]  fn_i;
  reg [4:0]  md_i;
  reg        fn_m0, fn_m1, md_ok;
  reg        fn_control, request_control, control_owner;
  reg [11:0] control_last_len;
  function [7:0] control_name_byte;
    input [7:0] idx;
    reg [255:0] shifted;
    begin
      shifted = CONTROL_FILENAME >> ((31-idx)*8);
      control_name_byte = (idx<32) ? shifted[7:0] : 8'd0;
    end
  endfunction
  reg        sess, rrq_sess, ovf;
  assign control_busy = control_owner && (sess || control_file_valid);
  reg [31:0] session_peer_ip;
  // EOP 当拍操作码（声明须先于 foreign_peer 使用；本工具链不接受隐式前向网）
  wire [15:0] opc_now = in_sop ? {8'd0, in_data} :
                          ((bidx == 16'd1) ? {opc[7:0], in_data} : opc);
  wire same_session_ip = (BIND_PEER_IP == 0) || (in_srcip == session_peer_ip);
  wire same_session_port = (BIND_PEER_IP != 0) ? (in_sport == tid) :
                          ((tid == 16'd0) || (in_sport == tid));
  wire foreign_peer = (sess || rrq_sess) &&
                      ((!same_session_ip) || (in_sport != tid)) &&
                      !((opc_now == 16'd1) || (opc_now == 16'd2));
  reg [255:0] stat_snapshot;
  reg [1:0]  resp_kind;
  reg [15:0] resp_blk, resp_err;
  reg [31:0] wstage;              // 时序：当前拼装的32位字
  reg [31:0] crc_acc;
  reg [31:0] to_ctr;
  reg [10:0] paylen;
  reg        crc_snap;          // in_eop 当拍 crc_acc 还没吃进最后一个字节

  // ---- EOP 当拍块号；DATA 载荷计数精确到512，513为超限饱和哨兵 ----
  wire [15:0] blk_now = (bidx == 16'd3) ? {blk_num[15:8], in_data} : blk_num;
  wire invalid_fixed_packet_length_eop = in_eop &&
      (in_sop || (((opc_now == 16'd3 || opc_now == 16'd4) && (bidx < 16'd3)) ||
                  ((opc_now == 16'd5) && (bidx < 16'd4)) ||
                  ((opc_now == 16'd4) && (bidx > 16'd3))));
  // P02/T16（2026-10-10）修复：请求"完整终止"的判据是"处于模式字段且末字节为
  // 其 NUL"。旧实现附加 md_i==5 条件，把长度≠5 的合法 NUL 结尾模式串
  //（如 netascii=8）误判为"不完整请求"回 ERROR(4)；正确语义为进入模式校验，
  // 非 octet → ERROR(0)（RFC 1350），真截断（EOP 处非 NUL / 尾随字节）仍 ERROR(4)。
  wire request_end_here = (ph == 2'd1) && (in_data == 8'h00);
  wire incomplete_request_eop = in_eop && (opc_now == 16'd1 || opc_now == 16'd2) &&
                                 !request_end_here;
  wire unterminated_error_eop = in_eop && (opc_now == 16'd5) && (in_data != 8'h00);
  // paylen saturates at 513, so pay_now is exact through 512 and remains >512
  // for any longer DATA packet (including lengths that would wrap an 11-bit count).
  wire [11:0] pay_now = (bidx >= 16'd4) ? ({1'b0, paylen} + 12'd1) : 12'd0;
  wire [31:0] data_abs_byte = (({16'd0, blk_num} - 32'd1) * 32'd512) +
                               ({16'd0, bidx} - 32'd4);
  wire data_byte_over_capacity = sess && same_session_ip &&
                                 (opc == 16'd3) && (bidx >= 16'd4) &&
                                 (blk_num == blk_expect) &&
                                 same_session_port &&
                                 ((data_abs_byte >= LOAD_BYTES) ||
                                  (control_owner && data_abs_byte>=8192));

  // ---- step3：卸载（RRQ "UPLOAD"）会话与块复制引擎 ----
  reg        ul_mode;           // 1 = 当前 RRQ 会话是卸载（否则为 STATUS）
  reg [15:0] ul_blk;            // 当前在途 DATA 块号
  reg [15:0] ul_nblk;           // 末块块号
  reg [8:0]  ul_last;           // 末块载荷字节数（0..511）
  reg [10:0] ul_rlen;           // 当前块响应长度（含 4 B 头）
  reg        cp_busy, cp_iss_d;
  reg [12:0] cp_ra;
  reg [7:0]  cp_nis;
  reg [6:0]  cp_wi;
  wire       cp_iss = cp_busy && (cp_nis != 8'd0) && !host_rd;
  wire [12:0] mem_ra = host_rd ? host_addr[12:0] : cp_ra;
  // Keep the visible byte index stable for opcode/block/header selection.
  // The top-level byte pump may independently prefetch the next payload byte
  // from the synchronous unload RAM while it consumes the current byte.
  wire [10:0] resp_ram_addr = resp_rd_addr + (resp_rd_ahead ? 11'd1 : 11'd0);
  wire [10:0] ra4 = resp_ram_addr - 11'd4;
  // rbuf：同步 1W1R，切开 post-fit 上 ra4→MLAB 组合读（扇出~1k）半/整周期 WNS。
  wire [31:0] rbw;
  reg  [1:0]  ra_lo_q;
  bram_1w1r #(.W(32), .D(128), .RD_NEG(0)) u_rbuf (
    .clk(clk),
    .wr_en(cp_iss_d), .wr_addr(cp_wi), .wr_data(host_rdata),
    .rd_addr(ra4[8:2]), .rd_data(rbw)
  );
  always @(posedge clk) ra_lo_q <= ra4[1:0];
  wire [7:0]  rb_b = (ra_lo_q == 2'd0) ? rbw[31:24] : (ra_lo_q == 2'd1) ? rbw[23:16] :
                     (ra_lo_q == 2'd2) ? rbw[15:8]  : rbw[7:0];
  function [10:0] ul_len_of;
    input [15:0] b; input [15:0] nb; input [8:0] last;
    begin ul_len_of = (b == nb) ? ({2'd0, last} + 11'd4) : 11'd516; end
  endfunction

  // Top-level SAP descriptor admission uses this to preserve the single
  // response slot and its peer metadata while a response or RAM copy is live.
  assign in_ready = !rst_sync && !resp_vld && !cp_busy && !control_abort && !control_ack;
  assign state_o  = {rrq_sess, sess, resp_kind};
  // Only RRQ UPLOAD DATA payload bytes come from the synchronous rbuf.
  // DATA headers and STATUS, ACK, and ERROR bytes are combinational.
  assign resp_byte_sync = (resp_kind == K_DATA) && ul_mode;

  // ---- 反射 CRC-32（字节串行）----
  function [31:0] crc32_byte;
    input [31:0] c0; input [7:0] d;
    reg [31:0] c; integer k;
    begin
      c = c0 ^ {24'd0, d};
      for (k = 0; k < 8; k = k + 1)
        c = c[0] ? ((c >> 1) ^ 32'hEDB88320) : (c >> 1);
      crc32_byte = c;
    end
  endfunction
  // ---- 文件名白名单："UPLOAD" / "STATUS" ----
  function [7:0] wl0; input [4:0] k;
    begin case (k) 0:wl0="U"; 1:wl0="P"; 2:wl0="L"; 3:wl0="O"; 4:wl0="A"; 5:wl0="D";
                   default: wl0=8'h00; endcase end
  endfunction
  function [7:0] wl1; input [4:0] k;
    begin case (k) 0:wl1="S"; 1:wl1="T"; 2:wl1="A"; 3:wl1="T"; 4:wl1="U"; 5:wl1="S";
                   default: wl1=8'h00; endcase end
  endfunction
  function [7:0] md_ch; input [4:0] k;
    begin case (k) 0:md_ch="o"; 1:md_ch="c"; 2:md_ch="t"; 3:md_ch="e"; 4:md_ch="t";
                   default: md_ch=8'h00; endcase end
  endfunction
  function [7:0] lower; input [7:0] c;
    begin lower = (c >= "A" && c <= "Z") ? (c + 8'd32) : c; end
  endfunction
  // ---- ERROR 报文的定长消息 "TFTP ERR" + NUL ----
  function [7:0] emsg; input [10:0] k;
    begin case (k) 0:emsg="T"; 1:emsg="F"; 2:emsg="T"; 3:emsg="P"; 4:emsg=" ";
                   5:emsg="E"; 6:emsg="R"; 7:emsg="R"; default: emsg=8'h00; endcase end
  endfunction
  // ---- RRQ 服务的 32 B 私有 STATUS 快照；重传不能随计数器变化 ----
  function [7:0] stat_b; input [10:0] k;
    reg [31:0] w;
    begin
      case (k[4:2])
        3'd0: w = stat_snapshot[255:224];
        3'd1: w = stat_snapshot[223:192];
        3'd2: w = stat_snapshot[191:160];
        3'd3: w = stat_snapshot[159:128];
        3'd4: w = stat_snapshot[127:96];
        3'd5: w = stat_snapshot[95:64];
        3'd6: w = stat_snapshot[63:32];
        default: w = stat_snapshot[31:0];
      endcase
      case (k[1:0]) 0: stat_b = w[31:24]; 1: stat_b = w[23:16];
                    2: stat_b = w[15:8];  default: stat_b = w[7:0]; endcase
    end
  endfunction

  assign resp_byte =
      (resp_kind == K_ACK)  ? ((resp_rd_addr == 11'd0) ? 8'h00 :
                               (resp_rd_addr == 11'd1) ? 8'h04 :
                               (resp_rd_addr == 11'd2) ? resp_blk[15:8] : resp_blk[7:0]) :
      (resp_kind == K_ERR)  ? ((resp_rd_addr == 11'd0) ? 8'h00 :
                               (resp_rd_addr == 11'd1) ? 8'h05 :
                               (resp_rd_addr == 11'd2) ? resp_err[15:8] :
                               (resp_rd_addr == 11'd3) ? resp_err[7:0] :
                                                         emsg(resp_rd_addr - 11'd4)) :
      (resp_kind == K_DATA) ? ((resp_rd_addr == 11'd0) ? 8'h00 :
                               (resp_rd_addr == 11'd1) ? 8'h03 :
                               (resp_rd_addr == 11'd2) ? resp_blk[15:8] :
                               (resp_rd_addr == 11'd3) ? resp_blk[7:0] :
                               ul_mode ? rb_b :       stat_b(resp_rd_addr - 11'd4)) :
                              8'h00;

  // 加载区单读端口：主机读优先，空闲拍给卸载复制引擎；无访问时保持上次读数。
  always @(posedge clk) begin
    if (host_rd || cp_iss) host_rdata <= load_mem[mem_ra];
  end

  // ======================================================================
  // 组合逻辑：DATA报文的字节对齐与拼装计算
  // ======================================================================
  
  // 中间计算变量（纯组合逻辑）
  reg [31:0] abs_i;               // 当前字节的绝对地址
  reg [16:0] abs_a;               // abs_i 的低17位
  reg [1:0]  lane;                // 字节在32位字内的对齐位置 (0..3)
  reg [31:0] nd;                  // 拼装后的新32位数据字
  
  always @(*) begin
    // 计算当前字节的绝对地址
    abs_i = data_abs_byte;
    abs_a = abs_i[16:0];
    lane  = abs_a[1:0];
    
    // 根据对齐位置拼装32位字
    case (lane)
      2'd0:    nd = {in_data, 24'd0};
      2'd1:    nd = {wstage[31:24], in_data, 16'd0};
      2'd2:    nd = {wstage[31:16], in_data, 8'd0};
      default: nd = {wstage[31:8], in_data};
    endcase
  end
  
  always @(posedge clk) begin
    if (rst_sync) begin
      opc <= 16'd0; blk_num <= 16'd0; bidx <= 16'd0; ph <= 2'd0;
      fn_i <= 5'd0; md_i <= 5'd0; fn_m0 <= 1'b0; fn_m1 <= 1'b0; md_ok <= 1'b0;
      fn_control <= 1'b0; request_control <= 1'b0; control_owner <= 1'b0;
      control_file_valid <= 1'b0; control_last_len <= 12'd0;
      sess <= 1'b0; rrq_sess <= 1'b0; ovf <= 1'b0;
      resp_kind <= K_NONE; resp_blk <= 16'd0; resp_err <= 16'd0;
      resp_vld <= 1'b0; resp_len <= 11'd0; resp_tid <= 16'd0;
      resp_peer_ip <= 32'd0; session_peer_ip <= 32'd0;
      stat_snapshot <= 256'd0;
      wstage <= 32'd0; crc_acc <= 32'hFFFF_FFFF; to_ctr <= 32'd0;
      loaded_ok <= 1'b0; err_code <= 16'd0; tid <= 16'd0; blk_expect <= 16'd0;
      bytes_rcvd <= 32'd0; crc32_val <= 32'd0; pkt_cnt <= 32'd0;
      dup_cnt <= 32'd0; err_cnt <= 32'd0; timeout_cnt <= 32'd0;
      retry_cnt <= 8'd0; fname_head <= 32'd0; paylen <= 11'd0; crc_snap <= 1'b0;
      ul_mode <= 1'b0; ul_blk <= 16'd0; ul_nblk <= 16'd0; ul_last <= 9'd0; ul_rlen <= 11'd0;
      cp_busy <= 1'b0; cp_iss_d <= 1'b0; cp_ra <= 13'd0; cp_nis <= 8'd0; cp_wi <= 7'd0;
    end else if (control_abort && (control_owner || control_mode)) begin
      sess <= 1'b0; rrq_sess <= 1'b0; ul_mode <= 1'b0; cp_busy <= 1'b0;
      cp_iss_d <= 1'b0; control_owner <= 1'b0;
      control_file_valid <= 1'b0; loaded_ok <= 1'b0;
      opc<=0; ph<=0; bidx<=0;
      // A stable ACK/ERROR may already belong to the management TX copier.
      // Finish/consume that response even when its control image is aborted;
      // dropping valid underneath MT_WARM/MT_BYTE would strand its TX block.
      if(resp_ack && resp_vld) resp_vld<=1'b0;
    end else begin
      if (control_ack && control_file_valid) begin
        control_file_valid <= 1'b0; control_owner <= 1'b0; loaded_ok <= 1'b0;
      end
      crc_snap <= 1'b0;
      if (crc_snap) crc32_val <= ~crc_acc;     // 晚一拍：此时最后一个字节已入 CRC
      if (resp_ack && resp_vld) begin
        resp_vld <= 1'b0; // packet consumption is not protocol progress
      end

      // ---------------- 卸载块复制：BRAM → rbuf（完成才置 resp_vld）----------------
      cp_iss_d <= cp_iss;
      if (cp_iss) begin cp_ra <= cp_ra + 13'd1; cp_nis <= cp_nis - 8'd1; end
      // 写入走 u_rbuf.wr_en=cp_iss_d；此处只推进写地址与完成标志
      if (cp_iss_d) begin
        cp_wi <= cp_wi + 7'd1;
        if (cp_wi == 7'd127) begin
          cp_busy <= 1'b0; to_ctr <= 32'd0;
          // 只在卸载会话仍是当前响应时放行（其间若被 WRQ/STATUS/ERROR 覆盖则不重放）
          if (rrq_sess && ul_mode && resp_kind == K_DATA) resp_vld <= 1'b1;
        end
      end

      // Timer counts owner wait time. It is reset only in accepted request/data/ACK branches below;
      // response consumption and ignored/foreign packets do not count as protocol progress.
      // P02：同拍消费到 EOP 时超时判决推迟到下一 tick——包处理优先，
      // 避免第 4 次超时与合法末包同拍时把会话误杀（retry/close 竞态）。
      // ---------------- 超时重传 ----------------
      if (tick_us && en && (sess || rrq_sess) && !resp_vld && !cp_busy
          && !(en && in_vld && in_ready && in_eop)) begin
        if (to_ctr >= TIMEOUT_US[31:0]) begin
          to_ctr      <= 32'd0;
          timeout_cnt <= timeout_cnt + 32'd1;
          resp_tid    <= tid;             // Timeout/retry always targets the established peer.
          resp_peer_ip <= session_peer_ip;
          if (retry_cnt >= RETRY_MAX[7:0]) begin
            resp_kind <= K_ERR; resp_err <= 16'd4; resp_len <= 11'd13;
            resp_vld  <= 1'b1;
            sess <= 1'b0; rrq_sess <= 1'b0; retry_cnt <= 8'd0; ul_mode <= 1'b0;
            err_code <= 16'd4; err_cnt <= err_cnt + 32'd1;
          end else begin
            retry_cnt <= retry_cnt + 8'd1;
            resp_vld  <= 1'b1;              // 重发上一条响应
            if (rrq_sess && ul_mode) begin  // 卸载：恢复为当前 DATA 块（rbuf 未变）
              resp_kind <= K_DATA; resp_blk <= ul_blk; resp_len <= ul_rlen;
            end else if (rrq_sess) begin    // STATUS: an intervening foreign-TID ERROR is not the retry.
              resp_kind <= K_DATA; resp_blk <= 16'd1; resp_len <= STAT_LEN[10:0] + 11'd4;
            end else if (sess) begin       // Upload: restore the last accepted block's ACK.
              resp_kind <= K_ACK; resp_blk <= blk_expect - 16'd1; resp_len <= 11'd4;
            end
          end
        end else begin
          to_ctr <= to_ctr + 32'd1;
        end
      end

      // ---------------- 字节流解析 ----------------
      if (en && in_vld && in_ready) begin
        bidx <= in_sop ? 16'd1 : (bidx + 16'd1);
        if (in_sop) begin
          opc <= {8'd0, in_data}; ph <= 2'd0; fn_i <= 5'd0; md_i <= 5'd0;
          fn_m0 <= 1'b1; fn_m1 <= 1'b1; md_ok <= 1'b1; paylen <= 11'd0;
          request_control <= control_mode;
          fn_control <= (CONTROL_FILENAME_LEN>0 && CONTROL_FILENAME_LEN<=32);
          ovf <= 1'b0; fname_head <= 32'd0;
        end else if (bidx == 16'd1) begin
          opc <= {opc[7:0], in_data};
          pkt_cnt <= pkt_cnt + 32'd1;
        end else begin
          case (opc)
            // ---- RRQ / WRQ ----
            16'd1, 16'd2: begin
              if (ph == 2'd0) begin
                if (in_data == 8'h00) begin
                  ph <= 2'd1;
                  if (fn_i == 5'd0) begin fn_m0 <= 1'b0; fn_m1 <= 1'b0; end
                  if (fn_i != 5'd6) begin fn_m0 <= 1'b0; fn_m1 <= 1'b0; end
                  if (fn_i != CONTROL_FILENAME_LEN) fn_control <= 1'b0;
                end else begin
                  if (fn_i < 5'd4)
                    fname_head <= {fname_head[23:0], in_data};
                  if (fn_i > 5'd5 || in_data !== wl0(fn_i[4:0])) fn_m0 <= 1'b0;
                  if (fn_i > 5'd5 || in_data !== wl1(fn_i[4:0])) fn_m1 <= 1'b0;
                  if (fn_i >= CONTROL_FILENAME_LEN || in_data !== control_name_byte(fn_i)) fn_control <= 1'b0;
                  if (fn_i != 8'hFF) fn_i <= fn_i + 8'd1;
                end
              end else if (ph == 2'd1) begin
                if (in_data == 8'h00) begin
                  ph <= 2'd2;
                  if (md_i != 5'd5) md_ok <= 1'b0;
                end else begin
                  if (md_i > 5'd4 || lower(in_data) !== md_ch(md_i)) md_ok <= 1'b0;
                  md_i <= md_i + 5'd1;
                end
              end
            end
            // ---- DATA ----
            16'd3: begin
              if      (bidx == 16'd2) blk_num <= {in_data, 8'd0};
              else if (bidx == 16'd3) blk_num <= {blk_num[15:8], in_data};
              else begin
                // Preserve an over-limit sentinel instead of wrapping on long malformed DATA.
                if (paylen < 11'd513) paylen <= paylen + 11'd1;
                if (sess && same_session_ip && same_session_port && blk_num == blk_expect &&
                    (bidx < 16'd516)) begin // payload bytes only at offsets 0..511
                  wstage <= nd;
                  if (abs_i >= LOAD_BYTES || (control_owner && abs_i>=8192)) ovf <= 1'b1;
                  else if (lane == 2'd3 || in_eop) load_mem[abs_a[14:2]] <= nd;
                  crc_acc <= crc32_byte(crc_acc, in_data);
                end
              end
            end
            // ---- ACK ----
            16'd4: begin
              if      (bidx == 16'd2) blk_num <= {in_data, 8'd0};
              else if (bidx == 16'd3) blk_num <= {blk_num[15:8], in_data};
            end
            // ---- ERROR ----
            16'd5: begin
              if      (bidx == 16'd2) blk_num <= {in_data, 8'd0};
              else if (bidx == 16'd3) blk_num <= {blk_num[15:8], in_data};
            end
            default: ;
          endcase
        end

        // ---------------- 报文结束：给出响应 ----------------
        if (in_eop) begin
          resp_tid <= in_sport;           // Immediate replies, including ERROR(5), go to this request's TID.
          resp_peer_ip <= (BIND_PEER_IP != 0) ? in_srcip : 32'd0;
          if (control_busy && (opc_now==16'd1 || opc_now==16'd2)) begin
            // The completed control image remains owned until parsing/result
            // consumption. New requests cannot replace its memory or peer.
            if (opc_now==16'd2 && request_control && fn_control && md_ok &&
                same_session_ip && same_session_port && sess && bytes_rcvd==0) begin
              resp_kind <= K_ACK; resp_blk <= 0; resp_len <= 4; resp_vld <= 1'b1;
            end else begin
              resp_kind <= K_ERR; resp_err <= 16'd2; resp_len <= 13; resp_vld <= 1'b1;
              err_code <= 16'd2; err_cnt <= err_cnt + 1;
            end
          end else if ((BIND_PEER_IP != 0) && foreign_peer) begin
            // Preserve the owner, image, expected block and retry history.
            // The immediate ERROR goes to the foreign IP+port; retries use
            // session_peer_ip+tid and reconstruct the owner's ACK/DATA.
            resp_kind <= K_ERR; resp_err <= 16'd5; resp_len <= 11'd13;
            resp_vld <= 1'b1; err_code <= 16'd5; err_cnt <= err_cnt + 32'd1;
          end else if (invalid_fixed_packet_length_eop || incomplete_request_eop ||
                       unterminated_error_eop) begin
            if (incomplete_request_eop) begin
              resp_kind <= K_ERR; resp_err <= 16'd4; resp_len <= 11'd13;
              resp_vld <= 1'b1; err_code <= 16'd4; err_cnt <= err_cnt + 32'd1;
            end else if ((sess || rrq_sess) && same_session_ip && same_session_port) begin
              resp_kind <= K_ERR; resp_err <= 16'd4; resp_len <= 11'd13;
              resp_vld <= 1'b1; err_code <= 16'd4; err_cnt <= err_cnt + 32'd1;
              sess <= 1'b0; rrq_sess <= 1'b0; ul_mode <= 1'b0;
            end else begin
              resp_kind <= K_ERR; resp_err <= 16'd5; resp_len <= 11'd13;
              resp_vld <= 1'b1; err_code <= 16'd5; err_cnt <= err_cnt + 32'd1;
            end
          end else begin
            case (opc_now)
            16'd2: begin                                   // WRQ
              if (!md_ok) begin
                resp_kind <= K_ERR; resp_err <= 16'd0; resp_len <= 11'd13;
                resp_vld <= 1'b1; err_code <= 16'd0; err_cnt <= err_cnt + 32'd1;
                sess <= 1'b0;
              end else if (request_control ? !fn_control : !fn_m0) begin
                resp_kind <= K_ERR; resp_err <= 16'd2; resp_len <= 11'd13;
                resp_vld <= 1'b1; err_code <= 16'd2; err_cnt <= err_cnt + 32'd1;
                sess <= 1'b0;
              end else begin
                to_ctr <= 32'd0; retry_cnt <= 8'd0;
                tid <= in_sport;
                session_peer_ip <= (BIND_PEER_IP != 0) ? in_srcip : 32'd0;
                resp_kind <= K_ACK; resp_blk <= 16'd0; resp_len <= 11'd4;
                resp_vld <= 1'b1;
                sess <= 1'b1; rrq_sess <= 1'b0; loaded_ok <= 1'b0; ul_mode <= 1'b0;
                control_owner <= request_control; control_file_valid <= 1'b0;
                blk_expect <= 16'd1; bytes_rcvd <= 32'd0;
                crc_acc <= 32'hFFFF_FFFF; crc32_val <= 32'd0; err_code <= 16'd0;
              end
            end
            16'd1: begin                                   // RRQ
              if (request_control) begin
                // LUR receive mode only accepts its configured WRQ endpoint.
                resp_kind <= K_ERR; resp_err <= 16'd2; resp_len <= 13; resp_vld <= 1'b1;
                err_code <= 16'd2; err_cnt <= err_cnt + 1;
              end else if (!md_ok) begin
                resp_kind <= K_ERR; resp_err <= 16'd0; resp_len <= 11'd13;
                resp_vld <= 1'b1; err_code <= 16'd0; err_cnt <= err_cnt + 32'd1;
              end else if (fn_m1) begin                    // "STATUS" 状态文件
                to_ctr <= 32'd0; retry_cnt <= 8'd0;
                tid <= in_sport;
                session_peer_ip <= (BIND_PEER_IP != 0) ? in_srcip : 32'd0;
                stat_snapshot <= {32'h41363135,32'hAF07_1000,bytes_rcvd,crc32_val,
                                  15'd0,loaded_ok,blk_expect,pkt_cnt,
                                  dup_cnt[15:0],err_cnt[15:0],
                                  timeout_cnt[15:0],8'd0,8'd0};
                resp_kind <= K_DATA; resp_blk <= 16'd1;
                resp_len  <= STAT_LEN[10:0] + 11'd4;
                resp_vld  <= 1'b1; rrq_sess <= 1'b1; sess <= 1'b0; ul_mode <= 1'b0;
              end else if (fn_m0 && loaded_ok) begin       // "UPLOAD" 卸载已加载镜像
                to_ctr <= 32'd0; retry_cnt <= 8'd0;
                tid <= in_sport;
                session_peer_ip <= (BIND_PEER_IP != 0) ? in_srcip : 32'd0;
                rrq_sess <= 1'b1; sess <= 1'b0; ul_mode <= 1'b1;
                ul_nblk <= {9'd0, bytes_rcvd[15:9]} + 16'd1;
                ul_last <= bytes_rcvd[8:0];
                ul_blk  <= 16'd1;
                ul_rlen <= ul_len_of(16'd1, {9'd0, bytes_rcvd[15:9]} + 16'd1, bytes_rcvd[8:0]);
                resp_kind <= K_DATA; resp_blk <= 16'd1; resp_vld <= 1'b0;
                resp_len  <= ul_len_of(16'd1, {9'd0, bytes_rcvd[15:9]} + 16'd1, bytes_rcvd[8:0]);
                cp_busy <= 1'b1; cp_ra <= 13'd0; cp_nis <= 8'd128; cp_wi <= 7'd0; cp_iss_d <= 1'b0;
              end else begin                               // 其它文件 / 尚无镜像
                resp_kind <= K_ERR; resp_err <= 16'd1; resp_len <= 11'd13;
                resp_vld <= 1'b1; err_code <= 16'd1; err_cnt <= err_cnt + 32'd1;
              end
            end
            16'd3: begin                                   // DATA
              if (control_file_valid && same_session_ip && same_session_port &&
                  blk_now==(blk_expect-16'd1) && pay_now==control_last_len) begin
                // Final DATA retransmissions are ACKed while the image is held;
                // sess=0 prevents any duplicate byte from being written again.
                resp_kind <= K_ACK; resp_blk <= blk_now; resp_len <= 4; resp_vld <= 1'b1;
                dup_cnt <= dup_cnt + 1;
              end else if (!sess) begin
                resp_kind <= K_ERR; resp_err <= 16'd5; resp_len <= 11'd13;
                resp_vld <= 1'b1; err_code <= 16'd5; err_cnt <= err_cnt + 32'd1;
              end else if (!same_session_ip || (tid != 16'd0 && tid != in_sport)) begin
                resp_kind <= K_ERR; resp_err <= 16'd5; resp_len <= 11'd13;
                resp_vld <= 1'b1; err_code <= 16'd5; err_cnt <= err_cnt + 32'd1;
              end else if (pay_now > 12'd512) begin
                // RFC 1350 DATA payload is at most 512 bytes; do not commit excess bytes.
                resp_kind <= K_ERR; resp_err <= 16'd4; resp_len <= 11'd13;
                resp_vld <= 1'b1; err_code <= 16'd4; err_cnt <= err_cnt + 32'd1;
                sess <= 1'b0;
              end else if (ovf || data_byte_over_capacity) begin
                resp_kind <= K_ERR; resp_err <= 16'd3; resp_len <= 11'd13;
                resp_vld <= 1'b1; err_code <= 16'd3; err_cnt <= err_cnt + 32'd1;
                sess <= 1'b0;
              end else if (blk_now == blk_expect) begin
                to_ctr <= 32'd0; retry_cnt <= 8'd0;
                resp_kind <= K_ACK; resp_blk <= blk_now; resp_len <= 11'd4;
                resp_vld <= 1'b1;
                blk_expect <= blk_expect + 16'd1;
                bytes_rcvd <= bytes_rcvd + {20'd0, pay_now};
                crc_snap   <= 1'b1;
                if (pay_now < 12'd512) begin               // 载荷 < 512 B（含 0 B）→ 末块
                  loaded_ok <= 1'b1; sess <= 1'b0;
                  if (control_owner) begin
                    control_file_valid <= 1'b1; control_last_len <= pay_now;
                  end
                end
              end else if (blk_now == (blk_expect - 16'd1)) begin
                to_ctr <= 32'd0; retry_cnt <= 8'd0;
                resp_kind <= K_ACK; resp_blk <= blk_now; resp_len <= 11'd4;
                resp_vld <= 1'b1; dup_cnt <= dup_cnt + 32'd1;
              end else begin
                resp_kind <= K_ERR; resp_err <= 16'd0; resp_len <= 11'd13;
                resp_vld <= 1'b1; err_code <= 16'd0; err_cnt <= err_cnt + 32'd1;
                sess <= 1'b0;
              end
            end
            16'd4: begin                                   // ACK（RRQ 方向）
              if (rrq_sess && ul_mode) begin               // 卸载会话
                if (in_sport != tid) begin                 // 外来 TID → ERROR(5)，会话继续
                  resp_kind <= K_ERR; resp_err <= 16'd5; resp_len <= 11'd13;
                  resp_vld <= 1'b1; err_code <= 16'd5; err_cnt <= err_cnt + 32'd1;
                end else if (blk_now == ul_blk) begin
                  to_ctr <= 32'd0; retry_cnt <= 8'd0;
                  if (ul_blk == ul_nblk) begin             // 末块已确认 → 结束
                    rrq_sess <= 1'b0; ul_mode <= 1'b0;
                    resp_kind <= K_NONE; resp_vld <= 1'b0;
                  end else begin                           // 下一块
                    ul_blk  <= ul_blk + 16'd1;
                    ul_rlen <= ul_len_of(ul_blk + 16'd1, ul_nblk, ul_last);
                    resp_kind <= K_DATA; resp_blk <= ul_blk + 16'd1; resp_vld <= 1'b0;
                    resp_len  <= ul_len_of(ul_blk + 16'd1, ul_nblk, ul_last);
                    cp_busy <= 1'b1; cp_ra <= {ul_blk[5:0], 7'd0};
                    cp_nis <= 8'd128; cp_wi <= 7'd0; cp_iss_d <= 1'b0;
                  end
                end else if (blk_now == (ul_blk - 16'd1)) begin
                  dup_cnt <= dup_cnt + 32'd1;              // 重复 ACK：不重发
                end
              end else if (rrq_sess && !ul_mode) begin
                if (!same_session_port) begin
                  // STATUS ACK from an unknown TID: reply to that TID, keep owner session.
                  resp_kind <= K_ERR; resp_err <= 16'd5; resp_len <= 11'd13;
                  resp_vld <= 1'b1; err_code <= 16'd5; err_cnt <= err_cnt + 32'd1;
                end else if (blk_now == 16'd1) begin
                  to_ctr <= 32'd0; retry_cnt <= 8'd0;   // STATUS 会话
                  rrq_sess <= 1'b0; resp_kind <= K_NONE; resp_vld <= 1'b0;
                end
              end
            end
            16'd5: begin                                   // 对端 ERROR
              if(control_owner) begin
                control_owner<=1'b0;control_file_valid<=1'b0;loaded_ok<=1'b0;
              end
              err_code <= blk_now; err_cnt <= err_cnt + 32'd1;
              sess <= 1'b0; rrq_sess <= 1'b0; ul_mode <= 1'b0;
              resp_kind <= K_NONE; resp_vld <= 1'b0;
            end
            default: begin                                 // 含 OACK(6) 等
              resp_kind <= K_ERR; resp_err <= 16'd4; resp_len <= 11'd13;
              resp_vld <= 1'b1; err_code <= 16'd4; err_cnt <= err_cnt + 32'd1;
            end
            endcase
          end
        end
      end
    end
  end
endmodule
