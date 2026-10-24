// Short PHY GMII contract test: 7x55+D5, contiguous DV, DA..FCS bytes,
// IFG, RX stripping, PHY errors, malformed preamble and recovery.
// Independent Python/zlib vectors cover payload lengths 1/32/1024/1471.
`timescale 1 ns / 1 ps
`include "vec/gmii_vectors.vh"
module tb_t41_gmii_phy;
  reg clk=0, rst=1;
  always #4 clk=~clk;
  reg in_vld=0, in_sof=0, in_eof=0;
  reg [7:0] in_byte=0;
  wire in_rdy, tx_valid;
  wire [7:0] tx_data;
  reg ignored_ready=0;
  reg start_permit=1;
  always @(negedge clk) ignored_ready <= ~ignored_ready;
  wire [15:0] underrun;
  mac_tx_if #(.IF_MODE(1), .PREAMBLE_EN(1), .FCS_MODE(2), .START_GUARD_EN(1)) u_tx (
    .clk(clk), .rst_sync(rst), .in_vld(in_vld), .in_byte(in_byte),
    .in_sof(in_sof), .in_eof(in_eof), .in_rdy(in_rdy),
    .pace_en(1'b1), .start_permit(start_permit), .link_rdy(ignored_ready),
    .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(),
    .frame_start(), .frame_done(), .busy(), .underrun_cnt(underrun));

  reg manual=0, manual_valid=0, manual_error=0;
  reg [7:0] manual_data=0;
  wire [7:0] body_data;
  wire body_valid, body_error;
  wire [31:0] preamble_drops;
  gmii_rx_strip u_strip (
    .clk(clk), .rst_sync(rst),
    .rx_data(manual ? manual_data : tx_data),
    .rx_valid(manual ? manual_valid : tx_valid),
    .rx_error(manual && manual_error),
    .frame_data(body_data), .frame_valid(body_valid),
    .frame_error(body_error), .preamble_drop_count(preamble_drops));
  wire pm_we, desc_vld, frame_err, blk_release;
  wire [12:0] pm_addr;
  wire [31:0] pm_data;
  wire [3:0] pm_be;
  wire [10:0] desc_len, desc_plen;
  wire [7:0] drop_reason;
  mac_rx_if #(.IF_MODE(1), .PHY_ERROR_EN(1), .FCS_MODE(2)) u_rx (
    .clk(clk), .rst_sync(rst), .enable(1'b1), .udp_csum_en(1'b1),
    .tb_us(24'd0), .rx_data(body_data), .rx_valid(body_valid),
    .rx_ready(1'b0), .rx_frame_error(body_error),
    .rx_blk(4'd6), .rx_blk_valid(1'b1), .frame_busy(),
    .pmem_wr_en(pm_we), .pmem_wr_addr(pm_addr),
    .pmem_wr_data(pm_data), .pmem_wr_be(pm_be),
    .blk_release(blk_release), .blk_release_id(),
    .desc_vld(desc_vld), .desc_blk(), .desc_len(desc_len), .desc_ts(),
    .desc_vlid(), .desc_sn(), .desc_net(), .desc_ifid(),
    .desc_src_ip(), .desc_dst_ip(), .desc_sport(), .desc_dport(),
    .desc_plen(desc_plen), .frame_err(frame_err), .crc_err(),
    .desc_first_frag(), .desc_is_frag(), .desc_frag_off(),
    .desc_df(), .desc_mf(), .desc_ident(),
    .drop_reason(drop_reason), .good_cnt(), .drop_cnt(), .disabled_cnt());

  reg [31:0] vec [0:`GMII_VECTOR_WORDS-1];
  reg [31:0] pmem [0:511];
  integer bases[0:3], lengths[0:3], plens[0:3];
  integer errors=0, checks=0, tx_frames=0, good_seen=0, bad_seen=0;
  integer active_case=0, cap_count=0, gap=100, k;
  integer ifg_run=0; // C3 加严：ST_IFG 精确 12 拍（杀 ifg_minus_one）
  reg in_frame=0;
  reg [7:0] last_drop=0;

  function [7:0] fbyte;
    input integer c, off;
    reg [31:0] word_value;
    begin
      word_value=vec[bases[c]+off/4];
      fbyte=word_value[31-8*(off%4) -: 8];
    end
  endfunction
  task bad;
    input [8*96-1:0] why;
    begin
      if (errors<20) $display("  [err] T41 t=%0t %0s", $time, why);
      errors=errors+1;
    end
  endtask

  always @(posedge clk) if (!rst) begin
    if (tx_valid) begin
      if (!in_frame) begin
        if(!start_permit)bad("MAC started before BAG permission");
        if (tx_frames!=0 && gap<12) bad("PHY inter-frame gap below 12 clocks");
        in_frame=1; cap_count=0;
      end
      checks=checks+1;
      if (cap_count<7) begin
        if (tx_data!==8'h55) bad("preamble byte differs from 55");
      end else if (cap_count==7) begin
        if (tx_data!==8'hD5) bad("SFD differs from D5");
      end else if (cap_count-8 >= lengths[active_case]) bad("TX frame too long");
      else if (tx_data!==fbyte(active_case,cap_count-8)) bad("TX DA..FCS differs from independent vector");
      cap_count=cap_count+1; gap=0;
    end else begin
      gap=gap+1;
      if (in_frame) begin
        if (cap_count!=8+lengths[active_case]) bad("DV fell inside a frame or frame length wrong");
        tx_frames=tx_frames+1; in_frame=0;
      end
    end
    // 精确 IFG：在 ST_IFG(5) 的连续拍数须 =12（mutant ifg_minus_one → 11）
    if (u_tx.st === 3'd5) ifg_run = ifg_run + 1;
    else if (ifg_run != 0) begin
      checks = checks + 1;
      if (ifg_run !== 12) bad("ST_IFG cycles != 12 (exact IFG)");
      ifg_run = 0;
    end
    if (pm_we) begin
      if (pm_addr[12:9]!==4'd6) bad("RX wrote outside allocated block");
      for(k=0;k<4;k=k+1)
        if(pm_be[3-k]) pmem[pm_addr[8:0]][31-8*k -: 8]<=pm_data[31-8*k -: 8];
    end
    if (desc_vld) good_seen=good_seen+1;
    if (frame_err) begin bad_seen=bad_seen+1; last_drop=drop_reason; end
  end

  integer c,i,j,pos,waitc,before_good,before_bad;
  reg [7:0] got;
  task check_pmem;
    input integer selected;
    integer byte_index;
    reg [31:0] q;
    begin
      if(desc_len!==lengths[selected] || desc_plen!==plens[selected]) bad("RX descriptor length wrong");
      for(byte_index=0;byte_index<lengths[selected];byte_index=byte_index+1) begin
        q=pmem[byte_index/4];
        if(q[31-8*(byte_index%4) -: 8]!==fbyte(selected,byte_index)) bad("RX PMEM byte mismatch");
        checks=checks+1;
      end
    end
  endtask
  task inject;
    // bad_pre: corrupt SFD; phy_er: valid CRC but PHY error on last byte;
    // bad_crc: corrupt last FCS byte; trim: remove final byte.
    input integer selected,bad_pre,phy_er,bad_crc,trim;
    integer n;
    reg [7:0] b;
    begin
      @(negedge clk);
      for(n=0;n<8+lengths[selected]-trim;n=n+1) begin
        b=(n<7)?8'h55:((n==7)?8'hD5:fbyte(selected,n-8));
        if(bad_pre!=0 && n==7) b=8'h54;
        if(bad_crc!=0 && n==7+lengths[selected]) b=b^8'h80;
        manual_data=b; manual_valid=1;
        manual_error=(phy_er!=0 && n==7+lengths[selected]);
        @(negedge clk);
      end
      manual_valid=0; manual_error=0;
      repeat(20) @(negedge clk);
    end
  endtask

  initial begin
    $readmemh("vec/gmii_frames.hex",vec,0,`GMII_VECTOR_WORDS-1);
    if(vec[0]!==4) $fatal(1,"T41 missing GMII vectors");
    pos=1;
    for(c=0;c<4;c=c+1) begin
      plens[c]=vec[pos]; lengths[c]=vec[pos+1]; bases[c]=pos+2;
      pos=pos+2+(lengths[c]+3)/4;
    end
    if(pos!=`GMII_VECTOR_WORDS) $fatal(1,"T41 vector layout mismatch");
    repeat(6) @(negedge clk); rst=0;
    for(c=0;c<4;c=c+1) begin
      active_case=c;
      @(negedge clk);
      // The first complete minimum frame fits in the FIFO while held.
      // A later permission drop inside frame 1 must not interrupt its DV.
      start_permit=(c!=0);
      for(i=0;i<lengths[c]-4;i=i+1) begin
        while(!in_rdy) begin in_vld=0; @(negedge clk); end
        in_vld=1; in_byte=fbyte(c,i); in_sof=(i==0); in_eof=(i==lengths[c]-5);
        @(negedge clk);
        if(c==1 && i==60)start_permit=0;
      end
      in_vld=0; in_sof=0; in_eof=0;
      if(c==0)begin
        repeat(32)begin
          @(negedge clk);checks=checks+1;
          if(tx_valid || tx_frames!=0 || good_seen!=0)bad("held complete frame escaped MAC");
        end
        start_permit=1;
      end
      waitc=0;
      while(good_seen<c+1 && waitc<10000) begin @(negedge clk); waitc=waitc+1; end
      if(good_seen!=c+1 || tx_frames!=c+1) bad("TX/RX frame completion timeout");
      check_pmem(c);
      start_permit=1;
      repeat(16) @(negedge clk);
    end
    if(underrun!==0) bad("TX FIFO underrun");
    $display("T41_START_GUARD held_cycles=32 midframe_permission_drop=1");
    manual=1; before_good=good_seen; before_bad=bad_seen;
    inject(1,1,0,0,0);
    if(good_seen!=before_good || bad_seen!=before_bad || preamble_drops!==1) bad("malformed preamble reached parser");
    inject(1,0,1,0,0);
    if(good_seen!=before_good || bad_seen!=before_bad+1 || last_drop!==8'h80) bad("PHY RX_ER with valid FCS was accepted");
    inject(1,0,0,1,0);
    if(good_seen!=before_good || bad_seen!=before_bad+2 || last_drop!==8'h01) bad("bad CRC accepted");
    inject(1,0,0,0,1);
    if(good_seen!=before_good || bad_seen!=before_bad+3 || last_drop!==8'h10) bad("truncated frame accepted");
    inject(1,0,0,0,0);
    if(good_seen!=before_good+1 || bad_seen!=before_bad+3) bad("recovery after bad PHY frames failed");
    check_pmem(1);
    if(errors==0) $display("T41 GMII PHY PASS checks=%0d tx_frames=%0d accepted=%0d rejected=%0d bad_preamble=%0d ready_ignored=1",checks,tx_frames,good_seen,bad_seen,preamble_drops);
    else $display("T41 GMII PHY FAIL errors=%0d",errors);
    $finish;
  end
  initial begin
    #1000000;
    $display("T41 GMII PHY FAIL timeout"); $finish;
  end
endmodule
