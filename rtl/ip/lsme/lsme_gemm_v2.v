`timescale 1ns / 1ps

// V2 描述符使用的缓存式 8×8 宏瓦片 GEMM 引擎。
// 每个 batch 先通过短 AXI burst 把 A、B 搬入私有 BRAM，再供全部输出瓦片复用。
// 实际算术原子仍是体系结构 4×4 MOPA；四个 ZA 组成 8×8 输出的四个象限。
module lsme_gemm_v2 (
    input              clk,
    input              reset,
    input              start,
    output reg         busy,
    output reg         done,
    output reg [7:0]   error_code,

    input      [31:0] src0_addr,
    input      [31:0] src1_addr,
    input      [31:0] dst_addr,
    input      [31:0] bias_addr,
    input      [15:0] m_dim,
    input      [15:0] n_dim,
    input      [15:0] k_dim,
    input      [15:0] batch_dim,
    input      [31:0] src0_row_stride,
    input      [31:0] src1_row_stride,
    input      [31:0] dst_row_stride,
    input      [31:0] src0_batch_stride,
    input      [31:0] src1_batch_stride,
    input      [31:0] dst_batch_stride,
    input              flag_trans_b,
    input              flag_output_int8,
    input              flag_bias,
    input              flag_relu,
    input      [4:0]   out_shift,

    output reg         burst_cmd_valid,
    input              burst_cmd_ready,
    output reg         burst_cmd_write,
    output reg [31:0]  burst_cmd_addr,
    output reg [3:0]   burst_cmd_beats,
    output reg         burst_w_valid,
    input              burst_w_ready,
    output reg [31:0]  burst_wdata,
    output reg [3:0]   burst_wstrb,
    input              burst_r_valid,
    output reg         burst_r_ready,
    input      [31:0]  burst_rdata,
    input              burst_rlast,
    input      [1:0]   burst_rresp,
    input              burst_done,
    input              burst_error,

    output reg         macro_start,
    input              macro_ready,
    output reg         macro_first,
    output reg [127:0] macro_a_top,
    output reg [127:0] macro_a_bottom,
    output reg [127:0] macro_b_left,
    output reg [127:0] macro_b_right,
    output reg [15:0]  macro_pred_a_top,
    output reg [15:0]  macro_pred_a_bottom,
    output reg [15:0]  macro_pred_b_left,
    output reg [15:0]  macro_pred_b_right,
    output reg [2047:0] macro_za_init,
    input              macro_busy,
    input              macro_done,
    input      [2047:0] macro_za_out,

    output reg [31:0]  tiles_completed,
    output             compute_active,
    output             memory_stall
);

    localparam [7:0] ERR_NONE     = 8'h00;
    localparam [7:0] ERR_CAPACITY = 8'h17;
    localparam [7:0] ERR_DMA      = 8'h18;

    localparam [1:0] LOAD_A    = 2'd0;
    localparam [1:0] LOAD_B    = 2'd1;
    localparam [1:0] LOAD_BIAS = 2'd2;

    localparam [5:0] ST_IDLE          = 6'd0;
    localparam [5:0] ST_VALIDATE      = 6'd1;
    localparam [5:0] ST_BIAS_SETUP    = 6'd2;
    localparam [5:0] ST_BATCH_SETUP   = 6'd3;
    localparam [5:0] ST_A_SETUP       = 6'd4;
    localparam [5:0] ST_B_SETUP       = 6'd5;
    localparam [5:0] ST_LOAD_CMD      = 6'd6;
    localparam [5:0] ST_LOAD_DATA     = 6'd7;
    localparam [5:0] ST_COMPUTE_SETUP = 6'd8;
    localparam [5:0] ST_READ_ISSUE    = 6'd9;
    localparam [5:0] ST_READ_CAPTURE  = 6'd10;
    localparam [5:0] ST_MACRO_ISSUE   = 6'd11;
    localparam [5:0] ST_MACRO_WAIT    = 6'd12;
    localparam [5:0] ST_STORE_CMD     = 6'd13;
    localparam [5:0] ST_STORE_DATA    = 6'd14;
    localparam [5:0] ST_STORE_WAIT    = 6'd15;
    localparam [5:0] ST_TILE_ADV      = 6'd16;
    localparam [5:0] ST_BATCH_ADV     = 6'd17;
    localparam [5:0] ST_FINISH        = 6'd18;
    localparam [5:0] ST_ERROR         = 6'd19;

    // 阅读状态机时可分为四段：
    // 1. VALIDATE/SETUP：锁存并检查描述符；
    // 2. LOAD：把 bias、A、B 从外部存储器搬入本地缓存；
    // 3. READ/MACRO：每四拍准备一个 8×8×4 操作数块，再调用四次 MOPA；
    // 4. STORE/ADV：按行 burst 写回，并推进 N、M、batch 循环。

    reg [5:0] state;
    reg [5:0] load_return_state;

    reg [31:0] cfg_src0;
    reg [31:0] cfg_src1;
    reg [31:0] cfg_dst;
    reg [31:0] cfg_bias;
    reg [15:0] cfg_m;
    reg [15:0] cfg_n;
    reg [15:0] cfg_k;
    reg [15:0] cfg_batch;
    reg [31:0] cfg_a_row_stride;
    reg [31:0] cfg_b_row_stride;
    reg [31:0] cfg_c_row_stride;
    reg [31:0] cfg_a_batch_stride;
    reg [31:0] cfg_b_batch_stride;
    reg [31:0] cfg_c_batch_stride;
    reg cfg_trans_b;
    reg cfg_output_int8;
    reg cfg_bias_enable;
    reg cfg_relu;
    reg [4:0] cfg_shift;

    reg [15:0] a_stride_words;
    reg [15:0] b_stride_words;
    reg [15:0] b_rows;
    reg [15:0] b_row_bytes;

    reg [15:0] batch_index;
    reg [31:0] batch_src0;
    reg [31:0] batch_src1;
    reg [31:0] batch_dst;

    reg [1:0] load_kind;
    reg [15:0] load_rows;
    reg [15:0] load_row;
    reg [15:0] load_row_bytes;
    reg [15:0] load_byte_offset;
    reg [15:0] load_local_stride;
    reg [15:0] load_local_row_base;
    reg [31:0] load_external_row_addr;
    reg [31:0] load_external_stride;
    reg [3:0] load_beats;
    reg [3:0] load_beat_index;

    reg [15:0] tile_m;
    reg [15:0] tile_n;
    reg [15:0] tile_k;
    reg [15:0] tile_a_base_word;
    reg [15:0] tile_b_n_base_word;
    reg [15:0] tile_b_k_base_word;
    reg [31:0] tile_m_dst_base;
    reg [31:0] tile_dst_base;
    reg [1:0] read_phase;

    reg [3:0] store_row;
    reg [3:0] store_beat;
    reg [3:0] store_beats;

    reg a0_en;
    reg a0_we;
    reg [9:0] a0_addr;
    reg [31:0] a0_wdata;
    wire [31:0] a0_rdata;
    reg a1_en;
    reg a1_we;
    reg [9:0] a1_addr;
    reg [31:0] a1_wdata;
    wire [31:0] a1_rdata;

    reg b0_en;
    reg b0_we;
    reg [10:0] b0_addr;
    reg [31:0] b0_wdata;
    wire [31:0] b0_rdata;
    reg b1_en;
    reg b1_we;
    reg [10:0] b1_addr;
    reg [31:0] b1_wdata;
    wire [31:0] b1_rdata;

    (* ram_style = "block" *) reg [31:0] bias_memory [0:127];

    integer i;
    integer j;
    integer col_offset;
    reg [31:0] packed_word;

    wire [15:0] a_words_rounded = (cfg_k + 16'd3) >> 2;
    wire [15:0] b_words_rounded = cfg_trans_b
                                ? ((cfg_k + 16'd3) >> 2)
                                : ((cfg_n + 16'd3) >> 2);
    wire [15:0] current_valid_m = cfg_m - tile_m >= 8
                                ? 16'd8 : cfg_m - tile_m;
    wire [15:0] current_valid_n = cfg_n - tile_n >= 8
                                ? 16'd8 : cfg_n - tile_n;
    wire [15:0] load_remaining = load_row_bytes - load_byte_offset;
    wire [3:0] calculated_load_beats = load_remaining >= 32
                                     ? 4'd8
                                     : ((load_remaining + 16'd3) >> 2);

    assign compute_active = state == ST_READ_ISSUE ||
                            state == ST_READ_CAPTURE ||
                            state == ST_MACRO_ISSUE ||
                            state == ST_MACRO_WAIT;
    assign memory_stall = state == ST_LOAD_CMD || state == ST_LOAD_DATA ||
                          state == ST_STORE_CMD || state == ST_STORE_DATA ||
                          state == ST_STORE_WAIT;

    lsme_bram_tdp #(.ADDR_WIDTH(10), .DEPTH(1024)) u_a_scratch (
        .clk(clk),
        .a_en(a0_en), .a_we(a0_we), .a_addr(a0_addr),
        .a_wdata(a0_wdata), .a_rdata(a0_rdata),
        .b_en(a1_en), .b_we(a1_we), .b_addr(a1_addr),
        .b_wdata(a1_wdata), .b_rdata(a1_rdata)
    );

    lsme_bram_tdp #(.ADDR_WIDTH(11), .DEPTH(2048)) u_b_scratch (
        .clk(clk),
        .a_en(b0_en), .a_we(b0_we), .a_addr(b0_addr),
        .a_wdata(b0_wdata), .a_rdata(b0_rdata),
        .b_en(b1_en), .b_we(b1_we), .b_addr(b1_addr),
        .b_wdata(b1_wdata), .b_rdata(b1_rdata)
    );

    function automatic [15:0] stride_offset;
        input [15:0] base;
        input [15:0] stride;
        input [2:0] offset;
        begin
            case (offset)
                3'd0: stride_offset = base;
                3'd1: stride_offset = base + stride;
                3'd2: stride_offset = base + (stride << 1);
                3'd3: stride_offset = base + (stride << 1) + stride;
                3'd4: stride_offset = base + (stride << 2);
                3'd5: stride_offset = base + (stride << 2) + stride;
                3'd6: stride_offset = base + (stride << 2) + (stride << 1);
                default: stride_offset = base + (stride << 3) - stride;
            endcase
        end
    endfunction

    function automatic [31:0] stride_offset32;
        input [31:0] base;
        input [31:0] stride;
        input [2:0] offset;
        begin
            case (offset)
                3'd0: stride_offset32 = base;
                3'd1: stride_offset32 = base + stride;
                3'd2: stride_offset32 = base + (stride << 1);
                3'd3: stride_offset32 = base + (stride << 1) + stride;
                3'd4: stride_offset32 = base + (stride << 2);
                3'd5: stride_offset32 = base + (stride << 2) + stride;
                3'd6: stride_offset32 = base + (stride << 2) +
                                              (stride << 1);
                default: stride_offset32 = base + (stride << 3) - stride;
            endcase
        end
    endfunction

    function automatic [15:0] operand_predicate;
        input [15:0] outer_base;
        input [15:0] outer_limit;
        input [15:0] inner_base;
        input [15:0] inner_limit;
        integer outer_lane;
        integer inner_lane;
        begin
            operand_predicate = 16'd0;
            for (outer_lane = 0; outer_lane < 4; outer_lane = outer_lane + 1)
                for (inner_lane = 0; inner_lane < 4; inner_lane = inner_lane + 1)
                    if (outer_base + outer_lane < outer_limit &&
                        inner_base + inner_lane < inner_limit)
                        operand_predicate[outer_lane*4+inner_lane] = 1'b1;
        end
    endfunction

    function automatic signed [7:0] requant_s8;
        input signed [31:0] value;
        input [4:0] shift;
        input relu;
        reg signed [31:0] magnitude;
        reg signed [31:0] shifted;
        reg signed [31:0] rounder;
        begin
            if (shift == 0)
                shifted = value;
            else begin
                rounder = 32'sd1 <<< (shift - 1);
                if (value < 0) begin
                    magnitude = -value;
                    shifted = -((magnitude + rounder) >>> shift);
                end
                else
                    shifted = (value + rounder) >>> shift;
            end
            if (relu && shifted < 0)
                requant_s8 = 8'sd0;
            else if (shifted > 127)
                requant_s8 = 8'sd127;
            else if (shifted < -128)
                requant_s8 = -8'sd128;
            else
                requant_s8 = shifted[7:0];
        end
    endfunction

    function automatic signed [31:0] za_element;
        input [3:0] row_index;
        input [3:0] col_index;
        integer quadrant;
        integer element_index;
        begin
            quadrant = (row_index >= 4 ? 2 : 0) +
                       (col_index >= 4 ? 1 : 0);
            element_index = (row_index & 3)*4 + (col_index & 3);
            za_element = $signed(macro_za_out[
                quadrant*512 + element_index*32 +: 32]);
        end
    endfunction

    always @(*) begin
        burst_cmd_valid = 1'b0;
        burst_cmd_write = 1'b0;
        burst_cmd_addr = 32'd0;
        burst_cmd_beats = 4'd1;
        burst_w_valid = 1'b0;
        burst_wdata = 32'd0;
        burst_wstrb = 4'b1111;
        burst_r_ready = 1'b0;

        macro_start = 1'b0;
        macro_first = tile_k == 0;
        macro_pred_a_top = operand_predicate(tile_m, cfg_m, tile_k, cfg_k);
        macro_pred_a_bottom = operand_predicate(tile_m + 16'd4,
                                                cfg_m, tile_k, cfg_k);
        macro_pred_b_left = operand_predicate(tile_n, cfg_n, tile_k, cfg_k);
        macro_pred_b_right = operand_predicate(tile_n + 16'd4,
                                               cfg_n, tile_k, cfg_k);

        a0_en = 1'b0;
        a0_we = 1'b0;
        a0_addr = 10'd0;
        a0_wdata = burst_rdata;
        a1_en = 1'b0;
        a1_we = 1'b0;
        a1_addr = 10'd0;
        a1_wdata = 32'd0;
        b0_en = 1'b0;
        b0_we = 1'b0;
        b0_addr = 11'd0;
        b0_wdata = burst_rdata;
        b1_en = 1'b0;
        b1_we = 1'b0;
        b1_addr = 11'd0;
        b1_wdata = 32'd0;

        macro_za_init = 2048'd0;
        for (i = 0; i < 4; i = i + 1) begin
            for (j = 0; j < 16; j = j + 1) begin
                col_offset = (i[0] ? 4 : 0) + (j & 3);
                if (cfg_bias_enable && tile_n + col_offset < cfg_n)
                    macro_za_init[i*512 + j*32 +: 32] =
                        bias_memory[tile_n + col_offset];
            end
        end

        if (state == ST_LOAD_CMD) begin
            burst_cmd_valid = 1'b1;
            burst_cmd_write = 1'b0;
            burst_cmd_addr = load_external_row_addr + load_byte_offset;
            burst_cmd_beats = calculated_load_beats;
        end
        else if (state == ST_LOAD_DATA) begin
            burst_r_ready = 1'b1;
            if (burst_r_valid) begin
                if (load_kind == LOAD_A) begin
                    a0_en = 1'b1;
                    a0_we = 1'b1;
                    a0_addr = load_local_row_base +
                              (load_byte_offset >> 2) + load_beat_index;
                end
                else if (load_kind == LOAD_B) begin
                    b0_en = 1'b1;
                    b0_we = 1'b1;
                    b0_addr = load_local_row_base +
                              (load_byte_offset >> 2) + load_beat_index;
                end
            end
        end
        else if (state == ST_READ_ISSUE) begin
            a0_en = 1'b1;
            a1_en = 1'b1;
            a0_addr = stride_offset(tile_a_base_word, a_stride_words,
                                    {read_phase, 1'b0}) + (tile_k >> 2);
            a1_addr = stride_offset(tile_a_base_word, a_stride_words,
                                    {read_phase, 1'b0} + 3'd1) +
                      (tile_k >> 2);

            b0_en = 1'b1;
            b1_en = 1'b1;
            if (!cfg_trans_b) begin
                b0_addr = stride_offset(tile_b_k_base_word, b_stride_words,
                                        {1'b0, read_phase}) + (tile_n >> 2);
                b1_addr = b0_addr + 11'd1;
            end
            else begin
                b0_addr = stride_offset(tile_b_n_base_word, b_stride_words,
                                        {read_phase, 1'b0}) + (tile_k >> 2);
                b1_addr = stride_offset(tile_b_n_base_word, b_stride_words,
                                        {read_phase, 1'b0} + 3'd1) +
                          (tile_k >> 2);
            end
        end
        else if (state == ST_MACRO_ISSUE) begin
            macro_start = 1'b1;
        end
        else if (state == ST_STORE_CMD) begin
            burst_cmd_valid = 1'b1;
            burst_cmd_write = 1'b1;
            burst_cmd_addr = stride_offset32(tile_dst_base,
                                             cfg_c_row_stride,
                                             store_row[2:0]);
            burst_cmd_beats = store_beats;
        end
        else if (state == ST_STORE_DATA) begin
            burst_w_valid = 1'b1;
            packed_word = 32'd0;
            if (cfg_output_int8) begin
                for (j = 0; j < 4; j = j + 1) begin
                    if ({12'd0, store_beat, 2'b00} + j < current_valid_n)
                        packed_word[j*8 +: 8] = requant_s8(
                            za_element(store_row,
                                       {store_beat, 2'b00} + j),
                            cfg_shift, cfg_relu);
                end
                burst_wdata = packed_word;
                case (current_valid_n - {12'd0, store_beat, 2'b00})
                    16'd1: burst_wstrb = 4'b0001;
                    16'd2: burst_wstrb = 4'b0011;
                    16'd3: burst_wstrb = 4'b0111;
                    default: burst_wstrb = 4'b1111;
                endcase
            end
            else begin
                burst_wdata = za_element(store_row, store_beat);
                burst_wstrb = 4'b1111;
            end
        end
    end

    always @(posedge clk) begin
        done <= 1'b0;

        if (reset) begin
            state <= ST_IDLE;
            busy <= 1'b0;
            done <= 1'b0;
            error_code <= ERR_NONE;
            cfg_src0 <= 32'd0;
            cfg_src1 <= 32'd0;
            cfg_dst <= 32'd0;
            cfg_bias <= 32'd0;
            cfg_m <= 16'd0;
            cfg_n <= 16'd0;
            cfg_k <= 16'd0;
            cfg_batch <= 16'd0;
            cfg_a_row_stride <= 32'd0;
            cfg_b_row_stride <= 32'd0;
            cfg_c_row_stride <= 32'd0;
            cfg_a_batch_stride <= 32'd0;
            cfg_b_batch_stride <= 32'd0;
            cfg_c_batch_stride <= 32'd0;
            cfg_trans_b <= 1'b0;
            cfg_output_int8 <= 1'b0;
            cfg_bias_enable <= 1'b0;
            cfg_relu <= 1'b0;
            cfg_shift <= 5'd0;
            a_stride_words <= 16'd0;
            b_stride_words <= 16'd0;
            b_rows <= 16'd0;
            b_row_bytes <= 16'd0;
            batch_index <= 16'd0;
            batch_src0 <= 32'd0;
            batch_src1 <= 32'd0;
            batch_dst <= 32'd0;
            load_kind <= LOAD_A;
            load_rows <= 16'd0;
            load_row <= 16'd0;
            load_row_bytes <= 16'd0;
            load_byte_offset <= 16'd0;
            load_local_stride <= 16'd0;
            load_local_row_base <= 16'd0;
            load_external_row_addr <= 32'd0;
            load_external_stride <= 32'd0;
            load_beats <= 4'd0;
            load_beat_index <= 4'd0;
            load_return_state <= ST_IDLE;
            tile_m <= 16'd0;
            tile_n <= 16'd0;
            tile_k <= 16'd0;
            tile_a_base_word <= 16'd0;
            tile_b_n_base_word <= 16'd0;
            tile_b_k_base_word <= 16'd0;
            tile_m_dst_base <= 32'd0;
            tile_dst_base <= 32'd0;
            read_phase <= 2'd0;
            macro_a_top <= 128'd0;
            macro_a_bottom <= 128'd0;
            macro_b_left <= 128'd0;
            macro_b_right <= 128'd0;
            store_row <= 4'd0;
            store_beat <= 4'd0;
            store_beats <= 4'd0;
            tiles_completed <= 32'd0;
        end
        else begin
            case (state)
                ST_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        busy <= 1'b1;
                        error_code <= ERR_NONE;
                        cfg_src0 <= src0_addr;
                        cfg_src1 <= src1_addr;
                        cfg_dst <= dst_addr;
                        cfg_bias <= bias_addr;
                        cfg_m <= m_dim;
                        cfg_n <= n_dim;
                        cfg_k <= k_dim;
                        cfg_batch <= batch_dim == 0 ? 16'd1 : batch_dim;
                        cfg_a_row_stride <= src0_row_stride;
                        cfg_b_row_stride <= src1_row_stride;
                        cfg_c_row_stride <= dst_row_stride;
                        cfg_a_batch_stride <= src0_batch_stride;
                        cfg_b_batch_stride <= src1_batch_stride;
                        cfg_c_batch_stride <= dst_batch_stride;
                        cfg_trans_b <= flag_trans_b;
                        cfg_output_int8 <= flag_output_int8;
                        cfg_bias_enable <= flag_bias;
                        cfg_relu <= flag_relu;
                        cfg_shift <= out_shift;
                        tiles_completed <= 32'd0;
                        state <= ST_VALIDATE;
                    end
                end

                ST_VALIDATE: begin
                    if (cfg_m == 0 || cfg_m > 64 || cfg_n == 0 ||
                        cfg_n > 128 || cfg_k == 0 || cfg_k > 64 ||
                        cfg_src0[1:0] != 0 || cfg_src1[1:0] != 0 ||
                        cfg_dst[1:0] != 0 ||
                        cfg_a_row_stride[1:0] != 0 ||
                        cfg_b_row_stride[1:0] != 0 ||
                        cfg_c_row_stride[1:0] != 0 ||
                        (cfg_bias_enable && cfg_bias[1:0] != 0)) begin
                        error_code <= ERR_CAPACITY;
                        state <= ST_ERROR;
                    end
                    else begin
                        a_stride_words <= a_words_rounded;
                        b_stride_words <= b_words_rounded;
                        b_rows <= cfg_trans_b ? cfg_n : cfg_k;
                        b_row_bytes <= cfg_trans_b ? cfg_k : cfg_n;
                        batch_index <= 16'd0;
                        batch_src0 <= cfg_src0;
                        batch_src1 <= cfg_src1;
                        batch_dst <= cfg_dst;
                        state <= cfg_bias_enable ? ST_BIAS_SETUP
                                                 : ST_BATCH_SETUP;
                    end
                end

                ST_BIAS_SETUP: begin
                    load_kind <= LOAD_BIAS;
                    load_rows <= 16'd1;
                    load_row <= 16'd0;
                    load_row_bytes <= cfg_n << 2;
                    load_byte_offset <= 16'd0;
                    load_local_stride <= cfg_n;
                    load_local_row_base <= 16'd0;
                    load_external_row_addr <= cfg_bias;
                    load_external_stride <= 32'd0;
                    load_return_state <= ST_BATCH_SETUP;
                    state <= ST_LOAD_CMD;
                end

                ST_BATCH_SETUP: begin
                    state <= ST_A_SETUP;
                end

                ST_A_SETUP: begin
                    load_kind <= LOAD_A;
                    load_rows <= cfg_m;
                    load_row <= 16'd0;
                    load_row_bytes <= cfg_k;
                    load_byte_offset <= 16'd0;
                    load_local_stride <= a_stride_words;
                    load_local_row_base <= 16'd0;
                    load_external_row_addr <= batch_src0;
                    load_external_stride <= cfg_a_row_stride;
                    load_return_state <= ST_B_SETUP;
                    state <= ST_LOAD_CMD;
                end

                ST_B_SETUP: begin
                    load_kind <= LOAD_B;
                    load_rows <= b_rows;
                    load_row <= 16'd0;
                    load_row_bytes <= b_row_bytes;
                    load_byte_offset <= 16'd0;
                    load_local_stride <= b_stride_words;
                    load_local_row_base <= 16'd0;
                    load_external_row_addr <= batch_src1;
                    load_external_stride <= cfg_b_row_stride;
                    load_return_state <= ST_COMPUTE_SETUP;
                    state <= ST_LOAD_CMD;
                end

                ST_LOAD_CMD: begin
                    if (burst_cmd_valid && burst_cmd_ready) begin
                        load_beats <= calculated_load_beats;
                        load_beat_index <= 4'd0;
                        state <= ST_LOAD_DATA;
                    end
                end

                ST_LOAD_DATA: begin
                    if (burst_r_valid && burst_r_ready) begin
                        if (burst_rresp != 2'b00) begin
                            error_code <= ERR_DMA;
                            state <= ST_ERROR;
                        end
                        else begin
                            if (load_kind == LOAD_BIAS &&
                                load_local_row_base +
                                (load_byte_offset >> 2) + load_beat_index < 128)
                                bias_memory[load_local_row_base +
                                    (load_byte_offset >> 2) + load_beat_index]
                                    <= burst_rdata;
                            load_beat_index <= load_beat_index + 4'd1;
                        end
                    end
                    if (burst_done) begin
                        if (burst_error) begin
                            error_code <= ERR_DMA;
                            state <= ST_ERROR;
                        end
                        else if (load_byte_offset + (load_beats << 2) >=
                                     load_row_bytes) begin
                            if (load_row + 16'd1 >= load_rows)
                                state <= load_return_state;
                            else begin
                                load_row <= load_row + 16'd1;
                                load_byte_offset <= 16'd0;
                                load_local_row_base <= load_local_row_base +
                                                       load_local_stride;
                                load_external_row_addr <=
                                    load_external_row_addr +
                                    load_external_stride;
                                state <= ST_LOAD_CMD;
                            end
                        end
                        else begin
                            load_byte_offset <= load_byte_offset +
                                                (load_beats << 2);
                            state <= ST_LOAD_CMD;
                        end
                    end
                end

                ST_COMPUTE_SETUP: begin
                    tile_m <= 16'd0;
                    tile_n <= 16'd0;
                    tile_k <= 16'd0;
                    tile_a_base_word <= 16'd0;
                    tile_b_n_base_word <= 16'd0;
                    tile_b_k_base_word <= 16'd0;
                    tile_m_dst_base <= batch_dst;
                    tile_dst_base <= batch_dst;
                    read_phase <= 2'd0;
                    macro_a_top <= 128'd0;
                    macro_a_bottom <= 128'd0;
                    macro_b_left <= 128'd0;
                    macro_b_right <= 128'd0;
                    state <= ST_READ_ISSUE;
                end

                ST_READ_ISSUE: begin
                    state <= ST_READ_CAPTURE;
                end

                ST_READ_CAPTURE: begin
                    case (read_phase)
                        2'd0: begin
                            macro_a_top[31:0] <= a0_rdata;
                            macro_a_top[63:32] <= a1_rdata;
                        end
                        2'd1: begin
                            macro_a_top[95:64] <= a0_rdata;
                            macro_a_top[127:96] <= a1_rdata;
                        end
                        2'd2: begin
                            macro_a_bottom[31:0] <= a0_rdata;
                            macro_a_bottom[63:32] <= a1_rdata;
                        end
                        default: begin
                            macro_a_bottom[95:64] <= a0_rdata;
                            macro_a_bottom[127:96] <= a1_rdata;
                        end
                    endcase

                    if (!cfg_trans_b) begin
                        for (i = 0; i < 4; i = i + 1) begin
                            macro_b_left[(i*4+read_phase)*8 +: 8]
                                <= b0_rdata[i*8 +: 8];
                            macro_b_right[(i*4+read_phase)*8 +: 8]
                                <= b1_rdata[i*8 +: 8];
                        end
                    end
                    else begin
                        if (read_phase < 2) begin
                            macro_b_left[(read_phase*2)*32 +: 32]
                                <= b0_rdata;
                            macro_b_left[(read_phase*2+1)*32 +: 32]
                                <= b1_rdata;
                        end
                        else begin
                            macro_b_right[((read_phase-2)*2)*32 +: 32]
                                <= b0_rdata;
                            macro_b_right[((read_phase-2)*2+1)*32 +: 32]
                                <= b1_rdata;
                        end
                    end

                    if (read_phase == 2'd3) begin
                        read_phase <= 2'd0;
                        state <= ST_MACRO_ISSUE;
                    end
                    else begin
                        read_phase <= read_phase + 2'd1;
                        state <= ST_READ_ISSUE;
                    end
                end

                ST_MACRO_ISSUE: begin
                    if (macro_ready)
                        state <= ST_MACRO_WAIT;
                end

                ST_MACRO_WAIT: begin
                    if (macro_done) begin
                        if (tile_k + 16'd4 >= cfg_k) begin
                            store_row <= 4'd0;
                            store_beat <= 4'd0;
                            store_beats <= cfg_output_int8
                                         ? ((current_valid_n + 16'd3) >> 2)
                                         : current_valid_n[3:0];
                            state <= ST_STORE_CMD;
                        end
                        else begin
                            tile_k <= tile_k + 16'd4;
                            tile_b_k_base_word <= tile_b_k_base_word +
                                                  (b_stride_words << 2);
                            macro_a_top <= 128'd0;
                            macro_a_bottom <= 128'd0;
                            macro_b_left <= 128'd0;
                            macro_b_right <= 128'd0;
                            state <= ST_READ_ISSUE;
                        end
                    end
                end

                ST_STORE_CMD: begin
                    if (burst_cmd_valid && burst_cmd_ready) begin
                        store_beat <= 4'd0;
                        state <= ST_STORE_DATA;
                    end
                end

                ST_STORE_DATA: begin
                    if (burst_w_valid && burst_w_ready) begin
                        if (store_beat + 4'd1 >= store_beats)
                            state <= ST_STORE_WAIT;
                        else
                            store_beat <= store_beat + 4'd1;
                    end
                end

                ST_STORE_WAIT: begin
                    if (burst_done) begin
                        if (burst_error) begin
                            error_code <= ERR_DMA;
                            state <= ST_ERROR;
                        end
                        else if (store_row + 4'd1 >= current_valid_m)
                            state <= ST_TILE_ADV;
                        else begin
                            store_row <= store_row + 4'd1;
                            store_beat <= 4'd0;
                            state <= ST_STORE_CMD;
                        end
                    end
                end

                ST_TILE_ADV: begin
                    tiles_completed <= tiles_completed + 32'd1;
                    tile_k <= 16'd0;
                    tile_b_k_base_word <= 16'd0;
                    macro_a_top <= 128'd0;
                    macro_a_bottom <= 128'd0;
                    macro_b_left <= 128'd0;
                    macro_b_right <= 128'd0;
                    if (tile_n + 16'd8 < cfg_n) begin
                        tile_n <= tile_n + 16'd8;
                        tile_b_n_base_word <= tile_b_n_base_word +
                                              (b_stride_words << 3);
                        tile_dst_base <= tile_dst_base +
                                         (cfg_output_int8 ? 32'd8 : 32'd32);
                        state <= ST_READ_ISSUE;
                    end
                    else if (tile_m + 16'd8 < cfg_m) begin
                        tile_m <= tile_m + 16'd8;
                        tile_n <= 16'd0;
                        tile_a_base_word <= tile_a_base_word +
                                             (a_stride_words << 3);
                        tile_b_n_base_word <= 16'd0;
                        tile_m_dst_base <= tile_m_dst_base +
                                           (cfg_c_row_stride << 3);
                        tile_dst_base <= tile_m_dst_base +
                                         (cfg_c_row_stride << 3);
                        state <= ST_READ_ISSUE;
                    end
                    else
                        state <= ST_BATCH_ADV;
                end

                ST_BATCH_ADV: begin
                    if (batch_index + 16'd1 < cfg_batch) begin
                        batch_index <= batch_index + 16'd1;
                        batch_src0 <= batch_src0 + cfg_a_batch_stride;
                        batch_src1 <= batch_src1 + cfg_b_batch_stride;
                        batch_dst <= batch_dst + cfg_c_batch_stride;
                        state <= ST_A_SETUP;
                    end
                    else
                        state <= ST_FINISH;
                end

                ST_FINISH: begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    state <= ST_IDLE;
                end

                ST_ERROR: begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    state <= ST_IDLE;
                end

                default: begin
                    error_code <= ERR_DMA;
                    state <= ST_ERROR;
                end
            endcase
        end
    end

endmodule
