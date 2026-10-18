// =====================================================================
// T57 — 615A 取件引擎 GMII 级加载（P05 集成，2026-10-10）
//
// TB 扮演装载端（server 10.0.0.2:40100）：经公开 GMII 端口与主机接口
// 执行「主机发起取件作业 → 目标端主动 RRQ → 装载端送 DATA → 目标端 ACK →
// 末块+dally → 主机读回完整文件」闭环；失败用例注入 ERROR 响应核对状态。
//
// 上行（DUT TX）按规范字段结构化核对：首帧 RRQ（opcode/端口 69/文件名），
// 其后须出现 ACK(1)/ACK(2)（块号与方向端口 40100），允许其间出现 ACK 重传。
// 下行（TB RX）帧来自独立构帧 gen_t57_vectors.py（FCS/UDP 校验和已核）。
// 文件内容经宿主窗 0xAC4E/0xAC4F 逐字节读回，与独立图案对账。
// =====================================================================
`timescale 1 ns / 1 ps
`include "vec/t57_fetch.vh"
module tb_t57_fetch_gmii;
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

  reg [31:0] vec[0:`T57_WORDS-1];
  reg [31:0] himg[0:8191];
  reg [31:0] hmeta[0:3];
  integer errors=0, checks=0, cycle=0;
  integer guard, i, j;

  task bad;
    input [8*112-1:0] reason;
    begin if (errors<20) $display("  [err] T57 cyc=%0d %0s", cycle, reason); errors=errors+1; end
  endtask
  task chk;
    input cond; input [8*112-1:0] reason;
    begin checks=checks+1; if (!cond) bad(reason); end
  endtask

  // ---- 上行帧收集（跳过前导/SFD；A 网为准，B 网同步核对）----
  // Physical capture: 7x55 + D5, Ethernet at byte8, IPv4 at22,
  // UDP at42, TFTP opcode at50..51, block at52..53, RRQ name at52.
  // cnt_a is one less than the physical array index after the first byte.
  // 关键点：上行帧字段必须在帧内逐拍锁存进 per-frame 数组，
  // 不能等帧尾回读滚动缓冲（那时内容已被后续帧覆盖）。
  integer fcnt=0;
  reg [2:0] f_op[0:15]; reg [15:0] f_blk[0:15]; reg [15:0] f_dp[0:15];
  reg [7:0]  f_b0[0:15]; reg [7:0]  f_b1[0:15];   // 载荷前两字节
  integer cnt_a=0, cnt_b=0; reg act_a=0, act_b=0;
  reg [7:0] rrq_a[0:640];        // 帧 0（RRQ）整帧快照（供文件名核对）

  // 独立计数器：从 tx_valid 首个高拍起逐拍 +1（含首拍）。
  // 与 cnt_a（首拍清零）分离，保证 RRQ 快照下标与线上字节严格一致。
  integer ridx = 0;
  always @(posedge clk) if (tx_valid[0] && fcnt==0) begin
    if (ridx<640) rrq_a[ridx] <= tx_data[0];
    ridx <= ridx + 1;
  end

  always @(posedge clk) begin
    cycle <= cycle+1;
    // A 网帧收集
    if (tx_valid[0]) begin
      if (!act_a) begin act_a<=1; cnt_a<=0; end
      else cnt_a<=cnt_a+1;
      if (fcnt<16) begin
        // Fields below use cnt_a; rrq_a uses the true physical index.
        if (cnt_a==43) f_dp[fcnt][15:8]  <= tx_data[0];
        if (cnt_a==44) f_dp[fcnt][7:0]   <= tx_data[0];
        if (cnt_a==50) f_op[fcnt]        <= tx_data[0][2:0];
        if (cnt_a==51) f_blk[fcnt][15:8] <= tx_data[0];
        if (cnt_a==52) begin
          f_blk[fcnt][7:0] <= tx_data[0];
          f_b0[fcnt]       <= tx_data[0];
        end
        if (cnt_a==53) f_b1[fcnt]        <= tx_data[0];
      end
    end else if (act_a) begin
      act_a<=0;
      fcnt <= fcnt+1;
      if (cnt_a != cnt_b && !act_b) bad("A/B frame length mismatch");
    end
    if (tx_valid[1]) begin
      if (!act_b) begin act_b<=1; cnt_b<=0; end
      else cnt_b<=cnt_b+1;
    end else if (act_b) act_b<=0;
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

  task configure;
    integer g; reg [31:0] v;
    begin
      reset=1; repeat(8) @(negedge clk); reset=0;
      read_word(16'h000C,v); g=0;
      while(!v[13] && g<30000) begin read_word(16'h000C,v); g=g+1; end
      if(!v[13]) bad("init timeout");
      write_word(16'h0008,32'h2000);
      write_word(16'h0078,32'h172D); write_word(16'h007C,32'hAB61);
      // RX VLID 查找映像：t12_top 为 VLID i → index i，覆盖 VLID 0x100（=256）。
      // 下行帧的 VLID=0x100，不装载该映像则 rx_vl_lookup 无法解析、帧被丢弃。
      u_host.wr(16'h0078, hmeta[0]); u_host.wr(16'h007C, hmeta[1]);
      for (g=0; g<8192; g=g+1) u_host.wr(16'h3D80+g, himg[g]);
      write_word(16'h42B2,32'h10100100); write_word(16'h0080,1);
      read_word(16'h0080,v); if(v[0]!==1'b1) bad("hash commit absent");
      // RX VL 表：key=0x100 → index 256；w0[31]=valid, net=A, Lmax=700
      write_word(16'h1D80+(256<<1), 32'hF5000000|(256<<12)|700);
      write_word(16'h1D81+(256<<1), 32'h0100);
      // RX 端口表：port 7 → 使能 + 允许 0x100
      //   w1[15:0] 必须等于下行帧的 UDP 目的端口 = 客户端本地 TID 0x3001
      //   （解析器 R_DPORT：port_w1[15:0] != in_desc[15:0] 即丢弃）
      write_word(16'h7D80+4*7,32'h80060000);
      write_word(16'h7D81+4*7,32'h00003001); write_word(16'h7D82+4*7,0); write_word(16'h7D83+4*7,1);
      // TX VL 7
      write_word(16'h1F80,32'hF5000000|(7<<12)|700); write_word(16'h1F81,32'h0100);
      write_word(16'h0204,7<<16); write_word(16'h0203,0); write_word(16'h0202,5000<<16);
      write_word(16'h0201,1000<<8); write_word(16'h0480,6040);
      write_word(16'h0200,32'h80000003|(700<<12));
      write_word(16'h0060,32'h172D2001); write_word(16'h0064,32'h0A000002);
      write_word(16'h0070,32'h0142);
      read_word(16'h005C,v); if(v!==0) bad("legal management configuration rejected");
      write_word(16'h0008,32'h071F);
    end
  endtask

  // ---- 下行注入（前导+SFD+帧；1B/拍）----
  reg [7:0] fr [0:1023];
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
      // 向量布局：[0]=帧数；帧记录从 word 1 起顺序排列：
      //   [len][bytes...]（bytes 按 32bit 大端打包，(len+3)/4 个词）
      base = 1;
      for (b = 0; b < frame_no; b = b + 1) base = base + 1 + (vec[base]+3)/4;
      flen = vec[base];
      @(negedge clk);
      for (i=0; i<flen+8; i=i+1) begin
        rx_valid=1; rx_data=(i<7)?8'h55:((i==7)?8'hD5:fbyte(base+1,i-8));
        @(negedge clk);
      end
      rx_valid=0;
      @(negedge clk);
    end
  endtask

  task start_fetch;
    begin
      write_word(16'hAC41,32'h0A000002);          // server ip
      write_word(16'hAC42,{8'h46,8'h57,8'h2E,8'h42});   // "FW.B"
      write_word(16'hAC43,{8'h49,8'h4E,8'h00,8'h00});   // "IN\0\0"
      write_word(16'hAC4A,32'd6);                 // fnlen
      write_word(16'hAC4B,32'd3000);              // timeout ticks（> BAG 1000us，
                                                  // 避免 RRQ 在等首片期间被超时重发）
      write_word(16'hAC54,32'h3001);              // local tid
      write_word(16'hAC40,32'h1);                 // start pulse
    end
  endtask

  integer t, nxt;
  task wait_status;
    input integer bitix;      // 0=busy,2=failed,3=done
    input integer limit;
    reg [31:0] v;
    begin
      guard=0;
      repeat (5) @(negedge clk);
      while (guard<limit) begin
        read_word(16'hAC40,v); guard=guard+1;
        if (v[bitix]===1'b1) guard=limit+1;
      end
      if (guard<=limit) bad("status wait timeout");
    end
  endtask

  task check_file;
    input integer len;
    reg [31:0] v;
    begin
      for (i=0;i<len;i=i+1) begin
        write_word(16'hAC4E, i[31:0]);
        @(negedge clk);
        read_word(16'hAC4F, v);
        if (v[7:0] !== patb(i)) bad("file readback byte mismatch");
        checks=checks+1;
      end
    end
  endtask
  function [7:0] patb; input integer k;
    begin patb = (k<512) ? ((k*7+8'h21)&8'hFF) : (((k-512)*13+8'h5A)&8'hFF); end
  endfunction

  initial begin
    $readmemh("vec/t57_fetch.hex", vec, 0, `T57_WORDS-1);
    $readmemh("vec/t12_top.img.hex", himg, 0, 8191);
    $readmemh("vec/t12_top.meta.hex", hmeta, 0, 3);
    if (vec[0] !== 3) $fatal(1, "T57 vectors missing");
    configure();

    // ================= J1: 正常取件 =================
    $display("T57 CASE J1");
    start_fetch;
    // 0xAC40 位序： [3]=done [2]=failed [1]=busy [0]=保留(恒 0)
    wait_status(1, 20000);                        // busy
    inject(0);                                    // DATA(1) 512B
    repeat (200) @(negedge clk);
    inject(1);                                    // DATA(2) 8B 末块
    wait_status(3, 400000);                       // done（含 dally 超时）
    // 状态与文件
    begin : j1checks
      reg [31:0] v;
      read_word(16'hAC40, v); chk(v[3]===1'b1 && v[1]===1'b0, "J1 done flagged");
      read_word(16'hAC4C, v); chk(v[13:0]===14'd520, "J1 file length 520");
      read_word(16'hAC50, v); chk(v===32'd520, "J1 rx_bytes 520");
      read_word(16'hAC51, v); chk(v===32'd0, "J1 no failure code");
      check_file(520);
    end
    // 上行帧核对（等 4 个 BAG 周期 = 4×125000 = 500000 拍）
    repeat (520000) @(negedge clk);
    chk(fcnt>=3, "J1 at least RRQ+2 ACK frames on wire");
    if (fcnt>=1) begin
      chk(f_op[0]===3'd1 && f_dp[0]===16'd69, "J1 first frame is RRQ to port 69");
      // RRQ 文件名取帧 0 独立快照 rrq_a（下标 51 起为 "FW.BIN"）。
      chk(rrq_a[52]==="F" && rrq_a[53]==="W", "J1 RRQ filename starts FW");
    end
    begin : j1seq
      integer saw1, saw2;
      saw1=0; saw2=0;
      for (i=0;i<fcnt && i<16;i=i+1) begin
        if (f_op[i]===3'd4 && f_blk[i]===16'd1 && f_dp[i]===16'd40100) saw1=1;
        if (f_op[i]===3'd4 && f_blk[i]===16'd2 && f_dp[i]===16'd40100) saw2=1;
        if (f_op[i]===3'd1) chk(i===0, "J1 RRQ only as first frame");
      end
      chk(saw1===1, "J1 ACK(1) on wire to loader TID");
      chk(saw2===1, "J1 ACK(2) on wire to loader TID");
    end

    // ================= J2: ERROR 响应 → failed =================
    $display("T57 CASE J2");
    write_word(16'hAC4D, 32'd1);                  // 释放 J1 文件
    repeat (10) @(negedge clk);
    start_fetch;
    wait_status(1, 20000);
    inject(2);                                    // ERROR(5)
    wait_status(2, 400000);                       // failed
    begin : j2checks
      reg [31:0] v;
      read_word(16'hAC40, v); chk(v[2]===1'b1 && v[3]===1'b0, "J2 failed flagged");
      read_word(16'hAC51, v); chk(v===32'd3, "J2 failure code E_SERVER");
    end
    if (u_host.errors!=0) bad("host stimulus failure");

    if (errors==0) $display("T57 FETCH GMII PASS checks=%0d frames=%0d", checks, fcnt);
    else $display("T57 FETCH GMII FAIL errors=%0d", errors);
    $finish;
  end
  initial begin #60000000; $display("T57 FETCH GMII FAIL timeout"); $finish; end
endmodule
