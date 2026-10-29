// afdx_app_init.v — 上电配置 128 TX VL + 126 RX VL + SAP 开（端口预算同 T90）
`timescale 1 ns / 1 ps
module afdx_app_init #(
  parameter integer NUM_TX_VL = 128,
  parameter integer NUM_RX_VL_CFG = 126,
  parameter integer TX_PORT_BASE = 16,
  parameter integer BAG_US = 1000,
  parameter integer SHARE_G0 = 705,
  parameter integer SHARE_G1 = 2710,
  parameter integer SHARE_G2 = 9152,
  parameter integer SHARE_G3 = 12902
) (
  input  wire        clk,
  input  wire        rst,
  output reg         cfg_done,
  output reg         req,
  output reg         we,
  output reg  [15:0] addr,
  output reg  [31:0] wdata,
  input  wire        ack,
  input  wire [31:0] rdata,
  // 每配完一条 RX：脉冲写 VL↔port 映射供顶层保存
  output reg         map_we,
  output reg  [6:0]  map_vl,
  output reg  [7:0]  map_port
);
  localparam [4:0]
    S_WAIT = 5'd0,
    S_CFG  = 5'd1,
    S_UDI  = 5'd2,
    S_IP   = 5'd3,
    S_UDP  = 5'd4,
    S_SD0  = 5'd5,
    S_SD1  = 5'd6,
    S_TP3  = 5'd7,
    S_TP0  = 5'd8,
    S_TW4  = 5'd9,
    S_TW3  = 5'd10,
    S_TW2  = 5'd11,
    S_TW1  = 5'd12,
    S_TSH  = 5'd13,
    S_TW0  = 5'd14,
    S_POOL = 5'd15,
    S_RHSH = 5'd16,
    S_RC0  = 5'd17,
    S_RC1  = 5'd18,
    S_RP0  = 5'd19,
    S_RP1  = 5'd20,
    S_RP2  = 5'd21,
    S_RP3  = 5'd22,
    S_HCM  = 5'd23,
    S_IRQ  = 5'd24,
    S_RUN  = 5'd25,
    S_DONE = 5'd26;

  reg [4:0]  st;
  reg [7:0]  vl;
  reg [7:0]  rx_i;
  reg [8:0]  pool_scan;
  reg [7:0]  pool_n;
  reg [7:0]  rx_pool [0:125];
  reg        way0_used [0:2047];   // 单写口(清零扫描/置位) + 单同步读口，可推断 BRAM
  reg        way0_q;
  reg [10:0] clr_i;
  reg        clr_busy;
  reg [15:0] waitc;
  reg [7:0]  port_tx, port_rx;
  reg [10:0] plen;
  reg [15:0] lmax;
  reg [15:0] share;
  reg [15:0] vlid;
  reg [11:0] rx_idx;
  reg [10:0] bucket;
  reg        way_sel;

  function [10:0] mix_bucket;
    input [15:0] v, seed;
    reg [15:0] x;
    begin
      x = v + seed + 16'h9E37;
      x = x ^ (x >> 7);
      x = x * 16'h9E37;
      x = x ^ (x >> 9);
      mix_bucket = x[10:0];
    end
  endfunction

  // way0_used 读写地址（bucket）。读口预取：S_RP3 内取下一条 RX 的 bucket，
  // 进入 S_RHSH 的第一拍 way0_q 即为该条 bucket 的占用位，不增加状态/拍数。
  // S_POOL 期间预取 rx_i=0。置位发生在 S_RHSH 首拍，远早于下一次预取（>=7 拍）。
  wire [10:0] bucket_cur = mix_bucket(16'h0100 + {8'd0, rx_i}, 16'h172D);
  wire [7:0]  rd_idx     = (st == S_POOL) ? 8'd0 : (rx_i + 8'd1);
  wire [10:0] bucket_rd  = mix_bucket(16'h0100 + {8'd0, rd_idx}, 16'h172D);
  wire        wy_set     = (st == S_RHSH) && !req && !way0_q;
  wire        w_we       = clr_busy | wy_set;
  wire [10:0] w_a        = clr_busy ? clr_i : bucket_cur;
  wire        w_d        = ~clr_busy;

  always @(posedge clk) begin
    if (w_we) way0_used[w_a] <= w_d;
    way0_q <= way0_used[bucket_rd];
  end

  // 复位后逐项清零 2048 拍（原为复位拍 2048 口并行清零）；S_POOL 出口等待清零完成。
  always @(posedge clk) begin
    if (rst) begin
      clr_i <= 11'd0;
      clr_busy <= 1'b1;
    end else if (clr_busy) begin
      clr_i <= clr_i + 11'd1;
      if (clr_i == 11'd2047) clr_busy <= 1'b0;
    end
  end

  function [10:0] plen_for;
    input [7:0] v;
    begin
      if (v < 8'd32)       plen_for = 11'd17;
      else if (v < 8'd64)  plen_for = 11'd256;
      else if (v < 8'd96)  plen_for = 11'd1024;
      else                 plen_for = 11'd1471;
    end
  endfunction

  function [15:0] share_for;
    input [7:0] v;
    begin
      if (v < 8'd32)       share_for = SHARE_G0[15:0];
      else if (v < 8'd64)  share_for = SHARE_G1[15:0];
      else if (v < 8'd96)  share_for = SHARE_G2[15:0];
      else                 share_for = SHARE_G3[15:0];
    end
  endfunction

  always @(posedge clk) begin
    if (rst) begin
      st <= S_WAIT;
      cfg_done <= 1'b0;
      req <= 1'b0; we <= 1'b0; addr <= 16'd0; wdata <= 32'd0;
      vl <= 8'd0; rx_i <= 8'd0; pool_scan <= 9'd0; pool_n <= 8'd0;
      waitc <= 16'd0;
      map_we <= 1'b0; map_vl <= 7'd0; map_port <= 8'd0;
    end else begin
      map_we <= 1'b0;
      case (st)
        S_WAIT: begin
          req <= 1'b1; we <= 1'b0; addr <= 16'h000C; wdata <= 32'd0;
          if (ack) begin
            req <= 1'b0;
            if (rdata[13]) begin st <= S_CFG; waitc <= 16'd0; end
            else if (waitc > 16'd40000) st <= S_DONE;
            else waitc <= waitc + 16'd1;
          end
        end
        S_CFG: begin
          req <= 1'b1; we <= 1'b1; addr <= 16'h0008; wdata <= 32'h0000_2000;
          if (ack) begin req <= 1'b0; st <= S_UDI; end
        end
        S_UDI: begin
          req <= 1'b1; we <= 1'b1; addr <= 16'h0060; wdata <= 32'h1234_2001;
          if (ack) begin req <= 1'b0; st <= S_IP; end
        end
        S_IP: begin
          req <= 1'b1; we <= 1'b1; addr <= 16'h0064; wdata <= 32'h0A00_0001;
          if (ack) begin req <= 1'b0; st <= S_UDP; end
        end
        S_UDP: begin
          req <= 1'b1; we <= 1'b1; addr <= 16'h0070; wdata <= 32'h0000_0142;
          if (ack) begin req <= 1'b0; st <= S_SD0; end
        end
        S_SD0: begin
          req <= 1'b1; we <= 1'b1; addr <= 16'h0078; wdata <= 32'h0000_172D;
          if (ack) begin req <= 1'b0; st <= S_SD1; end
        end
        S_SD1: begin
          req <= 1'b1; we <= 1'b1; addr <= 16'h007C; wdata <= 32'h0000_AB61;
          if (ack) begin req <= 1'b0; vl <= 8'd0; st <= S_TP3; end
        end

        S_TP3: begin
          port_tx <= TX_PORT_BASE[7:0] + vl;
          req <= 1'b1; we <= 1'b1;
          addr <= 16'h7D80 + ((TX_PORT_BASE + vl) << 2) + 16'd3;
          wdata <= 32'd1;
          if (ack) begin req <= 1'b0; st <= S_TP0; end
        end
        S_TP0: begin
          req <= 1'b1; we <= 1'b1;
          addr <= 16'h7D80 + ((TX_PORT_BASE + vl) << 2);
          wdata <= 32'h8000_C000 | {16'd0, vl};
          if (ack) begin req <= 1'b0; st <= S_TW4; end
        end
        S_TW4: begin
          req <= 1'b1; we <= 1'b1;
          addr <= 16'h0200 + (5 * vl) + 16'd4;
          wdata <= ((TX_PORT_BASE + vl) << 16);
          if (ack) begin req <= 1'b0; st <= S_TW3; end
        end
        S_TW3: begin
          req <= 1'b1; we <= 1'b1;
          addr <= 16'h0200 + (5 * vl) + 16'd3;
          wdata <= 32'hE000_0001;
          if (ack) begin req <= 1'b0; st <= S_TW2; end
        end
        S_TW2: begin
          req <= 1'b1; we <= 1'b1;
          addr <= 16'h0200 + (5 * vl) + 16'd2;
          wdata <= 32'h1388_C000;
          if (ack) begin req <= 1'b0; st <= S_TW1; end
        end
        S_TW1: begin
          req <= 1'b1; we <= 1'b1;
          addr <= 16'h0200 + (5 * vl) + 16'd1;
          wdata <= (BAG_US << 8);
          if (ack) begin req <= 1'b0; st <= S_TSH; end
        end
        S_TSH: begin
          req <= 1'b1; we <= 1'b1;
          addr <= 16'h0480 + vl;
          wdata <= {16'd0, share_for(vl)};
          if (ack) begin req <= 1'b0; st <= S_TW0; end
        end
        S_TW0: begin
          req <= 1'b1; we <= 1'b1;
          addr <= 16'h0200 + (5 * vl);
          // Lmax = plen+47，写入 w0[27:12]
          wdata <= 32'h8000_0003 | (({5'd0, plen_for(vl)} + 16'd47) << 12);
          if (ack) begin
            req <= 1'b0;
            if (vl == NUM_TX_VL[7:0] - 8'd1) begin
              pool_scan <= 9'd0; pool_n <= 8'd0; st <= S_POOL;
            end else begin
              vl <= vl + 8'd1; st <= S_TP3;
            end
          end
        end

        S_POOL: begin
          if (pool_scan >= 9'd256) begin
            if (!clr_busy) begin rx_i <= 8'd0; st <= S_RHSH; end
          end else begin
            if (pool_scan[7:0] != 8'd6 && pool_scan[7:0] != 8'd7 &&
                (pool_scan < TX_PORT_BASE ||
                 pool_scan >= (TX_PORT_BASE + NUM_TX_VL))) begin
              if (pool_n < NUM_RX_VL_CFG[7:0]) begin
                rx_pool[pool_n] <= pool_scan[7:0];
                pool_n <= pool_n + 8'd1;
              end
            end
            pool_scan <= pool_scan + 9'd1;
          end
        end

        S_RHSH: begin
          // 进入本态时锁存 way/bucket，ack 前不再改 way0_used
          if (!req) begin
            vlid   = 16'h0100 + {8'd0, rx_i};
            rx_idx = 12'h100 + {4'd0, rx_i};
            port_rx = rx_pool[rx_i];
            bucket  = mix_bucket(vlid, 16'h172D);
            way_sel = way0_q;   // 0=way0 空闲(置位在 wy_set)，1=占用走 way1
            map_we   <= 1'b1;
            map_vl   <= rx_i[6:0];
            map_port <= port_rx;
            req <= 1'b1; we <= 1'b1;
            addr <= 16'h3D80 + (bucket << 1) + {15'd0, way_sel};
            wdata <= {3'd0, 1'b1, vlid, rx_idx};
          end else if (ack) begin
            req <= 1'b0; st <= S_RC0;
          end
        end
        S_RC0: begin
          if (!req) begin
            port_rx = rx_pool[rx_i];
            plen = plen_for(rx_i);
            lmax = {5'd0, plen} + 16'd47;
            rx_idx = 12'h100 + {4'd0, rx_i};
            req <= 1'b1; we <= 1'b1;
            addr <= 16'h1D80 + (rx_idx << 1);
            wdata <= 32'hF500_0000 | ({24'd0, port_rx} << 12) | {21'd0, lmax[10:0]};
          end else if (ack) begin
            req <= 1'b0; st <= S_RC1;
          end
        end
        S_RC1: begin
          if (!req) begin
            vlid = 16'h0100 + {8'd0, rx_i};
            rx_idx = 12'h100 + {4'd0, rx_i};
            req <= 1'b1; we <= 1'b1;
            addr <= 16'h1D80 + (rx_idx << 1) + 16'd1;
            wdata <= {16'd0, vlid};
          end else if (ack) begin
            req <= 1'b0; st <= S_RP0;
          end
        end
        S_RP0: begin
          if (!req) begin
            port_rx = rx_pool[rx_i];
            req <= 1'b1; we <= 1'b1;
            addr <= 16'h7D80 + (port_rx << 2);
            wdata <= 32'h8004_0000;
          end else if (ack) begin
            req <= 1'b0; st <= S_RP1;
          end
        end
        S_RP1: begin
          if (!req) begin
            port_rx = rx_pool[rx_i];
            req <= 1'b1; we <= 1'b1;
            addr <= 16'h7D80 + (port_rx << 2) + 16'd1;
            wdata <= 32'h0000_1388;
          end else if (ack) begin
            req <= 1'b0; st <= S_RP2;
          end
        end
        S_RP2: begin
          if (!req) begin
            port_rx = rx_pool[rx_i];
            req <= 1'b1; we <= 1'b1;
            addr <= 16'h7D80 + (port_rx << 2) + 16'd2;
            wdata <= 32'd0;
          end else if (ack) begin
            req <= 1'b0; st <= S_RP3;
          end
        end
        S_RP3: begin
          if (!req) begin
            port_rx = rx_pool[rx_i];
            req <= 1'b1; we <= 1'b1;
            addr <= 16'h7D80 + (port_rx << 2) + 16'd3;
            wdata <= 32'd8;
          end else if (ack) begin
            req <= 1'b0;
            if (rx_i == NUM_RX_VL_CFG[7:0] - 8'd1) st <= S_HCM;
            else begin rx_i <= rx_i + 8'd1; st <= S_RHSH; end
          end
        end

        S_HCM: begin
          req <= 1'b1; we <= 1'b1; addr <= 16'h0080; wdata <= 32'h1;
          if (ack) begin req <= 1'b0; st <= S_IRQ; end
        end
        S_IRQ: begin
          req <= 1'b1; we <= 1'b1; addr <= 16'h0014; wdata <= 32'h1;
          if (ack) begin req <= 1'b0; st <= S_RUN; end
        end
        S_RUN: begin
          req <= 1'b1; we <= 1'b1; addr <= 16'h0008; wdata <= 32'h0000_051F;
          if (ack) begin req <= 1'b0; st <= S_DONE; end
        end
        S_DONE: begin
          cfg_done <= 1'b1;
          req <= 1'b0;
        end
        default: st <= S_DONE;
      endcase
    end
  end
endmodule
