// T08f/T08fg: complete RX hash/config frontdoor fill with per-word scoreboard,
// then one real 64B frame through lookup -> FLT -> IC -> RM -> port -> PMEM.
// This is full-table transaction coverage, not a claim that all 4096 keys have
// each been exercised by a live frame.
`timescale 1 ns / 1 ps
module tb_t08f_core #(parameter integer IF_MODE=0);
  localparam integer P_RX = 5;
  localparam [15:0] PT_RX = 16'h7D80 + 4*P_RX;
  localparam [31:0] RX_W0 = 32'hF500_0000 | (P_RX<<12) | 32'd79;

  reg clk=0, reset=1;
  always #4 clk=~clk;
  reg [7:0] rx_data=0, rx_data_b=0;
  reg rx_valid=0, rx_valid_b=0, rx_ready=0, rx_ready_b=0;
  reg host_cs=0, host_we=0;
  reg [15:0] host_addr=0;
  reg [31:0] host_wdata=0;
  wire [31:0] host_rdata;
  wire host_ack;

  AFDX_top #(.IF_MODE(IF_MODE),.FCS_MODE(2)) dut (
    .rx_error(1'b0), .rx_error_b(1'b0),
    .clk(clk),.reset(reset),.tx_data(),.tx_valid(),.tx_ready(),
    .rx_data(rx_data),.rx_valid(rx_valid),.rx_ready(rx_ready),
    .tx_data_b(),.tx_valid_b(),.tx_ready_b(),
    .rx_data_b(rx_data_b),.rx_valid_b(rx_valid_b),.rx_ready_b(rx_ready_b),
    .host_cs(host_cs),.host_we(host_we),.host_addr(host_addr),
    .host_wdata(host_wdata),.host_rdata(host_rdata),.host_ack(host_ack),
    .host_irq(),.pps_in(1'b0),.pps_out(),.rtc_time_us(),.dbg_frame_event());

  reg [31:0] image [0:8191];
  reg [31:0] meta [0:3];
  reg [31:0] vec [0:1144];
  reg [15:0] cfg_key [0:4095];
  reg cfg_seen [0:4095];
  reg [3:0] seen_way=0;
  integer errors=0, i, k, b, waitc, blk;
  integer valid_entries=0, hash_wr=0, hash_rd=0, cfg_wr=0, cfg_rd=0;
  integer deliveries=0, drops=0;
  reg [31:0] rd, w;

  task bad;
    input [8*112-1:0] reason;
    begin
      if(errors<16)
        $display("  [err] T08f%0d hW/R=%0d/%0d cW/R=%0d/%0d: %0s",
                 IF_MODE,hash_wr,hash_rd,cfg_wr,cfg_rd,reason);
      errors=errors+1;
    end
  endtask

  task host_write;
    input [15:0] addr;
    input [31:0] data;
    begin
      @(negedge clk); host_cs=1; host_we=1; host_addr=addr; host_wdata=data;
      @(negedge clk);
      if(host_ack!==1'b1) bad("host write ACK missing");
      host_cs=0; host_we=0;
    end
  endtask

  task host_read;
    input [15:0] addr;
    output [31:0] data;
    begin
      @(negedge clk); host_cs=1; host_we=0; host_addr=addr;
      @(negedge clk);
      if(host_ack!==1'b1) bad("host read ACK missing");
      data=host_rdata; host_cs=0;
    end
  endtask

  function [7:0] frame_byte;
    input integer off;
    reg [31:0] q;
    begin
      // t08a case 0 is a valid 64B A-network frame, header at vec[1].
      q=vec[3+(off>>2)];
      case(off&3)
        0:frame_byte=q[31:24]; 1:frame_byte=q[23:16];
        2:frame_byte=q[15:8];  default:frame_byte=q[7:0];
      endcase
    end
  endfunction

  task drive_case0_a;
    begin
      for(b=0;b<64;b=b+1) begin
        @(negedge clk); rx_ready=1; rx_valid=1; rx_data=frame_byte(b);
        if(IF_MODE==0) begin
          @(negedge clk); rx_valid=0;
          repeat(8) @(negedge clk);
        end
      end
      @(negedge clk); rx_ready=0; rx_valid=0;
    end
  endtask

  always @(posedge clk) if(!reset) begin
    if(dut.rx_ovf_a || dut.rx_ovf_b) bad("RX PMEM/descriptor queue overflow");
    if(dut.prs_out_vld && dut.pb_in_ready) begin
      if(dut.prs_out_drop) drops=drops+1; else deliveries=deliveries+1;
    end
  end

  initial begin
    $readmemh("vec/t12_top.img.hex",image);
    $readmemh("vec/t12_top.meta.hex",meta);
    $readmemh("vec/t08a_frames.hex",vec);
    if(meta[2]!==32'd4096 || vec[0]!==32'd22 || vec[1][15:0]!==16'd64 ||
       vec[1][23:16]!==8'd0 || vec[2]!==32'h7)
      bad("independent full-image or 64B frame fixture invalid");
    for(i=0;i<4096;i=i+1) begin cfg_seen[i]=0; cfg_key[i]=16'd0; end
    for(i=0;i<8192;i=i+1) if(image[i][28]) begin
      if(cfg_seen[image[i][11:0]]) bad("hash image contains duplicate RX index");
      cfg_seen[image[i][11:0]]=1'b1;
      cfg_key[image[i][11:0]]=image[i][27:12];
      valid_entries=valid_entries+1;
      seen_way[(i/4096)*2+(i&1)]=1'b1;
    end
    for(i=0;i<4096;i=i+1) if(!cfg_seen[i]) bad("hash image misses an RX index");
    if(valid_entries!=4096 || seen_way!==4'b1111) bad("hash image bank/way coverage invalid");

    repeat(7) @(negedge clk); reset=0;
    waitc=0;
    while(dut.init_done!==1 && waitc<26000) begin @(negedge clk); waitc=waitc+1; end
    if(waitc>=26000) bad("INIT_DONE timeout");
    host_write(16'h0008,32'h2000);
    host_write(16'h0078,meta[0]); host_write(16'h007C,meta[1]);
    // Full 8192-word hash frontdoor write/read scoreboard.
    for(i=0;i<8192;i=i+1) begin
      host_write(16'h3D80+i,image[i]); hash_wr=hash_wr+1;
    end
    for(i=0;i<8192;i=i+1) begin
      host_read(16'h3D80+i,rd); hash_rd=hash_rd+1;
      if(rd!==image[i]) bad("hash frontdoor readback mismatch");
    end
    host_write(16'h0080,32'h1);
    host_read(16'h0080,rd);
    if(rd[3:0]!==4'hF) bad("complete image commit flag missing");
    // Every RX index gets a valid config keyed to its image VLID; each word is
    // read back before RX is opened, so no configuration transaction is hidden.
    for(i=0;i<4096;i=i+1) begin
      host_write(16'h1D80+(i<<1),RX_W0); cfg_wr=cfg_wr+1;
      host_write(16'h1D81+(i<<1),{16'd0,cfg_key[i]}); cfg_wr=cfg_wr+1;
    end
    for(i=0;i<4096;i=i+1) begin
      host_read(16'h1D80+(i<<1),rd); cfg_rd=cfg_rd+1;
      if(rd!==RX_W0) bad("RX w0 full-table scoreboard mismatch");
      host_read(16'h1D81+(i<<1),rd); cfg_rd=cfg_rd+1;
      if(rd!=={16'd0,cfg_key[i]}) bad("RX w1 full-table scoreboard mismatch");
    end
    host_write(PT_RX,32'h8004_0000); host_write(PT_RX+1,32'h0000_1388);
    host_write(PT_RX+2,32'd0); host_write(PT_RX+3,32'd1);
    host_read(PT_RX,rd); if(rd!==32'h8004_0000) bad("RX port w0 readback mismatch");
    host_read(PT_RX+1,rd); if(rd!==32'h0000_1388) bad("RX port w1 readback mismatch");
    if(hash_wr!=8192 || hash_rd!=8192 || cfg_wr!=8192 || cfg_rd!=8192)
      bad("full-table transaction count mismatch");

    host_write(16'h0008,32'h051E);
    drive_case0_a();
    waitc=0;
    while(deliveries<1 && waitc<10000) begin @(negedge clk); waitc=waitc+1; end
    if(deliveries!==1 || drops!==0) bad("representative full-chain frame delivery/drop mismatch");
    host_read(16'h8480+P_RX,rd); if(rd!==32'd1) bad("MSG_CNT after frame is not one");
    host_read(16'h8180+P_RX,rd);
    if(rd[31]!==1'b1 || rd[27:24]!==4'd1 || rd[10:0]!==11'd8 || rd[23:20]<4'd6)
      bad("PORT_DESC after representative frame mismatch");
    blk=rd[23:20];
    for(i=10;i<13;i=i+1) begin
      host_read(16'h8800+(blk<<9)+i,w);
      for(k=0;k<4;k=k+1) if(4*i+k>=42 && 4*i+k<50)
        if(w[31-8*k -: 8]!==frame_byte(4*i+k)) bad("RX payload byte scoreboard mismatch");
    end
    host_read(16'h0100,rd); if(rd!==32'd1) bad("RX deliver statistic mismatch");
    host_read(16'h0040,rd); if(rd!==32'd0) bad("unexpected FLT unconfigured drop");
    host_read(16'h0044,rd); if(rd!==32'd0) bad("unexpected FLT lmax drop");
    host_read(16'h0048,rd); if(rd!==32'd0) bad("unexpected IC drop");
    host_write(16'h8380+P_RX,32'd0);
    repeat(180) @(negedge clk);
    if(dut.rx_free_map!==16'hFFC0) bad("RX block was not returned after MSG_RD");
    if(errors==0)
      $display("T08 FULL SCOREBOARD PASS (IF_MODE=%0d hash=8192W/8192R rx_cfg=8192W/8192R keys=4096 ways=%04b delivery=1 payload=8B)",
        IF_MODE,seen_way);
    else
      $display("T08 FULL SCOREBOARD FAIL (IF_MODE=%0d errors=%0d)",IF_MODE,errors);
    $finish;
  end
  initial begin
    #120_000_000;
    $display("T08 FULL SCOREBOARD FAIL: timeout IF_MODE=%0d hW/R=%0d/%0d cW/R=%0d/%0d",
             IF_MODE,hash_wr,hash_rd,cfg_wr,cfg_rd);
    $finish;
  end
endmodule

module tb_t08f_full_scoreboard;  tb_t08f_core #(.IF_MODE(0)) core(); endmodule
module tb_t08fg_full_scoreboard; tb_t08f_core #(.IF_MODE(1)) core(); endmodule
