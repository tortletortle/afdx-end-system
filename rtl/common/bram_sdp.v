// =====================================================================
// bram_sdp.v —— BRAM 封装（1 写口 + 2 读口 A/B，读延迟 1 拍）
// 设计书 §7.14（PMEM 需求: 读口 A 给 flt/parse 控制流、读口 B 给
//   CRC/校验和，与写口并行）、§7.19（公共模块表）、§8.6（PMEM 规格）
// 推断要点（O-20 第 3 条冒烟对象，doc_AFDX设计书_优化增量_r1.md）：
//   同步读（rd_data_* 寄存输出）、地址/数据寄存、无复位、
//   不做同拍读写假设——同地址同拍读写结果未定义，
//   调用方不得依赖该行为（如需先读后写须隔拍）。
// eLinx 冒烟结论（2026-09-22，elinx/prj/bram_sdp_smoke.ys）：
//   该 Yosys 分支的 $mem 即 1W2R cell（RD_DATA/RD_DATA_B 双读口）；
//   单读口写法会被双驱动 rd_data（CHECK 报错），1W2R 一一映射通过。
//   若后续满配规模推断失败，按 §7.19 走 `ifdef ELINX_SYNTH` 例化
//   eLinx BRAM IP（elinx/ip/）。
// 端口风格: 非 ANSI。原因: AW 需由 D 经 clog2 派生，而 V2001 ANSI
//   参数表不能调用函数；体内声明顺序 = 参数 → clog2 → AW → 端口，
//   与 vlog-2730 教训（声明前置）一致。
// 命名/握手: §10（与 sync_fifo 一致: wr_en/rd_en）
// =====================================================================
`timescale 1 ns / 1 ps
module bram_sdp (
  clk,
  wr_en, wr_addr, wr_data, wr_be,
  rd_en_a, rd_addr_a, rd_data_a,
  rd_en_b, rd_addr_b, rd_data_b
);
  parameter integer W = 32;    // 数据位宽（PMEM: 32 bit 字）
  parameter integer D = 8192;  // 深度（PMEM: 8192 字 = 32 KB；须为 2 的幂）
  parameter integer BYTE_EN = 0; // 仅 PMEM 打开；其他旧实例保留整字写，不依赖悬空 wr_be

  // 自备 clog2（$clog2 是 2005 项，O-20 第 4 条）
  function integer clog2;
    input integer value;
    integer v;
    begin
      v = value - 1;
      for (clog2 = 0; v > 0; clog2 = clog2 + 1)
        v = v >> 1;
    end
  endfunction
  localparam integer AW = (D <= 2) ? 1 : clog2(D);

  input  wire            clk;
  input  wire            wr_en;
  input  wire [AW-1:0]   wr_addr;
  input  wire [W-1:0]    wr_data;
  input  wire [W/8-1:0]  wr_be; // [W/8-1] 控制最高 8 bit，PMEM 时 [3]=[31:24]
  input  wire            rd_en_a;
  input  wire [AW-1:0]   rd_addr_a;
  output reg  [W-1:0]    rd_data_a;
  input  wire            rd_en_b;
  input  wire [AW-1:0]   rd_addr_b;
  output reg  [W-1:0]    rd_data_b;

  // continue2（2026-09-25）：eLinx 隔离综合 iso_bram_sdp_pmem 证明
  // "同一 $mem 上按 lane 部分写" 不被 memory_bram 接受，退化为 8192×32
  // 触发器 + 24k $eq（顶层 OPT_MUXTREE 内存爆炸的来源之一）。
  // 修复：BYTE_EN=1 时拆成 W/8 个独立 8 bit 整字写存储体（每 lane 1W2R，
  // wr_en & wr_be[l] 为其写使能）。读口语义完全不变：同拍同地址读写
  // 仍未定义，读延迟 1 拍，rd_en 门控寄存输出。
  wire [W-1:0] rd_a_w, rd_b_w;
  genvar lane;
  generate
    if (BYTE_EN != 0) begin : g_lanes
      for (lane = 0; lane < W/8; lane = lane + 1) begin : g_lane
        bram_sdp_core #(.W(8), .AW(AW), .D(D)) u_lane (
          .clk(clk), .wr_en(wr_en & wr_be[lane]), .wr_addr(wr_addr),
          .wr_data(wr_data[8*lane +: 8]),
          .rd_en_a(rd_en_a), .rd_addr_a(rd_addr_a), .rd_data_a(rd_a_w[8*lane +: 8]),
          .rd_en_b(rd_en_b), .rd_addr_b(rd_addr_b), .rd_data_b(rd_b_w[8*lane +: 8]));
      end
    end else begin : g_word
      bram_sdp_core #(.W(W), .AW(AW), .D(D)) u_word (
        .clk(clk), .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data),
        .rd_en_a(rd_en_a), .rd_addr_a(rd_addr_a), .rd_data_a(rd_a_w),
        .rd_en_b(rd_en_b), .rd_addr_b(rd_addr_b), .rd_data_b(rd_b_w));
    end
  endgenerate
  always @(*) begin
    rd_data_a = rd_a_w;
    rd_data_b = rd_b_w;
  end
endmodule

// 1W1R 存储（continue2）：写口 posedge；RD_NEG=1 时读口 negedge 同步读。
// 用于把"寄存地址 + 组合读"的配置表改为 BRAM 而保持逐拍等价（读地址须为
// 上升沿寄存信号；读数据到消费寄存器为半周期路径）。eLinx brams.txt
// clocks 2 3 / clkpol 2 3 支持端口独立极性。同拍同地址读写未定义。
module bram_1w1r (clk, wr_en, wr_addr, wr_data, rd_addr, rd_data);
  parameter integer W = 32;
  parameter integer D = 4096;
  parameter integer RD_NEG = 0;
  function integer clog2;
    input integer value;
    integer v;
    begin
      v = value - 1;
      for (clog2 = 0; v > 0; clog2 = clog2 + 1) v = v >> 1;
    end
  endfunction
  localparam integer AW = (D <= 2) ? 1 : clog2(D);
  input  wire          clk;
  input  wire          wr_en;
  input  wire [AW-1:0] wr_addr;
  input  wire [W-1:0]  wr_data;
  input  wire [AW-1:0] rd_addr;
  output reg  [W-1:0]  rd_data;
  (* no_rw_check *)
  reg [W-1:0] mem [0:D-1];
  always @(posedge clk) begin
    if (wr_en) mem[wr_addr] <= wr_data;
  end
  generate
    if (RD_NEG != 0) begin : g_rneg
      always @(negedge clk) rd_data <= mem[rd_addr];
    end else begin : g_rpos
      always @(posedge clk) rd_data <= mem[rd_addr];
    end
  endgenerate
endmodule

// 整字写 1W2R 存储核（原 BYTE_EN=0 冒烟路径，eLinx 可映射 altsyncram）
module bram_sdp_core (
  clk, wr_en, wr_addr, wr_data,
  rd_en_a, rd_addr_a, rd_data_a,
  rd_en_b, rd_addr_b, rd_data_b
);
  parameter integer W  = 32;
  parameter integer AW = 13;
  parameter integer D  = 8192;
  input  wire          clk;
  input  wire          wr_en;
  input  wire [AW-1:0] wr_addr;
  input  wire [W-1:0]  wr_data;
  input  wire          rd_en_a;
  input  wire [AW-1:0] rd_addr_a;
  output reg  [W-1:0]  rd_data_a;
  input  wire          rd_en_b;
  input  wire [AW-1:0] rd_addr_b;
  output reg  [W-1:0]  rd_data_b;
  // no_rw_check: 规范本就"不做同拍读写假设"（O-20 第 3 条）
  (* no_rw_check *)
  reg [W-1:0] mem [0:D-1];
  always @(posedge clk) begin
    if (wr_en) mem[wr_addr] <= wr_data;
  end
  always @(posedge clk) begin
    if (rd_en_a) rd_data_a <= mem[rd_addr_a];
  end
  always @(posedge clk) begin
    if (rd_en_b) rd_data_b <= mem[rd_addr_b];
  end
endmodule
