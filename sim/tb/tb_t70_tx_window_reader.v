`timescale 1 ns / 1 ps
module tb_t70_tx_window_reader;
  reg clk=0; always #4 clk=~clk;
  reg rst=1,start=0,cancel=0,grant_enable=0,byte_ready=0;
  reg [13:0] app_len=0,window_offset=0,window_len=0;
  reg [2:0] block_count=0;
  reg [15:0] blocks=0;
  wire start_ready,start_error,req_valid;
  wire [12:0] req_addr;
  wire byte_valid,byte_last,done;
  wire [7:0] byte_data;
  wire rsp_valid; wire [31:0] rsp_data;
  reg zero_latency=0;
  tx_pmem_window_reader dut (
    .clk(clk),.rst_sync(rst),.start(start),.start_ready(start_ready),
    .app_len(app_len),.block_count(block_count),.blocks(blocks),
    .window_offset(window_offset),.window_len(window_len),.cancel(cancel),
    .start_error(start_error),.pmem_req_valid(req_valid),
    .pmem_req_grant(grant_enable && req_valid),.pmem_req_addr(req_addr),
    .pmem_rsp_valid(rsp_valid),.pmem_rsp_data(rsp_data),
    .byte_valid(byte_valid),.byte_ready(byte_ready),.byte_data(byte_data),
    .byte_last(byte_last),.done(done));

  reg pending=0; reg [1:0] delay_count=0; reg [12:0] saved_addr=0;
  reg rsp_v=0; reg [31:0] rsp_d=0;
  function [7:0] mem_byte;
    input integer addr;
    begin mem_byte=(addr*13+7)&8'hff; end
  endfunction
  function [31:0] mem_word;
    input [12:0] addr;
    integer base;
    begin
      base=(addr>>9)*2048+(addr&511)*4;
      mem_word={mem_byte(base),mem_byte(base+1),mem_byte(base+2),mem_byte(base+3)};
    end
  endfunction
  assign rsp_valid = zero_latency ? (req_valid && grant_enable) : rsp_v;
  assign rsp_data = zero_latency ? mem_word(req_addr) : rsp_d;

  integer errors=0,monitor_errors=0,k,guard,physical,bi,accepted;
  reg req_hold=0, byte_stall=0, rsp_expected=0;
  reg [12:0] held_req_addr=0;
  reg [8:0] held_beat=0;

  always @(posedge clk) begin
    rsp_v<=0;
    if (rst) begin
      pending<=0; delay_count<=0; rsp_v<=0;
      req_hold<=0; byte_stall<=0; rsp_expected<=0;
    end
    else begin
      if (req_valid && grant_enable) begin
        if (pending || rsp_expected) begin
          $display("T70 FAIL overlapping PMEM request"); monitor_errors<=monitor_errors+1;
        end
        saved_addr<=req_addr;
        if (!zero_latency) begin
          pending<=1; rsp_expected<=1; delay_count<=2;
        end
      end
      if (pending) begin
        if (delay_count==0) begin
          rsp_v<=1;
          rsp_d<={mem_byte((saved_addr>>9)*2048+(saved_addr&511)*4),
                  mem_byte((saved_addr>>9)*2048+(saved_addr&511)*4+1),
                  mem_byte((saved_addr>>9)*2048+(saved_addr&511)*4+2),
                  mem_byte((saved_addr>>9)*2048+(saved_addr&511)*4+3)};
          pending<=0;
        end else delay_count<=delay_count-1;
      end
      if (rsp_valid) begin
        if (!rsp_expected && !(zero_latency && req_valid && grant_enable)) begin
          $display("T70 FAIL unsolicited PMEM response"); monitor_errors<=monitor_errors+1;
        end
        if (!zero_latency) rsp_expected<=0;
      end
      if (req_hold && req_valid && req_addr!==held_req_addr) begin
        $display("T70 FAIL request address changed while grant withheld");
        monitor_errors<=monitor_errors+1;
      end
      if (req_valid && !grant_enable) begin req_hold<=1; held_req_addr<=req_addr; end
      else req_hold<=0;
      if (byte_stall &&
          (!byte_valid || {byte_last,byte_data}!==held_beat)) begin
        $display("T70 FAIL byte output changed/dropped while stalled");
        monitor_errors<=monitor_errors+1;
      end
      if (byte_stall && byte_valid && byte_ready) byte_stall<=0;
      if (byte_valid && !byte_ready && !byte_stall) begin
        byte_stall<=1; held_beat<={byte_last,byte_data};
      end
    end
  end
  task run_window;
    input integer alen, off, wlen;
    input [2:0] nblk;
    input [15:0] ids;
    begin
      app_len=alen; window_offset=off; window_len=wlen;
      block_count=nblk; blocks=ids; grant_enable=0; byte_ready=0;
      @(negedge clk); start=1; @(negedge clk); start=0;
      if (start_error || !req_valid) begin $display("T70 FAIL start alen=%0d off=%0d len=%0d",alen,off,wlen); errors=errors+1; end
      k=0; guard=0; accepted=0;
      while (k<wlen && guard<100000) begin
        // Hold request without grant, then permit a grant; hold each response
        // behind the reader's explicit valid handshake by the memory model.
        if (req_valid && (guard%7)==0) grant_enable=1;
        else if (req_valid) grant_enable=0;
        if (byte_valid) begin
          physical=(off+k); bi=physical/2048;
          if (byte_data !== mem_byte((ids >> (4*bi) & 15)*2048+physical%2048)) begin
            $display("T70 FAIL byte offset=%0d got=%02x",off+k,byte_data); errors=errors+1;
          end
          if (byte_last !== (k==wlen-1)) begin $display("T70 FAIL last offset=%0d",k); errors=errors+1; end
          if ((guard%5)==0) byte_ready=0; else begin byte_ready=1; k=k+1; end
        end else byte_ready=0;
        @(negedge clk); guard=guard+1;
      end
      byte_ready=0; grant_enable=0;
      if (k!=wlen) begin $display("T70 FAIL byte count %0d/%0d",k,wlen); errors=errors+1; end
      guard=0; while (!done && guard<8) begin @(negedge clk); guard=guard+1; end
      if (!done) begin $display("T70 FAIL missing done"); errors=errors+1; end
      @(negedge clk);
    end
  endtask

  task reject_window;
    input integer alen, off, wlen;
    input [2:0] nblk;
    input [15:0] ids;
    begin
      app_len=alen; window_offset=off; window_len=wlen;
      block_count=nblk; blocks=ids; grant_enable=0; byte_ready=0; cancel=0;
      @(negedge clk); start=1; @(negedge clk); start=0;
      if (!start_error || req_valid || byte_valid) begin
        $display("T70 FAIL invalid window accepted alen=%0d off=%0d len=%0d",alen,off,wlen);
        errors=errors+1;
      end
      @(negedge clk);
    end
  endtask

  initial begin
    repeat(4) @(negedge clk); rst=0; repeat(2) @(negedge clk);
    // Split requests cross byte lanes and block boundaries, with holes in IDs.
    run_window(2047,1,2046,1,16'h0003);
    run_window(2048,2047,1,1,16'h0004);
    run_window(2049,2046,3,2,16'h0015);
    run_window(8191,8179,12,4,16'h5420);
    run_window(8192,2047,4099,4,16'h1350);
    // Zero-latency PMEM returns on the same cycle as grant.
    zero_latency=1;
    run_window(13,0,13,1,16'h0003);
    zero_latency=0;
    // Invalid block lists and windows must be rejected before any PMEM request.
    reject_window(2049,0,1,2,16'h0011); // duplicate block ID
    reject_window(2049,0,1,2,16'h0016); // block 6 is not in the TX pool
    reject_window(2048,0,0,1,16'h0002); // empty window
    reject_window(2048,2040,16,1,16'h0002); // offset + length exceeds app_len
    // Cancellation after grant but before response: drain stale response,
    // then restart and verify the new transaction's first bytes.
    app_len=2048; block_count=1; blocks=16'h0002; window_offset=0; window_len=8;
    grant_enable=1; @(negedge clk); start=1; @(negedge clk); start=0;
    guard=0; while (!req_valid && guard<20) begin @(negedge clk); guard=guard+1; end
    if (!req_valid) begin $display("T70 FAIL request missing before cancel"); errors=errors+1; end
    @(negedge clk); cancel=1; @(negedge clk); cancel=0;
    guard=0; while (start_ready!==1 && guard<20) begin @(negedge clk); guard=guard+1; end
    if (!start_ready) begin $display("T70 FAIL drain did not return idle"); errors=errors+1; end
    run_window(2048,0,8,1,16'h0002);
    // Cancel during EMIT while a consumer is ready. No byte may be accepted.
    app_len=2048; block_count=1; blocks=16'h0002; window_offset=0; window_len=8;
    grant_enable=1; byte_ready=1;
    @(negedge clk); start=1; @(negedge clk); start=0;
    guard=0; while (!byte_valid && guard<30) begin @(negedge clk); guard=guard+1; end
    if (!byte_valid) begin $display("T70 FAIL byte stream missing before cancel"); errors=errors+1; end
    else begin
      @(negedge clk); cancel=1;
      #1; // allow the cancel-gated combinational valid output to settle
      if (byte_valid) begin $display("T70 FAIL byte_valid visible during cancel"); errors=errors+1; end
      @(negedge clk); cancel=0;
    end
    byte_ready=0; grant_enable=0;
    if (done) begin $display("T70 FAIL cancel asserted done"); errors=errors+1; end
    repeat(2) @(negedge clk);
    if(errors==0 && monitor_errors==0) $display("T70 TX_WINDOW_READER PASS");
    else $display("T70 TX_WINDOW_READER FAIL errors=%0d monitor_errors=%0d",errors,monitor_errors);
    $finish;
  end
endmodule
