// Independent Python vectors plus a delayed/grant-stalled PMEM model.
// Each fragment is tested with arbitrary output backpressure, then both GMII MACs.
`timescale 1 ns / 1 ps
module tb_tx_fragment_frame_builder;
  reg clk=0, rst_sync=1;
  always #4 clk=~clk;
  reg start=0, cancel=0;
  wire start_ready, busy, done, error;
  reg [13:0] app_len=0, fragment_offset=0;
  reg [15:0] blocks=0, identification=0;
  reg [2:0] block_count=0;
  reg [7:0] sn=0;
  reg csum=0;
  wire req, rsp;
  wire [12:0] addr;
  reg grant=0, response_valid=0;
  reg [31:0] response_data=0;
  wire valid, sof, eof;
  wire [7:0] byte_a, byte_b;
  wire last_fragment;
  wire [13:0] next_offset;
  wire [10:0] payload_length;
  integer mode=0, cycle=0, errors=0, checks=0, cases=0;
  wire ready_a, ready_b;
  wire ready = mode == 1 ? ready_a && ready_b : (cycle % 7 != 1 && cycle % 7 != 2);
  tx_fragment_frame_builder dut (
    .clk(clk), .rst_sync(rst_sync), .start(start), .cancel(cancel), .start_ready(start_ready),
    .app_len(app_len), .blocks(blocks), .block_count(block_count), .fragment_offset(fragment_offset),
    .identification(identification), .vlid(16'h0105), .udi(16'h1234),
    .ifid_a(3'd1), .ifid_b(3'd2), .tos(8'h2c), .ttl(8'd64), .sequence_number(sn),
    .source_ip(32'hc0a80101), .destination_ip(32'hc0a80102),
    .source_port(16'h1234), .destination_port(16'h5678), .udp_checksum_enable(csum),
    .pmem_req_valid(req), .pmem_req_grant(grant), .pmem_req_addr(addr),
    .pmem_rsp_valid(response_valid), .pmem_rsp_data(response_data),
    .out_valid(valid), .out_ready(ready), .out_byte_a(byte_a), .out_byte_b(byte_b),
    .out_sof(sof), .out_eof(eof), .done(done), .error(error), .busy(busy),
    .last_fragment(last_fragment), .next_fragment_offset(next_offset), .fragment_payload_len(payload_length)
  );
  wire txv_a, txv_b, mac_busy_a, mac_busy_b;
  wire [7:0] txd_a, txd_b;
  wire [15:0] underrun_a, underrun_b;
  mac_tx_if #(.IF_MODE(2), .PREAMBLE_EN(1), .FCS_MODE(2)) mac_a (
    .clk(clk), .rst_sync(rst_sync), .in_vld(valid && mode == 1 && ready),
    .in_byte(byte_a), .in_sof(sof), .in_eof(eof), .in_rdy(ready_a),
    .pace_en(1'b1), .start_permit(1'b1), .link_rdy(1'b0), .tx_data(txd_a), .tx_valid(txv_a),
    .tx_ready(), .frame_start(), .frame_done(), .busy(mac_busy_a), .underrun_cnt(underrun_a)
  );
  mac_tx_if #(.IF_MODE(2), .PREAMBLE_EN(1), .FCS_MODE(2)) mac_b (
    .clk(clk), .rst_sync(rst_sync), .in_vld(valid && mode == 1 && ready),
    .in_byte(byte_b), .in_sof(sof), .in_eof(eof), .in_rdy(ready_b),
    .pace_en(1'b1), .start_permit(1'b1), .link_rdy(1'b0), .tx_data(txd_b), .tx_valid(txv_b),
    .tx_ready(), .frame_start(), .frame_done(), .busy(mac_busy_b), .underrun_cnt(underrun_b)
  );
  reg [31:0] memory [0:8191];
  reg outstanding=0;
  integer response_delay=0;
  reg [12:0] pending_addr=0;
  reg [31:0] pending_data=0;
  reg allow_response=1;
  task check;
    input condition;
    input [767:0] text;
    begin
      checks=checks+1;
      if (condition !== 1'b1) begin
        errors=errors+1;
        if (errors<20) $display("TX_FRAGMENT ERROR case=%0d mode=%0d: %0s", cases,mode,text);
      end
    end
  endtask
  always @(negedge clk) grant = req && !outstanding && cycle % 4 != 1;
  always @(posedge clk) begin
    cycle<=cycle+1;
    response_valid<=0;
    if (rst_sync) begin outstanding<=0; response_delay<=0; end
    else begin
      if (req && grant) begin
        check(!outstanding,"two outstanding PMEM requests");
        check(addr[12:9] <= 5,"read outside TX pool");
        outstanding<=1;
        pending_addr<=addr;
        pending_data<=memory[addr];
        response_delay<=1+cycle%7;
      end
      if (outstanding && allow_response) begin
        if (response_delay==0) begin
          response_valid<=1;
          response_data<=pending_data;
          outstanding<=0;
        end else response_delay<=response_delay-1;
      end
    end
  end

  reg [7:0] expected_body [0:1517];
  reg [7:0] recovery_body [0:59];
  reg [7:0] expected_wire_a [0:1529];
  reg [7:0] expected_wire_b [0:1529];
  integer body_count=0, wire_count_a=0, wire_count_b=0;
  integer body_length=0, wire_length=0, expected_last=0, expected_next=0, expected_payload=0;
  reg monitor=0, held=0, prev_tx_a=0, prev_tx_b=0, ended_a=0, ended_b=0;
  reg [17:0] held_tuple;
  always @(posedge clk) begin
    if (rst_sync || !monitor) begin held=0; prev_tx_a=0; prev_tx_b=0; ended_a=0; ended_b=0; end
    else begin
      if (held) check(valid && {sof,eof,byte_a,byte_b} === held_tuple,"output changed under backpressure");
      held=valid && !ready;
      held_tuple={sof,eof,byte_a,byte_b};
      if (valid && ready) begin
        check(body_count < body_length,"extra frame body byte");
        check(byte_a === expected_body[body_count],"A body byte mismatch");
        check(byte_b === (body_count==11 ? 8'h40 : expected_body[body_count]),"B body byte mismatch");
        check(sof === (body_count==0),"SOF mismatch");
        check(eof === (body_count==body_length-1),"EOF mismatch");
        body_count=body_count+1;
      end
      if (prev_tx_a && !txv_a) ended_a=1;
      if (prev_tx_b && !txv_b) ended_b=1;
      if (txv_a) begin
        check(!ended_a,"GMII A valid has a frame hole");
        check(wire_count_a<wire_length && txd_a===expected_wire_a[wire_count_a],"GMII A byte/FCS mismatch");
        wire_count_a=wire_count_a+1;
      end
      if (txv_b) begin
        check(!ended_b,"GMII B valid has a frame hole");
        check(wire_count_b<wire_length && txd_b===expected_wire_b[wire_count_b],"GMII B byte/FCS mismatch");
        wire_count_b=wire_count_b+1;
      end
      prev_tx_a=txv_a; prev_tx_b=txv_b;
    end
  end
  integer fd, rc, value, total, c, j, k, p, timeout, physical, word_address;
  reg [2047:0] vector_path="vec/tx_fragment_builder/cases.hex";
  reg [31:0] word;
  task get_word;
    output integer number;
    begin
      rc=$fscanf(fd,"%h",number);
      if (rc!=1) begin $display("TX_FRAGMENT ERROR malformed or truncated oracle"); $finish; end
    end
  endtask
  task launch;
    begin
      check(start_ready,"start not ready");
      start=1;
      @(negedge clk);start=0;
    end
  endtask
  task await_idle;
    begin
      timeout=0;
      while(!start_ready && timeout<100000) begin @(negedge clk); timeout=timeout+1; end
      check(start_ready,"builder failed to complete or drain");
    end
  endtask
  initial begin
    repeat(5) @(negedge clk);rst_sync=0;
    // Let reset gating and the combinational ready signal settle before launch.
    @(negedge clk);
    rc=$value$plusargs("TX_FRAGMENT_VECTORS=%s",vector_path);
    fd=$fopen(vector_path,"r");
    if (!fd) begin $display("TX_FRAGMENT ERROR missing oracle");$finish;end
    get_word(total);
    for (c=0;c<total;c=c+1) begin
      get_word(value);app_len=value;
      get_word(value);block_count=value;
      get_word(value);blocks=value;
      get_word(value);fragment_offset=value;
      get_word(value);csum=value;
      get_word(value);identification=value;
      get_word(value);sn=value;
      get_word(body_length);get_word(expected_last);get_word(expected_next);
      get_word(expected_payload);get_word(wire_length);
      for (j=0;j<app_len;j=j+1) begin
        get_word(value);
        case(j/2048)
          0: physical=blocks[3:0];1:physical=blocks[7:4];
          2:physical=blocks[11:8];default:physical=blocks[15:12];
        endcase
        word_address=physical*512+(j%2048)/4;
        if(j%4==0) word=0;
        word[31-8*(j%4) -:8]=value;
        memory[word_address]=word;
      end
      for(j=0;j<body_length;j=j+1) begin get_word(value);expected_body[j]=value;end
      if(c==0) for(j=0;j<60;j=j+1) recovery_body[j]=expected_body[j];
      for(j=0;j<wire_length;j=j+1) begin get_word(value);expected_wire_a[j]=value;end
      for(j=0;j<wire_length;j=j+1) begin get_word(value);expected_wire_b[j]=value;end
      for(p=0;p<2;p=p+1) begin
        mode=p; body_count=0;wire_count_a=0;wire_count_b=0; monitor=1;
        launch();await_idle();
        check(body_count==body_length,"body byte count mismatch");
        check(last_fragment===expected_last[0] && next_offset==expected_next && payload_length==expected_payload,"fragment metadata mismatch");
        check(!error,"unexpected builder error");
        if(mode==1) begin
          timeout=0;
          while((mac_busy_a || mac_busy_b || txv_a || txv_b || wire_count_a<wire_length || wire_count_b<wire_length) && timeout<5000) begin
            @(negedge clk);timeout=timeout+1;
          end
          check(wire_count_a==wire_length && wire_count_b==wire_length,"GMII byte count mismatch");
          check(underrun_a==0 && underrun_b==0,"GMII MAC underrun");
        end
        monitor=0;cases=cases+1;
        repeat(20) @(negedge clk);
      end
    end
    rc=$fscanf(fd,"%h",value);check(rc!=1,"unconsumed oracle data");$fclose(fd);
    // Invalid descriptor shapes must never emit even a partial frame.
    mode=0;csum=1;fragment_offset=0;app_len=8192;
    for(k=0;k<4;k=k+1) begin
      blocks=16'h0351;block_count=4;
      case(k)
        0: app_len=0;
        1: begin app_len=8192;block_count=3;end
        2: begin app_len=8192;blocks=16'h0311;end
        3: begin app_len=8192;fragment_offset=1;end
      endcase
      launch();timeout=0;
      while(!error && timeout<100) begin @(negedge clk);check(!valid,"invalid descriptor emitted bytes");timeout=timeout+1;end
      check(error,"invalid descriptor was accepted");await_idle();cases=cases+1;
      repeat(3) @(negedge clk);
    end
    // Cancel an outstanding read: busy must remain until its response drains.
    app_len=8192;blocks=16'h0351;block_count=4;fragment_offset=0;allow_response=0;
    launch();timeout=0;
    while(!outstanding && timeout<100) begin @(negedge clk);timeout=timeout+1;end
    check(outstanding,"cancel fixture did not create an outstanding read");
    cancel=1;@(negedge clk);cancel=0;
    repeat(12) begin @(negedge clk);check(busy && !valid && !start_ready && !done,"cancel released before PMEM drain");end
    allow_response=1;await_idle();check(!outstanding,"cancel left an outstanding read");cases=cases+1;
    // A clean subsequent transaction proves the drained response was not reused.
    app_len=1;block_count=1;blocks=16'h0001;csum=0;fragment_offset=0;
    identification=16'h1200;sn=8'h91;memory[512]=32'h03000000;
    body_length=60;body_count=0;wire_count_a=0;wire_count_b=0;
    for(j=0;j<60;j=j+1) expected_body[j]=recovery_body[j];
    monitor=1;launch();await_idle();
    check(!error && body_count==60,"restart after cancel failed");
    check(last_fragment && next_offset==9 && payload_length==9,"restart metadata mismatch");
    monitor=0;cases=cases+1;
    if(errors==0) $display("T80 TX_FRAGMENT_FRAME_BUILDER PASS cases=%0d fragments=%0d checks=%0d",cases,total,checks);
    else $display("T80 TX_FRAGMENT_FRAME_BUILDER FAIL errors=%0d checks=%0d",errors,checks);
    $finish;
  end
  initial begin #100000000; $display("T80 TX_FRAGMENT_FRAME_BUILDER FAIL timeout");$finish;end
endmodule
