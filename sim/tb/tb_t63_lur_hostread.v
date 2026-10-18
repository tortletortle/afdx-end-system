// =====================================================================
// T63 — 615A LUR 宿主观测读路径 逐字节验证（P05 集成）
//
// 覆盖 P05 剩余项 1：宿主通过 0xAC88/0xAC89/0xAC8A/0xAC8B 观测 lur_rx
// 已解析清单的名字与长度。此路径与编排器搬运路径共用 lur_rx 的单口名字
// 读口，但走宿主导航（lur_host_index/lur_host_read），需独立验证：
//
//   H1 0xAC86 名字长度（含 NUL）与清单一致（0/1/2 条目）
//   H2 file_select = 0 时逐字节读回 "A.BIN\0"（0xAC89 == 41 2E 42 49 4E 00）
//   H3 file_select = 1（0xAC88）后逐字节读回 "LONGNAME.BIN\0"
//   H4 file_select = 2 后逐字节读回 "C.DE\0"
//   H5 越界索引（index >= name_len）读回 0（lur_rx 只在范围内驱动 query_valid）
//   H6 读口时序：0xAC8B 写 1 后名字字节在 0xAC89 稳定可读（含 1 拍寄存延迟）
//   H7 file_select 复位回 0（0xAC87 关断上传后宿主仍可观测）
//   H8 编排器运行时宿主读口不干扰（本用例仅启上传，不起编排器，作对拍基线）
//
// 上传路径：仅走公开 GMII 下行一帧 LUR 清单（UDP → 管理 SAP）。
// 清单由 gen_t62_vectors.py 同一构造器生成，本用例额外读入 t63 专用向量。
// =====================================================================
`timescale 1 ns / 1 ps
`include "vec/t63_lur_hostrd.vh"
module tb_t63_lur_hostread;
  reg clk=0, reset=1;
  always #4 clk=~clk;
  reg [7:0] rx_data=0;
  reg rx_valid=0;
  wire [7:0] tx_data[0:1];
  wire tx_valid[0:1];
  wire hcs,hwe,hack;
  wire [15:0] haddr;
  wire [31:0] hwdata,hrdata;
  AFDX_top #(.TFTP_TIMEOUT_US(50)) dut (
    .clk(clk),.reset(reset),.tx_data(tx_data[0]),.tx_valid(tx_valid[0]),.tx_ready(),
    .rx_data(rx_data),.rx_valid(rx_valid),.rx_ready(1'b0),.rx_error(1'b0),
    .tx_data_b(tx_data[1]),.tx_valid_b(tx_valid[1]),.tx_ready_b(),
    .rx_data_b(8'd0),.rx_valid_b(1'b0),.rx_ready_b(1'b0),.rx_error_b(1'b0),
    .host_cs(hcs),.host_we(hwe),.host_addr(haddr),.host_wdata(hwdata),
    .host_rdata(hrdata),.host_ack(hack),.host_irq(),
    .pps_in(1'b0),.pps_out(),.rtc_time_us(),.dbg_frame_event());
  afdx_host_bfm u_host (.clk(clk),.cs(hcs),.we(hwe),.addr(haddr),.wdata(hwdata),.rdata(hrdata),.ack(hack));

  reg [31:0] vec[0:`T63_WORDS-1];
  reg [31:0] himg[0:8191];
  reg [31:0] hmeta[0:3];
  integer errors=0, checks=0, cycle=0;
  integer guard, i, j;

  task bad;
    input [8*112-1:0] reason;
    begin if (errors<20) $display("  [err] T63 cyc=%0d %0s", cycle, reason); errors=errors+1; end
  endtask
  task chk;
    input cond; input [8*112-1:0] reason;
    begin checks=checks+1; if (!cond) bad(reason); end
  endtask

  always @(posedge clk) cycle <= cycle+1;

  // ---- 向量 / 哈希映像加载 ----
  initial begin
    $readmemh("vec/t63_lur_hostrd.hex", vec, 0, `T63_WORDS-1);
    $readmemh("vec/t12_top.img.hex", himg, 0, 8191);
    $readmemh("vec/t12_top.meta.hex", hmeta, 0, 3);
  end

  // ---- 主机访问 ----
  task read_word;
    input [15:0] address; output [31:0] value;
    integer g;
    begin
      @(negedge clk); u_host.cs=1; u_host.we=0; u_host.addr=address;
      @(negedge clk); g=0;
      while (hack!==1'b1 && g<64) begin @(negedge clk); g=g+1; end
      if (hack!==1'b1) bad("host read timeout");
      value=hrdata; u_host.cs=0;
    end
  endtask
  task write_word;
    input [15:0] address; input [31:0] value;
    begin u_host.wr(address, value); end
  endtask

  // ---- 下行注入（前导+SFD+帧；1B/拍）----
  integer flen;
  function [7:0] fbyte; input integer base, off; reg [31:0] w;
    begin w=vec[base+(off>>2)];
      case (off&3) 0:fbyte=w[31:24]; 1:fbyte=w[23:16]; 2:fbyte=w[15:8]; default:fbyte=w[7:0];
      endcase
    end
  endfunction
  task inject;
    input integer frame_no;
    integer b, base;
    begin
      base = 1;
      for (b = 0; b < frame_no; b = b + 1) base = base + 1 + (vec[base]+3)/4;
      flen = vec[base];
      @(negedge clk);
      for (i=0; i<flen+8; i=i+1) begin
        rx_valid=1; rx_data=(i<7)?8'h55:((i==7)?8'hD5:fbyte(base+1,i-8));
        @(negedge clk);
      end
      rx_valid=0; @(negedge clk);
    end
  endtask

  // ---- LUR 宿主窗访问 ----
  task read_lur;
    input [5:0] off; output [31:0] v;
    begin read_word(16'hAC80 + {10'd0, off}, v); end
  endtask
  task write_lur;
    input [5:0] off; input [31:0] v;
    begin write_word(16'hAC80 + {10'd0, off}, v); end
  endtask

  // ---- 宿主单字节名字读：先写索引(0xAC8A)、再写读触发(0xAC8B=1)、后读(0xAC89) ----
  // 说明：0xAC8B 的写请求组合进入 lur_rx（1 拍发出），lur_rx 的 name_byte 为寄存
  // 输出，故写入后须再等 ≥1 拍，顶层已把该请求展宽并在对齐拍锁存进 0xAC89。
  task read_name_byte;
    input [2:0] sel; input [7:0] idx; output [7:0] b;
    reg [31:0] v;
    begin
      write_lur(6'h08, {29'd0, sel});      // 0xAC88 条目选择
      write_lur(6'h0A, {24'd0, idx});      // 0xAC8A 名字字节索引
      @(negedge clk); @(negedge clk);      // 让 lur_rx 组合选择稳定
      write_lur(6'h0B, 32'd1);             // 0xAC8B 读触发
      @(negedge clk); @(negedge clk); @(negedge clk);
      read_lur(6'h09, v);                  // 0xAC89 名字字节
      b = v[7:0];
    end
  endtask

  // ---- 逐字节校验一个清单条目 ----
  // 期望字符串以 16 进制逐字节给出；n = 含 NUL 的长度（等于 0xAC86）。
  task check_name;
    input [2:0] sel;
    input [7:0] n;              // 含 NUL 的长度
    input [7:0] d0, d1, d2, d3, d4, d5, d6, d7, d8, d9, d10, d11;
    reg [31:0] v;
    reg [7:0]  got [0:11];
    reg [7:0]  exp [0:11];
    reg [8*96-1:0] tag;         // 条目描述（短标签）
    integer k;
    begin
      exp[0]=d0; exp[1]=d1; exp[2]=d2;  exp[3]=d3;
      exp[4]=d4; exp[5]=d5; exp[6]=d6;  exp[7]=d7;
      exp[8]=d8; exp[9]=d9; exp[10]=d10; exp[11]=d11;
      case (sel) 3'd0: tag="A.BIN"; 3'd1: tag="LONGNAME.BIN"; default: tag="C.DE"; endcase
      // 先切条目选择（0xAC88 是寄存写，须等 2 拍生效），再读长度。
      // lur_rx 的 filename_length 是「组合」跟随 file_select 的，若先读长度
      // 会拿到上一轮选择的条目长度。
      write_lur(6'h08, {29'd0, sel});
      @(negedge clk); @(negedge clk);
      // 0xAC86 长度
      read_lur(6'h06, v);
      chk(v[7:0]===n, "0xAC86 name_len matches manifest");
      // 逐字节
      for (k=0; k<n && k<12; k=k+1) begin
        read_name_byte(sel, k[7:0], got[k]);
      end
      for (k=0; k<n && k<12; k=k+1) begin
        chk(got[k]===exp[k], "name byte mismatch (sel/index)");
      end
      $display("  [name] sel=%0d len=%0d bytes=%02x %02x %02x %02x %02x %02x %02x %02x",
               sel, n, got[0], got[1], got[2], got[3], got[4], got[5], got[6], got[7]);
    end
  endtask

  // ---- 配置 ----
  task configure;
    integer g; reg [31:0] v;
    begin
      reset=1; repeat(8) @(negedge clk); reset=0;
      read_word(16'h000C,v); g=0;
      while(!v[13] && g<30000) begin read_word(16'h000C,v); g=g+1; end
      if(!v[13]) bad("init timeout");
      write_word(16'h0008,32'h2000);
      // RX VLID 哈希映像（VLID 0x100 → index 256）
      u_host.wr(16'h0078, hmeta[0]); u_host.wr(16'h007C, hmeta[1]);
      for (g=0; g<8192; g=g+1) u_host.wr(16'h3D80+g, himg[g]);
      write_word(16'h42B2,32'h10100100); write_word(16'h0080,1);
      read_word(16'h0080,v); if(v[0]!==1'b1) bad("hash commit absent");
      // RX VL 表：key 0x100 → index 256
      write_word(16'h1D80+(256<<1), 32'hF5000000|(256<<12)|1400);
      write_word(16'h1D81+(256<<1), 32'h0100);
      // RX 端口表：port 7，w1[15:0] == 下行帧 UDP dport 0x3001
      write_word(16'h7D80+4*7,32'h80060000);
      write_word(16'h7D81+4*7,32'h00003001); write_word(16'h7D82+4*7,0); write_word(16'h7D83+4*7,1);
      // TX VL 0 → 端口 7，BAG 1000us
      write_word(16'h1F80,32'hF5000000|(7<<12)|1400); write_word(16'h1F81,32'h0100);
      write_word(16'h0204,7<<16); write_word(16'h0203,0); write_word(16'h0202,5000<<16);
      write_word(16'h0201,1000<<8); write_word(16'h0480,6040);
      write_word(16'h0200,32'h80000003|(1400<<12));
      write_word(16'h0060,32'h172D2001); write_word(16'h0064,32'h0A000002);
      write_word(16'h0070,32'h0142);
      read_word(16'h005C,v); if(v!==0) bad("legal management configuration rejected");
      write_word(16'h0008,32'h071F);
    end
  endtask

  task wait_guard;
    input integer n;
    begin for (guard=0; guard<n; guard=guard+1) @(negedge clk); end
  endtask

  reg [31:0] v;
  integer k;
  reg [7:0] got;

  initial begin
    rst_phase: begin
      reset=1; repeat(10) @(negedge clk); reset=0;
    end
    $display("T63 CASE configure");
    configure;

    // ---------- 上传 LUR 清单 ----------
    $display("T63 CASE upload manifest over GMII");
    write_word(16'hAC87, 32'h1);          // lur_upload_mode=1 → SAP 路由到 lur_rx
    repeat (20) @(negedge clk);
    inject(0);                            // 清单帧（向量 0 号帧）
    repeat (2000) @(negedge clk);

    begin : lurstat
      read_lur(6'h05, v);
      chk(v[2]===1'b1, "H0 LUR result_valid");
      chk(v[1]===1'b1, "H0 LUR request_ok");
      chk(v[6:3]===4'd0, "H0 LUR error_code == 0");
      read_lur(6'h04, v);
      chk(v[15:0]===16'd3, "H0 LUR file_count == 3");
    end

    // 关断上传接收态，回到宿主观测
    write_word(16'hAC87, 32'h0);
    repeat (20) @(negedge clk);

    // ---------- H2: 条目 0 = "A.BIN\0"（6 字节）----------
    $display("T63 CASE H2 sel=0 A.BIN");
    check_name(3'd0, 8'd6,
               8'h41, 8'h2E, 8'h42, 8'h49, 8'h4E, 8'h00, 8'h00, 8'h00,
               8'h00, 8'h00, 8'h00, 8'h00);

    // ---------- H3: 条目 1 = "LONGNAME.BIN\0"（13 字节）----------
    $display("T63 CASE H3 sel=1 LONGNAME.BIN");
    check_name(3'd1, 8'd13,
               8'h4C, 8'h4F, 8'h4E, 8'h47, 8'h4E, 8'h41, 8'h4D, 8'h45,
               8'h2E, 8'h42, 8'h49, 8'h4E);

    // ---------- H4: 条目 2 = "C.DE\0"（5 字节）----------
    $display("T63 CASE H4 sel=2 C.DE");
    check_name(3'd2, 8'd5,
               8'h43, 8'h2E, 8'h44, 8'h45, 8'h00, 8'h00, 8'h00, 8'h00,
               8'h00, 8'h00, 8'h00, 8'h00);

    // ---------- H5: 越界索引读回 0 ----------
    $display("T63 CASE H5 out-of-range index");
    begin : oob
      read_name_byte(3'd0, 8'd6, got);          // 索引 6 == len（越界）
      chk(got===8'd0, "H5 index==len reads 0 (sel0)");
      read_name_byte(3'd0, 8'd200, got);        // 远越界
      chk(got===8'd0, "H5 index=200 reads 0 (sel0)");
      read_name_byte(3'd2, 8'd5, got);          // len=5，索引 5 越界
      chk(got===8'd0, "H5 index==len reads 0 (sel2)");
    end

    // ---------- H6: 时序稳定性 —— 同一索引连续两次读一致 ----------
    $display("T63 CASE H6 repeat read stability");
    begin : rep
      reg [7:0] a, b;
      read_name_byte(3'd1, 8'd3, a);   // "G"
      read_name_byte(3'd1, 8'd3, b);
      chk(a===8'h47 && b===8'h47, "H6 repeated read of index 3 stable (=G)");
      read_name_byte(3'd1, 8'd0, a);
      chk(a===8'h4C, "H6 first byte = L");
    end

    // ---------- H7: 0xAC89 读回后 0xAC88/0xAC8A/0xAC8B 可回读 ----------
    $display("T63 CASE H7 register readback");
    begin : regrb
      write_lur(6'h08, 32'd1); read_lur(6'h08, v);
      chk(v[2:0]===3'd1, "H7 0xAC88 select readback == 1");
      write_lur(6'h0A, 32'd7); read_lur(6'h0A, v);
      chk(v[7:0]===8'd7, "H7 0xAC8A index readback == 7");
      read_lur(6'h07, v);
      chk(v[0]===1'b0, "H7 0xAC87 upload_mode readback == 0");
    end

    if (errors==0) $display("T63 LUR HOST RD PASS checks=%0d", checks);
    else $display("T63 LUR HOST RD FAIL errors=%0d", errors);
    $finish;
  end

  initial begin #60000000; $display("T63 LUR HOST RD FAIL timeout"); $finish; end
endmodule
