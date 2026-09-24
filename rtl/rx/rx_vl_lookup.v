// Two-table/two-way RX VLID lookup (§7.9, O-13), standalone until RX integration.
// Config image: 4*HASH_BUCKETS words of {3'b0,valid,vlid[15:0],idx[11:0]}.
// Host word offset = table*(2*HASH_BUCKETS)+bucket*2+way.  A CFG_MODE
// transaction is only accepted while idle and INIT_DONE.  A failed offline
// build must NOT be loaded or used to open RX; the enclosing top owns that gate.
// No runtime probe/eviction: parallel synchronous bucket reads, four compares.
`timescale 1 ns / 1 ps
module rx_vl_lookup #(
  parameter integer NUM_RX_VL=4096,
  parameter integer HASH_BUCKETS=2048
) (
  input  wire         clk,
  input  wire         rst_sync,
  input  wire         init_done,
  input  wire         init_we,
  input  wire [12:0]  init_addr,   // 0 .. 4*HASH_BUCKETS-1 (T_HASH sweep)
  input  wire         cfg_mode,    // only load/read while RX is disabled
  input  wire         rx_enable,
  input  wire [15:0]  seed0, seed1, // stable while RX enabled; supplied by host config
  input  wire         cfg_wr,
  input  wire         cfg_rd,
  input  wire [12:0]  cfg_addr,    // LOW half of host RX_HASH window, base 0x3D80
  input  wire [31:0]  cfg_wdata,
  output wire         cfg_ready,
  output reg          cfg_rvalid,
  output wire [31:0]  cfg_rdata,
  input  wire         in_vld,
  output wire         in_ready,
  input  wire [162:0] in_desc,
  output reg          out_vld,
  input  wire         out_ready,
  output reg          out_hit,
  output reg  [11:0]  out_vl,
  output reg  [162:0] out_desc
);
  localparam integer BITS = $clog2(HASH_BUCKETS);
  localparam integer WORDS = 4*HASH_BUCKETS;
  localparam [1:0] IDLE=2'd0, COMPARE=2'd1, OUTPUT=2'd2;
  reg [1:0] state;
  reg [15:0] vlid_q;

  // Each way has one muxed write port (sweep OR frontdoor) and one shared
  // synchronous read address (lookup OR config read OR write). Avoid an array
  // reset, asynchronous read, or multiple procedural writes: eLinx otherwise
  // silently implements the 256 Kbit image as FFs instead of BRAM.
  reg [31:0] table0way0 [0:HASH_BUCKETS-1];
  reg [31:0] table0way1 [0:HASH_BUCKETS-1];
  reg [31:0] table1way0 [0:HASH_BUCKETS-1];
  reg [31:0] table1way1 [0:HASH_BUCKETS-1];
  reg [31:0] q00, q01, q10, q11;
  reg [1:0] cfg_sel_q;

  // Keep the Python hash in sw/golden/hash_seed.py bit-identical. Addition
  // before 16-bit wrap/multiply/xorshift changes WHICH keys collide when seed
  // changes; XORing a final bucket number would only relabel buckets.
  function [10:0] mix_bucket;
    input [15:0] vlid, seed;
    input table_id;
    reg [15:0] x;
    begin
      x = vlid + seed + (table_id ? 16'h1F5B : 16'h9E37);
      x = x ^ (x >> 7);
      x = x * (table_id ? 16'h45D9 : 16'h9E37);
      x = x ^ (x >> 9);
      mix_bucket = x & (HASH_BUCKETS - 1);
    end
  endfunction
  wire [BITS-1:0] h0 = mix_bucket(in_desc[123:108],seed0,1'b0);
  wire [BITS-1:0] h1 = mix_bucket(in_desc[123:108],seed1,1'b1);

  wire cfg_ok_addr = (cfg_addr < WORDS);
  wire sweep = !rst_sync && init_we && (init_addr < WORDS);
  wire config_idle = !rst_sync && init_done && !init_we && cfg_mode &&
                     !rx_enable && (state == IDLE);
  assign cfg_ready = config_idle && cfg_ok_addr && (cfg_wr ^ cfg_rd);
  wire cfg_write = cfg_wr && cfg_ready;
  wire cfg_read = cfg_rd && cfg_ready;
  wire [BITS-1:0] cfg_bucket = cfg_addr[BITS:1];
  wire [BITS-1:0] init_bucket = init_addr[BITS:1];
  wire cfg_table = cfg_addr[BITS+1];
  wire init_table = init_addr[BITS+1];
  wire cfg_way = cfg_addr[0];
  wire init_way = init_addr[0];
  wire sweep00 = sweep && !init_table && !init_way;
  wire sweep01 = sweep && !init_table && init_way;
  wire sweep10 = sweep && init_table && !init_way;
  wire sweep11 = sweep && init_table && init_way;
  wire cfg00 = cfg_write && !cfg_table && !cfg_way;
  wire cfg01 = cfg_write && !cfg_table && cfg_way;
  wire cfg10 = cfg_write && cfg_table && !cfg_way;
  wire cfg11 = cfg_write && cfg_table && cfg_way;
  wire wr00 = sweep00 || cfg00;
  wire wr01 = sweep01 || cfg01;
  wire wr10 = sweep10 || cfg10;
  wire wr11 = sweep11 || cfg11;
  wire [31:0] write_data = sweep ? 32'd0 : cfg_wdata;
  wire [BITS-1:0] a00 = wr00 ? (sweep00 ? init_bucket : cfg_bucket) :
                         (cfg_read && !cfg_table ? cfg_bucket : h0);
  wire [BITS-1:0] a01 = wr01 ? (sweep01 ? init_bucket : cfg_bucket) :
                         (cfg_read && !cfg_table ? cfg_bucket : h0);
  wire [BITS-1:0] a10 = wr10 ? (sweep10 ? init_bucket : cfg_bucket) :
                         (cfg_read && cfg_table ? cfg_bucket : h1);
  wire [BITS-1:0] a11 = wr11 ? (sweep11 ? init_bucket : cfg_bucket) :
                         (cfg_read && cfg_table ? cfg_bucket : h1);

  always @(posedge clk) begin
    if (wr00) table0way0[a00] <= write_data;
    if (wr01) table0way1[a01] <= write_data;
    if (wr10) table1way0[a10] <= write_data;
    if (wr11) table1way1[a11] <= write_data;
    q00 <= table0way0[a00];
    q01 <= table0way1[a01];
    q10 <= table1way0[a10];
    q11 <= table1way1[a11];
  end
  assign cfg_rdata = cfg_sel_q == 2'd0 ? q00 :
                     cfg_sel_q == 2'd1 ? q01 :
                     cfg_sel_q == 2'd2 ? q10 : q11;

  function valid_match;
    input [31:0] word;
    input [15:0] key;
    begin
      valid_match = (word[31:29] == 3'd0) && word[28] &&
                    (word[27:12] == key) && (word[11:0] < NUM_RX_VL);
    end
  endfunction
  wire m00 = valid_match(q00,vlid_q);
  wire m01 = valid_match(q01,vlid_q);
  wire m10 = valid_match(q10,vlid_q);
  wire m11 = valid_match(q11,vlid_q);
  assign in_ready = !rst_sync && init_done && !init_we && rx_enable &&
                    !cfg_mode && (state == IDLE);

  always @(posedge clk) begin
    if (rst_sync || init_we) begin
      state <= IDLE;
      out_vld <= 1'b0;
      out_hit <= 1'b0;
      out_vl <= 12'd0;
      out_desc <= 163'd0;
      vlid_q <= 16'd0;
      cfg_rvalid <= 1'b0;
      cfg_sel_q <= 2'd0;
    end else begin
      cfg_rvalid <= cfg_read;
      if (cfg_read) cfg_sel_q <= {cfg_table,cfg_way};
      case (state)
        IDLE: if (in_vld && in_ready) begin
          vlid_q <= in_desc[123:108];
          out_desc <= in_desc;
          state <= COMPARE;
        end
        COMPARE: begin
          out_hit <= m00 || m01 || m10 || m11;
          out_vl <= m00 ? q00[11:0] : m01 ? q01[11:0] :
                    m10 ? q10[11:0] : m11 ? q11[11:0] : 12'd0;
          out_vld <= 1'b1;
          state <= OUTPUT;
        end
        OUTPUT: if (out_ready) begin
          out_vld <= 1'b0;
          state <= IDLE;
        end
        default: state <= IDLE;
      endcase
    end
  end
endmodule
