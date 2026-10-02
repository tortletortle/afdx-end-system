// =====================================================================
// a615a_tftp.v —— ARINC 615A 数据加载 TFTP 引擎（RFC 1350 子集）
// 设计书 §7.17。continue4 实现（原第 0 周空壳）。
//
// 已实现（真实协议闭环）：
//   * WRQ(2)  : 文件名白名单 + mode 必须为 octet，通过→ACK(0) 开会话；
//               白名单不中→ERROR(2) 访问违规；mode 非 octet→ERROR(0)。
//   * DATA(3) : 块号 == 期望 → 写入加载区、累计字节与 CRC32、ACK(blk)；
//               块号 == 期望-1 → 重复块，只补发 ACK，不重复写（dup_cnt）；
//               其它块号 → ERROR(0)；TID(源端口) 不符 → ERROR(5)。
//               末块（载荷<512 B）→ loaded_ok=1，会话结束。
//               超出加载区容量 → ERROR(3) 磁盘满。
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
//   * step3 修复（20260928）：块号低字节在 bidx==3 才写入 blk_num，而 4 字节
//     报文（ACK / 0 字节 DATA / ERROR 头）的 EOP 恰在同一拍判定，旧实现读到的
//     是陈旧块号：单元级 4 B ACK(1) 结束不了 RRQ 会话（之后超时重发）、0 字节
//     末块被判块号错回 ERROR(0)、字节计数 paylen+1 对空块多记 1。现 EOP 判定一律
//     用 blk_now（bidx==3 时并入当拍 in_data）与 pay_now（精确载荷字节数）。
//     顶层上线的 ACK 补零到 8 B（AFDX UDP 载荷 >=8 B），EOP 在 bidx=7，不受影响。
//   * 卸载数据通路：加载区是 32 KB 同步读 BRAM，而 resp_byte 须对 resp_rd_addr
//     组合有效（顶层 0xAC27 字节口当拍采样）。每发一块前先把该 512 B 从 BRAM
//     复制到 128 字响应缓冲 rbuf（约 130 拍），复制完成才置 resp_vld。复制与
//     主机读口分时复用同一 BRAM 读端口（主机优先），不新增读端口。
//
// 覆盖边界（如实标注，未实现/不宣称）：
//   - RRQ 只服务 "STATUS" 与 "UPLOAD"（最近一次加载的镜像），无文件系统/多文件；
//   - 发给外来 TID 的 ERROR(5) 只放进同一响应口，本模块不单独导出外来端口号；
//   - 不支持 OACK/blksize/tsize/timeout 选项协商（RFC 2347/2348 一律忽略）；
//   - 不做 A615-A 的上层协议（Find/Info/载荷签名校验），只做 TFTP 传输层；
//   - CRC32 为标准反射 CRC-32（poly EDB88320，初值 FFFFFFFF，末尾取反），
//     仅覆盖 DATA 载荷字节，不含 TFTP 头。
// =====================================================================
`timescale 1 ns / 1 ps
module a615a_tftp #(
  parameter integer LOAD_WORDS = 8192,          // 32 KB 加载区
  parameter integer RETRY_MAX  = 3,
  parameter integer TIMEOUT_US = 5000
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
  input  wire        resp_ack,
  input  wire [10:0] resp_rd_addr,
  output wire [7:0]  resp_byte,
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
  output wire [3:0]  state_o
);
  localparam [1:0] K_NONE = 2'd0, K_ACK = 2'd1, K_ERR = 2'd2, K_DATA = 2'd3;
  localparam integer LOAD_BYTES = LOAD_WORDS * 4;
  localparam integer STAT_LEN   = 32;

  reg [31:0] load_mem [0:LOAD_WORDS-1];

  reg [15:0] opc, blk_num, bidx;
  reg [1:0]  ph;                 // RRQ/WRQ: 0=filename 1=mode 2=tail
  reg [4:0]  fn_i, md_i;
  reg        fn_m0, fn_m1, md_ok;
  reg        sess, rrq_sess, ovf;
  reg [1:0]  resp_kind;
  reg [15:0] resp_blk, resp_err;
  reg [31:0] wstage, nd;
  reg [31:0] crc_acc;
  reg [31:0] to_ctr;
  integer    abs_i;
  reg [16:0] abs_a;
  reg [1:0]  lane;
  reg [10:0] paylen;
  reg        crc_snap;          // in_eop 当拍 crc_acc 还没吃进最后一个字节

  // ---- step3：EOP 当拍的完整块号 / 精确载荷字节数 ----
  wire [15:0] blk_now = (bidx == 16'd3) ? {blk_num[15:8], in_data} : blk_num;
  wire [11:0] pay_now = (bidx >= 16'd4) ? ({1'b0, paylen} + 12'd1) : 12'd0;

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
  reg [31:0] rbuf [0:127];
  wire       cp_iss = cp_busy && (cp_nis != 8'd0) && !host_rd;
  wire [12:0] mem_ra = host_rd ? host_addr[12:0] : cp_ra;
  wire [10:0] ra4 = resp_rd_addr - 11'd4;
  wire [31:0] rbw = rbuf[ra4[8:2]];
  wire [7:0]  rb_b = (ra4[1:0] == 2'd0) ? rbw[31:24] : (ra4[1:0] == 2'd1) ? rbw[23:16] :
                     (ra4[1:0] == 2'd2) ? rbw[15:8]  : rbw[7:0];
  function [10:0] ul_len_of;
    input [15:0] b; input [15:0] nb; input [8:0] last;
    begin ul_len_of = (b == nb) ? ({2'd0, last} + 11'd4) : 11'd516; end
  endfunction

  assign in_ready = 1'b1;        // 引擎可按线速吸收，不产生反压
  assign state_o  = {rrq_sess, sess, resp_kind};

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
  // ---- RRQ 服务的 32 B STATUS 文件 ----
  function [7:0] stat_b; input [10:0] k;
    reg [31:0] w;
    begin
      case (k[4:2])
        3'd0: w = 32'h41363135;                                 // "A615"
        3'd1: w = 32'hAF07_1000;                                // ES ID
        3'd2: w = bytes_rcvd;
        3'd3: w = crc32_val;
        3'd4: w = {15'd0, loaded_ok, blk_expect};
        3'd5: w = pkt_cnt;
        3'd6: w = {dup_cnt[15:0], err_cnt[15:0]};
        default: w = {timeout_cnt[15:0], retry_cnt, 8'd0};
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

  always @(posedge clk) begin
    if (rst_sync) begin
      opc <= 16'd0; blk_num <= 16'd0; bidx <= 16'd0; ph <= 2'd0;
      fn_i <= 5'd0; md_i <= 5'd0; fn_m0 <= 1'b0; fn_m1 <= 1'b0; md_ok <= 1'b0;
      sess <= 1'b0; rrq_sess <= 1'b0; ovf <= 1'b0;
      resp_kind <= K_NONE; resp_blk <= 16'd0; resp_err <= 16'd0;
      resp_vld <= 1'b0; resp_len <= 11'd0;
      wstage <= 32'd0; crc_acc <= 32'hFFFF_FFFF; to_ctr <= 32'd0;
      loaded_ok <= 1'b0; err_code <= 16'd0; tid <= 16'd0; blk_expect <= 16'd0;
      bytes_rcvd <= 32'd0; crc32_val <= 32'd0; pkt_cnt <= 32'd0;
      dup_cnt <= 32'd0; err_cnt <= 32'd0; timeout_cnt <= 32'd0;
      retry_cnt <= 8'd0; fname_head <= 32'd0; paylen <= 11'd0; crc_snap <= 1'b0;
      ul_mode <= 1'b0; ul_blk <= 16'd0; ul_nblk <= 16'd0; ul_last <= 9'd0; ul_rlen <= 11'd0;
      cp_busy <= 1'b0; cp_iss_d <= 1'b0; cp_ra <= 13'd0; cp_nis <= 8'd0; cp_wi <= 7'd0;
    end else begin
      crc_snap <= 1'b0;
      if (crc_snap) crc32_val <= ~crc_acc;     // 晚一拍：此时最后一个字节已入 CRC
      if (resp_ack && resp_vld) begin
        resp_vld <= 1'b0;
        to_ctr   <= 32'd0;
      end

      // ---------------- 卸载块复制：BRAM → rbuf（完成才置 resp_vld）----------------
      cp_iss_d <= cp_iss;
      if (cp_iss) begin cp_ra <= cp_ra + 13'd1; cp_nis <= cp_nis - 8'd1; end
      if (cp_iss_d) begin
        rbuf[cp_wi] <= host_rdata;
        cp_wi <= cp_wi + 7'd1;
        if (cp_wi == 7'd127) begin
          cp_busy <= 1'b0; to_ctr <= 32'd0;
          // 只在卸载会话仍是当前响应时放行（其间若被 WRQ/STATUS/ERROR 覆盖则不重放）
          if (rrq_sess && ul_mode && resp_kind == K_DATA) resp_vld <= 1'b1;
        end
      end

      // ---------------- 超时重传 ----------------
      if (tick_us && en && (sess || rrq_sess) && !resp_vld && !cp_busy) begin
        if (to_ctr >= TIMEOUT_US[31:0]) begin
          to_ctr      <= 32'd0;
          timeout_cnt <= timeout_cnt + 32'd1;
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
                end else begin
                  if (fn_i < 5'd4)
                    fname_head <= {fname_head[23:0], in_data};
                  if (fn_i > 5'd5 || in_data !== wl0(fn_i)) fn_m0 <= 1'b0;
                  if (fn_i > 5'd5 || in_data !== wl1(fn_i)) fn_m1 <= 1'b0;
                  fn_i <= fn_i + 5'd1;
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
                paylen <= paylen + 11'd1;
                if (blk_num == blk_expect && (tid == 16'd0 || tid == in_sport)) begin
                  abs_i = (blk_num - 1) * 512 + (bidx - 16'd4);
                  abs_a = abs_i[16:0];
                  lane  = abs_a[1:0];
                  case (lane)
                    2'd0: nd = {in_data, 24'd0};
                    2'd1: nd = {wstage[31:24], in_data, 16'd0};
                    2'd2: nd = {wstage[31:16], in_data, 8'd0};
                    default: nd = {wstage[31:8], in_data};
                  endcase
                  wstage <= nd;
                  if (abs_i >= LOAD_BYTES) ovf <= 1'b1;
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
          to_ctr <= 32'd0; retry_cnt <= 8'd0;
          case (opc)
            16'd2: begin                                   // WRQ
              tid <= in_sport;
              if (!md_ok) begin
                resp_kind <= K_ERR; resp_err <= 16'd0; resp_len <= 11'd13;
                resp_vld <= 1'b1; err_code <= 16'd0; err_cnt <= err_cnt + 32'd1;
                sess <= 1'b0;
              end else if (!fn_m0) begin                   // 只有 "UPLOAD" 可写
                resp_kind <= K_ERR; resp_err <= 16'd2; resp_len <= 11'd13;
                resp_vld <= 1'b1; err_code <= 16'd2; err_cnt <= err_cnt + 32'd1;
                sess <= 1'b0;
              end else begin
                resp_kind <= K_ACK; resp_blk <= 16'd0; resp_len <= 11'd4;
                resp_vld <= 1'b1;
                sess <= 1'b1; rrq_sess <= 1'b0; loaded_ok <= 1'b0; ul_mode <= 1'b0;
                blk_expect <= 16'd1; bytes_rcvd <= 32'd0;
                crc_acc <= 32'hFFFF_FFFF; crc32_val <= 32'd0; err_code <= 16'd0;
              end
            end
            16'd1: begin                                   // RRQ
              tid <= in_sport;
              if (!md_ok) begin
                resp_kind <= K_ERR; resp_err <= 16'd0; resp_len <= 11'd13;
                resp_vld <= 1'b1; err_code <= 16'd0; err_cnt <= err_cnt + 32'd1;
              end else if (fn_m1) begin                    // "STATUS" 状态文件
                resp_kind <= K_DATA; resp_blk <= 16'd1;
                resp_len  <= STAT_LEN[10:0] + 11'd4;
                resp_vld  <= 1'b1; rrq_sess <= 1'b1; sess <= 1'b0; ul_mode <= 1'b0;
              end else if (fn_m0 && loaded_ok) begin       // "UPLOAD" 卸载已加载镜像
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
              if (!sess) begin
                resp_kind <= K_ERR; resp_err <= 16'd5; resp_len <= 11'd13;
                resp_vld <= 1'b1; err_code <= 16'd5; err_cnt <= err_cnt + 32'd1;
              end else if (tid != 16'd0 && tid != in_sport) begin
                resp_kind <= K_ERR; resp_err <= 16'd5; resp_len <= 11'd13;
                resp_vld <= 1'b1; err_code <= 16'd5; err_cnt <= err_cnt + 32'd1;
              end else if (ovf) begin
                resp_kind <= K_ERR; resp_err <= 16'd3; resp_len <= 11'd13;
                resp_vld <= 1'b1; err_code <= 16'd3; err_cnt <= err_cnt + 32'd1;
                sess <= 1'b0;
              end else if (blk_now == blk_expect) begin
                resp_kind <= K_ACK; resp_blk <= blk_now; resp_len <= 11'd4;
                resp_vld <= 1'b1;
                blk_expect <= blk_expect + 16'd1;
                bytes_rcvd <= bytes_rcvd + {20'd0, pay_now};
                crc_snap   <= 1'b1;
                if (pay_now < 12'd512) begin               // 载荷 < 512 B（含 0 B）→ 末块
                  loaded_ok <= 1'b1; sess <= 1'b0;
                end
              end else if (blk_now == (blk_expect - 16'd1)) begin
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
              end else if (rrq_sess && blk_now == 16'd1) begin   // STATUS 会话
                rrq_sess <= 1'b0; resp_kind <= K_NONE; resp_vld <= 1'b0;
              end
            end
            16'd5: begin                                   // 对端 ERROR
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
endmodule
