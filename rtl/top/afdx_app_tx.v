// afdx_app_tx.v — 应用字节流(VLID+payload) → 申请块 / 写 PMEM / MSG_WR
// 载荷缓存 pmem：512x32，单写口 + 单同步读口（读数据打一拍），可推断 BRAM。
// 载荷字节 j（原 capt[2+j]）按大端装字：pmem[j>>2][31-8*(j&3) -: 8]。
// VLID 两字节留在寄存器 hb0/hb1，不进 pmem。
`timescale 1 ns / 1 ps
module afdx_app_tx #(
  parameter integer TX_PORT_BASE = 16,
  parameter integer MAX_BYTES    = 2048   // 须 <= 2048（pmem 512 字）
) (
  input  wire        clk,
  input  wire        rst,
  input  wire        cfg_done,
  input  wire [7:0]  tx_data,
  input  wire        tx_valid,
  output wire        tx_ready,
  output reg         req,
  output reg         we,
  output reg  [15:0] addr,
  output reg  [31:0] wdata,
  input  wire        ack,
  input  wire [31:0] rdata,
  output reg  [31:0] drop_cnt,
  output reg  [31:0] submit_cnt,
  output wire [2:0]  dbg_st
);
  localparam [2:0]
    S_IDLE   = 3'd0,
    S_STAT   = 3'd1,
    S_CLRERR = 3'd2,
    S_WR     = 3'd3,
    S_COMMIT = 3'd4,
    S_RDERR  = 3'd5;

  reg [31:0] pmem [0:511];
  reg [11:0] capt_n;
  reg        capturing;
  reg        busy;
  reg [7:0]  hb0, hb1;
  reg [31:0] acc;
  reg [15:0] cur_vlid;
  reg [10:0] cur_plen;
  reg [2:0]  st;
  reg [15:0] base;
  reg [10:0] words, widx;
  reg        issued;
  reg [7:0]  port_tx;
  reg [31:0] err_after_wr;

  assign tx_ready = cfg_done && !busy;
  assign dbg_st = st;

  // -------- ingress 译码（与原 capt[] 写入条件逐条等价）--------
  wire        ing_en  = cfg_done && !rst && !busy;
  wire [11:0] idx     = capturing ? capt_n : 12'd0;
  wire        accept  = ing_en && tx_valid && (!capturing || capt_n < MAX_BYTES[11:0]);
  wire [11:0] jn      = idx - 12'd2;                 // 载荷字节序号（idx>=2 时有效）
  wire        acc_pay = accept && (idx >= 12'd2);
  wire        mw_full = acc_pay && (jn[1:0] == 2'd3);
  wire [11:0] fl_j    = capt_n - 12'd2;              // 结束时已收载荷字节数
  wire        mw_fl   = ing_en && !tx_valid && capturing &&
                        (capt_n >= 12'd2) && (fl_j[1:0] != 2'd0);
  wire        m_we    = mw_full | mw_fl;
  wire [8:0]  m_wa    = mw_full ? jn[10:2] : fl_j[10:2];
  wire [31:0] m_wd    = mw_full ? {acc[31:8], tx_data} : acc;

  // -------- 读口：同步读，地址随总线事务预取下一字 --------
  // S_WR 内已发起请求(issued=1)时预取 widx+1，ack 后下一拍 rd_q 即为新字；
  // 其余时刻取 widx。与原组合读相比发请求的拍数不变。
  wire [8:0]  rd_a    = (st == S_WR && issued) ? (widx[8:0] + 9'd1) : widx[8:0];
  reg  [31:0] rd_q;

  always @(posedge clk) begin
    if (m_we) pmem[m_wa] <= m_wd;
    rd_q <= pmem[rd_a];
  end

  always @(posedge clk) begin
    if (rst) begin
      capturing <= 1'b0;
      capt_n <= 12'd0;
      busy <= 1'b0;
      drop_cnt <= 32'd0;
      submit_cnt <= 32'd0;
      req <= 1'b0; we <= 1'b0; addr <= 16'd0; wdata <= 32'd0;
      st <= S_IDLE;
      issued <= 1'b0;
      widx <= 11'd0; words <= 11'd0;
      cur_vlid <= 16'd0; cur_plen <= 11'd0;
      base <= 16'd0; port_tx <= 8'd0;
      err_after_wr <= 32'd0;
      hb0 <= 8'd0; hb1 <= 8'd0; acc <= 32'd0;
    end else if (!cfg_done) begin
      req <= 1'b0;
      busy <= 1'b0;
      capturing <= 1'b0;
      capt_n <= 12'd0;
      st <= S_IDLE;
      issued <= 1'b0;
    end else begin
      // -------- ingress --------
      if (!busy) begin
        if (tx_valid) begin
          if (!capturing) begin
            capturing <= 1'b1;
            hb0 <= tx_data;
            capt_n <= 12'd1;
          end else if (capt_n < MAX_BYTES[11:0]) begin
            if (capt_n == 12'd1) hb1 <= tx_data;
            capt_n <= capt_n + 12'd1;
          end
          if (acc_pay) begin
            case (jn[1:0])
              2'd0: acc <= {tx_data, 24'd0};
              2'd1: acc[23:16] <= tx_data;
              2'd2: acc[15:8]  <= tx_data;
              default: ;
            endcase
          end
        end else if (capturing) begin
          capturing <= 1'b0;
          if (capt_n >= 12'd2) begin
            busy     <= 1'b1;
            cur_vlid <= {hb0, hb1};
            cur_plen <= capt_n[10:0] - 11'd2;
            port_tx  <= TX_PORT_BASE[7:0] + hb1; // VLID=0x01xx → port=16+xx
            st       <= S_STAT;
            issued   <= 1'b0;
            req      <= 1'b0;
          end else begin
            drop_cnt <= drop_cnt + 32'd1;
          end
          capt_n <= 12'd0;
        end
      end else if (tx_valid) begin
        drop_cnt <= drop_cnt + 32'd1;
      end

      // -------- host submit FSM --------
      if (busy) begin
        case (st)
          S_STAT: begin
            if (!issued) begin
              req <= 1'b1; we <= 1'b0;
              addr <= 16'h0074; wdata <= 32'd0;
              issued <= 1'b1;
            end else if (ack) begin
              req <= 1'b0;
              issued <= 1'b0;
              if (rdata[4]) begin
                base  <= 16'h8800 + (rdata[3:0] << 9);
                words <= (cur_plen + 11'd3) >> 2;
                widx  <= 11'd0;
                st    <= S_CLRERR;
              end
            end
          end
          S_CLRERR: begin
            // W1C ERR.ACC，便于写后检查是否被假 ACK 置位
            if (!issued) begin
              req <= 1'b1; we <= 1'b1;
              addr <= 16'h0010; wdata <= 32'h1;
              issued <= 1'b1;
            end else if (ack) begin
              req <= 1'b0; issued <= 1'b0; st <= S_WR;
            end
          end
          S_WR: begin
            if (widx >= words) begin
              st <= S_RDERR;
              issued <= 1'b0;
              req <= 1'b0;
            end else if (!issued) begin
              req <= 1'b1; we <= 1'b1;
              addr <= base + widx;
              wdata <= rd_q;
              issued <= 1'b1;
            end else if (ack) begin
              req <= 1'b0;
              issued <= 1'b0;
              widx <= widx + 11'd1;
            end
          end
          S_RDERR: begin
            if (!issued) begin
              req <= 1'b1; we <= 1'b0;
              addr <= 16'h0010; wdata <= 32'd0;
              issued <= 1'b1;
            end else if (ack) begin
              req <= 1'b0; issued <= 1'b0;
              err_after_wr <= rdata;
              // synthesis translate_off
              $display("APP_TX_WR_DONE base=%04h words=%0d err_after=%08h expect0=%08h",
                       base, words, rdata, (cur_plen == 11'd0) ? 32'd0 : pmem[0]);
              // synthesis translate_on
              st <= S_COMMIT;
            end
          end
          S_COMMIT: begin
            if (!issued) begin
              req <= 1'b1; we <= 1'b1;
              addr <= 16'h8280 + {8'd0, port_tx};
              wdata <= {21'd0, cur_plen};
              issued <= 1'b1;
            end else if (ack) begin
              req <= 1'b0;
              issued <= 1'b0;
              submit_cnt <= submit_cnt + 32'd1;
              busy <= 1'b0;
              st <= S_IDLE;
              // synthesis translate_off
              $display("APP_TX_SUBMIT vlid=%04h port=%0d plen=%0d submit=%0d err_after=%08h",
                       cur_vlid, port_tx, cur_plen, submit_cnt + 1, err_after_wr);
              // synthesis translate_on
            end
          end
          default: begin
            st <= S_IDLE;
            busy <= 1'b0;
            req <= 1'b0;
            issued <= 1'b0;
          end
        endcase
      end else begin
        req <= 1'b0;
      end
    end
  end
endmodule
