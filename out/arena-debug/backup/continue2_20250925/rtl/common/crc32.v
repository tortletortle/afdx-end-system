// =====================================================================
// crc32.v —— IEEE 802.3 CRC32（字节输入，reflected）
// 设计书 §6.4/§7.3/§7.8（FCS 生成与校验，FCS_MODE；RX 校验 T08/T03）
// init = 0xFFFFFFFF，final = crc_out ^ 0xFFFFFFFF（由使用方做异或）
// 自检向量: "123456789" → 0xCBF43926（T00/T03，tb_t01 里已带）
// =====================================================================
`timescale 1 ns / 1 ps
module crc32 (
  input  wire        clk,
  input  wire        rst,
  input  wire        init,          // 1 拍：状态清 0xFFFFFFFF
  input  wire        data_valid,    // 每拍 1 字节
  input  wire [7:0]  data,
  output wire [31:0] crc_out,       // 原始状态
  output wire [31:0] crc_final      // = crc_out ^ 0xFFFFFFFF
);
  localparam [31:0] POLY_R = 32'hEDB8_8320;   // 0x04C11DB7 的 reflected
  reg [31:0] crc_r;
  wire [31:0] d32 = {24'h000, data};
  wire [31:0] s  = crc_r ^ d32;
  wire [31:0] c0 = s[0]  ? (s  >> 1) ^ POLY_R : (s  >> 1);
  wire [31:0] c1 = c0[0] ? (c0 >> 1) ^ POLY_R : (c0 >> 1);
  wire [31:0] c2 = c1[0] ? (c1 >> 1) ^ POLY_R : (c1 >> 1);
  wire [31:0] c3 = c2[0] ? (c2 >> 1) ^ POLY_R : (c2 >> 1);
  wire [31:0] c4 = c3[0] ? (c3 >> 1) ^ POLY_R : (c3 >> 1);
  wire [31:0] c5 = c4[0] ? (c4 >> 1) ^ POLY_R : (c4 >> 1);
  wire [31:0] c6 = c5[0] ? (c5 >> 1) ^ POLY_R : (c5 >> 1);
  wire [31:0] c7 = c6[0] ? (c6 >> 1) ^ POLY_R : (c6 >> 1);

  always @(posedge clk) begin
    if (rst)
      crc_r <= 32'hFFFF_FFFF;
    else if (init)
      crc_r <= 32'hFFFF_FFFF;
    else if (data_valid)
      crc_r <= c7;
  end
  assign crc_out   = crc_r;
  assign crc_final = crc_r ^ 32'hFFFF_FFFF;
endmodule
