// RTC candidate only: a burst of +/-550 microseconds per 1-PPS interval and
// sync-loss/reacquisition. Shortened second is deliberately a *stress* model:
// 550/100000 local ticks is 10x the fractional error of 550 ppm at 1 MHz;
// the per-PPS absolute phase displacement is still 550 us. This is not a
// board-level oscillator or CDC measurement.
`timescale 1ns/1ps
module tb_t16b_fll_disturb;
 localparam integer U=100000;
 reg clk=0; always #4 clk=~clk;
 reg rst=1,pps=0;
 reg [63:0] free_us=0;
 wire [63:0] rtc_us,old_us;
 wire pps_out,loss,locked,old_out,old_loss,old_lock;
 wire [31:0] err,jumps,steps,ppsc,phase;
 wire [31:0] old_err,old_j,old_s,old_p,old_phase;
 rtc_sync #(.US_PER_SEC(U),.SYNC_TIMEOUT(250000),.LOCK_N(3),.FREQ_LOCK_EN(1)) dut (
  .clk(clk),.rst_sync(rst),.en(1'b1),.hold(1'b0),.tick_us(!rst),.rtc_free_us(free_us),
  .pps_in(pps),.sync_vld(1'b0),.sync_master_ts(64'd0),.path_est_us(16'd0),
  .th_jump_us(8'd100),.log2_avg(4'd2),.rtc_time_us(rtc_us),
  .pps_out(pps_out),.sync_loss(loss),.locked(locked),.last_err_us(err),
  .jump_cnt(jumps),.step_cnt(steps),.pps_cnt(ppsc),.sec_phase(phase));
 rtc_sync #(.US_PER_SEC(U),.SYNC_TIMEOUT(250000),.LOCK_N(3),.FREQ_LOCK_EN(0)) control (
  .clk(clk),.rst_sync(rst),.en(1'b1),.hold(1'b0),.tick_us(!rst),.rtc_free_us(free_us),
  .pps_in(pps),.sync_vld(1'b0),.sync_master_ts(64'd0),.path_est_us(16'd0),
  .th_jump_us(8'd100),.log2_avg(4'd2),.rtc_time_us(old_us),
  .pps_out(old_out),.sync_loss(old_loss),.locked(old_lock),.last_err_us(old_err),
  .jump_cnt(old_j),.step_cnt(old_s),.pps_cnt(old_p),.sec_phase(old_phase));
 always @(posedge clk)if(rst)free_us<=0;else free_us<=free_us+64'd1;
 integer cyc=0,errors=0,checks=0;
 always @(posedge clk)cyc<=cyc+1;
 task chk(input bit yes,input [8*104-1:0] what);
  begin checks=checks+1;if(!yes)begin errors=errors+1;if(errors<30)$display("FLL_B_FAIL t=%0t %0s",$time,what);end end
 endtask
 task waitcyc(input integer target);begin while(cyc<target)@(negedge clk);end endtask
 task pulse(input integer target);
  begin waitcyc(target);pps=1;waitcyc(target+10);pps=0;waitcyc(target+20);end
 endtask
 function integer absval(input integer e);absval=(e<0)?-e:e;endfunction
 task drift_case(input [8*8-1:0] name,input integer drift);
  integer n,t,per,maxe,maxold,anchor,q,quarter,observed,expected;
  begin
   @(negedge clk);rst=1;pps=0;repeat(5)@(negedge clk);rst=0;
   per=U+drift;t=cyc+30000;maxe=0;maxold=0;
   for(n=0;n<12;n=n+1)begin
    pulse(t);
    if(n==0)chk(jumps==1,"initial phase acquisition jump missing");
    if(n>=4)begin
     if(absval($signed(err))>maxe)maxe=absval($signed(err));
     if(absval($signed(old_err))>maxold)maxold=absval($signed(old_err));
     chk(absval($signed(err))<=1,"PPS error >1us after FLL training");
     // Spot-check the continuous corrected clock, not merely PPS registers.
     anchor=rtc_us[31:0];
     for(q=1;q<=3;q=q+1)begin
      quarter=per*q/4;
      waitcyc(t+20+quarter);
      expected=({32'd0,quarter}*U)/per;
      observed=$signed(rtc_us[31:0])-anchor;
      chk(absval(observed-expected)<=1,"within-second timestamp slope >1us");
     end
    end
    t=t+per;
   end
   chk(maxe<=1,"steady +/-550us per PPS failed <=1us");
   chk(maxold>1,"P-only negative control not discriminative");
   chk(jumps<=2,"repeated late PPS jumps after rate lock");
   chk(locked===1'b1 && loss===1'b0,"stable PPS did not lock cleanly");
   $display("FLL_B_METRIC case=%0s d_us_per_pps=%0d steady_pps_max=%0d P_only_max=%0d jumps=%0d locked=%0d",name,drift,maxe,maxold,jumps,locked);
  end
 endtask
 integer t0,n,j0;
 initial begin
  repeat(5)@(negedge clk);
  drift_case("fast",550);
  drift_case("slow",-550);
  // With a locked -550us/interval FLL, omit >2.5s of PPS to trigger loss.
  t0=cyc+265000;waitcyc(t0);
  chk(loss===1'b1 && locked===1'b0,"missing PPS not recognized as SYNC_LOSS");
  j0=jumps;
  for(n=0;n<8;n=n+1)begin
   pulse(t0);if(n==0)chk(loss===1'b0,"SYNC_LOSS did not clear on PPS recovery");
   if(n>=4)chk(absval($signed(err))<=1,"post-loss reacquisition failed <=1us");
   t0=t0+U-550;
  end
  chk(locked===1'b1,"lock did not return after PPS recovery");
  chk(jumps>=j0,"jump count corrupted during reacquisition");
  $display("FLL_B_METRIC recovery_locked=%0d loss_cleared=%0d recovery_jumps=%0d tests=%0d",locked,!loss,jumps-j0,checks);
  if(errors==0)$display("T16b FLL DISTURB PASS (%0d checks)",checks);
  else $display("T16b FLL DISTURB FAIL (%0d errors in %0d checks)",errors,checks);
  $finish;
 end
 initial begin #300_000_000;$display("T16b FLL DISTURB FAIL WATCHDOG");$finish;end
  // Optional bounded VCD: capture both the loss edge and the first
  // reacquisition PPS. Without +FLL_WAVE, zero waveform overhead.
  initial begin
    if ($test$plusargs("FLL_WAVE")) begin
      $dumpfile("fll_disturb_bounded.vcd");
      $dumpvars(0,tb_t16b_fll_disturb);
      $dumpoff;
      wait(loss===1'b1); $dumpon;
      repeat(600)@(posedge clk); $dumpoff;
      wait(pps===1'b1); $dumpon;
      repeat(1000)@(posedge clk); $dumpoff;
    end
  end
endmodule
