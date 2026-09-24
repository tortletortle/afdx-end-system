// T12f0/f1: REAL host window + physical hash RAM + A/B MAC ingress -> lookup.
// Only ingress/lookup is connected; FLT, IC, RM and port delivery are NOT.
`timescale 1 ns / 1 ps
module tb_t12f_core #(parameter integer IF_MODE=0);
  reg clk=0, reset=1;
  always #4 clk=~clk;
  reg host_cs=0,host_we=0,rx_valid=0,rx_valid_b=0,rx_ready=0,rx_ready_b=0;
  reg [15:0] host_addr=0;
  reg [31:0] host_wdata=0;
  reg [7:0] rx_data=0,rx_data_b=0;
  wire [31:0] host_rdata;
  wire host_ack;
  AFDX_top #(.IF_MODE(IF_MODE),.FCS_MODE(2)) dut (
    .clk(clk),.reset(reset),.tx_data(),.tx_valid(),.tx_ready(),
    .rx_data(rx_data),.rx_valid(rx_valid),.rx_ready(rx_ready),
    .tx_data_b(),.tx_valid_b(),.tx_ready_b(),
    .rx_data_b(rx_data_b),.rx_valid_b(rx_valid_b),.rx_ready_b(rx_ready_b),
    .host_cs(host_cs),.host_we(host_we),.host_addr(host_addr),
    .host_wdata(host_wdata),.host_rdata(host_rdata),.host_ack(host_ack),
    .host_irq(),.pps_in(1'b0),.pps_out(),.rtc_time_us(),.dbg_frame_event());
  reg [31:0] image [0:8191];
  reg [31:0] meta [0:3];
  reg [31:0] frames [0:92];
  integer errors=0,lookups=0,read_words=0,write_words=0,crc_bad=0,pops=0;
  integer i,j,waitc,hot_slot=-1;
  reg [31:0] rd;
  reg want_active=0,want_hit=0,want_net=0;
  reg [15:0] want_key=0;
  reg [11:0] want_idx=0;
  reg [3:0] seen_way=0;
  task bad;
    input [8*106-1:0] reason;
    begin
      if(errors<10) $display("  [err] T12f%0d out=%0d wr=%0d rd=%0d: %0s",
                            IF_MODE,lookups,write_words,read_words,reason);
      errors=errors+1;
    end
  endtask
  always @(posedge clk) if(!reset) begin
    if(dut.rx_ovf_a || dut.rx_ovf_b) bad("RX PMEM/descriptor FIFO overflow");
    if(dut.rx_crc_err_b) crc_bad=crc_bad+1;
    if(dut.rx_desc_pop_a || dut.rx_desc_pop_b) begin
      pops=pops+1;
      if(dut.rx_desc_pop_a && dut.rx_desc_pop_b)
        bad("A/B descriptor popped twice on single lookup port");
    end
    if(dut.lookup_out_vld) begin
      lookups=lookups+1;
      if(!want_active) bad("lookup output not from an accepted good frame");
      if(dut.lookup_out_hit!==want_hit || dut.lookup_out_vl!==want_idx ||
         dut.lookup_out_desc[123:108]!==want_key ||
         dut.lookup_out_desc[99]!==want_net ||
         dut.lookup_out_desc[158:148]!==11'd79)
        bad("real RX frame hash result/metadata differs from independent oracle");
      want_active=0;
    end
  end
  task host_write;
    input [15:0] addr;
    input [31:0] data;
    begin
      @(negedge clk);host_cs=1;host_we=1;host_addr=addr;host_wdata=data;
      @(negedge clk);
      if(host_ack!==1'b1)bad("host write missing fixed-cycle ACK");
      host_cs=0;host_we=0;
    end
  endtask
  task host_read;
    input [15:0] addr;
    output [31:0] data;
    begin
      @(negedge clk);host_cs=1;host_we=0;host_addr=addr;
      @(negedge clk);
      if(host_ack!==1'b1)bad("host read missing fixed-cycle ACK");
      data=host_rdata;host_cs=0;
    end
  endtask
  task check_acc;
    input should_set;
    begin
      host_read(16'h0010,rd);
      if(rd[0]!==should_set) bad("ERR.ACC wrong after legal/illegal host operation");
      if(should_set) host_write(16'h0010,32'h1);
    end
  endtask
  function [7:0] frame_byte;
    input integer base, off;
    reg [31:0] word;
    begin
      word=frames[base+3+(off>>2)];
      case(off&3)
        0: frame_byte=word[31:24];
        1: frame_byte=word[23:16];
        2: frame_byte=word[15:8];
        default: frame_byte=word[7:0];
      endcase
    end
  endfunction
  task send_case;
    input integer case_no;
    integer base,c,b,n,prev_lookup,prev_crc;
    reg [31:0] word;
    begin
      base=1;
      for(c=0;c<case_no;c=c+1) base=base+3+((frames[base]+3)/4);
      n=frames[base]; word=frames[base+1];
      if(n!=79 || frames[base+2]>1 || word>2)
        bad("generated ingress vector layout corrupt");
      prev_lookup=lookups;prev_crc=crc_bad;
      want_hit=word[0];want_net=frames[base+2][0];
      want_key={frame_byte(base,4),frame_byte(base,5)};
      want_idx=want_hit ? 12'h100 : 12'd0;
      want_active=(word!=2);
      for(b=0;b<n;b=b+1) begin
        @(negedge clk);
        if(want_net) begin rx_ready_b=1;rx_valid_b=1;rx_data_b=frame_byte(base,b);end
        else begin rx_ready=1;rx_valid=1;rx_data=frame_byte(base,b);end
        if(IF_MODE==0) begin
          @(negedge clk);rx_valid=0;rx_valid_b=0;
          repeat(8) @(negedge clk);
        end
      end
      @(negedge clk);rx_ready=0;rx_valid=0;rx_ready_b=0;rx_valid_b=0;
      repeat(14) @(negedge clk);
      if(word==2) begin
        if(lookups!=prev_lookup || crc_bad!=prev_crc+1)
          bad("bad-FCS frame entered lookup or CRC rejection was not observed");
      end else begin
        if(lookups!=prev_lookup+1 || want_active)
          bad("valid frame did not produce exactly one stable lookup result");
      end
      if(dut.rx_free_map!==16'hFFC0)
        bad("RX block leaked after lookup result/CRC rejection");
    end
  endtask

  initial begin
    $readmemh("vec/t12_top.img.hex",image);
    $readmemh("vec/t12_top.meta.hex",meta);
    $readmemh("vec/t12_top_frames.hex",frames);
    if(meta[2]!==4096 || meta[3]!==2048 || frames[0]!==4)
      bad("offline top image/frame metadata invalid");
    for(i=0;i<8192;i=i+1) if(image[i][28]) begin
      seen_way[(i/4096)*2+(i&1)]=1;
      if(image[i][27:12]==16'h0100) hot_slot=i;
    end
    if(seen_way!==4'b1111 || hot_slot<0 || image[hot_slot][11:0]!=12'h100)
      bad("real frame key/index missing from offline four-way image");
    repeat(7) @(negedge clk);reset=0;
    waitc=0;
    while(dut.init_done!==1 && waitc<26000) begin @(negedge clk);waitc=waitc+1;end
    if(waitc>=26000) bad("INIT_DONE timeout");
    host_read(16'h0080,rd);if(rd!==0) bad("image flags not reset");
    host_write(16'h0008,32'h051E); // RX_EN must be masked before commit
    host_read(16'h0008,rd);if(rd[1]!==0)bad("RX_EN opened without hash image");
    check_acc(1'b1);
    host_write(16'h0008,32'h2000);
    host_write(16'h0080,32'h1); // commit without seeds/entry
    check_acc(1'b1);
    host_write(16'h0078,32'h0001_172D); // upper reserved bits reject
    check_acc(1'b1);
    host_read(16'h0078,rd);if(rd!==0)bad("invalid seed polluted register");
    host_write(16'h0078,meta[0]);
    host_write(16'h007C,meta[1]);
    host_read(16'h0078,rd);if(rd!==meta[0])bad("seed0 readback mismatch");
    host_read(16'h007C,rd);if(rd!==meta[1])bad("seed1 readback mismatch");
    host_write(16'h0080,32'h1); // still no valid entry
    check_acc(1'b1);
    host_write(16'h3D80,32'h8000_0000); // malformed padding
    check_acc(1'b1);
    host_read(16'h3D80,rd);if(rd!==0)bad("invalid image word was stored");
    host_write(16'h5D80,32'h1000_0100); // reserved high half
    check_acc(1'b1);
    host_read(16'h5D80,rd);
    if(rd!==32'hDEAD_BEEF)bad("reserved high-half aliased live hash bank");
    check_acc(1'b1);
    // One word on EVERY rising edge; ACK then fully pipelined synchronous
    // readback through the physical bank mux (not a TB backdoor peek).
    @(negedge clk);host_cs=1;host_we=1;
    for(i=0;i<8192;i=i+1) begin
      host_addr=16'h3D80+i;host_wdata=image[i];
      @(negedge clk);
      if(host_ack!==1'b1)bad("pipelined hash image write ACK gap");
      write_words=write_words+1;
    end
    host_cs=0;host_we=0;
    check_acc(1'b0);
    @(negedge clk);host_cs=1;host_we=0;
    for(i=0;i<8192;i=i+1) begin
      host_addr=16'h3D80+i;
      @(negedge clk);
      if(host_ack!==1'b1 || host_rdata!==image[i])
        bad("pipelined hash image readback mismatch/shift");
      read_words=read_words+1;
    end
    host_cs=0;
    host_read(16'h0080,rd);
    if(rd[3:0]!==4'hE)bad("image flags wrong before commit");
    host_write(16'h0080,32'h1);
    host_read(16'h0080,rd);
    if(rd[3:0]!==4'hF)bad("image commit not accepted");
    host_write(16'h0008,32'h051E);
    host_read(16'h0008,rd);if(rd[1]!==1)bad("valid image cannot enable RX");
    host_read(16'h3D80,rd); // RX running: reading config is forbidden
    if(rd!==32'hDEAD_BEEF)bad("hash read during RUN leaked stale RAM data");
    check_acc(1'b1);
    host_write(16'h3D80,32'hDEAD_BEEF); // no config writes during RUN
    check_acc(1'b1);
    host_write(16'h0008,32'h2000);
    host_read(16'h3D80,rd);if(rd!==image[0])bad("RUN write modified table");
    host_read(16'h0080,rd);if(rd[0]!==1)bad("denied RUN writes invalidated image");
    host_write(16'h0008,32'h051E);
    send_case(0);send_case(1);send_case(2);send_case(3);
    if(lookups!=3 || pops!=3 || crc_bad!=1)
      bad("A/B hit, unknown miss, bad CRC histogram wrong");
    // Any seed rewrite invalidates an armed image, and a renewed commit without
    // writing at least one candidate word is rejected (no stale-seed service).
    host_write(16'h0008,32'h2000);
    host_write(16'h0078,32'h0000_B564);
    host_read(16'h0080,rd);if(rd[3:0]!==4'h6)bad("seed update left old image armed");
    host_write(16'h0080,32'h1);check_acc(1'b1);
    host_write(16'h0008,32'h051E);
    host_read(16'h0008,rd);if(rd[1]!==0)bad("RX_EN opened after seed invalidation");
    check_acc(1'b1);
    host_write(16'h0008,32'h2000);
    host_write(16'h0078,meta[0]);
    host_write(16'h3D80+hot_slot[15:0],image[hot_slot]);
    host_write(16'h0080,32'h1);
    host_write(16'h0008,32'h051E);
    send_case(0);
    if(lookups!=4 || pops!=4)bad("restored seed did not resume one-match path");
    @(negedge clk);reset=1;
    repeat(6) @(negedge clk);reset=0;
    waitc=0;
    while(dut.init_done!==1 && waitc<26000) begin @(negedge clk);waitc=waitc+1;end
    if(waitc>=26000)bad("repeat INIT_DONE timeout");
    host_read(16'h0080,rd);if(rd!==0)bad("image ready flags leaked through reset");
    host_read(16'h0078,rd);if(rd!==0)bad("seed leaked through reset");
    host_write(16'h0008,32'h2000);
    host_read(16'h3D80+hot_slot[15:0],rd);
    if(rd!==0)bad("real hash RAM retained stale VL after repeated sweep");
    host_write(16'h0008,32'h051E);
    host_read(16'h0008,rd);if(rd[1]!==0)bad("RX_EN permitted after cold reset");
    check_acc(1'b1);
    if(read_words!==8192 || write_words!==8192 || seen_way!==4'b1111)
      bad("frontdoor did not cover 8192 words/all banks");
    if(errors==0)
      $display("T12f TOP LOOKUP PASS (IF_MODE=%0d image=4096/8192 frontdoor=%0dW+%0dR ways=%04b real_lookup=%0d hit=3 miss=1 badCRC=%0d seed=%04h/%04h)",
        IF_MODE,write_words,read_words,seen_way,lookups,crc_bad,meta[0][15:0],meta[1][15:0]);
    else $display("T12f TOP LOOKUP FAIL (IF_MODE=%0d errors=%0d)",IF_MODE,errors);
    $finish;
  end
  initial begin
    #4_000_000;
    $display("T12f TOP LOOKUP FAIL: timeout IF_MODE=%0d wr=%0d rd=%0d lookup=%0d",
       IF_MODE,write_words,read_words,lookups);
    $finish;
  end
endmodule
module tb_t12f_top_lookup; tb_t12f_core #(.IF_MODE(0)) core(); endmodule
module tb_t12fg_top_lookup; tb_t12f_core #(.IF_MODE(1)) core(); endmodule
