// 每网写口 8 字 skid + 好帧描述符 4 深。
// 仲裁必须对两路 RX 写 FIFO 优先，最后才处理运行时的主机请求。
// desc_mark 是最后一字进入写 FIFO 后的写指针；只有读指针追到 mark
// （PMEM 写沿已提交）才放出好帧，防止后级在内存未完成时观察该帧。
`timescale 1 ns / 1 ps
module rx_pmem_queue (
  input wire clk, rst_sync,
  input wire in_wr_en,
  input wire [12:0] in_wr_addr,
  input wire [31:0] in_wr_data,
  input wire [3:0] in_wr_be,
  input wire in_desc_vld,
  input wire [162:0] in_desc,
  output wire frame_room,
  output wire wr_valid,
  output wire [12:0] wr_addr,
  output wire [31:0] wr_data,
  output wire [3:0] wr_be,
  input wire wr_pop,
  output wire desc_valid,
  output wire [162:0] desc,
  input wire desc_pop,
  output reg overflow
);
  reg [48:0] words [0:7];
  reg [162:0] descs [0:3];
  reg [3:0] marks [0:3];
  reg [3:0] wp, rp;
  reg [2:0] dw, dr;
  wire [3:0] used = wp-rp;
  wire [2:0] desc_used = dw-dr;
  wire push_word = in_wr_en && used != 4'd8;
  wire pop_word = wr_pop && wr_valid;
  wire push_desc = in_desc_vld && desc_used != 3'd4;
  wire pop_desc = desc_pop && desc_valid;
  assign wr_valid = (wp != rp);
  assign {wr_addr,wr_data,wr_be} = words[rp[2:0]];
  assign desc = descs[dr[1:0]];
  assign desc_valid = (dw != dr) && (rp == marks[dr[1:0]]);
  // 单网相邻写之间至少 4 拍；同拍两网只争 1 写口，8 字足够覆盖仲裁泡沫。
  // 描述符占用 <4 才接纳下一帧，保留它的一席，运行期不丢好帧。
  assign frame_room = (desc_used < 3'd4) && (used < 4'd6);
  always @(posedge clk) begin
    if (rst_sync) begin
      wp <= 4'd0; rp <= 4'd0;
      dw <= 3'd0; dr <= 3'd0; overflow <= 1'b0;
    end else begin
      if (push_word) begin
        words[wp[2:0]] <= {in_wr_addr,in_wr_data,in_wr_be};
        wp <= wp+4'd1;
      end
      if (pop_word) rp <= rp+4'd1;
      if (push_desc) begin
        descs[dw[1:0]] <= in_desc;
        marks[dw[1:0]] <= wp + {3'd0,push_word};
        dw <= dw+3'd1;
      end
      if (pop_desc) dr <= dr+3'd1;
      if (in_wr_en && !push_word || in_desc_vld && !push_desc)
        overflow <= 1'b1;
    end
  end
endmodule
