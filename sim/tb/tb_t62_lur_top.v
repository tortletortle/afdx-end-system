// =====================================================================
// T62 — 615A LUR 顶层上传 → 逐文件取件 的 GMII 级端到端（P05 集成）
//
// TB 扮演装载端（server 10.0.0.2:40100），仅走公开 GMII + 宿主接口：
//   1) GMII WRQ TARGET.LUR, DATA1/2 -> complete533B control file;
//   2) DUT 内 lur_rx 解析 → 编排器按清单逐文件发起 RRQ；
//   3) TB 对每个文件回 DATA(1) 512B / DATA(2) 8B 末块；
//   4) 核对 ok_files / total_bytes / done，并逐字节读回两个文件；
//   5) 核对上行线序：RRQ(A.BIN) → ACK1 → ACK2 → RRQ(C.DE) → ACK1 → ACK2。
//
// 下行帧由 gen_t62_vectors.py 独立构造（FCS/UDP 校验和已核）。
// =====================================================================
`timescale 1 ns / 1 ps
`include "vec/t62_lur_top.vh"
module tb_t62_lur_top;
  reg clk=0, reset=1;
  always #4 clk=~clk;
  reg [7:0] rx_data=0;
  reg rx_valid=0;
  wire [7:0] tx_data[0:1];
  wire tx_valid[0:1];
  wire hcs,hwe,hack;
  wire [15:0] haddr;
  wire [31:0] hwdata,hrdata;
  AFDX_top #(.TFTP_TIMEOUT_US(5000)) dut (
    .clk(clk),.reset(reset),.tx_data(tx_data[0]),.tx_valid(tx_valid[0]),.tx_ready(),
    .rx_data(rx_data),.rx_valid(rx_valid),.rx_ready(1'b0),.rx_error(1'b0),
    .tx_data_b(tx_data[1]),.tx_valid_b(tx_valid[1]),.tx_ready_b(),
    .rx_data_b(8'd0),.rx_valid_b(1'b0),.rx_ready_b(1'b0),.rx_error_b(1'b0),
    .host_cs(hcs),.host_we(hwe),.host_addr(haddr),.host_wdata(hwdata),
    .host_rdata(hrdata),.host_ack(hack),.host_irq(),
    .pps_in(1'b0),.pps_out(),.rtc_time_us(),.dbg_frame_event());
  afdx_host_bfm u_host (.clk(clk),.cs(hcs),.we(hwe),.addr(haddr),.wdata(hwdata),.rdata(hrdata),.ack(hack));

  reg [31:0] vec[0:`T62_WORDS-1];
  reg [31:0] himg[0:8191];
  reg [31:0] hmeta[0:3];
  integer errors=0, checks=0, cycle=0;
  integer rb_files=0;
  integer control_cases=0;
  integer phy_a_fd, phy_b_fd;
  reg phy_a_active=0, phy_b_active=0;
  always @(posedge clk) begin
    if(tx_valid[0]) begin $fwrite(phy_a_fd,"%02x",tx_data[0]);phy_a_active<=1;end
    else if(phy_a_active) begin $fwrite(phy_a_fd,"\n");phy_a_active<=0;end
    if(tx_valid[1]) begin $fwrite(phy_b_fd,"%02x",tx_data[1]);phy_b_active<=1;end
    else if(phy_b_active) begin $fwrite(phy_b_fd,"\n");phy_b_active<=0;end
  end
  integer guard, i, j;

  task bad;
    input [8*112-1:0] reason;
    begin if (errors<20) $display("  [err] T62 cyc=%0d %0s", cycle, reason); errors=errors+1; end
  endtask
  task chk;
    input cond; input [8*112-1:0] reason;
    begin checks=checks+1; if (!cond) bad(reason); end
  endtask

  // ---- Physical capture:7x55+D5, Ethernet at8, IPv4 at22, UDP at42.
  // TFTP opcode50..51, block52..53, RRQ name52. cnt_a is one less
  // than the actual physical index after the first byte.
  // 字段在帧内逐拍锁存；RRQ 文件名用独立计数器做整帧快照。
  //
  // 注意：`cnt_a` 在首个 tx_valid 拍被赋 0（非阻塞），其下标语义与纯字节计数
  // 不同；故另设独立计数器 `ridx`（含 tx_valid 首拍起 +1），与线上字节严格对齐，
  // 用于整帧快照（此结论由 T57 逐字节实测锚定）。
  integer fcnt=0;
  reg [2:0] f_op[0:31]; reg [15:0] f_blk[0:31]; reg [15:0] f_dp[0:31];
  reg [7:0]  f_b0[0:31]; reg [7:0] f_b1[0:31];
  integer cnt_a=0, cnt_b=0; reg act_a=0, act_b=0;
  reg [7:0] snap0[0:96];          // 帧 0（A.BIN RRQ）整帧快照（独立计数）
  reg [7:0] snap3[0:96];          // 帧 3（C.DE RRQ）整帧快照（独立计数）
  integer ridx=0;

  always @(posedge clk) begin
    if (tx_valid[0]) begin
      if (fcnt==4 && ridx<96) snap0[ridx] <= tx_data[0];
      if (fcnt==7 && ridx<96) snap3[ridx] <= tx_data[0];
      ridx <= ridx + 1;
    end else if (act_a) ridx <= 0;
  end

  always @(posedge clk) begin
    cycle <= cycle+1;
    if (tx_valid[0]) begin
      if (!act_a) begin act_a<=1; cnt_a<=0; end
      else cnt_a<=cnt_a+1;
      if (fcnt<32) begin
        if (cnt_a==43) f_dp[fcnt][15:8]  <= tx_data[0];
        if (cnt_a==44) f_dp[fcnt][7:0]   <= tx_data[0];
        if (cnt_a==50) f_op[fcnt]        <= tx_data[0][2:0];
        if (cnt_a==51) f_blk[fcnt][15:8] <= tx_data[0];
        if (cnt_a==52) begin f_blk[fcnt][7:0] <= tx_data[0]; f_b0[fcnt] <= tx_data[0]; end
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
      // RX VLID 哈希映像（VLID 0x100 → index 256）
      u_host.wr(16'h0078, hmeta[0]); u_host.wr(16'h007C, hmeta[1]);
      for (g=0; g<8192; g=g+1) u_host.wr(16'h3D80+g, himg[g]);
      write_word(16'h42B2,32'h10100100); write_word(16'h0080,1);
      read_word(16'h0080,v); if(v[0]!==1'b1) bad("hash commit absent");
      // RX VL 表：key 0x100 → index 256
      write_word(16'h1D80+(256<<1), 32'hF5000000|(256<<12)|1400);
      write_word(16'h1D81+(256<<1), 32'h0100);
      // RX 端口表：port 7，w1[15:0] 必须等于下行帧 UDP dport 0x3001
      write_word(16'h7D80+4*7,32'h80060000);
      write_word(16'h7D81+4*7,32'h00003001); write_word(16'h7D82+4*7,0); write_word(16'h7D83+4*7,1);
      // TX VL 0（mgmt/VL 映射）→ 端口 7，BAG 1000us
      write_word(16'h1F80,32'hF5000000|(7<<12)|1400); write_word(16'h1F81,32'h0100);
      write_word(16'h0204,7<<16); write_word(16'h0203,0); write_word(16'h0202,5000<<16);
      write_word(16'h0201,1000<<8); write_word(16'h0480,6040);
      write_word(16'h0200,32'h80000003|(1400<<12));
      write_word(16'h0060,32'h172D2001); write_word(16'h0064,32'h0A000002);
      write_word(16'h0070,32'h0142);
      read_word(16'h005C,v); if(v!==0) bad("legal management configuration rejected");
      write_word(16'h0008,32'h071F);
      // LUR 作业：server_ip / local_tid / timeout
      write_word(16'hAC41,32'h0A000002);
      write_word(16'hAC54,32'h3001);
      write_word(16'hAC4B,32'd3000);
    end
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
      // [0]=帧数；帧记录从 word 1 起：[len][bytes...]（大端打包）
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

  // ---- LUR 宿主窗读 ----
  task read_lur;
    input [5:0] off; output [31:0] v;
    begin read_word(16'hAC80 + {10'd0, off}, v); end
  endtask

  task wait_guard;
    input integer n;
    begin for (guard=0; guard<n; guard=guard+1) @(negedge clk); end
  endtask

  task control_exchange;
    input integer record_no, expected_op, expected_block;
    integer before_frames;
    begin
      before_frames=fcnt;inject(record_no);wait_guard(140000);
      chk(fcnt==before_frames+1,"control exchange response count");
      chk(f_op[before_frames]==expected_op && f_blk[before_frames]==expected_block,
          "control exchange opcode/block/error");
    end
  endtask

  // 等取件引擎 busy（本文件作业已被接受）
  task wait_fe_busy;
    input integer limit;
    reg [31:0] state_word;
    begin
      guard=0;read_word(16'hAC40,state_word);
      while (guard<limit && state_word[1]!==1'b1) begin read_word(16'hAC40,state_word); guard=guard+1; end
      if (guard>=limit) bad("fetch engine never went busy");
    end
  endtask

  // 等取件引擎本文件作业结束（done 或 failed 均锁存，busy 落）
  task wait_fe_idle;
    input integer limit;
    reg [31:0] state_word;
    begin
      guard=0;read_word(16'hAC40,state_word);
      while (guard<limit && state_word[1]===1'b1) begin read_word(16'hAC40,state_word); guard=guard+1; end
      if (guard>=limit) bad("fetch engine never finished");
    end
  endtask

  // 服务一个文件的完整会话（含 dally 超时收尾）。
  // TFTP 末块之后客户端进入 S_DALLY，需等 timeout_ticks（3000us = 375000 拍）
  // 无新数据才判定文件结束；期间不得注入下一文件的 DATA，否则会被本会话吞掉。
  // 上行 RRQ/ACK 均受 VL 0 的 BAG（1000us = 125000 拍）节拍放行。
  //
  // Hold each published file in the same orchestrated session; compare its
  // distinct bytes through the public file window before allowing the next RRQ.
  task serv_file;
    input integer f1; input integer f2;
    input release_file;
    reg [31:0] v;
    begin
      wait_fe_busy(600000);                        // 等 RRQ 上线且作业被接受
      inject(f1);                                  // DATA(1) 512B
      wait_guard(60000);
      inject(f2);                                  // DATA(2) 8B 末块
      wait_fe_idle(900000);                        // 等 dally 超时收尾
      wait_fe_file_valid(10000);
      read_word(16'hAC4C,v);chk(v[13:0]==520 && v[17:16]==0,"published file length/error");
      read_word(16'hAC8D,v);chk(v[1],"public waiting-file-ack status");
      // Changing the configured policy must not release this or the next
      // file in a session whose policy was latched at start.
      write_word(16'hAC8D,0);wait_guard(10000);
      read_word(16'hAC4D,v);chk(v[0],"held file disappeared before host readback");
      check_file(520,f1==5 ? 1 : 0);rb_files=rb_files+1;
      read_word(16'hAC4D,v);chk(v[0],"file disappeared during readback");
      chk(fcnt<=4+rb_files*3,"next RRQ started before previous file acknowledgement");
      $display("T62 FILE_VERIFIED file=%0d bytes=520 still_published=%0d",rb_files,v[0]);
      if(release_file)write_word(16'hAC8C,1);
    end
  endtask

  // 等落盘文件发布（0xAC4D 读 = fe_file_valid[0]）
  task wait_fe_file_valid;
    input integer limit;
    reg [31:0] v;
    begin
      guard=0;
      while (guard<limit) begin
        read_word(16'hAC4D, v);
        if (v[0]===1'b1) guard=limit+1;
        else guard=guard+1;
      end
      if (guard<=limit) bad("file never published");
    end
  endtask

  function [7:0] patb; input integer k,which;
    begin
      if(which==0)patb = (k<512) ? ((k*7+8'h21)&8'hFF) : (((k-512)*13+8'h5A)&8'hFF);
      else patb = (k<512) ? ((k*11+8'h93)&8'hFF) : (((k-512)*17+8'hC6)&8'hFF);
    end
  endfunction

  // 逐字节读回一个 520B 文件（经取件引擎 0xAC4E/0xAC4F）
  task check_file;
    input integer len,which;
    reg [31:0] v;
    begin
      for (i=0;i<len;i=i+1) begin
        write_word(16'hAC4E, i[31:0]);
        @(negedge clk);
        read_word(16'hAC4F, v);
        if (v[7:0] !== patb(i,which)) bad("file readback byte mismatch");
        checks=checks+1;
      end
    end
  endtask

  // 编排器握手观察：每完成/失败一拍打一行（含作业序号与状态位）
  reg [31:0] last_lur82 = 32'hFFFFFFFF;
  // 单口名字读口互斥断言：编排器运行期间（lur_busy=1）宿主观测必须被旁路，
  // 读口所有权归编排器。若顶层 mux 接反，宿主的 lur_host_read/index 会污染
  // 编排器的搬运（现象为文件名错位/首字节 0）。
  integer mux_viol = 0;
  always @(posedge clk) begin
    if (dut.lur_busy === 1'b1) begin
      if (dut.lur_name_read_mux !== dut.lur_name_read ||
          dut.lur_name_index_mux !== dut.lur_name_index ||
          dut.lur_sel_mux !== dut.lur_file_select_w) begin
        if (mux_viol < 3)
          $display("  [mux] VIOLATION cyc=%0d busy=1 host read not bypassed", cycle);
        mux_viol = mux_viol + 1;
      end
    end
    if (dut.lur_busy !== 1'b0 || dut.lur_done !== 1'b0 || dut.lur_failed !== 1'b0) begin
      if (!(dut.lur_failed)) begin
        if (dut.lur_done === 1'b1 && last_lur82 !== 32'h0) begin
          last_lur82 <= 32'h0;
          $display("  [orch] DONE cyc=%0d ok=%0d fail=%0d bytes=%0d",
                   cycle, dut.lur_ok_cnt, dut.lur_fail_cnt, dut.lur_bytes);
        end
      end
    end
  end
  initial begin
    phy_a_fd=$fopen("out/t62_phy_a.hex","w");
    phy_b_fd=$fopen("out/t62_phy_b.hex","w");
    if(!phy_a_fd || !phy_b_fd)$fatal(1,"T62 cannot open PHY capture");
    $readmemh("vec/t62_lur_top.hex", vec, 0, `T62_WORDS-1);
    $readmemh("vec/t12_top.img.hex", himg, 0, 8191);
    $readmemh("vec/t12_top.meta.hex", hmeta, 0, 3);
    if (vec[0] !== `T62_FRAMES) $fatal(1, "T62 vectors missing");
    configure();

    // ================= L1: LUR 上传 → 2 文件取件 =================
    $display("T62 CASE L1");
    // AC87[1:0]=3 selects complete TFTP control-file reception.
    write_word(16'hAC87, 32'h3); // receive the explicit LUR endpoint through TFTP
    repeat (20) @(negedge clk);
    write_word(16'hAC8D,1); // configure hold at session start
    inject(0); // WRQ TARGET.LUR
    wait_guard(140000);
    $display("T62 CONTROL_CAPTURE phase=WRQ frames=%0d op=%0d block=%0d",fcnt,f_op[0],f_blk[0]);
    chk(fcnt==1 && f_op[0]==4 && f_blk[0]==0,"control WRQ ACK(0)");
    inject(1); // first 512B control DATA
    wait_guard(140000);
    $display("T62 CONTROL_CAPTURE phase=DATA1 frames=%0d op=%0d block=%0d",fcnt,f_op[1],f_blk[1]);
    begin : partial_control reg [31:0] v;
      chk(fcnt==2 && f_op[1]==4 && f_blk[1]==1,"control DATA(1) ACK");
      read_word(16'hAC85,v);chk(!v[2] && !v[1],"partial TFTP LUR published parser result");
      read_word(16'hAC8E,v);chk(v[1] && !v[2],"partial control ownership/publication");
    end
    inject(2); // complete control file, one file boundary across both blocks
    // Public load reads contend with the pump's synchronous read port.
    for(j=0;j<400;j=j+1) begin : load_contention reg [31:0] v;
      read_word(16'hCD80+(j%100),v);
    end
    wait_guard(140000);
    begin : complete_control reg [31:0] v;
      chk(fcnt==3 && f_op[2]==4 && f_blk[2]==2,"control final ACK(2)");
      read_word(16'hAC8F,v);chk(v==`T62_LUR_BYTES,"complete control file byte count");
      read_word(16'hAC8E,v);chk(v[3:0]==4'b1111 && !v[4],"parsed control image remains held");
    end
    inject(9); // loss of final ACK must not cause another parse or overwrite
    wait_guard(140000);
    chk(fcnt==4 && f_op[3]==4 && f_blk[3]==2,"held control final retransmission ACK");
    // 主机读 LUR 解析结果：0xAC84 file_count，0xAC85 result_vld/ok/err
    //   0xAC85 = {28'd0, err[3:0], result_vld, ok, up_busy}
    //     bit0 = up_busy, bit1 = request_ok, bit2 = result_valid, bit6:3 = error_code
    begin : lurchk
      reg [31:0] v;
      read_lur(6'h04, v); chk(v[15:0]===16'd2, "L1 LUR file_count == 2");
      read_lur(6'h05, v);
      chk(v[2]===1'b1, "L1 LUR result_valid");
      chk(v[1]===1'b1, "L1 LUR request_ok");
      chk(v[6:3]===4'd0, "L1 LUR error_code == 0");
    end
    // 关闭上传接收态，改为「清单已上传」模式启动编排取件：
    //   0xAC87[0]=0 释放 SAP 路由；0xAC80[0]=start，[3]=up_mode（清单已就绪）。
    write_word(16'hAC87, 32'h0);
    repeat (20) @(negedge clk);
    write_word(16'hAC80, 32'h9);                 // start=1, up_mode=1
    // 串行服务两个文件：每个 = RRQ → DATA1 → DATA2 → dally 收尾
    serv_file(3, 4, 1);                          // A.BIN, read before release
    serv_file(5, 6, 1);                          // C.DE, distinct bytes, read before release
    // 等 done（0xAC82 = {24'd0, cur, fcode, failed, done, busy}）
    guard=0;
    while (guard<1600000) begin
      begin : wd reg [31:0] w; read_lur(6'h02, w);
        if (w[1]===1'b1 || w[2]===1'b1) guard=9000000; end
      guard=guard+1;
    end
    begin : orchchk
      reg [31:0] v;
      read_lur(6'h02, v); chk(v[1]===1'b1 && v[2]===1'b0, "L1 orchestrator done, not failed");
      read_lur(6'h01, v); chk(v[15:0]===16'd2 && v[31:16]===16'd0, "L1 ok_files=2 fail_files=0");
      read_lur(6'h03, v); chk(v===32'd1040, "L1 total_bytes == 1040");
      read_lur(6'h00, v); chk(v[28]===1'b0, "L1 upload mode released");
    end
    // 取件引擎观测：两文件共 4 片 DATA 全部被消化，无丢弃
    begin : fechk
      reg [31:0] v;
      read_word(16'hAC52, v); chk(v===32'd4, "L1 fetch engine ok_cnt == 4");
      read_word(16'hAC53, v); chk(v===32'd0, "L1 fetch engine drop_cnt == 0");
    end
    // Both files have been compared before their explicit acknowledgements.
    begin : rbchk
      reg [31:0] v;
      read_word(16'hAC4D, v); chk(v[0]===1'b0, "L1 no file left published");
      chk(rb_files==2,"both same-session files were read before release");
      // 单口读口互斥：整个运行期间未曾出现宿主旁路失效
      chk(mux_viol===0, "L1 host read port fully bypassed while orchestrator busy");
    end
    // 上行线序核对：等所有 ACK 排空（再留 2 个 BAG）
    wait_guard(260000);
    begin : seqchk
      integer k;
      for (k=0;k<fcnt && k<32;k=k+1)
        $display("  [seq] f[%0d] op=%0d blk=%0d dp=%0d", k, f_op[k], f_blk[k], f_dp[k]);
      chk(fcnt>=10, "L1 control ACKs and six data-file frames on wire");
      chk(f_op[4]===3'd1 && f_dp[4]===16'd69, "L1 first file frame is RRQ to port 69");
      // Four control ACKs precede RRQ A.BIN(frame4)/C.DE(frame7).
      chk(snap0[52]==="A" && snap0[53]==="." && snap0[54]==="B" &&
          snap0[55]==="I" && snap0[56]==="N", "L1 first RRQ is A.BIN");
      chk(snap3[52]==="C" && snap3[53]==="." && snap3[54]==="D" &&
          snap3[55]==="E", "L1 second RRQ is C.DE, after A.BIN");
      chk(f_op[7]===3'd1 && f_dp[7]===16'd69, "L1 second file RRQ to port 69");
      chk(f_blk[5]===16'd1 && f_op[5]===3'd4 && f_dp[5]===16'd40100,
          "L1 A.BIN ACK(1) to loader TID");
      chk(f_blk[6]===16'd2 && f_op[6]===3'd4 && f_dp[6]===16'd40100,
          "L1 A.BIN ACK(2) to loader TID");
      chk(f_blk[8]===16'd1 && f_op[8]===3'd4 && f_dp[8]===16'd40100,
          "L1 C.DE ACK(1) to loader TID");
      chk(f_blk[9]===16'd2 && f_op[9]===3'd4 && f_dp[9]===16'd40100,
          "L1 C.DE ACK(2) to loader TID");
    end

    // Restart from DONE without reset, then abort a fully published held file.
    write_word(16'hAC8D,1);write_word(16'hAC80,9);
    serv_file(7,8,0);
    begin : held_abort reg [31:0] v;
      read_word(16'hAC81,v);chk(v==0,"new session retained old file counts");
      write_word(16'hAC80,2);wait_guard(20);
      read_word(16'hAC82,v);chk(v[2] && !v[1] && v[6:3]==3,"published-file abort status");
      read_word(16'hAC4D,v);chk(!v[0],"abort lost release pulse after LUR ownership dropped");
      read_word(16'hAC81,v);chk(v==0,"aborted held file counted as success");
      // A failed session must accept a fresh job with a free file buffer.
      write_word(16'hAC80,9);wait_fe_busy(600000);
      read_word(16'hAC82,v);chk(v[0] && !v[1] && !v[2],"restart from FAILED did not clear terminal state");
      write_word(16'hAC80,2);wait_guard(100);
      read_word(16'hAC40,v);chk(!v[1],"abort lost transport cancellation after ownership dropped");
      read_word(16'hAC4D,v);chk(!v[0],"in-flight restart abort published partial file");
    end
    // Complete control transport failures/recovery on the same DUT instance.
    // Drain the last in-flight abort's already-committed packet before starting
    // another management exchange. Cancellation must finish an emitted frame.
    wait_guard(260000);
    begin : control_lifecycle reg [31:0] v;
      write_word(16'hAC85,1);wait_guard(20);
      read_word(16'hAC8E,v);chk(v[3:1]==0,"control result acknowledgement did not free buffer/pump");
      write_word(16'hAC87,3);
      $display("T62 CONTROL_CASE wrong-name");control_cases=control_cases+1;
      control_exchange(10,5,2);
      read_word(16'hAC85,v);chk(!v[2],"wrong-name request published LUR");
      $display("T62 CONTROL_CASE partial-abort-restart");control_cases=control_cases+1;
      control_exchange(11,4,0);control_exchange(12,4,1);
      read_word(16'hAC85,v);chk(!v[2] && !v[1],"partial control file parsed");
      write_word(16'hAC8F,1);wait_guard(20);
      read_word(16'hAC8E,v);chk(v[3:1]==0,"control partial abort leaked buffer/pump");
      $display("T62 CONTROL_CASE malformed-complete-hold");control_cases=control_cases+1;
      control_exchange(13,4,0);control_exchange(14,4,1);control_exchange(15,4,2);
      read_word(16'hAC85,v);chk(v[2] && !v[1] && v[6:3]==1,"malformed whole-file length not rejected");
      read_word(16'hAC84,v);chk(v==0,"malformed LUR exposed entries");
      control_exchange(16,5,2);
      read_word(16'hAC8F,v);chk(v==`T62_LUR_BYTES,"replacement WRQ changed held image");
      write_word(16'hAC85,1);wait_guard(20);
      $display("T62 CONTROL_CASE good-recovery-wrong-tid-abort");control_cases=control_cases+1;
      control_exchange(17,4,0);control_exchange(18,4,1);control_exchange(19,4,2);
      read_word(16'hAC85,v);chk(v[2] && v[1] && v[6:3]==0,"good control file did not recover after parse failure");
      read_word(16'hAC84,v);chk(v==2,"recovered control file lost entries");
      control_exchange(20,5,5);
      read_word(16'hAC85,v);chk(v[2] && v[1],"wrong TID disturbed valid LUR result");
      read_word(16'hAC8E,v);chk(v[2:1]==3,"wrong TID released held control image");
      write_word(16'hAC8F,1);wait_guard(20);
      read_word(16'hAC8E,v);chk(v[3:1]==0,"published control abort leaked buffer/pump");
      read_word(16'hAC85,v);chk(!v[2] && !v[1],"published control abort retained parser result");
      $display("T62 CONTROL_CASE response-copy-abort");control_cases=control_cases+1;
      // Internal timing selects the collision edge only. Success is judged
      // by complete public PHY responses and the following accepted WRQ.
      fork
        inject(21);
        begin
          wait(dut.mt_state==dut.MT_BYTE && dut.mt_sel_tftp);
          write_word(16'hAC8F,1);
        end
      join
      wait_guard(140000);
      chk(f_op[fcnt-1]==5 && f_blk[fcnt-1]==2,"abort dropped management-owned ERROR response");
      control_exchange(22,4,0);
      write_word(16'hAC8F,1);wait_guard(20);
      read_word(16'hAC8E,v);chk(v[3:1]==0,"response-copy abort recovery retained ownership");
    end
    if (u_host.errors!=0) bad("host stimulus failure");
    $fclose(phy_a_fd);$fclose(phy_b_fd);
    if (errors==0) $display("T62 LUR TOP PASS checks=%0d frames=%0d readback_bytes=1560 confirmed_files=2 aborted_files=1 control_cases=%0d", checks, fcnt,control_cases);
    else $display("T62 LUR TOP FAIL errors=%0d", errors);
    $finish;
  end

  initial begin #1200000000; $display("T62 LUR TOP FAIL timeout"); $finish; end
endmodule
