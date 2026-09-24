// T08e: top-level RX integrity check (rx_ic wired after rx_flt, v0.5.14).
// Real 79 B model/zlib frame (t08a case 2, VLID 0x0100 -> idx 0x100) with
// the SN byte (offset 74) patched and FCS recomputed in the TB.  Frames run
// mac_rx_if -> lookup -> FLT -> IC inside AFDX_top.  Checks:
//   * directed IC verdict + reason per frame (strict first frame, OK, dup,
//     lost-one, lost-two, backwards, SN=0 reset, A/B independent PSN,
//     wrap 254 -> 1 as lost-one, IC_FIRST_ANY=1, CTL.IC_EN=0 bypass);
//   * an independent TB PSN model re-derives every IC output;
//   * PSN RAM contents (unique RAM inside u_rxic) for both nets;
//   * RX_EN stop sweep 13 skews x 13 offsets (drain vs IC/RM output);
//   * A/B near-simultaneous frames at 0..9 cycle skew, with the B frame
//     either IC-accepted or FLT-rejected, so FLT reject / IC output / free
//     port contention is exercised; block conservation after every frame;
//   * DROP_CNT(0x1C) = FLT + IC drops, DROP_CNT_K ic(0x48), reset clearing.
// v0.5.15: IC-accepted frames continue into rx_rm (VL rm_en=0 here, so RM
// forwards them); parse/port are still shells, the block is then recycled.  This is NOT a full T08/T22.
`timescale 1 ns / 1 ps
module tb_t08e_core #(parameter integer IF_MODE=0);
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

  localparam [2:0] R_OK=0,R_RESET=1,R_LOST1=2,R_FANY=3,R_FFAIL=4,R_OOO=5;
  localparam [12:0] ADDR_A=13'h0100, ADDR_B=13'h1100;
  reg [31:0] vec [0:1144];
  reg [7:0] base [0:78];
  reg [7:0] frm_a [0:78];
  reg [7:0] frm_b [0:78];
  integer errors=0, ic_seen=0, ic_acc=0, ic_rej=0, flt_rej=0, drain_ic_overlap=0;
  integer i,k,d,waitc,sn_next;
  reg [31:0] rd;
  // directed expectation for the NEXT IC output (sequential sends only)
  reg exp_active=0, exp_acc=0;
  reg [2:0] exp_reason=0;
  reg [7:0] exp_sn=0;
  reg exp_net=0;
  // independent reference PSN model (index 0x100 only is used)
  reg [7:0] m_psn [0:1];
  reg m_acc; reg [2:0] m_rsn; reg [7:0] m_e1, m_e2, m_p, m_s;

  task bad(input [8*96-1:0] reason);
    begin
      if(errors<16) $display("  [err] T08e%0d ic=%0d: %0s",IF_MODE,ic_seen,reason);
      errors=errors+1;
    end
  endtask

  always @(posedge clk) if(!reset) begin
    if(dut.rx_ovf_a||dut.rx_ovf_b) bad("RX FIFO overflow");
    if(dut.flt_out_vld && dut.flt_out_ready && !dut.flt_out_pass) flt_rej=flt_rej+1;
    // coverage: a queued descriptor waits for drain while IC/RM is emitting
    if(!dut.rx_stream_en && (dut.ic_out_vld || dut.rm_out_vld) &&
       (dut.rx_desc_valid_a || dut.rx_desc_valid_b)) drain_ic_overlap=drain_ic_overlap+1;
    // at most one block release source per cycle on the shared free port
    if((dut.rm_out_vld + dut.ic_rej_fire + dut.flt_free + dut.lookup_drain) > 1)
      bad("two block releases in one cycle on shared free port");
    // v0.5.15: an IC-accepted output may wait for rx_rm; count handshakes.
    if(dut.ic_fire) begin
      ic_seen=ic_seen+1;
      if(dut.ic_out_accept) ic_acc=ic_acc+1; else ic_rej=ic_rej+1;
      if(dut.ic_out_vl!==12'h100) bad("IC out_vl is not the looked-up index");
      if(dut.ic_out_desc[158:148]!==11'd79) bad("IC descriptor len corrupted");
      // reference model, same rule as design doc 7.10 / afdx_model.ic_decide
      m_p=m_psn[dut.ic_out_desc[99]]; m_s=dut.ic_out_desc[107:100];
      m_e1=(m_p==8'd255)?8'd1:m_p+8'd1;
      m_e2=(m_p>=8'd254)?m_p-8'd253:m_p+8'd2;
      if(m_s==0) begin m_acc=1; m_rsn=R_RESET; end
      else if(m_p==0) begin
        m_acc=(m_s==1)||dut.udp_cfg_r[0];
        m_rsn=(m_s==1)?R_OK:(dut.udp_cfg_r[0]?R_FANY:R_FFAIL);
      end else if(m_s==m_e1) begin m_acc=1; m_rsn=R_OK; end
      else if(m_s==m_e2) begin m_acc=1; m_rsn=R_LOST1; end
      else begin m_acc=0; m_rsn=R_OOO; end
      if(dut.ic_out_accept!==m_acc || dut.ic_out_reason!==m_rsn)
        bad("IC verdict differs from TB reference model");
      if(m_acc) m_psn[dut.ic_out_desc[99]]=m_s;
      if(exp_active) begin
        if(dut.ic_out_desc[99]!==exp_net || dut.ic_out_desc[107:100]!==exp_sn)
          bad("IC output is not the frame just sent");
        if(dut.ic_out_accept!==exp_acc) bad("directed IC accept/reject wrong");
        if(dut.ic_out_reason!==exp_reason) bad("directed IC reason wrong");
        exp_active=0;
      end
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
  task drive_a;
    integer b;
    begin
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
  task settle_check;
    begin
      repeat(40) @(negedge clk);
      if(dut.rx_free_map!==16'hFFC0) bad("RX block leaked (conservation)");
    end
  endtask
  // one frame, directed expectation
  task send(input net,input [7:0] sn,input acc,input [2:0] reason);
    integer n0;
    begin
      build(net,sn); n0=ic_seen;
      exp_net=net; exp_sn=sn; exp_acc=acc; exp_reason=reason; exp_active=1;
      if(net) drive_b(0); else drive_a;
      settle_check;
      if(exp_active) begin bad("frame produced no IC verdict"); exp_active=0; end
      if(ic_seen!==n0+1) bad("frame produced more than one IC verdict");
    end
  endtask
  // one frame expected to bypass IC (IC_EN=0)
  task send_bypass(input net,input [7:0] sn);
    integer n0;
    begin
      build(net,sn); n0=ic_seen;
      if(net) drive_b(0); else drive_a;
      settle_check;
      if(ic_seen!==n0) bad("IC_EN=0 frame still entered IC");
    end
  endtask
  task check_psn(input [7:0] a, input [7:0] b);
    begin
      if(dut.u_rxic.psn_mem[ADDR_A]!==a) bad("PSN RAM net A value wrong");
      if(dut.u_rxic.psn_mem[ADDR_B]!==b) bad("PSN RAM net B value wrong");
      if(m_psn[0]!==a || m_psn[1]!==b) bad("TB model PSN diverged from directed plan");
    end
  endtask
  task cfg_mode_on;  begin host_write(16'h0008,32'h2000); end endtask
  task run_ic;       begin host_write(16'h0008,32'h051E); end endtask // IC_EN=1
  task run_noic;     begin host_write(16'h0008,32'h051A); end endtask // IC_EN=0
  task write_vlcfg(input [31:0] w0,input [31:0] w1);
    begin host_write(16'h1F80,w0); host_write(16'h1F81,w1); end
  endtask
  task wait_init;
    begin
      waitc=0;
      while(dut.init_done!==1 && waitc<26000) begin @(negedge clk);waitc=waitc+1;end
      if(waitc>=26000) bad("INIT_DONE timeout");
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
    // self-check TB CRC against the vector's own FCS (SN=1 unchanged)
    build(0,8'd1);
    for(i=75;i<79;i=i+1) if(frm_a[i]!==base[i]) bad("TB CRC32 disagrees with vector FCS");
    m_psn[0]=0; m_psn[1]=0;
    repeat(7) @(negedge clk);reset=0;
    wait_init;
    if(dut.u_rxic.psn_mem[ADDR_A]!==8'd0 || dut.u_rxic.psn_mem[8191]!==8'd0)
      bad("init sweep did not clear IC PSN RAM");
    cfg_mode_on;
    host_write(16'h0078,32'h172D);
    host_write(16'h007C,32'hAB61);
    host_write(16'h42B2,32'h1010_0100);   // VLID 0x0100 -> idx 0x100
    host_write(16'h0080,32'h1);
    write_vlcfg(32'hB000_0000|32'd79,32'h0000_0100); // valid,net=11,lmax=79
    run_ic;
    // ---- 1. strict first frame, sequencing, loss, duplicates ----
    send(0,8'd5,0,R_FFAIL);  check_psn(0,0);
    send(0,8'd1,1,R_OK);     check_psn(1,0);
    send(0,8'd2,1,R_OK);
    send(0,8'd2,0,R_OOO);    // duplicate
    send(0,8'd4,1,R_LOST1);  check_psn(4,0);
    send(0,8'd7,0,R_OOO);    // lost two
    send(0,8'd3,0,R_OOO);    // backwards
    send(1,8'd1,1,R_OK);     check_psn(4,1);   // B independent of A
    send(0,8'd5,1,R_OK);     check_psn(5,1);   // B did not disturb A
    send(0,8'd0,1,R_RESET);  check_psn(0,1);   // SN=0 re-arms
    send(0,8'd6,0,R_FFAIL);  check_psn(0,1);   // strict after reset
    // ---- 2. wrap on B: 2..254, then 1 (lost 255, exp2 wraps), then 2 ----
    for(k=2;k<=254;k=k+1) send(1,k[7:0],1,R_OK);
    check_psn(0,254);
    send(1,8'd1,1,R_LOST1);  check_psn(0,1);
    send(1,8'd2,1,R_OK);     check_psn(0,2);
    // ---- 3. IC_FIRST_ANY=1 (UDP_CFG[0]) ----
    host_write(16'h0070,32'h0000_0143);
    send(0,8'd9,1,R_FANY);   check_psn(9,2);
    send(0,8'd10,1,R_OK);
    host_write(16'h0070,32'h0000_0142);
    // ---- 4. CTL.IC_EN=0 bypass: no PSN read/write, block still recycled ----
    run_noic;
    send_bypass(0,8'd99);
    send_bypass(1,8'd77);
    check_psn(10,2);
    run_ic;
    send(0,8'd11,1,R_OK);    check_psn(11,2);
    // ---- 5. A/B skew sweep, both PASS -> both through IC ----
    sn_next=12;
    for(d=0;d<10;d=d+1) begin
      build(0,sn_next[7:0]); build(1,8'd3+d[7:0]);
      fork drive_a; drive_b(d); join
      settle_check;
      sn_next=sn_next+1;
    end
    check_psn(8'd21,8'd12);
    // ---- 6. A/B skew sweep, B FLT-rejected (net A-only) while A in IC ----
    cfg_mode_on;
    write_vlcfg(32'h9000_0000|32'd79,32'h0000_0100); // net=01 A-only
    run_ic;
    for(d=0;d<10;d=d+1) begin
      build(0,sn_next[7:0]); build(1,8'd13);
      fork drive_a; drive_b(d); join
      settle_check;
      sn_next=sn_next+1;
    end
    check_psn(8'd31,8'd12);
    // ---- 7. counters ----
    // IC rejects in step 1: 5 (FFAIL, dup, lost2, back, FFAIL).
    if(ic_rej!==5) bad("IC reject histogram wrong");
    if(ic_acc!==dut.ic_accept_cnt) bad("ic_accept_cnt mismatch");
    if(flt_rej!==10) bad("FLT reject count (NET) wrong");
    host_read(16'h0048,rd); if(rd!==32'd5)  bad("DROP_CNT_K ic mismatch");
    host_read(16'h0040,rd); if(rd!==32'd10) bad("DROP_CNT_K unconf mismatch");
    host_read(16'h001C,rd); if(rd!==32'd15) bad("DROP_CNT total != FLT+IC");
    // ---- 7b. RX_EN drop sweep: stop the stream t cycles after A enters IC
    // while B (skew d) is finishing, so a queued B descriptor is drained
    // around A's IC output cycle (shared free port).  Outcome per frame may
    // be drain / FLT reject / truncation; only conservation + model are
    // asserted, and counters must stay consistent with what was observed.
    // d up to 12 so B completes while A is already in RM (drain vs RM out).
    for(d=0;d<13;d=d+1) for(k=0;k<13;k=k+1) begin
      build(0,sn_next[7:0]); build(1,8'd13);
      fork
        drive_a;
        drive_b(d);
        begin
          @(posedge clk); while(!(dut.ic_in_vld && dut.ic_in_ready)) @(posedge clk);
          repeat(k) @(negedge clk);
          cfg_mode_on;
        end
      join
      settle_check;
      if(m_psn[0]===sn_next[7:0]) sn_next=sn_next+1;
      else bad("A frame lost in RX_EN sweep");
      run_ic;
    end
    if(drain_ic_overlap==0) bad("sweep never overlapped drain with IC output window");
    host_read(16'h0048,rd); if(rd!==ic_rej)  bad("DROP_CNT_K ic != observed after sweep");
    host_read(16'h0040,rd); if(rd!==flt_rej) bad("DROP_CNT_K unconf != observed after sweep");
    host_read(16'h001C,rd); if(rd!==ic_rej+flt_rej) bad("DROP_CNT total != observed after sweep");
    // ---- 8. reset clears IC state, counters and PSN RAM ----
    @(negedge clk);reset=1;repeat(6) @(negedge clk);reset=0;
    wait_init;
    if(dut.u_rxic.psn_mem[ADDR_A]!==8'd0 || dut.u_rxic.psn_mem[ADDR_B]!==8'd0)
      bad("PSN RAM not cleared by re-init sweep");
    host_read(16'h0048,rd); if(rd!==32'd0) bad("IC drop counter not cleared");
    host_read(16'h001C,rd); if(rd!==32'd0) bad("DROP_CNT not cleared");
    if(errors==0)
      $display("T08e TOP IC PASS (IF_MODE=%0d ic=%0d accept=%0d reject=%0d flt_reject=%0d drain_overlap=%0d skew=0..9 rxen_sweep=169 wrap/first_any/bypass/reset ok)",
        IF_MODE,ic_seen,ic_acc,ic_rej,flt_rej,drain_ic_overlap);
    else $display("T08e TOP IC FAIL (IF_MODE=%0d errors=%0d)",IF_MODE,errors);
    $finish;
  end
  initial begin
    #60_000_000;
    $display("T08e TOP IC FAIL: timeout IF_MODE=%0d ic=%0d",IF_MODE,ic_seen);
    $finish;
  end
endmodule
module tb_t08e_top_ic;  tb_t08e_core #(.IF_MODE(0)) core(); endmodule
module tb_t08eg_top_ic; tb_t08e_core #(.IF_MODE(1)) core(); endmodule
