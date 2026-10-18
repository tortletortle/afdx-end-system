// Scatter-copy endpoint for the opt-in five-block RX reassembly mode.
// PMEM addresses are 13-bit word addresses: {physical 2KiB block, word index}.
module rx_pmem_scatter_copy (
    input  wire        clk,
    input  wire        reset,
    input  wire        cancel,

    input  wire        job_valid,
    output wire        job_ready,
    input  wire [3:0]  src_blk,
    input  wire [10:0] src_byte,
    input  wire [19:0] dst_blocks,
    input  wire [2:0]  dst_count,
    input  wire [13:0] dst_byte,
    input  wire [13:0] len,

    output reg         done,
    output reg         error,
    output reg         cancelled,

    output wire        rd_req,
    input  wire        rd_grant,
    input  wire        rd_valid,
    input  wire [31:0] rd_data,
    output wire [12:0] rd_addr,

    output wire        wr_valid,
    input  wire        wr_grant,
    output wire [12:0] wr_addr,
    output wire [31:0] wr_data,
    output wire [3:0]  wr_be
);

    localparam [2:0] ST_IDLE  = 3'd0;
    localparam [2:0] ST_READ  = 3'd1;
    localparam [2:0] ST_WAIT  = 3'd2;
    localparam [2:0] ST_WRITE = 3'd3;
    localparam [2:0] ST_DRAIN = 3'd4;

    reg [2:0] state;
    reg [3:0] src_blk_reg;
    reg [10:0] src_cur;
    reg [19:0] dst_blocks_reg;
    reg [13:0] dst_cur;
    reg [13:0] remaining;
    reg [31:0] read_word;

    reg [16:0] src_end_ext;
    reg [16:0] dst_end_ext;
    reg [16:0] dst_capacity_ext;
    reg job_ok;
    reg duplicate_dst;
    reg src_dst_alias;
    integer i;
    integer j;

    always @* begin
        src_end_ext = {6'd0, src_byte} + {3'd0, len};
        dst_end_ext = {3'd0, dst_byte} + {3'd0, len};
        dst_capacity_ext = {3'd0, dst_count, 11'd0};
        duplicate_dst = 1'b0;
        src_dst_alias = 1'b0;
        for (i = 0; i < 5; i = i + 1) begin
            if (i < dst_count) begin
                if (((dst_blocks >> (i * 4)) & 20'h0000f) == src_blk)
                    src_dst_alias = 1'b1;
                for (j = i + 1; j < 5; j = j + 1) begin
                    if ((j < dst_count) &&
                        (((dst_blocks >> (i * 4)) & 20'h0000f) ==
                         ((dst_blocks >> (j * 4)) & 20'h0000f)))
                        duplicate_dst = 1'b1;
                end
            end
        end
        job_ok = (dst_count >= 3'd1) && (dst_count <= 3'd5) &&
                 (src_end_ext <= 17'd2048) &&
                 (dst_byte <= dst_capacity_ext[13:0]) &&
                 (dst_end_ext <= dst_capacity_ext) &&
                 !duplicate_dst && !src_dst_alias;
    end

    assign job_ready = (state == ST_IDLE) && !reset && !cancel;
    assign rd_req = (state == ST_READ) && !cancel && !reset;
    assign rd_addr = {src_blk_reg, src_cur[10:2]};

    reg [13:0] chunk_calc;
    reg [13:0] src_room;
    reg [13:0] dst_room;
    reg [13:0] block_room;
    reg [3:0] dst_physical_block;
    reg [31:0] wr_data_calc;
    reg [3:0] wr_be_calc;
    reg [7:0] byte_calc;
    integer lane;

    always @* begin
        src_room = 14'd4 - {12'd0, src_cur[1:0]};
        dst_room = 14'd4 - {12'd0, dst_cur[1:0]};
        block_room = 14'd2048 - {3'd0, dst_cur[10:0]};
        chunk_calc = remaining;
        if (chunk_calc > src_room) chunk_calc = src_room;
        if (chunk_calc > dst_room) chunk_calc = dst_room;
        if (chunk_calc > block_room) chunk_calc = block_room;

        dst_physical_block = (dst_blocks_reg >> (dst_cur[13:11] * 4)) & 4'hf;
        wr_data_calc = 32'd0;
        wr_be_calc = 4'b0000;
        byte_calc = 8'd0;
        for (lane = 0; lane < 4; lane = lane + 1) begin
            if (lane < chunk_calc) begin
                byte_calc = (read_word >> (24 - 8 * (src_cur[1:0] + lane))) & 8'hff;
                wr_data_calc = wr_data_calc |
                    ({24'd0, byte_calc} << (24 - 8 * (dst_cur[1:0] + lane)));
                wr_be_calc[3 - (dst_cur[1:0] + lane)] = 1'b1;
            end
        end
    end

    assign wr_valid = (state == ST_WRITE) && !cancel && !reset;
    assign wr_addr = {dst_physical_block, dst_cur[10:2]};
    assign wr_data = wr_data_calc;
    assign wr_be = wr_be_calc;

    always @(posedge clk) begin
        if (reset) begin
            state <= ST_IDLE;
            src_blk_reg <= 4'd0;
            src_cur <= 11'd0;
            dst_blocks_reg <= 20'd0;
            dst_cur <= 14'd0;
            remaining <= 14'd0;
            read_word <= 32'd0;
            done <= 1'b0;
            error <= 1'b0;
            cancelled <= 1'b0;
        end else begin
            done <= 1'b0;
            error <= 1'b0;
            cancelled <= 1'b0;
            case (state)
                ST_IDLE: begin
                    if (job_valid && job_ready) begin
                        if (!job_ok) begin
                            done <= 1'b1;
                            error <= 1'b1;
                        end else if (len == 14'd0) begin
                            done <= 1'b1;
                        end else begin
                            src_blk_reg <= src_blk;
                            src_cur <= src_byte;
                            dst_blocks_reg <= dst_blocks;
                            dst_cur <= dst_byte;
                            remaining <= len;
                            state <= ST_READ;
                        end
                    end
                end
                ST_READ: begin
                    if (cancel) begin
                        cancelled <= 1'b1;
                        done <= 1'b1;
                        state <= ST_IDLE;
                    end else if (rd_req && rd_grant) begin
                        if (rd_valid) begin
                            read_word <= rd_data;
                            state <= ST_WRITE;
                        end else begin
                            state <= ST_WAIT;
                        end
                    end
                end
                ST_WAIT: begin
                    if (rd_valid) begin
                        if (cancel) begin
                            cancelled <= 1'b1;
                            done <= 1'b1;
                            state <= ST_IDLE;
                        end else begin
                            read_word <= rd_data;
                            state <= ST_WRITE;
                        end
                    end else if (cancel) begin
                        state <= ST_DRAIN;
                    end
                end
                ST_DRAIN: begin
                    if (rd_valid) begin
                        cancelled <= 1'b1;
                        done <= 1'b1;
                        state <= ST_IDLE;
                    end
                end
                ST_WRITE: begin
                    if (cancel) begin
                        cancelled <= 1'b1;
                        done <= 1'b1;
                        state <= ST_IDLE;
                    end else if (wr_valid && wr_grant) begin
                        if (remaining == chunk_calc) begin
                            done <= 1'b1;
                            state <= ST_IDLE;
                        end else begin
                            src_cur <= src_cur + chunk_calc;
                            dst_cur <= dst_cur + chunk_calc;
                            remaining <= remaining - chunk_calc;
                            state <= ST_READ;
                        end
                    end
                end
                default: begin
                    state <= ST_IDLE;
                end
            endcase
        end
    end
endmodule
