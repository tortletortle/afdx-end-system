// T35/T35g: public-host configuration plus live A/B RX delivery for every
// selected index. Default selects all 4096; T35_COUNT is pilot-only.
`timescale 1 ns / 1 ps
module tb_t35_core #(parameter integer IF_MODE=0);
  localparam integer N=4096, P_RX=5, WORDS_PER_FRAME=20, WORDS_PER_INDEX=41;
  localparam [15:0] PT_RX=16'h7D80+4*P_RX;
  localparam [31:0] RX_W0=32'hF500_0000|(P_RX<<12)|32'd79;
  reg clk=0, reset=1;
  always #4 clk=~clk;
  reg [7:0] rx_data=0,rx_data_b=0;
  reg rx_valid=0,rx_valid_b=0,rx_ready=0,rx_ready_b=0;
  reg host_cs=0,host_we=0;
  reg [15:0] host_addr=0;
  reg [31:0] host_wdata=0;
  wire [31:0] host_rdata;
  wire host_ack;
  AFDX_top #(.NUM_RX_VL(4096),.IF_MODE(IF_MODE),.FCS_MODE(2)) dut (
    .clk(clk),.reset(reset),.tx_data(),.tx_valid(),.tx_ready(),
    .rx_data(rx_data),.rx_valid(rx_valid),.rx_ready(rx_ready),
    .tx_data_b(),.tx_valid_b(),.tx_ready_b(),
    .rx_data_b(rx_data_b),.rx_valid_b(rx_valid_b),.rx_ready_b(rx_ready_b),
    .host_cs(host_cs),.host_we(host_we),.host_addr(host_addr),
    .host_wdata(host_wdata),.host_rdata(host_rdata),.host_ack(host_ack),
    .host_irq(),.pps_in(1'b0),.pps_out(),.rtc_time_us(),.dbg_frame_event(),
    .rx_error(1'b0),.rx_error_b(1'b0));

  reg [31:0] image[0:8191],meta[0:3],frames[0:168000];
  reg [15:0] key_by_idx[0:4095];
  reg seen[0:4095];
  integer requested=4096,errors=0,i,j,k,wc,hash_w=0,cfg_w=0,cfg_r=0,valid_entries=0;
  integer debug_shown=0,plusarg_found,errors_before;
  reg [3:0] seen_way=0;
  integer in_a=0,in_b=0,unique_count=0,dup_count=0,drop_count=0;
  reg [31:0] rd,w,cookie,index_word;
  reg [15:0] sentinel;
  integer len,blk;
  reg [7:0] bval;
  integer phy_a,phy_b,phy_bytes_a=0,phy_bytes_b=0,phy_start_a,phy_start_b;
  integer phy_timing_a,phy_timing_b,phy_cycle=0;
  reg phy_active_a=0,phy_active_b=0;
  // Actual public pins sampled by the DUT, including the PHY envelope.
  always @(posedge clk) if(IF_MODE==2)begin
    phy_cycle=phy_cycle+1;
    if(rx_valid)begin
      if(!phy_active_a)phy_start_a=phy_cycle;
      phy_active_a=1;phy_bytes_a=phy_bytes_a+1;$fwrite(phy_a,"%02x ",rx_data);
    end else if(phy_active_a)begin
      if(phy_bytes_a!=72)bad("PHY A input was not a continuous 72-byte frame");
      $fwrite(phy_a,"\n");$fwrite(phy_timing_a,"%0d %0d\n",phy_start_a,phy_cycle-1);
      phy_active_a=0;phy_bytes_a=0;
    end
    if(rx_valid_b)begin
      if(!phy_active_b)phy_start_b=phy_cycle;
      phy_active_b=1;phy_bytes_b=phy_bytes_b+1;$fwrite(phy_b,"%02x ",rx_data_b);
    end else if(phy_active_b)begin
      if(phy_bytes_b!=72)bad("PHY B input was not a continuous 72-byte frame");
      $fwrite(phy_b,"\n");$fwrite(phy_timing_b,"%0d %0d\n",phy_start_b,phy_cycle-1);
      phy_active_b=0;phy_bytes_b=0;
    end
  end

  task bad; input [8*112-1:0] msg; begin
    if(errors<20) $display("  [err] T35%0d: %0s",IF_MODE,msg);
    errors=errors+1;
  end endtask
  task hw; input [15:0] a; input [31:0] d; begin
    @(negedge clk);host_cs=1;host_we=1;host_addr=a;host_wdata=d;
    @(negedge clk);if(host_ack!==1)bad("host write ACK missing");host_cs=0;host_we=0;
  end endtask
  task hr; input [15:0] a; output [31:0] d; begin
    @(negedge clk);host_cs=1;host_we=0;host_addr=a;
    @(negedge clk);if(host_ack!==1)bad("host read ACK missing");d=host_rdata;host_cs=0;
  end endtask
  function [7:0] fbyte; input integer idx,net,off; reg [31:0] q; integer pos; begin
    // frames[0] is the record count and each record starts with a length word.
    // The A-frame payload begins at word 2; B begins at word 22.
    pos=2+idx*WORDS_PER_INDEX+net*WORDS_PER_FRAME+(off>>2);
    q=frames[pos];case(off&3) 0:fbyte=q[31:24];1:fbyte=q[23:16];2:fbyte=q[15:8];default:fbyte=q[7:0];endcase
  end endfunction
  task send_frame; input integer idx,net; begin
    len=frames[1+idx*WORDS_PER_INDEX];
    if(IF_MODE==2)begin
      for(j=0;j<8;j=j+1)begin
        @(negedge clk);
        if(net==0)begin rx_valid=1;rx_data=(j==7)?8'hD5:8'h55;end
        else begin rx_valid_b=1;rx_data_b=(j==7)?8'hD5:8'h55;end
      end
    end
    for(j=0;j<len;j=j+1) begin
      @(negedge clk);rx_ready=1;rx_ready_b=1;
      if(net==0) begin rx_valid=1;rx_data=fbyte(idx,0,j);end
      else begin rx_valid_b=1;rx_data_b=fbyte(idx,1,j);end
      if(IF_MODE==0) begin @(negedge clk);rx_valid=0;rx_valid_b=0;repeat(8)@(negedge clk);end
    end
    @(negedge clk);rx_valid=0;rx_valid_b=0;rx_ready=0;rx_ready_b=0;
    if(net==0)in_a=in_a+1;else in_b=in_b+1;
  end endtask

  initial begin
    if(IF_MODE==2)begin
      phy_a=$fopen("out/metrics/t35_phy_a.hex","w");phy_b=$fopen("out/metrics/t35_phy_b.hex","w");
      phy_timing_a=$fopen("out/metrics/t35_phy_a_cycles.txt","w");
      phy_timing_b=$fopen("out/metrics/t35_phy_b_cycles.txt","w");
      if(!phy_a||!phy_b||!phy_timing_a||!phy_timing_b)$fatal(1,"T35 PHY capture open");
    end
    plusarg_found=$value$plusargs("T35_COUNT=%d",requested);
    if(requested<1||requested>N)begin bad("T35_COUNT must be 1..4096");requested=0;end
    $readmemh("vec/t12_top.img.hex",image);$readmemh("vec/t12_top.meta.hex",meta);
    $readmemh("vec/t35_frames.hex",frames);
    for(i=0;i<N;i=i+1)begin seen[i]=0;key_by_idx[i]=0;end
    if(meta[2]!==4096||frames[0]!==4096||frames[1]!==64)bad("full image/frame fixture malformed");
    for(i=0;i<8192;i=i+1)if(image[i][28])begin
      if(image[i][11:0]>=N)bad("hash image index outside 4096");
      else begin
        if(seen[image[i][11:0]])bad("hash image duplicate index");
        if(image[i][27:12]!==image[i][11:0])bad("hash image VLID/index mapping mismatch");
        seen[image[i][11:0]]=1;key_by_idx[image[i][11:0]]=image[i][27:12];
        seen_way[(i/4096)*2+(i&1)]=1;valid_entries=valid_entries+1;
      end
    end
    for(i=0;i<N;i=i+1)if(!seen[i])bad("hash image misses RX index");
    if(valid_entries!=4096||seen_way!==4'b1111)bad("hash image full-index/way coverage invalid");
    for(i=0;i<N;i=i+1)seen[i]=0;
    repeat(7)@(negedge clk);reset=0;wc=0;
    while(dut.init_done!==1&&wc<26000)begin @(negedge clk);wc=wc+1;end
    if(wc>=26000)bad("INIT_DONE timeout");
    hw(16'h0008,32'h2000);hw(16'h0078,meta[0]);hw(16'h007C,meta[1]);
    for(i=0;i<8192;i=i+1)begin hw(16'h3D80+i,image[i]);hash_w=hash_w+1;end
    hw(16'h0080,1);hr(16'h0080,rd);if(rd[0]!==1)bad("hash commit absent");
    for(i=0;i<N;i=i+1)begin hw(16'h1D80+(i<<1),RX_W0);hw(16'h1D81+(i<<1),{16'd0,key_by_idx[i]});cfg_w=cfg_w+2;end
    for(i=0;i<N;i=i+1)begin
      hr(16'h1D80+(i<<1),rd);if(rd!==RX_W0)bad("RX config w0 readback mismatch");
      hr(16'h1D81+(i<<1),rd);if(rd!=={16'd0,key_by_idx[i]})bad("RX config key readback mismatch");cfg_r=cfg_r+2;
    end
    hw(PT_RX,32'h8004_0000);hw(PT_RX+1,32'h0000_1388);hw(PT_RX+2,0);hw(PT_RX+3,1);
    hr(PT_RX,rd);if(rd!==32'h8004_0000)bad("RX port config readback mismatch");
    hw(16'h0008,32'h051E);
    for(i=0;i<requested;i=i+1)begin
      errors_before=errors;
      send_frame(i,0);wc=0;rd=0;
      while(rd==0&&wc<1000)begin hr(16'h8480+P_RX,rd);wc=wc+1;end
      if(rd!==1)begin
        bad("bounded wait did not find exactly one host message");drop_count=drop_count+1;
        if(!debug_shown)begin
          debug_shown=1;
          $display("T35_DEBUG msg_cnt=%08X frame_err=%b/%b reason=%02X/%02X crc=%b/%b desc_vld=%b/%b queue_ovf=%b/%b lookup=%b/%b hit=%b vl=%0d flt=%b/%b ic=%b/%b rm=%b/%b pb=%b drop_total=%0d rm_dup=%0d ic_drop=%0d flt_unconf=%0d flt_lmax=%0d rxpb_deliver=%0d rxpb_drop=%0d",
            rd,dut.rx_frame_err_a,dut.rx_frame_err_b,dut.rx_drop_reason_a,dut.rx_drop_reason_b,
            dut.rx_crc_err_a,dut.rx_crc_err_b,dut.rx_desc_valid_a,dut.rx_desc_valid_b,
            dut.rx_ovf_a,dut.rx_ovf_b,dut.lookup_out_vld,dut.lookup_out_hit,dut.lookup_out_vl,
            dut.flt_out_vld,dut.flt_out_pass,dut.ic_out_vld,dut.ic_out_accept,
            dut.rm_out_vld,dut.rm_out_fwd,dut.prs_out_vld,dut.pb_ev_drop,
            dut.flt_drop_total,dut.rm_dup_cnt,dut.ic_drop_cnt,dut.flt_unconf_cnt,dut.flt_lmax_cnt,
            dut.rxpb_deliver_cnt,dut.rxpb_port_drop_cnt);
        end
      end
      send_frame(i,1);repeat(128)@(negedge clk);
      hr(16'h8480+P_RX,rd);if(rd!==1)bad("A/B duplicate changed host MSG_CNT");
      hr(16'h8180+P_RX,rd);
      if(rd[31]!==1||rd[10:0]!==11'd8||rd[23:20]<6)begin
        bad("host descriptor malformed");
      end else begin
        blk=rd[23:20];
        hr(16'h8800+(blk<<9)+10,w);index_word=w;
        if(index_word[15:0]!==i[15:0])bad("host payload index mismatch");
        hr(16'h8800+(blk<<9)+11,w);cookie=32'h35C00000 ^ (i*32'h9E3779B1);
        if(w!==cookie)bad("host payload cookie mismatch");
        hr(16'h8800+(blk<<9)+12,w);sentinel=16'hA55A ^ i[15:0];
        if(w[31:16]!==sentinel)bad("host payload sentinel mismatch");
        if(seen[i])bad("duplicate index delivery");
        if(errors==errors_before)begin
          seen[i]=1;unique_count=unique_count+1;
          $display("T35_DELIVERY index=%0d cookie=%08X port=%0d payload=%04X%08X%04X",i,cookie,P_RX,index_word[15:0],cookie,sentinel);
        end
      end
      hw(16'h8380+P_RX,0);
      if((i%128)==127||i==requested-1)$display("T35_PROGRESS covered=%0d/%0d A=%0d B=%0d",i+1,requested,in_a,in_b);
    end
    repeat(180)@(negedge clk);hr(16'h8480+P_RX,rd);if(rd!==0)bad("host queue not empty after drain");
    if(hash_w!=8192||cfg_w!=8192||cfg_r!=8192)bad("configuration transaction counts incomplete");
    hr(16'h0100,rd);if(rd!==requested)bad("RX delivered statistic mismatch");
    hr(16'h0040,w);if(w!==0)bad("unexpected FLT configuration drops");
    hr(16'h0044,w);if(w!==0)bad("unexpected FLT length drops");
    hr(16'h0048,w);if(w!==0)bad("unexpected IC rejects");
    hr(16'h004C,w);dup_count=w;if(dup_count!=requested)bad("A/B duplicate suppression count mismatch");
    hr(16'h001C,w);if(w!==requested)bad("global drop total differs from expected A/B duplicates");
    if(unique_count!=requested||in_a!=requested||in_b!=requested)bad("coverage or A/B input totals mismatch");
    if(IF_MODE==2)begin
      if(phy_active_a||phy_active_b)bad("partial PHY frame after drain");
      $fclose(phy_a);$fclose(phy_b);$fclose(phy_timing_a);$fclose(phy_timing_b);
    end
    if(errors==0)$display("T35 RX4096 PASS IF_MODE=%0d requested=%0d covered=%0d inputA=%0d inputB=%0d unique=%0d duplicate=%0d drops=%0d",IF_MODE,requested,unique_count,in_a,in_b,unique_count,dup_count,drop_count);
    else $display("T35 RX4096 FAIL IF_MODE=%0d requested=%0d covered=%0d inputA=%0d inputB=%0d unique=%0d errors=%0d",IF_MODE,requested,unique_count,in_a,in_b,unique_count,errors);
    $finish;
  end
  initial begin #120_000_000;$display("T35 RX4096 FAIL timeout IF_MODE=%0d",IF_MODE);$finish;end
endmodule
module tb_t35_rx4096; tb_t35_core #(.IF_MODE(0)) c(); endmodule
module tb_t35g_rx4096; tb_t35_core #(.IF_MODE(1)) c(); endmodule
module tb_t35p_rx4096; tb_t35_core #(.IF_MODE(2)) c(); endmodule
