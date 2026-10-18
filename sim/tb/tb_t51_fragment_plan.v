// =====================================================================
// T51 — ipv4_fragment_plan 分片边界规划（P03，2026-10-10）
//
// 覆盖：单帧、精确边界、max+1、raw=17 → 单个 17 字节末片（不是 16+1）、
// 非末片 8 字节对齐、末片允许不对齐、offset 递进与 has_udp_header 仅首片、
// done 脉冲、参数越界（<8 / >8200 / max 对齐后不足 8）报 error。
// 期望分片表由 TB 按文档规则独立计算。
// =====================================================================
`timescale 1 ns / 1 ps
module tb_t51_fragment_plan;
  reg clk = 0;
  always #4 clk = ~clk;
  reg rst = 1, start = 0;
  reg [13:0] total = 0, max_payload = 0;
  wire start_ready, frag_valid, done, error_w;
  reg frag_ready = 0;
  wire [12:0] off_units;
  wire [13:0] len;
  wire mf, has_udp;

  ipv4_fragment_plan dut (
    .clk(clk), .rst_sync(rst), .start(start), .start_ready(start_ready),
    .total_ip_payload_len(total), .max_ip_payload(max_payload),
    .frag_valid(frag_valid), .frag_ready(frag_ready),
    .frag_offset_units(off_units), .frag_payload_len(len), .frag_mf(mf),
    .frag_has_udp_header(has_udp), .done(done), .error(error_w)
  );

  integer errors = 0, checks = 0;
  task bad;
    input [8*96-1:0] reason;
    begin if (errors < 15) $display("  [err] T51 %0s", reason); errors = errors + 1; end
  endtask
  task chk;
    input cond; input [8*96-1:0] reason;
    begin checks = checks + 1; if (!cond) bad(reason); end
  endtask

  // Independent expected plan (document rules):
  //   non-final pieces = floor(raw_max/8)*8; a piece is non-final while
  //   remaining > raw_max; final piece = remaining (may be up to raw_max).
  integer exp_n, exp_off [0:63], exp_len [0:63], exp_mf [0:63];
  task plan_expect;
    input integer tot, mx;
    integer pos, rem, chunk, k;
    begin
      chunk = (mx / 8) * 8;
      pos = 0; k = 0;
      while (pos < tot) begin
        rem = tot - pos;
        if (rem > mx) begin
          exp_off[k] = pos; exp_len[k] = chunk; exp_mf[k] = 1;
        end else begin
          exp_off[k] = pos; exp_len[k] = rem; exp_mf[k] = 0;
        end
        pos = pos + exp_len[k];
        k = k + 1;
      end
      exp_n = k;
    end
  endtask

  integer i, guard, seen;
  task run_plan;
    input integer tot, mx;
    integer k;
    begin
      total = tot[13:0]; max_payload = mx[13:0];
      @(negedge clk); start = 1;
      @(negedge clk); start = 0;
      k = 0; guard = 0; seen = 0;
      while (guard < 20000 && !seen) begin
        if (frag_valid === 1'b1) begin
          // 当前拍的值属于第 k 片；置 ready 后由下一个上升沿消费
          chk(k < exp_n, "more fragments than expected");
          if (k < exp_n) begin
            chk(off_units === exp_off[k][13:3], "fragment offset units");
            chk(len === exp_len[k][13:0], "fragment payload length");
            chk(mf === (exp_mf[k] != 0), "fragment MF flag");
            chk(has_udp === (k == 0), "has_udp_header only on first fragment");
          end
          k = k + 1;
          frag_ready = 1;
        end else begin
          frag_ready = 0;
        end
        @(negedge clk);
        guard = guard + 1;
        if (done === 1'b1) seen = 1;
        if (error_w === 1'b1) begin
          bad("unexpected plan error");
          seen = 1;
        end
      end
      frag_ready = 0;
      chk(seen === 1, "plan did not finish (done/timeout)");
      chk(k === exp_n, "fragment count");
      @(negedge clk); @(negedge clk);
    end
  endtask

  task run_error;
    input integer tot, mx;
    begin
      total = tot[13:0]; max_payload = mx[13:0];
      @(negedge clk); start = 1;
      @(negedge clk); start = 0;
      guard = 0;
      while (error_w !== 1'b1 && guard < 200) begin @(negedge clk); guard = guard + 1; end
      chk(error_w === 1'b1, "expected start error");
      chk(frag_valid === 1'b0, "no fragments on error");
      @(negedge clk); @(negedge clk);
    end
  endtask

  initial begin
    repeat (5) @(negedge clk);
    rst = 0; repeat (2) @(negedge clk);
    chk(start_ready === 1'b1, "start_ready after reset");

    // single frame
    plan_expect(100, 1472); run_plan(100, 1472);
    // exact boundary: total == max -> single frame
    plan_expect(1472, 1472); run_plan(1472, 1472);
    // max + 1
    plan_expect(1473, 1472); run_plan(1473, 1472);
    // raw max 17, total 17 -> one 17-byte final piece (not 16+1)
    plan_expect(17, 17); run_plan(17, 17);
    // raw max 17, total 18 -> chunk=16 (MF=1), final=2
    plan_expect(18, 17); run_plan(18, 17);
    // unaligned non-final limit rounds down: max=19 -> chunk 16
    plan_expect(40, 19); run_plan(40, 19);
    // large datagram split
    plan_expect(8200, 2000); run_plan(8200, 2000);
    // min sizes
    plan_expect(8, 8); run_plan(8, 8);
    // errors
    run_error(7, 100);       // total < 8
    run_error(8201, 2000);   // total > 8200
    run_error(100, 7);       // rounded limit < 8

    if (errors == 0) $display("T51 FRAGMENT_PLAN PASS checks=%0d", checks);
    else $display("T51 FRAGMENT_PLAN FAIL errors=%0d", errors);
    $finish;
  end
  initial begin #2000000; $display("T51 FRAGMENT_PLAN FAIL timeout"); $finish; end
endmodule
