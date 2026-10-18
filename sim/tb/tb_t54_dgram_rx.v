// =====================================================================
// T54 — a615a_tftp_dgram_rx：SAP 字节流 → 完整 TFTP 数据报字段（P05，2026-10-10）
//
// 覆盖：DATA 满块/空末块字段与载荷 lane 约定（[4095-8j]=第 j 字节）、
// ACK 4B、ERROR（NUL 终止）码字段；超长 DATA(513)/超长 ACK(5B)/无 NUL ERROR/
// RRQ/WRQ/OACK/首字节非 0/超缓冲 → 整包丢弃且计数；完整未消费数据报对上游
// out_ready=0 背压、字段稳定；消费后恢复接收。TB 侧按可停顿契约驱动字节。
// =====================================================================
`timescale 1 ns / 1 ps
module tb_t54_dgram_rx;
  reg clk = 0;
  always #4 clk = ~clk;
  reg rst = 1, en = 1;

  reg        in_vld = 0, in_sop = 0, in_eop = 0;
  reg [7:0]  in_data = 0;
  reg [15:0] in_sport = 16'd40100;
  reg [15:0] in_dport = 16'h1234;
  reg [31:0] in_srcip = 32'h0A000002;
  wire       out_ready;

  wire        rx_valid;
  reg         rx_ready = 0;
  wire [31:0] rx_src_ip;
  wire [15:0] rx_src_port, rx_dst_port;
  wire [2:0]  rx_opcode;
  wire [15:0] rx_block;
  wire [9:0]  rx_data_len;
  wire [4095:0] rx_data;
  wire [15:0] rx_error_code;
  wire [31:0] ok_cnt, drop_cnt;

  a615a_tftp_dgram_rx #(.BUF_BYTES(516)) dut (
    .clk(clk), .rst_sync(rst), .en(en),
    .in_vld(in_vld), .in_sop(in_sop), .in_eop(in_eop), .in_data(in_data),
    .in_sport(in_sport), .in_dport(in_dport), .in_srcip(in_srcip),
    .out_ready(out_ready),
    .rx_valid(rx_valid), .rx_ready(rx_ready),
    .rx_src_ip(rx_src_ip), .rx_src_port(rx_src_port), .rx_dst_port(rx_dst_port),
    .rx_opcode(rx_opcode), .rx_block(rx_block), .rx_data_len(rx_data_len),
    .rx_data(rx_data), .rx_error_code(rx_error_code),
    .ok_cnt(ok_cnt), .drop_cnt(drop_cnt)
  );

  integer errors = 0, checks = 0;
  task bad;
    input [8*96-1:0] reason;
    begin if (errors < 15) $display("  [err] T54 %0s", reason); errors = errors + 1; end
  endtask
  task chk;
    input cond; input [8*96-1:0] reason;
    begin checks = checks + 1; if (!cond) bad(reason); end
  endtask

  function [7:0] payb; input integer j; begin payb = (j * 7 + 8'h31) & 8'hFF; end endfunction
  function [7:0] datb; input [4095:0] d; input integer j;
    begin datb = d[4095 - 8*j -: 8]; end
  endfunction

  // ---- SAP 侧字节驱动（遵守 out_ready 停顿）----
  reg [7:0] pkt [0:767];
  integer pn;
  task send_pkt;
    integer i;
    reg acc;
    begin
      for (i = 0; i < pn; i = i + 1) begin
        @(negedge clk);
        in_vld = 1; in_sop = (i == 0); in_eop = (i == pn-1); in_data = pkt[i];
        // 保持该字节直到恰好一个 posedge 被接受（out_ready 在 posedge 采样）
        acc = 0;
        while (!acc) begin
          @(posedge clk);
          acc = (out_ready === 1'b1);
        end
        // 注意：被接受后立即进入下一字节（循环顶部等下一 negedge），
        // 不得再额外等一拍，否则同一字节会跨两个 posedge 被消费两次。
      end
      @(negedge clk); in_vld = 0; in_sop = 0; in_eop = 0;
    end
  endtask

  integer guard;
  task wait_rx;
    begin
      guard = 0;
      while (rx_valid !== 1'b1 && guard < 2000) begin @(negedge clk); guard = guard + 1; end
      if (rx_valid !== 1'b1) bad("rx_valid timeout");
    end
  endtask
  task consume_rx;
    begin
      @(negedge clk); rx_ready = 1;
      @(negedge clk); rx_ready = 0;
      @(negedge clk);
    end
  endtask
  task no_rx;
    integer i;
    begin
      for (i = 0; i < 20; i = i + 1) begin
        @(negedge clk);
        if (rx_valid === 1'b1) bad("unexpected rx_valid");
      end
    end
  endtask

  integer i, d0, d1;
  initial begin
    repeat (5) @(negedge clk);
    rst = 0; repeat (2) @(negedge clk);

    $display("CASE C1");
    // ---- C1: DATA 512B ----
    pkt[0]=8'h00; pkt[1]=8'h03; pkt[2]=8'h12; pkt[3]=8'h34;
    for (i = 0; i < 512; i = i + 1) pkt[4+i] = payb(i);
    pn = 516; send_pkt;
    wait_rx;
    chk(rx_opcode === 3'd3 && rx_block === 16'h1234 && rx_data_len === 10'd512, "C1 fields");
    chk(rx_src_port === 16'd40100 && rx_dst_port === 16'h1234
        && rx_src_ip === 32'h0A000002, "C1 ports/ip");
    chk(datb(rx_data, 0) === payb(0) && datb(rx_data, 1) === payb(1)
        && datb(rx_data, 255) === payb(255) && datb(rx_data, 511) === payb(511),
        "C1 payload lanes");
    consume_rx;

    $display("CASE C2");
    // ---- C2: DATA 0B（空末块）----
    pkt[0]=8'h00; pkt[1]=8'h03; pkt[2]=8'h00; pkt[3]=8'h07;
    pn = 4; send_pkt;
    wait_rx;
    chk(rx_opcode === 3'd3 && rx_block === 16'h0007 && rx_data_len === 10'd0, "C2 empty DATA");
    consume_rx;

    $display("CASE C3");
    // ---- C3: DATA 513B -> 丢弃 ----
    pkt[0]=8'h00; pkt[1]=8'h03; pkt[2]=8'h00; pkt[3]=8'h08;
    for (i = 0; i < 513; i = i + 1) pkt[4+i] = payb(i);
    pn = 517; send_pkt;
    no_rx;
    chk(drop_cnt === 32'd1, "C3 over-long DATA dropped");

    $display("CASE C4");
    // ---- C4: ACK 4B ----
    pkt[0]=8'h00; pkt[1]=8'h04; pkt[2]=8'h00; pkt[3]=8'h05;
    pn = 4; send_pkt;
    wait_rx;
    chk(rx_opcode === 3'd4 && rx_block === 16'h0005 && rx_data_len === 10'd0, "C4 ACK");
    consume_rx;

    $display("CASE C5");
    // ---- C5: ACK 5B -> 丢弃 ----
    pkt[0]=8'h00; pkt[1]=8'h04; pkt[2]=8'h00; pkt[3]=8'h05; pkt[4]=8'h00;
    pn = 5; send_pkt;
    no_rx;
    chk(drop_cnt === 32'd2, "C5 over-long ACK dropped");

    $display("CASE C6");
    // ---- C6: ERROR NUL 终止 ----
    pkt[0]=8'h00; pkt[1]=8'h05; pkt[2]=8'h00; pkt[3]=8'h05;
    pkt[4]="E"; pkt[5]="R"; pkt[6]="R"; pkt[7]=8'h00;
    pn = 8; send_pkt;
    wait_rx;
    chk(rx_opcode === 3'd5 && rx_error_code === 16'd5, "C6 ERROR code");
    consume_rx;

    $display("CASE C7");
    // ---- C7: ERROR 缺 NUL -> 丢弃 ----
    pkt[0]=8'h00; pkt[1]=8'h05; pkt[2]=8'h00; pkt[3]=8'h04;
    pkt[4]="X"; pkt[5]="Y";
    pn = 6; send_pkt;
    no_rx;
    chk(drop_cnt === 32'd3, "C7 unterminated ERROR dropped");

    $display("CASE C8");
    // ---- C8: RRQ / WRQ / OACK / 首字节非 0 -> 丢弃 ----
    pkt[0]=8'h00; pkt[1]=8'h01; pkt[2]="A"; pkt[3]=8'h00;
    pn = 4; send_pkt; no_rx;
    pkt[0]=8'h00; pkt[1]=8'h02; pkt[2]="A"; pkt[3]=8'h00;
    send_pkt; no_rx;
    pkt[0]=8'h00; pkt[1]=8'h06; pkt[2]=8'h00; pkt[3]=8'h00;
    send_pkt; no_rx;
    pkt[0]=8'h01; pkt[1]=8'h03; pkt[2]=8'h00; pkt[3]=8'h01;
    send_pkt; no_rx;
    chk(drop_cnt === 32'd7, "C8 opcode policy drops");

    $display("CASE C9");
    // ---- C9: 背压保持 + 字段稳定 ----
    pkt[0]=8'h00; pkt[1]=8'h03; pkt[2]=8'h00; pkt[3]=8'h09;
    for (i = 0; i < 8; i = i + 1) pkt[4+i] = payb(i);
    pn = 12; send_pkt;
    wait_rx;
    d0 = rx_block; d1 = rx_data_len;
    chk(out_ready === 1'b0, "C9 upstream backpressure while holding");
    for (i = 0; i < 5; i = i + 1) begin
      @(negedge clk);
      chk(rx_valid === 1'b1 && rx_block === d0 && rx_data_len === d1, "C9 descriptor stable");
    end
    // 试图在保持期间发送下一包首字节：out_ready=0，DUT 不得消费
    @(negedge clk); in_vld = 1; in_sop = 1; in_eop = 0; in_data = 8'h00;
    @(negedge clk);
    chk(out_ready === 1'b0, "C9 no new byte accepted while holding");
    consume_rx;
    // 保持的字节此时被接收（sop 已置）
    @(negedge clk);
    in_vld = 0; in_sop = 0;
    chk(ok_cnt === 32'd5, "C9 ok count");

    $display("CASE C10");
    // ---- C10: 消费后恢复接收 ----
    pkt[0]=8'h00; pkt[1]=8'h03; pkt[2]=8'h00; pkt[3]=8'h0A;
    for (i = 0; i < 4; i = i + 1) pkt[4+i] = payb(i);
    pn = 8; send_pkt;
    wait_rx;
    chk(rx_block === 16'h000A, "C10 recovery after backpressure");
    consume_rx;

    $display("CASE C11");
    // ---- C11: 超缓冲（600B）整包丢弃 ----
    for (i = 0; i < 600; i = i + 1) pkt[i] = (i == 0) ? 8'h00 : ((i == 1) ? 8'h03 : 8'h55);
    pn = 600; send_pkt;
    no_rx;
    chk(drop_cnt === 32'd8, "C11 oversized packet dropped");

    if (errors == 0) $display("T54 DGRAM_RX PASS checks=%0d ok=%0d drop=%0d", checks, ok_cnt, drop_cnt);
    else $display("T54 DGRAM_RX FAIL errors=%0d", errors);
    $finish;
  end
  initial begin #4000000; $display("T54 DGRAM_RX FAIL timeout"); $finish; end
endmodule
