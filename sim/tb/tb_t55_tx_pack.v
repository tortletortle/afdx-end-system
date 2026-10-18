// =====================================================================
// T55 — a615a_tftp_tx_pack：client 发射描述符 → 完整 TFTP 报文（P05，2026-10-10）
//
// 覆盖：RRQ/WRQ（filename+octet 布局）、DATA 满块/短块、ACK、ERROR（码+文本）、
// 目标字段锁存、pkt_len 与字节内容独立对账、保持期间读口稳定、pkt_ack 释放、
// 非法描述符（fnlen=0 / DATA len=513）接受但不发包并计数、连续多包。
// =====================================================================
`timescale 1 ns / 1 ps
module tb_t55_tx_pack;
  reg clk = 0;
  always #4 clk = ~clk;
  reg rst = 1, en = 1;

  reg        tx_valid = 0;
  wire       tx_ready;
  reg [2:0]  tx_opcode = 0;
  reg [15:0] tx_block = 0;
  reg [15:0] tx_error_code = 0;
  reg [9:0]  tx_data_len = 0;
  reg [4095:0] tx_data = 0;
  reg [2047:0] tx_filename = 0;
  reg [7:0]  tx_filename_len = 0;
  reg        tx_mode_octet = 1;
  reg [31:0] tx_dst_ip = 32'h0A000002;
  reg [15:0] tx_src_port = 16'h1234;
  reg [15:0] tx_dst_port = 16'd69;

  wire        pkt_vld;
  wire [10:0] pkt_len;
  wire [31:0] pkt_dst_ip;
  wire [15:0] pkt_src_port, pkt_dst_port;
  reg [10:0]  pkt_rd_addr = 0;
  wire [7:0]  pkt_byte;
  reg         pkt_ack = 0;
  wire [31:0] pkt_cnt, err_cnt;

  a615a_tftp_tx_pack dut (
    .clk(clk), .rst_sync(rst), .en(en),
    .tx_valid(tx_valid), .tx_ready(tx_ready),
    .tx_opcode(tx_opcode), .tx_block(tx_block), .tx_error_code(tx_error_code),
    .tx_data_len(tx_data_len), .tx_data(tx_data),
    .tx_filename(tx_filename), .tx_filename_len(tx_filename_len),
    .tx_mode_octet(tx_mode_octet),
    .tx_dst_ip(tx_dst_ip), .tx_src_port(tx_src_port), .tx_dst_port(tx_dst_port),
    .pkt_vld(pkt_vld), .pkt_len(pkt_len), .pkt_dst_ip(pkt_dst_ip),
    .pkt_src_port(pkt_src_port), .pkt_dst_port(pkt_dst_port),
    .pkt_rd_addr(pkt_rd_addr), .pkt_byte(pkt_byte), .pkt_ack(pkt_ack),
    .pkt_cnt(pkt_cnt), .err_cnt(err_cnt)
  );

  integer errors = 0, checks = 0;
  task bad;
    input [8*96-1:0] reason;
    begin if (errors < 15) $display("  [err] T55 %0s", reason); errors = errors + 1; end
  endtask
  task chk;
    input cond; input [8*96-1:0] reason;
    begin checks = checks + 1; if (!cond) bad(reason); end
  endtask

  function [7:0] payb; input integer j; begin payb = (j * 5 + 8'h42) & 8'hFF; end endfunction
  function [7:0] datb; input [4095:0] d; input integer j;
    begin datb = d[4095 - 8*j -: 8]; end
  endfunction
  function [7:0] fnb; input [2047:0] d; input integer j;
    begin fnb = d[2047 - 8*j -: 8]; end
  endfunction

  // 独立期望字节构造
  reg [7:0] expb [0:600];
  integer en_;
  function [7:0] modec; input integer k;
    begin case (k) 0:modec="o";1:modec="c";2:modec="t";3:modec="e";4:modec="t";
                     default:modec=8'h00; endcase end
  endfunction
  task build_expect_rq;
    input [2:0] op; input integer flen;
    integer i;
    begin
      expb[0]=8'h00; expb[1]={5'd0,op};
      for (i=0;i<flen;i=i+1) expb[2+i]=fnb(tx_filename,i);
      expb[2+flen]=8'h00;
      for (i=0;i<5;i=i+1) expb[3+flen+i]=modec(i);
      expb[8+flen]=8'h00;
      en_=flen+9;
    end
  endtask
  task build_expect_data;
    input [15:0] blk; input integer dlen;
    integer i;
    begin
      expb[0]=8'h00; expb[1]=8'h03; expb[2]=blk[15:8]; expb[3]=blk[7:0];
      for (i=0;i<dlen;i=i+1) expb[4+i]=datb(tx_data,i);
      en_=dlen+4;
    end
  endtask
  task build_expect_ack;
    input [15:0] blk;
    begin
      expb[0]=8'h00; expb[1]=8'h04; expb[2]=blk[15:8]; expb[3]=blk[7:0];
      en_=4;
    end
  endtask
  task build_expect_err;
    input [15:0] code; input integer dlen;
    integer i;
    begin
      expb[0]=8'h00; expb[1]=8'h05; expb[2]=code[15:8]; expb[3]=code[7:0];
      for (i=0;i<dlen;i=i+1) expb[4+i]=datb(tx_data,i);
      en_=dlen+4;
    end
  endtask

  integer guard, i, b0, b1;
  task fire_tx;
    begin
      guard = 0;
      while (tx_ready !== 1'b1 && guard < 50) begin @(negedge clk); guard = guard + 1; end
      if (tx_ready !== 1'b1) bad("tx_ready timeout");
      @(negedge clk); tx_valid = 1;
      @(negedge clk); tx_valid = 0;
    end
  endtask

  task wait_pkt;
    begin
      guard = 0;
      while (pkt_vld !== 1'b1 && guard < 3000) begin @(negedge clk); guard = guard + 1; end
      if (pkt_vld !== 1'b1) bad("pkt_vld timeout");
      @(negedge clk);
      chk(pkt_len === en_[10:0], "packet length");
    end
  endtask

  task check_bytes;
    begin
      for (i = 0; i < en_; i = i + 1) begin
        pkt_rd_addr = i[10:0]; #1;
        if (pkt_byte !== expb[i]) begin
          if (i < 5 || i > en_-3)
            $display("  [dbg] byte %0d got %02x exp %02x", i, pkt_byte, expb[i]);
          bad("packet byte mismatch");
        end
        checks = checks + 1;
      end
    end
  endtask

  task ack_pkt;
    begin
      @(negedge clk); pkt_ack = 1;
      @(negedge clk); pkt_ack = 0;
      @(negedge clk);
      chk(pkt_vld === 1'b0, "pkt_vld cleared by ack");
    end
  endtask

  initial begin
    repeat (5) @(negedge clk);
    rst = 0; repeat (2) @(negedge clk);

    // ---- C1: RRQ "FW.BIN" ----
    tx_opcode = 3'd1; tx_filename = 0;
    tx_filename[2047 -: 8]="F"; tx_filename[2039 -: 8]="W"; tx_filename[2031 -: 8]=".";
    tx_filename[2023 -: 8]="B"; tx_filename[2015 -: 8]="I"; tx_filename[2007 -: 8]="N";
    tx_filename_len = 8'd6;
    tx_dst_port = 16'd69; tx_src_port = 16'h1001;
    build_expect_rq(3'd1, 6);
    fire_tx; wait_pkt;
    chk(pkt_dst_ip === 32'h0A000002 && pkt_src_port === 16'h1001 && pkt_dst_port === 16'd69,
        "C1 packet destination fields");
    check_bytes; ack_pkt;

    // ---- C2: WRQ（同一文件）----
    tx_opcode = 3'd2;
    build_expect_rq(3'd2, 6);
    fire_tx; wait_pkt;
    check_bytes; ack_pkt;

    // ---- C3: DATA 512B ----
    tx_opcode = 3'd3; tx_block = 16'h0234; tx_data_len = 10'd512;
    tx_data = 4096'd0;
    for (i = 0; i < 512; i = i + 1) tx_data[4095 - 8*i -: 8] = payb(i);
    tx_dst_port = 16'd40100;
    build_expect_data(16'h0234, 512);
    fire_tx; wait_pkt;
    chk(pkt_dst_port === 16'd40100, "C3 dst port follows descriptor");
    check_bytes; ack_pkt;

    // ---- C4: DATA 短块 8B ----
    tx_opcode = 3'd3; tx_block = 16'h0235; tx_data_len = 10'd8;
    tx_data = 4096'd0;
    for (i = 0; i < 8; i = i + 1) tx_data[4095 - 8*i -: 8] = payb(i);
    build_expect_data(16'h0235, 8);
    fire_tx; wait_pkt;
    check_bytes; ack_pkt;

    // ---- C5: ACK ----
    tx_opcode = 3'd4; tx_block = 16'h000A;
    build_expect_ack(16'h000A);
    fire_tx; wait_pkt;
    check_bytes; ack_pkt;

    // ---- C6: ERROR（code 5 + 20B 文本）----
    tx_opcode = 3'd5; tx_error_code = 16'd5; tx_data_len = 10'd20;
    tx_data = 4096'd0;
    for (i = 0; i < 20; i = i + 1) tx_data[4095 - 8*i -: 8] = (i < 18) ? (8'h41 + (i % 26)) : 8'h00;
    build_expect_err(16'd5, 20);
    fire_tx; wait_pkt;
    check_bytes; ack_pkt;

    // ---- C7: 非法描述符（fnlen=0；DATA len=513）→ 计数不出包 ----
    b0 = err_cnt; b1 = pkt_cnt;
    tx_opcode = 3'd2; tx_filename_len = 8'd0;
    fire_tx;
    repeat (30) @(negedge clk);
    chk(err_cnt === b0 + 32'd1 && pkt_cnt === b1 && pkt_vld === 1'b0, "C7 zero-fnlen rejected");
    tx_opcode = 3'd3; tx_data_len = 10'd513;
    fire_tx;
    repeat (30) @(negedge clk);
    chk(err_cnt === b0 + 32'd2 && pkt_cnt === b1 && pkt_vld === 1'b0, "C7 over-long DATA rejected");

    // ---- C8: 保持期间读口稳定 + 随机地址读一致 ----
    tx_opcode = 3'd3; tx_block = 16'h0555; tx_data_len = 10'd100;
    tx_data = 4096'd0;
    for (i = 0; i < 100; i = i + 1) tx_data[4095 - 8*i -: 8] = payb(i);
    build_expect_data(16'h0555, 100);
    fire_tx; wait_pkt;
    pkt_rd_addr = 11'd3; #1;
    b0 = pkt_byte;
    repeat (5) @(negedge clk);
    pkt_rd_addr = 11'd3; #1;
    chk(pkt_vld === 1'b1 && pkt_byte === b0, "C8 read port stable while held");
    pkt_rd_addr = 11'd50; #1;
    chk(pkt_byte === expb[50], "C8 mid-packet byte");
    ack_pkt;

    // ---- C9: 释放后可立即接下一包 ----
    tx_opcode = 3'd4; tx_block = 16'h0001;
    build_expect_ack(16'h0001);
    fire_tx; wait_pkt;
    check_bytes; ack_pkt;
    chk(pkt_cnt === 32'd8 + 32'd0, "C9 packet count");

    if (errors == 0) $display("T55 TX_PACK PASS checks=%0d pkts=%0d err=%0d", checks, pkt_cnt, err_cnt);
    else $display("T55 TX_PACK FAIL errors=%0d", errors);
    $finish;
  end
  initial begin #4000000; $display("T55 TX_PACK FAIL timeout"); $finish; end
endmodule
