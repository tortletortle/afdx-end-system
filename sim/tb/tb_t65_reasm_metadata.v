`timescale 1 ns / 1 ps
module tb_t65_reasm_metadata;
  localparam integer PORT5=5, PORT6=6, MAX_VEC=4096;
  localparam [31:0] RX_W0_5=32'hF500_0000|(PORT5<<12)|32'd700;
  localparam [31:0] RX_W0_6=32'hF500_0000|(PORT6<<12)|32'd100;
  reg clk=0, reset=1;
  always #4 clk=~clk; // 125 MHz
  reg [7:0] rx_data=0;
  reg rx_valid=0;
  wire [7:0] tx_data, tx_data_b;
  wire tx_valid, tx_valid_b;
  wire [31:0] host_rdata;
  wire host_ack;
  wire host_irq, pps_out;
  wire [63:0] rtc_time_us;
  wire [3:0] dbg_frame_event;
  wire host_cs, host_we;
  wire [15:0] host_addr;
  wire [31:0] host_wdata;
  AFDX_top #(.IF_MODE(2),.FCS_MODE(2)) dut (
    .clk(clk), .reset(reset), .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(),
    .rx_data(rx_data), .rx_valid(rx_valid), .rx_ready(1'b0), .rx_error(1'b0),
    .tx_data_b(tx_data_b), .tx_valid_b(tx_valid_b), .tx_ready_b(),
    .rx_data_b(8'd0), .rx_valid_b(1'b0), .rx_ready_b(1'b0), .rx_error_b(1'b0),
    .host_cs(host_cs), .host_we(host_we), .host_addr(host_addr),
    .host_wdata(host_wdata), .host_rdata(host_rdata), .host_ack(host_ack),
    .host_irq(host_irq), .pps_in(1'b0), .pps_out(pps_out),
    .rtc_time_us(rtc_time_us), .dbg_frame_event(dbg_frame_event));
  afdx_host_bfm u_host (
    .clk(clk), .cs(host_cs), .we(host_we), .addr(host_addr), .wdata(host_wdata),
    .rdata(host_rdata), .ack(host_ack));

  reg [31:0] vectors [0:MAX_VEC-1];
  reg [31:0] hash_img [0:8191];
  reg [31:0] hash_meta [0:3];
  reg [7:0] frame_bytes [0:4095];
  integer errors=0, checks=0, vec_pos=1, frame_len=0;
  integer i=0, j=0, guard=0, port_id=0, expected_len=0, blk=0;
  integer overlap_busy_cycles=0, overlap_diff_cycles=0, overlap_exact_cycles=0;
  reg [31:0] word_data, descriptor, rx_free_initial;
  reg [31:0] msg5_before, msg6_before;

  task bad;
    input [8*112-1:0] why;
    begin
      if(errors<30) $display("  [err] T65 %0s",why);
      errors=errors+1;
    end
  endtask
  task chk;
    input cond;
    input [8*112-1:0] why;
    begin checks=checks+1; if(!cond) bad(why); end
  endtask
  task read_word;
    input [15:0] addr;
    output [31:0] value;
    begin u_host.rd(addr,value); end
  endtask

  // Structural cover only: delivery and all byte verdicts below use public
  // host registers/PMEM. These hierarchical references are coupled to this
  // exact AFDX_top/rx_reassembly implementation and are not an external API.
  always @(posedge clk) begin
    if(!dut.rst_sync && dut.u_rxreasm.complete_check_busy) begin
      overlap_busy_cycles<=overlap_busy_cycles+1;
      if(dut.rm_hold_w0 !== dut.reasm_hold_w0)
        overlap_diff_cycles<=overlap_diff_cycles+1;
      if((dut.rm_hold_w0 === RX_W0_6) &&
         (dut.reasm_hold_w0 === RX_W0_5))
        overlap_exact_cycles<=overlap_exact_cycles+1;
    end
  end

  function [7:0] want_app;
    input integer p;
    input integer n;
    begin
      if(p==PORT5) want_app=(n*7+(n/8)*13+8'h5A)&8'hFF;
      else want_app=(n*19+8'hA7+(n/3)*5)&8'hFF;
    end
  endfunction

  task configure;
    integer g, n;
    reg [31:0] value;
    begin
      reset=1; repeat(8) @(negedge clk); reset=0;
      // rst_sync deasserts after three rising edges. Start the one-cycle
      // host BFM only after the synchronous reset has actually released.
      repeat(4) @(negedge clk);
      chk(dut.rst_sync===1'b0,"synchronous reset released before host access");
      read_word(16'h000C,value); g=0;
      while(!value[13] && g<30000) begin
        read_word(16'h000C,value); g=g+1;
      end
      chk(value[13]===1'b1,"default initialization completed");
      chk(hash_meta[2]===32'd4096,"T12 metadata describes 4096 RX entries");
      chk(hash_meta[0][15:0]===16'h172D && hash_meta[1][15:0]===16'hAB61,
          "T12 top hash seeds match generated top image");

      u_host.wr(16'h0008,32'h00002000);
      u_host.wr(16'h0078,hash_meta[0]);
      u_host.wr(16'h007C,hash_meta[1]);
      for(n=0;n<8192;n=n+1) u_host.wr(16'h3D80+n,hash_img[n]);
      u_host.wr(16'h0080,32'd1);
      read_word(16'h0080,value); chk(value[0]===1'b1,"T12 hash image committed");

      u_host.wr(16'h1D80+(PORT5<<1),RX_W0_5);
      u_host.wr(16'h1D81+(PORT5<<1),32'd5);
      u_host.wr(16'h1D80+(PORT6<<1),RX_W0_6);
      u_host.wr(16'h1D81+(PORT6<<1),32'd6);
      for(n=0;n<2;n=n+1) begin
        port_id=(n==0)?PORT5:PORT6;
        u_host.wr(16'h7D80+4*port_id,32'h8004_0000);
        u_host.wr(16'h7D81+4*port_id,(n==0)?32'd5000:32'd5001);
        u_host.wr(16'h7D82+4*port_id,32'd0);
        u_host.wr(16'h7D83+4*port_id,32'd1);
      end
      u_host.wr(16'h0060,32'h172D2001);
      u_host.wr(16'h0064,32'h0A000002);
      u_host.wr(16'h0070,32'h00000142); // UDP checksum enabled
      read_word(16'h005C,value); chk(value===32'd0,"RX port/VL configuration accepted");
      // A-only ingress, IC enabled, nonredundant RM bypass, reassembly enabled.
      u_host.wr(16'h0008,(1<<1)|(1<<2)|(1<<7));
      repeat(20) @(negedge clk);
    end
  endtask

  // Consume one length-prefixed frame from the vector file and transmit its
  // preamble/SFD/frame bytes at one byte per 125 MHz GMII cycle.
  task send_vec_frame;
    integer nbytes, nwords, q, lane;
    reg [31:0] w;
    begin
      frame_len=vectors[vec_pos]; vec_pos=vec_pos+1;
      nbytes=frame_len+8;
      nwords=(nbytes+3)/4;
      for(q=0;q<nwords;q=q+1) begin
        w=vectors[vec_pos]; vec_pos=vec_pos+1;
        frame_bytes[q*4+0]=w[31:24];
        frame_bytes[q*4+1]=w[23:16];
        frame_bytes[q*4+2]=w[15:8];
        frame_bytes[q*4+3]=w[7:0];
      end
      for(q=0;q<nbytes;q=q+1) begin
        rx_valid=1; rx_data=frame_bytes[q];
        @(negedge clk);
      end
      rx_valid=0; rx_data=0;
    end
  endtask
  task send_ifg12;
    integer q;
    begin
      for(q=0;q<12;q=q+1) begin
        rx_valid=0; rx_data=0;
        @(negedge clk);
      end
    end
  endtask

  task wait_msg_count;
    input integer p;
    input [31:0] target;
    integer g;
    reg [31:0] value;
    begin
      g=0; value=32'hFFFF_FFFF;
      while(value!==target && g<20000) begin
        read_word(16'h8480+p,value);
        if(value!==target) @(negedge clk);
        g=g+1;
      end
      if(value!==target) bad("bounded wait for public MSG_CNT expired");
    end
  endtask

  task check_public_payload;
    input integer p;
    input integer nbytes;
    integer wi, lane, app_index;
    reg [31:0] desc, data;
    begin
      read_word(16'h8180+p,desc);
      chk(desc[31]===1'b1,"public descriptor valid");
      chk(desc[10:0]===nbytes[10:0],"public descriptor carries exact application length");
      if(desc[31] && desc[10:0]===nbytes[10:0]) begin
        blk=desc[23:20];
        for(wi=0;wi<(nbytes+5)/4;wi=wi+1) begin
          read_word(16'h8800+(blk<<9)+10+wi,data);
          for(lane=0;lane<4;lane=lane+1) begin
            app_index=wi*4+lane-2;
            if(app_index>=0 && app_index<nbytes) begin
              case(lane)
                0: chk(data[31:24]===want_app(p,app_index),"public PMEM byte matches independent payload");
                1: chk(data[23:16]===want_app(p,app_index),"public PMEM byte matches independent payload");
                2: chk(data[15:8]===want_app(p,app_index),"public PMEM byte matches independent payload");
                3: chk(data[7:0]===want_app(p,app_index),"public PMEM byte matches independent payload");
              endcase
            end
          end
        end
      end
    end
  endtask

  task consume_port;
    input integer p;
    input integer nbytes;
    reg [31:0] count;
    begin
      read_word(16'h8480+p,count);
      chk(count===32'd1,"each public port has exactly one queued message");
      check_public_payload(p,nbytes);
      u_host.wr(16'h8380+p,32'd0); // hostMSG_RD consumes and releases the block
    end
  endtask

  initial begin
    $readmemh("vec/t12_top.img.hex",hash_img);
    $readmemh("vec/t12_top.meta.hex",hash_meta);
    $readmemh("vec/t65_metadata.hex",vectors);
    chk(vectors[0]===32'd3,"vector contains exactly three ordered frames");
    configure;
    rx_free_initial=dut.rx_free_map;
    read_word(16'h8480+PORT5,msg5_before);
    read_word(16'h8480+PORT6,msg6_before);
    chk(msg5_before===0 && msg6_before===0,"both public queues start empty");

    // The only gap between these frames is exactly 12 GMII idle byte clocks.
    // In particular there is no software/debug wait between VL5 tail and VL6.
    send_vec_frame; send_ifg12; // VL5 first: UDP + 600 application bytes, MF
    send_vec_frame; send_ifg12; // VL5 tail: offset 608, 36 application bytes
    send_vec_frame;             // VL6 single 12-byte application datagram
    rx_valid=0;

    wait_msg_count(PORT5,msg5_before+1);
    wait_msg_count(PORT6,msg6_before+1);
    repeat(200) @(negedge clk);
    read_word(16'h8480+PORT5,word_data);
    chk(word_data===msg5_before+1,"VL5 delivered exactly once through public MSG_CNT");
    read_word(16'h8480+PORT6,word_data);
    chk(word_data===msg6_before+1,"VL6 delivered exactly once through public MSG_CNT");
    consume_port(PORT5,636);
    consume_port(PORT6,12);
    repeat(200) @(negedge clk);
    read_word(16'h8480+PORT5,word_data);
    chk(word_data===msg5_before,"VL5 public MSG_RD emptied its queue");
    read_word(16'h8480+PORT6,word_data);
    chk(word_data===msg6_before,"VL6 public MSG_RD emptied its queue");
    chk(dut.rx_free_map===rx_free_initial,"free-map conserved after both hostMSG_RD consumes");

    // Required structural coverage: while VL5 checksum is busy, RM has accepted
    // VL6's distinct w0 but the held reassembly metadata remains VL5's w0.
    // If this exact overlap did not occur, this regression fails as uncovered.
    chk(overlap_busy_cycles>0,"internal structural probe observed UDP checksum busy");
    chk(overlap_diff_cycles>0,"internal structural probe observed rm/reassembly w0 differ during checksum busy");
    chk(overlap_exact_cycles>0,"overlap was specifically rm=VL6 w0 and reassembly=VL5 w0");
    chk(u_host.errors==0,"host BFM reported no hidden ACK errors");
    $display("T65 OVERLAP cover busy=%0d differing=%0d exact_VL6_over_VL5=%0d",
             overlap_busy_cycles,overlap_diff_cycles,overlap_exact_cycles);
    if(errors==0) $display("T65 REASM METADATA PASS checks=%0d",checks);
    else $display("T65 REASM METADATA FAIL errors=%0d checks=%0d",errors,checks);
    $finish;
  end
  initial begin #40000000; $display("T65 REASM METADATA FAIL timeout"); $finish; end
endmodule
