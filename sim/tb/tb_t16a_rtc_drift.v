// Isolated RTC FLL STRICT regression: old P-only RTL fails by construction.
// The local second is scaled to 100,000 ticks, with +/-20 or +50 ticks per
// second standing in for +/-20 or +50 ppm at a real 1 Hz PPS. This tests the
// loop dynamics, not a physical 1 Hz oscillator or board-level CDC.
`timescale 1ns/1ps
module tb_t16a_rtc_drift;
  localparam integer USEC=100000, NPPS=20, NSTEADY=10;
  reg clk=0; always #4 clk=~clk;
  reg rst=1,pps=0;
  reg [63:0] free_us=0;
  wire [63:0] rtc_us, rtc_old;
  wire pps_out,sync_loss,locked,pps_out_old,loss_old,lock_old;
  wire [31:0] err,jumps,steps,pps_count,phase;
  wire [31:0] old_err,old_jump,old_step,old_pps,old_phase;
  rtc_sync #(.US_PER_SEC(USEC),.SYNC_TIMEOUT(250000),.LOCK_N(3),.FREQ_LOCK_EN(1)) dut (
    .clk(clk),.rst_sync(rst),.en(1'b1),.hold(1'b0),.tick_us(!rst),.rtc_free_us(free_us),
    .pps_in(pps),.sync_vld(1'b0),.sync_master_ts(64'd0),.path_est_us(16'd0),
    .th_jump_us(8'd100),.log2_avg(4'd2),
    .rtc_time_us(rtc_us),.pps_out(pps_out),.sync_loss(sync_loss),.locked(locked),
    .last_err_us(err),.jump_cnt(jumps),.step_cnt(steps),.pps_cnt(pps_count),.sec_phase(phase));
  // Negative control: identical stimulus with the original P-only law.
  rtc_sync #(.US_PER_SEC(USEC),.SYNC_TIMEOUT(250000),.LOCK_N(3),.FREQ_LOCK_EN(0)) p_only (
    .clk(clk),.rst_sync(rst),.en(1'b1),.hold(1'b0),.tick_us(!rst),.rtc_free_us(free_us),
    .pps_in(pps),.sync_vld(1'b0),.sync_master_ts(64'd0),.path_est_us(16'd0),
    .th_jump_us(8'd100),.log2_avg(4'd2),
    .rtc_time_us(rtc_old),.pps_out(pps_out_old),.sync_loss(loss_old),.locked(lock_old),
    .last_err_us(old_err),.jump_cnt(old_jump),.step_cnt(old_step),.pps_cnt(old_pps),.sec_phase(old_phase));
  always @(posedge clk) if(rst) free_us<=0; else free_us<=free_us+64'd1;
  integer cyc=0, errors=0, checks=0;
  always @(posedge clk) cyc<=cyc+1;
  task chk(input bit valid,input [8*100-1:0] msg);
    begin checks=checks+1; if(!valid)begin errors=errors+1; if(errors<35)$display("FLL_STRICT_FAIL t=%0t %0s",$time,msg);end end
  endtask
  task wait_cyc(input integer target);
    begin while(cyc<target)@(negedge clk);end
  endtask
  function integer iabs(input integer x);iabs=(x<0)?-x:x;endfunction

  task run_case;
    input [8*4-1:0] name;
    input integer d_even,d_odd;
    integer n,t,per,e,eo,pps0,maxe,maxold,quarter,observed,expected,q,steady_count;
    reg [63:0] anchor;
    reg [63:0] scaled;
    begin
      @(negedge clk);rst=1;pps=0;repeat(5)@(negedge clk);rst=0;
      t=cyc+30000;
      maxe=0;maxold=0;steady_count=0;pps0=0;
      for(n=0;n<NPPS;n=n+1)begin
        wait_cyc(t);pps=1;
        wait_cyc(t+10);pps=0;
        wait_cyc(t+20);
        e=$signed(err);eo=$signed(old_err);
        if(n==0)begin chk(jumps==1,"first PPS must acquire in one jump");pps0=pps_count;end
        if(n>=3)chk(iabs(e)<=1,"PPS phase error exceeds 1us after rate learned");
        if(n>=NPPS-NSTEADY)begin
          if(iabs(e)>maxe)maxe=iabs(e);
          if(iabs(eo)>maxold)maxold=iabs(eo);
          steady_count=steady_count+1;
        end
        per=USEC+((n%2==0)?d_even:d_odd);
        // Sample continuous timestamp slope at three quarters of each steady
        // second, relative to the corrected timestamp after the PPS. The
        // expected elapsed true microseconds are floor(local_ticks*USEC/per).
        if(n>=3 && n<NPPS-1)begin
          anchor=rtc_us;
          for(q=1;q<=3;q=q+1)begin
            quarter=(per*q)/4;
            wait_cyc(t+20+quarter);
            scaled=({32'd0,quarter}*USEC)/per;
            expected=scaled[31:0];
            observed=$signed(rtc_us[31:0]-anchor[31:0]);
            chk(iabs(observed-expected)<=1,"within-second corrected timestamp slope >1us");
          end
        end
        t=t+per;
      end
      chk(steady_count==NSTEADY,"steady PPS count wrong");
      chk(maxe<=1,"last ten PPS failed <=1us under drift");
      chk(jumps==1,"unexpected repeated PPS phase jump with FLL");
      chk(locked===1'b1,"frequency-locked PPS did not lock");
      chk(sync_loss===1'b0,"false SYNC_LOSS while PPS present");
      chk(pps_count-pps0>=NPPS-2,"local PPS output stopped");
      if(d_even!=0 || d_odd!=0)
        chk(maxold>1,"negative P-only control did not fail <=1us claim");
      $display("FLL_METRIC case=%0s drift_ppm_eq=%0d/%0d steady_pps_max_abs_err_us=%0d old_P_only_max_err_us=%0d jumps=%0d steps=%0d locked=%0d tests=%0d",
               name,d_even,d_odd,maxe,maxold,jumps,steps,locked,checks);
    end
  endtask
  initial begin
    repeat(5)@(negedge clk);
    run_case("A",0,0);
    run_case("B",20,20);
    run_case("C",-20,-20);
    run_case("D",50,50);
    run_case("E",0,1);
    if(errors==0)$display("T16a FLL STRICT PASS (PPS <=1us and three within-second samples <=1us; P-only negative control; %0d checks)",checks);
    else $display("T16a FLL STRICT FAIL errors=%0d checks=%0d",errors,checks);
    $finish;
  end
  initial begin #200_000_000;$display("T16a FLL STRICT FAIL watchdog");$finish;end
endmodule
