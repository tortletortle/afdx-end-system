`timescale 1 ns / 1 ps
module tb_t77_fetch_abort_restart;
  reg clk=0; always #4 clk=~clk;
  reg rst=1, en=1, start=0, start_write=1, abort=0;
  reg [31:0] server_ip=32'h0A000002;
  reg [15:0] local_tid=16'h3001, timeout_ticks=16'd50;
  reg [2047:0] filename=0;
  reg [7:0] filename_len=8'd4;
  reg timeout_tick=0;
  reg sap_vld=0, sap_sop=0, sap_eop=0;
  reg [7:0] sap_data=0;
  reg [15:0] sap_sport=16'd40100, sap_dport=16'h3001;
  reg [31:0] sap_srcip=32'h0A000002;
  wire sap_ready;
  wire pkt_vld; wire [10:0] pkt_len; wire [31:0] pkt_dst_ip;
  wire [15:0] pkt_src_port,pkt_dst_port; reg [10:0] pkt_rd_addr=0;
  wire [7:0] pkt_byte; reg pkt_ack=0;
  wire start_ready,busy,done,failed; wire [3:0] failure_code;
  wire [31:0] rx_bytes; wire file_busy,file_valid; wire [13:0] file_length;
  wire [1:0] file_error_code; wire [31:0] ok_cnt,drop_cnt;
  reg file_ack=0,rd_en=0; reg [12:0] rd_addr=0; wire rd_valid; wire [7:0] rd_data;
  wire upload_block_req; wire [15:0] upload_block_number;
  reg preload_start=0,preload_data_valid=0,preload_commit=0,preload_abort=0;
  reg [7:0] preload_data=0; reg [13:0] preload_length=0;
  wire preload_start_ready,preload_data_ready,preload_error;
  integer errors=0, checks=0, guard, k, nbytes, nblocks, bno, plen, idx;
  reg [7:0] rxpkt[0:3];

  a615a_fetch_engine dut (
    .clk(clk),.rst_sync(rst),.en(en),
    .sap_vld(sap_vld),.sap_sop(sap_sop),.sap_eop(sap_eop),.sap_data(sap_data),
    .sap_sport(sap_sport),.sap_dport(sap_dport),.sap_srcip(sap_srcip),.sap_ready(sap_ready),
    .pkt_vld(pkt_vld),.pkt_len(pkt_len),.pkt_dst_ip(pkt_dst_ip),
    .pkt_src_port(pkt_src_port),.pkt_dst_port(pkt_dst_port),
    .pkt_rd_addr(pkt_rd_addr),.pkt_byte(pkt_byte),.pkt_ack(pkt_ack),
    .start(start),.start_ready(start_ready),.start_write(start_write),
    .server_ip(server_ip),.local_tid(local_tid),.filename(filename),.filename_len(filename_len),
    .timeout_ticks(timeout_ticks),.timeout_tick(timeout_tick),.abort(abort),
    .upload_block_req(upload_block_req),.upload_block_number(upload_block_number),
    .preload_start(preload_start),.preload_start_ready(preload_start_ready),
    .preload_data_valid(preload_data_valid),.preload_data_ready(preload_data_ready),
    .preload_data(preload_data),.preload_commit(preload_commit),
    .preload_length(preload_length),.preload_abort(preload_abort),.preload_error(preload_error),
    .busy(busy),.done(done),.failed(failed),.failure_code(failure_code),.rx_bytes(rx_bytes),
    .file_busy(file_busy),.file_valid(file_valid),.file_ack(file_ack),
    .file_length(file_length),.file_error_code(file_error_code),
    .rd_en(rd_en),.rd_addr(rd_addr),.rd_valid(rd_valid),.rd_data(rd_data),
    .ok_cnt(ok_cnt),.drop_cnt(drop_cnt)
  );

  function [7:0] data_byte;
    input integer x;
    begin data_byte=(x*13+8'h5B)&8'hFF; end
  endfunction
  task chk;
    input cond; input [8*80-1:0] msg;
    begin checks=checks+1; if(!cond) begin errors=errors+1; $display("FAIL: %0s",msg); end end
  endtask
  task wait_packet;
    begin guard=0; while(pkt_vld!==1'b1 && guard<30000) begin @(negedge clk); guard=guard+1; end
      chk(pkt_vld===1'b1,"packet timeout"); end
  endtask
  task consume_packet;
    begin @(negedge clk); pkt_ack=1; @(negedge clk); pkt_ack=0; end
  endtask
  task expect_rrq_wrq;
    begin wait_packet();
      pkt_rd_addr=1; #1; chk(pkt_byte===(start_write ? 8'h02 : 8'h01),"request opcode");
      pkt_rd_addr=2; #1; chk(pkt_byte===8'h54,"WRQ filename");
      consume_packet();
    end
  endtask
  task send_ack;
    input integer blockno;
    integer j;
    reg [7:0] aa[0:3];
    begin
      aa[0]=0; aa[1]=4; aa[2]=(blockno>>8)&255; aa[3]=blockno&255;
      for(j=0;j<4;j=j+1) begin
        @(negedge clk); sap_vld=1; sap_sop=(j==0); sap_eop=(j==3); sap_data=aa[j];
        while(sap_ready!==1'b1) @(negedge clk);
        @(posedge clk);
      end
      @(negedge clk); sap_vld=0; sap_sop=0; sap_eop=0;
    end
  endtask
  task send_source_block;
    input integer blockno; input integer length; input integer offset; input integer last;
    integer j;
    begin
      guard=0; while((upload_block_req!==1'b1 || upload_block_number!==blockno[15:0]) && guard<30000) begin @(negedge clk); guard=guard+1; end
      chk(upload_block_req===1'b1,"source request");
      wait_packet();
      chk(upload_block_req===1'b0,"internal file source served request");
      chk(pkt_len===length+4,"DATA length");
      pkt_rd_addr=1; #1; chk(pkt_byte===8'h03,"DATA opcode");
      pkt_rd_addr=2; #1; chk(pkt_byte===((blockno>>8)&255),"DATA block high");
      pkt_rd_addr=3; #1; chk(pkt_byte===(blockno&255),"DATA block low");
      for(j=0;j<length;j=j+1) begin pkt_rd_addr=4+j; #1; chk(pkt_byte===data_byte(offset+j),"DATA payload byte"); end
      consume_packet();
    end
  endtask
  task preload_file;
    input integer length;
    integer j;
    begin
      guard=0; while(preload_start_ready!==1'b1 && guard<1000) begin @(negedge clk); guard=guard+1; end
      chk(preload_start_ready===1'b1,"preload ready");
      @(negedge clk); preload_start=1; @(posedge clk); @(negedge clk); preload_start=0;
      for(j=0;j<length;j=j+1) begin
        @(negedge clk); preload_data=data_byte(j); preload_data_valid=1;
        while(preload_data_ready!==1'b1) @(negedge clk);
        @(posedge clk); @(negedge clk); preload_data_valid=0;
      end
      @(negedge clk); preload_length=length; preload_commit=1;
      @(posedge clk); @(negedge clk); preload_commit=0;
      chk(file_valid===1'b1 && file_length===length && preload_error===1'b0,"preload file committed");
    end
  endtask
  task run_length;
    input integer length;
    integer remn, off, blockno, count, z;
    begin
      @(negedge clk); start=1; @(negedge clk); start=0;
      expect_rrq_wrq();
      send_ack(0);
      count=(length==0)?1:((length+511)/512); off=0; blockno=1;
      for(z=0;z<count;z=z+1) begin
        remn=length-off; if(remn>512) remn=512;
        send_source_block(blockno,remn,off,(off+remn==length));
        send_ack(blockno); off=off+remn; blockno=blockno+1;
      end
      if(length>0 && (length%512)==0) begin
        send_source_block(blockno,0,length,1); send_ack(blockno);
      end
      guard=0; while(done!==1'b1 && guard<30000) begin @(negedge clk); guard=guard+1; end
      chk(done===1'b1 && failed===1'b0 && busy===1'b0,"upload job done");
      chk(file_valid===1'b0,"upload does not publish download file");
    end
  endtask
  task timeout_pulses;
    input integer count;
    integer q;
    begin
      for(q=0;q<count;q=q+1) begin
        @(negedge clk); timeout_tick=1;
        @(negedge clk); timeout_tick=0;
      end
    end
  endtask
  task send_download_data512;
    integer q;
    reg [7:0] byte_value;
    begin
      for(q=0;q<516;q=q+1) begin
        case(q)
          0: byte_value=8'h00;
          1: byte_value=8'h03;
          2: byte_value=8'h00;
          3: byte_value=8'h01;
          default: byte_value=data_byte(q-4);
        endcase
        @(negedge clk); sap_vld=1; sap_sop=(q==0); sap_eop=(q==515); sap_data=byte_value;
        while(sap_ready!==1'b1) @(negedge clk);
        @(posedge clk);
      end
      @(negedge clk); sap_vld=0; sap_sop=0; sap_eop=0;
    end
  endtask

  initial begin
    filename[2047 -:8]="T"; filename[2039 -:8]="E"; filename[2031 -:8]="S"; filename[2023 -:8]="T";
    repeat(4) @(negedge clk); rst=0; repeat(3) @(negedge clk);
    preload_file(1);
    // Abort with a WRQ still buffered at the packet interface. No stale packet may survive.
    @(negedge clk); start=1; @(negedge clk); start=0;
    wait_packet(); pkt_rd_addr=1; #1; chk(pkt_byte===8'h02,"abort case began as WRQ");
    @(negedge clk); abort=1; @(negedge clk); abort=0;
    chk(failed===1'b1 && busy===1'b0 && done===1'b0,"abort is terminal failure");
    chk(pkt_vld===1'b0,"abort clears unsent packet");
    chk(file_valid===1'b1 && file_length===14'd1,"WRQ abort preserves committed file");

    // Disable after the shared file reader has supplied DATA1. The buffered
    // packet and reader request are cancelled, while the committed file stays.
    @(negedge clk); start=1; @(negedge clk); start=0;
    expect_rrq_wrq(); send_ack(0); wait_packet();
    chk(upload_block_req===1'b0,"reader request retires after DATA block formed");
    @(negedge clk); en=0; repeat(4) @(negedge clk);
    chk(failed===1'b1 && pkt_vld===1'b0,"disable cancels WRQ and pending DATA");
    chk(upload_block_req===1'b0,"disable clears upload reader state");
    chk(file_valid===1'b1 && file_length===14'd1,"disable preserves committed upload file");
    en=1;

    // Restart, then exhaust the initial WRQ/timeout retries without ACK0.
    @(negedge clk); start=1; @(negedge clk); start=0;
    expect_rrq_wrq();
    for(k=0;k<5;k=k+1) begin
      timeout_pulses(50);
      expect_rrq_wrq();
    end
    timeout_pulses(50);
    guard=0; while(failed!==1'b1 && guard<100) begin @(negedge clk); guard=guard+1; end
    chk(failed===1'b1 && busy===1'b0 && done===1'b0,"retry exhaustion fails job");
    chk(failure_code===4'd2,"retry exhaustion reports timeout");

    // A fresh start after failure is independent and can complete normally.
    @(negedge clk); start=1; @(negedge clk); start=0;
    expect_rrq_wrq(); send_ack(0);
    send_source_block(1,1,0,1); send_ack(1);
    guard=0; while(done!==1'b1 && guard<30000) begin @(negedge clk); guard=guard+1; end
    chk(done===1'b1 && failed===1'b0 && busy===1'b0,"restart after timeout completes");
    chk(file_valid===1'b1 && file_length===14'd1,"WRQ completion retains committed file");
    @(negedge clk); file_ack=1; @(negedge clk); file_ack=0;
    chk(file_valid===1'b0,"file ACK releases upload buffer before RRQ");

    // Disable a download while RRQ is still buffered. Both TX and partial-file
    // ownership must be cleared, including the adapter's delayed abort handshake.
    start_write=0;
    @(negedge clk); start=1; @(negedge clk); start=0;
    wait_packet(); pkt_rd_addr=1; #1; chk(pkt_byte===8'h01,"disable case began as RRQ");
    consume_packet();
    send_download_data512();
    wait_packet(); pkt_rd_addr=1; #1; chk(pkt_byte===8'h04,"partial download ACK pending");
    repeat(600) @(negedge clk);
    chk(file_busy===1'b1,"download adapter owns partial file buffer");
    chk(file_valid===1'b0,"partial file has not been published");
    @(negedge clk); en=0;
    repeat(4) @(negedge clk);
    chk(failed===1'b1 && busy===1'b0,"disable fails active download job");
    chk(pkt_vld===1'b0,"disable clears pending RRQ packet");
    chk(file_busy===1'b0 && file_valid===1'b0,"disable abort clears partial file");
    chk(upload_block_req===1'b0,"download disable leaves upload source idle");
    en=1;
    if(errors==0) $display("T77 PASS checks=%0d",checks); else $display("T77 FAIL errors=%0d checks=%0d",errors,checks);
    $finish;
  end
  initial begin #50000000; $display("T77 WATCHDOG"); $finish; end
endmodule

