// =====================================================================
// T16u -- ARINC 615A data LOAD + UNLOAD at the TFTP layer (RFC 1350)
// (test-set completion 20260928; ACCEPTANCE TEST FOR PLAN STEP 3).
//
// Status when written: the current a615a_tftp.v only serves the fixed
// 32 B "STATUS" file on RRQ, so U2..U6 are EXPECTED TO FAIL until the
// step-3 RTL (read-back of the loaded image) is in.  The test is written
// first on purpose; do not weaken it to match the old RTL.
//
// Minimal unload contract (to be implemented in step 3; scope = TFTP layer
// only, per the competition's 615A boundary -- no Find/Information/upper
// A615A protocol):
//   * RRQ "UPLOAD", mode octet, after a completed load (loaded_ok=1):
//       DATA(1)..DATA(N) carry the loaded image, 512 B per block, from the
//       load area; the last block is < 512 B.  If the image length is an
//       exact multiple of 512 B, a final 0-byte DATA block terminates the
//       transfer (RFC 1350 sec. 6).
//   * DATA(k+1) is sent only after ACK(k) from the requester's TID.
//     ACK(N) closes the read session: no further response.
//   * Duplicate ACK(k-1) while DATA(k) is outstanding: NO retransmission
//     (RFC 1350 "Sorcerer's Apprentice" rule); the timeout path resends.
//   * No response within TIMEOUT_US -> the last DATA is resent unchanged
//     (timeout_cnt increments).
//   * Packet from a foreign TID during the session -> ERROR(5) to it, the
//     session continues (RFC 1350 sec. 4).
//   * RRQ "UPLOAD" with no loaded image -> ERROR(1) file not found.
//   * RRQ "STATUS" keeps working; unloading does not alter the loaded
//     image, loaded_ok or crc32_val.
// Load-side checks included here as well (existing behaviour + gaps):
//   * WRQ/DATA load of 1300 B: ACK(0..3), loaded_ok, bytes, CRC-32.
//   * Load of exactly 1024 B ending in a 0-byte DATA(3): must be ACKed and
//     bytes_rcvd must be 1024.  In the old RTL the block number of a 4-byte
//     packet is judged at EOP before its low byte lands (blk_num stale), so
//     the 0-byte block is rejected, and paylen+1 would count 1025.
//   * Same stale-blk_num defect: ACK(1) of an RRQ is never recognised, the
//     read session lingers and later resends on timeout.  T16 A10 only
//     looks right after the ACK and misses it; here every "session closed"
//     check waits 3 x TIMEOUT_US.
//
// Harness: a615a_tftp instantiated directly (TIMEOUT_US=2000, tick_us every
// clock), requests driven as byte streams on in_*, responses read through
// resp_rd_addr/resp_byte with a 2-cycle settle per byte (tolerates a
// registered load-area read), then released with resp_ack.
// Verdict: "T16u 615A LOAD/UNLOAD PASS (...)" / "... FAIL (...)"
// =====================================================================
`timescale 1ns/1ps
module tb_t16u_tftp_unload;
  localparam integer TO_US = 2000;

  reg clk = 0; always #4 clk = ~clk;
  reg rst = 1;
  reg        in_vld = 0, in_sop = 0, in_eop = 0;
  reg  [7:0] in_data = 0;
  reg [15:0] in_sport = 0;
  wire       in_ready;
  wire       resp_vld;
  wire [10:0] resp_len;
  reg        resp_ack = 0;
  reg [10:0] resp_rd_addr = 0;
  wire [7:0] resp_byte;
  wire [31:0] host_rdata;
  wire loaded_ok;
  wire [15:0] err_code, tid, blk_expect;
  wire [31:0] bytes_rcvd, crc32_val, pkt_cnt, dup_cnt, err_cnt, timeout_cnt, fname_head;
  wire [7:0]  retry_cnt;
  wire [3:0]  state_o;

  a615a_tftp #(.TIMEOUT_US(TO_US)) dut (
    .clk(clk), .rst_sync(rst), .en(1'b1), .tick_us(!rst),
    .in_vld(in_vld), .in_sop(in_sop), .in_eop(in_eop), .in_data(in_data),
    .in_sport(in_sport), .in_ready(in_ready),
    .resp_vld(resp_vld), .resp_len(resp_len), .resp_ack(resp_ack),
    .resp_rd_addr(resp_rd_addr), .resp_byte(resp_byte),
    .host_rd(1'b0), .host_addr(13'd0), .host_rdata(host_rdata),
    .loaded_ok(loaded_ok), .err_code(err_code), .tid(tid), .blk_expect(blk_expect),
    .bytes_rcvd(bytes_rcvd), .crc32_val(crc32_val), .pkt_cnt(pkt_cnt),
    .dup_cnt(dup_cnt), .err_cnt(err_cnt), .timeout_cnt(timeout_cnt),
    .retry_cnt(retry_cnt), .fname_head(fname_head), .state_o(state_o));

  integer errors = 0, checks = 0;
  task bad; input [8*72-1:0] msg; begin errors = errors + 1; if (errors < 40) $display("  [err] T16u t=%0t: %0s", $time, msg); end endtask
  task chk; input c; input [8*72-1:0] msg; begin checks = checks + 1; if (!c) bad(msg); end endtask

  // ---------------- image + CRC ----------------
  function [7:0] img(input integer j); img = ((j * 7 + 3) ^ (j >> 8)) & 255; endfunction
  function [31:0] crc32_byte(input [31:0] c0, input [7:0] d);
    reg [31:0] c; integer k;
    begin
      c = c0 ^ {24'd0, d};
      for (k = 0; k < 8; k = k + 1) c = c[0] ? ((c >> 1) ^ 32'hEDB88320) : (c >> 1);
      crc32_byte = c;
    end
  endfunction
  function [31:0] img_crc(input integer n);
    integer j; reg [31:0] c;
    begin c = 32'hFFFF_FFFF; for (j = 0; j < n; j = j + 1) c = crc32_byte(c, img(j)); img_crc = ~c; end
  endfunction

  // ---------------- request builder ----------------
  reg [7:0] pk [0:1023];
  integer   plen;
  task mk_rq(input [15:0] opc, input [8*6-1:0] name);   // 6-char name
    integer k;
    begin
      pk[0] = opc[15:8]; pk[1] = opc[7:0]; plen = 2;
      for (k = 5; k >= 0; k = k - 1) begin pk[plen] = name[8*k +: 8]; plen = plen + 1; end
      pk[plen] = 8'h00; plen = plen + 1;
      pk[plen] = "o"; pk[plen+1] = "c"; pk[plen+2] = "t"; pk[plen+3] = "e"; pk[plen+4] = "t";
      pk[plen+5] = 8'h00; plen = plen + 6;
    end
  endtask
  task mk_data(input [15:0] blk, input integer off, input integer n);
    integer k;
    begin
      pk[0] = 8'h00; pk[1] = 8'h03; pk[2] = blk[15:8]; pk[3] = blk[7:0];
      for (k = 0; k < n; k = k + 1) pk[4 + k] = img(off + k);
      plen = 4 + n;
    end
  endtask
  task mk_ack(input [15:0] blk);
    begin pk[0] = 8'h00; pk[1] = 8'h04; pk[2] = blk[15:8]; pk[3] = blk[7:0]; plen = 4; end
  endtask
  task send(input [15:0] sport);
    integer k;
    begin
      for (k = 0; k < plen; k = k + 1) begin
        @(negedge clk);
        in_vld = 1; in_sop = (k == 0); in_eop = (k == plen - 1); in_data = pk[k]; in_sport = sport;
      end
      @(negedge clk); in_vld = 0; in_sop = 0; in_eop = 0;
    end
  endtask

  // ---------------- response reader ----------------
  reg [7:0] rb [0:1023];
  integer   rlen;
  reg       got;
  task get_resp(input integer wait_max);
    integer k, w;
    begin
      got = 0; rlen = 0; w = 0;
      while (resp_vld !== 1'b1 && w < wait_max) begin @(negedge clk); w = w + 1; end
      if (resp_vld === 1'b1) begin
        got = 1; rlen = resp_len;
        for (k = 0; k < rlen && k < 1024; k = k + 1) begin
          @(negedge clk); resp_rd_addr = k;
          @(negedge clk); @(negedge clk);
          rb[k] = resp_byte;
        end
        @(negedge clk); resp_ack = 1;
        @(negedge clk); resp_ack = 0;
      end
    end
  endtask
  task expect_none(input integer cycles, input [8*72-1:0] msg);
    integer w;
    begin
      w = 0;
      while (w < cycles) begin @(negedge clk); w = w + 1; if (resp_vld === 1'b1) w = cycles + 1; end
      chk(w == cycles, msg);
      if (resp_vld === 1'b1) get_resp(1);     // consume it so later steps start clean
    end
  endtask
  function [15:0] r16(input integer a); r16 = {rb[a], rb[a+1]}; endfunction

  task expect_ack(input [15:0] blk, input [8*72-1:0] msg);
    begin
      get_resp(20000);
      chk(got && rlen == 4 && r16(0) == 16'd4 && r16(2) == blk, msg);
    end
  endtask
  task expect_err(input [15:0] code, input [8*72-1:0] msg);
    begin
      get_resp(20000);
      chk(got && r16(0) == 16'd5 && r16(2) == code, msg);
    end
  endtask
  // DATA(blk) carrying image[off .. off+n-1]
  task expect_data(input [15:0] blk, input integer off, input integer n, input [8*72-1:0] msg);
    integer k, nbad;
    begin
      get_resp(20000);
      nbad = 0;
      if (got && rlen == 4 + n && r16(0) == 16'd3 && r16(2) == blk) begin
        for (k = 0; k < n; k = k + 1) if (rb[4 + k] !== img(off + k)) nbad = nbad + 1;
      end else nbad = -1;
      chk(nbad == 0, msg);
      if (nbad != 0)
        $display("  [info] T16u got=%0d len=%0d opc=%0d blk=%0d (want DATA blk=%0d len=%0d) bad_bytes=%0d",
                 got, rlen, r16(0), r16(2), blk, 4 + n, nbad);
    end
  endtask

  // load an n-byte image over WRQ "UPLOAD" from tid: blocks of 512 B, the
  // last block short; an exact multiple of 512 ends with a 0-byte block
  task do_load(input integer n, input [15:0] t);
    integer b, nblk, len;
    begin
      mk_rq(16'd2, "UPLOAD"); send(t); expect_ack(16'd0, "WRQ UPLOAD not answered with ACK(0)");
      nblk = n / 512 + 1;
      for (b = 1; b <= nblk; b = b + 1) begin
        len = (b < nblk) ? 512 : (n - (b - 1) * 512);
        mk_data(b, (b - 1) * 512, len); send(t);
        expect_ack(b, "load DATA not ACKed (0-byte last block needs full blk_num at EOP)");
      end
    end
  endtask

  integer to0;
  reg [31:0] crc_after_load;

  initial begin
    repeat (5) @(negedge clk); rst = 0; repeat (5) @(negedge clk);

    // ---- U0: RRQ UPLOAD with nothing loaded -> ERROR(1) ----
    mk_rq(16'd1, "UPLOAD"); send(16'd1070);
    expect_err(16'd1, "U0 RRQ UPLOAD before any load must be ERROR(1)");

    // ---- U1: load 1300 B (512+512+276) ----
    do_load(1300, 16'd1069);
    chk(loaded_ok === 1'b1, "U1 loaded_ok not set");
    chk(bytes_rcvd == 32'd1300, "U1 bytes_rcvd != 1300");
    chk(crc32_val == img_crc(1300), "U1 CRC-32 of loaded image wrong");
    crc_after_load = crc32_val;

    // ---- U2: unload 1300 B from a new TID ----
    mk_rq(16'd1, "UPLOAD"); send(16'd1070);
    expect_data(16'd1, 0, 512, "U2 DATA(1) wrong (RRQ UPLOAD must return image[0:512])");
    mk_ack(16'd1); send(16'd1070);
    expect_data(16'd2, 512, 512, "U2 DATA(2) wrong");
    mk_ack(16'd2); send(16'd1070);
    expect_data(16'd3, 1024, 276, "U2 DATA(3) wrong (final short block)");
    mk_ack(16'd3); send(16'd1070);
    expect_none(3 * TO_US, "U2 response after final ACK (session must close)");
    chk(loaded_ok === 1'b1 && crc32_val == crc_after_load, "U2 unload altered the loaded image state");

    // ---- U3: duplicate ACK is not answered; timeout path resends ----
    mk_rq(16'd1, "UPLOAD"); send(16'd1071);
    expect_data(16'd1, 0, 512, "U3 DATA(1) wrong");
    mk_ack(16'd1); send(16'd1071);
    expect_data(16'd2, 512, 512, "U3 DATA(2) wrong");
    mk_ack(16'd1); send(16'd1071);                               // duplicate
    expect_none(TO_US / 2, "U3 duplicate ACK(1) must not trigger a retransmission");
    to0 = timeout_cnt;
    expect_data(16'd2, 512, 512, "U3 timeout did not resend DATA(2) unchanged");
    chk(timeout_cnt == to0 + 1, "U3 timeout_cnt did not count the resend");
    mk_ack(16'd2); send(16'd1071);
    expect_data(16'd3, 1024, 276, "U3 DATA(3) after resend wrong");
    mk_ack(16'd3); send(16'd1071);
    expect_none(3 * TO_US, "U3 response after final ACK (lingering session resends on timeout)");

    // ---- U4: foreign TID gets ERROR(5), session continues ----
    mk_rq(16'd1, "UPLOAD"); send(16'd1072);
    expect_data(16'd1, 0, 512, "U4 DATA(1) wrong");
    mk_ack(16'd1); send(16'd2000);                               // intruder
    expect_err(16'd5, "U4 foreign TID must get ERROR(5)");
    mk_ack(16'd1); send(16'd1072);                               // real peer
    expect_data(16'd2, 512, 512, "U4 session did not survive the foreign TID");
    mk_ack(16'd2); send(16'd1072);
    expect_data(16'd3, 1024, 276, "U4 DATA(3) wrong");
    mk_ack(16'd3); send(16'd1072);
    expect_none(3 * TO_US, "U4 response after final ACK (lingering session resends on timeout)");

    // ---- U5: STATUS still readable, reflects the load ----
    mk_rq(16'd1, "STATUS"); send(16'd1073);
    get_resp(20000);
    chk(got && rlen == 36 && r16(0) == 16'd3 && r16(2) == 16'd1, "U5 RRQ STATUS must return DATA(1) 32 B");
    chk({rb[4], rb[5], rb[6], rb[7]} == 32'h41363135, "U5 STATUS magic 'A615' missing");
    chk({rb[12], rb[13], rb[14], rb[15]} == 32'd1300, "U5 STATUS bytes field != 1300");
    mk_ack(16'd1); send(16'd1073);
    expect_none(3 * TO_US, "U5 response after STATUS ACK (lingering session resends on timeout)");

    // ---- U6: exact multiple of 512 -> 0-byte terminator on load and unload ----
    do_load(1024, 16'd1080);                   // 512 + 512 + 0
    chk(loaded_ok === 1'b1, "U6 loaded_ok not set after 0-byte final block");
    chk(bytes_rcvd == 32'd1024, "U6 bytes_rcvd must be 1024 (0-byte block counted as 1?)");
    chk(crc32_val == img_crc(1024), "U6 CRC-32 of 1024 B image wrong");
    mk_rq(16'd1, "UPLOAD"); send(16'd1081);
    expect_data(16'd1, 0, 512, "U6 DATA(1) wrong");
    mk_ack(16'd1); send(16'd1081);
    expect_data(16'd2, 512, 512, "U6 DATA(2) wrong");
    mk_ack(16'd2); send(16'd1081);
    expect_data(16'd3, 1024, 0, "U6 missing 0-byte DATA(3) terminator");
    mk_ack(16'd3); send(16'd1081);
    expect_none(3 * TO_US, "U6 response after final ACK (lingering session resends on timeout)");

    if (errors == 0)
      $display("T16u 615A LOAD/UNLOAD PASS (TFTP layer: load 1300 B + 1024 B, unload by RRQ UPLOAD with ACK lockstep, dup-ACK no resend, timeout resend, foreign TID ERROR(5), no-image ERROR(1), 0-byte terminator; %0d checks)", checks);
    else
      $display("T16u 615A LOAD/UNLOAD FAIL (errors=%0d of %0d checks)", errors, checks);
    $finish;
  end

  initial begin
    #20_000_000;
    $display("T16u 615A LOAD/UNLOAD FAIL (watchdog)");
    $finish;
  end
endmodule
