// T22a — 冷启动后通过前门配置、PMEM 写/读回、MSG_WR 发一帧 A/B。
// 仅验证 TX 前门闭环（含 VL0 Q20 份额）；完整版 T22 的 RX 哈希/接收回环尚未完成。
`timescale 1 ns / 1 ps
module tb_t22a_frontdoor_tx;
  reg clk = 1'b0, reset = 1'b1;
  always #4 clk = ~clk;
  reg host_cs = 0, host_we = 0;
  reg [15:0] host_addr = 0;
  reg [31:0] host_wdata = 0;
  wire [31:0] host_rdata;
  wire host_ack, host_irq;
  wire [7:0] tx_data, tx_data_b;
  wire tx_valid, tx_valid_b, tx_ready, tx_ready_b;
  AFDX_top #(.IF_MODE(0), .FCS_MODE(2)) dut (
    .rx_error(1'b0), .rx_error_b(1'b0),
    .clk(clk), .reset(reset),
    .tx_data(tx_data), .rx_data(8'd0), .tx_valid(tx_valid), .rx_valid(1'b0),
    .tx_ready(tx_ready), .rx_ready(1'b1),
    .tx_data_b(tx_data_b), .tx_valid_b(tx_valid_b), .tx_ready_b(tx_ready_b),
    .rx_data_b(8'd0), .rx_valid_b(1'b0), .rx_ready_b(1'b1),
    .host_cs(host_cs), .host_we(host_we), .host_addr(host_addr), .host_wdata(host_wdata),
    .host_rdata(host_rdata), .host_ack(host_ack), .host_irq(host_irq),
    .pps_in(1'b0), .pps_out(), .rtc_time_us(), .dbg_frame_event());

  integer errors = 0, cycles = 0, na = 0, nb = 0, last_a = -1, frame_done_count = 0;
  reg [7:0] bytes_a [0:127], bytes_b [0:127];
  reg [31:0] crc_a = 32'hFFFF_FFFF, crc_b = 32'hFFFF_FFFF;
  reg [31:0] rd, word_exp;
  integer i, j, waitc, blk, base_addr;
  function [31:0] crc_step;
    input [31:0] c;
    input [7:0] d;
    integer k;
    reg [31:0] x;
    begin
      x = c ^ {24'd0,d};
      for (k = 0; k < 8; k = k+1) x = x[0] ? (x >> 1) ^ 32'hEDB8_8320 : (x >> 1);
      crc_step = x;
    end
  endfunction
  always @(posedge clk) begin
    cycles = cycles + 1;
    if (!reset) begin
      if (tx_valid) begin
        if (!dut.init_done || !dut.ctl_r[0]) begin
          $display("  [err] TX before INIT_DONE / TX_EN"); errors = errors + 1;
        end
        if (!tx_ready) begin $display("  [err] byte outside ready envelope"); errors = errors + 1; end
        if (na > 0 && cycles - last_a != 10) begin
          $display("  [err] byte gap=%0d (want 10)",cycles-last_a); errors = errors + 1;
        end
        last_a = cycles;
        if (na < 128) bytes_a[na] = tx_data;
        na = na + 1;
        crc_a = crc_step(crc_a,tx_data);
      end
      if (tx_valid_b) begin
        if (nb < 128) bytes_b[nb] = tx_data_b;
        nb = nb + 1;
        crc_b = crc_step(crc_b,tx_data_b);
      end
      if (dut.rm_frame_done) frame_done_count = frame_done_count + 1;
    end
  end
  task host_write(input [15:0] a, input [31:0] d);
    begin
      @(negedge clk); host_cs <= 1'b1; host_we <= 1'b1; host_addr <= a; host_wdata <= d;
      @(negedge clk);
      if (host_ack !== 1'b1) begin $display("  [err] write ack @%h",a); errors = errors + 1; end
      host_cs <= 1'b0; host_we <= 1'b0;
    end
  endtask
  task host_read(input [15:0] a, output [31:0] d);
    begin
      @(negedge clk); host_cs <= 1'b1; host_we <= 1'b0; host_addr <= a;
      @(negedge clk);
      if (host_ack !== 1'b1) begin $display("  [err] read ack @%h",a); errors = errors + 1; end
      d = host_rdata;
      host_cs <= 1'b0;
    end
  endtask
  initial begin
    repeat (7) @(negedge clk); reset <= 1'b0;
    repeat (4) @(negedge clk);
    host_write(16'h0008, 32'h3);    // 未完成初始化不能使能收/发
    host_read(16'h0008, rd);
    if (rd[1:0] !== 0) begin $display("  [err] early enable accepted"); errors = errors+1; end
    host_read(16'h0010, rd);
    if (!rd[0]) begin $display("  [err] early ACC missing"); errors = errors+1; end
    host_write(16'h0010, 32'h1);
    waitc = 0;
    while (dut.init_done !== 1'b1 && waitc < 27000) begin @(negedge clk); waitc = waitc+1; end
    if (waitc >= 27000) begin $display("  [err] init timeout"); errors=errors+1; end
    host_read(16'h000C, rd);
    if (rd[13] !== 1'b1 || rd[7:2] !== 6'd15) begin
      $display("  [err] init/status/free=%h",rd); errors=errors+1;
    end
    // 按附录 B 配置 port0 与 TX VL0。w0.valid 最后写，避免部分项上线。
    host_write(16'h0008, 32'h2000);  // CFG_MODE=1、TX_EN=0
    host_write(16'h0060, 32'h1234_2001); // UDI=0x1234, IFID A=1/B=2
    host_write(16'h0064, 32'h0A00_0001);
    host_write(16'h0070, 32'h0000_0142); // 开 UDP 校验和
    host_write(16'h7D83, 32'h0000_0001); // port0 depth=1
    host_write(16'h7D80, 32'h8000_C000); // valid, sampling, src port 49152
    host_write(16'h0204, 32'h0000_0000); // port_base=0
    host_write(16'h0203, 32'hE000_0001); // dst_ip
    host_write(16'h0202, 32'h1388_C000); // dp=5000, sp=49152
    host_write(16'h0201, 32'h0003_E800); // BAG 1000 us
    host_write(16'h0480, 32'd8305);     // ceil((79+20)*80ns/1000us*2^20)
    host_write(16'h0200, 32'h8004_F003); // valid, Lmax=79, net A+B
    host_read(16'h0480, rd);
    if (rd !== 32'd8305) begin $display("  [err] share readback %h",rd); errors=errors+1; end
    host_read(16'h0058, rd);
    if (rd !== 32'd8305) begin $display("  [err] CFG_SUM %h",rd); errors=errors+1; end
    host_read(16'h005C, rd);
    if (rd !== 32'd0) begin $display("  [err] CFG_ERR %h",rd); errors=errors+1; end
    host_read(16'h0202, rd);
    if (rd !== 32'h1388_C000) begin $display("  [err] TX config readback %h",rd); errors=errors+1; end
    host_write(16'h3D80, 32'h1000_0100); // 离线哈希映像前门写口冒烟（尚无 RX 查表）
    if (dut.u_rxlookup.table0way0[0] !== 32'h1000_0100) begin $display("  [err] hash RAM frontdoor write"); errors=errors+1; end
    host_read(16'h3D80, rd);
    if (rd !== 32'h1000_0100) begin $display("  [err] hash RAM frontdoor readback: %h",rd); errors=errors+1; end
    host_read(16'h0074, rd);
    if (rd !== 32'h10) begin $display("  [err] TX_WR_BLK %h (want block0 open)",rd); errors=errors+1; end
    blk = rd[3:0]; base_addr = 16'h8800 + (blk << 9);
    // 每拍一笔 PMEM 写，覆盖 32 字节；主机数据字按网络序映射。
    @(negedge clk); host_cs <= 1'b1; host_we <= 1'b1;
    for (i=0; i<8; i=i+1) begin
      host_addr <= base_addr + i; host_wdata <= 32'hA0B0_C0D0 + i;
      @(negedge clk);
      if (host_ack !== 1'b1) begin $display("  [err] PMEM burst ack word=%0d",i); errors=errors+1; end
    end
    host_cs <= 1'b0; host_we <= 1'b0;
    host_read(base_addr[15:0], rd);
    if (rd !== 32'hA0B0_C0D0) begin $display("  [err] PMEM frontdoor readback first=%h",rd); errors=errors+1; end
    host_read((base_addr+7), rd);
    if (rd !== 32'hA0B0_C0D7) begin $display("  [err] PMEM frontdoor readback last=%h",rd); errors=errors+1; end
    host_write(16'h0008, 32'h0000_0001);  // 退出 CFG_MODE，开流
    host_write(16'h8280, 32'd32);        // MSG_WR[port0]，L=32
    waitc = 0;
    while ((na < 79 || nb < 79) && waitc < 20000) begin @(negedge clk); waitc=waitc+1; end
    if (na != 79 || nb != 79) begin $display("  [err] transmitted bytes A=%0d B=%0d",na,nb); errors=errors+1; end
    else begin
      if (crc_a !== 32'hDEBB_20E3 || crc_b !== 32'hDEBB_20E3) begin
        $display("  [err] FCS A=%h B=%h",crc_a,crc_b); errors=errors+1;
      end
      if (bytes_a[0] !== 8'h03 || bytes_a[4] !== 8'h01 || bytes_a[5] !== 8'h00 ||
          bytes_a[9] !== 8'h12 || bytes_a[10] !== 8'h34 || bytes_a[11] !== 8'h20 ||
          bytes_b[11] !== 8'h40 || {bytes_a[16],bytes_a[17]} !== 16'd60 ||
          {bytes_a[38],bytes_a[39]} !== 16'd40 || bytes_a[74] !== 8'd1) begin
        $display("  [err] A/B header, IP/UDP length or SN mismatch"); errors=errors+1;
      end
      for (i=0; i<8; i=i+1) begin
        word_exp = 32'hA0B0_C0D0 + i;
        for (j=0; j<4; j=j+1)
          if (bytes_a[42+4*i+j] !== word_exp[31-8*j -: 8]) begin
            $display("  [err] payload byte%0d got=%h want=%h",4*i+j,bytes_a[42+4*i+j],word_exp[31-8*j -: 8]);
            errors=errors+1;
          end
      end
      for (i=0; i<75; i=i+1)
        if (i!=11 && bytes_a[i] !== bytes_b[i]) begin
          $display("  [err] A/B byte%0d differ: %h %h",i,bytes_a[i],bytes_b[i]); errors=errors+1;
        end
    end
    repeat (12) @(negedge clk);
    host_read(16'h0074, rd);
    if (rd[4] !== 1'b1 || rd[3:0] !== 4'd1) begin $display("  [err] next open block %h",rd); errors=errors+1; end
    if (dut.rm_frames_a !== 16'd1 || dut.rm_frames_b !== 16'd1 || frame_done_count != 1 ||
        dut.mac_a_underrun != 16'd0 || dut.mac_b_underrun != 16'd0 ||
        dut.sch_miss_cnt != 16'd0 || dut.u_sn.sn_cur[0] !== 8'd2) begin
      $display("  [err] stats A=%0d B=%0d done=%0d underrun=%0d/%0d miss=%0d SN=%0d",
               dut.rm_frames_a,dut.rm_frames_b,frame_done_count,dut.mac_a_underrun,
               dut.mac_b_underrun,dut.sch_miss_cnt,dut.u_sn.sn_cur[0]); errors=errors+1;
    end
    if (errors == 0) $display("T22a FRONTDOOR-TX PASS (init + table/PMEM frontdoor + A/B FCS/SN/payload)");
    else             $display("T22a FRONTDOOR-TX FAIL: %0d errors",errors);
    begin : dump_hex
      integer fa, fb, k;
      fa = $fopen("out/t22a_tx_a.hex", "w");
      fb = $fopen("out/t22a_tx_b.hex", "w");
      if (fa && fb && na==79 && nb==79) begin
        for (k=0; k<79; k=k+1) $fwrite(fa, "%02x", bytes_a[k]);
        for (k=0; k<79; k=k+1) $fwrite(fb, "%02x", bytes_b[k]);
        $fwrite(fa, "\n"); $fwrite(fb, "\n");
        $display("  dumped out/t22a_tx_a.hex / t22a_tx_b.hex for second oracle");
      end
      if (fa) $fclose(fa);
      if (fb) $fclose(fb);
    end
    $finish;
  end
  initial begin
    #2_000_000;
    $display("T22a FRONTDOOR-TX FAIL: timeout"); $finish;
  end
endmodule
