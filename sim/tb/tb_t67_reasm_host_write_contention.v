`timescale 1 ns / 1 ps
module tb_t67_reasm_host_write_contention;
  localparam integer PORT5=5, MAX_VEC=4096;
  localparam [31:0] RX_W0_5=32'hF500_0000|(PORT5<<12)|32'd700;
  reg clk=0, reset=1;
  always #4 clk=~clk; // 125 MHz
  reg [7:0] rx_data=0;
  reg rx_valid=0;
  reg host_cs=0, host_we=0;
  reg [15:0] host_addr=0;
  reg [31:0] host_wdata=0;
  wire [31:0] host_rdata;
  wire host_ack, host_irq, pps_out;
  wire [7:0] tx_data, tx_data_b;
  wire tx_valid, tx_valid_b;
  wire [63:0] rtc_time_us;
  wire [3:0] dbg_frame_event;
  AFDX_top #(.IF_MODE(2),.FCS_MODE(2)) dut (
    .clk(clk), .reset(reset), .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(),
    .rx_data(rx_data), .rx_valid(rx_valid), .rx_ready(1'b0), .rx_error(1'b0),
    .tx_data_b(tx_data_b), .tx_valid_b(tx_valid_b), .tx_ready_b(),
    .rx_data_b(8'd0), .rx_valid_b(1'b0), .rx_ready_b(1'b0), .rx_error_b(1'b0),
    .host_cs(host_cs), .host_we(host_we), .host_addr(host_addr),
    .host_wdata(host_wdata), .host_rdata(host_rdata), .host_ack(host_ack),
    .host_irq(host_irq), .pps_in(1'b0), .pps_out(pps_out),
    .rtc_time_us(rtc_time_us), .dbg_frame_event(dbg_frame_event));

  reg [31:0] vectors [0:MAX_VEC-1];
  reg [31:0] hash_img [0:8191];
  reg [31:0] hash_meta [0:3];
  reg [7:0] frame_bytes [0:4095];
  integer errors=0, checks=0, vec_pos=1, frame_len=0;
  integer i=0, q=0, lane=0, g=0, n=0, host_hold_cycles=0;
  integer copy_wait_cycles=0, copy_grants=0, copy_compete_cycles=0, copy_fair_grants=0;
  integer copy_wait=0, host_commit_grants=0, host_ack_count=0, host_bad_ack=0;
  integer write_owner_overlap=0, host_req_cycles=0;
  integer payload_bytes=0, ack_guard=0;
  reg [31:0] value, desc, data;
  reg [7:0] want_byte;
  reg [31:0] rx_free_initial, msg_before;
  reg stress_host_write=0;
  reg host_commit_d=0;
  reg copy_compete_waiting=0;
  reg [15:0] tx_open_status=0;
  reg [15:0] tx_open_addr=0;
  localparam [31:0] TX_STRESS_DATA=32'hC0DE_C0DE;

  task bad;
    input [8*112-1:0] why;
    begin if(errors<40) $display("  [err] T67 %0s",why); errors=errors+1; end
  endtask
  task chk;
    input cond;
    input [8*112-1:0] why;
    begin checks=checks+1; if(!cond) bad(why); end
  endtask
  task host_access;
    input wr;
    input [15:0] a;
    input [31:0] d;
    output [31:0] r;
    integer k;
    begin
      @(negedge clk); host_cs=1; host_we=wr; host_addr=a; host_wdata=d;
      k=0;
      while(host_ack!==1'b1 && k<100) begin @(negedge clk); k=k+1; end
      if(host_ack!==1'b1) bad("bounded host access ACK timeout");
      r=host_rdata;
      @(negedge clk); host_cs=0; host_we=0;
    end
  endtask
  task hw;
    input [15:0] a; input [31:0] d;
    reg [31:0] unused;
    begin host_access(1'b1,a,d,unused); end
  endtask
  task hr;
    input [15:0] a; output [31:0] d;
    begin host_access(1'b0,a,32'd0,d); end
  endtask
  task configure;
    reg [31:0] tmp;
    integer k;
    begin
      reset=1; repeat(8) @(negedge clk); reset=0;
      hr(16'h000C,tmp); k=0;
      while(!tmp[13] && k<30000) begin hr(16'h000C,tmp); k=k+1; end
      chk(tmp[13]===1'b1,"default initialization completed");
      chk(hash_meta[2]===32'd4096,"T12 metadata describes 4096 entries");
      hw(16'h0008,32'h00002000);
      hw(16'h0078,hash_meta[0]); hw(16'h007C,hash_meta[1]);
      for(k=0;k<8192;k=k+1) hw(16'h3D80+k,hash_img[k]);
      hw(16'h0080,32'd1); hr(16'h0080,tmp);
      chk(tmp[0]===1'b1,"T12 hash image committed");
      hw(16'h1D80+(PORT5<<1),RX_W0_5); hw(16'h1D81+(PORT5<<1),32'd5);
      hw(16'h7D80+4*PORT5,32'h8004_0000);
      hw(16'h7D81+4*PORT5,32'd5000); hw(16'h7D82+4*PORT5,32'd0);
      hw(16'h7D83+4*PORT5,32'd1);
      hw(16'h0060,32'h172D2001); hw(16'h0064,32'h0A000002);
      hw(16'h0070,32'h00000142);
      hr(16'h005C,tmp); chk(tmp===32'd0,"RX port/VL configuration accepted");
      hw(16'h0008,(1<<1)|(1<<2)|(1<<7));
      repeat(20) @(negedge clk);
    end
  endtask
  task send_vec_frame;
    integer nb, nw, x;
    reg [31:0] w;
    begin
      frame_len=vectors[vec_pos]; vec_pos=vec_pos+1;
      nb=frame_len+8; nw=(nb+3)/4;
      for(x=0;x<nw;x=x+1) begin
        w=vectors[vec_pos]; vec_pos=vec_pos+1;
        frame_bytes[x*4+0]=w[31:24]; frame_bytes[x*4+1]=w[23:16];
        frame_bytes[x*4+2]=w[15:8]; frame_bytes[x*4+3]=w[7:0];
      end
      for(x=0;x<nb;x=x+1) begin rx_valid=1; rx_data=frame_bytes[x]; @(negedge clk); end
      rx_valid=0; rx_data=0;
    end
  endtask
  task send_ifg12;
    integer x;
    begin for(x=0;x<12;x=x+1) begin rx_valid=0; rx_data=0; @(negedge clk); end end
  endtask
  function [7:0] want_app;
    input integer p;
    begin want_app=(p*7+(p/8)*13+8'h5A)&8'hFF; end
  endfunction

  // Structural monitoring covers the shared PMEM write-port arbitration.
  // Public host registers/PMEM below provide the functional RX verdict.
  always @(posedge clk) begin
    if(dut.rst_sync) host_commit_d<=1'b0;
    else begin
      if(stress_host_write) begin
        host_hold_cycles<=host_hold_cycles+1;
        if(host_cs!==1'b1 || host_we!==1'b1 || host_addr!==tx_open_addr || host_wdata!==TX_STRESS_DATA)
          bad("continuous TX host write request/address/data changed");
        if(dut.host_pmem_req) host_req_cycles<=host_req_cycles+1;
        if(dut.host_commit_now || dut.host_commit_pending)
          host_commit_grants<=host_commit_grants+1;
        if(host_ack) begin
          host_ack_count<=host_ack_count+1;
          if(!host_commit_d) host_bad_ack<=host_bad_ack+1;
        end
        if(dut.copy_wr_valid) begin
          copy_wait_cycles<=copy_wait_cycles+1;
          if(dut.host_pmem_req || dut.host_pmem_pending) begin
            copy_compete_cycles<=copy_compete_cycles+1;
            copy_compete_waiting<=1'b1;
          end
          if(dut.copy_wr_grant) begin
            copy_grants<=copy_grants+1;
            if(copy_compete_waiting) copy_fair_grants<=copy_fair_grants+1;
            copy_compete_waiting<=1'b0;
            copy_wait<=0;
          end else begin
            if(copy_wait>=7) bad("copy write missed grant by eighth competing cycle");
            copy_wait<=copy_wait+1;
          end
        end else begin copy_wait<=0; copy_compete_waiting<=1'b0; end
        if((dut.q_pop_a && dut.q_pop_b) ||
           (dut.q_pop_a && (dut.host_commit_now || dut.host_commit_pending)) ||
           (dut.q_pop_b && (dut.host_commit_now || dut.host_commit_pending)) ||
           (dut.q_pop_a && dut.copy_wr_grant) || (dut.q_pop_b && dut.copy_wr_grant) ||
           ((dut.host_commit_now || dut.host_commit_pending) && dut.copy_wr_grant) ||
           (dut.mt_wr_go && (dut.q_pop_a || dut.q_pop_b || dut.host_commit_now ||
                             dut.host_commit_pending || dut.copy_wr_grant)))
          write_owner_overlap<=write_owner_overlap+1;
      end
      host_commit_d <= dut.host_commit_now || dut.host_commit_pending;
    end
  end

  initial begin
    $readmemh("vec/t12_top.img.hex",hash_img);
    $readmemh("vec/t12_top.meta.hex",hash_meta);
    $readmemh("vec/t65_metadata.hex",vectors);
    chk(vectors[0]===32'd3,"T65 vector has three ordered frames");
    configure;
    hr(16'h8480+PORT5,msg_before); chk(msg_before===0,"VL5 queue begins empty");
    rx_free_initial=dut.rx_free_map;
    hr(16'h0074,value);
    chk(value[4]===1'b1 && value[3:0]<4'd6,"public status exposes a valid TX open block");
    tx_open_status=value[3:0];
    tx_open_addr=16'h8800+(tx_open_status<<9)+16'h01F0;

    send_vec_frame; send_ifg12; // first VL5 fragment (600 application bytes)
    repeat(50) @(negedge clk);
    // Read-only status 0x0074 supplies the real open TX block. A write at word
    // offset 0x1f0 stays inside that block and away from all RX storage.
    @(negedge clk); host_cs=1; host_we=1; host_addr=tx_open_addr;
    host_wdata=TX_STRESS_DATA; stress_host_write=1;
    send_vec_frame; // VL5 final fragment, offset 608
    for(i=0;i<6000;i=i+1) @(negedge clk);
    ack_guard=0;
    while(host_ack!==1'b1 && ack_guard<100) begin @(negedge clk); ack_guard=ack_guard+1; end
    chk(host_ack===1'b1,"held final TX PMEM write was retained until ACK");
    stress_host_write=0; host_cs=0; host_we=0;
    repeat(10) @(negedge clk);

    chk(host_hold_cycles>=6000,"TX host write request was held for at least 6000 clocks");
    chk(host_req_cycles>0 && host_commit_grants>0 && host_ack_count>0,
        "legal TX host writes committed while request remained asserted");
    chk(copy_wait_cycles>0 && copy_grants>0,"RX copy write requested and granted during TX host contention");
    chk(copy_compete_cycles>0,"RX copy waited while TX host request or pending write competed");
    chk(copy_fair_grants>0,"an RX copy grant followed an observed wait against TX host traffic");
    chk(host_bad_ack==0,"host ACK appears only after its own TX PMEM commit");
    chk(write_owner_overlap==0,"shared PMEM write port has at most one owner each cycle");
    chk(errors==0,"no monitor assertion failed during contention");

    hr(16'h8480+PORT5,value); chk(value===msg_before+1,"public queue reports exactly one completed VL5 message");
    hr(16'h8180+PORT5,desc);
    chk(desc[31]===1'b1 && desc[10:0]===11'd636,"public descriptor reports full 636-byte datagram");
    if(desc[31] && desc[10:0]===11'd636) begin
      for(i=0;i<(636+5)/4;i=i+1) begin
        hr(16'h8800+(desc[23:20]<<9)+10+i,data);
        for(lane=0;lane<4;lane=lane+1) begin
          g=i*4+lane-2;
          if(g>=0 && g<636) begin
            case(lane)
              0: want_byte=data[31:24]; 1: want_byte=data[23:16];
              2: want_byte=data[15:8]; 3: want_byte=data[7:0];
            endcase
            chk(want_byte===want_app(g),"public PMEM application byte matches generated VL5 payload");
            payload_bytes=payload_bytes+1;
          end
        end
      end
    end
    chk(payload_bytes==636,"all 636 application bytes checked through public host reads");
    hw(16'h8380+PORT5,32'd0); hr(16'h8480+PORT5,value);
    chk(value===msg_before,"public MSG_RD consumes the message");
    chk(dut.rx_free_map===rx_free_initial,"RX block allocation is conserved after host consume");
    $display("T67 WRITE contention host=%0d host_commit=%0d copy_wait/grant=%0d/%0d overlap=%0d",
             host_hold_cycles,host_commit_grants,copy_wait_cycles,copy_grants,copy_compete_cycles);
    if(errors==0) $display("T67 REASM HOST WRITE CONTENTION PASS checks=%0d",checks);
    else $display("T67 REASM HOST WRITE CONTENTION FAIL errors=%0d checks=%0d",errors,checks);
    $finish;
  end
  initial begin #40000000; $display("T67 REASM HOST WRITE CONTENTION FAIL timeout"); $finish; end
endmodule


