// Default 128TX/4096RX AFDX_top; public ports only, also usable with its
// mapped functional model. Independent expected bytes include complete
// Ethernet/IP/UDP/SN/FCS replies on BOTH networks. No DUT hierarchy reads.
`timescale 1 ns / 1 ps
`include "vec/gmii_management.vh"
module tb_t43_gmii_management;
  reg clk=0, reset=1;
  always #4 clk=~clk;
  reg [7:0] rx_data=0;
  reg rx_valid=0;
  wire [7:0] tx_data[0:1];
  wire tx_valid[0:1];
  wire hcs,hwe,hack;
  wire [15:0] haddr;
  wire [31:0] hwdata,hrdata;
  AFDX_top dut (
    .clk(clk),.reset(reset),.tx_data(tx_data[0]),.tx_valid(tx_valid[0]),.tx_ready(),
    .rx_data(rx_data),.rx_valid(rx_valid),.rx_ready(1'b0),.rx_error(1'b0),
    .tx_data_b(tx_data[1]),.tx_valid_b(tx_valid[1]),.tx_ready_b(),
    .rx_data_b(8'd0),.rx_valid_b(1'b0),.rx_ready_b(1'b0),.rx_error_b(1'b0),
    .host_cs(hcs),.host_we(hwe),.host_addr(haddr),.host_wdata(hwdata),
    .host_rdata(hrdata),.host_ack(hack),.host_irq(),
    .pps_in(1'b0),.pps_out(),.rtc_time_us(),.dbg_frame_event());
  afdx_host_bfm u_host (.clk(clk),.cs(hcs),.we(hwe),.addr(haddr),.wdata(hwdata),.rdata(hrdata),.ack(hack));
  reg [31:0] vec[0:`GMII_MGMT_WORDS-1];
  integer errors=0, checks=0, cycle=0, case_id=-1;
  integer expected_base[0:1], expected_length=0;
  integer count[0:1], frames[0:1], idle[0:1];
  reg active[0:1];
  integer net;
  always @(posedge clk) cycle<=cycle+1;
  task bad;
    input [8*112-1:0] reason;
    begin
      if(errors<25) $display("  [err] T43 case=%0d cycle=%0d %0s",case_id,cycle,reason);
      errors=errors+1;
    end
  endtask
  function [7:0] byte_at;
    input integer base,off;
    reg [31:0] word;
    begin word=vec[base+off/4]; byte_at=word[31-8*(off%4) -: 8]; end
  endfunction
  always @(posedge clk) begin
    for(net=0;net<2;net=net+1) begin
      if(reset) begin count[net]=0; frames[net]=0; idle[net]=100; active[net]=0; end
      else if(tx_valid[net]) begin
        if(!active[net]) begin
          if(idle[net]<12) bad("PHY IFG below 12 clocks");
          active[net]=1; count[net]=0;
        end
        if(expected_length==0) bad("unexpected response in quiet case");
        if(count[net]<7) begin
          if(tx_data[net]!==8'h55) bad("PHY preamble mismatch");
        end else if(count[net]==7) begin
          if(tx_data[net]!==8'hD5) bad("PHY SFD mismatch");
        end else if(count[net]-8>=expected_length) bad("extra response byte");
        else if(tx_data[net]!==byte_at(expected_base[net],count[net]-8))
          bad("A/B response differs from independent full-frame expectation");
        checks=checks+1; count[net]=count[net]+1; idle[net]=0;
      end else begin
        idle[net]=idle[net]+1;
        if(active[net]) begin
          if(count[net]!=expected_length+8) bad("DV discontinuity or wrong complete frame length");
          frames[net]=frames[net]+1; active[net]=0;
        end
      end
    end
  end
  task read_word;
    input [15:0] address;
    output [31:0] value;
    integer guard;
    begin
      @(negedge clk); u_host.cs=1; u_host.we=0; u_host.addr=address;
      @(negedge clk); guard=0;
      while(hack!==1'b1 && guard<64) begin @(negedge clk); guard=guard+1; end
      if(hack!==1'b1) bad("public host read timeout");
      value=hrdata; u_host.cs=0;
    end
  endtask
  task configure;
    input integer phase;
    integer port,guard;
    reg [31:0] value;
    begin
      port=(phase==0)?6:7;
      reset=1; repeat(8) @(negedge clk); reset=0;
      read_word(16'h000C,value); guard=0;
      while(!value[13] && guard<30000) begin read_word(16'h000C,value); guard=guard+1; end
      if(!value[13]) bad("default initialization timeout");
      u_host.wr(16'h0008,32'h2000);
      u_host.wr(16'h0078,32'h172D); u_host.wr(16'h007C,32'hAB61);
      u_host.wr(16'h42B2,32'h10100100); u_host.wr(16'h0080,1);
      u_host.wr(16'h1F80,32'hF5000000|(port<<12)|700); u_host.wr(16'h1F81,32'h0100);
      u_host.wr(16'h7D80+4*port,32'h80060000);
      u_host.wr(16'h7D81+4*port,5000); u_host.wr(16'h7D82+4*port,0); u_host.wr(16'h7D83+4*port,1);
      u_host.wr(16'h0204,port<<16); u_host.wr(16'h0203,0); u_host.wr(16'h0202,5000<<16);
      u_host.wr(16'h0201,1000<<8); u_host.wr(16'h0480,6040);
      u_host.wr(16'h0200,32'h80000003|(700<<12));
      u_host.wr(16'h0060,32'h172D2001); u_host.wr(16'h0064,32'h0A000002);
      u_host.wr(16'h0070,32'h0142);
      read_word(16'h005C,value); if(value!==0) bad("legal management configuration rejected");
      u_host.wr(16'h0008,32'h071F);
    end
  endtask
  task inject;
    input integer base,length;
    integer i;
    begin
      @(negedge clk);
      for(i=0;i<length+8;i=i+1) begin
        rx_valid=1; rx_data=(i<7)?8'h55:((i==7)?8'hD5:byte_at(base,i-8));
        @(negedge clk);
      end
      rx_valid=0;
    end
  endtask
  integer pos,phase,prior_phase=-1,req_base,req_length,guard,start_cycle;
  integer replies=0,quiet_cases=0;
  reg [31:0] drops_before,drops_after,value;
  initial begin
    $readmemh("vec/gmii_management.hex",vec,0,`GMII_MGMT_WORDS-1);
    if(vec[0]!==10) $fatal(1,"T43 missing management vectors");
    pos=1;
    for(case_id=0;case_id<10;case_id=case_id+1) begin
      phase=vec[pos]; req_length=vec[pos+1]; expected_length=vec[pos+2]; req_base=pos+3;
      expected_base[0]=req_base+(req_length+3)/4;
      expected_base[1]=expected_base[0]+(expected_length+3)/4;
      pos=expected_base[1]+(expected_length+3)/4;
      if(pos>`GMII_MGMT_WORDS) $fatal(1,"T43 vector record bounds");
      if(phase!=prior_phase) configure(phase);
      frames[0]=0; frames[1]=0;
      if(case_id==3) read_word(16'hAC18,drops_before);
      start_cycle=cycle;
      inject(req_base,req_length);
      if(expected_length!=0) begin
        guard=0;
        while((frames[0]<1 || frames[1]<1) && guard<250000) begin @(negedge clk); guard=guard+1; end
        if(frames[0]!=1 || frames[1]!=1) bad("missing or extra complete A/B response");
        if(cycle-start_cycle>250000) bad("GMII request first byte to complete response exceeds 2ms");
        repeat(20) @(negedge clk);
        if(frames[0]!=1 || frames[1]!=1) bad("extra response after completion");
        replies=replies+2;
      end else begin
        // Explicit no-response observation covers two legal 1ms BAG periods.
        repeat(250000) @(negedge clk);
        if(frames[0]!=0 || frames[1]!=0 || active[0] || active[1]) bad("quiet case emitted a response");
        if(case_id==3) begin
          read_word(16'hAC18,drops_after);
          if(drops_after!=drops_before+1) bad("wrong-community drop not counted exactly once");
        end
        quiet_cases=quiet_cases+1;
      end
      $display("T43_CASE id=%0d phase=%0d response_bytes=%0d complete_a=%0d complete_b=%0d elapsed_us=%.3f",case_id,phase,expected_length,frames[0],frames[1],(cycle-start_cycle)*0.008);
      prior_phase=phase;
    end
    if(pos!=`GMII_MGMT_WORDS || u_host.errors!=0) bad("vector layout or host stimulus failure");
    if(errors==0) $display("T43 GMII MANAGEMENT PASS checks=%0d responses=%0d quiet_cases=%0d snmp_set_get_getnext=1 tftp_load_unload_bytes=520",checks,replies,quiet_cases);
    else $display("T43 GMII MANAGEMENT FAIL errors=%0d",errors);
    $finish;
  end
  initial begin #20000000; $display("T43 GMII MANAGEMENT FAIL timeout"); $finish; end
endmodule
