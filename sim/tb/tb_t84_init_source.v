// T84: explicit initialization source and public GMII WRQ.
`timescale 1 ns / 1 ps
module tb_t84_init_source;
  reg clk=0, reset=1;
  always #4 clk=~clk;
  reg [7:0] rx_data=0;
  reg rx_valid=0;
  wire [7:0] tx_data[0:1];
  wire tx_valid[0:1];
  wire hcs,hwe,hack;
  wire [15:0] haddr;
  wire [31:0] hwdata,hrdata;
  AFDX_top #(.TFTP_TIMEOUT_US(50), .TX_MESSAGE_CHAIN_BLOCKS(4), .RX_REASM_CHAIN_BLOCKS(5)) dut (
    .clk(clk),.reset(reset),.tx_data(tx_data[0]),.tx_valid(tx_valid[0]),.tx_ready(),
    .rx_data(rx_data),.rx_valid(rx_valid),.rx_ready(1'b0),.rx_error(1'b0),
    .tx_data_b(tx_data[1]),.tx_valid_b(tx_valid[1]),.tx_ready_b(),
    .rx_data_b(8'd0),.rx_valid_b(1'b0),.rx_ready_b(1'b0),.rx_error_b(1'b0),
    .host_cs(hcs),.host_we(hwe),.host_addr(haddr),.host_wdata(hwdata),
    .host_rdata(hrdata),.host_ack(hack),.host_irq(),
    .pps_in(1'b0),.pps_out(),.rtc_time_us(),.dbg_frame_event());
  afdx_host_bfm u_host (.clk(clk),.cs(hcs),.we(hwe),.addr(haddr),.wdata(hwdata),.rdata(hrdata),.ack(hack));


  integer errors=0,checks=0,cycle=0,guard,i,j;
  reg [31:0] himg[0:8191],hmeta[0:3],v,acks[0:292];
  reg [7:0] expected[0:8];
  integer fcount[0:1],count[0:1],fh[0:1];
  reg [7:0] frames[0:1][0:3][0:1530];
  integer lens[0:1][0:3];
  reg active[0:1];
  integer n,idx,k,probe;
  task bad;
    input [8*112-1:0] reason;
    begin if(errors<20) $display("  [err] T84 %0s",reason);errors=errors+1;end
  endtask
  task chk;
    input cond;input [8*112-1:0] reason;
    begin checks=checks+1;if(cond!==1'b1)bad(reason);end
  endtask
  always @(posedge clk) begin
    cycle=cycle+1;
    for(n=0;n<2;n=n+1) begin
      if(tx_valid[n]) begin
        if(fcount[n]>=4 || count[n]>=1531)$fatal(1,"T84 extra/overflow PHY");
        active[n]=1;frames[n][fcount[n]][count[n]]=tx_data[n];
        $fwrite(fh[n],"%02x ",tx_data[n]);count[n]=count[n]+1;
      end else if(active[n])begin
        active[n]=0;lens[n][fcount[n]]=count[n];count[n]=0;
        fcount[n]=fcount[n]+1;$fwrite(fh[n],"\n");
      end
    end
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
  task inject;
    input integer number;
    integer off,b;
    begin
      off=1;for(b=0;b<number;b=b+1)off=off+1+acks[off];
      @(negedge clk);
      for(b=0;b<acks[off];b=b+1)begin
        rx_valid=1;rx_data=acks[off+1+b][7:0];@(negedge clk);
      end
      rx_valid=0;repeat(20)@(negedge clk);
    end
  endtask
  task wait_frames;
    input integer target;
    integer timeout;
    begin
      timeout=0;
      while((fcount[0]<target || fcount[1]<target) && timeout<1000000)begin
        @(negedge clk);timeout=timeout+1;
      end
      chk(fcount[0]==target && fcount[1]==target,"both networks completed expected frame");
    end
  endtask
  task wait_source;
    begin
      guard=0;v=0;
      while(!v[1] && guard<64)begin read_word(16'hAC58,v);guard=guard+1;end
      chk(v[3:0]===4'b0010,"source published once with done and no error");
      read_word(16'hAC4C,v);chk(v[17:0]===18'd9,"published length and error");
      read_word(16'hAC4D,v);chk(v[0]===1'b1,"published valid held");
    end
  endtask
  task read_source;
    input [31:0] fields;
    integer b;
    begin
      expected[0]=0;expected[1]=0;expected[2]=0;expected[3]=9;
      expected[4]=fields[31:24];expected[5]=fields[23:16];
      expected[6]=fields[15:8];expected[7]=fields[7:0];expected[8]=0;
      for(b=0;b<9;b=b+1)begin
        write_word(16'hAC4E,b);repeat(2)@(negedge clk);read_word(16'hAC4F,v);
        chk(v[7:0]===expected[b],"all nine public host bytes match explicit fields");
      end
    end
  endtask
  task upload;
    input integer job;
    integer b;
    begin
      write_word(16'hAC41,32'h0A000001);
      write_word(16'hAC42,32'h54415247);write_word(16'hAC43,32'h45542E4C);
      write_word(16'hAC44,32'h55490000);write_word(16'hAC4A,10);
      write_word(16'hAC4B,3000);write_word(16'hAC54,32'h3001);
      write_word(16'hAC40,5);
      wait_frames(2*job+1);
      for(b=0;b<2;b=b+1) begin
        chk(frames[b][2*job][50]===0 && frames[b][2*job][51]===2,"WRQ opcode");
        chk(frames[b][2*job][44]===0 && frames[b][2*job][45]===69,"WRQ well-known port");
      end
      inject(2*job);wait_frames(2*job+2);
      for(b=0;b<2;b=b+1)begin
        chk(frames[b][2*job+1][50]===0 && frames[b][2*job+1][51]===3 &&
            frames[b][2*job+1][52]===0 && frames[b][2*job+1][53]===1,"DATA block one");
        chk(frames[b][2*job+1][46]===0 && frames[b][2*job+1][47]===21,"UDP length nine-byte file");
        for(k=0;k<9;k=k+1)chk(frames[b][2*job+1][54+k]===expected[k],"both PHY file contents");
      end
      inject(2*job+1);guard=0;v=0;
      while(!v[3] && guard<1000)begin read_word(16'hAC40,v);guard=guard+1;end
      chk(v[3:1]===3'b100,"WRQ done after ACK1 without failure");
      read_word(16'hAC4D,v);chk(v[0]===1'b1,"uploaded source remains host owned");
      u_host.stall_probe_write(16'hAC58,1,3,probe);
      chk(probe==1,"new initialization waits until file release");
      write_word(16'hAC4D,1);repeat(3)@(negedge clk);
    end
  endtask
  initial begin
    for(idx=0;idx<2;idx=idx+1)begin fcount[idx]=0;count[idx]=0;active[idx]=0;end
    fh[0]=$fopen("out/metrics/t84_init_a.hex","w");fh[1]=$fopen("out/metrics/t84_init_b.hex","w");
    if(!fh[0] || !fh[1])$fatal(1,"T84 capture open");
    $readmemh("vec/t84_init_source/acks.hex",acks,0,292);
    $readmemh("vec/t12_top.img.hex",himg,0,8191);
    $readmemh("vec/t12_top.meta.hex",hmeta,0,3);
    configure();
    $display("T84 CASE abort-partial");
    write_word(16'hAC59,32'h41310002);write_word(16'hAC58,1);
    write_word(16'hAC58,2);repeat(4)@(negedge clk);
    read_word(16'hAC58,v);chk(v[2:0]===3'b100,"abort clears busy and reports error");
    read_word(16'hAC4D,v);chk(v[0]===0,"partial initialization never published");
    $display("T84 CASE disable-partial");
    write_word(16'hAC58,1);write_word(16'h0008,32'h051F);
    repeat(4)@(negedge clk);read_word(16'hAC4D,v);chk(v[0]===0,"disable cancels partial source");
    read_word(16'hAC58,v);chk(v[3:0]===4'b0100,"disabled source not ready and cancelled");
    u_host.stall_probe_write(16'hAC58,1,3,probe);chk(probe==1,"disabled source start is not acknowledged");
    write_word(16'h0008,32'h071F);
    $display("T84 CASE host-preload-owner");
    write_word(16'hAC57,1);
    u_host.stall_probe_write(16'hAC58,1,3,probe);chk(probe==1,"host preload owns shared memory");
    write_word(16'hAC57,2);repeat(3)@(negedge clk);
    $display("T84 CASE explicit-A1-upload");
    write_word(16'hAC59,32'h41310002);write_word(16'hAC58,1);
    u_host.stall_probe_write(16'hAC55,255,3,probe);chk(probe==1,"host byte blocked during hardware pump");
    write_word(16'hAC59,32'hFFFFFFFF);wait_source();read_source(32'h41310002);upload(0);
    $display("T84 CASE raw-tag-restart");
    write_word(16'hAC59,32'h11223344);write_word(16'hAC58,1);
    wait_source();read_source(32'h11223344);upload(1);
    $display("T84 CASE published-idle-abort");
    write_word(16'hAC59,32'h55667788);write_word(16'hAC58,1);
    wait_source();write_word(16'hAC58,2);repeat(3)@(negedge clk);
    read_word(16'hAC4D,v);chk(v[0]===1'b1,"idle abort does not release host-owned published source");
    read_source(32'h55667788);write_word(16'hAC4D,1);
    $display("T84 CASE reset-partial");
    write_word(16'hAC58,1);reset=1;repeat(8)@(negedge clk);reset=0;
    repeat(4)@(negedge clk);read_word(16'hAC4D,v);chk(v[0]===0,"reset cancels partial initialization");
    read_word(16'hAC58,v);chk(v[3:0]===0,"reset clears source status and disables it");
    chk(u_host.errors==0,"all public host transactions acknowledged correctly");
    repeat(100)@(negedge clk);
    $fclose(fh[0]);$fclose(fh[1]);
    if(errors==0)$display("T84 INIT SOURCE PASS checks=%0d jobs=2 frames_per_net=4 file_bytes=18 control_cases=5",checks);
    else $display("T84 INIT SOURCE FAIL errors=%0d",errors);
    $finish;
  end
  initial begin #25000000;$display("T84 INIT SOURCE FAIL timeout");$finish;end
endmodule

