`timescale 1 ns / 1 ps
// Opt-in production top GMII test; all descriptor/chain/payload verdicts use
// the public host bus. Internal probes only check ownership and job lifetimes.
module tb_rx8k_gmii;
  localparam integer MAX_WORDS=131072, MAX_APP=524288, MAX_CASES=64, MAX_FRAMES=16;
  localparam [31:0] CTL_RUN=32'h00000086, CTL_NO_REASM=32'h00000006;
  reg clk=0, reset=1;
  always #4 clk=~clk;
  reg [7:0] rx_data=0;
  reg rx_valid=0;
  wire [7:0] tx_data, tx_data_b;
  wire tx_valid, tx_valid_b, host_ack;
  wire [31:0] host_rdata;
  reg host_cs=0, host_we=0;
  reg [15:0] host_addr=0;
  reg [31:0] host_wdata=0;
  AFDX_top #(.IF_MODE(2), .FCS_MODE(2), .RX_REASM_CHAIN_BLOCKS(5)) dut (
    .clk(clk), .reset(reset), .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(),
    .rx_data(rx_data), .rx_valid(rx_valid), .rx_ready(1'b0), .rx_error(1'b0),
    .tx_data_b(tx_data_b), .tx_valid_b(tx_valid_b), .tx_ready_b(),
    .rx_data_b(8'd0), .rx_valid_b(1'b0), .rx_ready_b(1'b0), .rx_error_b(1'b0),
    .host_cs(host_cs), .host_we(host_we), .host_addr(host_addr),
    .host_wdata(host_wdata), .host_rdata(host_rdata), .host_ack(host_ack),
    .host_irq(), .pps_in(1'b0), .pps_out(), .rtc_time_us(), .dbg_frame_event());

  reg [31:0] vec[0:MAX_WORDS-1], header[0:4], hash_img[0:8191], hash_meta[0:3];
  reg [7:0] expected[0:MAX_APP-1];
  integer kinds[0:MAX_CASES-1], lens[0:MAX_CASES-1], salts[0:MAX_CASES-1];
  integer nframes[0:MAX_CASES-1], ports[0:MAX_CASES-1], app_base[0:MAX_CASES-1];
  integer bg_base[0:MAX_CASES-1], bg_len[0:MAX_CASES-1], bg_count[0:MAX_CASES-1];
  integer frame_pos[0:MAX_CASES*MAX_FRAMES-1];
  integer chain_ids[0:4], saved_ids[0:4];
  reg [15:0] chain_mask, saved_mask;
  integer errors=0, checks=0, current_case=-1, case_count=0;
  integer case_start=0, case_limit=0, executed_cases=0;
  integer total_bytes=0, copy_jobs=0, copy_finishes=0, copy_aborts=0;
  integer check_jobs=0, check_finishes=0, check_aborts=0;
  reg copy_active=0, check_active=0;
  reg [3:0] copy_source;
  reg [15:0] check_mask;
  integer mi;

  task bad;
    input [8*160-1:0] why;
    begin
      if(errors<30) $display("RX8K error case=%0d t=%0t: %0s",current_case,$time,why);
      errors=errors+1;
    end
  endtask
  task chk;
    input cond;
    input [8*160-1:0] why;
    begin checks=checks+1; if(cond !== 1'b1) bad(why); end
  endtask

  // Hold requests until ACK, including PMEM arbitration waits. No direct RAM
  // peek or backdoor write is used. Drive/sample on falling GMII clock edges.
  task host_access;
    input wr;
    input [15:0] address;
    input [31:0] data;
    output [31:0] result;
    integer g;
    begin
      @(negedge clk);
      host_cs=1; host_we=wr; host_addr=address; host_wdata=data;
      @(negedge clk); g=0;
      while(host_ack !== 1'b1 && g<50000) begin @(negedge clk); g=g+1; end
      if(host_ack !== 1'b1) begin
        $display("RX8K host timeout addr=%04h write=%0d",address,wr);
        $fatal(1,"RX8K GMII FAIL host ACK timeout");
      end
      result=host_rdata; host_cs=0; host_we=0;
    end
  endtask
  task rd;
    input [15:0] address;
    output [31:0] data;
    begin host_access(1'b0,address,32'd0,data); end
  endtask
  task wr;
    input [15:0] address;
    input [31:0] data;
    reg [31:0] ignored;
    begin host_access(1'b1,address,data,ignored); end
  endtask

  function integer pop16;
    input [15:0] mask;
    integer k;
    begin pop16=0; for(k=0;k<16;k=k+1) pop16=pop16+mask[k]; end
  endfunction

  always @(posedge clk) begin
    // External reset is asserted before the first clock initializes the
    // synchronizer and downstream grant registers.
    if(reset || dut.rst_sync) begin
      if(copy_active) copy_aborts<=copy_aborts+1;
      if(check_active) check_aborts<=check_aborts+1;
      copy_active<=0; check_active<=0;
    end else begin
      if(dut.chain_copy_valid && dut.chain_copy_ready) begin
        chk(!copy_active,"scatter accepts at most one job at a time");
        copy_jobs<=copy_jobs+1; copy_active<=1; copy_source<=dut.chain_copy_src;
        chk(dut.chain_copy_src>=6,"scatter source is an RX physical ID");
        for(mi=0;mi<5;mi=mi+1)
          if(mi<dut.reasm_copy_dst_count)
            chk(dut.reasm_copy_dst_blocks[4*mi+:4] != dut.chain_copy_src,
                "scatter source never aliases a destination");
      end
      if(dut.chain_copy_done) begin
        chk(copy_active,"scatter completion belongs to an accepted job");
        copy_finishes<=copy_finishes+1; copy_active<=0;
      end
      if(dut.chain_check_valid && dut.reasm_check_ready) begin
        chk(!check_active,"checker accepts at most one job at a time");
        check_jobs<=check_jobs+1; check_active<=1; check_mask=0;
        for(mi=0;mi<5;mi=mi+1)
          if(mi<dut.reasm_check_block_count)
            check_mask=check_mask|(16'h0001<<dut.reasm_check_blocks[4*mi+:4]);
      end
      if(dut.reasm_check_done) begin
        chk(check_active,"checksum completion belongs to an accepted job");
        check_finishes<=check_finishes+1; check_active<=0;
      end
      if(dut.reasm_free_valid) begin
        chk(!(copy_active && dut.reasm_free_id==copy_source),
            "accepted copy source survives until completion or reset");
        chk(!(check_active && check_mask[dut.reasm_free_id]),
            "accepted checker destinations survive until completion or reset");
      end
      chk(({3'd0,dut.host_pmem_rd}+{3'd0,dut.fb_rd_en_a}+{3'd0,dut.sap_pm_gnt}+
           {3'd0,dut.copy_rd_grant}+{3'd0,dut.check_rd_grant})<=1,
          "PMEM read grants are mutually exclusive");
    end
  end

  task wait_reg;
    input [15:0] address;
    input [31:0] target;
    integer g;
    reg [31:0] value;
    begin
      g=0; value=32'hffffffff;
      while(value !== target && g<100000) begin rd(address,value); g=g+1; end
      if(value !== target) begin
        $display("RX8K wait timeout addr=%04h want=%08h got=%08h",address,target,value);
        $fatal(1,"RX8K GMII FAIL bounded register wait");
      end
    end
  endtask

  task check_empty;
    integer k;
    reg [31:0] value;
    begin
      wait_reg(16'h8485,0); wait_reg(16'h8486,0); wait_reg(16'hAC2D,0);
      repeat(40) @(negedge clk);
      chk(dut.rx_free_map===16'hFFC0,"all ten RX blocks returned");
      for(k=0;k<16;k=k+1) begin
        rd(16'h8580+k,value); chk(value===0,"public aperture empty after release/reset");
      end
    end
  endtask

  task configure;
    input do_reset;
    integer n,g;
    reg [31:0] value;
    begin
      if(do_reset) begin reset=1; repeat(8) @(negedge clk); reset=0; end
      repeat(4) @(negedge clk);
      g=0; rd(16'h000C,value);
      while(value[13] !== 1'b1 && g<30000) begin rd(16'h000C,value); g=g+1; end
      if(value[13] !== 1'b1) $fatal(1,"RX8K GMII FAIL init timeout");
      wr(16'h0008,32'h00002000);
      wr(16'h0078,hash_meta[0]); wr(16'h007C,hash_meta[1]);
      for(n=0;n<8192;n=n+1) wr(16'h3D80+n,hash_img[n]);
      wr(16'h0080,1); rd(16'h0080,value); chk(value[0]===1'b1,"hash image committed");
      for(n=5;n<=6;n=n+1) begin
        wr(16'h1D80+(n<<1),32'hF5000000|(n<<12)|32'd1518);
        wr(16'h1D81+(n<<1),n);
        wr(16'h7D80+4*n,(n==5)?32'h80040000:32'h80050000);
        wr(16'h7D81+4*n,5000+n-5); wr(16'h7D82+4*n,0); wr(16'h7D83+4*n,8);
      end
      wr(16'h0060,32'h172D2001); wr(16'h0064,32'h0A000002);
      // T65 checksum policy plus FIRST_ANY, so post-reset serialized vectors
      // may begin with an arbitrary nonzero SN. IC remains enabled.
      wr(16'h0070,32'h00000143);
      rd(16'h005C,value); chk(value===0,"port/VL configuration accepted");
      wr(16'h0008,CTL_RUN); repeat(20) @(negedge clk);
      rd(16'hAC2A,value); chk(value===1,"reassembly enabled through host CTL");
      check_empty;
    end
  endtask

  task send_frame;
    input integer ci,fi;
    integer p,n,k;
    reg [31:0] w;
    begin
      p=frame_pos[ci*MAX_FRAMES+fi]; n=vec[p]+8;
      chk(n>=72 && n<=1526,"serialized GMII frame fits production MAC bounds");
      @(negedge clk);
      for(k=0;k<n;k=k+1) begin
        w=vec[p+2+k/4]; rx_data=w[31-8*(k%4)-:8]; rx_valid=1;
        @(negedge clk);
      end
      rx_valid=0; rx_data=0; repeat(12) @(negedge clk);
    end
  endtask
  task pace;
    input integer ci,fi;
    integer n;
    begin n=vec[frame_pos[ci*MAX_FRAMES+fi]+1]; repeat(n) @(negedge clk); end
  endtask
  task send_range;
    input integer ci,first,last;
    integer fi;
    begin
      for(fi=first;fi<=last;fi=fi+1) begin
        send_frame(ci,fi); if(fi<last) pace(ci,fi);
      end
    end
  endtask

  task capture_chain;
    input integer port,nbytes,count;
    output [31:0] descriptor;
    integer k,id,want_count,gaps;
    reg [31:0] word;
    begin
      rd(16'h8180+port,descriptor);
      chk(descriptor[31]===1'b1,"public PORT_DESC valid");
      chk(descriptor[27:24]===count[3:0],"public descriptor message count");
      chk(descriptor[13:0]===nbytes[13:0],"public descriptor full 14-bit length");
      chk(descriptor[16:14]===0,"public descriptor reserved bits zero");
      want_count=(42+nbytes+2047)/2048;
      chk(descriptor[19:17]===want_count[2:0],"chain count trims at logical header+app boundary");
      chain_mask=0; id=descriptor[23:20];
      for(k=0;k<5;k=k+1) chain_ids[k]=0;
      if(descriptor[31]===1'b1 && descriptor[19:17]===want_count[2:0]) begin
        for(k=0;k<want_count;k=k+1) begin
          chk(id>=6 && id<=15,"aperture points only to RX physical IDs 6..15");
          chk(!chain_mask[id],"aperture traversal has no repeated physical ID");
          chain_ids[k]=id; chain_mask=chain_mask|(16'h0001<<id);
          rd(16'h8580+id,word);
          chk(word[31:6]===0 && word[5]===1'b1,"public membership valid with zero reserved bits");
          chk(word[4]===(k+1<want_count),"public has_next agrees with descriptor count");
          if(k+1==want_count) chk(word[3:0]===0,"public chain tail next is zero");
          id=word[3:0];
        end
        if(kinds[current_case]==4 && want_count>1) begin
          gaps=0;
          for(k=0;k<want_count-1;k=k+1) if(chain_ids[k+1]!=chain_ids[k]+1) gaps=gaps+1;
          chk(gaps>0,"pool recovery uses a non-contiguous physical destination chain");
          chk((chain_mask&saved_mask)===0,"new chain never aliases retained queue heads");
        end
      end else $fatal(1,"RX8K GMII FAIL descriptor prevents safe chain traversal");
    end
  endtask

  task verify_payload;
    input integer nbytes,base;
    integer logical_word,logical_byte,lane,app_i,id;
    reg [31:0] word;
    reg [7:0] got;
    begin
      for(logical_word=10;logical_word<(42+nbytes+3)/4;logical_word=logical_word+1) begin
        id=chain_ids[logical_word/512];
        rd(16'h8800+id*512+(logical_word%512),word);
        for(lane=0;lane<4;lane=lane+1) begin
          logical_byte=logical_word*4+lane; app_i=logical_byte-42;
          if(app_i>=0 && app_i<nbytes) begin
            got=word[31-8*lane-:8];
            if(got !== expected[base+app_i] && errors<30)
              $display("RX8K byte mismatch case=%0d app=%0d blk=%0d got=%02h want=%02h",
                       current_case,app_i,id,got,expected[base+app_i]);
            chk(got===expected[base+app_i],"public PMEM application byte equals independent golden");
            total_bytes=total_bytes+1;
          end
        end
      end
    end
  endtask

  task consume;
    input integer port;
    integer id;
    reg [31:0] word;
    reg [15:0] returned;
    begin
      returned=chain_mask;
      wr(16'h8380+port,0); repeat(20) @(negedge clk);
      for(id=0;id<16;id=id+1) if(returned[id]) begin
        rd(16'h8580+id,word); chk(word===0,"MSG_RD clears every returned chain membership");
      end
    end
  endtask

  task run_positive;
    input integer ci,first;
    integer g;
    reg [31:0] word,desc;
    begin
      // Any single fragment, including tail-first, cannot publish the message.
      send_frame(ci,first); pace(ci,first);
      rd(16'h8480+ports[ci],word); chk(word===0,"first arrival alone does not deliver");
      wait_reg(16'hAC2D,1);
      send_range(ci,first+1,nframes[ci]-1);
      wait_reg(16'h8480+ports[ci],1); wait_reg(16'hAC2D,0);
      capture_chain(ports[ci],lens[ci],1,desc);
      chk(desc[30]===1 && desc[29:28]===0,"new sampling descriptor fresh with no overflow/pin");
      verify_payload(lens[ci],app_base[ci]);
      consume(ports[ci]);
    end
  endtask


  task no_delivery;
    reg [31:0] word;
    begin
      rd(16'h8485,word); chk(word===0,"rejected/cancelled datagram never reaches host port");
      rd(16'h8185,word); chk(word[31]===0,"no valid descriptor after rejection/cancellation");
      for(integer j=0;j<16;j=j+1) begin
        rd(16'h8580+j,word); chk(word===0,"cancelled context is absent from public metadata");
      end
    end
  endtask

  task run_reject;
    input integer ci;
    reg [31:0] drops,word;
    begin
      rd(16'hAC2C,drops);
      send_range(ci,0,nframes[ci]-1);
      wait_reg(16'hAC2C,drops+1); wait_reg(16'hAC2D,0);
      rd(16'hAC2F,word); chk(word==((kinds[ci]==3)?5:9),"public reason distinguishes overlap/checksum rejection");
      no_delivery; check_empty;
    end
  endtask

  task run_pool;
    input integer ci;
    integer j,k;
    reg [31:0] desc,word,drops;
    reg [15:0] background_mask;
    begin
      chk(bg_count[ci]===5 && bg_len[ci]===64,"pool fixture has five independent queue messages");
      background_mask=0;
      for(j=0;j<5;j=j+1) begin
        send_frame(ci,j); pace(ci,j); wait_reg(16'h8486,j+1);
      end
      chk(pop16(dut.rx_free_map)===5,"five queue heads retain five RX blocks");
      rd(16'hAC2C,drops); send_frame(ci,5); pace(ci,5);
      wait_reg(16'hAC2C,drops+1); wait_reg(16'hAC2D,0);
      rd(16'hAC2F,word); chk(word===3,"atomic allocation failure reports pool capacity");
      rd(16'h8485,word); chk(word===0,"pool exhaustion emits no application message");
      chk(pop16(dut.rx_free_map)===5,"failed allocation returns source without consuming destinations");
      // Returning two low IDs leaves three unrelated heads live and forces a
      // non-contiguous destination chain around those retained physical IDs.
      for(j=0;j<2;j=j+1) begin
        capture_chain(6,64,5-j,desc); background_mask=background_mask|chain_mask;
        verify_payload(64,bg_base[ci]+j*64); consume(6);
      end
      saved_mask=0;
      for(k=6;k<16;k=k+1) begin
        rd(16'h8580+k,word); if(word[5]) saved_mask=saved_mask|(16'h0001<<k);
      end
      chk(pop16(saved_mask)===3,"three queue singleton memberships remain live");
      run_positive(ci,6); // Its final consume leaves the three queue heads.
      for(j=2;j<5;j=j+1) begin
        capture_chain(6,64,5-j,desc);
        chk((background_mask&chain_mask)===0,"retained queue heads remain distinct");
        background_mask=background_mask|chain_mask;
        verify_payload(64,bg_base[ci]+j*64); consume(6);
      end
      check_empty;
    end
  endtask

  task await_job;
    input integer phase;
    integer guard;
    begin
      guard=0;
      while(((phase==0 && !copy_active)||(phase==1 && !check_active)) && guard<30000) begin
        @(negedge clk); guard=guard+1;
      end
      if(guard>=30000) $fatal(1,"RX8K GMII FAIL lifecycle trigger never accepted a job");
      chk((phase==0)?copy_active:check_active,"lifecycle trigger targets an accepted PMEM job");
    end
  endtask

  task run_lifecycle;
    input integer ci;
    integer prefix,phase,before_copy,before_check,before_abort;
    begin
      prefix=(kinds[ci]==7 || kinds[ci]==9)?6:1;
      phase=(prefix==6)?1:0;
      before_copy=copy_finishes; before_check=check_finishes;
      before_abort=copy_aborts+check_aborts;
      if(kinds[ci]==5) begin
        send_frame(ci,0); pace(ci,0); wait_reg(16'hAC2D,1);
        chk(!copy_active && !check_active,"incomplete context is idle before disable");
        wr(16'h0008,CTL_NO_REASM);
      end else begin
        if(prefix>1) begin send_range(ci,0,prefix-2); pace(ci,prefix-2); end
        fork
          begin send_frame(ci,prefix-1); end
          begin
            await_job(phase);
            if(kinds[ci]==8 || kinds[ci]==9) begin
              reset=1; repeat(8) @(negedge clk); reset=0;
            end else wr(16'h0008,CTL_NO_REASM);
          end
        join
      end
      if(kinds[ci]==8 || kinds[ci]==9) begin
        chk(copy_aborts+check_aborts===before_abort+1,"reset explicitly aborts exactly the accepted job");
        configure(1'b1);
      end else begin
        wait_reg(16'hAC2A,0); wait_reg(16'hAC2D,0);
        if(kinds[ci]==6) chk(copy_finishes>before_copy,"disable waits for accepted copy completion");
        if(kinds[ci]==7) chk(check_finishes>before_check,"disable waits for accepted checker completion");
        chk(copy_aborts+check_aborts===before_abort,"disable completes jobs without a reset abort");
        check_empty; wr(16'h0008,CTL_RUN); repeat(20) @(negedge clk);
        wait_reg(16'hAC2A,1);
      end
      no_delivery; check_empty;
      run_positive(ci,prefix); check_empty;
    end
  endtask

  integer fd,scan_ok,ci,fi,pos,k,nwords;
  initial begin
    fd=$fopen("vectors/rx8k_gmii.hex","r");
    if(fd==0) $fatal(1,"RX8K GMII FAIL missing frozen vectors");
    for(k=0;k<5;k=k+1) begin
      scan_ok=$fscanf(fd,"%h",header[k]);
      if(scan_ok!=1) $fatal(1,"RX8K GMII FAIL vector header truncated");
    end
    $fclose(fd);
    if(header[0]!==32'h5258384B || header[1]!==1 || header[2]<1 ||
       header[2]>MAX_CASES || header[3]>MAX_WORDS || header[4]>MAX_APP)
      $fatal(1,"RX8K GMII FAIL vector schema/bounds");
    $readmemh("vectors/rx8k_gmii.hex",vec,0,header[3]-1);
    $readmemh("vectors/expected_app.hex",expected,0,header[4]-1);
    $readmemh("vectors/hash_img.hex",hash_img);
    $readmemh("vectors/hash_meta.hex",hash_meta);
    chk(hash_meta[2]===4096 && hash_meta[3]===2048,"full production hash dimensions");
    case_count=header[2]; pos=5;
    for(ci=0;ci<case_count;ci=ci+1) begin
      kinds[ci]=vec[pos]; lens[ci]=vec[pos+1]; salts[ci]=vec[pos+2]; nframes[ci]=vec[pos+3];
      ports[ci]=vec[pos+4]; app_base[ci]=vec[pos+7]; bg_base[ci]=vec[pos+8];
      bg_len[ci]=vec[pos+9]; bg_count[ci]=vec[pos+10]; pos=pos+11;
      if(nframes[ci]<1 || nframes[ci]>MAX_FRAMES || lens[ci]<1 || lens[ci]>8192 ||
         app_base[ci]+lens[ci]>header[4]) $fatal(1,"RX8K GMII FAIL case bounds");
      for(fi=0;fi<nframes[ci];fi=fi+1) begin
        frame_pos[ci*MAX_FRAMES+fi]=pos; nwords=(vec[pos]+11)/4; pos=pos+2+nwords;
        if(pos>header[3]) $fatal(1,"RX8K GMII FAIL frame bounds");
      end
    end
    chk(pos===header[3],"all serialized words consumed");
    if(!$value$plusargs("RX8K_CASE_LIMIT=%d",case_limit)) case_limit=case_count;
    if(!$value$plusargs("RX8K_CASE_START=%d",case_start)) case_start=0;
    if(case_start<0 || case_limit<=case_start || case_limit>case_count) $fatal(1,"RX8K GMII FAIL invalid case limit");
    configure(1'b1);
    for(ci=case_start;ci<case_limit;ci=ci+1) begin
      current_case=ci;
      $display("RX8K CASE index=%0d kind=%0d length=%0d frames=%0d",ci,kinds[ci],lens[ci],nframes[ci]);
      check_empty;
      case(kinds[ci])
        0: run_positive(ci,0);
        1,2,3: run_reject(ci);
        4: run_pool(ci);
        5,6,7,8,9: run_lifecycle(ci);
        10: begin
          wr(16'h0070,32'h00000141); run_positive(ci,0);
          wr(16'h0070,32'h00000143);
        end
        default: $fatal(1,"RX8K GMII FAIL unimplemented vector kind");
      endcase
      check_empty; executed_cases=executed_cases+1;
      $display("RX8K CASE_DONE index=%0d errors=%0d t=%0t",ci,errors,$time);
    end
    repeat(20) @(negedge clk);
    chk(copy_jobs==copy_finishes+copy_aborts && !copy_active,"copy jobs finish or explicitly reset");
    chk(check_jobs==check_finishes+check_aborts && !check_active,"checker jobs finish or explicitly reset");
    if(errors==0) $display("RX8K GMII PASS cases=%0d checks=%0d bytes=%0d copy=%0d/%0d check=%0d/%0d",
                           executed_cases,checks,total_bytes,copy_finishes,copy_jobs,check_finishes,check_jobs);
    else $display("RX8K GMII FAIL errors=%0d checks=%0d",errors,checks);
    $finish;
  end
  initial begin #200000000; $fatal(1,"RX8K GMII FAIL global timeout"); end
endmodule
