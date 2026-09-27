// T10: top-level RX redundancy management (rx_rm wired after rx_ic, v0.5.15).
// Real 79 B model/zlib frame (t08a case 2, VLID 0x0100 -> idx 0x100), SN byte
// patched and FCS recomputed in the TB; frames run the whole top-level chain
// mac_rx_if -> lookup -> FLT -> IC -> RM.  Checks:
//   * A/B copies of one SN at 0..9 cycle skew, A-first and B-first: exactly
//     one forward + one drop_dup per SN (the "same-cycle double forward" case
//     of design doc 7.11 included);
//   * copies further apart than SkewMax (exp=0, 4 us) both forward and raise
//     the skew event; copies inside SkewMax (exp=5) are dropped;
//   * CTL.RM_EN=0 and VL rm_en=0 disable dedup (both copies forward, RM RAM
//     untouched); IC_EN=0 bypass still feeds RM;
//   * an IC-rejected frame never writes the RM entry (pollution check);
//   * first SN=0 frame after init with SkewMax 131 ms is forwarded (seen bit);
//   * an independent TB RM model re-derives every RM verdict; RM RAM
//     {seen,last_ts,last_sn} checked; block conservation after every frame; one
//     block release per cycle on the shared free port;
//   * DROP_CNT_K rm (0x4C), DROP_CNT total, reset clears RAM/seen/counters.
// v0.5.16: forwarded frames continue to parse; no RX port is configured here,
// so each is dropped as port-unconfigured and its block recycled.  This is NOT a full T08/T22.
`timescale 1 ns / 1 ps
module tb_t10_core #(parameter integer IF_MODE=0);
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

  localparam [31:0] W0_RM = 32'hF000_0000 | 32'd79;   // valid,rm_en,net=11,lmax=79
  reg [31:0] vec [0:1144];
  reg [7:0] base [0:78];
  reg [7:0] frm_a [0:78];
  reg [7:0] frm_b [0:78];
  integer errors=0, rm_seen=0, rm_fwd=0, rm_dup=0, rm_skew=0, ic_rej=0;
  integer from_bypass=0, pairs=0;
  integer i,k,d,waitc,f0,u0,s0;
  reg [31:0] rd, w0, pd;
  // independent reference RM model (VL index 0x100 only)
  reg m_seen; reg [7:0] m_sn; reg [23:0] m_ts;
  reg m_act, m_fwd, m_skw; reg [23:0] m_d, m_win;
  // IC PSN per net, tracked by the TB plan to know the next legal SN
  integer fwd_of_sn [0:255];

  task bad(input [8*96-1:0] reason);
    begin
      if(errors<16) $display("  [err] T10%0d rm=%0d: %0s",IF_MODE,rm_seen,reason);
      errors=errors+1;
    end
  endtask

  always @(posedge clk) if(!reset) begin
    if(dut.rx_ovf_a||dut.rx_ovf_b) bad("RX FIFO overflow");
    if((dut.rm_dup_fire + dut.ic_rej_fire + dut.flt_free + dut.lookup_drain) > 1)
      bad("two block releases in one cycle on shared free port");
    if(dut.ic_rej_fire) ic_rej=ic_rej+1;
    if(dut.rm_in_vld && dut.rm_in_ready && !dut.ic_to_rm) from_bypass=from_bypass+1;
    if(dut.rm_fire) begin
      rm_seen=rm_seen+1;
      if(dut.rm_out_vl!==12'h100) bad("RM out_vl is not the looked-up index");
      if(dut.rm_out_desc[158:148]!==11'd79) bad("RM descriptor len corrupted");
      w0 = dut.u_rxcfg_rm0.mem[12'h100];  // continue2: RX_VL_CFG w0 replica read by RM
      m_act = dut.ctl_r[3] && w0[30] && (w0[29:28]==2'b11);
      m_win = 24'd4 << w0[27:24];
      m_d = dut.rm_out_desc[147:124] - m_ts;
      if(m_d[23]) m_d = -m_d;
      m_fwd = !(m_act && m_seen && dut.rm_out_desc[107:100]==m_sn && m_d<=m_win);
      m_skw = m_act && m_seen && dut.rm_out_desc[107:100]==m_sn && m_d>m_win;
      if(dut.rm_out_fwd!==m_fwd) bad("RM verdict differs from TB reference model");
      if(dut.rm_out_skew!==m_skw) bad("RM skew event differs from TB model");
      if(m_act && m_fwd) begin
        m_seen=1; m_sn=dut.rm_out_desc[107:100]; m_ts=dut.rm_out_desc[147:124];
      end
      if(dut.rm_out_fwd) begin
        rm_fwd=rm_fwd+1;
        fwd_of_sn[dut.rm_out_desc[107:100]]=fwd_of_sn[dut.rm_out_desc[107:100]]+1;
      end else rm_dup=rm_dup+1;
      if(dut.rm_out_skew) rm_skew=rm_skew+1;
    end
  end

  task host_write(input [15:0] addr,input [31:0] data);
    begin
      @(negedge clk);host_cs=1;host_we=1;host_addr=addr;host_wdata=data;
      @(negedge clk);
      if(host_ack!==1'b1)bad("host write ACK missing");
      host_cs=0;host_we=0;
    end
  endtask
  task host_read(input [15:0] addr,output [31:0] data);
    begin
      @(negedge clk);host_cs=1;host_we=0;host_addr=addr;
      @(negedge clk);
      if(host_ack!==1'b1)bad("host read ACK missing");
      data=host_rdata;host_cs=0;
    end
  endtask

  function [31:0] crc_step(input [31:0] c, input [7:0] b);
    integer j; reg [31:0] x;
    begin
      x=c^{24'd0,b};
      for(j=0;j<8;j=j+1) x=x[0]?((x>>1)^32'hEDB88320):(x>>1);
      crc_step=x;
    end
  endfunction
  // Build frame with SN patched; FCS = zlib crc32 sent low byte first.
  task build(input net, input [7:0] sn);
    integer j; reg [31:0] c; reg [7:0] v;
    begin
      c=32'hFFFFFFFF;
      for(j=0;j<75;j=j+1) begin
        v=(j==74)?sn:base[j];
        if(net) frm_b[j]=v; else frm_a[j]=v;
        c=crc_step(c,v);
      end
      c=~c;
      for(j=0;j<4;j=j+1) begin
        v=c[8*j+:8];
        if(net) frm_b[75+j]=v; else frm_a[75+j]=v;
      end
    end
  endtask
  task drive_a(input integer delay);
    integer b;
    begin
      repeat(delay) @(negedge clk);
      for(b=0;b<79;b=b+1) begin
        @(negedge clk); rx_ready=1;rx_valid=1;rx_data=frm_a[b];
        if(IF_MODE==0) begin @(negedge clk);rx_valid=0; repeat(8) @(negedge clk); end
      end
      @(negedge clk);rx_ready=0;rx_valid=0;
    end
  endtask
  task drive_b(input integer delay);
    integer b;
    begin
      repeat(delay) @(negedge clk);
      for(b=0;b<79;b=b+1) begin
        @(negedge clk); rx_ready_b=1;rx_valid_b=1;rx_data_b=frm_b[b];
        if(IF_MODE==0) begin @(negedge clk);rx_valid_b=0; repeat(8) @(negedge clk); end
      end
      @(negedge clk);rx_ready_b=0;rx_valid_b=0;
    end
  endtask
  // one frame, directed expectation
  // one frame expected to bypass IC (IC_EN=0)
  task wait_init;
    begin
      waitc=0;
      while(dut.init_done!==1 && waitc<26000) begin @(negedge clk);waitc=waitc+1;end
      if(waitc>=26000) bad("INIT_DONE timeout");
    end
  endtask

  // IF_MODE=0 only: B paced with `gap` idle cycles per byte, so it starts
  // first but completes last -> A's descriptor (later first-byte ts) is
  // judged first and B's timestamp is EARLIER than last_ts.
  task drive_b_slow(input integer gap);
    integer b;
    begin
      for(b=0;b<79;b=b+1) begin
        @(negedge clk); rx_ready_b=1;rx_valid_b=1;rx_data_b=frm_b[b];
        @(negedge clk);rx_valid_b=0; repeat(gap) @(negedge clk);
      end
      @(negedge clk);rx_ready_b=0;rx_valid_b=0;
    end
  endtask
  task settle_check;
    begin
      repeat(60) @(negedge clk);
      if(dut.rx_free_map!==16'hFFC0) bad("RX block leaked (conservation)");
    end
  endtask
  task check_ram;
    begin
      if(dut.u_rxrm.rm_mem[12'h100][32]!==m_seen) bad("RM seen bit differs from model");
      if(m_seen && dut.u_rxrm.rm_mem[12'h100]!=={1'b1,m_ts,m_sn})
        bad("RM RAM {last_ts,last_sn} differs from model");
    end
  endtask
  // A/B copies of one SN; a_first selects which net is delayed by `dly`.
  task pair(input [7:0] sn, input integer dly, input a_first,
            input integer exp_f, input integer exp_u);
    begin
      f0=rm_fwd; u0=rm_dup;
      build(0,sn); build(1,sn);
      if(a_first) fork drive_a(0); drive_b(dly); join
      else        fork drive_a(dly); drive_b(0); join
      settle_check; check_ram;
      if(rm_fwd-f0!==exp_f || rm_dup-u0!==exp_u) bad("pair forward/dup count wrong");
      pairs=pairs+1;
    end
  endtask
  // copy on one net, then after `gap` cycles on the other
  task pair_seq(input [7:0] sn, input integer gap, input integer exp_f,
                input integer exp_u, input integer exp_s);
    begin
      f0=rm_fwd; u0=rm_dup; s0=rm_skew;
      build(0,sn); build(1,sn);
      drive_a(0); repeat(gap) @(negedge clk); drive_b(0);
      settle_check; check_ram;
      if(rm_fwd-f0!==exp_f || rm_dup-u0!==exp_u || rm_skew-s0!==exp_s)
        bad("sequential pair forward/dup/skew count wrong");
    end
  endtask
  task single(input net, input [7:0] sn, input integer exp_f);
    begin
      f0=rm_fwd; build(net,sn);
      if(net) drive_b(0); else drive_a(0);
      settle_check; check_ram;
      if(rm_fwd-f0!==exp_f) bad("single frame forward count wrong");
    end
  endtask
  task cfg_mode_on; begin host_write(16'h0008,32'h2000); end endtask
  task run_rm;      begin host_write(16'h0008,32'h051E); end endtask // IC+RM
  task run_normglb; begin host_write(16'h0008,32'h0516); end endtask // RM_EN=0
  task run_noic;    begin host_write(16'h0008,32'h051A); end endtask // IC_EN=0
  task write_vlcfg(input [31:0] w0v);
    begin
      cfg_mode_on; host_write(16'h1F80,w0v); host_write(16'h1F81,32'h0000_0100);
    end
  endtask
  task boot;
    begin
      wait_init;
      if(dut.u_rxrm.rm_mem[12'h100]!==33'd0 || dut.u_rxrm.rm_mem[4095]!==33'd0 ||
         dut.u_rxrm.rm_mem[0]!==33'd0)
        bad("init sweep did not clear RM RAM / seen");
      m_seen=0; m_sn=0; m_ts=0;
      cfg_mode_on;
      host_write(16'h0078,32'h172D);
      host_write(16'h007C,32'hAB61);
      host_write(16'h42B2,32'h1010_0100);   // VLID 0x0100 -> idx 0x100
      host_write(16'h0080,32'h1);
    end
  endtask

  initial begin
    $readmemh("vec/t08a_frames.hex",vec);
    if(vec[0]!==22 || vec[37][15:0]!==79 || vec[37][31:24]!==2)
      bad("t08a real frame vector missing or shifted");
    for(i=0;i<79;i=i+1) begin
      rd=vec[37+2+(i>>2)];
      case(i&3) 0: base[i]=rd[31:24]; 1: base[i]=rd[23:16];
                2: base[i]=rd[15:8]; default: base[i]=rd[7:0]; endcase
    end
    if(base[74]!==8'd1) bad("base frame SN byte not at offset 74");
    build(0,8'd1);
    for(i=75;i<79;i=i+1) if(frm_a[i]!==base[i]) bad("TB CRC32 disagrees with vector FCS");
    for(i=0;i<256;i=i+1) fwd_of_sn[i]=0;
    repeat(7) @(negedge clk);reset=0;
    boot;
    // ---- 1. first frame SN=0 right after init, SkewMax 131 ms (exp=15) ----
    write_vlcfg(W0_RM | (32'd15<<24)); run_rm;
    pair(8'd0,3,1,1,1);
    // ---- 2. exp=5 (128 us): A-first and B-first pairs, skew 0..9 cycles ----
    write_vlcfg(W0_RM | (32'd5<<24)); run_rm;
    for(d=0;d<10;d=d+1) pair(8'd1+d[7:0],d,1,1,1);        // SN 1..10
    for(d=0;d<10;d=d+1) pair(8'd11+d[7:0],d,0,1,1);       // SN 11..20
    // sequential copies inside SkewMax (1000 cycles ~ 8 us) -> dup
    pair_seq(8'd21,1000,1,1,0);
    // ---- 3. exp=0 (4 us): copies 8 us apart -> both forward + skew event ----
    write_vlcfg(W0_RM | (32'd0<<24)); run_rm;
    pair_seq(8'd22,1000,2,0,1);
    pair(8'd23,0,1,1,1);                                  // same-time still dup
    // ---- 4. IC-rejected frame must not write RM (pollution check) ----
    write_vlcfg(W0_RM | (32'd5<<24)); run_rm;
    single(1,8'd24,1); single(1,8'd25,1);     // B psn 25, A psn 23, RM last 25
    single(0,8'd26,0);                        // A 23 -> 26: IC reject
    if(ic_rej!==1) bad("pollution probe was not IC-rejected");
    single(1,8'd26,1);                        // must forward (not a dup of A)
    // A catches up 24/25/26.  RM keeps only the LAST forwarded SN (7.11), so
    // a late copy older than last_sn, or arriving after that, is forwarded
    // again; the model predicts the same (documented limitation).
    single(0,8'd24,1); single(0,8'd25,1); single(0,8'd26,1);
    // ---- 5. CTL.RM_EN=0 and VL rm_en=0: both copies forward, RAM frozen ----
    run_normglb;
    pair(8'd27,2,1,2,0);
    write_vlcfg(32'hB000_0000 | (32'd5<<24) | 32'd79); run_rm;   // rm_en=0
    pair(8'd28,2,0,2,0);
    // ---- 6. IC_EN=0 bypass still dedups in RM ----
    write_vlcfg(W0_RM | (32'd5<<24)); run_noic;
    pair(8'd29,4,1,1,1);
    if(from_bypass!==2) bad("IC_EN=0 frames did not enter RM via FLT bypass");
    run_rm;
    for(d=0;d<10;d=d+1) pair(8'd30+d[7:0],d,d[0],1,1);    // SN 30..39
    // ---- 6b. (IF_MODE=0) later-judged copy with EARLIER timestamp: B starts
    // ~5 us before A but ends after it; exp=1 (8 us) -> must still be dup.
    if(IF_MODE==0) begin
      write_vlcfg(W0_RM | (32'd1<<24)); run_rm;
      f0=rm_fwd; u0=rm_dup; build(0,8'd40); build(1,8'd40);
      fork drive_a(625); drive_b_slow(20); join
      settle_check; check_ram;
      if(rm_fwd-f0!==1 || rm_dup-u0!==1) bad("earlier-ts late copy not deduplicated");
      if(m_ts!==dut.u_rxrm.rm_mem[12'h100][31:8] || m_sn!==8'd40)
        bad("A copy was not the one judged first");
      pairs=pairs+1;
    end else begin
      single(0,8'd40,1); single(1,8'd40,0);
    end
    // ---- 7. exactly-once delivery per SN and counters ----
    for(i=0;i<41;i=i+1) begin
      k=(i==22||i==24||i==25||i==26||i==27||i==28)?2:1;
      if(fwd_of_sn[i]!==k) bad("SN delivered wrong number of times");
    end
    host_read(16'h004C,rd); if(rd!==rm_dup) bad("DROP_CNT_K rm mismatch");
    host_read(16'h0048,rd); if(rd!==ic_rej) bad("DROP_CNT_K ic mismatch");
    // v0.5.16: forwarded frames reach parse; no RX port configured -> port drop.
    host_read(16'h0101,pd); if(pd!==dut.rm_fwd_cnt) bad("port drops != RM forwards (no port configured)");
    host_read(16'h001C,rd); if(rd!==rm_dup+ic_rej+pd) bad("DROP_CNT total != IC+RM+port drops");
    if(dut.rm_fwd_cnt!==rm_fwd || dut.rm_skew_cnt!==rm_skew) bad("RM internal counters wrong");
    // ---- 8. reset clears RM RAM, seen bitmap and counters ----
    @(negedge clk);reset=1;repeat(6) @(negedge clk);reset=0;
    boot;
    host_read(16'h004C,rd); if(rd!==32'd0) bad("RM drop counter not cleared");
    host_read(16'h001C,rd); if(rd!==32'd0) bad("DROP_CNT not cleared");
    write_vlcfg(W0_RM | (32'd15<<24)); run_rm;
    pair(8'd1,0,1,1,1);                       // fresh state after reset
    if(errors==0)
      $display("T10 TOP RM PASS (IF_MODE=%0d rm=%0d fwd=%0d dup=%0d skew=%0d pairs=%0d ic_rej=%0d bypass=%0d first0/window/disable/pollution/reset ok)",
        IF_MODE,rm_seen,rm_fwd,rm_dup,rm_skew,pairs,ic_rej,from_bypass);
    else $display("T10 TOP RM FAIL (IF_MODE=%0d errors=%0d)",IF_MODE,errors);
    $finish;
  end
  initial begin
    #60_000_000;
    $display("T10 TOP RM FAIL: timeout IF_MODE=%0d rm=%0d",IF_MODE,rm_seen);
    $finish;
  end
endmodule
module tb_t10_top_rm;  tb_t10_core #(.IF_MODE(0)) core(); endmodule
module tb_t10g_top_rm; tb_t10_core #(.IF_MODE(1)) core(); endmodule
