// =====================================================================
// T45 — 默认顶层 TFTP 超时/背压契约（P02，2026-10-10）
//
// 目的：在默认 128TX/4096RX、IF_MODE=2 顶层上验证：
//   * 会话超时响应与在途包字节共存时，包字节被背压保持、不丢、不乱序；
//   * 把超时判决时刻扫掠到包接收/解析/SAP 复制/分发各阶段：每次注入
//     都要求最终收到期望 ACK(k)（允许 1 次 ACK(k-1) 重传先行）；
//   * 512 B 接受、513 B 超长 DATA → ERROR(4)；
//   * 无会话 DATA / 5 字节畸形 ACK → ERROR(5)；
//   * 主机读回加载区与 bytes/crc/loaded_ok 寄存器，逐字节对账；
//   * 第二会话（新 TID）重新加载小文件成功，覆盖失败后恢复。
//
// 时序锚点：管理帧上线受 TX VL BAG 节拍限制（本配置 1 ms）。TFTP 超时
// 计数在响应取走（≈上一帧线上完成）后恢复，30 µs 后判决。因此注入时刻
// 取「上一响应线上完成 + 3750 - X」，X 为判决相对注入的偏移拍数。
// 预期报文全部来自 gen_t45_vectors.py 的独立构帧；响应帧按
// (类型, 事件序号 SN, 网络) 三维索引匹配，不看 DUT 内部信号。
// TFTP_TIMEOUT_US 参数缩短为 30 以适配仿真时长；其余参数为默认值。
// =====================================================================
`timescale 1 ns / 1 ps
`include "vec/t45_contract.vh"
module tb_t45_tftp_timeout;
  localparam integer TIMEOUT_US_OVR = 30;
  localparam integer TO_CYCLES      = TIMEOUT_US_OVR * 125;  // 125 MHz 时钟
  localparam integer REQ_IDX_WORD   = 10;                    // vec[10+2i]=len, [11+2i]=off

  reg clk=0, reset=1;
  always #4 clk=~clk;
  reg [7:0] rx_data=0;
  reg rx_valid=0;
  wire [7:0] tx_data[0:1];
  wire tx_valid[0:1];
  wire hcs,hwe,hack;
  wire [15:0] haddr;
  wire [31:0] hwdata,hrdata;
  AFDX_top #(.TFTP_TIMEOUT_US(TIMEOUT_US_OVR)) dut (
    .clk(clk),.reset(reset),.tx_data(tx_data[0]),.tx_valid(tx_valid[0]),.tx_ready(),
    .rx_data(rx_data),.rx_valid(rx_valid),.rx_ready(1'b0),.rx_error(1'b0),
    .tx_data_b(tx_data[1]),.tx_valid_b(tx_valid[1]),.tx_ready_b(),
    .rx_data_b(8'd0),.rx_valid_b(1'b0),.rx_ready_b(1'b0),.rx_error_b(1'b0),
    .host_cs(hcs),.host_we(hwe),.host_addr(haddr),.host_wdata(hwdata),
    .host_rdata(hrdata),.host_ack(hack),.host_irq(),
    .pps_in(1'b0),.pps_out(),.rtc_time_us(),.dbg_frame_event());
  afdx_host_bfm u_host (.clk(clk),.cs(hcs),.we(hwe),.addr(haddr),.wdata(hwdata),.rdata(hrdata),.ack(hack));

  reg [31:0] vec[0:`T45_WORDS-1];
  integer errors=0, checks=0, cycle=0;
  integer img_err1=0, img_err2=0;

  // ---- candidate response matching state ----
  integer cand_type[0:1];
  integer cand_tid[0:1];       // 0 -> TID 49152, 1 -> TID 49153
  integer cnt[0:1];            // bytes seen in the current wire frame (incl. preamble)
  reg     active[0:1];
  integer idle[0:1];
  reg [1:0] mism[0:1];         // per candidate slot bit
  integer ev[0:1];             // completed response events per net
  integer last_type[0:1];
  integer last_cycle[0:1];
  integer net, c;
  reg [7:0] obsA [0:639];
  reg [7:0] obsB [0:639];
  integer dbg_shown = 0;

  task bad;
    input [8*128-1:0] reason;
    begin
      if (errors < 25) $display("  [err] T45 cyc=%0d net=%0d %0s", cycle, net, reason);
      errors = errors + 1;
    end
  endtask

  function [7:0] byte_at;
    input integer base, off;
    reg [31:0] w;
    begin
      w = vec[base + (off>>2)];
      case (off&3) 0: byte_at=w[31:24]; 1: byte_at=w[23:16];
                   2: byte_at=w[15:8];  default: byte_at=w[7:0];
      endcase
    end
  endfunction

  function integer rec_off;      // record word offset for (tid, type, ev-index, net)
    input integer td, t, s, n;
    begin rec_off = vec[`T45_IDX_BASE + ((td*`T45_NT + t)*2 + n)*`T45_MAXS + s]; end
  endfunction

  // ---- PHY frame monitor with candidate matching per net（帧含 7×55+D5 前导）----
  reg ok0, ok1;
  integer ro0, ro1, nn, ob;
  always @(posedge clk) begin
    cycle <= cycle + 1;
    for (nn=0; nn<2; nn=nn+1) begin
      if (reset) begin
        cnt[nn]=0; active[nn]=0; idle[nn]=100; ev[nn]=0;
        last_type[nn]=-1; last_cycle[nn]=0; mism[nn]=2'b00;
      end else if (tx_valid[nn]) begin
        if (!active[nn]) begin
          if (idle[nn] < 12) begin net=nn; bad("PHY IFG below 12 clocks"); end
          active[nn]=1; cnt[nn]=0; mism[nn]=2'b00;
        end
        if (nn==0 && cnt[nn]<640) obsA[cnt[nn]] = tx_data[0];
        if (nn==1 && cnt[nn]<640) obsB[cnt[nn]] = tx_data[1];
        if (cnt[nn] < 7) begin
          if (tx_data[nn] !== 8'h55) begin net=nn; bad("PHY preamble mismatch"); end
        end else if (cnt[nn] == 7) begin
          if (tx_data[nn] !== 8'hD5) begin net=nn; bad("PHY SFD mismatch"); end
        end         else begin
          ob = cnt[nn] - 8;
          for (c=0; c<2; c=c+1) begin
            ro0 = rec_off(cand_tid[c], cand_type[c], ev[nn], nn);
            if (ob < vec[ro0]) begin
              if (tx_data[nn] !== byte_at(ro0+1, ob)) mism[nn][c]=1'b1;
            end else mism[nn][c]=1'b1;
          end
        end
        checks = checks + 1;
        cnt[nn] = cnt[nn] + 1;
        idle[nn] = 0;
      end else begin
        idle[nn] = idle[nn] + 1;
        if (active[nn]) begin
          active[nn] = 0;
          ro0 = rec_off(cand_tid[0], cand_type[0], ev[nn], nn);
          ro1 = rec_off(cand_tid[1], cand_type[1], ev[nn], nn);
          ok0 = (!mism[nn][0]) && ((cnt[nn]-8) == vec[ro0]);
          ok1 = (!mism[nn][1]) && ((cnt[nn]-8) == vec[ro1]);
          net = nn;
          if (!(ok0 || ok1)) begin
            bad("response frame mismatch vs candidates");
            if (dbg_shown < 6) begin
              dbg_shown = dbg_shown + 1;
              $display("  [dbg] mismatch net=%0d len=%0d ev=%0d cand=%0d/%0d p42-49=%02x%02x%02x%02x%02x%02x%02x%02x",
                       nn, cnt[nn]-8, ev[nn], cand_type[0], cand_type[1],
                       obsA[42], obsA[43], obsA[44], obsA[45], obsA[46], obsA[47], obsA[48], obsA[49]);
            end
          end
          else if (ok0 && ok1 && (cand_type[0] != cand_type[1]))
            bad("ambiguous response match");
          else begin
            last_type[nn] = (ok0 || (cand_type[0] == cand_type[1]))
                            ? cand_type[0] : cand_type[1];
          end
          last_cycle[nn] = cycle;
          if (nn == 0) begin
            $display("  [ev] cyc=%0d type=%0d len=%0d sn=%02x evidx=%0d",
                     cycle, (ok0 ? cand_type[0] : (ok1 ? cand_type[1] : -1)),
                     cnt[nn]-8, obsA[cnt[nn]-5], ev[nn]);
          end
          ev[nn] = ev[nn] + 1;
        end
      end
    end
  end

  // ---- host read (guard, works for register and load window) ----
  task read_word;
    input [15:0] address;
    output [31:0] value;
    integer guard;
    begin
      @(negedge clk); u_host.cs=1; u_host.we=0; u_host.addr=address;
      @(negedge clk); guard=0;
      while (hack!==1'b1 && guard<64) begin @(negedge clk); guard=guard+1; end
      if (hack!==1'b1) bad("public host read timeout");
      value=hrdata; u_host.cs=0;
    end
  endtask

  task configure;
    integer guard;
    reg [31:0] value;
    begin
      reset=1; repeat(8) @(negedge clk); reset=0;
      read_word(16'h000C,value); guard=0;
      while(!value[13] && guard<30000) begin read_word(16'h000C,value); guard=guard+1; end
      if(!value[13]) bad("default initialization timeout");
      u_host.wr(16'h0008,32'h2000);
      u_host.wr(16'h0078,32'h172D); u_host.wr(16'h007C,32'hAB61);
      u_host.wr(16'h42B2,32'h10100100); u_host.wr(16'h0080,1);
      u_host.wr(16'h1F80,32'hF5000000|(7<<12)|700); u_host.wr(16'h1F81,32'h0100);
      u_host.wr(16'h7D80+4*7,32'h80060000);
      u_host.wr(16'h7D81+4*7,5000); u_host.wr(16'h7D82+4*7,0); u_host.wr(16'h7D83+4*7,1);
      u_host.wr(16'h0204,7<<16); u_host.wr(16'h0203,0); u_host.wr(16'h0202,5000<<16);
      u_host.wr(16'h0201,1000<<8); u_host.wr(16'h0480,6040);
      u_host.wr(16'h0200,32'h80000003|(700<<12));
      u_host.wr(16'h0060,32'h172D2001); u_host.wr(16'h0064,32'h0A000002);
      u_host.wr(16'h0070,32'h0142);
      read_word(16'h005C,value); if(value!==0) bad("legal management configuration rejected");
      u_host.wr(16'h0008,32'h071F);
    end
  endtask

  task inject_req;
    input integer rid;
    integer rlen, rbase, i;
    begin
      rlen  = vec[REQ_IDX_WORD + 2*rid];
      rbase = vec[REQ_IDX_WORD + 2*rid + 1] + 1;
      @(negedge clk);
      for (i=0; i<rlen+8; i=i+1) begin
        rx_valid=1; rx_data=(i<7)?8'h55:((i==7)?8'hD5:byte_at(rbase,i-8));
        @(negedge clk);
      end
      rx_valid=0;
    end
  endtask

  task wait_to;
    input integer target;
    begin
      while (cycle < target) @(negedge clk);
    end
  endtask

  task set_cands;
    input integer td, t0, t1;
    begin cand_tid[0]=td; cand_tid[1]=td; cand_type[0]=t0; cand_type[1]=t1; end
  endtask

  task wait_phase;
    input integer f0, f1, target;
    integer guard;
    begin
      guard=0;
      while (!((ev[0]>f0 && last_type[0]==target) &&
               (ev[1]>f1 && last_type[1]==target))) begin
        @(negedge clk); guard=guard+1;
        if (guard>700000) begin bad("phase response timeout"); disable wait_phase; end
        // 允许前序 ACK 的重传链尾随（最多 2 个）+ 目标响应；再多为异常。
        if (ev[0]-f0 > 4 || ev[1]-f1 > 4) begin
          bad("too many responses in phase"); disable wait_phase;
        end
      end
    end
  endtask

  integer f0,f1, k, tprev, target;
  integer exp_crc1, exp_crc2, exp_len1, exp_len2;
  reg [31:0] hval;

  task check_image;
    input integer words_n, is_second;
    integer ww, jj, bb, oo, ee;
    reg [31:0] vv, ex;
    reg [7:0] by;
    begin
      ee = 0;
      for (ww=0; ww<words_n; ww=ww+1) begin
        read_word(16'hCC20 + ww[15:0], vv);
        ex = 32'd0;
        for (jj=0; jj<4; jj=jj+1) begin
          bb = (4*ww+jj)/512;
          oo = (4*ww+jj)%512;
          if (is_second) begin
            if (bb == 1) by = (oo*17 + 8'h2D) & 8'hFF;
            else         by = (oo*11 + 8'h63) & 8'hFF;
          end else begin
            by = (oo*7 + (bb+1)*8'h21) & 8'hFF;
          end
          ex = {ex[23:0], by};
        end
        if (vv !== ex) begin
          if (ee < 3) $display("  [img] word %0d got %08x exp %08x", ww, vv, ex);
          ee = ee + 1;
        end
      end
      checks = checks + words_n;
      if (ee != 0) begin
        if (is_second) img_err2 = img_err2 + ee; else img_err1 = img_err1 + ee;
        bad("image readback mismatch");
      end
    end
  endtask

  initial begin
    $timeformat(-9, 0, "ns", 12);
    $readmemh("vec/t45_contract.hex", vec, 0, `T45_WORDS-1);
    if (vec[0] !== 45) $fatal(1, "T45 missing contract vectors");
    exp_crc1 = vec[4]; exp_crc2 = vec[5];
    exp_len1 = vec[6]; exp_len2 = vec[7];
    configure();

    // ---- 阶段 0：WRQ1 → ACK(0) ----
    set_cands(0, 0, 0);
    f0=ev[0]; f1=ev[1];
    inject_req(0);
    wait_phase(f0, f1, 0);
    tprev = last_cycle[0];
    $display("T45 WRQ1 ACK0 wire_complete at cycle=%0d", tprev);

    // ---- 扫掠：X 为超时判决相对注入的时刻偏移（拍）。
    //      注入时刻 = tprev + 3750 - X；X<0 表示判决先于注入。
    //      期望序列：允许 1 次 ACK(k-1) 重传先行，最终必须 ACK(k)。
    for (k=1; k<=5; k=k+1) begin
      set_cands(0, k-1, k);
      case (k)
        1: target = -150;
        2: target = 200;
        3: target = 550;
        4: target = 900;
        default: target = 1250;
      endcase
      f0=ev[0]; f1=ev[1];
      wait_to(tprev + TO_CYCLES - target);
      inject_req(k);
      wait_phase(f0, f1, k);
      tprev = last_cycle[0];
      $display("T45 sweep k=%0d X=%0d ACK%0d wire_complete at cycle=%0d ev=%0d", k, target, k, tprev, ev[0]);
    end

    // ---- 513 B 超长 DATA（会话内）→ ERROR(4) ----
    set_cands(0, 5, 6);           // {ACK(5), ERROR(4)}，首会话 TID
    f0=ev[0]; f1=ev[1];
    wait_to(tprev + TO_CYCLES - 400);
    inject_req(6);
    wait_phase(f0, f1, 6);
    tprev = last_cycle[0];
    $display("T45 513B over-long -> ERROR(4) at cycle=%0d ev=%0d", tprev, ev[0]);

    // ---- 无会话 DATA → ERROR(5) ----
    set_cands(0, 7, 7);
    f0=ev[0]; f1=ev[1];
    wait_to(tprev + 300);
    inject_req(7);
    wait_phase(f0, f1, 7);
    tprev = last_cycle[0];
    $display("T45 no-session DATA -> ERROR(5) at cycle=%0d", tprev);

    // ---- 5 字节畸形 ACK → ERROR(5) ----
    set_cands(0, 7, 7);
    f0=ev[0]; f1=ev[1];
    wait_to(tprev + 300);
    inject_req(8);
    wait_phase(f0, f1, 7);
    tprev = last_cycle[0];
    $display("T45 malformed ACK -> ERROR(5) at cycle=%0d", tprev);

    // ---- 主机读回第一镜像：blocks 1..5 完好；寄存器一致 ----
    f0 = img_err1;
    check_image(640, 0);
    read_word(16'hAC21, hval); checks=checks+1;
    if (hval !== exp_len1) begin $display("  bytes got %0d exp %0d", hval, exp_len1); bad("bytes_rcvd1 wrong"); end
    read_word(16'hAC22, hval); checks=checks+1;
    if (hval !== exp_crc1) begin $display("  crc got %08x exp %08x", hval, exp_crc1); bad("crc1 wrong"); end
    read_word(16'hAC20, hval); checks=checks+1;
    if (hval[31] !== 1'b0) bad("loaded_ok set despite 513B error");
    if (img_err1 == f0)
      $display("T45 host image1 verified (crc=%08x len=%0d)", exp_crc1, exp_len1);

    // ---- 第二会话：WRQ2（新 TID）→ ACK(0) ----
    set_cands(1, 0, 0);
    f0=ev[0]; f1=ev[1];
    wait_to(tprev + 300);
    inject_req(9);
    wait_phase(f0, f1, 0);
    tprev = last_cycle[0];
    $display("T45 WRQ2 ACK0 at cycle=%0d", tprev);

    // ---- DATA2(1) 512B → ACK(1) ----
    set_cands(1, 0, 1);
    f0=ev[0]; f1=ev[1];
    wait_to(tprev + 300);
    inject_req(10);
    wait_phase(f0, f1, 1);
    tprev = last_cycle[0];

    // ---- DATA2(2) 8B 末块 → ACK(2) ----
    set_cands(1, 1, 2);
    f0=ev[0]; f1=ev[1];
    wait_to(tprev + 300);
    inject_req(11);
    wait_phase(f0, f1, 2);
    tprev = last_cycle[0];

    // ---- 主机读回第二镜像 ----
    check_image(130, 1);
    read_word(16'hAC21, hval); checks=checks+1;
    if (hval !== exp_len2) begin $display("  bytes got %0d exp %0d", hval, exp_len2); bad("bytes_rcvd2 wrong"); end
    read_word(16'hAC22, hval); checks=checks+1;
    if (hval !== exp_crc2) begin $display("  crc got %08x exp %08x", hval, exp_crc2); bad("crc2 wrong"); end
    read_word(16'hAC20, hval); checks=checks+1;
    if (hval[31] !== 1'b1) bad("loaded_ok not set after recovery load");
    if (u_host.errors != 0) bad("host stimulus failure");

    if (errors==0)
      $display("T45 TFTP TIMEOUT CONTRACT PASS checks=%0d events=%0d images_ok=2", checks, ev[0]);
    else
      $display("T45 TFTP TIMEOUT CONTRACT FAIL errors=%0d img1=%0d img2=%0d", errors, img_err1, img_err2);
    $finish;
  end

  initial begin
    #80000000;
    $display("T45 TFTP TIMEOUT CONTRACT FAIL timeout");
    $finish;
  end
endmodule
