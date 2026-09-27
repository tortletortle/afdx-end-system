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
//   * RRQ(1)  : 仅服务 32 B 的 "STATUS" 状态文件 → DATA(1)（末块）。
//   * ACK(4)  : RRQ 方向收到 ACK(1) → 传输完成。
//   * ERROR(5): 记录对端错误码并终止会话。
//   * 超时重传：TIMEOUT_US 无后续报文则重发上一条响应，
//               retry_cnt > RETRY_MAX → 本地 ERROR(4) 并终止。
//
// 覆盖边界（如实标注，未实现/不宣称）：
//   - RRQ 只服务固定的 32 B STATUS 文件，不支持从 32 KB 加载区回读任意文件；
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
                                                         stat_b(resp_rd_addr - 11'd4)) :
                              8'h00;

  always @(posedge clk) begin
    if (host_rd) host_rdata <= load_mem[host_addr[12:0]];
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
    end else begin
      crc_snap <= 1'b0;
      if (crc_snap) crc32_val <= ~crc_acc;     // 晚一拍：此时最后一个字节已入 CRC
      if (resp_ack && resp_vld) begin
        resp_vld <= 1'b0;
        to_ctr   <= 32'd0;
      end

      // ---------------- 超时重传 ----------------
      if (tick_us && en && (sess || rrq_sess) && !resp_vld) begin
        if (to_ctr >= TIMEOUT_US[31:0]) begin
          to_ctr      <= 32'd0;
          timeout_cnt <= timeout_cnt + 32'd1;
          if (retry_cnt >= RETRY_MAX[7:0]) begin
            resp_kind <= K_ERR; resp_err <= 16'd4; resp_len <= 11'd13;
            resp_vld  <= 1'b1;
            sess <= 1'b0; rrq_sess <= 1'b0; retry_cnt <= 8'd0;
            err_code <= 16'd4; err_cnt <= err_cnt + 32'd1;
          end else begin
            retry_cnt <= retry_cnt + 8'd1;
            resp_vld  <= 1'b1;              // 重发上一条响应
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
                sess <= 1'b1; rrq_sess <= 1'b0; loaded_ok <= 1'b0;
                blk_expect <= 16'd1; bytes_rcvd <= 32'd0;
                crc_acc <= 32'hFFFF_FFFF; crc32_val <= 32'd0; err_code <= 16'd0;
              end
            end
            16'd1: begin                                   // RRQ
              tid <= in_sport;
              if (!md_ok) begin
                resp_kind <= K_ERR; resp_err <= 16'd0; resp_len <= 11'd13;
                resp_vld <= 1'b1; err_code <= 16'd0; err_cnt <= err_cnt + 32'd1;
              end else if (!fn_m1) begin                   // 只有 "STATUS" 可读
                resp_kind <= K_ERR; resp_err <= 16'd1; resp_len <= 11'd13;
                resp_vld <= 1'b1; err_code <= 16'd1; err_cnt <= err_cnt + 32'd1;
              end else begin
                resp_kind <= K_DATA; resp_blk <= 16'd1;
                resp_len  <= STAT_LEN[10:0] + 11'd4;
                resp_vld  <= 1'b1; rrq_sess <= 1'b1; sess <= 1'b0;
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
              end else if (blk_num == blk_expect) begin
                resp_kind <= K_ACK; resp_blk <= blk_num; resp_len <= 11'd4;
                resp_vld <= 1'b1;
                blk_expect <= blk_expect + 16'd1;
                bytes_rcvd <= bytes_rcvd + {21'd0, paylen} + 32'd1;
                crc_snap   <= 1'b1;
                if (paylen < 11'd511) begin                // 载荷 < 512 B → 末块
                  loaded_ok <= 1'b1; sess <= 1'b0;
                end
              end else if (blk_num == (blk_expect - 16'd1)) begin
                resp_kind <= K_ACK; resp_blk <= blk_num; resp_len <= 11'd4;
                resp_vld <= 1'b1; dup_cnt <= dup_cnt + 32'd1;
              end else begin
                resp_kind <= K_ERR; resp_err <= 16'd0; resp_len <= 11'd13;
                resp_vld <= 1'b1; err_code <= 16'd0; err_cnt <= err_cnt + 32'd1;
                sess <= 1'b0;
              end
            end
            16'd4: begin                                   // ACK（RRQ 方向）
              if (rrq_sess && blk_num == 16'd1) begin
                rrq_sess <= 1'b0; resp_kind <= K_NONE; resp_vld <= 1'b0;
              end
            end
            16'd5: begin                                   // 对端 ERROR
              err_code <= blk_num; err_cnt <= err_cnt + 32'd1;
              sess <= 1'b0; rrq_sess <= 1'b0;
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
