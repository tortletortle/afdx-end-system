// RX integrity check (§7.10).  Only already-validated frame descriptors may
// enter this stage.  One synchronous PSN read and one conditional write share
// the same RAM port; a rejected frame never changes PSN.  The 163-bit payload
// is the RX ingress descriptor {blk,len,ts,vlid,sn,net,ifid,src,dst,sport,dport}.
// v0.5.14: wired in AFDX_top after rx_flt; RM/parse/port downstream still TODO.
`timescale 1 ns / 1 ps
module rx_ic #(
  parameter integer DW = 163,     // RX 描述符位宽（v0.5.16 顶层用 174）
  parameter integer NUM_RX_VL = 4096
) (
  input  wire         clk,
  input  wire         rst_sync,
  input  wire         init_done,
  input  wire         init_we,
  input  wire [12:0]  init_addr,       // 0 .. 2*NUM_RX_VL-1, from init_sweep T_PSN
  input  wire         ic_first_any,    // UDP_CFG[0]; snapshot at input handshake
  input  wire         in_vld,
  output wire         in_ready,
  input  wire [DW-1:0] in_desc,
  input  wire [11:0]  in_vl,           // looked-up index, NOT wire VLID
  output reg          out_vld,
  input  wire         out_ready,
  output reg          out_accept,
  output reg  [2:0]   out_reason,
  output reg  [DW-1:0] out_desc,
  output reg  [11:0]  out_vl,
  input  wire         dbg_en,
  input  wire         dbg_wr,
  input  wire [11:0]  dbg_vl,
  input  wire         dbg_net,
  input  wire [7:0]   dbg_psn
);
  localparam [2:0] R_OK=3'd0, R_RESET=3'd1, R_LOST_ONE=3'd2,
                   R_FIRST_ANY=3'd3, R_FIRST_FAIL=3'd4,
                   R_OUT_OF_ORDER=3'd5, R_BAD_VL=3'd6;
  localparam [1:0] ST_IDLE=2'd0, ST_CMP=2'd1, ST_WRITE=2'd2, ST_OUT=2'd3;
  localparam integer PSN_DEPTH = 2*NUM_RX_VL;

  // No array reset: init_sweep writes all entries before INIT_DONE.  eLinx
  // only keeps this as one BRAM when init/debug/commit are muxed into ONE
  // physical write port and the synchronous read shares its address.  Three
  // separate array assignments silently expand the table into FFs instead.
  reg [7:0] psn_mem [0:PSN_DEPTH-1];
  reg [1:0] state;
  reg [12:0] addr_q;
  reg [7:0] psn_q, sn_q;
  reg vl_ok_q, first_any_q, accept_q;
  reg [2:0] reason_q;
  wire vl_ok = (in_vl < NUM_RX_VL);
  wire dbg_vl_ok = (dbg_vl < NUM_RX_VL);
  wire [12:0] rd_addr = (in_desc[99] ? NUM_RX_VL : 0) + in_vl;
  wire [12:0] dbg_addr = (dbg_net ? NUM_RX_VL : 0) + dbg_vl;
  wire sweep_we = !rst_sync && init_we && (init_addr < PSN_DEPTH);
  wire debug_we = !rst_sync && !init_we && init_done &&
                  (state == ST_IDLE) && dbg_en && dbg_wr && dbg_vl_ok;
  wire commit_we = !rst_sync && !init_we && (state == ST_WRITE) && accept_q;
  wire mem_we = sweep_we || debug_we || commit_we;
  wire [12:0] wr_addr = sweep_we ? init_addr : debug_we ? dbg_addr : addr_q;
  wire [7:0] wr_data = sweep_we ? 8'd0 : debug_we ? dbg_psn : sn_q;
  wire [12:0] mem_addr = mem_we ? wr_addr : vl_ok ? rd_addr : 13'd0;
  always @(posedge clk) begin
    if (mem_we) psn_mem[mem_addr] <= wr_data;
    psn_q <= psn_mem[mem_addr];  // single synchronous read; write value unused
  end
  wire [7:0] exp1 = (psn_q == 8'd255) ? 8'd1 : psn_q + 8'd1;
  wire [7:0] exp2 = (psn_q >= 8'd254) ? psn_q - 8'd253 : psn_q + 8'd2;
  reg accept_next;
  reg [2:0] reason_next;

  // No implicit drop under downstream backpressure.  An out_vld descriptor
  // remains stable until out_ready; a one-deep state machine serializes
  // same-VL (including A/B) reads behind the preceding PSN writeback.
  // Mask the handshake during reset even if init_done has not yet cleared.
  assign in_ready = !rst_sync && (state == ST_IDLE) && init_done && !init_we &&
                    !(dbg_en && dbg_wr);
  always @* begin
    accept_next = 1'b0;
    reason_next = R_OUT_OF_ORDER;
    if (!vl_ok_q) reason_next = R_BAD_VL;
    else if (sn_q == 8'd0) begin
      accept_next = 1'b1;
      reason_next = R_RESET;
    end else if (psn_q == 8'd0) begin
      accept_next = (sn_q == 8'd1) || first_any_q;
      if (sn_q == 8'd1) reason_next = R_OK;
      else if (first_any_q) reason_next = R_FIRST_ANY;
      else reason_next = R_FIRST_FAIL;
    end else if (sn_q == exp1) begin
      accept_next = 1'b1;
      reason_next = R_OK;
    end else if (sn_q == exp2) begin
      accept_next = 1'b1;
      reason_next = R_LOST_ONE;
    end
  end

  always @(posedge clk) begin
    if (rst_sync) begin
      state <= ST_IDLE;
      out_vld <= 1'b0;
      out_accept <= 1'b0;
      out_reason <= R_OK;
      out_desc <= {DW{1'b0}};
      out_vl <= 12'd0;
      addr_q <= 13'd0;
      sn_q <= 8'd0;
      vl_ok_q <= 1'b0;
      first_any_q <= 1'b0;
      accept_q <= 1'b0;
      reason_q <= R_OK;
    end else if (init_we) begin
      // A restart sweep aborts any outstanding transaction.  Integration must
      // only start a sweep while RX is disabled; init_done gates new frames.
      state <= ST_IDLE;
      out_vld <= 1'b0;
    end else begin
      case (state)
        ST_IDLE: begin
          if (in_vld && in_ready) begin
            out_desc <= in_desc;
            out_vl <= in_vl;
            sn_q <= in_desc[107:100];
            vl_ok_q <= vl_ok;
            first_any_q <= ic_first_any;
            addr_q <= rd_addr;
            state <= ST_CMP;
          end
        end
        ST_CMP: begin
          accept_q <= accept_next;
          reason_q <= reason_next;
          state <= ST_WRITE;
        end
        ST_WRITE: begin
          out_accept <= accept_q;
          out_reason <= reason_q;
          out_vld <= 1'b1;
          state <= ST_OUT;
        end
        ST_OUT: if (out_ready) begin
          out_vld <= 1'b0;
          state <= ST_IDLE;
        end
        default: state <= ST_IDLE;
      endcase
    end
  end
endmodule
