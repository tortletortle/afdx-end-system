// T21/T21g: RX block pool exhaustion, NO_BLK backpressure evidence,
// recovery and block return through rx_port_buf MSG_RD.
// The test fills the 10-block RX pool (blocks 6..15) with queue-port
// messages, drives one extra real frame while the pool is empty, checks that
// no PMEM write or port enqueue occurs and mac_rx_if reports NO_BLK, then
// releases every queued message and verifies a subsequent frame is accepted.
`timescale 1 ns / 1 ps
module tb_t21_core #(parameter integer IF_MODE=0);
  reg clk=0, reset=1;
  always #4 clk=~clk;

  reg host_cs=0, host_we=0, rx_valid=0, rx_valid_b=0, rx_ready=0, rx_ready_b=0;
  reg [15:0] host_addr=0;
  reg [31:0] host_wdata=0;
  reg [7:0] rx_data=0, rx_data_b=0;
  wire [31:0] host_rdata;
  wire host_ack;

  AFDX_top #(.IF_MODE(IF_MODE), .FCS_MODE(2)) dut (
    .clk(clk), .reset(reset), .tx_data(), .tx_valid(), .tx_ready(), .rx_error(1'bz), .rx_error_b(1'bz),
    .rx_data(rx_data), .rx_valid(rx_valid), .rx_ready(rx_ready),
    .tx_data_b(), .tx_valid_b(), .tx_ready_b(),
    .rx_data_b(rx_data_b), .rx_valid_b(rx_valid_b), .rx_ready_b(rx_ready_b),
    .host_cs(host_cs), .host_we(host_we), .host_addr(host_addr),
    .host_wdata(host_wdata), .host_rdata(host_rdata), .host_ack(host_ack),
    .host_irq(), .pps_in(1'b0), .pps_out(), .rtc_time_us(), .dbg_frame_event());
  afdx_cov_rsrc u_cov_rsrc (
    .clk(clk), .rst_sync(reset),
    .pmem_free(dut.pmem_free),
    .pb_ev_sample(dut.pb_ev_sample), .pb_ev_queue(dut.pb_ev_queue),
    .pb_ev_ovf(dut.pb_ev_ovf), .pb_ev_drop(dut.pb_ev_drop));

  localparam integer P = 5;
  localparam [15:0] PT = 16'h7D80 + 4*P;
  localparam [31:0] W0_VL = 32'hF500_0000 | (P<<12) | 32'd79;

  reg [31:0] vec [0:1144];
  reg [7:0] base [0:78];
  reg [7:0] frm_a [0:78];
  integer errors=0, i, k, waitc;
  integer deliveries=0, no_blk_pulses=0, pmem_during_empty=0;
  integer exp_deliv=0;
  reg monitor_no_pmem=0;
  reg [31:0] rd, w;
  reg [15:0] dport;
  reg [7:0] sn_a;

  task bad(input [8*128-1:0] reason);
    begin
      if(errors < 20)
        $display("  [err] T21%0d t=%0t held=%0d exh=%0d mac_drop=%0d: %0s",
                 IF_MODE, $time, 10-popc(dut.rx_free_map), dut.rx_exh_cnt,
                 dut.u_mac_rx_a.drop_cnt, reason);
      errors = errors + 1;
    end
  endtask

  function integer popc(input [15:0] m);
    integer j; begin popc=0; for(j=0;j<16;j=j+1) popc=popc+m[j]; end
  endfunction

  always @(posedge clk) if(!reset) begin
    if(dut.rx_ovf_a || dut.rx_ovf_b) bad("RX PMEM/descriptor queue overflow");
    if(dut.prs_out_vld && dut.pb_in_ready && !dut.prs_out_drop) deliveries = deliveries + 1;
    if(dut.u_mac_rx_a.frame_err && dut.u_mac_rx_a.drop_reason == 8'h40) no_blk_pulses = no_blk_pulses + 1;
    if(monitor_no_pmem && dut.rxw_en_a) pmem_during_empty = pmem_during_empty + 1;
  end

  task host_write(input [15:0] addr, input [31:0] data);
    begin
      @(negedge clk); host_cs=1; host_we=1; host_addr=addr; host_wdata=data;
      @(negedge clk);
      if(host_ack!==1'b1) bad("host write ACK missing");
      host_cs=0; host_we=0;
    end
  endtask

  task host_read(input [15:0] addr, output [31:0] data);
    begin
      @(negedge clk); host_cs=1; host_we=0; host_addr=addr;
      @(negedge clk);
      if(host_ack!==1'b1) bad("host read ACK missing");
      data=host_rdata; host_cs=0;
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

  task build_a(input [7:0] sn, input [7:0] mk);
    integer j; reg [31:0] c; reg [7:0] v;
    begin
      c=32'hFFFFFFFF;
      for(j=0;j<75;j=j+1) begin
        v=(j==74)?sn:(j==42)?mk:(j==43)?~mk:base[j];
        frm_a[j]=v; c=crc_step(c,v);
      end
      c=~c;
      for(j=0;j<4;j=j+1) frm_a[75+j]=c[8*j+:8];
    end
  endtask

  task drive_a;
    integer b;
    begin
      for(b=0;b<79;b=b+1) begin
        @(negedge clk); rx_ready=1; rx_valid=1; rx_data=frm_a[b];
        if(IF_MODE==0) begin @(negedge clk); rx_valid=0; repeat(8) @(negedge clk); end
      end
      @(negedge clk); rx_ready=0; rx_valid=0;
    end
  endtask

  task single_a(input [7:0] mk);
    begin
      build_a(sn_a, mk);
      drive_a();
      sn_a = sn_a + 1;
    end
  endtask

  task wait_init;
    begin
      waitc=0;
      while(dut.init_done!==1 && waitc<26000) begin @(negedge clk); waitc=waitc+1; end
      if(waitc>=26000) bad("INIT_DONE timeout");
    end
  endtask

  task cfg_mode_on; begin host_write(16'h0008,32'h2000); end endtask
  task run_on;      begin host_write(16'h0008,32'h051E); end endtask

  task boot;
    begin
      wait_init;
      cfg_mode_on;
      host_write(16'h0078,32'h172D);
      host_write(16'h007C,32'hAB61);
      host_write(16'h42B2,32'h1010_0100);
      host_write(16'h0080,32'h1);
      host_write(16'h0070,32'h0000_0140);
      host_write(16'h1F80,W0_VL);
      host_write(16'h1F81,32'h0000_0100);
      // Queue RX port with depth 10, matching the RX block pool size 6..15.
      host_write(PT,   32'h8005_0000);
      host_write(PT+1, {16'd0,dport});
      host_write(PT+2, 32'd0);
      host_write(PT+3, 32'd10);
      sn_a=8'd1;
      run_on;
    end
  endtask

  task read_desc(output [31:0] d); begin host_read(16'h8180+P,d); end endtask
  task msg_rd; begin host_write(16'h8380+P,32'd0); end endtask
  task msg_cnt(input [3:0] n);
    begin host_read(16'h8480+P,rd); if(rd!=={28'd0,n}) bad("MSG_CNT wrong"); end
  endtask

  task settle(input integer n);
    begin
      repeat(100) @(negedge clk);
      if(popc(dut.rx_free_map)!==10-n) bad("held RX block count wrong");
      if(dut.u_rxpb.p_cnt[P]!==n[3:0]) bad("rx_port_buf count does not match held blocks");
    end
  endtask

  task check_desc(input [31:0] d, input [3:0] cnt);
    begin
      if(d[31]!==1'b1) bad("PORT_DESC valid wrong");
      if(d[27:24]!==cnt) bad("PORT_DESC cnt wrong");
      if(d[10:0]!==11'd32) bad("PORT_DESC payload length wrong");
      if(d[23:20] < 4'd6) bad("PORT_DESC block outside RX pool");
    end
  endtask

  task check_empty_desc;
    begin
      read_desc(rd);
      if(rd[31]!==1'b0 || rd[27:24]!==4'd0 || rd[10:0]!==11'd0)
        bad("PORT_DESC not empty");
    end
  endtask

  task check_payload(input [3:0] blk, input [7:0] mk);
    integer j; reg [7:0] got, want;
    begin
      for(j=40;j<76;j=j+4) begin
        host_read(16'h8800 + {blk,9'd0} + (j>>2), w);
        for(k=0;k<4;k=k+1) if(j+k>=42 && j+k<74) begin
          got=w[31-8*k -: 8];
          want=(j+k==42)?mk:(j+k==43)?~mk:base[j+k];
          if(got!==want) bad("payload byte read back from PMEM differs");
        end
      end
    end
  endtask

  initial begin
    $readmemh("vec/t08a_frames.hex", vec);
    if(vec[0]!==22 || vec[37][15:0]!==79 || vec[37][31:24]!==2)
      bad("t08a real frame vector missing or shifted");
    for(i=0;i<79;i=i+1) begin
      rd=vec[37+2+(i>>2)];
      case(i&3) 0: base[i]=rd[31:24]; 1: base[i]=rd[23:16];
                2: base[i]=rd[15:8]; default: base[i]=rd[7:0]; endcase
    end
    dport={base[36],base[37]};
    repeat(7) @(negedge clk); reset=0;
    boot;

    // 1) Fill all ten RX blocks and verify queue scoreboard/order.
    for(i=0;i<10;i=i+1) begin
      single_a(8'h30+i[7:0]);
      settle(i+1);
    end
    exp_deliv = 10;
    if(dut.rx_free_map!==16'h0000) bad("RX pool not fully exhausted");
    if(dut.rx_exh_cnt!==16'd0) bad("exhaust counter changed before pool empty");
    if(dut.rx_borrow_cnt!==16'd4) bad("borrow counter did not cover blocks 12..15");
    msg_cnt(10);

    // 2) One more frame sees an empty pool: allocator rejects, mac_rx_if reports
    // NO_BLK, no PMEM write and no new queue entry.
    monitor_no_pmem=1;
    single_a(8'hEE);
    repeat(120) @(negedge clk);
    monitor_no_pmem=0;
    if(dut.rx_exh_cnt!==16'd1) bad("exhaust counter did not increment once");
    if(no_blk_pulses!==1 || dut.u_mac_rx_a.drop_cnt!==16'd1) bad("NO_BLK drop not observed exactly once");
    if(pmem_during_empty!==0) bad("PMEM write occurred while pool empty");
    if(dut.u_rxpb.p_cnt[P]!==4'd10 || deliveries!==exp_deliv) bad("empty-pool frame changed queue delivery state");
    msg_cnt(10);

    // 3) Return blocks through MSG_RD and verify every queued payload.
    for(i=0;i<10;i=i+1) begin
      read_desc(rd); check_desc(rd, 10-i);
      check_payload(rd[23:20], 8'h30+i[7:0]);
      msg_rd; settle(9-i);
    end
    msg_cnt(0); check_empty_desc;
    if(dut.rx_free_map!==16'hFFC0) bad("RX pool did not recover after MSG_RD releases");

    // 4) Recovery: after return, the next frame is accepted and no extra
    // exhaust event is counted.
    single_a(8'hA5); settle(1); exp_deliv=11;
    if(dut.rx_exh_cnt!==16'd1) bad("exhaust counter changed during recovery frame");
    read_desc(rd); check_desc(rd,4'd1); check_payload(rd[23:20],8'hA5);
    msg_rd; settle(0);
    host_read(16'h0100,rd); if(rd!==exp_deliv) bad("RX_DELIVER stat wrong");
    host_read(16'h0101,rd); if(rd!==32'd0) bad("PORT_DROP should not count NO_BLK");
    host_read(16'h0103,rd); if(rd!==32'd0) bad("Q_OVF should remain 0");

    begin : dump_rsrc
      integer fd;
      fd = $fopen("out/metrics/cover_rsrc.csv", "a");
      if (fd != 0) begin
        $fdisplay(fd, "%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",
                  u_cov_rsrc.n_free0, u_cov_rsrc.n_free1, u_cov_rsrc.n_free2,
                  u_cov_rsrc.n_free_gt2, u_cov_rsrc.n_sample, u_cov_rsrc.n_queue,
                  u_cov_rsrc.n_ovf, u_cov_rsrc.n_pdrop);
        $fclose(fd);
      end
    end

    if(errors==0)
      $display("T21 BLOCK-POOL PASS (IF_MODE=%0d filled=10 no_blk=%0d exhaust=%0d borrow=%0d returned=10 recovery=1 deliver=%0d no_pmem_empty=%0d)",
        IF_MODE, no_blk_pulses, dut.rx_exh_cnt, dut.rx_borrow_cnt, deliveries, pmem_during_empty);
    else
      $display("T21 BLOCK-POOL FAIL (IF_MODE=%0d errors=%0d)", IF_MODE, errors);
    $finish;
  end

  initial begin
    #80_000_000;
    $display("T21 BLOCK-POOL FAIL: timeout IF_MODE=%0d", IF_MODE);
    $finish;
  end
endmodule

module tb_t21_block_pool;  tb_t21_core #(.IF_MODE(0)) core(); endmodule
module tb_t21g_block_pool; tb_t21_core #(.IF_MODE(1)) core(); endmodule
