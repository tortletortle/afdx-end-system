// =====================================================================
// mac_rx_if.v — RX 字节入口：流式 FCS/IP/UDP 校验，坏帧不放行 (O-04/O-05)
// 阶段范围 T08a：独立接收入口；外部提供 RX 块并按 byte enable 写 PMEM。
// 尚未接到 AFDX_top 的 RX 块池/PMEM 仲裁、flt/lookup/IC/RM/端口。
// IF_MODE=0：rx_ready 为整帧包络，rx_valid 为字节脉冲；
// IF_MODE=1：rx_valid 为逐拍 DV，首次下降沿结束帧，rx_ready 忽略。
// 只有整帧校验通过且最后一笔 PMEM 写已提交后才发 desc_vld。
// 坏帧仍可能暂写 RX 块，但释放该块，绝不产生描述符。
// =====================================================================
`timescale 1 ns / 1 ps
module mac_rx_if #(
  parameter integer IF_MODE = 0,
  parameter integer FCS_MODE = 2,
  parameter integer PHY_ERROR_EN = 0,
  parameter integer MAX_FRAME = 1518,
  parameter integer NET_ID = 0                // 0=A，1=B；仅作为描述符元数据
) (
  input  wire        clk,
  input  wire        rst_sync,
  input  wire        enable,
  input  wire        udp_csum_en,
  input  wire [23:0] tb_us,
  input  wire [7:0]  rx_data,
  input  wire        rx_valid,
  input  wire        rx_ready,
  input  wire        rx_frame_error,
  input  wire [3:0]  rx_blk,
  input  wire        rx_blk_valid,
  output wire        frame_busy,     // 首字节取块用；仅描述当前网入口是否处于帧内
  output reg         pmem_wr_en,
  output reg  [12:0] pmem_wr_addr,
  output reg  [31:0] pmem_wr_data,
  output reg  [3:0]  pmem_wr_be,       // [3] 写 [31:24]，依次至 [0] [7:0]
  output reg         blk_release,     // 坏帧归还当前 RX 块；好帧由后级归还
  output reg  [3:0]  blk_release_id,
  output reg         desc_vld,        // 仅好帧、尾字写口完成后发 1 拍
  output reg  [3:0]  desc_blk,
  output reg  [10:0] desc_len,        // 含 FCS 的 DMAC..FCS 总长
  output reg  [23:0] desc_ts,         // 首字节时间戳
  output reg  [15:0] desc_vlid,
  output reg  [7:0]  desc_sn,
  output reg         desc_net,
  output reg  [2:0]  desc_ifid,
  output reg  [31:0] desc_src_ip,
  output reg  [31:0] desc_dst_ip,
  output reg  [15:0] desc_sport,
  output reg  [15:0] desc_dport,
  output reg  [10:0] desc_plen,        // v0.5.16: UDP 载荷长 L = udp_len-8（首部已核对）
  // P08：分片元数据（仅在 desc_vld 拍有效）
  output reg  [15:0] desc_ident,       // IP Identification
  output reg         desc_mf,          // More Fragments
  output reg         desc_df,          // Don't Fragment
  output reg  [12:0] desc_frag_off,    // 字节偏移（=wire 字段 ×8）
  output reg         desc_is_frag,     // 1 = 该帧为分片（MF=1 或 offset≠0）
  output reg         desc_first_frag,  // 1 = 首片（offset==0），携带 UDP 头
  output reg         frame_err,       // 坏帧一次性脉冲；不更新任何 IC/RM 状态
  output reg         crc_err,         // FCS 失败脉冲（含与长度错重叠时）
  output reg  [7:0]  drop_reason,     // 01 CRC,02 IP,04 UDP,08 HDR,10 LEN,20 PAD,40 NO_BLK,80 ABORT
  output reg  [15:0] good_cnt,
  output reg  [15:0] drop_cnt,
  output reg  [15:0] disabled_cnt
);
  localparam [31:0] CRC_RESIDUE = 32'hDEBB_20E3; // 线序低字节先发的完整帧原始 CRC 余数
  localparam integer FCS_BYTES = (FCS_MODE >= 1) ? 4 : 0;
  localparam integer FRAME_MIN = 60 + FCS_BYTES;
  localparam integer FRAME_MAX = MAX_FRAME - 4 + FCS_BYTES;

  function [31:0] crc_step;
    input [31:0] state;
    input [7:0]  data;
    reg   [31:0] x;
    integer i;
    begin
      x = state ^ {24'd0,data};
      for (i=0; i<8; i=i+1) x = x[0] ? ((x >> 1) ^ 32'hEDB8_8320) : (x >> 1);
      crc_step = x;
    end
  endfunction
  function [15:0] fold32;
    input [31:0] s;
    reg [16:0] a,b;
    begin
      a = {1'b0,s[15:0]} + {1'b0,s[31:16]};
      b = {1'b0,a[15:0]} + a[16];
      fold32 = b[15:0];
    end
  endfunction

  reg in_frame, blk_vld_q, csum_on, hdr_bad, pad_bad, pending_desc;
  assign frame_busy = in_frame;
  reg [3:0] blk_q;
  reg [11:0] count;                      // 已接收字节数，最大帧 1518
  reg [23:0] ts_q;
  reg [31:0] crc_q, ip_sum, pseudo_sum, udp_sum, pack;
  reg [7:0] ip_hi, pseudo_hi, udp_hi, ip_len_hi, udp_len_hi;
  reg [15:0] ip_len, udp_len, udp_check;
  reg [15:0] vlid_q, sport_q, dport_q;
  reg [2:0]  ifid_q;
  reg [31:0] src_ip_q, dst_ip_q;
  // P08：IPv4 分片字段（单位：字节偏移，已按 8 字节单位左移 3 位）
  reg [15:0] ident_q;
  reg [7:0]  ident_hi;
  reg [4:0]  frag_off_hi;
  reg        mf_q;          // More Fragments
  reg        df_q;          // Don't Fragment
  reg [15:0] frag_off_q;    // 字节偏移 = wire_offset(13b, 8B 单位) << 3
  reg [7:0]  tail0,tail1,tail2,tail3,tail4; // 最近 5 B，tail0=FCS 前 SN
  reg disabled_seen;
  reg phy_bad;

  wire byte_in = rx_valid && ((IF_MODE != 0) || rx_ready);
  wire frame_end = in_frame && ((IF_MODE != 0) ? !rx_valid : !rx_ready);
  wire [15:0] in_zero16 = 16'd0;
  wire [11:0] payload_len = {1'b0,udp_len} - 12'd8;
  wire [11:0] pad_len = (payload_len < 12'd17) ? 12'd17-payload_len : 12'd0;
  wire [12:0] expected_len = 13'd43 + {1'b0,payload_len} + {1'b0,pad_len} + FCS_BYTES;
  // ---- P08：分片感知的长度/校验分支 ----
  // AFDX 单帧布局：ETH14 IP20 UDP8 | payload | pad(补到 17) | SN(1) | FCS(4)。
  // IPv4 分片仍是独立 AFDX 帧，仍带 SN/FCS；首片 UDP checksum 要等完整重组后验证。
  //   * is_frag_any（含首片：MF=1 或 offset≠0）→ 长度只按 IP Total Length 与线长核对；
  //   * 每片均有 IP 头并单独校验其 checksum；
  //   * 只有首片携带 UDP 头，完整 UDP checksum 需在重组后验证；
  //   * 非分片帧保持 v0.5.16 原有单帧语义不变。
  wire is_later_frag = (frag_off_q != 16'd0);
  wire is_first_frag = (frag_off_q == 16'd0) && mf_q;
  wire is_frag_any   = is_first_frag || is_later_frag;
  // 分片本片载荷长（供重组阶段的位图覆盖计算，单位字节）：
  //   IP 载荷 = ip_len - 20（IP 头）；首片还含 UDP 头 8，故再减 8。
  //   ip_len 可能为 0（未采到），此时钳为 0，不影响上游长度拒绝（len_bad_frag）。
  wire [11:0] ip_pay_12 = (ip_len >= 16'd20) ? (ip_len[11:0] - 12'd20) : 12'd0;
  wire [11:0] frag_payload_len = is_first_frag ? ((ip_pay_12 >= 12'd8) ? (ip_pay_12 - 12'd8) : 12'd0)
                                               : ip_pay_12;
  // The first fragment's IP payload contains the 8-byte UDP header, so 17
  // application bytes plus that header reach Ethernet's 46-byte MAC-data
  // minimum. Later fragments have no UDP header and need 25 fragment bytes.
  // AFDX SN is immediately before FCS, so the pad precedes SN.
  wire [11:0] frag_payload_min = is_first_frag ? 12'd17 : 12'd25;
  wire [11:0] frag_pad_len = (frag_payload_len < frag_payload_min) ?
                             (frag_payload_min-frag_payload_len) : 12'd0;
  wire len_bad_frag = (count < FRAME_MIN) || (count > FRAME_MAX) ||
                      (ip_len < 16'd21) || (ip_len > 16'd1480) ||
                      ({1'b0,count} != (13'd15 + {1'b0,ip_len} +
                                        {1'b0,frag_pad_len} + FCS_BYTES[12:0]));
  wire len_bad_single = (count < FRAME_MIN) || (count > FRAME_MAX) ||
                 // AFDX data may contain one payload byte. Ethernet padding is
                 // checked separately and must not raise this UDP minimum.
                 (udp_len < 16'd9) || (udp_len > 16'd1479) ||
                 (ip_len != udp_len + 16'd20) || ({1'b0,count} != expected_len);
  wire len_bad = is_frag_any ? len_bad_frag : len_bad_single;
  wire fcs_bad = (FCS_MODE >= 1) && (crc_q != CRC_RESIDUE);
  // 每片都带 IP 头，必须各自通过 IP checksum。
  wire ip_bad  = (fold32(ip_sum) != 16'hFFFF);
  // UDP 头只存在于单帧与首片；分片 UDP checksum 必须待完整 datagram 重组。
  // UDP checksum spans the whole datagram, so a first fragment cannot be
  // checked against its own bytes. Reassembly must verify it before delivery.
  wire udp_bad = is_frag_any ? 1'b0 :
                 (csum_on && ((udp_check == 16'd0) ||
                  (fold32(pseudo_sum + udp_sum + 32'd17 + {16'd0,udp_len} +
                          (udp_len[0] ? {16'd0,udp_hi,8'd0} : 32'd0)) != 16'hFFFF)));
  wire [7:0] reason_now = len_bad ? 8'h10 :
                          !blk_vld_q ? 8'h40 :
                          phy_bad ? 8'h80 :
                          (IF_MODE == 0 && rx_valid) ? 8'h80 :
                          fcs_bad ? 8'h01 :
                          hdr_bad ? 8'h08 :
                          ip_bad ? 8'h02 :
                          udp_bad ? 8'h04 :
                          pad_bad ? 8'h20 : 8'h00;

  always @(posedge clk) begin
    if (rst_sync) begin
      in_frame <= 1'b0; blk_vld_q <= 1'b0; csum_on <= 1'b0;
      hdr_bad <= 1'b0; pad_bad <= 1'b0;
      phy_bad <= 1'b0;
      pending_desc <= 1'b0; disabled_seen <= 1'b0;
      blk_q <= 4'd0; count <= 12'd0; ts_q <= 24'd0;
      crc_q <= 32'hFFFF_FFFF; ip_sum <= 32'd0; pseudo_sum <= 32'd0;
      udp_sum <= 32'd0; pack <= 32'd0;
      ip_hi <= 8'd0; pseudo_hi <= 8'd0; udp_hi <= 8'd0;
      ip_len_hi <= 8'd0; udp_len_hi <= 8'd0;
      ip_len <= 16'd0; udp_len <= 16'd0; udp_check <= 16'd0;
      vlid_q <= 16'd0; sport_q <= 16'd0; dport_q <= 16'd0; ifid_q <= 3'd0;
      src_ip_q <= 32'd0; dst_ip_q <= 32'd0;
      tail0 <= 8'd0; tail1 <= 8'd0; tail2 <= 8'd0; tail3 <= 8'd0; tail4 <= 8'd0;
      pmem_wr_en <= 1'b0; pmem_wr_addr <= 13'd0; pmem_wr_data <= 32'd0; pmem_wr_be <= 4'd0;
      blk_release <= 1'b0; blk_release_id <= 4'd0;
      desc_vld <= 1'b0; desc_blk <= 4'd0; desc_len <= 11'd0; desc_ts <= 24'd0;
      desc_vlid <= 16'd0; desc_sn <= 8'd0; desc_net <= 1'b0; desc_ifid <= 3'd0;
      desc_src_ip <= 32'd0; desc_dst_ip <= 32'd0; desc_sport <= 16'd0; desc_dport <= 16'd0; desc_plen <= 11'd0;
      desc_ident <= 16'd0; desc_mf <= 1'b0; desc_df <= 1'b0;
      desc_frag_off <= 13'd0; desc_is_frag <= 1'b0; desc_first_frag <= 1'b1;
      ident_q <= 16'd0; ident_hi <= 8'd0; frag_off_hi <= 5'd0;
      mf_q <= 1'b0; df_q <= 1'b0; frag_off_q <= 16'd0;
      frame_err <= 1'b0; crc_err <= 1'b0; drop_reason <= 8'd0;
      good_cnt <= 16'd0; drop_cnt <= 16'd0; disabled_cnt <= 16'd0;
    end else begin
      pmem_wr_en <= 1'b0; blk_release <= 1'b0; desc_vld <= pending_desc;
      pending_desc <= 1'b0; frame_err <= 1'b0; crc_err <= 1'b0;
      // pending_desc 在上一拍帧尾置位；到本拍末字 PMEM 写已生效，下一拍下游才看到 desc_vld。
      if ((IF_MODE != 0 && !rx_valid) || (IF_MODE == 0 && !rx_ready)) disabled_seen <= 1'b0;
      if (!enable && !in_frame && byte_in && !disabled_seen) begin
        disabled_cnt <= disabled_cnt + 16'd1; disabled_seen <= 1'b1;
      end
      if (in_frame && !enable) begin
        in_frame <= 1'b0;
        frame_err <= 1'b1; drop_reason <= 8'h80; drop_cnt <= drop_cnt + 16'd1;
        blk_release <= blk_vld_q; blk_release_id <= blk_q;
      end else if (frame_end) begin
        in_frame <= 1'b0;
        crc_err <= fcs_bad;
        if (count[1:0] != 0 && blk_vld_q && count <= FRAME_MAX) begin
          // 帧尾不足 4 B：按高字节优先写，低位保留（由外部 byte enable 存储体处理）。
          pmem_wr_en <= 1'b1;
          pmem_wr_addr <= {blk_q,count[10:2]};
          pmem_wr_data <= pack;
          case (count[1:0])
            2'd1: pmem_wr_be <= 4'b1000;
            2'd2: pmem_wr_be <= 4'b1100;
            default: pmem_wr_be <= 4'b1110;
          endcase
        end
        if (reason_now == 0) begin
          good_cnt <= good_cnt + 16'd1;
          pending_desc <= 1'b1;
          desc_blk <= blk_q; desc_len <= count[10:0]; desc_ts <= ts_q;
          desc_vlid <= vlid_q; desc_sn <= (FCS_MODE>=1) ? tail0 : tail4;
          desc_net <= NET_ID[0]; desc_ifid <= ifid_q;
          desc_src_ip <= src_ip_q; desc_dst_ip <= dst_ip_q;
          // UDP 头（端口字段）只存在于单帧与首片；后续片的字节 34~41 是载荷，
          // 不能写入描述符端口字段（否则解析层用垃圾端口号做 DPORT 匹配）。
          desc_sport <= (is_later_frag ? in_zero16 : sport_q);
          desc_dport <= (is_later_frag ? in_zero16 : dport_q);
          // 载荷长：单帧/首片 = UDP 载荷（udp_len-8）；后续片无 UDP 头
          // （字节 38/39 是载荷而非 UDP 长度字段），必须按 IP Total Length 推算
          //     IP 载荷 = ip_len - 20；首片再减 UDP 头 8。
          desc_plen <= is_frag_any ? frag_payload_len[10:0] : payload_len[10:0];
          // P08：分片元数据。非首片无 UDP 头，载荷长按 IP 长度推算。
          desc_ident <= ident_q;
          desc_mf <= mf_q;
          desc_df <= df_q;
          desc_frag_off <= frag_off_q[15:3];
          desc_is_frag <= is_frag_any;
          desc_first_frag <= (frag_off_q == 16'd0);
        end else begin
          drop_cnt <= drop_cnt + 16'd1; frame_err <= 1'b1; drop_reason <= reason_now;
          blk_release <= blk_vld_q; blk_release_id <= blk_q;
        end
      end else if (enable && byte_in) begin
        if (!in_frame) begin
          phy_bad <= (PHY_ERROR_EN != 0) && rx_frame_error;
          in_frame <= 1'b1; blk_q <= rx_blk; blk_vld_q <= rx_blk_valid;
          csum_on <= udp_csum_en; ts_q <= tb_us; count <= 12'd1;
          crc_q <= crc_step(32'hFFFF_FFFF,rx_data);
          ip_sum <= 32'd0; pseudo_sum <= 32'd0; udp_sum <= 32'd0;
          ip_len <= 16'd0; udp_len <= 16'd0; udp_check <= 16'd0;
          vlid_q <= 16'd0; sport_q <= 16'd0; dport_q <= 16'd0;
          src_ip_q <= 32'd0; dst_ip_q <= 32'd0; ifid_q <= 3'd0;
          ip_hi <= 8'd0; pseudo_hi <= 8'd0; udp_hi <= 8'd0;
          ip_len_hi <= 8'd0; udp_len_hi <= 8'd0;
          hdr_bad <= (rx_data != 8'h03); pad_bad <= 1'b0;
          pack <= {rx_data,24'd0};
          tail0 <= 8'd0; tail1 <= 8'd0; tail2 <= 8'd0; tail3 <= 8'd0; tail4 <= rx_data;
        end else begin
          if (PHY_ERROR_EN != 0 && rx_frame_error) phy_bad <= 1'b1;
          if (count < 12'd2047) count <= count + 12'd1;
          crc_q <= crc_step(crc_q,rx_data);
          tail0 <= tail1; tail1 <= tail2; tail2 <= tail3; tail3 <= tail4; tail4 <= rx_data;
          if (count <= FRAME_MAX && blk_vld_q) begin
            case (count[1:0])
              2'd0: pack <= {rx_data,24'd0};
              2'd1: pack[23:16] <= rx_data;
              2'd2: pack[15:8] <= rx_data;
              2'd3: begin
                pmem_wr_en <= 1'b1;
                pmem_wr_addr <= {blk_q,count[10:2]};
                pmem_wr_data <= {pack[31:8],rx_data};
                pmem_wr_be <= 4'hF;
              end
            endcase
          end
          case (count)
            12'd1,12'd2,12'd3: if (rx_data != 0) hdr_bad <= 1'b1;
            12'd4: vlid_q[15:8] <= rx_data;
            12'd5: vlid_q[7:0] <= rx_data;
            12'd6: if (rx_data != 8'h02) hdr_bad <= 1'b1;
            12'd11: ifid_q <= rx_data[7:5];
            12'd12: if (rx_data != 8'h08) hdr_bad <= 1'b1;
            12'd13: if (rx_data != 8'h00) hdr_bad <= 1'b1;
            12'd14: if (rx_data != 8'h45) hdr_bad <= 1'b1;
            12'd16: ip_len_hi <= rx_data;
            12'd17: ip_len <= {ip_len_hi,rx_data};
            // P08：IPv4 Identification（字节 18/19）
            12'd18: ident_hi <= rx_data;
            12'd19: ident_q <= {ident_hi, rx_data};
            // P08：Flags/Fragment Offset（字节 20/21）
            //   [7:5] flags（bit1=DF, bit0=MF），[4:0]+下一字节 = 13 位 8 字节单位偏移
            12'd20: begin
              mf_q <= rx_data[5];
              df_q <= rx_data[6];
              frag_off_hi <= rx_data[4:0];
            end
            12'd21: frag_off_q <= {frag_off_hi, rx_data, 3'b000};  // 字节偏移（13b<<3）
            12'd23: if (rx_data != 8'd17) hdr_bad <= 1'b1;
            12'd26: src_ip_q[31:24] <= rx_data;
            12'd27: src_ip_q[23:16] <= rx_data;
            12'd28: src_ip_q[15:8] <= rx_data;
            12'd29: src_ip_q[7:0] <= rx_data;
            12'd30: dst_ip_q[31:24] <= rx_data;
            12'd31: dst_ip_q[23:16] <= rx_data;
            12'd32: dst_ip_q[15:8] <= rx_data;
            12'd33: dst_ip_q[7:0] <= rx_data;
            12'd34: sport_q[15:8] <= rx_data;
            12'd35: sport_q[7:0] <= rx_data;
            12'd36: dport_q[15:8] <= rx_data;
            12'd37: dport_q[7:0] <= rx_data;
            12'd38: udp_len_hi <= rx_data;
            12'd39: udp_len <= {udp_len_hi,rx_data};
            12'd40: udp_check[15:8] <= rx_data;
            12'd41: udp_check[7:0] <= rx_data;
            default: ;
          endcase
          if (count >= 12'd14 && count <= 12'd33) begin
            if (!count[0]) ip_hi <= rx_data;
            else ip_sum <= ip_sum + {16'd0,ip_hi,rx_data};
          end
          if (count >= 12'd26 && count <= 12'd33) begin
            if (!count[0]) pseudo_hi <= rx_data;
            else pseudo_sum <= pseudo_sum + {16'd0,pseudo_hi,rx_data};
          end
          if (count >= 12'd34 && {4'd0,count} < (16'd14+ip_len)) begin
            if (!count[0]) udp_hi <= rx_data;
            else udp_sum <= udp_sum + {16'd0,udp_hi,rx_data};
          end
          if (!is_frag_any && udp_len >= 16'd8 && udp_len < 16'd25 &&
              {4'd0,count} >= (16'd42+udp_len-16'd8) && count < 12'd59 && rx_data != 0)
            pad_bad <= 1'b1;
        end
      end
      if (IF_MODE == 0 && !in_frame && rx_valid && !rx_ready && enable) begin
        // 帧包络外的字节是总线协议错误，不会触发描述符或 PMEM 写。
        frame_err <= 1'b1; drop_reason <= 8'h80; drop_cnt <= drop_cnt + 16'd1;
      end
    end
  end
endmodule
