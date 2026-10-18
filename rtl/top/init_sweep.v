// init_sweep.v — 上电清状态与配置 valid 的逐字扫描（§4.2 / O-08）。
// 本模块只产生目标/地址/写使能，存储体的实际清零由顶层单写口完成。
// 哈希物理区 4*HASH_BUCKETS 项（2 表 × HASH_BUCKETS 桶 × 2 way）；其余规模由参数决定。
// 最后一项写入后额外留一拍排空，再拉高 done，主机不得提前开流。
`timescale 1 ns / 1 ps
module init_sweep #(
  parameter integer NUM_RX_VL = 4096,
  parameter integer NUM_TX_VL = 128,
  parameter integer NUM_PORTS = 256,
  parameter integer HASH_BUCKETS = 2048
) (
  input  wire        clk,
  input  wire        rst_sync,
  output wire        init_we,
  output reg  [2:0] init_target,
  output reg  [12:0] init_addr,
  output reg         init_done
);
  localparam [2:0] T_PSN    = 3'd0;  // 2 × NUM_RX_VL（A/B）
  localparam [2:0] T_RM     = 3'd1;  // NUM_RX_VL
  localparam [2:0] T_HASH   = 3'd2;  // 4*HASH_BUCKETS 项
  localparam [2:0] T_RXCFG  = 3'd3;  // NUM_RX_VL 个 w0.valid
  localparam [2:0] T_TXCFG  = 3'd4;  // NUM_TX_VL 个 w0.valid
  localparam [2:0] T_PORT   = 3'd5;  // NUM_PORTS 个 w0.valid
  localparam [2:0] T_RXDESC = 3'd6;  // NUM_PORTS 个描述符
  localparam [2:0] T_VLSTAT = 3'd7;  // NUM_TX_VL 项首统计字

  reg draining;
  reg [12:0] last_index;
  always @(*) begin
    case (init_target)
      T_PSN:    last_index = 2*NUM_RX_VL - 1;
      T_RM:     last_index = NUM_RX_VL - 1;
      T_HASH:   last_index = (4*HASH_BUCKETS) - 1;
      T_RXCFG:  last_index = NUM_RX_VL - 1;
      T_TXCFG:  last_index = NUM_TX_VL - 1;
      T_PORT:   last_index = NUM_PORTS - 1;
      T_RXDESC: last_index = NUM_PORTS - 1;
      default:  last_index = NUM_TX_VL - 1;
    endcase
  end
  assign init_we = ~rst_sync & ~draining & ~init_done;

  always @(posedge clk) begin
    if (rst_sync) begin
      init_target <= T_PSN;
      init_addr   <= 13'd0;
      init_done   <= 1'b0;
      draining    <= 1'b0;
    end else if (init_we) begin
      if (init_addr == last_index) begin
        init_addr <= 13'd0;
        if (init_target == T_VLSTAT) draining <= 1'b1;
        else                         init_target <= init_target + 3'd1;
      end else begin
        init_addr <= init_addr + 13'd1;
      end
    end else if (draining) begin
      draining <= 1'b0;
      init_done <= 1'b1;
    end
  end
endmodule
