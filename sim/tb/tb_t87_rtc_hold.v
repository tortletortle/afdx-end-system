// DRAFT ONLY: not compiled or run. Contract-derived checks, no DUT force.
// Default RTC parameters. One clock represents one us tick in tick=1 phases;
// this accelerates functional time, not a physical 125 MHz/1 Hz CDC test.
`timescale 1ns/1ps
module tb_t87_rtc_hold;
  reg clk=0, rst=1, en=1, hold=0, tick=0, pps=0, msg=0;
  always #4 clk=~clk;
  reg [63:0] free_us=0, master=0;
  wire [63:0] rtc;
  wire local_pps, loss, locked;
  wire [31:0] last_err, jumps, steps, ppsc, phase;
  integer errors=0, checks=0, cases=0, cyc=0, guard, i, target;
  reg [511:0] frozen;
  reg [63:0] old_bias, old_offset;
  reg [31:0] count0, old_phase;
  reg old_direction;
  reg track_loss=0;
  integer false_loss=0;

  // Compile the same tests against untouched production logic as a negative
  // control. That reference differs only in its module name, not behavior.
`ifdef RTC_HOLD_REPAIR_USE_ORIGINAL
  rtc_sync_original_reference dut (
`else
  rtc_sync dut (
`endif
    .clk(clk), .rst_sync(rst), .en(en), .hold(hold), .tick_us(tick),
    .rtc_free_us(free_us), .pps_in(pps), .sync_vld(msg),
    .sync_master_ts(master), .path_est_us(16'd0),
    .th_jump_us(8'd100), .log2_avg(4'd2),
    .rtc_time_us(rtc), .pps_out(local_pps), .sync_loss(loss),
    .locked(locked), .last_err_us(last_err), .jump_cnt(jumps),
    .step_cnt(steps), .pps_cnt(ppsc), .sec_phase(phase));

  always @(posedge clk) begin
    if(rst) begin free_us<=0; cyc<=0; end
    else begin
      cyc<=cyc+1;
      // Model the top-level timebase HOLD contract. tick intentionally stays
      // high during some HOLD cases to test rtc_sync's own state gating.
      if(tick && !hold) free_us<=free_us+1;
    end
  end
  always @(negedge clk)
    if(track_loss && loss!==1'b0) false_loss=false_loss+1;

  task automatic ck(input logic ok, input string why);
    begin
      checks=checks+1;
      if(ok!==1'b1) begin
        errors=errors+1;
        $display("RTC_HOLD_UNIT_DIAG case=%0d cycle=%0d %s",cases,cyc,why);
      end
    end
  endtask
  task automatic step(input integer n);
    repeat(n) @(negedge clk);
  endtask
  task automatic until_cycle(input integer n);
    while(cyc<n) @(negedge clk);
  endtask
  task automatic begin_case(input string name);
    begin
      track_loss=0;
      @(negedge clk); rst=1; en=1; hold=0; tick=0; pps=0; msg=0; master=0;
      step(4); rst=0;
      cases=cases+1;
      $display("RTC_HOLD_UNIT_CASE id=%0d name=%s",cases,name);
    end
  endtask
  task automatic pulse;
    begin pps=1; step(8); pps=0; step(8); end
  endtask
  // Read-only unit observations are needed for internal watchdog/pipeline
  // obligations. These are not top-level/public-interface signoff checks.
  function automatic [511:0] stable_state;
    stable_state={rtc,dut.offset,dut.freq_bias,phase,jumps,steps,ppsc,last_err,
                  dut.idle_us,loss,locked,dut.lock_run,dut.err_q,dut.disc_q_pps};
  endfunction
  task automatic same_state(input [511:0] expected, input string why);
    begin
      ck((^stable_state())!==1'bx,"HOLD stable state contains X/Z");
      ck((stable_state()==expected)===1'b1,why);
      ck(dut.disc_pend===1'b0,"HOLD must cancel pending immediately");
      ck(local_pps===1'b0,"HOLD must drain output PPS pulse");
    end
  endtask
  task automatic clean_training;
    ck(({dut.seen_pps,dut.rate_valid,dut.rate_mag,dut.period_us,
         dut.freq_acc,dut.trim_apply,dut.trim_up_q}==0)===1'b1 &&
       dut.period_div_us===32'd1000000,
       "HOLD clears existing training/trim tokens, preserves accumulated bias");
  endtask
  task automatic next_legal_pps;
    begin
      count0=jumps+steps;
      pulse();
      ck((jumps+steps)==count0+1,"next legal PPS must produce exactly one event");
      ck(loss===1'b0,"next legal PPS clears sync loss");
      ck(dut.seen_pps===1'b1,"first legal PPS rearms frequency measurement");
      ck(dut.rate_valid===1'b0,"one post-HOLD PPS cannot reuse old training pair");
    end
  endtask

  initial begin
    // 1: Make real nonzero offset and locked state through legal messages.
    // error=-40, avg shift2 => offset +10. Four exact-zero messages establish
    // the existing LOCK_N=3 comparator behavior, without changing lock policy.
    begin_case("entered HOLD: PPS/message/tick freeze all decision state");
    master=40; msg=1; step(1); msg=0; step(1);
    ck(dut.offset===64'd10 && steps===32'd1 && last_err===32'hFFFFFFD8,
       "message -40us must smooth by +10us");
    master=10;
    repeat(4) begin msg=1; step(1); msg=0; step(1); end
    ck(locked===1'b1 && steps===32'd5,"legal zero-error messages establish lock");
    frozen=stable_state(); hold=1; tick=1; step(8);
    same_state(frozen,"HOLD tick must not advance phase/watchdog/lock");
    pps=1; msg=1; master=64'd1000;
    repeat(8) begin step(1); same_state(frozen,"HOLD PPS/message mutated decision state"); end
    pps=0; msg=0;
    repeat(8) begin step(1); same_state(frozen,"HOLD falling edge mutated state"); end
    ck(dut.pps_q===3'b000,"PPS sampler continues through HOLD high/low");
    clean_training(); tick=0; hold=0; step(8);
    ck((stable_state()==frozen)===1'b1,"HOLD events must not replay after release");
    next_legal_pps();

    // 2: Existing loss=1 must remain 1 under held PPS, unlike original watchdog.
    begin_case("watchdog loss state remains frozen under held PPS");
    tick=1; step(2500001);
    ck(loss===1'b1 && locked===1'b0,"default watchdog expires at timeout+1 ticks");
    frozen=stable_state(); hold=1;
    pulse(); same_state(frozen,"held PPS must not clear watchdog loss");
    clean_training(); tick=0; hold=0; step(8);
    ck(loss===1'b1,"release alone must retain prior loss state");
    next_legal_pps();

    // 3: Assert HOLD precisely between capture and apply of a PPS decision.
    begin_case("cancel captured PPS pending on first HOLD clock");
    tick=1; step(32); tick=0; pps=1;
    guard=0;
    while(dut.disc_pend!==1'b1 && guard<8) begin step(1); guard=guard+1; end
    ck(dut.disc_pend===1'b1 && dut.disc_q_pps===1'b1,"PPS pending setup reached");
    ck(jumps===0 && steps===0,"pending was captured before any application");
    frozen=stable_state(); hold=1; tick=1;
    step(1); same_state(frozen,"HOLD same clock must abort old PPS decision");
    pps=0; step(8); same_state(frozen,"aborted PPS must remain canceled");
    tick=0; hold=0; step(8);
    ck((stable_state()==frozen)===1'b1,"canceled PPS must not apply on release");
    next_legal_pps();

    // 4: The analogous message pipeline abort, including last_err retention.
    begin_case("cancel captured message pending on first HOLD clock");
    master=40; msg=1; step(1); msg=0;
    ck(dut.disc_pend===1'b1 && dut.disc_q_pps===1'b0,"message pending setup reached");
    frozen=stable_state(); hold=1; tick=1;
    step(1); same_state(frozen,"HOLD same clock must abort old message decision");
    step(8); tick=0; hold=0; step(8);
    ck((stable_state()==frozen)===1'b1,"canceled message must not apply on release");
    // New message has independent arithmetic expectation, not canceled value.
    master=40; msg=1; step(1); msg=0; step(1);
    ck(dut.offset===64'd10 && steps===32'd1 && last_err===32'hFFFFFFD8,
       "new post-HOLD message works once, old pending does not replay");

    // 5/6: Raw PPS first sampled on last HOLD clock, pipeline edge after release.
    // Test both high across release and a one-sample pulse ending at release.
    for(i=0;i<2;i=i+1) begin
      begin_case(i==0 ? "late HOLD PPS stays high across release" :
                              "late HOLD PPS falls at release");
      tick=1; step(20); tick=0; frozen=stable_state();
      hold=1; pps=1; step(1);
      same_state(frozen,"last-HOLD raw sample cannot mutate state");
      ck(dut.pps_q===3'b001,"last-HOLD high was sampled before release");
      hold=0; if(i==1) pps=0;
      step(8);
      ck((stable_state()==frozen)===1'b1,
         "HOLD-origin edge reaching synchronizer after release must be rejected");
      ck(dut.seen_pps===1'b0 && dut.rate_valid===1'b0,
         "HOLD-origin edge must not rearm FLL after release");
      pps=0; step(8); next_legal_pps();
    end

    // 7: Natural FLL training produces a queued +1us trim. HOLD must clear
    // its token but retain the already accumulated bias. No force/backdoor.
    begin_case("clear queued trim; no release residual frequency pulse");
    tick=1; until_cycle(40); pulse();
    until_cycle(999940); pulse(); // exactly 999900 ticks between external rises
    ck(dut.rate_valid===1'b1 && dut.rate_mag===13'd100 && dut.rate_up===1'b1,
       "independent 100us short interval trains +100/999900 rate");
    guard=0;
    while(dut.trim_apply!==1'b1 && guard<20000) begin step(1); guard=guard+1; end
    ck(dut.trim_apply===1'b1,"natural pending trim setup reached");
    frozen=stable_state(); old_bias=dut.freq_bias; old_phase=phase;
    old_direction=dut.rate_up; hold=1;
    step(1); same_state(frozen,"HOLD at pending trim must freeze correction state");
    clean_training();
    ck(dut.rate_up===old_direction,"existing inert rate direction is preserved");
    step(8); same_state(frozen,"frequency bias must remain unchanged throughout HOLD");
    hold=0; step(1);
    ck(phase===((old_phase+1)%1000000),"first release tick must advance exactly one us");
    ck(dut.freq_bias===old_bias && dut.trim_apply===1'b0,
       "release must not apply a residual trim or change frequency bias");
    tick=0; next_legal_pps();

    // 8: Default no-HOLD adjacent behavior: exact 1e6 tick PPS intervals,
    // acquisition, lock, no false loss, watchdog expiry and reacquisition.
    begin_case("default 1Hz functional grid remains unchanged without HOLD");
    tick=1; false_loss=0;
    for(i=0;i<8;i=i+1) begin
      target=200+i*1000000; until_cycle(target); pulse();
      ck(jumps+steps===i+1,"one discipline event per default-period PPS");
      ck(loss===1'b0,"default-period PPS must not assert false loss");
      if(i==0) begin ck(jumps===32'd1,"first nonzero-phase PPS acquires by jump"); track_loss=1; end
      if(i>=3) ck($signed(last_err)>=-1 && $signed(last_err)<=1,
                  "settled default-grid phase error stays within 1us");
    end
    track_loss=0;
    ck(false_loss==0 && locked===1'b1,"default grid locks without inter-PPS loss");
    ck(ppsc>=7 && ppsc<=9,"default local PPS output continues at one second scale");
    step(2500001); ck(loss===1'b1 && locked===1'b0,"missing default PPS loses lock");
    count0=jumps+steps; pulse();
    ck(jumps+steps===count0+1 && loss===1'b0,"legal PPS reacquires after loss");

    // 9: Scope characterization only. Existing EN=0 does not abort an already
    // captured decision. Preserve this old behavior; it is not HOLD semantics.
    begin_case("EN=0 pending characterization: separate existing issue");
    master=40; msg=1; step(1); msg=0;
    ck(dut.disc_pend===1'b1,"EN characterization pending setup reached");
    en=0; step(1);
    ck(dut.offset===64'd10 && steps===32'd1,
       "scope lock: existing EN=0 pending application remains unchanged");
    $display("RTC_EN_PENDING_OBSERVATION behavior=existing_pending_applies scope=excluded");

    ck(cases==9,"all nine directed cases completed");
    if(errors==0) $display("T87 RTC HOLD DECISION UNIT PASS cases=%0d checks=%0d",cases,checks);
    else $display("T87 RTC HOLD DECISION UNIT FAIL errors=%0d cases=%0d checks=%0d",errors,cases,checks);
    $finish;
  end
  initial begin
    #200000000;
    $display("T87 RTC HOLD DECISION UNIT FAIL timeout");
    $finish;
  end
endmodule
