// =====================================================================
// a615a_fetch_engine.v — 615A 主动取件引擎（P05 装配组件，2026-10-10）
// 状态：顶层已有实例；WRQ 方向和上传源由本模块接口提供。
//
// 结构：a615a_tftp_client_1350（协议核）+ a615a_tftp_dgram_rx（响应解析）+
//       a615a_tftp_tx_pack（请求/ACK 报文缓冲）+ a615a_tftp_file_rx_adapter
//       （下载块→完整文件）。
//
// 数据面：
//   * SAP 字节流进入 dgram_rx（引擎对上游的 out_ready 即 sap 背压源）；
//   * client 发射描述符 → tx_pack → 报文缓冲（pkt_*），供管理发送路径读取；
//   * 下载块 → file_rx_adapter → 完整文件（file_* / rd_* 主机读口）。
//
// 作业面：
//   * start 脉冲 + (server_ip, local_tid, filename, fnlen, timeout_ticks) 发起；
//   * busy/done/failed + failure_code 锁存；abort 取消；done 后可直接再 start。
//   * rx_bytes = 已接收文件长度（发布后有效）；file_* 透传适配器。
// =====================================================================
`timescale 1 ns / 1 ps
module a615a_fetch_engine (
  input  wire        clk,
  input  wire        rst_sync,
  input  wire        en,
  // ---- SAP 字节流（引擎为唯一消费者）----
  input  wire        sap_vld,
  input  wire        sap_sop,
  input  wire        sap_eop,
  input  wire [7:0]  sap_data,
  input  wire [15:0] sap_sport,
  input  wire [15:0] sap_dport,
  input  wire [31:0] sap_srcip,
  output wire        sap_ready,
  // ---- 报文缓冲读口（管理发送路径消费）----
  output wire        pkt_vld,
  output wire [10:0] pkt_len,
  output wire [31:0] pkt_dst_ip,
  output wire [15:0] pkt_src_port,
  output wire [15:0] pkt_dst_port,
  input  wire [10:0] pkt_rd_addr,
  output wire [7:0]  pkt_byte,
  input  wire        pkt_ack,
  // ---- 作业配置/控制 ----
  input  wire        start,
  output wire        start_ready,
  input  wire        start_write, // 0=RRQ 下载，1=WRQ 上传
  input  wire [31:0] server_ip,
  input  wire [15:0] local_tid,
  input  wire [2047:0] filename,
  input  wire [7:0]  filename_len,
  input  wire [15:0] timeout_ticks,
  input  wire        timeout_tick,
  input  wire        abort,
  // Host source preload: bytes are written into the same file_mem used by RRQ.
  input  wire        preload_start,
  output wire        preload_start_ready,
  input  wire        preload_data_valid,
  output wire        preload_data_ready,
  input  wire [7:0]  preload_data,
  input  wire        preload_commit,
  input  wire [13:0] preload_length,
  input  wire        preload_abort,
  output wire        preload_error,
  // Client source request observability; actual block data comes from file_mem.
  output wire        upload_block_req,
  output wire [15:0] upload_block_number,
  // ---- 状态/文件 ----
  output reg         busy,
  output reg         done,
  output reg         failed,
  output wire [3:0]  failure_code,
  output wire [31:0] rx_bytes,
  output wire        file_busy,
  output wire        file_valid,
  input  wire        file_ack,
  output wire [13:0] file_length,
  output wire [1:0]  file_error_code,
  input  wire        rd_en,
  input  wire [12:0] rd_addr,
  output wire        rd_valid,
  output wire [7:0]  rd_data,
  // ---- 观测 ----
  output wire [31:0] ok_cnt,
  output wire [31:0] drop_cnt
);
  // ---- client ----
  wire        client_start_w;
  wire        client_busy, client_done, client_failed;
  wire        cl_tx_valid, cl_tx_ready;
  wire [31:0] cl_tx_dst_ip;
  wire [15:0] cl_tx_src_port, cl_tx_dst_port;
  wire [2:0]  cl_tx_opcode;
  wire [15:0] cl_tx_block, cl_tx_error_code;
  wire [9:0]  cl_tx_data_len;
  wire [4095:0] cl_tx_data;
  wire [2047:0] cl_tx_filename;
  wire [7:0]  cl_tx_filename_len;
  wire        cl_tx_mode_octet;
  wire        cl_dl_valid, cl_dl_last, cl_reject;
  wire        cl_dl_ready;
  wire [15:0] cl_dl_number;
  wire [9:0]  cl_dl_len;
  wire [4095:0] cl_dl_data;
  wire [15:0] cl_peer_tid;
  wire        cl_peer_valid;
  wire        cl_rx_valid, cl_rx_ready;
  wire [31:0] cl_rx_src_ip;
  wire [15:0] cl_rx_src_port, cl_rx_dst_port;
  wire [2:0]  cl_rx_opcode;
  wire [15:0] cl_rx_block, cl_rx_error_code;
  wire [9:0]  cl_rx_data_len;
  wire [4095:0] cl_rx_data;
  wire [3:0]  cl_fcode;
  wire        cl_upload_valid, cl_upload_ready, cl_upload_last;
  wire [9:0]  cl_upload_len;
  wire [4095:0] cl_upload_data;
  reg         abort_failed;
  reg         job_write;

  // ---- dgram_rx（响应解析）----
  wire        dr_rx_valid, dr_rx_ready;
  wire [31:0] dr_src_ip;
  wire [15:0] dr_src_port, dr_dst_port;
  wire [2:0]  dr_opcode;
  wire [15:0] dr_block, dr_err;
  wire [9:0]  dr_dlen;
  wire [4095:0] dr_data;

  // ---- tx_pack ----
  wire [2:0]  tp_opcode;

  // ---- file_rx_adapter ----
  wire        fa_start_ready, fa_file_busy, fa_file_valid;
  wire [13:0] fa_file_len;
  wire [1:0]  fa_fec;
  wire [1:0]  fa_aerr;
  wire        fa_upload_source_ready;

  // 作业状态：0 idle / 1 run / 2 done_latched / 3 failed_latched
  reg  [2:0]  jstate;
  reg         abort_l;
  reg         client_failed_l;    // adapter 需要脉冲语义

  wire source_start_ready = start_write ? fa_upload_source_ready : fa_start_ready;
  wire job_can_start = en && !rst_sync &&
                       ((jstate == 3'd0) || (jstate == 3'd2) || (jstate == 3'd3));
  wire start_ok = job_can_start && source_start_ready;
  wire start_fire = start_ok && start;
  assign start_ready = start_ok;
  assign client_start_w = start_fire;
  wire jrunning = (jstate == 3'd1);
  // Reserve upload storage on the accepting WRQ clock, independently of
  // RRQ file readiness. Feeding start_fire into storage availability creates
  // a structural ready/start loop through the unused download-ready branch.
  wire upload_start_fire = job_can_start && start && start_write && fa_upload_source_ready;
  wire upload_job_active = (jrunning && job_write) || upload_start_fire;
  wire client_rst = rst_sync | ((abort || !en) && jrunning);
  wire write_mode_live = start_fire ? start_write : job_write;
  wire download_start = client_start_w && !write_mode_live;

  // dgram_rx 输入接 SAP 字节流
  a615a_tftp_dgram_rx #(.BUF_BYTES(516)) u_dr (
    // ACK/ERROR responses are needed in both directions; direction isolation
    // applies to the download file adapter below, not the shared parser.
    .clk(clk), .rst_sync(rst_sync), .en(jrunning),
    .in_vld(sap_vld), .in_sop(sap_sop), .in_eop(sap_eop), .in_data(sap_data),
    .in_sport(sap_sport), .in_dport(sap_dport), .in_srcip(sap_srcip),
    .out_ready(sap_ready),
    .rx_valid(dr_rx_valid), .rx_ready(dr_rx_ready),
    .rx_src_ip(dr_src_ip), .rx_src_port(dr_src_port), .rx_dst_port(dr_dst_port),
    .rx_opcode(dr_opcode), .rx_block(dr_block), .rx_data_len(dr_dlen),
    .rx_data(dr_data), .rx_error_code(dr_err),
    .ok_cnt(ok_cnt), .drop_cnt(drop_cnt)
  );

  a615a_tftp_client_1350 #(.MAX_RETRIES(5)) u_cl (
    .clk(clk), .rst_sync(client_rst), .start(client_start_w), .start_ready(),
    .start_write(write_mode_live),
    .server_ip(server_ip), .local_tid(local_tid),
    .filename(filename), .filename_len(filename_len),
    .timeout_tick(timeout_tick), .timeout_ticks(timeout_ticks),
    .rx_valid(dr_rx_valid), .rx_ready(dr_rx_ready),
    .rx_src_ip(dr_src_ip), .rx_src_port(dr_src_port), .rx_dst_port(dr_dst_port),
    .rx_opcode(dr_opcode), .rx_block(dr_block), .rx_data_len(dr_dlen),
    .rx_data(dr_data), .rx_error_code(dr_err),
    .tx_valid(cl_tx_valid), .tx_ready(cl_tx_ready), .tx_dst_ip(cl_tx_dst_ip),
    .tx_src_port(cl_tx_src_port), .tx_dst_port(cl_tx_dst_port),
    .tx_opcode(cl_tx_opcode), .tx_block(cl_tx_block),
    .tx_error_code(cl_tx_error_code), .tx_data_len(cl_tx_data_len),
    .tx_data(cl_tx_data), .tx_filename(cl_tx_filename),
    .tx_filename_len(cl_tx_filename_len), .tx_mode_octet(cl_tx_mode_octet),
    .upload_block_req(upload_block_req), .upload_block_number(upload_block_number),
    .upload_block_valid(cl_upload_valid), .upload_block_ready(cl_upload_ready),
    .upload_data_len(cl_upload_len), .upload_data(cl_upload_data),
    .upload_block_last(cl_upload_last),
    .download_block_valid(cl_dl_valid), .download_block_ready(cl_dl_ready),
    .download_block_number(cl_dl_number), .download_data_len(cl_dl_len),
    .download_data(cl_dl_data), .download_block_last(cl_dl_last),
    .peer_tid_valid(cl_peer_valid), .peer_tid(cl_peer_tid),
    .busy(client_busy), .done(client_done), .failed(client_failed),
    .failure_code(cl_fcode), .server_error_code()
  );

  a615a_tftp_tx_pack u_tp (
    .clk(clk), .rst_sync(client_rst), .en(1'b1),
    .tx_valid(cl_tx_valid), .tx_ready(cl_tx_ready),
    .tx_opcode(cl_tx_opcode), .tx_block(cl_tx_block),
    .tx_error_code(cl_tx_error_code), .tx_data_len(cl_tx_data_len),
    .tx_data(cl_tx_data), .tx_filename(cl_tx_filename),
    .tx_filename_len(cl_tx_filename_len), .tx_mode_octet(cl_tx_mode_octet),
    .tx_dst_ip(cl_tx_dst_ip), .tx_src_port(cl_tx_src_port), .tx_dst_port(cl_tx_dst_port),
    .pkt_vld(pkt_vld), .pkt_len(pkt_len), .pkt_dst_ip(pkt_dst_ip),
    .pkt_src_port(pkt_src_port), .pkt_dst_port(pkt_dst_port),
    .pkt_rd_addr(pkt_rd_addr), .pkt_byte(pkt_byte), .pkt_ack(pkt_ack),
    .pkt_cnt(), .err_cnt()
  );

  a615a_tftp_file_rx_adapter #(.MAX_BYTES(8192)) u_fa (
    .clk(clk), .rst_sync(rst_sync), .start(download_start), .start_ready(fa_start_ready),
    .client_done(client_done), .client_failed(client_failed_l),
    .abort_request(abort_l),
    .preload_start(preload_start), .preload_start_ready(preload_start_ready),
    .preload_data_valid(preload_data_valid), .preload_data_ready(preload_data_ready),
    .preload_data(preload_data), .preload_commit(preload_commit),
    .preload_length(preload_length), .preload_abort(preload_abort || !en),
    .preload_error(preload_error), .upload_job_active(upload_job_active),
    .upload_block_req(upload_block_req), .upload_block_number(upload_block_number),
    .upload_block_valid(cl_upload_valid), .upload_block_ready(cl_upload_ready),
    .upload_data_len(cl_upload_len), .upload_data(cl_upload_data),
    .upload_block_last(cl_upload_last), .upload_source_ready(fa_upload_source_ready),
    .download_block_valid(cl_dl_valid), .download_block_ready(cl_dl_ready),
    .download_data_len(cl_dl_len), .download_data(cl_dl_data),
    .download_block_last(cl_dl_last), .block_reject(cl_reject),
    .file_busy(file_busy), .file_valid(file_valid), .file_ack(file_ack),
    .file_length(file_length), .file_error_code(file_error_code),
    .rd_en(rd_en), .rd_addr(rd_addr), .rd_valid(rd_valid), .rd_data(rd_data),
    .adapter_error(fa_aerr)
  );

  assign rx_bytes = {18'd0, file_length};
  assign failure_code = abort_failed ? 4'd5 : cl_fcode;

  always @(posedge clk) begin
    if (rst_sync) begin
      jstate <= 3'd0;
      busy <= 1'b0; done <= 1'b0; failed <= 1'b0;
      abort_l <= 1'b0;
      client_failed_l <= 1'b0;
      abort_failed <= 1'b0;
      job_write <= 1'b0;
    end else begin
      // 运行中 abort/disable：客户端与待发报文立即取消；下载适配器收到取消脉冲
      // Route cancellation to the adapter in both directions: RRQ aborts its
      // partial receiver, while WRQ aborts only its active file reader.
      abort_l <= (abort || !en) && jrunning;
      if (client_failed) client_failed_l <= 1'b1; else client_failed_l <= 1'b0;
      if (start_fire) begin
        abort_failed <= 1'b0;
        job_write <= start_write;
      end
      case (jstate)
        3'd0, 3'd2, 3'd3: begin
          if (start_fire) begin
            jstate <= 3'd1;
            busy <= 1'b1; done <= 1'b0; failed <= 1'b0;
          end
        end
        3'd1: begin
          if (abort || !en) begin
            jstate <= 3'd3; busy <= 1'b0; done <= 1'b0; failed <= 1'b1;
            abort_failed <= 1'b1;
          end else if (client_done) begin
            jstate <= 3'd2; busy <= 1'b0; done <= 1'b1;
          end else if (client_failed) begin
            jstate <= 3'd3; busy <= 1'b0; failed <= 1'b1;
          end
        end
        default: jstate <= 3'd0;
      endcase
    end
  end
endmodule

