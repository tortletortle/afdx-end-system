// T24g: IF_MODE=1 (GMII 连续字节) 变体，验证 §7.1.1 上线路径不依赖帧包络节奏。
// 判据与 T24 相同，仅 IF_MODE 参数不同。
`timescale 1 ns / 1 ps
module tb_t24g_mgmt_tx #(parameter integer IF_MODE=1);
  tb_t24_mgmt_tx #(.IF_MODE(IF_MODE)) u_core();
endmodule
