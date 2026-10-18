// =====================================================================
// T52 — ipv4_fragment_header 分片 IP 头（P03，2026-10-10）
//
// 覆盖：20 字节头字段（版本/IHL、DSCP/ECN、total length=20+payload、
// identification、MF/offset、TTL、protocol、源/目的 IP）、头校验和
// （TB 独立按 16 位反码和实现）、片间字段关系、header_last 位置、
// 停顿保持、参数错误（payload=0、TTL=0、MF=1 未对齐、片末超 8200）。
// =====================================================================
`timescale 1 ns / 1 ps
module tb_t52_fragment_header;
  reg clk = 0;
  always #4 clk = ~clk;
  reg rst = 1, start = 0;
  reg [7:0] dscp_ecn = 0;
  reg [13:0] payload = 0;
  reg [15:0] ident = 0;
  reg mf = 0;
  reg [12:0] off_units = 0;
  reg [7:0] ttl = 64, proto = 17;
  reg [31:0] sip = 32'h0A000001, dip = 32'h0A000002;
  wire start_ready, header_valid, header_last, busy, done, err_w;
  reg header_ready = 0;
  wire [7:0] hbyte;

  ipv4_fragment_header dut (
    .clk(clk), .rst_sync(rst), .start(start), .start_ready(start_ready),
    .dscp_ecn(dscp_ecn), .payload_len(payload), .identification(ident),
    .more_fragments(mf), .fragment_offset_units(off_units), .ttl(ttl),
    .protocol(proto), .source_ip(sip), .destination_ip(dip),
    .header_valid(header_valid), .header_ready(header_ready),
    .header_byte(hbyte), .header_last(header_last),
    .busy(busy), .done(done), .error(err_w)
  );

  integer errors = 0, checks = 0;
  task bad;
    input [8*96-1:0] reason;
    begin if (errors < 15) $display("  [err] T52 %0s", reason); errors = errors + 1; end
  endtask
  task chk;
    input cond; input [8*96-1:0] reason;
    begin checks = checks + 1; if (!cond) bad(reason); end
  endtask

  // Independent IPv4 header checksum over the 20 header bytes (fold 16-bit
  // one's complement sum; returned un-complemented so the consumer can add
  // the checksum field and expect 0xFFFF).
  function [15:0] fold20;
    input [7:0] dscp;
    input [15:0] total_len;
    input [15:0] idv;
    input [15:0] flof;
    input [7:0] ttlv;
    input [7:0] protov;
    input [31:0] sv;
    input [31:0] dv;
    reg [31:0] s;
    begin
      s = 32'd0;
      s = s + {8'h00, 8'h45, dscp};
      s = s + {16'h0000, total_len};
      s = s + {16'h0000, idv};
      s = s + {16'h0000, flof};
      s = s + {16'h0000, ttlv, protov};
      s = s + {16'h0000, sv[31:16]} + {16'h0000, sv[15:0]};
      s = s + {16'h0000, dv[31:16]} + {16'h0000, dv[15:0]};
      s = (s & 32'hFFFF) + (s >> 16);
      s = (s & 32'hFFFF) + (s >> 16);
      fold20 = s[15:0];
    end
  endfunction

  function [7:0] exp_byte;
    input integer k;
    input [7:0] dscp; input [13:0] plen; input [15:0] idv;
    input mfv; input [12:0] ofu; input [7:0] ttlv; input [7:0] protov;
    input [31:0] sv; input [31:0] dv;
    reg [15:0] tl, fo, csum;
    begin
      tl = 16'd20 + {2'b0, plen};
      fo = {2'b00, mfv, ofu};
      csum = ~fold20(dscp, tl, idv, fo, ttlv, protov, sv, dv);
      case (k)
        0: exp_byte = 8'h45;
        1: exp_byte = dscp;
        2: exp_byte = tl[15:8];
        3: exp_byte = tl[7:0];
        4: exp_byte = idv[15:8];
        5: exp_byte = idv[7:0];
        6: exp_byte = fo[15:8];
        7: exp_byte = fo[7:0];
        8: exp_byte = ttlv;
        9: exp_byte = protov;
        10: exp_byte = csum[15:8];
        11: exp_byte = csum[7:0];
        12: exp_byte = sv[31:24];
        13: exp_byte = sv[23:16];
        14: exp_byte = sv[15:8];
        15: exp_byte = sv[7:0];
        16: exp_byte = dv[31:24];
        17: exp_byte = dv[23:16];
        18: exp_byte = dv[15:8];
        default: exp_byte = dv[7:0];
      endcase
    end
  endfunction

  integer k, guard, seen, got_bytes;
  task run_header;
    input [7:0] dscp; input integer plen; input integer idv;
    input integer mfv; input integer ofu; input integer ttlv;
    reg [31:0] acc16;
    begin
      dscp_ecn = dscp; payload = plen[13:0]; ident = idv[15:0];
      mf = mfv[0]; off_units = ofu[12:0]; ttl = ttlv[7:0]; proto = 8'd17;
      @(negedge clk); start = 1;
      @(negedge clk); start = 0;
      k = 0; guard = 0; acc16 = 32'd0; seen = 0;
      // 采样在前、握手在后：negedge 时看到的是当前字节（byte_index=k），
      // ready 由下一个上升沿消费；done 与末字节同窗口，在同一 negedge 采样。
      while (!(k == 20 && seen) && guard < 600) begin
        if (header_valid === 1'b1) begin
          chk(hbyte === exp_byte(k, dscp, plen[13:0], idv[15:0], mfv[0],
                                 ofu[12:0], ttlv[7:0], 8'd17, sip, dip),
              "header byte mismatch");
          chk(header_last === (k == 19), "header_last position");
          if (k % 2 == 0) acc16 = acc16 + {hbyte, 8'd0};
          else acc16 = acc16 + {8'd0, hbyte};
          k = k + 1;
          header_ready = 1;
        end else header_ready = 0;
        if (done === 1'b1 && k == 20) seen = 1;
        guard = guard + 1;
        @(negedge clk);
      end
      header_ready = 0;
      chk(k == 20, "header byte count");
      chk(seen === 1, "done pulse after header");
      // folded sum including the emitted checksum must be 0xFFFF
      acc16 = (acc16 & 32'hFFFF) + (acc16 >> 16);
      acc16 = (acc16 & 32'hFFFF) + (acc16 >> 16);
      chk(acc16[15:0] === 16'hFFFF, "header checksum closes to 0xFFFF");
      @(negedge clk);
    end
  endtask

  task run_error;
    input integer plen; input integer ttlv; input integer mfv; input integer ofu;
    begin
      payload = plen[13:0]; ttl = ttlv[7:0]; mf = mfv[0]; off_units = ofu[12:0];
      @(negedge clk); start = 1;
      @(negedge clk); start = 0;
      guard = 0;
      while (err_w !== 1'b1 && guard < 50) begin @(negedge clk); guard = guard + 1; end
      chk(err_w === 1'b1, "expected header error");
      chk(busy === 1'b0, "busy stays low on error");
      @(negedge clk); @(negedge clk);
    end
  endtask

  initial begin
    repeat (5) @(negedge clk);
    rst = 0; repeat (2) @(negedge clk);
    chk(start_ready === 1'b1, "start_ready after reset");

    // first fragment: offset 0, MF=1, aligned
    run_header(8'h00, 2000, 16'h1234, 1, 0, 64);
    // middle fragment: offset 250 units (2000 bytes), MF=1
    run_header(8'h2E, 2000, 16'h1234, 1, 250, 64);
    // final fragment: MF=0, offset 500 units, short unaligned tail
    run_header(8'h00, 200, 16'h1234, 0, 500, 64);
    // single-frame DF=0 un-fragmented
    run_header(8'hB8, 1472, 16'hABCD, 0, 0, 255);

    // errors
    run_error(0, 64, 0, 0);        // payload 0
    run_error(100, 0, 0, 0);       // ttl 0
    run_error(19, 64, 1, 0);       // MF=1 not 8-byte aligned
    run_error(7, 64, 1, 0);        // MF=1 shorter than 8
    run_error(200, 64, 0, 1001);   // offset*8+len > 8200

    if (errors == 0) $display("T52 FRAGMENT_HEADER PASS checks=%0d", checks);
    else $display("T52 FRAGMENT_HEADER FAIL errors=%0d", errors);
    $finish;
  end
  initial begin #2000000; $display("T52 FRAGMENT_HEADER FAIL timeout"); $finish; end
endmodule
