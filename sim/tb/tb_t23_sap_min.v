// T23/T23g: enabled SAP port must reach the minimal management handoff,
// expose its descriptor window, and return its RX PMEM block without touching
// rx_port_buf. It does not claim SNMP/TFTP BER parsing or a response path.
`timescale 1 ns / 1 ps
module tb_t23_sap_core #(parameter integer IF_MODE=0);
  localparam integer P_SAP = 5;
  localparam [15:0] PT_SAP = 16'h7D80 + 4*P_SAP;
  localparam [31:0] W0_VL = 32'hF500_0000 | (P_SAP<<12) | 32'd79;
  reg clk=0, reset=1;
  always #4 clk=~clk;
  reg [7:0] rx_data=0,rx_data_b=0;
  reg rx_valid=0,rx_valid_b=0,rx_ready=0,rx_ready_b=0;
  reg host_cs=0,host_we=0;
  reg [15:0] host_addr=0;
  reg [31:0] host_wdata=0;
  wire [31:0] host_rdata;
  wire host_ack;
  AFDX_top #(.IF_MODE(IF_MODE),.FCS_MODE(2)) dut (
    .clk(clk),.reset(reset),.tx_data(),.tx_valid(),.tx_ready(),
    .rx_data(rx_data),.rx_valid(rx_valid),.rx_ready(rx_ready),.rx_error(1'b0),
    .tx_data_b(),.tx_valid_b(),.tx_ready_b(),
    .rx_data_b(rx_data_b),.rx_valid_b(rx_valid_b),.rx_ready_b(rx_ready_b),.rx_error_b(1'b0),
    .host_cs(host_cs),.host_we(host_we),.host_addr(host_addr),
    .host_wdata(host_wdata),.host_rdata(host_rdata),.host_ack(host_ack),
    .host_irq(),.pps_in(1'b0),.pps_out(),.rtc_time_us(),.dbg_frame_event());
  localparam [15:0] PT_SAMPLE0 = 16'h7D80 + 4*6;
  localparam [15:0] PT_SAMPLE1 = 16'h7D80 + 4*7;
  localparam [15:0] PORT_DESC0 = 16'h8180 + 6;
  localparam [15:0] PORT_DESC1 = 16'h8180 + 7;
  localparam [15:0] MSG_RD0 = 16'h8380 + 6;
  localparam [15:0] MSG_RD1 = 16'h8380 + 7;
  reg [31:0] vec [0:1144];
  reg [7:0] test_frame [0:63];
  integer errors=0,i,k,b,waitc,blk,sap_fire=0,sap_return=0;
  integer collision_cnt=0, mgmt_wait=0, max_mgmt_wait=0, disabled_sap=0;
  integer reset_base=-1, vec_idx, overlap_cycles=0;
  integer sample_events=0, sap_stream_frames=0, sap_stream_bytes=0, sap_stream_eops=0;
  integer scheduled_release=0;
  reg [3:0] expected_pb1_id=0, expected_mgmt_id=0;
  reg second_in_wire=0, during_pair=0;
  reg [3:0] sap_blk0=0, sap_blk1=0, sample_blk0=0, sample_blk1=0;
  reg [31:0] rd,w;
  reg [31:0] base_mgmt_accept, base_mgmt_free, base_deliver, base_drop, base_total_drop;
  reg [31:0] base_msg_cnt0, base_msg_cnt1;
  task bad;
    input [8*104-1:0] reason;
    begin if(errors<16) $display("  [err] T23%0d: %0s",IF_MODE,reason); errors=errors+1; end
  endtask
  task host_write;
    input [15:0] addr; input [31:0] data;
    begin
      @(negedge clk);host_cs=1;host_we=1;host_addr=addr;host_wdata=data;
      @(negedge clk);if(host_ack!==1'b1) bad("host write ACK missing");host_cs=0;host_we=0;
    end
  endtask
  task host_read;
    input [15:0] addr; output [31:0] data;
    begin
      @(negedge clk);host_cs=1;host_we=0;host_addr=addr;
      @(negedge clk);if(host_ack!==1'b1) bad("host read ACK missing");data=host_rdata;host_cs=0;
    end
  endtask
  function [7:0] frame_byte;
    input integer off; reg [31:0] q;
    begin
      q=vec[3+(off>>2)];
      case(off&3) 0:frame_byte=q[31:24];1:frame_byte=q[23:16];
                   2:frame_byte=q[15:8];default:frame_byte=q[7:0]; endcase
    end
  endfunction
  // The golden vector generator includes case 18: same CRC-checked 64B SAP
  // frame as case 0 but SN=0 (reset sequence). Send it immediately before
  // case 0 (SN=1), rather than repeating the same SN and hiding a drop.
  function [7:0] reset_frame_byte;
    input integer off; reg [31:0] q;
    begin
      q=vec[reset_base+(off>>2)];
      case(off&3) 0:reset_frame_byte=q[31:24];1:reset_frame_byte=q[23:16];
                   2:reset_frame_byte=q[15:8];default:reset_frame_byte=q[7:0]; endcase
    end
  endfunction
  task drive_one_a;
    input integer use_reset_sn;
    begin
      for(b=0;b<64;b=b+1) begin
        @(negedge clk);rx_ready=1;rx_valid=1;
        rx_data=use_reset_sn ? reset_frame_byte(b) : frame_byte(b);
        if(during_pair && !use_reset_sn) second_in_wire=1;
        if(IF_MODE==0) begin @(negedge clk);rx_valid=0;repeat(8) @(negedge clk);end
      end
      @(negedge clk);rx_ready=0;rx_valid=0;
    end
  endtask
  function [31:0] crc_step;
    input [31:0] c; input [7:0] v;
    integer j; reg [31:0] x;
    begin
      x=c^{24'd0,v};
      for(j=0;j<8;j=j+1) x=x[0]?((x>>1)^32'hEDB88320):(x>>1);
      crc_step=x;
    end
  endfunction
  function [31:0] vl_word_for_port;
    input [3:0] p;
    begin vl_word_for_port=32'hF500_0000 | ({28'd0,p}<<12) | 32'd79; end
  endfunction
  task build_test_frame;
    input [7:0] sn;
    integer j; reg [31:0] c;
    begin
      for(j=0;j<60;j=j+1) test_frame[j]=(j==59)?sn:frame_byte(j);
      c=32'hFFFF_FFFF;
      for(j=0;j<60;j=j+1) c=crc_step(c,test_frame[j]);
      c=~c;
      for(j=0;j<4;j=j+1) test_frame[60+j]=c[8*j+:8];
      c=32'hFFFF_FFFF;
      for(j=0;j<64;j=j+1) c=crc_step(c,test_frame[j]);
      if(c!==32'hDEBB_20E3) bad("generated test-frame FCS residue is invalid");
    end
  endtask
  task drive_test_frame;
    begin
      for(b=0;b<64;b=b+1) begin
        @(negedge clk);rx_ready=1;rx_valid=1;rx_data=test_frame[b];
        if(IF_MODE==0) begin @(negedge clk);rx_valid=0;repeat(8) @(negedge clk);end
      end
      @(negedge clk);rx_ready=0;rx_valid=0;
    end
  endtask
  task cfg_vl_port;
    input [3:0] p;
    begin
      host_write(16'h0008,32'h2000);
      host_write(16'h1F80,vl_word_for_port(p));
      host_write(16'h0008,32'h051E);
    end
  endtask
  task check_payload;
    input [3:0] payload_blk;
    integer j, lane; reg [31:0] q;
    begin
      for(j=42;j<50;j=j+1) begin
        host_read(16'h8800+(payload_blk<<9)+(j>>2),q);
        lane=j&3;
        if(q[31-8*lane -: 8]!==frame_byte(j)) bad("host PMEM payload differs from golden frame");
      end
    end
  endtask
  task wait_accept_count;
    input [31:0] target;
    begin
      waitc=0;
      while(dut.mgmt_accept_cnt<target && waitc<10000) begin @(negedge clk);waitc=waitc+1;end
      if(waitc>=10000) bad("SAP accept timeout");
    end
  endtask
  task release_sample_at_sap_copy_end;
    input [15:0] msg_addr;
    input [3:0] sample_blk, sap_blk;
    integer guard, before_collisions;
    begin
      expected_pb1_id=sample_blk; expected_mgmt_id=sap_blk;
      scheduled_release=1; before_collisions=collision_cnt; guard=0;
      while(!(dut.u_mgmt_sap.st==2'd1 && dut.u_mgmt_sap.cap_v &&
              dut.u_mgmt_sap.req_done &&
              dut.u_mgmt_sap.wp >= (dut.u_mgmt_sap.wlast-9'd6)) && guard<300) begin
        @(negedge clk); guard=guard+1;
      end
      if(guard>=300) bad("SAP final-copy scheduling point not reached");
      else begin
        // This host request is asserted on the negedge immediately before the
        // final COPY edge. rx_port_buf registers pb_free1 on that edge; SAP
        // enters STREAM on the same edge, so both real owners free next cycle.
        host_cs=1; host_we=1; host_addr=msg_addr; host_wdata=32'd0;
        @(negedge clk);
        if(host_ack!==1'b1) bad("scheduled MSG_RD ACK missing");
        host_cs=0; host_we=0;
        guard=0;
        while(collision_cnt==before_collisions && guard<20) begin @(negedge clk);guard=guard+1;end
        if(collision_cnt!=before_collisions+1) bad("scheduled real PB1/SAP collision missing");
      end
      scheduled_release=0;
    end
  endtask
  always @(posedge clk) if(!reset) begin
    if(dut.rx_ovf_a||dut.rx_ovf_b) bad("RX FIFO overflow");
    if(dut.pb_ev_sample) sample_events=sample_events+1;
    if(dut.sap_out_vld && dut.sap_out_ready) begin
      if(dut.sap_out_sop) begin
        if(sap_stream_bytes!=0) bad("SAP next SOP before prior payload EOP");
        sap_stream_frames=sap_stream_frames+1;
        sap_stream_bytes=0;
      end
      if(sap_stream_frames==0 || sap_stream_bytes>=8) bad("unexpected SAP payload handshake");
      else if(dut.sap_out_data!==frame_byte(42+sap_stream_bytes)) bad("SAP stream payload differs from golden frame");
      sap_stream_bytes=sap_stream_bytes+1;
      if(dut.sap_out_eop) begin
        if(sap_stream_bytes!=8) bad("SAP EOP length differs from 8-byte payload");
        sap_stream_eops=sap_stream_eops+1;
        sap_stream_bytes=0;
      end
    end
    if(dut.prs_out_vld && dut.prs_out_drop && dut.prs_out_reason==3'd5 && dut.pb_in_ready)
      disabled_sap=disabled_sap+1; // R_SAP must return its block via port-buffer drop
    if(dut.prs_to_sap && dut.sap_in_ready) begin
      if(sap_fire==0) sap_blk0=dut.prs_out_blk;
      if(sap_fire==1) sap_blk1=dut.prs_out_blk;
      sap_fire=sap_fire+1;
    end
    if(dut.mgmt_free_take) sap_return=sap_return+1;
    if(dut.mgmt_free_req) begin
      if(second_in_wire) overlap_cycles=overlap_cycles+1;
      if(!dut.mgmt_free_take) mgmt_wait=mgmt_wait+1;
      else mgmt_wait=0;
      if(mgmt_wait>max_mgmt_wait) max_mgmt_wait=mgmt_wait;
      if(mgmt_wait>1) bad("SAP return starved by ordinary RX frees");
      if(dut.pb_free1) begin
        collision_cnt=collision_cnt+1;
        if(dut.pb_free1_id===dut.mgmt_free_id ||
           dut.rx_free_map[dut.pb_free1_id]!==1'b0 || dut.rx_free_map[dut.mgmt_free_id]!==1'b0)
          bad("collision owners are aliased or not both allocated before free");
        if(scheduled_release && (dut.pb_free1_id!==expected_pb1_id || dut.mgmt_free_id!==expected_mgmt_id))
          bad("collision free IDs do not match the two real owners");
        if(!dut.pool_free_spill || !dut.pool_free_pb1 ||
           !((dut.pool_free_pb1_id==dut.mgmt_free_id && dut.pool_free_spill_id==dut.pb_free1_id) ||
             (dut.pool_free_spill_id==dut.mgmt_free_id && dut.pool_free_pb1_id==dut.pb_free1_id)))
          bad("simultaneous SAP/PB1 return lost a block");
      end
    end
  end
  initial begin
    $readmemh("vec/t08a_frames.hex",vec);
    if(vec[0]!==32'd22 || vec[1][15:0]!==16'd64 || vec[1][23:16]!==8'd0 || vec[2]!==32'h7)
      bad("valid 64B SAP fixture missing");
    vec_idx=1;
    for(i=0;i<22;i=i+1) begin
      if(vec[vec_idx][31:24]==8'd18 && vec[vec_idx][15:0]==16'd64)
        reset_base=vec_idx+2;
      vec_idx=vec_idx+2+(vec[vec_idx][15:0]+3)/4;
    end
    if(reset_base<0 || frame_byte(59)!==8'd1 || reset_frame_byte(59)!==8'd0)
      bad("distinct SN=0/1 golden SAP FCS fixtures missing");
    repeat(7) @(negedge clk);reset=0;
    waitc=0;while(dut.init_done!==1 && waitc<26000) begin @(negedge clk);waitc=waitc+1;end
    if(waitc>=26000) bad("INIT_DONE timeout");
    host_write(16'h0008,32'h2000);
    // Existing T11/T22-known image entry: VLID 0100 maps to RX index 0100.
    host_write(16'h0078,32'h172D);host_write(16'h007C,32'hAB61);
    host_write(16'h42B2,32'h1010_0100);host_write(16'h0080,32'h1);
    host_write(16'h1F80,vl_word_for_port(4'd6));host_write(16'h1F81,32'h0000_0100);
    host_write(PT_SAP,32'h8006_0000);host_write(PT_SAP+1,32'h0000_1388);
    host_write(PT_SAP+2,32'd0);host_write(PT_SAP+3,32'd1);
    host_write(PT_SAMPLE0,32'h8004_0000);host_write(PT_SAMPLE0+1,32'h0000_1388);
    host_write(PT_SAMPLE0+2,32'd0);host_write(PT_SAMPLE0+3,32'd1);
    host_write(PT_SAMPLE1,32'h8004_0000);host_write(PT_SAMPLE1+1,32'h0000_1388);
    host_write(PT_SAMPLE1+2,32'd0);host_write(PT_SAMPLE1+3,32'd1);
    host_read(PT_SAP,rd);if(rd!==32'h8006_0000) bad("SAP port readback mismatch");
    // RX_EN and SNMP_EN are both set in 0x051E; CTL.SNMP_EN gates SAP routing.
    host_write(16'h0008,32'h051E);
    // Baseline counters are captured before any message is injected. First
    // deliver and host-observe two real sampling messages; the blocks remain
    // owned by rx_port_buf while the RX VL entry is changed legally in CFG_MODE.
    host_read(16'hAC10,base_mgmt_accept);host_read(16'hAC11,base_mgmt_free);
    host_read(16'h0100,base_deliver);host_read(16'h0101,base_drop);host_read(16'h001C,base_total_drop);
    host_read(16'h8480+6,base_msg_cnt0);host_read(16'h8480+7,base_msg_cnt1);
    build_test_frame(8'd0);drive_test_frame();
    waitc=0;while(dut.u_rxpb.p_cnt[6]!==4'd1 && waitc<10000) begin @(negedge clk);waitc=waitc+1;end
    if(waitc>=10000) bad("ordinary sample port 6 delivery timeout");
    host_read(PORT_DESC0,rd);
    if(rd[31]!==1'b1 || rd[27:24]!==4'd1 || rd[10:0]!==11'd8) bad("port 6 PORT_DESC invalid");
    sample_blk0=rd[23:20];
    if(sample_blk0<4'd6 || dut.rx_free_map[sample_blk0]!==1'b0 || dut.u_rxpb.p_seen[6]!==1'b1)
      bad("port 6 block ownership/seen did not establish");
    check_payload(sample_blk0);
    host_read(16'h8480+6,rd);if(rd!==base_msg_cnt0+32'd1) bad("port 6 MSG_CNT baseline+delivery wrong");

    cfg_vl_port(4'd7);
    build_test_frame(8'd1);drive_test_frame();
    waitc=0;while(dut.u_rxpb.p_cnt[7]!==4'd1 && waitc<10000) begin @(negedge clk);waitc=waitc+1;end
    if(waitc>=10000) bad("ordinary sample port 7 delivery timeout");
    host_read(PORT_DESC1,rd);
    if(rd[31]!==1'b1 || rd[27:24]!==4'd1 || rd[10:0]!==11'd8) bad("port 7 PORT_DESC invalid");
    sample_blk1=rd[23:20];
    if(sample_blk1<4'd6 || sample_blk1===sample_blk0 || dut.rx_free_map[sample_blk1]!==1'b0 ||
       dut.u_rxpb.p_seen[7]!==1'b1) bad("port 7 block is not a distinct held owner");
    check_payload(sample_blk1);
    host_read(16'h8480+7,rd);if(rd!==base_msg_cnt1+32'd1) bad("port 7 MSG_CNT baseline+delivery wrong");
    if(sample_events!==2 || dut.rx_free_map!==(16'hFFC0 & ~(16'h0001<<sample_blk0) & ~(16'h0001<<sample_blk1)))
      bad("two real sample blocks are not simultaneously held");

    // Preserve the original continuous two-frame SAP wire case and its legal
    // IF_MODE-specific 12-byte inter-frame gap. A separate host thread observes
    // each accept and schedules the corresponding public MSG_RD at final COPY.
    cfg_vl_port(4'd5);
    fork
      begin : sap_wire_pair
        build_test_frame(8'd2);drive_test_frame();
        repeat(IF_MODE==0 ? 120 : 12) @(negedge clk);
        build_test_frame(8'd3);drive_test_frame();
      end
      begin : sap_host_release_pair
        wait_accept_count(base_mgmt_accept+32'd1);
        release_sample_at_sap_copy_end(MSG_RD0,sample_blk0,sap_blk0);
        wait_accept_count(base_mgmt_accept+32'd2);
        release_sample_at_sap_copy_end(MSG_RD1,sample_blk1,sap_blk1);
      end
    join
    waitc=0;
    while((dut.mgmt_free_cnt<base_mgmt_free+32'd2 || sap_stream_eops<2) && waitc<2000) begin
      @(negedge clk);waitc=waitc+1;
    end
    if(waitc>=2000) bad("two SAP returns/EOPs did not complete");
    repeat(40) @(negedge clk);

    host_read(16'hAC10,rd);if(rd!==base_mgmt_accept+32'd2) bad("MGMT accept baseline+2 wrong");
    host_read(16'hAC11,rd);if(rd!==base_mgmt_free+32'd2) bad("MGMT block-return baseline+2 wrong");
    host_read(16'hAC12,rd);
    if(rd[31]!==1'b1 || rd[22:15]!==P_SAP || rd[10:0]!==11'd8 ||
       rd[14:11]!==sap_blk1)
      bad("MGMT descriptor window/latest SAP block wrong");
    blk=rd[14:11];
    host_read(16'hAC13,rd);if(rd!==32'd0) bad("MGMT still busy after return");
    if(sap_fire!==2 || sap_return!==2 || sap_stream_frames!==2 || sap_stream_eops!==2 || sap_stream_bytes!==0)
      bad("SAP pair accept/return/two-stream content accounting wrong");
    if(collision_cnt!==2 || max_mgmt_wait>1)
      bad("exactly two real PB1/SAP collisions or bounded return absent");
    if(dut.u_rxpb.p_cnt[6]!==4'd0 || dut.u_rxpb.p_cnt[7]!==4'd0 ||
       dut.u_rxpb.p_seen[6]!==1'b0 || dut.u_rxpb.p_seen[7]!==1'b0 ||
       dut.rx_free_map!==16'hFFC0)
      bad("sample/SAP owners were not all returned to the RX pool");
    host_read(16'h8480+6,rd);if(rd!==base_msg_cnt0) bad("port 6 MSG_CNT did not return to baseline after MSG_RD");
    host_read(16'h8480+7,rd);if(rd!==base_msg_cnt1) bad("port 7 MSG_CNT did not return to baseline after MSG_RD");
    host_read(16'h8180+P_SAP,rd);
    if(rd[31]!==1'b0 || rd[27:24]!==4'd0 || rd[10:0]!==11'd0)
      bad("SAP incorrectly entered PORT_DESC");
    host_read(16'h8480+P_SAP,rd);if(rd!==32'd0) bad("SAP incorrectly entered MSG_CNT");
    host_read(16'h0100,rd);if(rd!==base_deliver+32'd2) bad("RX delivery baseline+2 wrong");
    host_read(16'h0101,rd);if(rd!==base_drop) bad("enabled SAP/sample unexpectedly became port drop");
    host_read(16'h001C,rd);if(rd!==base_total_drop) bad("enabled SAP/sample unexpectedly became total drop");
    if(dut.rx_free_map!==16'hFFC0 || dut.rx_free_map[sap_blk0]!==1'b1 ||
       dut.rx_free_map[sap_blk1]!==1'b1 || dut.rx_free_map[sample_blk0]!==1'b1 ||
       dut.rx_free_map[sample_blk1]!==1'b1)
      bad("all four distinct real-owner blocks were not returned");
    // The stream monitor above checks each accepted byte for both SAP frames
    // while mgmt_sap_rx owns the copy; this host read is supplementary.
    check_payload(sap_blk1);

    // Negative case: reset RM history, configure the same valid fixture but
    // leave CTL.SNMP_EN=0; it must drop specifically with R_SAP and return its allocated block.
    reset=1; repeat(7) @(negedge clk); reset=0;
    waitc=0;while(dut.init_done!==1 && waitc<26000) begin @(negedge clk);waitc=waitc+1;end
    if(waitc>=26000) bad("INIT_DONE timeout in disabled-SAP case");
    host_write(16'h0008,32'h2000);
    host_write(16'h0078,32'h172D);host_write(16'h007C,32'hAB61);
    host_write(16'h42B2,32'h1010_0100);host_write(16'h0080,32'h1);
    host_write(16'h1F80,vl_word_for_port(4'd5));host_write(16'h1F81,32'h0000_0100);
    host_write(PT_SAP,32'h8006_0000);host_write(PT_SAP+1,32'h0000_1388);
    host_write(PT_SAP+2,32'd0);host_write(PT_SAP+3,32'd1);
    host_write(PT_SAMPLE0,32'h8004_0000);host_write(PT_SAMPLE0+1,32'h0000_1388);
    host_write(PT_SAMPLE0+2,32'd0);host_write(PT_SAMPLE0+3,32'd1);
    host_write(PT_SAMPLE1,32'h8004_0000);host_write(PT_SAMPLE1+1,32'h0000_1388);
    host_write(PT_SAMPLE1+2,32'd0);host_write(PT_SAMPLE1+3,32'd1);
    host_write(16'h0008,32'h041E); // RX enabled, SNMP_EN bit8 cleared
    drive_one_a(0);
    waitc=0;while(disabled_sap<1 && waitc<10000) begin @(negedge clk);waitc=waitc+1;end
    if(waitc>=10000) bad("Disabled SAP never produced R_SAP drop");
    repeat(32) @(negedge clk);
    if(disabled_sap!==1) bad("Disabled SAP dropped more than once");
    host_read(16'hAC10,rd);if(rd!==32'd0) bad("Disabled SAP entered MGMT accept");
    host_read(16'hAC11,rd);if(rd!==32'd0) bad("Disabled SAP entered MGMT return");
    host_read(16'h0101,rd);if(rd!==32'd1) bad("Disabled SAP port drop count wrong");
    host_read(16'h001C,rd);if(rd!==32'd1) bad("Disabled SAP total drop count wrong");
    if(sap_fire!==2 || sap_return!==2 || dut.rx_free_map!==16'hFFC0)
      bad("Disabled SAP ownership/block return wrong");
    if(errors==0)
      $display("T23 SAP MINIMAL PASS (IF_MODE=%0d accept=2 return=2 SN=0,1,2,3 sample_blocks=%0d,%0d sap_blocks=%0d,%0d streams=%0d pb1_collisions=%0d max_wait=%0d disabled_rsap=%0d)",IF_MODE,sample_blk0,sample_blk1,sap_blk0,sap_blk1,sap_stream_frames,collision_cnt,max_mgmt_wait,disabled_sap);
    else $display("T23 SAP MINIMAL FAIL (IF_MODE=%0d errors=%0d)",IF_MODE,errors);
    $finish;
  end
  initial begin
    #120_000_000;$display("T23 SAP MINIMAL FAIL: timeout IF_MODE=%0d",IF_MODE);$finish;
  end
endmodule
module tb_t23_sap_min;  tb_t23_sap_core #(.IF_MODE(0)) core(); endmodule
module tb_t23g_sap_min; tb_t23_sap_core #(.IF_MODE(1)) core(); endmodule
