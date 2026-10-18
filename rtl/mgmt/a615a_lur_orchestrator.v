// =====================================================================
// a615a_lur_orchestrator —— 615A LUR 请求编排（P05）
//
// 输入：a615a_lur_rx 已整文件校验通过的 LUR 清单。
// 输出：逐个文件向装载端发起 TFTP 单作业取件；成功落盘后 file_ack 交付。
//
// 语义：
//   * 单一在飞作业（与单会话 SAP 路由一致）。
//   * filename_len 不含 NUL：lur_name_len 含 NUL，搬运时减一。
//   * 失败即停（host_skip 脉冲可跳过该文件继续），绝不产出部分成功的 done。
//   * host_up_mode is the top-level LUR request mode (the current top-level
//     flow sets it after the manifest upload). Per-file jobs emitted here are
//     RRQ downloads; this status/mode bit must not turn them into WRQ uploads.
//   * 不做 UDP/IP/路由：顶层负责把 job_* 接到 client 与 fe_* 通道。
//
// 名字搬运实现：S_MOVE 期间每两拍取一字节，从 name_shift 的**最高字节端**写入
// 并整体右移 8 位，最终 name_shift[2047:0] 的高 name_len_eff 字节为名字
// （字节 0 在 [2047:2040]，与 client/tx_pack 的 MSB 优先位序一致）。
// =====================================================================
`timescale 1 ns / 1 ps
module a615a_lur_orchestrator #(
  parameter integer MAX_FILES = 8,
  parameter integer DEF_TICKS = 50
) (
  input  wire        clk,
  input  wire        rst_sync,

  input  wire        host_start,
  input  wire        host_abort,
  input  wire        host_skip,
  input  wire [31:0] host_server_ip,
  input  wire [15:0] host_local_tid,
  input  wire [15:0] host_timeout_ticks,
  input  wire        host_up_mode,
  input  wire        host_hold_files, // latched at start; retain each published file until host acknowledgement
  input  wire        host_file_ack,   // accepted only in the published-file wait state

  input  wire        lur_ok,
  input  wire [15:0] lur_file_count,
  input  wire [7:0]  lur_name_len,      // 含 NUL
  input  wire [7:0]  lur_name_byte,
  output wire        lur_name_read,
  output wire [7:0]  lur_name_index,
  // 清单条目选择：搬运名字前必须先把 lur_rx 的 file_select 切到本轮文件，
  // 否则读回的永远是第 0 个条目的名字（顶层原仅由宿主 0xAC88 驱动）。
  output wire [2:0]  lur_file_select,

  output reg         job_start,
  input  wire        job_start_ready,
  output reg  [31:0] job_server_ip,
  output reg  [15:0] job_local_tid,
  output reg  [2047:0] job_filename,
  output reg  [7:0]  job_filename_len,
  output reg  [15:0] job_timeout_ticks,
  output reg         job_abort,
  output reg         job_up_mode,
  input  wire        job_done,
  input  wire        job_failed,
  input  wire [3:0]  job_failure_code,

  output reg         file_ack,
  input  wire        file_valid,
  input  wire [13:0] file_length,
  output wire        waiting_file_ack,

  output reg         busy,
  output reg         done,
  output reg         failed,
  output reg  [3:0]  failure_code,
  output reg  [2:0]  cur_file,
  output reg  [15:0] ok_files,
  output reg  [15:0] fail_files,
  output reg  [31:0] total_bytes
);
  localparam [2:0] S_IDLE=3'd0, S_LOAD=3'd1, S_MOVE=3'd2, S_FIRE=3'd3,
                   S_WAIT=3'd4, S_SETTLE=3'd5, S_DONE=3'd6, S_FAILED=3'd7;
  localparam [3:0] F_LUR=4'd1, F_JOB=4'd2, F_ABORT=4'd3, F_EMPTY=4'd4;

  reg  [2:0]   state;
  reg  [2:0]   nxt_file;
  reg  [7:0]   name_len_eff;
  reg  [7:0]   mv_idx;
  reg          start_d;
  reg  [2047:0] name_acc;

  wire start_p = host_start & ~start_d;
  wire [15:0] eff_ticks = (host_timeout_ticks == 16'd0) ? DEF_TICKS[15:0] : host_timeout_ticks;
  wire [2:0]  last_file = (lur_file_count > MAX_FILES[15:0]) ? (MAX_FILES[2:0] - 3'd1)
                                                             : (lur_file_count[2:0] - 3'd1);

  // 名字读口时序适配：mv_wait=1 表示已发请求、本轮等待寄存输出对齐。
  reg mv_wait;
  // S_WAIT 首拍屏蔽位：屏蔽上一作业 done/failed 的残余锁存（见 S_WAIT 注释）。
  reg wait_arm;
  reg hold_files;
  assign waiting_file_ack = state==S_SETTLE && hold_files && file_valid;

  // 名字读口（去顶层路由到 lur_rx 的 name_read/name_byte_index）
  // 注意：a615a_lur_rx 的 name_byte 为寄存输出（name_byte_valid <= query_valid，
  // 见 a615a_lur_rx.v:88-91），即相对 name_byte_index 有 1 拍延迟。
  // 因此 S_MOVE 发起读请求后必须再等 1 拍，才轮到本轮索引对应的字节对齐。
  assign lur_name_read  = (state == S_MOVE) && !mv_wait && (mv_idx < name_len_eff);
  assign lur_name_index = mv_idx;

  // 本条清单条目号：搬运/取件期间恒为 nxt_file。S_LOAD 起即生效（比 S_MOVE 早一拍），
  // 保证 lur_rx 的 file_select 在首个 name_read 前已切好。
  assign lur_file_select = ((state == S_LOAD) || (state == S_MOVE) ||
                            (state == S_FIRE) || (state == S_WAIT) ||
                            (state == S_SETTLE)) ? nxt_file : 3'd0;

  integer i;
  integer name_byte_i;
  always @(posedge clk) begin
    if (rst_sync) begin
      state <= S_IDLE; job_start <= 1'b0; job_abort <= 1'b0;
      job_server_ip <= 32'd0; job_local_tid <= 16'h3001; job_filename <= 2048'd0;
      job_filename_len <= 8'd0; job_timeout_ticks <= DEF_TICKS[15:0]; job_up_mode <= 1'b0;
      file_ack <= 1'b0; busy <= 1'b0; done <= 1'b0; failed <= 1'b0; failure_code <= 4'd0;
      cur_file <= 3'd0; ok_files <= 16'd0; fail_files <= 16'd0; total_bytes <= 32'd0;
      nxt_file <= 3'd0; name_len_eff <= 8'd0; mv_idx <= 8'd0;
      start_d <= 1'b0; name_acc <= 2048'd0; job_filename <= 2048'd0; mv_wait <= 1'b0;
      wait_arm <= 1'b0;
      hold_files <= 1'b0;
    end else begin
      start_d <= host_start;
      file_ack <= 1'b0;

      if (host_abort && (state != S_IDLE) && (state != S_DONE) && (state != S_FAILED)) begin
        job_abort <= 1'b1;
        // A finished download is no longer an active client job, so aborting
        // the transport alone cannot return its published file buffer.
        file_ack <= file_valid;
        state <= S_FAILED; failed <= 1'b1; busy <= 1'b0; failure_code <= F_ABORT;
      end else begin
        case (state)
          S_IDLE, S_DONE, S_FAILED: begin
            job_abort <= 1'b0;
            job_start <= 1'b0;
            busy <= 1'b0;
            if(state==S_DONE) done<=1'b1;
            if(state==S_FAILED) failed<=1'b1;
            if (start_p) begin
              hold_files<=host_hold_files;
              done<=1'b0;failed<=1'b0;
              ok_files<=0;fail_files<=0;total_bytes<=0;nxt_file<=0;cur_file<=0;
              if (!lur_ok) begin
                state <= S_FAILED; failed <= 1'b1; failure_code <= F_LUR;
              end else if (lur_file_count == 16'd0) begin
                state <= S_FAILED; failed <= 1'b1; failure_code <= F_EMPTY;
              end else if (lur_file_count > MAX_FILES[15:0]) begin
                state <= S_FAILED; failed <= 1'b1; failure_code <= F_LUR;
              end else begin
                state <= S_LOAD; busy <= 1'b1; done <= 1'b0; failed <= 1'b0;
                failure_code <= 4'd0; ok_files <= 16'd0; fail_files <= 16'd0;
                total_bytes <= 32'd0; nxt_file <= 3'd0;
              end
            end
          end

          // 选定第 nxt_file 个条目
          S_LOAD: begin
            cur_file <= nxt_file;
            name_len_eff <= (lur_name_len == 8'd0) ? 8'd0 : (lur_name_len - 8'd1);
            mv_idx <= 8'd0;
            mv_wait <= 1'b0;
            name_acc <= 2048'd0;
            state <= S_MOVE;
          end

          // 逐字节搬运：文件名按「字节 0 = 最高字节」装配。
          // tx_pack 以 MSB 优先取字节（fnb: d[2047-8k-:8]，见 a615a_tftp_tx_pack.v），
          // 且 client 对 filename 原样直通（tx_filename = filename_reg），
          // 故此处必须写 [2047 - 8n -: 8]，与 T49/T56 的位序约定一致。
          // 两拍一轮：第 1 拍发读请求（name_read=1, index=mv_idx）；
          //           第 2 拍寄存输出已对齐（name_byte 即 mv_idx 字节）。
          S_MOVE: begin
            if (mv_idx < name_len_eff) begin
              if (!mv_wait) begin
                mv_wait <= 1'b1;
              end else begin
                // 单次整字节赋值（避免 for 循环位选在部分综合/仿真器上的位序歧义）：
                // 字节 n 落在 [2047-8n : 2040-8n]。
                for (name_byte_i = 0; name_byte_i < 256; name_byte_i = name_byte_i + 1) begin
                  if (mv_idx == name_byte_i)
                    name_acc[2047 - 8*name_byte_i -: 8] <= lur_name_byte;
                end
                mv_idx  <= mv_idx + 8'd1;
                mv_wait <= 1'b0;
              end
            end else begin
              job_filename     <= name_acc;
              job_filename_len <= name_len_eff;
              job_server_ip    <= host_server_ip;
              job_local_tid    <= host_local_tid;
              job_timeout_ticks<= eff_ticks;
              job_up_mode      <= 1'b0; // each LUR file entry is fetched with RRQ
              state <= S_FIRE;
            end
          end

          // 发起点：直接脉冲。取件引擎在 jstate=done/failed 锁存时接受 start，
          // 并在同一拍清 done/failed；因此不能在此等待 !job_done（会死锁）。
          S_FIRE: begin
            if (job_start_ready) begin
              job_start <= 1'b1;
              // 仅当发起点仍有上一作业的 done/failed 残余时，才屏蔽 S_WAIT 首拍。
              wait_arm <= (job_done || job_failed);
              state <= S_WAIT;
            end
          end

          S_WAIT: begin
            job_start <= 1'b0;
            // 首拍屏蔽：取件引擎在 start 被接受后一拍才清上一作业的 done/failed
            // 锁存；若在进入 S_WAIT 的首拍直接采样，会把上一作业结果误判为本作业
            // 结果（→ F_EMPTY）。仅在「进入时 done/failed 已为高」的瞬态屏蔽一次，
            // 不影响随后到达的真实完成/失败脉冲。
            if (wait_arm) begin
              wait_arm <= 1'b0;
            end else if (job_done && file_valid) begin
              state <= S_SETTLE;
            end else if (job_failed || (job_done && !file_valid)) begin
              if (job_failed) fail_files <= fail_files + 16'd1;
              if (host_skip) begin
                if (nxt_file < last_file) begin
                  nxt_file <= nxt_file + 3'd1; state <= S_LOAD;
                end else state <= S_DONE;
              end else begin
                state <= S_FAILED; failed <= 1'b1; busy <= 1'b0;
                failure_code <= job_failed ? F_JOB : F_EMPTY;
              end
            end
          end

          S_SETTLE: begin
            if(!file_valid) begin
              state<=S_FAILED;failed<=1'b1;busy<=1'b0;failure_code<=F_EMPTY;
            end else if(!hold_files || host_file_ack) begin
              file_ack <= 1'b1;
              ok_files <= ok_files + 16'd1;
              total_bytes <= total_bytes + {{18{1'b0}}, file_length};
              if (nxt_file < last_file) begin
                nxt_file <= nxt_file + 3'd1; state <= S_LOAD;
              end else state <= S_DONE;
            end
          end

          default: state <= S_IDLE;
        endcase
      end
    end
  end

endmodule
