// afdx_app_rx.v — 轮询 MSG_CNT → DESC/PMEM → 输出 VLID+payload → MSG_RD
`timescale 1 ns / 1 ps
module afdx_app_rx #(
  parameter integer NUM_RX = 126
) (
  input  wire        clk,
  input  wire        rst,
  input  wire        cfg_done,
  input  wire        map_we,
  input  wire [6:0]  map_vl,
  input  wire [7:0]  map_port,
  output reg  [7:0]  rx_data,
  output reg         rx_valid,
  input  wire        rx_ready,
  output reg         req,
  output reg         we,
  output reg  [15:0] addr,
  output reg  [31:0] wdata,
  input  wire        ack,
  input  wire [31:0] rdata,
  output reg  [31:0] deliver_cnt
);
  localparam [2:0]
    S_SCAN = 3'd0, S_CNT = 3'd1, S_DESC = 3'd2,
    S_OH   = 3'd3, S_OL  = 3'd4, S_PAY = 3'd5, S_REL = 3'd6;

  // 端口 0..255 均可合法；不得用 8'hFF 作「未映射」哨兵（VL125→port255 会被跳过）。
  // port_of_vl：仅 map_we 写、不复位（只在 vl_valid=1 时使用）；vl_valid 用位向量，避免复位 for 循环生成 128 个写口。
  reg [7:0]   port_of_vl [0:127];
  reg [127:0] vl_valid;
  reg [6:0] scan_vl;
  reg [7:0] cur_port;
  reg [15:0] cur_vlid;
  reg [10:0] cur_plen;
  reg [3:0]  cur_blk;
  reg [10:0] pay_off;
  reg [2:0]  st;
  reg        issued;

  always @(posedge clk) begin
    if (map_we && !rst) port_of_vl[map_vl] <= map_port;
  end

  always @(posedge clk) begin
    if (rst) vl_valid <= 128'd0;
    else if (map_we) vl_valid[map_vl] <= 1'b1;
  end

  wire [6:0] scan_next =
      (scan_vl >= NUM_RX[6:0] - 7'd1) ? 7'd0 : (scan_vl + 7'd1);

  always @(posedge clk) begin
    if (rst) begin
      st <= S_SCAN; scan_vl <= 7'd0;
      req <= 1'b0; we <= 1'b0; addr <= 16'd0; wdata <= 32'd0;
      rx_data <= 8'd0; rx_valid <= 1'b0;
      deliver_cnt <= 32'd0; issued <= 1'b0;
      cur_port <= 8'd0; cur_vlid <= 16'd0; cur_plen <= 11'd0;
      cur_blk <= 4'd0; pay_off <= 11'd0;
    end else if (!cfg_done) begin
      req <= 1'b0; rx_valid <= 1'b0;
    end else begin
      rx_valid <= 1'b0;
      case (st)
        S_SCAN: begin
          req <= 1'b0;
          cur_port <= port_of_vl[scan_vl];
          if (vl_valid[scan_vl]) begin
            st <= S_CNT; issued <= 1'b0;
          end else scan_vl <= scan_next;
        end
        S_CNT: begin
          if (!issued) begin
            req <= 1'b1; we <= 1'b0;
            addr <= 16'h8480 + cur_port; wdata <= 32'd0;
            issued <= 1'b1;
          end else if (ack) begin
            req <= 1'b0; issued <= 1'b0;
            if (rdata != 32'd0) st <= S_DESC;
            else begin scan_vl <= scan_next; st <= S_SCAN; end
          end
        end
        S_DESC: begin
          if (!issued) begin
            req <= 1'b1; we <= 1'b0;
            addr <= 16'h8180 + cur_port; wdata <= 32'd0;
            issued <= 1'b1;
          end else if (ack) begin
            req <= 1'b0; issued <= 1'b0;
            if (rdata[31]) begin
              cur_plen <= rdata[10:0];
              cur_blk  <= rdata[23:20];
              cur_vlid <= 16'h0100 + {9'd0, scan_vl};
              st <= S_OH;
            end else begin scan_vl <= scan_next; st <= S_SCAN; end
          end
        end
        S_OH: begin
          rx_valid <= 1'b1; rx_data <= cur_vlid[15:8];
          st <= S_OL;
        end
        S_OL: begin
          rx_valid <= 1'b1; rx_data <= cur_vlid[7:0];
          pay_off <= 11'd0; issued <= 1'b0; st <= S_PAY;
        end
        S_PAY: begin
          if (pay_off >= cur_plen) begin
            st <= S_REL; issued <= 1'b0;
          end else if (!issued) begin
            req <= 1'b1; we <= 1'b0;
            addr <= 16'h8800 + (cur_blk << 9) + ((11'd42 + pay_off) >> 2);
            wdata <= 32'd0;
            issued <= 1'b1;
          end else if (ack) begin
            req <= 1'b0; issued <= 1'b0;
            rx_valid <= 1'b1;
            case ((11'd42 + pay_off) & 11'd3)
              11'd0: rx_data <= rdata[31:24];
              11'd1: rx_data <= rdata[23:16];
              11'd2: rx_data <= rdata[15:8];
              default: rx_data <= rdata[7:0];
            endcase
            pay_off <= pay_off + 11'd1;
          end
        end
        S_REL: begin
          if (!issued) begin
            req <= 1'b1; we <= 1'b1;
            addr <= 16'h8380 + cur_port; wdata <= 32'd0;
            issued <= 1'b1;
          end else if (ack) begin
            req <= 1'b0; issued <= 1'b0;
            deliver_cnt <= deliver_cnt + 32'd1;
            scan_vl <= scan_next; st <= S_SCAN;
          end
        end
        default: st <= S_SCAN;
      endcase
    end
  end
endmodule
