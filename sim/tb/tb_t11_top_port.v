// T11: top-level RX delivery to host ports (v0.5.16): lookup -> FLT -> IC ->
// RM -> rx_ip_udp_parse -> rx_port_buf, plus host readback over the front door.
// Real 79 B model/zlib frame (t08a case 2, VLID 0x0100, L=32 payload bytes);
// SN and payload marker patched, FCS recomputed, UDP checksum check disabled.
// Checks (every step: PORT_DESC fields, MSG_CNT, payload bytes read back from
// PMEM at run time vs the frame actually sent, held-block map, conservation):
//   * sampling port: A/B copies delivered exactly once; fresh read-clear;
//     MSG_RD release; overwrite (ovf, OVR stat, old block recycled);
//     overwrite after the host read the descriptor keeps the old block pinned
//     and intact until MSG_RD; second overwrite releases the older pin;
//   * queue port depth 3: FIFO order, overflow drops (Q_OVF stat, DROP_CNT),
//     fresh after pop, cnt;
//   * parse drops: UDP dst-port mismatch, TX-direction port, unconfigured
//     port, port_base out of range, enabled SAP -> management handoff (detailed T23);
//   * MSG_RD to a non-RX port and TX MSG_WR to an RX port set ERR.ACC;
//   * reset clears port state and statistics.
// This is NOT T22 (no TX/RX cold-start loop) SAP detailed checks are in T23.
`timescale 1 ns / 1 ps
module tb_t11_core #(parameter integer IF_MODE=0);
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

  localparam integer P = 5;                         // RX port under test
  localparam [15:0] PT = 16'h7D80 + 4*P;            // port table entry
  localparam [31:0] W0_VL = 32'hF500_0000 | (P<<12) | 32'd79; // rm,net11,exp5
  reg [31:0] vec [0:1144];
  reg [7:0] base [0:78];
  reg [7:0] frm_a [0:78];
  reg [7:0] frm_b [0:78];
  integer errors=0, i, k, waitc, deliveries=0, drops_seen=0;
  integer exp_dup=0, exp_qovf=0, exp_pdrop=0, exp_ovr=0, exp_deliv=0;
  reg [31:0] rd, w;
  reg [15:0] dport;
  reg [3:0] b_old, b_new;
  reg [7:0] sn_a, sn_b;        // next SN per net (IC strict sequence)

  task bad(input [8*96-1:0] reason);
    begin
      if(errors<20) $display("  [err] T11%0d t=%0t: %0s",IF_MODE,$time,reason);
      errors=errors+1;
    end
  endtask
  always @(posedge clk) if(!reset) begin
    if(dut.rx_ovf_a||dut.rx_ovf_b) bad("RX FIFO overflow");
    if((dut.rm_dup_fire + dut.ic_rej_fire + dut.flt_free + dut.lookup_drain) > 1)
      bad("two block releases in one cycle on shared free port");
    if(dut.pb_free0 && dut.pb_free1 && dut.pb_free0_id==dut.pb_free1_id)
      bad("port buffer released the same block twice");
    if(dut.prs_to_port && dut.pb_in_ready) begin
      if(dut.prs_out_drop) drops_seen=drops_seen+1; else deliveries=deliveries+1;
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
  // Build frame: SN (byte 74) and payload marker bytes 42/43 patched, FCS
  // recomputed (UDP checksum disabled in this test via UDP_CFG[1]=0).
  task build(input net, input [7:0] sn, input [7:0] mk);
    integer j; reg [31:0] c; reg [7:0] v;
    begin
      c=32'hFFFFFFFF;
      for(j=0;j<75;j=j+1) begin
        v=(j==74)?sn:(j==42)?mk:(j==43)?~mk:base[j];
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

  function integer popc(input [15:0] m);
    integer j; begin popc=0; for(j=0;j<16;j=j+1) popc=popc+m[j]; end
  endfunction
  // number of RX blocks held (by ports or pins) must equal `n` once idle
  task settle(input integer n);
    begin
      repeat(80) @(negedge clk);
      if(popc(dut.rx_free_map)!==10-n) bad("held RX block count wrong (conservation)");
    end
  endtask
  task cfg_mode_on; begin host_write(16'h0008,32'h2000); end endtask
  task run_on;      begin host_write(16'h0008,32'h051E); end endtask
  task set_port(input [31:0] w0v, input [31:0] w1v, input [31:0] w3v);
    begin
      cfg_mode_on;
      host_write(PT,w0v); host_write(PT+1,w1v); host_write(PT+2,32'd0); host_write(PT+3,w3v);
      run_on;
    end
  endtask
  task set_vl(input [31:0] w0v);
    begin cfg_mode_on; host_write(16'h1F80,w0v); host_write(16'h1F81,32'h0000_0100); run_on; end
  endtask
  // A/B copies of the next SN (both nets in step) -> one delivery, one RM dup
  task pair(input [7:0] mk);
    begin
      build(0,sn_a,mk); build(1,sn_b,mk);
      fork drive_a(0); drive_b(3); join
      sn_a=sn_a+1; sn_b=sn_b+1; exp_dup=exp_dup+1;
    end
  endtask
  task read_desc(output [31:0] d); begin host_read(16'h8180+P,d); end endtask
  task check_desc(input [31:0] d, input v, input f, input o, input pn,
                  input [3:0] cnt);
    begin
      if(d[31]!==v)  bad("PORT_DESC valid wrong");
      if(d[30]!==f)  bad("PORT_DESC fresh wrong");
      if(d[29]!==o)  bad("PORT_DESC ovf wrong");
      if(d[28]!==pn) bad("PORT_DESC pin wrong");
      if(d[27:24]!==cnt) bad("PORT_DESC cnt wrong");
      if(v && d[10:0]!==11'd32) bad("PORT_DESC payload length wrong");
      if(!v && d[10:0]!==11'd0) bad("PORT_DESC length not 0 when empty");
      if(v && (d[23:20]<4'd6)) bad("PORT_DESC block outside RX pool");
    end
  endtask
  // read the 32 payload bytes from PMEM block `blk` and compare to marker mk
  task check_payload(input [3:0] blk, input [7:0] mk);
    integer j; reg [7:0] got, want;
    begin
      for(j=40;j<76;j=j+4) begin
        host_read(16'h8800 + {blk,9'd0} + (j>>2), w);
        for(k=0;k<4;k=k+1) if(j+k>=42 && j+k<74) begin
          got=w[31-8*k -: 8];
          want=(j+k==42)?mk:(j+k==43)?~mk:base[j+k];
          if(got!==want) bad("payload byte read back from PMEM differs from frame");
        end
      end
    end
  endtask
  task msg_rd; begin host_write(16'h8380+P,32'd0); end endtask
  task msg_cnt(input [3:0] n);
    begin host_read(16'h8480+P,rd); if(rd!=={28'd0,n}) bad("MSG_CNT wrong"); end
  endtask
  task boot;
    begin
      wait_init;
      if(dut.u_rxpb.p_cnt[P]!==4'd0 || dut.u_rxpb.p_cnt[255]!==4'd0)
        bad("init sweep did not clear RX port state");
      cfg_mode_on;
      host_write(16'h0078,32'h172D);
      host_write(16'h007C,32'hAB61);
      host_write(16'h42B2,32'h1010_0100);   // VLID 0x0100 -> idx 0x100
      host_write(16'h0080,32'h1);
      host_write(16'h0070,32'h0000_0140);   // UDP checksum check off (payload patched)
      host_write(16'h1F80,W0_VL); host_write(16'h1F81,32'h0000_0100);
      sn_a=1; sn_b=1;
    end
  endtask
  task check_err_acc(input exp);
    begin
      host_read(16'h0010,rd);
      if(rd[0]!==exp) bad("ERR.ACC state wrong");
      host_write(16'h0010,32'hFFFF_FFFF);
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
    dport={base[36],base[37]};
    if({base[38],base[39]}!==16'd40) bad("base frame UDP length is not 8+32");
    repeat(7) @(negedge clk);reset=0;
    boot;
    // ================= 1. sampling port, basic delivery ====================
    set_port(32'h8004_0000, {16'd0,dport}, 32'd1);   // valid, RX, sampling
    check_err_acc(0);
    pair(8'h11); settle(1); exp_deliv=exp_deliv+1;
    read_desc(rd); check_desc(rd,1,1,0,0,1); b_old=rd[23:20];
    check_payload(b_old,8'h11);
    msg_cnt(1);
    read_desc(rd); check_desc(rd,1,0,0,0,1);       // fresh cleared by read
    msg_rd; settle(0);
    read_desc(rd); check_desc(rd,0,0,0,0,0);
    msg_cnt(0);
    // ================= 2. overwrite of an unseen message ===================
    pair(8'h22); pair(8'h33); settle(1); exp_deliv=exp_deliv+2; exp_ovr=exp_ovr+1;
    read_desc(rd); check_desc(rd,1,1,1,0,1);
    check_payload(rd[23:20],8'h33);
    read_desc(rd); check_desc(rd,1,0,0,0,1);       // ovf cleared by read too
    msg_rd; settle(0);
    // ================= 3. overwrite after descriptor read -> pin ============
    pair(8'h44); settle(1); exp_deliv=exp_deliv+1;
    read_desc(rd); b_old=rd[23:20];                // host starts reading 0x44
    pair(8'h55); settle(2); exp_deliv=exp_deliv+1; exp_ovr=exp_ovr+1;
    if(dut.rx_free_map[b_old]!==1'b0) bad("pinned block returned to pool early");
    check_payload(b_old,8'h44);                    // old payload still intact
    msg_rd; settle(1);                             // frees only the pin
    read_desc(rd); check_desc(rd,1,1,1,0,1); check_payload(rd[23:20],8'h55);
    msg_rd; settle(0);
    // second overwrite while a pin exists releases the older pin
    pair(8'h66); settle(1); exp_deliv=exp_deliv+1;
    read_desc(rd); b_old=rd[23:20];                // seen 0x66
    pair(8'h77); settle(2); exp_deliv=exp_deliv+1; exp_ovr=exp_ovr+1;  // pin 0x66
    read_desc(rd); check_desc(rd,1,1,1,1,1); b_new=rd[23:20];           // seen 0x77
    pair(8'h88); settle(2); exp_deliv=exp_deliv+1; exp_ovr=exp_ovr+1;  // 0x66 freed, pin 0x77
    if(dut.rx_free_map[b_old]!==1'b1) bad("older pin not released by second overwrite");
    if(dut.rx_free_map[b_new]!==1'b0) bad("newer pinned block released");
    check_payload(b_new,8'h77);
    msg_rd; settle(1);
    read_desc(rd); check_desc(rd,1,1,1,0,1); check_payload(rd[23:20],8'h88);
    msg_rd; settle(0);
    // ================= 4. queue port, depth 3 ==============================
    set_port(32'h8005_0000, {16'd0,dport}, 32'd3);   // valid, RX, queue
    // A/B pairs keep both IC sequences in step (a rejected jump would leave
    // net B out of sequence for the rest of the run).
    for(i=0;i<5;i=i+1) begin pair(8'hA0+i[7:0]); repeat(20) @(negedge clk); end
    settle(3); exp_deliv=exp_deliv+3; exp_qovf=exp_qovf+2;
    msg_cnt(3);
    for(i=0;i<3;i=i+1) begin
      read_desc(rd); check_desc(rd,1,1,(i==0),0,3-i);
      check_payload(rd[23:20],8'hA0+i[7:0]);
      read_desc(rd); if(rd[30]!==1'b0) bad("queue fresh not cleared by read");
      msg_rd; settle(2-i);
    end
    read_desc(rd); check_desc(rd,0,0,0,0,0); msg_cnt(0);
    msg_rd; settle(0);                             // MSG_RD on empty queue: no-op
    // dual-net pairs into the queue still deliver once each
    pair(8'hB1); pair(8'hB2); settle(2); exp_deliv=exp_deliv+2;
    read_desc(rd); check_payload(rd[23:20],8'hB1); msg_rd;
    read_desc(rd); check_payload(rd[23:20],8'hB2); msg_rd; settle(0);
    // ================= 5. parse drops ======================================
    set_port(32'h8004_0000, {16'd0,dport^16'h0001}, 32'd1);  // dport mismatch
    pair(8'hC1); settle(0); exp_pdrop=exp_pdrop+1;
    set_port(32'h8000_0000, {16'd0,dport}, 32'd1);           // TX direction
    pair(8'hC2); settle(0); exp_pdrop=exp_pdrop+1;
    set_port(32'h8006_0000, {16'd0,dport}, 32'd1);           // SAP -> management, auto-return
    pair(8'hC3); settle(0);
    set_port(32'h0004_0000, {16'd0,dport}, 32'd1);           // valid=0
    pair(8'hC4); settle(0); exp_pdrop=exp_pdrop+1;
    set_port(32'h8004_0000, {16'd0,dport}, 32'd1);
    set_vl(32'hF500_0000 | (32'd300<<12) | 32'd79);          // port_base 300
    pair(8'hC5); settle(0); exp_pdrop=exp_pdrop+1;
    set_vl(W0_VL);
    pair(8'hC6); settle(1); exp_deliv=exp_deliv+1;           // back to normal
    read_desc(rd); check_payload(rd[23:20],8'hC6); msg_rd; settle(0);
    // ================= 6. host access errors ===============================
    check_err_acc(0);
    host_write(16'h8380+6,32'd0); check_err_acc(1);          // MSG_RD non-RX port
    host_write(16'h8280+P,32'd32); check_err_acc(1);          // TX MSG_WR to RX port
    host_read(16'h8480+6,rd); if(rd!==32'd0) bad("MSG_CNT of non-RX port not 0");
    // ================= 7. statistics and totals ============================
    // parse->port handshakes: accepted (delivered or queue-full) vs parse drops
    if(deliveries!==exp_deliv+exp_qovf) bad("parse->port accepted count differs from plan");
    if(drops_seen!==exp_pdrop) bad("parse drop events differ from plan");
    host_read(16'h0100,rd); if(rd!==exp_deliv) bad("RX_DELIVER stat wrong");
    host_read(16'h0101,rd); if(rd!==exp_pdrop) bad("PORT_DROP stat wrong");
    host_read(16'h0102,rd); if(rd!==exp_ovr)   bad("OVR stat wrong");
    host_read(16'h0103,rd); if(rd!==exp_qovf)  bad("Q_OVF stat wrong");
    host_read(16'h004C,rd); if(rd!==exp_dup)   bad("DROP_CNT_K rm wrong");
    host_read(16'h0048,rd); if(rd!==32'd0)     bad("unexpected IC reject");
    host_read(16'h001C,rd); if(rd!==exp_dup+exp_pdrop+exp_qovf) bad("DROP_CNT total wrong");
    // ================= 8. reset clears ports and stats =====================
    pair(8'hD1); settle(1);                                   // leave one held
    @(negedge clk);reset=1;repeat(6) @(negedge clk);reset=0;
    boot;
    if(dut.rx_free_map!==16'hFFC0) bad("RX pool not restored by reset");
    host_read(16'h0100,rd); if(rd!==32'd0) bad("RX_DELIVER not cleared by reset");
    set_port(32'h8004_0000, {16'd0,dport}, 32'd1);
    read_desc(rd); check_desc(rd,0,0,0,0,0);
    pair(8'hE1); settle(1);
    read_desc(rd); check_desc(rd,1,1,0,0,1); check_payload(rd[23:20],8'hE1);
    msg_rd; settle(0);
    if(errors==0)
      $display("T11 TOP PORT PASS (IF_MODE=%0d deliver=%0d ovr=%0d qovf=%0d port_drop=%0d rm_dup=%0d sampling/pin/queue/parse-drop/err/reset ok)",
        IF_MODE,exp_deliv,exp_ovr,exp_qovf,exp_pdrop,exp_dup);
    else $display("T11 TOP PORT FAIL (IF_MODE=%0d errors=%0d)",IF_MODE,errors);
    $finish;
  end
  initial begin
    #80_000_000;
    $display("T11 TOP PORT FAIL: timeout IF_MODE=%0d",IF_MODE);
    $finish;
  end
endmodule
module tb_t11_top_port;  tb_t11_core #(.IF_MODE(0)) core(); endmodule
module tb_t11g_top_port; tb_t11_core #(.IF_MODE(1)) core(); endmodule
