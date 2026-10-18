// T79: MAC RX acceptance at the fragment-specific Ethernet minimum length.
`timescale 1 ns / 1 ps
module tb_t79_rx_frag_minlen;
  reg clk=0, rst=1, rx_valid=0, rx_ready=0;
  reg [7:0] rx_data=0;
  always #4 clk=~clk;

  wire frame_busy, pmem_wr_en, blk_release, desc_vld, frame_err, crc_err;
  wire [12:0] pmem_wr_addr;
  wire [31:0] pmem_wr_data;
  wire [3:0] pmem_wr_be, blk_release_id, desc_blk;
  wire [10:0] desc_len, desc_plen;
  wire [23:0] desc_ts;
  wire [15:0] desc_vlid, desc_ident, desc_sport, desc_dport, good_cnt, drop_cnt, disabled_cnt;
  wire [7:0] desc_sn, drop_reason;
  wire desc_net, desc_mf, desc_df, desc_is_frag, desc_first_frag;
  wire [2:0] desc_ifid;
  wire [31:0] desc_src_ip, desc_dst_ip;
  wire [12:0] desc_frag_off;

  mac_rx_if #(.IF_MODE(0),.FCS_MODE(2),.MAX_FRAME(1518),.NET_ID(0)) dut (
    .clk(clk),.rst_sync(rst),.enable(1'b1),.udp_csum_en(1'b1),.tb_us(24'd0),
    .rx_data(rx_data),.rx_valid(rx_valid),.rx_ready(rx_ready),.rx_frame_error(1'b0),
    .rx_blk(4'd6),.rx_blk_valid(1'b1),.frame_busy(frame_busy),
    .pmem_wr_en(pmem_wr_en),.pmem_wr_addr(pmem_wr_addr),.pmem_wr_data(pmem_wr_data),.pmem_wr_be(pmem_wr_be),
    .blk_release(blk_release),.blk_release_id(blk_release_id),
    .desc_vld(desc_vld),.desc_blk(desc_blk),.desc_len(desc_len),.desc_ts(desc_ts),
    .desc_vlid(desc_vlid),.desc_sn(desc_sn),.desc_net(desc_net),.desc_ifid(desc_ifid),
    .desc_src_ip(desc_src_ip),.desc_dst_ip(desc_dst_ip),.desc_sport(desc_sport),.desc_dport(desc_dport),
    .desc_plen(desc_plen),.desc_ident(desc_ident),.desc_mf(desc_mf),.desc_df(desc_df),
    .desc_frag_off(desc_frag_off),.desc_is_frag(desc_is_frag),.desc_first_frag(desc_first_frag),
    .frame_err(frame_err),.crc_err(crc_err),.drop_reason(drop_reason),
    .good_cnt(good_cnt),.drop_cnt(drop_cnt),.disabled_cnt(disabled_cnt));

  reg [31:0] vec[0:1023];
  reg [7:0] pkt[0:255];
  integer errors=0, good_seen=0, drop_seen=0, release_seen=0;
  integer pos=1, cases, ci, len, reason, plen, flags, offset, i, w;
  integer g0,d0,r0;
  reg [31:0] word;

  always @(posedge clk) if (!rst) begin
    if (desc_vld) good_seen <= good_seen + 1;
    if (frame_err) drop_seen <= drop_seen + 1;
    if (blk_release) release_seen <= release_seen + 1;
  end

  task check;
    input condition;
    input [8*96-1:0] message;
    begin
      if (!condition) begin
        if (errors < 20) $display("  [err] T79 case=%0d %0s",ci,message);
        errors = errors + 1;
      end
    end
  endtask

  initial begin
    $readmemh("vec/t79_rx_frag_minlen.hex",vec);
    cases=vec[0];
    repeat (6) @(negedge clk);
    rst=0;
    for (ci=0; ci<cases; ci=ci+1) begin
      len=vec[pos]; reason=vec[pos+1]; plen=vec[pos+2]; flags=vec[pos+3]; offset=vec[pos+4];
      pos=pos+5;
      for (i=0; i<((len+3)/4); i=i+1) begin
        word=vec[pos+i];
        pkt[i*4+0]=word[31:24]; pkt[i*4+1]=word[23:16];
        pkt[i*4+2]=word[15:8]; pkt[i*4+3]=word[7:0];
      end
      pos=pos+((len+3)/4);
      g0=good_seen; d0=drop_seen; r0=release_seen;
      @(negedge clk); rx_ready=1; rx_valid=1;
      for (i=0; i<len; i=i+1) begin
        rx_data=pkt[i]; @(negedge clk);
      end
      rx_valid=0; rx_ready=0;
      repeat (4) @(negedge clk);
      if (reason==0) begin
        check(good_seen==g0+1 && drop_seen==d0, "minimum-sized legal fragment accepted");
        check(release_seen==r0, "accepted block not released");
        check(desc_len==len && desc_plen==plen, "descriptor lengths");
        check(desc_is_frag && desc_first_frag==flags[1] && desc_mf==flags[0], "fragment flags");
        check(desc_frag_off==offset, "fragment offset");
        check(desc_vlid==16'h0100 && desc_sn!=0, "AFDX metadata and sequence number");
      end else begin
        check(good_seen==g0 && drop_seen==d0+1, "below-minimum frame rejected");
        check(drop_reason==reason && release_seen==r0+1, "bad-frame reason and block release");
      end
    end
    check(good_cnt==3 && drop_cnt==1, "aggregate MAC counters");
    if (errors==0) $display("T79 RX FRAGMENT MIN-LENGTH PASS cases=%0d good=%0d drop=%0d",cases,good_seen,drop_seen);
    else $display("T79 RX FRAGMENT MIN-LENGTH FAIL errors=%0d good=%0d drop=%0d",errors,good_seen,drop_seen);
    $finish;
  end
  initial begin #1000000; $display("T79 RX FRAGMENT MIN-LENGTH FAIL timeout"); $finish; end
endmodule
