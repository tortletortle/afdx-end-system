// T08d: top-level RX semantic filter (rx_flt, design doc 7.8 S2).
// Real model/zlib frames feed mac_rx_if -> lookup -> rx_flt; the TB checks
// PASS/UNCONF/NET/LMAX/VLID verdicts, per-class DROP counters, block
// conservation and reset clearing.  v0.5.14: rx_ic is wired after FLT, but
// this test runs with CTL.IC_EN=0 (0x051A) so PASS frames take the IC bypass
// and FLT verdicts/counters stay isolated from PSN state (IC is T08e).
// RM/port delivery is still NOT wired, so this is NOT a full T08/T22.
`timescale 1 ns / 1 ps
module tb_t08d_core #(parameter integer IF_MODE=0);
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
  reg [31:0] vec [0:1144];
  integer errors=0,flt_seen=0,pass_seen=0,drop_seen=0,crc_seen=0;
  integer i,waitc;
  reg [31:0] rd, pd;
  reg expect_active=0, expect_pass=0;
  reg [2:0] expect_reason=0;
  task bad(input [8*96-1:0] reason);
    begin
      if(errors<12) $display("  [err] T08d%0d flt=%0d: %0s",IF_MODE,flt_seen,reason);
      errors=errors+1;
    end
  endtask
  always @(posedge clk) if(!reset) begin
    if(dut.rx_ovf_a||dut.rx_ovf_b) bad("RX FIFO overflow");
    if(dut.rx_crc_err_b||dut.rx_crc_err_a) crc_seen=crc_seen+1;
    if(dut.flt_out_vld) begin
      flt_seen=flt_seen+1;
      if(!expect_active) bad("unexpected FLT verdict");
      else begin
        if(dut.flt_out_pass!==expect_pass) bad("PASS/DROP verdict wrong");
        if(!expect_pass && dut.flt_out_reason!==expect_reason)
          bad("drop reason class wrong");
        if(dut.flt_out_desc[158:148]!==11'd79) bad("descriptor len corrupted");
      end
      if(dut.flt_out_pass) pass_seen=pass_seen+1; else drop_seen=drop_seen+1;
      expect_active=0;
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
  function [7:0] vecbyte(input integer base,input integer idx);
    reg [31:0] word;
    begin
      word=vec[base+2+(idx>>2)];
      case(idx&3)
        0: vecbyte=word[31:24]; 1: vecbyte=word[23:16];
        2: vecbyte=word[15:8]; default: vecbyte=word[7:0];
      endcase
    end
  endfunction
  // vec case2 (base=37) is the known-good 79 B VLID=0x0100 real frame.
  task send79(input integer base,input net,input do_pass,input [2:0] reason,
              input expect_verdict);
    integer b;
    begin
      expect_pass=do_pass; expect_reason=reason; expect_active=expect_verdict;
      for(b=0;b<79;b=b+1) begin
        @(negedge clk);
        if(net) begin rx_ready_b=1;rx_valid_b=1;rx_data_b=vecbyte(base,b);end
        else begin rx_ready=1;rx_valid=1;rx_data=vecbyte(base,b);end
        if(IF_MODE==0) begin
          @(negedge clk);rx_valid=0;rx_valid_b=0;
          repeat(8) @(negedge clk);
        end
      end
      @(negedge clk);rx_ready=0;rx_valid=0;rx_ready_b=0;rx_valid_b=0;
      repeat(20) @(negedge clk);
      if(expect_verdict && expect_active) bad("frame produced no FLT verdict");
      if(!expect_verdict && flt_seen!=0 && expect_active===0 && 0) ;
      if(dut.rx_free_map!==16'hFFC0) bad("RX block leaked after verdict");
    end
  endtask
  task send_corrupt(input integer base,input net);
    integer b;
    reg [7:0] v;
    begin
      expect_active=0;
      for(b=0;b<79;b=b+1) begin
        v=vecbyte(base,b); if(b==78) v=v^8'h01; // break FCS only
        @(negedge clk);
        if(net) begin rx_ready_b=1;rx_valid_b=1;rx_data_b=v;end
        else begin rx_ready=1;rx_valid=1;rx_data=v;end
        if(IF_MODE==0) begin
          @(negedge clk);rx_valid=0;rx_valid_b=0;
          repeat(8) @(negedge clk);
        end
      end
      @(negedge clk);rx_ready=0;rx_valid=0;rx_ready_b=0;rx_valid_b=0;
      repeat(20) @(negedge clk);
      if(dut.rx_free_map!==16'hFFC0) bad("bad-FCS frame leaked a block");
    end
  endtask
  task cfg_mode_on;  begin host_write(16'h0008,32'h2000); end endtask
  task run_mode_on;  begin host_write(16'h0008,32'h051A); end endtask // IC_EN=0
  // RX_VL_CFG idx 0x100 words: 0x1D80+0x200/0x201.
  task write_vlcfg(input [31:0] w0,input [31:0] w1);
    begin
      host_write(16'h1F80,w0);
      host_write(16'h1F81,w1);
    end
  endtask
  initial begin
    $readmemh("vec/t08a_frames.hex",vec);
    if(vec[0]!==22 || vec[37][15:0]!==79 || vec[37][31:24]!==2)
      bad("t08a real frame vector missing or shifted");
    repeat(7) @(negedge clk);reset=0;
    waitc=0;
    while(dut.init_done!==1 && waitc<26000) begin @(negedge clk);waitc=waitc+1;end
    if(waitc>=26000) bad("INIT_DONE timeout");
    // Minimal hash fixture (same as T08c): seeds + one real slot for
    // VLID=0x0100 -> idx 0x100.  HASH_IMAGE=1 is a host assertion only.
    cfg_mode_on;
    host_write(16'h0078,32'h172D);
    host_write(16'h007C,32'hAB61);
    host_write(16'h42B2,32'h1010_0100);
    host_write(16'h0080,32'h1);
    // Phase A: valid config, both nets allowed, exact lmax boundary 79.
    write_vlcfg(32'hB000_0000|32'd79,32'h0000_0100); // valid,rm,net=11,lmax=79
    run_mode_on;
    send79(37,0,1,3'd0,1);            // A net hit -> PASS
    send79(37,1,1,3'd0,1);            // B net hit -> PASS (net_mode=3)
    // Unknown VLID 0x8000 (vec case index 2? use miss frame from t12 set):
    // reuse frame with VLID patched is not available here; instead drop by
    // un-arming the config entry (valid=0) to prove UNCONF on a live VL.
    cfg_mode_on;
    write_vlcfg(32'h3000_0000|32'd79,32'h0000_0100); // valid=0
    run_mode_on;
    send79(37,0,0,3'd1,1);            // UNCONF (entry disabled)
    // Phase B: net restriction A-only, frame from B -> NET drop.
    cfg_mode_on;
    write_vlcfg(32'h9000_0000|32'd79,32'h0000_0100); // valid, net=01 A-only
    run_mode_on;
    send79(37,1,0,3'd2,1);            // B frame rejected (NET)
    send79(37,0,1,3'd0,1);            // A frame still PASS
    // Phase C: lmax below the real 79 B frame -> LMAX drop; 79 passes above.
    cfg_mode_on;
    write_vlcfg(32'hB000_0000|32'd78,32'h0000_0100);
    run_mode_on;
    send79(37,0,0,3'd3,1);            // LMAX
    // Phase D: expect_vl mismatch -> VLID drop.
    cfg_mode_on;
    write_vlcfg(32'hB000_0000|32'd79,32'h0000_0200);
    run_mode_on;
    send79(37,0,0,3'd4,1);            // VLID (hash/config inconsistency)
    // Phase E: corrupted FCS never reaches lookup/FLT.
    send_corrupt(37,1);
    if(crc_seen<1) bad("bad-FCS frame was not counted by ingress");
    // Verdict histogram and per-class counters.
    if(pass_seen!==3 || drop_seen!==4 || flt_seen!==7)
      bad("verdict histogram wrong");
    // v0.5.16: the 3 PASS frames reach parse; VL port_base=0 is unconfigured.
    host_read(16'h0101,pd); if(pd!==32'd3) bad("port-drop count for PASS frames wrong");
    host_read(16'h001C,rd); if(rd!==32'd4+pd) bad("DROP_CNT total mismatch");
    host_read(16'h0040,rd); if(rd!==32'd3) bad("DROP_CNT_K unconf class mismatch");
    host_read(16'h0044,rd); if(rd!==32'd1) bad("DROP_CNT_K lmax class mismatch");
    host_read(16'h0048,rd); if(rd!==32'd0) bad("IC drop counted while IC_EN=0");
    if(dut.ic_accept_cnt!==0) bad("IC saw frames while IC_EN=0 (bypass broken)");
    if(dut.u_rxic.psn_mem[13'h100]!==8'd0 || dut.u_rxic.psn_mem[13'h1100]!==8'd0)
      bad("PSN written while IC_EN=0");
    // Reset clears counters and verdict pipeline.
    @(negedge clk);reset=1;repeat(6) @(negedge clk);reset=0;
    waitc=0;
    while(dut.init_done!==1 && waitc<26000) begin @(negedge clk);waitc=waitc+1;end
    if(waitc>=26000) bad("repeat INIT_DONE timeout");
    host_read(16'h001C,rd); if(rd!==32'd0) bad("DROP_CNT not cleared by reset");
    host_read(16'h0040,rd); if(rd!==32'd0) bad("unconf counter not cleared");
    if(errors==0)
      $display("T08d TOP FLT PASS (IF_MODE=%0d verdicts=%0d pass=%0d drop=%0d unconf/net/vlid=3 lmax=1 crc=%0d)",
        IF_MODE,flt_seen,pass_seen,drop_seen,crc_seen);
    else $display("T08d TOP FLT FAIL (IF_MODE=%0d errors=%0d)",IF_MODE,errors);
    $finish;
  end
  initial begin
    #6_000_000;
    $display("T08d TOP FLT FAIL: timeout IF_MODE=%0d flt=%0d",IF_MODE,flt_seen);
    $finish;
  end
endmodule
module tb_t08d_top_flt;  tb_t08d_core #(.IF_MODE(0)) core(); endmodule
module tb_t08dg_top_flt; tb_t08d_core #(.IF_MODE(1)) core(); endmodule
