// T08a: RX 单元入口，黄金模型帧 + 独立 zlib 线序 FCS。
// 验证两档 IF_MODE 的流式 FCS/IP/UDP、pad/SN/长度、PMEM byte enable、
// 坏帧不发描述符；RX 块仲裁/查表/IC/RM/端口尚未接入顶层，不等于完整 T08/T22。
`timescale 1 ns / 1 ps
module tb_t08a_core #(parameter IF_MODE=0);
  reg clk=0, reset=1;
  always #4 clk=~clk;
  reg enable=1, udp_csum_en=1, rx_valid=0, rx_ready=0, rx_blk_valid=1;
  reg [7:0] rx_data=0;
  reg [3:0] rx_blk=4'd6;
  reg [23:0] tb_us=0;
  wire pmem_wr_en, blk_release, desc_vld, frame_err, crc_err, desc_net;
  wire [12:0] pmem_wr_addr;
  wire [31:0] pmem_wr_data, desc_src_ip, desc_dst_ip;
  wire [3:0] pmem_wr_be, blk_release_id, desc_blk;
  wire [10:0] desc_len;
  wire [23:0] desc_ts;
  wire [15:0] desc_vlid, desc_sport, desc_dport, good_cnt, drop_cnt, disabled_cnt;
  wire [7:0] desc_sn, drop_reason;
  wire [2:0] desc_ifid;
  mac_rx_if #(.IF_MODE(IF_MODE),.FCS_MODE(2),.MAX_FRAME(1518),.NET_ID(0)) dut (
    .clk(clk),.rst_sync(reset),.enable(enable),.udp_csum_en(udp_csum_en),.tb_us(tb_us),
    .rx_data(rx_data),.rx_valid(rx_valid),.rx_ready(rx_ready),
    .rx_blk(rx_blk),.rx_blk_valid(rx_blk_valid),
    .pmem_wr_en(pmem_wr_en),.pmem_wr_addr(pmem_wr_addr),
    .pmem_wr_data(pmem_wr_data),.pmem_wr_be(pmem_wr_be),
    .blk_release(blk_release),.blk_release_id(blk_release_id),
    .desc_vld(desc_vld),.desc_blk(desc_blk),.desc_len(desc_len),.desc_ts(desc_ts),
    .desc_vlid(desc_vlid),.desc_sn(desc_sn),.desc_net(desc_net),.desc_ifid(desc_ifid),
    .desc_src_ip(desc_src_ip),.desc_dst_ip(desc_dst_ip),
    .desc_sport(desc_sport),.desc_dport(desc_dport),
    .frame_err(frame_err),.crc_err(crc_err),.drop_reason(drop_reason),
    .good_cnt(good_cnt),.drop_cnt(drop_cnt),.disabled_cnt(disabled_cnt));

  reg [31:0] vec[0:1144];
  reg [31:0] pmem[0:8191];
  integer errors=0, good_seen=0, drop_seen=0, rel_seen=0, crc_seen=0;
  reg [7:0] last_reason;
  reg [23:0] first_ts, last_ts;
  reg [10:0] last_len;
  reg [7:0] last_sn;
  reg [2:0] last_ifid;
  reg [15:0] last_vlid;
  reg [31:0] last_sip,last_dip;
  reg [15:0] last_sport,last_dport;
  integer j;
  always @(posedge clk) begin
    if (reset) tb_us <= 24'd0;
    else tb_us <= tb_us + 24'd1;
    if (!reset && pmem_wr_en) begin
      if (pmem_wr_addr[12:9] != 4'd6) begin
        $display("  [err] PMEM write outside given block: %h",pmem_wr_addr); errors=errors+1;
      end
      for (j=0;j<4;j=j+1)
        if (pmem_wr_be[3-j]) pmem[pmem_wr_addr][31-j*8 -: 8] <= pmem_wr_data[31-j*8 -: 8];
    end
    if (!reset && desc_vld) begin
      good_seen=good_seen+1;
      last_ts=desc_ts; last_len=desc_len; last_sn=desc_sn;
      last_ifid=desc_ifid; last_vlid=desc_vlid;
      last_sip=desc_src_ip; last_dip=desc_dst_ip;
      last_sport=desc_sport; last_dport=desc_dport;
      if (desc_blk != 4'd6 || desc_net != 1'b0) begin
        $display("  [err] descriptor block/net =%h/%b",desc_blk,desc_net); errors=errors+1;
      end
    end
    if (!reset && frame_err) begin drop_seen=drop_seen+1; last_reason=drop_reason; end
    if (!reset && blk_release) begin
      rel_seen=rel_seen+1;
      if (blk_release_id != 4'd6) begin $display("  [err] released wrong block %h",blk_release_id); errors=errors+1; end
    end
    if (!reset && crc_err) crc_seen=crc_seen+1;
  end

  integer base,i,k,word_off,ncases,nwords,csum,hasblk,en,reason;
  integer gb,db,rb,cb,disabled_before;
  reg [31:0] ew;
  reg [7:0] exp_b,got_b;
  initial begin
    $readmemh("vec/t08a_frames.hex",vec);
    ncases=vec[0]; base=1;
    repeat(6) @(negedge clk); reset<=0;
    for (i=0;i<ncases;i=i+1) begin
      nwords=vec[base][15:0]; reason=vec[base][23:16];
      csum=vec[base+1][0]; hasblk=vec[base+1][1]; en=vec[base+1][2];
      gb=good_seen; db=drop_seen; rb=rel_seen; cb=crc_seen;
      disabled_before=disabled_cnt;
      for(k=0;k<512;k=k+1) pmem[(6<<9)+k]=32'hA5A5_A5A5;
      udp_csum_en=csum[0]; rx_blk_valid=hasblk[0]; enable=en[0];
      for (k=0;k<nwords;k=k+1) begin
        word_off=base+2+(k>>2); ew=vec[word_off];
        case(k&3)
          0: exp_b=ew[31:24]; 1: exp_b=ew[23:16];
          2: exp_b=ew[15:8]; default: exp_b=ew[7:0];
        endcase
        @(negedge clk);
        rx_ready<=1'b1; rx_valid<=1'b1; rx_data<=exp_b;
        if(k==0) first_ts=tb_us; // 驱动首字节前锁存时基，不依赖 DUT 内部状态
        if (IF_MODE==0) begin
          @(negedge clk); rx_valid<=1'b0;
          repeat(8) @(negedge clk);
        end
      end
      @(negedge clk); rx_valid<=1'b0; rx_ready<=1'b0;
      repeat(5) @(negedge clk);
      if (!en) begin
        if (good_seen!=gb || drop_seen!=db || rel_seen!=rb || disabled_cnt!=disabled_before+1) begin
          $display("  [err] disabled case %0d: desc=%0d drop=%0d release=%0d dis=%0d",
                   i,good_seen-gb,drop_seen-db,rel_seen-rb,disabled_cnt-disabled_before); errors=errors+1;
        end
      end else if (reason==0) begin
        if (good_seen!=gb+1 || drop_seen!=db || rel_seen!=rb || last_len!=nwords ||
            last_ts!==first_ts || last_vlid!=16'h0100 || last_sip!=32'h0A00_0001 ||
            last_dip!=32'hE000_0001 || last_sport!=16'd49152 || last_dport!=16'd5000 ||
            last_ifid!=(i==2 ? 3'd2 : 3'd1) || last_sn!=(i==18 ? 8'd0 : 8'd1)) begin
          $display("  [err] case %0d good verdict/metadata: good=%0d bad=%0d rel=%0d len=%0d ts=%0d/%0d ifid=%0d SN=%0d",
                   i,good_seen-gb,drop_seen-db,rel_seen-rb,last_len,last_ts,first_ts,last_ifid,last_sn);
          errors=errors+1;
        end
        // 仅好帧的块内容可见；坏帧写入的块必须由后级按 release 重用。
        for(k=0;k<nwords;k=k+1) begin
          word_off=base+2+(k>>2); ew=vec[word_off];
          case(k&3)
            0: exp_b=ew[31:24]; 1: exp_b=ew[23:16];
            2: exp_b=ew[15:8]; default: exp_b=ew[7:0];
          endcase
          ew=pmem[(6<<9)+(k>>2)];
          case(k&3)
            0: got_b=ew[31:24]; 1: got_b=ew[23:16];
            2: got_b=ew[15:8]; default: got_b=ew[7:0];
          endcase
          if (got_b!==exp_b) begin
            if (errors<12) $display("  [err] case %0d PMEM byte %0d got=%02x want=%02x",i,k,got_b,exp_b);
            errors=errors+1;
          end
        end
        if ((nwords&3)!=0) begin
          ew=pmem[(6<<9)+(nwords>>2)];
          for(k=(nwords&3);k<4;k=k+1)
            if (ew[31-k*8 -: 8] !== 8'hA5) begin
              $display("  [err] case %0d partial-word lane %0d clobbered",i,k); errors=errors+1;
            end
        end
      end else if (good_seen!=gb || drop_seen!=db+1 || last_reason!=reason ||
                   rel_seen!=rb+(hasblk?1:0)) begin
        $display("  [err] case %0d bad verdict good=%0d drop=%0d reason=%h/%h rel=%0d",
                 i,good_seen-gb,drop_seen-db,last_reason,reason,rel_seen-rb); errors=errors+1;
      end
      if (i==4 && crc_seen!=cb+1) begin
        $display("  [err] mutated FCS did not pulse crc_err"); errors=errors+1;
      end
      base=base+2+((nwords+3)>>2);
    end
    if (base!=1145 || good_cnt!=good_seen || drop_cnt!=drop_seen) begin
      $display("  [err] vector end/counter: base=%0d good=%0d/%0d bad=%0d/%0d",
               base,good_cnt,good_seen,drop_cnt,drop_seen); errors=errors+1;
    end
    if (IF_MODE==0) begin
      db=drop_seen;
      @(negedge clk); enable<=1'b1; rx_ready<=1'b0; rx_valid<=1'b1; rx_data<=8'h44;
      @(negedge clk); rx_valid<=1'b0;
      repeat(3) @(negedge clk);
      if (drop_seen!=db+1 || last_reason!=8'h80) begin
        $display("  [err] byte outside ready envelope not counted"); errors=errors+1;
      end
    end
    if(errors==0) $display("T08a RXINGRESS PASS (IF_MODE=%0d, %0d model/zlib frames, bad frame isolation/PMEM BE)",IF_MODE,ncases);
    else $display("T08a RXINGRESS FAIL: %0d errors (IF_MODE=%0d)",errors,IF_MODE);
    $finish;
  end
  initial begin #5_000_000; $display("T08a RXINGRESS FAIL: timeout IF_MODE=%0d",IF_MODE); $finish; end
endmodule
module tb_t08a_rx_ingress; tb_t08a_core #(.IF_MODE(0)) core(); endmodule
module tb_t08ag_rx_ingress; tb_t08a_core #(.IF_MODE(1)) core(); endmodule
