// Public-port test of the FINAL default PHY GMII top, full 128TX/4096RX.
// 16 active TX VLs, legal 1ms BAG, 1024-byte payloads. Fixed wall-clock
// windows include header/FCS/IFG and scheduler idle time. A and B are
// measured separately; redundant bytes are never added together.
// A second phase injects independent golden PHY frames and counts only
// complete payloads independently verified through the public host port.
`timescale 1 ns / 1 ps
`include "vec/gmii_vectors.vh"
module tb_t42_gmii_metrics;
  localparam integer NVL=16, PLEN=1024, LMAX=PLEN+47;
  localparam integer BAG_CYC=125000, SLOT_CYC=BAG_CYC/NVL;
  localparam integer TX_PORT_BASE=16, RX_PORT=128, RX_INDEX=256, RX_FRAMES=32;
  localparam [63:0] SHARE64=((64'd1091*8*1048576)+999999)/1000000;
  localparam integer SHARE=SHARE64;
  reg clk=0, reset=1;
  always #4 clk=~clk;
  wire [7:0] tx_a, tx_b;
  wire dv_a, dv_b;
  reg [7:0] rx_a=0;
  reg rx_dv=0, rx_er=0, external_ready=0;
  always @(negedge clk) external_ready<=~external_ready;
  wire hcs,hwe,hack;
  wire [15:0] haddr;
  wire [31:0] hwdata,hrdata;
  AFDX_top dut (
    .clk(clk),.reset(reset),.tx_data(tx_a),.tx_valid(dv_a),.tx_ready(),
    .rx_data(rx_a),.rx_valid(rx_dv),.rx_ready(external_ready),.rx_error(rx_er),
    .tx_data_b(tx_b),.tx_valid_b(dv_b),.tx_ready_b(),
    .rx_data_b(8'd0),.rx_valid_b(1'b0),.rx_ready_b(~external_ready),.rx_error_b(1'b0),
    .host_cs(hcs),.host_we(hwe),.host_addr(haddr),.host_wdata(hwdata),
    .host_rdata(hrdata),.host_ack(hack),.host_irq(),
    .pps_in(1'b0),.pps_out(),.rtc_time_us(),.dbg_frame_event());
  afdx_host_bfm u_host (.clk(clk),.cs(hcs),.we(hwe),.addr(haddr),
                       .wdata(hwdata),.rdata(hrdata),.ack(hack));
  integer errors=0, checks=0, cycle=0;
  always @(posedge clk) cycle<=cycle+1;
  integer rounds=3, min_mbps=100;
  integer window_start=0, window_stop=0, tx_phase=0;
  reg [7:0] cap [0:1][0:1599];
  integer size[0:1], frame_count[0:1], gap[0:1], frame_start[0:1];
  integer vl_count[0:1][0:NVL-1];
  integer previous_start[0:1][0:NVL-1];
  integer min_vl_latency[0:1][0:NVL-1], max_vl_latency[0:1][0:NVL-1];
  integer commit_time[0:NVL-1][0:9999];
  reg active[0:1];
  reg [63:0] verified_tx_bytes[0:1];
  integer max_tx_latency=0, max_rx_latency=0, max_tx_jitter=0;
  reg [31:0] vec[0:`GMII_VECTOR_WORDS-1];
  reg [7:0] rx_packet[0:1517];
  integer golden_base, golden_length;
  reg [63:0] verified_rx_bytes=0;

  task bad;
    input [8*120-1:0] why;
    begin
      if(errors<30) $display("  [err] T42 cycle=%0d %0s",cycle,why);
      errors=errors+1;
    end
  endtask
  function [7:0] payload_byte;
    input integer vl,r,off;
    begin payload_byte=(vl*17+r*29+off*13+8'h53)&255; end
  endfunction
  function [31:0] crc_byte;
    input [31:0] old_crc;
    input [7:0] b;
    reg [31:0] c;
    integer bit_index;
    begin
      c=old_crc^{24'd0,b};
      for(bit_index=0;bit_index<8;bit_index=bit_index+1)
        c=c[0]?((c>>1)^32'hEDB8_8320):(c>>1);
      crc_byte=c;
    end
  endfunction
  function [7:0] golden_byte;
    input integer off;
    reg [31:0] q;
    begin q=vec[golden_base+off/4]; golden_byte=q[31-8*(off%4) -: 8]; end
  endfunction
  function [10:0] mix_bucket;
    input [15:0] vlid,seed;
    reg [15:0] x;
    begin
      x=vlid+seed+16'h9E37; x=x^(x>>7); x=x*16'h9E37; x=x^(x>>9);
      mix_bucket=x&11'h7FF;
    end
  endfunction
  task read_word;
    input [15:0] address;
    output [31:0] value;
    integer timeout_cycles;
    begin
      @(negedge clk); u_host.cs=1; u_host.we=0; u_host.addr=address;
      @(negedge clk); timeout_cycles=0;
      while(hack!==1'b1 && timeout_cycles<64) begin
        @(negedge clk); timeout_cycles=timeout_cycles+1;
      end
      if(hack!==1'b1) bad("public host read ACK timeout");
      value=hrdata; u_host.cs=0;
    end
  endtask

  task check_frame;
    input integer net;
    integer i,vl,r,prior_errors,latency;
    reg [31:0] crc,sum;
    begin
      prior_errors=errors;
      if(size[net]!=8+LMAX) bad("PHY TX frame length or continuous DV wrong");
      for(i=0;i<7;i=i+1) if(cap[net][i]!==8'h55) bad("TX preamble wrong");
      if(cap[net][7]!==8'hD5) bad("TX SFD wrong");
      if({cap[net][8],cap[net][9],cap[net][10],cap[net][11]}!==32'h03000000) bad("TX destination prefix wrong");
      vl=((cap[net][12]<<8)|cap[net][13])-16'h0100;
      if(vl<0 || vl>=NVL) bad("TX VLID outside configured active set");
      else begin
        r=vl_count[net][vl];
        if(r>=rounds) bad("unexpected extra frame for VL");
        else begin
          if(cap[net][8+42+PLEN]!==((r%255)+1)) bad("TX sequence number wrong");
          for(i=0;i<PLEN;i=i+1) begin
            if(cap[net][8+42+i]!==payload_byte(vl,r,i)) bad("TX payload differs from submitted data");
            checks=checks+1;
          end
          latency=cycle-commit_time[vl][r];
          if(latency<0 || latency>250000) bad("host commit to GMII final byte exceeds 2ms");
          if(latency>max_tx_latency) max_tx_latency=latency;
          if(latency<min_vl_latency[net][vl]) min_vl_latency[net][vl]=latency;
          if(latency>max_vl_latency[net][vl]) max_vl_latency[net][vl]=latency;
          if(r!=0 && frame_start[net]-previous_start[net][vl]<BAG_CYC)
            bad("same-VL physical frame starts violate 1ms BAG");
          previous_start[net][vl]=frame_start[net];
        end
        vl_count[net][vl]=r+1;
      end
      if(cap[net][19]!==((net==0)?8'h20:8'h40)) bad("A/B source interface identifier wrong");
      if({cap[net][20],cap[net][21]}!==16'h0800 || cap[net][22]!==8'h45) bad("TX EtherType/IP header wrong");
      if({cap[net][24],cap[net][25]}!==PLEN+28 || {cap[net][46],cap[net][47]}!==PLEN+8) bad("TX IP/UDP length wrong");
      crc=32'hFFFFFFFF;
      for(i=8;i<size[net];i=i+1) crc=crc_byte(crc,cap[net][i]);
      if(crc!==32'hDEBB20E3) begin
        $display("T42_CRC net=%0d vl=%0d frame=%0d crc=%08h size=%0d",net,vl,frame_count[net],crc,size[net]);
        bad("TX FCS residue mismatch");
      end
      sum=0;
      for(i=22;i<42;i=i+2) sum=sum+{cap[net][i],cap[net][i+1]};
      sum=(sum&65535)+(sum>>16); sum=(sum&65535)+(sum>>16);
      if(sum!==65535) bad("TX IPv4 checksum mismatch");
      if(prior_errors==errors && frame_start[net]>=window_start && cycle<=window_stop)
        verified_tx_bytes[net]=verified_tx_bytes[net]+PLEN;
      frame_count[net]=frame_count[net]+1;
    end
  endtask
  task capture_byte;
    input integer net;
    input vld;
    input [7:0] value;
    begin
      if(vld) begin
        if(!active[net]) begin
          if(frame_count[net]!=0 && gap[net]<12) bad("GMII IFG shorter than 12 clocks");
          active[net]=1; size[net]=0; frame_start[net]=cycle;
        end
        if(size[net]<1600) cap[net][size[net]]=value;
        else bad("GMII capture overflow");
        size[net]=size[net]+1; gap[net]=0;
      end else begin
        gap[net]=gap[net]+1;
        if(active[net]) begin check_frame(net); active[net]=0; end
      end
    end
  endtask
  always @(posedge clk) if(!reset && tx_phase!=0) begin
    capture_byte(0,dv_a,tx_a); capture_byte(1,dv_b,tx_b);
  end

  task send_msg;
    input integer vl,r,when_cycle;
    integer j,waitc,block,port;
    reg [31:0] value;
    begin
      port=TX_PORT_BASE+vl;
      read_word(16'h0074,value); waitc=0;
      while(!value[4] && waitc<10000) begin read_word(16'h0074,value); waitc=waitc+1; end
      if(!value[4]) bad("no open TX payload block");
      block=value[3:0];
      @(negedge clk); u_host.cs=1; u_host.we=1;
      for(j=0;j<PLEN/4;j=j+1)
        u_host.wr_burst_word(16'h8800+(block<<9)+j,
          {payload_byte(vl,r,4*j),payload_byte(vl,r,4*j+1),
           payload_byte(vl,r,4*j+2),payload_byte(vl,r,4*j+3)});
      u_host.cs=0; u_host.we=0;
      while(cycle<when_cycle) @(negedge clk);
      commit_time[vl][r]=cycle;
      u_host.wr(16'h8280+port,PLEN);
    end
  endtask
  task inject_rx;
    input integer sequence_number;
    integer j;
    reg [31:0] crc;
    begin
      for(j=0;j<golden_length;j=j+1) rx_packet[j]=golden_byte(j);
      rx_packet[42+PLEN]=sequence_number;
      crc=32'hFFFFFFFF;
      for(j=0;j<golden_length-4;j=j+1) crc=crc_byte(crc,rx_packet[j]);
      crc=crc^32'hFFFFFFFF;
      rx_packet[golden_length-4]=crc[7:0]; rx_packet[golden_length-3]=crc[15:8];
      rx_packet[golden_length-2]=crc[23:16]; rx_packet[golden_length-1]=crc[31:24];
      for(j=0;j<8+golden_length;j=j+1) begin
        rx_a=(j<7)?8'h55:((j==7)?8'hD5:rx_packet[j-8]); rx_dv=1;
        @(negedge clk);
      end
      rx_dv=0;
    end
  endtask
  task verify_rx;
    input integer start_cycle,deadline;
    integer waitc,block,j,k,off,prior_errors,latency;
    reg [31:0] value;
    begin
      prior_errors=errors; waitc=0;
      read_word(16'h8480+RX_PORT,value);
      while(value==0 && waitc<10000) begin read_word(16'h8480+RX_PORT,value); waitc=waitc+1; end
      if(value!==1) bad("RX message count differs from one");
      read_word(16'h8180+RX_PORT,value);
      if(value[31]!==1'b1 || value[10:0]!==PLEN) bad("RX public descriptor invalid");
      block=value[23:20];
      for(j=10;j<=(42+PLEN-1)/4;j=j+1) begin
        read_word(16'h8800+(block<<9)+j,value);
        for(k=0;k<4;k=k+1) begin
          off=j*4+k;
          if(off>=42 && off<42+PLEN) begin
            if(value[31-8*k -: 8]!==golden_byte(off)) bad("RX public PMEM payload mismatch");
            checks=checks+1;
          end
        end
      end
      u_host.wr(16'h8380+RX_PORT,32'd0);
      latency=cycle-start_cycle;
      if(latency>250000) bad("GMII first byte to verified host payload exceeds 2ms");
      if(latency>max_rx_latency) max_rx_latency=latency;
      if(cycle>=deadline) bad("RX verification completed outside fixed throughput window");
      if(prior_errors==errors) verified_rx_bytes=verified_rx_bytes+PLEN;
    end
  endtask

  integer i,r,net,pos,t_start,rx_start,rx_stop,first,metric_fd;
  reg [31:0] value;
  real tx_mbps_a,tx_mbps_b,rx_mbps;
  initial begin
    if($value$plusargs("T42_ROUNDS=%d",rounds)) ;
    if($value$plusargs("T42_MIN_MBPS=%d",min_mbps)) ;
    if(rounds<2 || rounds>10000) $fatal(1,"T42_ROUNDS must be 2..10000");
    $readmemh("vec/gmii_frames.hex",vec,0,`GMII_VECTOR_WORDS-1);
    pos=1; golden_base=0; golden_length=0;
    for(i=0;i<4;i=i+1) begin
      if(vec[pos]==PLEN) begin golden_base=pos+2; golden_length=vec[pos+1]; end
      pos=pos+2+(vec[pos+1]+3)/4;
    end
    if(golden_length!=LMAX) $fatal(1,"T42 missing independent 1024-byte payload vector");
    for(net=0;net<2;net=net+1) begin
      active[net]=0; size[net]=0; frame_count[net]=0; gap[net]=100; verified_tx_bytes[net]=0;
      for(i=0;i<NVL;i=i+1) begin
        vl_count[net][i]=0; previous_start[net][i]=0;
        min_vl_latency[net][i]=2147483647; max_vl_latency[net][i]=0;
      end
    end
    repeat(7) @(negedge clk); reset=0;
    // INIT_DONE is observed through the public STATUS register.
    read_word(16'h000C,value);
    while(!value[13] && cycle<40000) read_word(16'h000C,value);
    if(!value[13]) bad("INIT_DONE timeout");
    u_host.wr(16'h0008,32'h2000);
    u_host.wr(16'h0060,32'h12342001); u_host.wr(16'h0064,32'h0A000001);
    u_host.wr(16'h0070,32'h00000142);
    for(i=0;i<NVL;i=i+1) begin
      // Ports 6/7 are reserved management SAPs in the default top.
      u_host.wr(16'h7D80+4*(TX_PORT_BASE+i)+3,1);
      u_host.wr(16'h7D80+4*(TX_PORT_BASE+i),32'h8000C000|i);
      u_host.wr(16'h0204+5*i,(TX_PORT_BASE+i)<<16); u_host.wr(16'h0203+5*i,32'hE0000001);
      u_host.wr(16'h0202+5*i,32'h1388C000);
      u_host.wr(16'h0201+5*i,1000<<8); u_host.wr(16'h0480+i,SHARE);
      u_host.wr(16'h0200+5*i,32'h80000003|(LMAX<<12));
    end
    read_word(16'h0058,value); if(value!==NVL*SHARE) bad("1Gbps-normalized CFG_SUM mismatch");
    read_word(16'h005C,value); if(value!==0) bad("legal PHY load rejected");
    u_host.wr(16'h0078,32'h172D); u_host.wr(16'h007C,32'hAB61);
    u_host.wr(16'h3D80+(mix_bucket(16'h0100,16'h172D)<<1),32'h10100100);
    u_host.wr(16'h0080,1);
    u_host.wr(16'h1F80,32'hF5000000|(RX_PORT<<12)|LMAX); u_host.wr(16'h1F81,32'h0100);
    u_host.wr(16'h7D80+4*RX_PORT,32'h80040000);
    u_host.wr(16'h7D81+4*RX_PORT,5000); u_host.wr(16'h7D82+4*RX_PORT,0);
    u_host.wr(16'h7D83+4*RX_PORT,1);
    u_host.wr(16'h0008,1);
    t_start=cycle; window_start=t_start+BAG_CYC; window_stop=t_start+rounds*BAG_CYC;
    tx_phase=1;
    for(r=0;r<rounds;r=r+1)
      for(i=0;i<NVL;i=i+1) send_msg(i,r,t_start+r*BAG_CYC+i*BAG_CYC/NVL);
    while(cycle<window_stop+2000) @(negedge clk);
    for(net=0;net<2;net=net+1) begin
      if(frame_count[net]!=NVL*rounds || active[net]) bad("TX exact total/complete frame check failed");
      for(i=0;i<NVL;i=i+1) begin
        if(vl_count[net][i]!=rounds) bad("TX VL missing expected rounds");
        if(max_vl_latency[net][i]-min_vl_latency[net][i]>max_tx_jitter)
          max_tx_jitter=max_vl_latency[net][i]-min_vl_latency[net][i];
      end
    end
    // 50us is this project's declared conservative representative-scenario
    // bound; the organizer has not specified an exact jitter statistic.
    if(max_tx_jitter>6250) bad("per-VL latency range exceeds project 50us bound");
    tx_mbps_a=$itor(verified_tx_bytes[0])*8.0/((window_stop-window_start)*0.008);
    tx_mbps_b=$itor(verified_tx_bytes[1])*8.0/((window_stop-window_start)*0.008);
    if(tx_mbps_a<min_mbps || tx_mbps_b<min_mbps) bad("measured per-net TX payload throughput below target");
    u_host.wr(16'h0008,32'h051E); tx_phase=0;
    rx_start=cycle+20; rx_stop=rx_start+RX_FRAMES*SLOT_CYC;
    for(i=0;i<RX_FRAMES;i=i+1) begin
      while(cycle<rx_start+i*SLOT_CYC) @(negedge clk);
      first=cycle; inject_rx(i+1); verify_rx(first,rx_stop);
    end
    while(cycle<rx_stop) @(negedge clk);
    rx_mbps=$itor(verified_rx_bytes)*8.0/((rx_stop-rx_start)*0.008);
    if(verified_rx_bytes!=RX_FRAMES*PLEN || rx_mbps<min_mbps) bad("measured verified RX payload throughput below target");
    if(u_host.errors!=0) bad("host stimulus protocol errors");
    metric_fd=$fopen("out/metrics/t42_gmii.csv","w");
    if(metric_fd==0) bad("cannot create GMII metrics report");
    else begin
      $fdisplay(metric_fd,"direction,verified_payload_bytes,window_cycles,clock_period_ns,payload_mbps");
      $fdisplay(metric_fd,"tx_a,%0d,%0d,8,%.6f",verified_tx_bytes[0],window_stop-window_start,tx_mbps_a);
      $fdisplay(metric_fd,"tx_b,%0d,%0d,8,%.6f",verified_tx_bytes[1],window_stop-window_start,tx_mbps_b);
      $fdisplay(metric_fd,"rx_a,%0d,%0d,8,%.6f",verified_rx_bytes,rx_stop-rx_start,rx_mbps);
      $fclose(metric_fd);
    end
    $display("T42_METRIC tx_a_payload_mbps=%.6f tx_b_payload_mbps=%.6f rx_verified_payload_mbps=%.6f tx_commit_to_gmii_eof_max_us=%.3f rx_gmii_sof_to_verified_host_max_us=%.3f",tx_mbps_a,tx_mbps_b,rx_mbps,max_tx_latency*0.008,max_rx_latency*0.008);
    $display("T42_JITTER statistic=per_vl_host_commit_to_gmii_eof_latency_range max_us=%.3f project_bound_us=50 official_exact_bound_unspecified=1",max_tx_jitter*0.008);
    if(errors==0) $display("T42 GMII METRICS PASS checks=%0d rounds=%0d frames_a=%0d frames_b=%0d rx_frames=%0d ready_ignored=1",checks,rounds,frame_count[0],frame_count[1],RX_FRAMES);
    else $display("T42 GMII METRICS FAIL errors=%0d",errors);
    $finish;
  end
  initial begin
    #1; #((rounds+10)*64'd1000000);
    $display("T42 GMII METRICS FAIL timeout"); $finish;
  end
endmodule
