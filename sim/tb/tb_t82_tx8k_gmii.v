// Full-size production AFDX_top, opt-in four-block TX, default PHY GMII.
// Public registers/PMEM for normal stimulus and all payload/resource verdicts.
// Recovery deliberately corrupts launch metadata; expected PHY bytes stay external.
`timescale 1 ns / 1 ps
module tb_t82_tx8k_gmii;
  reg clk=0,reset=1;
  always #4 clk=~clk;
  wire [7:0] tx_a,tx_b;
  wire dv_a,dv_b;
  wire hcs,hwe,hack;
  wire [15:0] haddr;
  wire [31:0] hwdata,hrdata;
  reg ready_flip=0;
  always @(negedge clk)ready_flip<=!ready_flip;
  AFDX_top #(.TX_MESSAGE_CHAIN_BLOCKS(4)) dut (
    .clk(clk),.reset(reset),.tx_data(tx_a),.tx_valid(dv_a),.tx_ready(),
    .rx_data(8'd0),.rx_valid(1'b0),.rx_ready(ready_flip),.rx_error(1'b0),
    .tx_data_b(tx_b),.tx_valid_b(dv_b),.tx_ready_b(),.rx_data_b(8'd0),.rx_valid_b(1'b0),.rx_ready_b(!ready_flip),.rx_error_b(1'b0),
    .host_cs(hcs),.host_we(hwe),.host_addr(haddr),.host_wdata(hwdata),.host_rdata(hrdata),.host_ack(hack),.host_irq(),
    .pps_in(1'b0),.pps_out(),.rtc_time_us(),.dbg_frame_event()
  );
  afdx_host_bfm u_host(.clk(clk),.cs(hcs),.we(hwe),.addr(haddr),.wdata(hwdata),.rdata(hrdata),.ack(hack));
  integer errors=0,checks=0,cycle=0,cases=0,capture_a=0,capture_b=0;
  always @(posedge clk)cycle<=cycle+1;
  task check;
    input condition;
    input [767:0] text;
    begin checks=checks+1;if(condition!==1'b1)begin errors=errors+1;if(errors<25)$display("T82 ERROR case=%0d cycle=%0d %0s",cases,cycle,text);end end
  endtask
  task read_word;
    input [15:0] address;
    output [31:0] value;
    integer t;
    begin
      @(negedge clk);u_host.cs=1;u_host.we=0;u_host.addr=address;
      @(negedge clk);t=0;
      while(hack!==1 && t<128)begin @(negedge clk);t=t+1;end
      check(hack===1,"public host read ACK timeout");value=hrdata;u_host.cs=0;
    end
  endtask
  reg [7:0] app [0:8191];
  reg [7:0] expected_a [0:5][0:1529];
  reg [7:0] expected_b [0:5][0:1529];
  integer expected_length [0:5];
  integer expected_frames=0,n_a=0,n_b=0,frame_a=0,frame_b=0,start_a=0,start_b=0,previous_a=-1,previous_b=-1;
  integer last_a=0,last_b=0,commit_cycle=0,latency_a=0,latency_b=0;
  reg prev_a=0,prev_b=0,monitor=0;
  always @(posedge clk) begin
    if(!reset && monitor) begin
      if(dv_a)begin
        $fwrite(capture_a,"%02x ",tx_a);
        if(!prev_a)begin
          check(cycle-last_a>=12 || frame_a==0,"GMII A IFG shorter than12");
          start_a=cycle;
          if(previous_a>=0)check(start_a-previous_a>=125000,"A physical fragment start violates1ms BAG");
          previous_a=start_a;
        end
        check(frame_a<expected_frames && n_a<expected_length[frame_a],"unexpected A frame/byte");
        check(tx_a===expected_a[frame_a][n_a],"A golden frame/header/payload/FCS mismatch");n_a=n_a+1;
      end else if(prev_a)begin
        $fwrite(capture_a,"\n");
        check(n_a==expected_length[frame_a],"A frame contains gap/truncation");
        frame_a=frame_a+1;n_a=0;last_a=cycle;
      end
      if(dv_b)begin
        $fwrite(capture_b,"%02x ",tx_b);
        if(!prev_b)begin
          check(cycle-last_b>=12 || frame_b==0,"GMII B IFG shorter than12");
          start_b=cycle;
          if(previous_b>=0)check(start_b-previous_b>=125000,"B physical fragment start violates1ms BAG");
          previous_b=start_b;
        end
        check(frame_b<expected_frames && n_b<expected_length[frame_b],"unexpected B frame/byte");
        check(tx_b===expected_b[frame_b][n_b],"B golden frame/header/payload/FCS mismatch");n_b=n_b+1;
      end else if(prev_b)begin
        $fwrite(capture_b,"\n");
        check(n_b==expected_length[frame_b],"B frame contains gap/truncation");
        frame_b=frame_b+1;n_b=0;last_b=cycle;
      end
      prev_a=dv_a;prev_b=dv_b;
    end
  end
  integer fd,rc,v,total,message_length,checksum_enable,j,k,f,physical,base,word_index,timeout,total_frames=0,verified_bytes=0;
  integer recovery_case,recovery_total,failed_length,failed_offset,fault_kind,message_index;
  integer recovery_frames=0,recovery_bytes=0,faults_injected=0,sn_errors=0;
  reg fault_armed=0,fault_active=0;
  // Fault selection uses only launch phase/offset. No internal payload or
  // resource state is used to manufacture a golden frame or PASS outcome.
  always @(negedge clk)if(!reset)begin
    if(dut.u_sn.err)sn_errors=sn_errors+1;
    if(fault_armed && !fault_active && dut.g_tx_fragment.u_launch.state==2 &&
       dut.g_tx_fragment.u_launch.offset_q==failed_offset &&
       dut.g_tx_fragment.u_launch.len_q==failed_length)begin
      if(fault_kind==0)force dut.g_tx_fragment.u_launch.len_q=14'd0;
      else force dut.g_tx_fragment.u_launch.count_q=3'd0;
      fault_active=1;
    end
    if(fault_active && dut.chain_fb_error)begin
      release dut.g_tx_fragment.u_launch.len_q;
      release dut.g_tx_fragment.u_launch.count_q;
      fault_active=0;fault_armed=0;faults_injected=faults_injected+1;
    end
  end
  reg [31:0] value,blocks_word,masks_word,packed_word;
  task get_word;
    output integer number;
    begin rc=$fscanf(fd,"%h",number);if(rc!=1)begin $display("T82 FAIL truncated golden");$finish;end end
  endtask
  task write_application;
    input integer n;
    begin
      u_host.wr(16'h8590,n);read_word(16'h8590,value);
      check(value[18] && value[17] && value[13:0]==n,"recovery reserve status");
      read_word(16'h8591,blocks_word);
      for(j=0;j<n;j=j+4)begin
        case(j/2048)
          0:physical=blocks_word[3:0];1:physical=blocks_word[7:4];2:physical=blocks_word[11:8];default:physical=blocks_word[15:12];
        endcase
        packed_word=0;for(k=0;k<4;k=k+1)if(j+k<n)packed_word[31-8*k -:8]=app[j+k];
        u_host.wr(16'h8800+physical*512+(j%2048)/4,packed_word);
      end
      u_host.wr(16'h8290,n);
    end
  endtask
  initial begin
    capture_a=$fopen("out/metrics/t82_tx_a.hex","w");capture_b=$fopen("out/metrics/t82_tx_b.hex","w");
    if(!capture_a || !capture_b)begin $display("T82 FAIL could not open PHY captures");$finish;end
    repeat(7)@(negedge clk);reset=0;
    read_word(16'h000c,value);timeout=0;
    while(!value[13] && timeout<30000)begin read_word(16'h000c,value);timeout=timeout+1;end
    check(value[13],"initialization timeout");
    u_host.wr(16'h0008,32'h2000);u_host.wr(16'h0060,32'h12342001);u_host.wr(16'h0064,32'hc0a80101);
    // Queuing TX port16, VL0; 1518-byte MAC maximum and legal1ms BAG.
    u_host.wr(16'h7dc3,3);u_host.wr(16'h7dc0,32'h80010000);
    u_host.wr(16'h0204,32'h00100000);u_host.wr(16'h0203,32'hc0a80102);
    u_host.wr(16'h0202,32'h56781234);u_host.wr(16'h0201,(1000<<8)|12);
    u_host.wr(16'h0480,12902);u_host.wr(16'h0200,32'h80000003|(1518<<12));
    read_word(16'h005c,value);check(value==0,"configuration rejected");
    u_host.wr(16'h0008,1);
    fd=$fopen("vec/t82_tx8k/cases.hex","r");if(!fd)begin $display("T82 FAIL missing golden");$finish;end
    get_word(total);
    for(cases=0;cases<total;cases=cases+1)begin
      get_word(message_length);get_word(checksum_enable);get_word(expected_frames);
      for(j=0;j<message_length;j=j+1)begin get_word(v);app[j]=v;end
      for(f=0;f<expected_frames;f=f+1)begin
        get_word(expected_length[f]);
        for(j=0;j<expected_length[f];j=j+1)begin get_word(v);expected_a[f][j]=v;end
        for(j=0;j<expected_length[f];j=j+1)begin get_word(v);expected_b[f][j]=v;end
      end
      // No direct DUT-memory writes. Reserve, read chain, write each owned word.
      u_host.wr(16'h0070,checksum_enable ? 32'h142 : 32'h140);
      u_host.wr(16'h8590,message_length);read_word(16'h8590,value);
      check(value[18] && value[17] && value[13:0]==message_length,"reserve status/14-bit length");
      check(value[16:14]==(message_length+2047)/2048,"public reserved count");
      read_word(16'h8591,blocks_word);read_word(16'h8592,masks_word);
      check((masks_word[31:16] & masks_word[15:0])==0,"free/reserved mask overlap");
      for(j=0;j<message_length;j=j+4)begin
        case(j/2048)
          0:physical=blocks_word[3:0];1:physical=blocks_word[7:4];2:physical=blocks_word[11:8];default:physical=blocks_word[15:12];
        endcase
        packed_word=0;for(k=0;k<4;k=k+1)if(j+k<message_length)packed_word[31-8*k -:8]=app[j+k];
        u_host.wr(16'h8800+physical*512+(j%2048)/4,packed_word);
      end
      frame_a=0;frame_b=0;n_a=0;n_b=0;prev_a=0;prev_b=0;monitor=1;
      commit_cycle=cycle;u_host.wr(16'h8290,message_length);timeout=0;
      if(expected_frames>1)begin
        // The first fragment is building here. Scheduling is inhibited for
        // its head, but the publicly queued complete-message descriptor stays visible.
        repeat(32)@(negedge clk);read_word(16'h8190,value);
        check(value[27] && {value[28],value[20:8]}==message_length,"in-flight non-final descriptor disappeared/lost full length");
      end
      while((frame_a<expected_frames || frame_b<expected_frames) && timeout<1000000)begin @(negedge clk);timeout=timeout+1;end
      check(frame_a==expected_frames && frame_b==expected_frames,"complete-message frame count/time limit");
      repeat(30)@(negedge clk);monitor=0;
      read_word(16'h8592,value);check((value[31:16]|value[15:0])==16'h003f,"final consumer did not return full chain");
      read_word(16'h8190,value);check(!value[27],"last fragment left queue descriptor valid");
      read_word(16'h0010,value);check(value[0]==0,"public host access error");
      total_frames=total_frames+expected_frames;verified_bytes=verified_bytes+message_length;
      read_word(16'h0108,value);check(value==total_frames,"public TX frame stats mismatch");
      read_word(16'h0109,value);check(value==verified_bytes,"public TX application byte stats include UDP header/wrong frame");
      read_word(16'h010a,value);check(value==0,"unexpected TX byte counter high word");
      latency_a=(last_a-commit_cycle)*8;latency_b=(last_b-commit_cycle)*8;
      $display("T82 LATENCY index=%0d app=%0d commit_call_to_last_A_ns=%0d B_ns=%0d",cases,message_length,latency_a,latency_b);
      $display("T82 MESSAGE_DONE index=%0d app=%0d frames=%0d errors=%0d",cases,message_length,expected_frames,errors);
    end
    rc=$fscanf(fd,"%h",v);check(rc!=1,"unconsumed golden words");$fclose(fd);
    // Four deliberate metadata faults: first/later non-final, multi-fragment
    // final and single-fragment final. Two successors are queued before enable.
    // All expected bytes, frame counts and stats come from serialized golden.
    fd=$fopen("vec/t82_recovery/cases.hex","r");if(!fd)begin $display("T82 FAIL missing recovery golden");$finish;end
    get_word(recovery_total);check(recovery_total==4,"recovery case count");
    for(recovery_case=0;recovery_case<recovery_total;recovery_case=recovery_case+1)begin
      get_word(failed_length);get_word(failed_offset);get_word(fault_kind);get_word(expected_frames);
      u_host.wr(16'h0008,0);u_host.wr(16'h0070,32'h142);
      for(message_index=0;message_index<3;message_index=message_index+1)begin
        if(message_index==0)message_length=failed_length;else get_word(message_length);
        for(f=0;f<message_length;f=f+1)begin get_word(v);app[f]=v;end
        write_application(message_length);
      end
      read_word(16'h8190,value);check(value[27] && {value[28],value[20:8]}==failed_length,"failed message descriptor before enable");
      read_word(16'h0010,value);check(!value[0],"recovery setup public host error");
      for(f=0;f<expected_frames;f=f+1)begin
        get_word(expected_length[f]);
        for(j=0;j<expected_length[f];j=j+1)begin get_word(v);expected_a[f][j]=v;end
        for(j=0;j<expected_length[f];j=j+1)begin get_word(v);expected_b[f][j]=v;end
      end
      frame_a=0;frame_b=0;n_a=0;n_b=0;prev_a=0;prev_b=0;monitor=1;
      fault_armed=1;u_host.wr(16'h0008,1);timeout=0;
      while((frame_a<expected_frames || frame_b<expected_frames) && timeout<1000000)begin @(negedge clk);timeout=timeout+1;end
      check(frame_a==expected_frames && frame_b==expected_frames,"recovery successors/partial prefix frame count");
      check(!fault_armed && !fault_active && faults_injected==recovery_case+1,"fault not delivered exactly once");
      // Stay on the PHY monitor through another full BAG to reject a ghost
      // retry of the failed message or an extra successor.
      repeat(125050)@(negedge clk);monitor=0;
      read_word(16'h8594,value);check(value==recovery_case+1,"public failed/bad completion counters");
      read_word(16'h8592,value);check((value[31:16]|value[15:0])==16'h003f,"failed chain/successor leaked physical blocks");
      read_word(16'h8190,value);check(!value[27],"failed message/successor left descriptor valid");
      read_word(16'h0010,value);check(!value[0],"recovery public host access error");
      recovery_frames=recovery_frames+expected_frames;recovery_bytes=recovery_bytes+65+(failed_offset!=0 ? 1464 : 0);
      read_word(16'h0108,value);check(value==total_frames+recovery_frames,"failed fragment counted as transmitted frame");
      read_word(16'h0109,value);check(value==verified_bytes+recovery_bytes,"failed fragment counted as transmitted bytes");
      check(sn_errors==0,"failed snapshot left SN ownership/protocol error");
      $display("T82 RECOVERY_DONE index=%0d failed_app=%0d offset=%0d fault=%0d frames=%0d errors=%0d",recovery_case,failed_length,failed_offset,fault_kind,expected_frames,errors);
    end
    rc=$fscanf(fd,"%h",v);check(rc!=1,"unconsumed recovery golden");$fclose(fd);
    $display("T82 RECOVERY_TOTAL cases=%0d frames_per_net=%0d bytes=%0d injected=%0d sn_errors=%0d",recovery_total,recovery_frames,recovery_bytes,faults_injected,sn_errors);
    // Public negative attempts retain ownership and an observable result.
    u_host.wr(16'h8590,0);repeat(64)@(negedge clk);read_word(16'h8590,value);
    check(value[20] && !value[18],"zero-length reserve rejection was not sticky");
    read_word(16'h0010,value);check(value[0],"reserve failure did not set ERR.ACC");u_host.wr(16'h0010,1);
    u_host.wr(16'h8590,8193);repeat(64)@(negedge clk);read_word(16'h8590,value);
    check(value[20] && !value[18],"oversize reserve changed ownership");u_host.wr(16'h0010,1);
    u_host.wr(16'h8590,32'h10020);read_word(16'h8590,value);
    check(value[20] && !value[18],"reserved high bits accepted");u_host.wr(16'h0010,1);
    u_host.wr(16'h8590,32);read_word(16'h8590,value);
    check(!value[20] && value[18] && value[13:0]==32,"valid attempt failed to clear old result");
    read_word(16'h8592,masks_word);
    u_host.wr(16'h8590,8192);repeat(64)@(negedge clk);read_word(16'h8590,value);
    check(value[20] && value[18] && value[13:0]==32,"second reserve modified active reservation");
    read_word(16'h8592,value);check(value==masks_word,"rejected second reserve acquired blocks");u_host.wr(16'h0010,1);
    u_host.wr(16'h8290,33);read_word(16'h0010,value);check(value[0],"mismatched MSG_WR accepted");
    read_word(16'h8590,value);check(value[18] && value[13:0]==32,"invalid commit consumed reservation");
    u_host.wr(16'h0010,1);u_host.wr(16'h8593,1);
    read_word(16'h8593,value);check(value==0,"cancel did not clear reservation/result");
    // Cancel releases a host reservation without publishing a descriptor/frame.
    u_host.wr(16'h8590,8192);u_host.wr(16'h8593,1);repeat(4)@(negedge clk);
    read_word(16'h8592,value);check((value[31:16]|value[15:0])==16'h003f,"public cancel leaked blocks");
    check(u_host.errors==0,"host BFM protocol errors");
    $fclose(capture_a);$fclose(capture_b);
    if(errors==0)$display("T82 TX8K GMII PASS cases=%0d frames_per_net=%0d bytes=%0d checks=%0d",cases,total_frames,verified_bytes,checks);
    else $display("T82 TX8K GMII FAIL errors=%0d checks=%0d",errors,checks);
    $finish;
  end
  initial begin #150000000;$display("T82 TX8K GMII FAIL timeout");$finish;end
endmodule
