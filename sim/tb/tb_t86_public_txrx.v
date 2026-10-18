// P11 public-interface business scenario, full dimensions, TX4/RX5.
// Original T83 remains unchanged and separately checks internal grants/jobs.
// This case preserves its three complete golden TX/RX/TFTP scenarios and all
// public packet/content/descriptor/resource verdicts. Coactivity is measured
// at public pins, not inferred as a particular internal PMEM collision.
`timescale 1 ns / 1 ps
module tb_t86_public_txrx;
  localparam [31:0] CTL_RUN=32'h0000079f;
  // 125 MHz: two configured 1 ms BAG periods; synchronization guard only.
  localparam integer TX_PHY_WAIT_CYCLES=250000;
  reg clk=0,reset=1;
  always #4 clk=~clk;
  reg [7:0] rx_a=0,rx_b=0;
  reg rdv_a=0,rdv_b=0;
  wire [7:0] tx_a,tx_b;
  wire tdv_a,tdv_b,hack;
  reg hcs=0,hwe=0;
  reg [15:0] haddr=0;
  reg [31:0] hwdata=0;
  wire [31:0] hrdata;
  AFDX_top #(.TX_MESSAGE_CHAIN_BLOCKS(4),.RX_REASM_CHAIN_BLOCKS(5)) dut (
    .clk(clk),.reset(reset),.tx_data(tx_a),.tx_valid(tdv_a),.tx_ready(),
    .rx_data(rx_a),.rx_valid(rdv_a),.rx_ready(1'b0),.rx_error(1'b0),
    .tx_data_b(tx_b),.tx_valid_b(tdv_b),.tx_ready_b(),
    .rx_data_b(rx_b),.rx_valid_b(rdv_b),.rx_ready_b(1'b1),.rx_error_b(1'b0),
    .host_cs(hcs),.host_we(hwe),.host_addr(haddr),.host_wdata(hwdata),.host_rdata(hrdata),.host_ack(hack),.host_irq(),
    .pps_in(1'b0),.pps_out(),.rtc_time_us(),.dbg_frame_event());
  integer errors=0,checks=0,case_id=-1,cycle=0;
  always @(posedge clk)cycle<=cycle+1;
  task check;
    input cond;
    input [8*160-1:0] why;
    begin checks=checks+1;if(cond!==1'b1)begin errors=errors+1;if(errors<30)$display("T86 ERROR case=%0d cycle=%0d %0s",case_id,cycle,why);end end
  endtask
  task access;
    input write;
    input [15:0] addr;
    input [31:0] data;
    output [31:0] result;
    integer g;
    begin
      @(negedge clk);hcs=1;hwe=write;haddr=addr;hwdata=data;
      @(negedge clk);g=0;
      while(hack!==1 && g<50000)begin @(negedge clk);g=g+1;end
      check(hack===1,"host ACK timeout");result=hrdata;hcs=0;hwe=0;
    end
  endtask
  task wr;
    input [15:0] addr;
    input [31:0] data;
    reg [31:0] ignored;
    begin access(1,addr,data,ignored);end
  endtask
  task rd;
    input [15:0] addr;
    output [31:0] data;
    begin access(0,addr,0,data);end
  endtask
  task wait_reg;
    input [15:0] addr;
    input [31:0] target;
    integer g;
    reg [31:0] word;
    begin
      g=0;rd(addr,word);
      while(word!==target && g<100000)begin rd(addr,word);g=g+1;end
      check(word===target,"public register failed to reach expected value");
    end
  endtask
  reg [7:0] tx_app[0:8191],rx_app[0:8191],held_app[0:63];
  reg [7:0] rx_frames_a[0:12][0:1530],rx_frames_b[0:12][0:1530];
  reg [7:0] expected_a[0:5][0:1530],expected_b[0:5][0:1530];
  reg [7:0] request_bytes[0:2][0:600];
  reg [7:0] mgmt_a[0:2][0:200],mgmt_b[0:2][0:200];
  reg [7:0] captured_a[0:1530],captured_b[0:1530];
  reg [31:0] hash_img[0:8191];
  integer rx_lengths[0:12],tx_lengths[0:5],request_lengths[0:2],mgmt_lengths[0:2];
  integer data_frames_a=0,data_frames_b=0,mgmt_frames_a=0,mgmt_frames_b=0;
  integer n_a=0,n_b=0,last_a=-1000000,last_b=-1000000,start_a=0,start_b=0;
  integer previous_data_a=-1,previous_data_b=-1,previous_mgmt_a=-1,previous_mgmt_b=-1;
  integer capture_a=0,capture_b=0,timing_a=0,timing_b=0,host_capture=0;
  reg prev_a=0,prev_b=0,monitor=0,recovery_permission=0;
  integer ai,bi,which_a,which_b;
  always @(posedge clk)if(!reset && monitor)begin
    if(tdv_a)begin
      if(!prev_a)begin check(cycle-last_a>=12,"PHY A IFG");start_a=cycle;end
      check(n_a<1531,"PHY A frame exceeds capture capacity");
      if(n_a>=1531)$fatal(1,"T86 PUBLIC TXRX FAIL A capture overflow");
      if(n_a<1531)captured_a[n_a]=tx_a;
      $fwrite(capture_a,"%02x ",tx_a);n_a=n_a+1;
    end else if(prev_a)begin
      $fwrite(capture_a,"\n");last_a=cycle;
      $fwrite(timing_a,"%0d %0d\n",start_a,cycle-1);
      check(captured_a[13]==0 || captured_a[13]==1,"unexpected outgoing VL on A");
      if(n_a<72 || !(captured_a[13]==0 || captured_a[13]==1))$fatal(1,"T86 PUBLIC TXRX FAIL A invalid frame");
      if(captured_a[13]==0)begin
        if(data_frames_a>=6)$fatal(1,"T86 PUBLIC TXRX FAIL A extra data frame");
        which_a=data_frames_a;check(which_a<6 && n_a==tx_lengths[which_a],"A data frame count/length");
        for(ai=0;ai<n_a;ai=ai+1)check(captured_a[ai]===expected_a[which_a][ai],"A complete data PHY differs from golden");
        check(previous_data_a<0 || start_a-previous_data_a>=125000,"A data1ms BAG");previous_data_a=start_a;
        data_frames_a=data_frames_a+1;
      end else begin
        if(mgmt_frames_a>=3)$fatal(1,"T86 PUBLIC TXRX FAIL A extra management frame");
        which_a=mgmt_frames_a;check(which_a<3 && n_a==mgmt_lengths[which_a],"A management frame count/length");
        for(ai=0;ai<n_a;ai=ai+1)check(captured_a[ai]===mgmt_a[which_a][ai],"A complete TFTP PHY differs from golden");
        check(previous_mgmt_a<0 || start_a-previous_mgmt_a>=125000,"A management1ms BAG");previous_mgmt_a=start_a;
        mgmt_frames_a=mgmt_frames_a+1;
      end
      n_a=0;
    end
    if(tdv_b)begin
      if(!prev_b)begin check(cycle-last_b>=12,"PHY B IFG");start_b=cycle;end
      check(n_b<1531,"PHY B frame exceeds capture capacity");
      if(n_b>=1531)$fatal(1,"T86 PUBLIC TXRX FAIL B capture overflow");
      if(n_b<1531)captured_b[n_b]=tx_b;
      $fwrite(capture_b,"%02x ",tx_b);n_b=n_b+1;
    end else if(prev_b)begin
      $fwrite(capture_b,"\n");last_b=cycle;
      $fwrite(timing_b,"%0d %0d\n",start_b,cycle-1);
      check(captured_b[13]==0 || captured_b[13]==1,"unexpected outgoing VL on B");
      if(n_b<72 || !(captured_b[13]==0 || captured_b[13]==1))$fatal(1,"T86 PUBLIC TXRX FAIL B invalid frame");
      if(captured_b[13]==0)begin
        if(data_frames_b>=6)$fatal(1,"T86 PUBLIC TXRX FAIL B extra data frame");
        which_b=data_frames_b;check(which_b<6 && n_b==tx_lengths[which_b],"B data frame count/length");
        for(bi=0;bi<n_b;bi=bi+1)check(captured_b[bi]===expected_b[which_b][bi],"B complete data PHY differs from golden");
        check(previous_data_b<0 || start_b-previous_data_b>=125000,"B data1ms BAG");previous_data_b=start_b;
        data_frames_b=data_frames_b+1;
      end else begin
        if(mgmt_frames_b>=3)$fatal(1,"T86 PUBLIC TXRX FAIL B extra management frame");
        which_b=mgmt_frames_b;check(which_b<3 && n_b==mgmt_lengths[which_b],"B management frame count/length");
        for(bi=0;bi<n_b;bi=bi+1)check(captured_b[bi]===mgmt_b[which_b][bi],"B complete TFTP PHY differs from golden");
        check(previous_mgmt_b<0 || start_b-previous_mgmt_b>=125000,"B management1ms BAG");previous_mgmt_b=start_b;
        mgmt_frames_b=mgmt_frames_b+1;
      end
      n_b=0;
    end
    prev_a=tdv_a;prev_b=tdv_b;
  end
  integer tx_host_overlap=0,rx_outstanding_bytes=0,tftp_outstanding_bytes=0;
  integer host_readbacks=0;
  reg tx_message_outstanding=0,tftp_request_active=0;
  always @(posedge clk) if(!reset && monitor) begin
    if(tx_message_outstanding && (rdv_a || rdv_b))
      rx_outstanding_bytes=rx_outstanding_bytes+1;
    if(tx_message_outstanding && tftp_request_active && rdv_a)
      tftp_outstanding_bytes=tftp_outstanding_bytes+1;
    if((tdv_a || tdv_b) && hcs && !hwe && haddr>=16'h8800 && haddr<16'ha800)
      tx_host_overlap=tx_host_overlap+1;
    if(data_frames_a==6 && data_frames_b==6)tx_message_outstanding=0;
  end
  function integer pop16;
    input [15:0] mask;
    integer bit_index;
    begin pop16=0;for(bit_index=0;bit_index<16;bit_index=bit_index+1)pop16=pop16+mask[bit_index];end
  endfunction
  task wait_public_tx_busy;
    integer guard;
    reg [31:0] status;
    begin
      guard=0;rd(16'h000c,status);
      while(!status[1] && guard<10000)begin rd(16'h000c,status);guard=guard+1;end
      check(status[1]===1'b1,"public STAT frame-builder busy was not observed");
      tx_message_outstanding=1;
    end
  endtask
  task wait_public_tx_phy;
    integer guard;
    begin
      guard=0;@(negedge clk);
      while(tdv_a!==1'b1 && tdv_b!==1'b1 && guard<TX_PHY_WAIT_CYCLES)begin
        @(negedge clk);guard=guard+1;
      end
      check(tdv_a===1'b1 || tdv_b===1'b1,"public TX PHY synchronization timeout before held reads");
      $display("T86 HOST_PHY_SYNC case=%0d cycle=%0d waited_cycles=%0d A=%b B=%b",case_id,cycle,guard,tdv_a,tdv_b);
    end
  endtask
  task check_public_rx_free;
    reg [31:0] status,masks;
    integer tx_free,rx_free;
    begin
      // STAT[7:2] is exact TX+RX physical free count; 8592[31:16]
      // exposes the TX physical free mask. Quiescent samples and public
      // membership checks together require all ten configured RX IDs free.
      rd(16'h8592,masks);rd(16'h000c,status);
      tx_free=pop16(masks[31:16]);rx_free=status[7:2]-tx_free;
      check(rx_free==10,"public physical RX pool free count did not return to ten");
      check(status[1]===1'b0,"public frame builder remains busy at final resource check");
    end
  endtask
  task inject_rx;
    input integer index;
    integer k;
    begin
      @(negedge clk);
      for(k=0;k<rx_lengths[index];k=k+1)begin
        rx_a=rx_frames_a[index][k];rx_b=rx_frames_b[index][k];rdv_a=1;rdv_b=1;@(negedge clk);
      end
      rx_a=0;rx_b=0;rdv_a=0;rdv_b=0;repeat(12)@(negedge clk);
    end
  endtask
  task tftp_exchange;
    integer m,k,g;
    begin
      for(m=0;m<3;m=m+1)begin
        @(negedge clk);
        tftp_request_active=1;
        for(k=0;k<request_lengths[m];k=k+1)begin rx_a=request_bytes[m][k];rdv_a=1;@(negedge clk);end
        rx_a=0;rdv_a=0;tftp_request_active=0;g=0;
        while((mgmt_frames_a<m+1 || mgmt_frames_b<m+1) && g<500000)begin @(negedge clk);g=g+1;end
        check(mgmt_frames_a==m+1 && mgmt_frames_b==m+1,"TFTP response timeout/extra reply");
        if(mgmt_frames_a!=m+1 || mgmt_frames_b!=m+1)begin
          $display("T86 TFTP_DIAGNOSTIC request=%0d observed_A=%0d B=%0d data_A=%0d B=%0d",m,mgmt_frames_a,mgmt_frames_b,data_frames_a,data_frames_b);
          $fatal(1,"T86 PUBLIC TXRX FAIL TFTP exchange");
        end
        repeat(20)@(negedge clk);
      end
    end
  endtask
  integer chain_ids[0:4],held_id;
  task capture_chain;
    input integer port,nbytes;
    integer k,id,want;
    reg [31:0] desc,word;
    reg [15:0] mask;
    begin
      rd(16'h8180+port,desc);want=(42+nbytes+2047)/2048;
      check(desc[31] && desc[27:24]==1 && desc[13:0]==nbytes,"public RX descriptor/count/length");
      check(desc[19:17]==want && desc[16:14]==0,"public RX chain count/reserved bits");
      mask=0;id=desc[23:20];
      for(k=0;k<want;k=k+1)begin
        check(id>=6 && id<=15 && !mask[id],"RX chain out-of-pool/cycle");
        chain_ids[k]=id;mask=mask|(16'd1<<id);rd(16'h8580+id,word);
        check(word[31:6]==0 && word[5] && word[4]==(k+1<want),"RX membership aperture");
        if(k+1==want)check(word[3:0]==0,"RX tail next not zero");id=word[3:0];
      end
    end
  endtask
  task read_payload;
    input integer nbytes,held;
    integer w,k,logical,index,id;
    reg [31:0] word;
    reg [7:0] b;
    begin
      for(w=10;w<(42+nbytes+3)/4;w=w+1)begin
        id=held ? held_id : chain_ids[w/512];rd(16'h8800+id*512+w%512,word);
        for(k=0;k<4;k=k+1)begin
          logical=w*4+k;index=logical-42;b=word[31-8*k -:8];
          if(index>=0 && index<nbytes)begin
            check(b===(held ? held_app[index] : rx_app[index]),"public RX payload differs from independent golden");
            host_readbacks=host_readbacks+1;
            $fwrite(host_capture,"%02x\n",b);
          end
        end
      end
    end
  endtask
  task consume;
    input integer port,nbytes;
    integer k;
    reg [31:0] word;
    begin
      wr(16'h8380+port,0);repeat(40)@(negedge clk);
      for(k=0;k<(42+nbytes+2047)/2048;k=k+1)begin rd(16'h8580+chain_ids[k],word);check(word==0,"released RX membership remains valid");end
    end
  endtask
  task configure;
    integer n,g;
    reg [31:0] value;
    begin
      reset=1;repeat(8)@(negedge clk);reset=0;repeat(4)@(negedge clk);
      rd(16'h000c,value);g=0;while(!value[13] && g<30000)begin rd(16'h000c,value);g=g+1;end
      check(value[13],"initialization timeout");wr(16'h0008,32'h2000);
      wr(16'h0078,32'h172d);wr(16'h007c,32'hab61);
      for(n=0;n<8192;n=n+1)wr(16'h3d80+n,hash_img[n]);wr(16'h0080,1);rd(16'h0080,value);check(value[0],"hash commit");
      for(n=5;n<=6;n=n+1)begin
        wr(16'h1d80+2*n,32'hf5000000|(n<<12)|1518);wr(16'h1d81+2*n,n);
        wr(16'h7d80+4*n,n==5 ? 32'h80040000 : 32'h80050000);
        wr(16'h7d81+4*n,5000+n-5);wr(16'h7d82+4*n,0);wr(16'h7d83+4*n,8);
      end
      wr(16'h1f80,32'hf5000000|(7<<12)|1518);wr(16'h1f81,32'h100);
      wr(16'h7d9c,32'h80060000);wr(16'h7d9d,5000);wr(16'h7d9e,0);wr(16'h7d9f,3);
      wr(16'h7dc0,32'h80010000);wr(16'h7dc1,0);wr(16'h7dc2,0);wr(16'h7dc3,3);
      wr(16'h0204,16<<16);wr(16'h0203,32'hc0a80102);wr(16'h0202,32'h56781234);
      wr(16'h0201,(1000<<8)|12);wr(16'h0480,12902);wr(16'h0200,32'h80000003|(1518<<12));
      wr(16'h0209,7<<16);wr(16'h0208,0);wr(16'h0207,5000<<16);wr(16'h0206,1000<<8);
      wr(16'h0481,6040);wr(16'h0205,32'h80000003|(700<<12));
      rd(16'h0205,value);check(value==(32'h80000003|(700<<12)),"VL1 public w0 configuration");
      rd(16'h0209,value);check(value==(7<<16),"VL1 public port assignment");
      wr(16'h0060,32'h172d2001);wr(16'h0064,32'h0a000002);wr(16'h0070,32'h143);
      rd(16'h005c,value);check(value==0,"configuration rejected");wr(16'h0008,CTL_RUN);
      rd(16'hac2a,value);check(value==1,"reassembly not publicly enabled");
    end
  endtask
  task submit_tx;
    integer j,k,id;
    reg [31:0] blocks,value,word;
    begin
      wr(16'h8590,8192);rd(16'h8590,value);check(value[18] && value[17] && value[16:14]==4 && value[13:0]==8192,"TX public reservation");
      rd(16'h8591,blocks);
      for(j=0;j<8192;j=j+4)begin
        case(j/2048)0:id=blocks[3:0];1:id=blocks[7:4];2:id=blocks[11:8];default:id=blocks[15:12];endcase
        word=0;for(k=0;k<4;k=k+1)word[31-8*k -:8]=tx_app[j+k];wr(16'h8800+id*512+(j%2048)/4,word);
      end
      wr(16'h8290,8192);
    end
  endtask
  integer fd,rc,v,total,mode,rx_count,prefix_count,recovery_count,f,j,g,r;
  reg [31:0] value;
  reg [511:0] capture_name;
  task get;
    output integer n;
    begin rc=$fscanf(fd,"%h",n);if(rc!=1)$fatal(1,"T86 PUBLIC TXRX FAIL truncated vectors");end
  endtask
  initial begin
    fd=$fopen("vec/t83_coexist/cases.hex","r");if(!fd)$fatal(1,"T86 PUBLIC TXRX FAIL missing vectors");
    $readmemh("vec/t83_coexist/hash_img.hex",hash_img);
    get(total);check(total==3,"golden case count");
    for(case_id=0;case_id<total;case_id=case_id+1)begin
      get(mode);get(rx_count);get(prefix_count);get(recovery_count);check(mode==case_id && rx_count<=13,"golden case bounds");
      for(j=0;j<8192;j=j+1)begin get(v);tx_app[j]=v;end
      for(j=0;j<8192;j=j+1)begin get(v);rx_app[j]=v;end
      for(j=0;j<64;j=j+1)begin get(v);held_app[j]=v;end
      for(f=0;f<rx_count;f=f+1)begin
        get(rx_lengths[f]);for(j=0;j<rx_lengths[f];j=j+1)begin get(v);rx_frames_a[f][j]=v;end
        for(j=0;j<rx_lengths[f];j=j+1)begin get(v);rx_frames_b[f][j]=v;end
      end
      for(f=0;f<6;f=f+1)begin
        get(tx_lengths[f]);for(j=0;j<tx_lengths[f];j=j+1)begin get(v);expected_a[f][j]=v;end
        for(j=0;j<tx_lengths[f];j=j+1)begin get(v);expected_b[f][j]=v;end
      end
      for(f=0;f<3;f=f+1)begin
        get(request_lengths[f]);for(j=0;j<request_lengths[f];j=j+1)begin get(v);request_bytes[f][j]=v;end
        get(mgmt_lengths[f]);for(j=0;j<mgmt_lengths[f];j=j+1)begin get(v);mgmt_a[f][j]=v;end
        for(j=0;j<mgmt_lengths[f];j=j+1)begin get(v);mgmt_b[f][j]=v;end
      end
      if(case_id==0 && $test$plusargs("PUBLIC_CORRUPT_EXPECTED"))
        expected_a[0][50]=expected_a[0][50]^8'h01;
      tx_host_overlap=0;rx_outstanding_bytes=0;tftp_outstanding_bytes=0;tx_message_outstanding=0;
      configure();data_frames_a=0;data_frames_b=0;mgmt_frames_a=0;mgmt_frames_b=0;n_a=0;n_b=0;prev_a=0;prev_b=0;
      previous_data_a=-1;previous_data_b=-1;previous_mgmt_a=-1;previous_mgmt_b=-1;host_readbacks=0;recovery_permission=0;
      $sformat(capture_name,"out/metrics/t86_case%0d_a.hex",case_id);capture_a=$fopen(capture_name,"w");
      $sformat(capture_name,"out/metrics/t86_case%0d_b.hex",case_id);capture_b=$fopen(capture_name,"w");
      $sformat(capture_name,"out/metrics/t86_case%0d_a_cycles.txt",case_id);timing_a=$fopen(capture_name,"w");
      $sformat(capture_name,"out/metrics/t86_case%0d_b_cycles.txt",case_id);timing_b=$fopen(capture_name,"w");
      $sformat(capture_name,"out/metrics/t86_case%0d_host.hex",case_id);host_capture=$fopen(capture_name,"w");
      check(capture_a!=0 && capture_b!=0 && timing_a!=0 && timing_b!=0 && host_capture!=0,"PHY/host capture creation");monitor=1;
      inject_rx(0);wait_reg(16'h8486,1);capture_chain(6,64);held_id=chain_ids[0];read_payload(64,1);
      for(f=1;f<prefix_count+(mode==2 ? 1 : 0);f=f+1)begin inject_rx(f);repeat(12000)@(negedge clk);end
      wait_reg(16'h8485,0);wait_reg(16'hac2d,1);submit_tx();
      wait_public_tx_busy();
      if(mode==2)begin
        wr(16'h0008,CTL_RUN & ~32'h82);wait_reg(16'hac2a,0);wait_reg(16'hac2d,0);wait_reg(16'h8485,0);wr(16'h0008,CTL_RUN);
      end
      fork
        begin
          wait_public_tx_phy();
          $display("T86 HELD_READ_WINDOW_BEGIN case=%0d cycle=%0d held_id=%0d",case_id,cycle,held_id);
          for(r=0;r<128;r=r+1)read_payload(64,1);
          $display("T86 HELD_READ_WINDOW_END case=%0d cycle=%0d host_bytes=%0d",case_id,cycle,host_readbacks);
          if(mode!=0)begin
            wait_reg(16'hac2d,0);wait_reg(16'h8485,0);
            recovery_permission=1;
          end
        end
        begin
          if(mode!=2)inject_rx(prefix_count);
          tftp_exchange();
          if(mode!=0)begin
            wait(recovery_permission); // this fork never owns the host bus.
            for(f=prefix_count+1;f<rx_count;f=f+1)begin inject_rx(f);repeat(12000)@(negedge clk);end
          end
        end
      join
      wait_reg(16'h8485,1);wait_reg(16'hac2d,0);capture_chain(5,8192);read_payload(8192,0);consume(5,8192);
      capture_chain(6,64);consume(6,64);
      g=0;while((data_frames_a!=6 || data_frames_b!=6 || mgmt_frames_a!=3 || mgmt_frames_b!=3) && g<1000000)begin @(negedge clk);g=g+1;end
      check(data_frames_a==6 && data_frames_b==6 && mgmt_frames_a==3 && mgmt_frames_b==3,"TX/management complete frame counts");
      repeat(125050)@(negedge clk);monitor=0;$fclose(capture_a);$fclose(capture_b);
      $fclose(timing_a);$fclose(timing_b);$fclose(host_capture);
      rd(16'h8592,value);check((value[31:16]|value[15:0])==16'h003f,"TX chain leak");
      rd(16'h8594,value);check(value==0,"unexpected TX error completion");
      rd(16'h8190,value);check(!value[27],"TX data descriptor remains valid");rd(16'h8187,value);check(!value[27],"TX SAP descriptor remains valid");
      for(j=6;j<16;j=j+1)begin rd(16'h8580+j,value);check(value==0,"RX public membership leaked");end
      check_public_rx_free();
      rd(16'h8485,value);check(value==0,"duplicate RX message published");rd(16'h8486,value);check(value==0,"held RX queue not released");
      rd(16'h0108,value);check(value==9,"public TX frame statistics");rd(16'h0109,value);check(value==8204,"public TX byte statistics");
      rd(16'h0010,value);check(!value[0],"public host access error");
      check(rx_outstanding_bytes>0 && tx_host_overlap>0 && tftp_outstanding_bytes>0,
            "public TX message/RX/TFTP/host coactivity coverage incomplete");
      $display("T86 CASE_DONE index=%0d errors=%0d data_frames_A=%0d B=%0d mgmt_frames_A=%0d B=%0d host_bytes=%0d tx_host_overlap=%0d rx_outstanding_bytes=%0d tftp_outstanding_bytes=%0d",case_id,errors,data_frames_a,data_frames_b,mgmt_frames_a,mgmt_frames_b,host_readbacks,tx_host_overlap,rx_outstanding_bytes,tftp_outstanding_bytes);
    end
    rc=$fscanf(fd,"%h",v);check(rc!=1,"unconsumed golden words");$fclose(fd);
    if(errors==0)$display("T86 PUBLIC TXRX PASS cases=3 data_frames_per_net=18 mgmt_frames_per_net=9 rx_app_bytes=24576 checks=%0d",checks);
    else $display("T86 PUBLIC TXRX FAIL errors=%0d checks=%0d",errors,checks);
    $finish;
  end
  initial begin #100000000;$fatal(1,"T86 PUBLIC TXRX FAIL global timeout");end
endmodule
