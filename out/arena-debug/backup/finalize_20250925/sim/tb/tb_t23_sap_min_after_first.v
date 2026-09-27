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
    .rx_data(rx_data),.rx_valid(rx_valid),.rx_ready(rx_ready),
    .tx_data_b(),.tx_valid_b(),.tx_ready_b(),
    .rx_data_b(rx_data_b),.rx_valid_b(rx_valid_b),.rx_ready_b(rx_ready_b),
    .host_cs(host_cs),.host_we(host_we),.host_addr(host_addr),
    .host_wdata(host_wdata),.host_rdata(host_rdata),.host_ack(host_ack),
    .host_irq(),.pps_in(1'b0),.pps_out(),.rtc_time_us(),.dbg_frame_event());
  reg [31:0] vec [0:1144];
  integer errors=0,i,k,b,waitc,blk,sap_fire=0,sap_return=0;
  integer collision_cnt=0, mgmt_wait=0, max_mgmt_wait=0, disabled_sap=0;
  integer reset_base=-1, vec_idx, overlap_cycles=0;
  reg second_in_wire=0, during_pair=0;
  reg [3:0] sap_blk0=0, sap_blk1=0;
  reg [31:0] rd,w;
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
  always @(posedge clk) if(!reset) begin
    if(dut.rx_ovf_a||dut.rx_ovf_b) bad("RX FIFO overflow");
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
    host_write(16'h1F80,W0_VL);host_write(16'h1F81,32'h0000_0100);
    host_write(PT_SAP,32'h8006_0000);host_write(PT_SAP+1,32'h0000_1388);
    host_write(PT_SAP+2,32'd0);host_write(PT_SAP+3,32'd1);
    host_read(PT_SAP,rd);if(rd!==32'h8006_0000) bad("SAP port readback mismatch");
    // RX_EN and SNMP_EN are both set in 0x051E; CTL.SNMP_EN gates SAP routing.
    host_write(16'h0008,32'h051E);
    // Drive valid SN=0 then SN=1 on the same wire at a 12-byte IFG. Inject
    // sustained ordinary PB1 release-slot pulses while each SAP is pending.
    // This is slot-level contention, not a second ordinary RX frame stream.
    force dut.pb_free1 = 1'b1;
    force dut.pb_free1_id = 4'd15;
    during_pair=1;
    drive_one_a(1);
    repeat(IF_MODE==0 ? 120 : 12) @(negedge clk);
    drive_one_a(0);
    during_pair=0; second_in_wire=0;
    waitc=0;while(dut.mgmt_accept_cnt<2 && waitc<10000) begin @(negedge clk);waitc=waitc+1;end
    if(waitc>=10000) bad("SAP back-to-back accept timeout");
    repeat(16) @(negedge clk);
    release dut.pb_free1; release dut.pb_free1_id;
    repeat(100) @(negedge clk);
    host_read(16'hAC10,rd);if(rd!==32'd2) bad("MGMT accept counter wrong");
    host_read(16'hAC11,rd);if(rd!==32'd2) bad("MGMT block-return counter wrong");
    host_read(16'hAC12,rd);
    if(rd[31]!==1'b1 || rd[22:15]!==P_SAP || rd[10:0]!==11'd8 ||
       rd[14:11]!==sap_blk1 || sap_blk0!==4'd6)
      bad("MGMT descriptor window wrong");
    blk=rd[14:11];
    host_read(16'hAC13,rd);if(rd!==32'd0) bad("MGMT still busy after return");
    if(sap_fire!==2 || sap_return!==2) bad("SAP pair handshake/return count wrong");
    if(collision_cnt<2 || max_mgmt_wait>1 || overlap_cycles<1)
      bad("SAP pair PB1 contention, in-flight overlap or bounded return absent");
    // Empty PORT_DESC leaves its unused block field unspecified; check only
    // defined empty-state fields rather than comparing the entire word.
    host_read(16'h8180+P_SAP,rd);
    if(rd[31]!==1'b0 || rd[27:24]!==4'd0 || rd[10:0]!==11'd0)
      bad("SAP incorrectly entered PORT_DESC");
    host_read(16'h8480+P_SAP,rd);if(rd!==32'd0) bad("SAP incorrectly entered MSG_CNT");
    host_read(16'h0100,rd);if(rd!==32'd0) bad("SAP incorrectly incremented port delivery");
    host_read(16'h0101,rd);if(rd!==32'd0) bad("enabled SAP became port drop");
    host_read(16'h001C,rd);if(rd!==32'd0) bad("enabled SAP became total drop");
    for(i=10;i<13;i=i+1) begin
      host_read(16'h8800+(blk<<9)+i,w);
      for(k=0;k<4;k=k+1) if(4*i+k>=42 && 4*i+k<50)
        if(w[31-8*k -:8]!==frame_byte(4*i+k)) bad("SAP PMEM payload differs from frame");
    end
    if(dut.rx_free_map!==16'hFFC0 || !dut.rx_free_map[sap_blk0] || !dut.rx_free_map[sap_blk1])
      bad("SAP pair blocks not returned to RX pool");

    // Negative case: reset RM history, configure the same valid fixture but
    // leave CTL.SNMP_EN=0; it must drop specifically with R_SAP and free blk 6.
    reset=1; repeat(7) @(negedge clk); reset=0;
    waitc=0;while(dut.init_done!==1 && waitc<26000) begin @(negedge clk);waitc=waitc+1;end
    if(waitc>=26000) bad("INIT_DONE timeout in disabled-SAP case");
    host_write(16'h0008,32'h2000);
    host_write(16'h0078,32'h172D);host_write(16'h007C,32'hAB61);
    host_write(16'h42B2,32'h1010_0100);host_write(16'h0080,32'h1);
    host_write(16'h1F80,W0_VL);host_write(16'h1F81,32'h0000_0100);
    host_write(PT_SAP,32'h8006_0000);host_write(PT_SAP+1,32'h0000_1388);
    host_write(PT_SAP+2,32'd0);host_write(PT_SAP+3,32'd1);
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
      $display("T23 SAP MINIMAL PASS (IF_MODE=%0d accept=2 return=2 SN=0,1 port=5 plen=8 pmem=8B pb1_collisions=%0d overlap=%0d max_wait=%0d disabled_rsap=%0d)",IF_MODE,collision_cnt,overlap_cycles,max_mgmt_wait,disabled_sap);
    else $display("T23 SAP MINIMAL FAIL (IF_MODE=%0d errors=%0d)",IF_MODE,errors);
    $finish;
  end
  initial begin
    #120_000_000;$display("T23 SAP MINIMAL FAIL: timeout IF_MODE=%0d",IF_MODE);$finish;
  end
endmodule
module tb_t23_sap_min;  tb_t23_sap_core #(.IF_MODE(0)) core(); endmodule
module tb_t23g_sap_min; tb_t23_sap_core #(.IF_MODE(1)) core(); endmodule
