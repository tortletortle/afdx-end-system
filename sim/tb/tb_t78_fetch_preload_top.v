// T78 — verify host preload registers through the public AFDX_top host port.
// This checks the top-level byte source, commit/length handshake, file
// publication, readback, direction latch, and explicit file release.
`timescale 1 ns / 1 ps
module tb_t78_fetch_preload_top;
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
  afdx_host_bfm u_host (.clk(clk),.cs(hcs),.we(hwe),.addr(haddr),
                        .wdata(hwdata),.rdata(hrdata),.ack(hack));

  integer errors=0, i, no_early_ack;
  reg [31:0] value;
  reg [7:0] expected [0:3];

  task check;
    input cond;
    input [8*96-1:0] label_text;
    begin
      if (!cond) begin
        if (errors<20) $display("  [err] T78 %0s",label_text);
        errors=errors+1;
      end
    end
  endtask

  initial begin
    expected[0]=8'hA5; expected[1]=8'h00;
    expected[2]=8'h5A; expected[3]=8'hC3;
    repeat(10) @(negedge clk);
    reset=0;
    repeat(3) @(negedge clk);

    // Enable the 615A engine, then begin staging into its shared file buffer.
    u_host.wr(16'h0008,32'h0000_0200);
    u_host.stall_probe_write(16'hAC40,32'h0000_0005,3,no_early_ack);
    check(no_early_ack===1,"WRQ start waits while the file source is unavailable");
    u_host.stall_probe_write(16'hAC55,32'h0000_00FF,3,no_early_ack);
    check(no_early_ack===1,"preload byte write waits until preload has started");
    u_host.wr(16'hAC57,32'h0000_0001);
    for (i=0;i<4;i=i+1) u_host.wr(16'hAC55,{24'd0,expected[i]});
    u_host.wr(16'hAC56,32'd4);
    repeat(3) @(negedge clk);

    u_host.rd(16'hAC4C,value);
    check(value[13:0]===14'd4,"committed file length is four bytes");
    check(value[17:16]===2'd0,"preload has no file error");
    u_host.rd(16'hAC4D,value);
    check(value[0]===1'b1,"committed file is published");

    // Start a WRQ while selecting its direction in the same public register
    // write. This exercises ready against the prospective mode, not stale mode.
    u_host.wr(16'hAC41,32'h0A00_0002);
    u_host.wr(16'hAC42,32'h5445_5354); // filename "TEST"
    u_host.wr(16'hAC4A,32'd4);
    u_host.wr(16'hAC40,32'h0000_0005);
    repeat(3) @(negedge clk);
    u_host.rd(16'hAC40,value);
    check(value[1]===1'b1,"same-write WRQ start is accepted");
    u_host.rd(16'hAC57,value);
    check(value[3]===1'b1,"WRQ direction bit is retained");
    check(value[2]===1'b0,"preload error remains clear");

    // Cancel quickly; the committed upload source remains owned by the host.
    u_host.wr(16'hAC40,32'h0000_0002);
    repeat(3) @(negedge clk);
    u_host.rd(16'hAC40,value);
    check(value[1]===1'b0,"aborted WRQ releases engine ownership");
    check(value[2]===1'b1,"aborted WRQ reports failure");

    for (i=0;i<4;i=i+1) begin
      u_host.wr(16'hAC4E,i);
      repeat(2) @(negedge clk);
      u_host.rd(16'hAC4F,value);
      check(value[7:0]===expected[i],"host readback byte matches preload");
    end

    // A committed buffer remains available until explicit host acknowledgement.
    u_host.wr(16'hAC4D,32'd1);
    repeat(2) @(negedge clk);
    u_host.rd(16'hAC4D,value);
    check(value[0]===1'b0,"file_ack releases the committed buffer");
    check(u_host.errors===0,"host bus completed every transaction");

    if(errors==0) $display("T78 FETCH PRELOAD TOP PASS");
    else $display("T78 FETCH PRELOAD TOP FAIL errors=%0d",errors);
    $finish;
  end
endmodule
