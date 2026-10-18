// One store-and-forward switch port: capture a complete MAC frame from TX,
// wait DELAY_US, then play it into RX at the same IF_MODE byte cadence.
// rx_ready stays 1 except a short EOF dip (same envelope as existing TBs),
// so it can share the DUT pin that is also TX link_rdy.
`timescale 1 ns / 1 ps
module afdx_net_port #(
  parameter integer IF_MODE  = 0,
  parameter integer DELAY_US = 10,
  parameter integer MAXB     = 1518,
  parameter integer DEPTH    = 4,
  parameter integer TAIL_CYC = 4,
  parameter integer LOOPBACK = 1
) (
  input  wire        clk,
  input  wire        rst,
  input  wire [7:0]  tx_data,
  input  wire        tx_valid,
  input  wire        tx_ready,
  input  wire        corrupt_next,
  output reg  [7:0]  rx_data,
  output reg         rx_valid,
  output reg         rx_ready,
  output reg  [31:0] frames_fwd,
  output reg  [31:0] frames_corrupt,
  output reg  [10:0] last_len
);
  // TB injects a station-to-ES frame (S7/S8). Held one cycle; accepted when
  // the play queue has room. LOOPBACK=0 still captures TX but does not replay it.
  reg        inj_req;
  reg        inj_seen;
  reg [10:0] inj_len;
  reg [7:0]  inj_mem [0:MAXB-1];
  reg        drop_next;
  reg        dup_next;
  integer    ifg_extra;
  initial begin
    inj_req = 1'b0; inj_len = 11'd0; inj_seen = 1'b0;
    drop_next = 1'b0; dup_next = 1'b0; ifg_extra = 0;
  end
  localparam integer BYTE_SLOT = (IF_MODE != 0) ? 1 : 10;
  localparam integer IDLE_LIM  = BYTE_SLOT * 12;
  localparam integer DELAY_CYC = DELAY_US * 125;

  function integer clog2p;
    input integer v;
    integer n, x;
    begin
      n = 0; x = v - 1;
      while (x > 0) begin n = n + 1; x = x >> 1; end
      clog2p = (n == 0) ? 1 : n;
    end
  endfunction
  localparam integer PW = clog2p(DEPTH);

  reg [7:0]  mem [0:DEPTH-1][0:MAXB-1];
  reg [10:0] flen [0:DEPTH-1];
  reg [31:0] due  [0:DEPTH-1];
  reg [PW-1:0] wptr, rptr;
  integer      qcnt;

  reg        in_frm;
  reg [10:0] cap_len;
  reg [15:0] idle_n;
  reg        cap_corrupt;
  reg [7:0]  cap_mem [0:MAXB-1];

  integer    st, idx, gap, tail;
  integer    i;
  reg [31:0] cyc;

  wire take = tx_valid && ((IF_MODE != 0) || tx_ready);

  integer qi;

  always @(posedge clk) begin
    if (rst) begin
      cyc <= 32'd0;
      in_frm <= 1'b0;
      cap_len <= 11'd0;
      idle_n <= 16'd0;
      cap_corrupt <= 1'b0;
      wptr <= {PW{1'b0}}; rptr <= {PW{1'b0}}; qcnt <= 0;
      rx_data <= 8'd0; rx_valid <= 1'b0; rx_ready <= 1'b1;
      st <= 0; idx <= 0; gap <= 0; tail <= 0;
      frames_fwd <= 32'd0; frames_corrupt <= 32'd0;
      last_len <= 11'd0;
      inj_seen <= 1'b0;
      drop_next <= 1'b0;
      dup_next <= 1'b0;
      ifg_extra = 0;
    end else begin
      cyc <= cyc + 32'd1;

      if (take) begin
        if (!in_frm) begin
          in_frm <= 1'b1;
          cap_mem[0] <= tx_data;
          cap_len <= 11'd1;
          cap_corrupt <= corrupt_next;
        end else if (cap_len < MAXB[10:0]) begin
          cap_mem[cap_len] <= tx_data;
          cap_len <= cap_len + 11'd1;
        end
        idle_n <= 16'd0;
      end else if (in_frm) begin
        if (idle_n + 16'd1 >= IDLE_LIM[15:0]) begin
          in_frm <= 1'b0;
          idle_n <= 16'd0;
          if (LOOPBACK == 0) begin
            last_len <= cap_len;
            drop_next <= 1'b0;
            dup_next <= 1'b0;
          end else if (drop_next) begin
            last_len <= cap_len;
            drop_next <= 1'b0;
            dup_next <= 1'b0;
          end else if (qcnt >= DEPTH) begin
            $display("  [err] net_port queue overflow t=%0t", $time);
          end else begin
            for (qi = 0; qi < MAXB; qi = qi + 1)
              if (qi < cap_len) mem[wptr][qi] <= cap_mem[qi];
            if (cap_corrupt && cap_len != 0)
              mem[wptr][cap_len - 11'd1] <= cap_mem[cap_len - 11'd1] ^ 8'hFF;
            flen[wptr] <= cap_len;
            due[wptr]  <= cyc + DELAY_CYC[31:0];
            last_len   <= cap_len;
            wptr <= wptr + 1'b1;
            qcnt <= qcnt + 1;
            frames_fwd <= frames_fwd + 32'd1;
            if (cap_corrupt) frames_corrupt <= frames_corrupt + 32'd1;
            if (dup_next && (qcnt + 1) < DEPTH) begin
              for (qi = 0; qi < MAXB; qi = qi + 1)
                if (qi < cap_len) mem[wptr + 1'b1][qi] <= cap_mem[qi];
              flen[wptr + 1'b1] <= cap_len;
              due[wptr + 1'b1]  <= cyc + DELAY_CYC[31:0] + 16;
              wptr <= wptr + 2'd2;
              qcnt <= qcnt + 2;
              frames_fwd <= frames_fwd + 32'd2;
            end
            drop_next <= 1'b0;
            dup_next <= 1'b0;
          end
        end else         idle_n <= idle_n + 16'd1;
      end

      if (inj_req && !inj_seen && qcnt < DEPTH) begin
        for (qi = 0; qi < MAXB; qi = qi + 1)
          if (qi < inj_len) mem[wptr][qi] <= inj_mem[qi];
        flen[wptr] <= inj_len;
        due[wptr]  <= cyc + DELAY_CYC[31:0];
        last_len   <= inj_len;
        wptr <= wptr + 1'b1;
        qcnt <= qcnt + 1;
        frames_fwd <= frames_fwd + 32'd1;
        inj_seen <= 1'b1;
      end else if (!inj_req) begin
        inj_seen <= 1'b0;
      end

      case (st)
        0: begin
          rx_valid <= 1'b0;
          rx_ready <= 1'b1;
          if (qcnt != 0 && cyc >= due[rptr] + ifg_extra) begin
            st  <= 1;
            idx <= 0;
            ifg_extra = 0;
          end
        end
        1: begin
          rx_ready <= 1'b1;
          rx_valid <= 1'b1;
          rx_data  <= mem[rptr][idx];
          if (BYTE_SLOT == 1) begin
            if (idx + 1 >= flen[rptr]) begin st <= 3; tail <= 0; end
            else idx <= idx + 1;
          end else begin
            st  <= 2;
            gap <= BYTE_SLOT - 2;
          end
        end
        2: begin
          rx_valid <= 1'b0;
          rx_ready <= 1'b1;
          if (gap == 0) begin
            if (idx + 1 >= flen[rptr]) begin st <= 3; tail <= 0; end
            else begin idx <= idx + 1; st <= 1; end
          end else gap <= gap - 1;
        end
        default: begin
          rx_valid <= 1'b0;
          rx_ready <= 1'b0;
          if (tail + 1 >= TAIL_CYC) begin
            rx_ready <= 1'b1;
            rptr <= rptr + 1'b1;
            qcnt <= qcnt - 1;
            st <= 0;
          end else tail <= tail + 1;
        end
      endcase
    end
  end

  task swap_head;
    integer qi, a, b;
    reg [7:0] tmp;
    reg [10:0] tl;
    reg [31:0] td;
    begin
      if (qcnt >= 2) begin
        a = rptr;
        b = rptr + 1'b1;
        for (qi = 0; qi < MAXB; qi = qi + 1) begin
          tmp = mem[a][qi];
          mem[a][qi] = mem[b][qi];
          mem[b][qi] = tmp;
        end
        tl = flen[a]; flen[a] = flen[b]; flen[b] = tl;
        td = due[a]; due[a] = due[b]; due[b] = td;
      end
    end
  endtask
endmodule
