`timescale 1ns / 1ps
`include "lsme_defs_fused.vh"

// 描述符驱动的 HCTA 控制器。
// V1 GEMM 会被分解为 LDZ/PSET/ZERO/SMOPA/STZA，因此高级描述符路径与
// CPU 低级自定义指令使用同一套 ZA 数据通路。V2 GEMM 通过宏瓦片端口
// 直接复用同一个 Z/P/ZA 与 MOPA 核。Softmax 和向量加法使用专用整数逻辑。
module lsme_exec_engine (
    input              clk,
    input              reset,

    input              start,
    input      [31:0]  descriptor_addr,
    output reg         busy,
    output reg         done,
    output reg [7:0]   error_code,
    output reg [31:0]  user_tag,
    output reg [1:0]   schedule_mode,

    output reg [31:0]  perf_descriptor_count,
    output reg [31:0]  perf_direct_mem_words,
    output reg [31:0]  perf_gemm_tiles,
    output reg [31:0]  perf_softmax_rows,
    output reg [31:0]  perf_engine_cycles,
    output reg [31:0]  perf_compute_cycles,
    output reg [31:0]  perf_memory_stall_cycles,
    output reg [31:0]  perf_overlap_cycles,
    output reg [31:0]  perf_last_descriptor_cycles,

    output reg         core_req_valid,
    input              core_req_ready,
    output reg [2:0]   core_req_command,
    output reg [6:0]   core_req_imm,
    output reg [31:0]  core_req_rj,
    output reg [31:0]  core_req_rk,
    input              core_rsp_valid,
    input      [31:0]  core_rsp_rdata,

    output reg         mem_req_valid,
    input              mem_req_ready,
    output reg         mem_req_write,
    output reg [31:0]  mem_req_addr,
    output reg [31:0]  mem_req_wdata,
    output reg [3:0]   mem_req_wstrb,
    input              mem_rsp_valid,
    input      [31:0]  mem_rsp_rdata,
    input              mem_rsp_error,

    output             burst_cmd_valid,
    input              burst_cmd_ready,
    output             burst_cmd_write,
    output     [31:0]  burst_cmd_addr,
    output     [3:0]   burst_cmd_beats,
    output             burst_w_valid,
    input              burst_w_ready,
    output     [31:0]  burst_wdata,
    output     [3:0]   burst_wstrb,
    input              burst_r_valid,
    output             burst_r_ready,
    input      [31:0]  burst_rdata,
    input              burst_rlast,
    input      [1:0]   burst_rresp,
    input              burst_done,
    input              burst_error,
    input              burst_busy,

    output             macro_start,
    input              macro_ready,
    output             macro_first,
    output     [127:0] macro_a_top,
    output     [127:0] macro_a_bottom,
    output     [127:0] macro_b_left,
    output     [127:0] macro_b_right,
    output     [15:0]  macro_pred_a_top,
    output     [15:0]  macro_pred_a_bottom,
    output     [15:0]  macro_pred_b_left,
    output     [15:0]  macro_pred_b_right,
    output     [2047:0] macro_za_init,
    input              macro_busy,
    input              macro_done,
    input      [2047:0] macro_za_out
);

    localparam [5:0] ST_IDLE          = 6'd0;
    localparam [5:0] ST_DESC_REQ      = 6'd1;
    localparam [5:0] ST_DESC_WAIT     = 6'd2;
    localparam [5:0] ST_DECODE        = 6'd3;
    localparam [5:0] ST_CORE_WAIT     = 6'd4;
    localparam [5:0] ST_G_INIT        = 6'd5;
    localparam [5:0] ST_G_ZERO        = 6'd6;
    localparam [5:0] ST_G_BIAS        = 6'd7;
    localparam [5:0] ST_G_P0          = 6'd8;
    localparam [5:0] ST_G_P1          = 6'd9;
    localparam [5:0] ST_G_LDA         = 6'd10;
    localparam [5:0] ST_G_LDB         = 6'd11;
    localparam [5:0] ST_G_MOPA        = 6'd12;
    localparam [5:0] ST_G_K_ADV       = 6'd13;
    localparam [5:0] ST_G_STORE       = 6'd14;
    localparam [5:0] ST_G_ADV         = 6'd15;
    localparam [5:0] ST_SM_READ_REQ   = 6'd16;
    localparam [5:0] ST_SM_READ_WAIT  = 6'd17;
    localparam [5:0] ST_SM_START      = 6'd18;
    localparam [5:0] ST_SM_WAIT       = 6'd19;
    localparam [5:0] ST_SM_WRITE_REQ  = 6'd20;
    localparam [5:0] ST_SM_WRITE_WAIT = 6'd21;
    localparam [5:0] ST_SM_ADV        = 6'd22;
    localparam [5:0] ST_VA_READ0_REQ  = 6'd23;
    localparam [5:0] ST_VA_READ0_WAIT = 6'd24;
    localparam [5:0] ST_VA_READ1_REQ  = 6'd25;
    localparam [5:0] ST_VA_READ1_WAIT = 6'd26;
    localparam [5:0] ST_VA_WRITE_REQ  = 6'd27;
    localparam [5:0] ST_VA_WRITE_WAIT = 6'd28;
    localparam [5:0] ST_VA_ADV        = 6'd29;
    localparam [5:0] ST_FINISH        = 6'd30;
    localparam [5:0] ST_ERROR         = 6'd31;
    localparam [5:0] ST_G_V2_WAIT     = 6'd32;
    localparam [5:0] ST_FA_WAIT       = 6'd33;

    localparam [7:0] ERR_NONE        = 8'h00;
    localparam [7:0] ERR_DESC_MEMORY = 8'h10;
    localparam [7:0] ERR_BAD_OP      = 8'h11;
    localparam [7:0] ERR_BAD_DIM     = 8'h12;
    localparam [7:0] ERR_UNSUPPORTED = 8'h13;
    localparam [7:0] ERR_CORE        = 8'h14;
    localparam [7:0] ERR_DATA_MEMORY = 8'h15;

    reg [5:0] state;
    reg [5:0] after_core_state;
    reg [4:0] descriptor_index;
    reg [31:0] descriptor_base;
    reg [31:0] descriptor [0:15];

    reg [7:0] operation;
    reg [23:0] flags;
    reg [31:0] src0_addr;
    reg [31:0] src1_addr;
    reg [31:0] dst_addr;
    reg [31:0] bias_addr;
    reg [15:0] m_dim;
    reg [15:0] n_dim;
    reg [15:0] k_dim;
    reg [15:0] batch_dim;
    reg [31:0] src0_row_stride;
    reg [31:0] src1_row_stride;
    reg [31:0] dst_row_stride;
    reg [31:0] src0_batch_stride;
    reg [31:0] src1_batch_stride;
    reg [31:0] dst_batch_stride;
    reg [4:0] out_shift;
    reg [4:0] score_shift;
    reg [7:0] head_count;
    reg [7:0] head_dim;

    reg [15:0] batch_index;
    reg [15:0] row_index;
    reg [15:0] tile_m;
    reg [15:0] tile_n;
    reg [15:0] tile_k;

    reg [31:0] batch_src0;
    reg [31:0] batch_src1;
    reg [31:0] batch_dst;
    reg [31:0] m_src0_base;
    reg [31:0] m_dst_base;
    reg [31:0] tile_src1_base;
    reg [31:0] tile_dst_base;
    reg [31:0] tile_bias_base;
    reg [31:0] a_k_addr;
    reg [31:0] b_k_addr;

    reg [2047:0] softmax_input;
    wire [511:0] softmax_output;
    reg softmax_start;
    wire softmax_busy;
    wire softmax_done;
    reg [6:0] softmax_index;
    reg [4:0] softmax_word_index;
    reg [31:0] softmax_row_src;
    reg [31:0] softmax_row_dst;

    reg [15:0] vadd_word_index;
    reg [15:0] vadd_words_per_row;
    reg [31:0] vadd_row_src0;
    reg [31:0] vadd_row_src1;
    reg [31:0] vadd_row_dst;
    reg [31:0] vadd_src0_word;

    reg [31:0] vadd_result_word;
    reg signed [32:0] vadd_sum32;
    integer i;
    integer byte_lane;

    reg v2_start;
    wire v2_busy;
    wire v2_done;
    wire [7:0] v2_error;
    wire [31:0] v2_tiles_completed;
    wire v2_compute_active;
    wire v2_memory_stall;
    reg fused_attention_start;
    wire fused_attention_busy;
    wire fused_attention_done;
    wire [7:0] fused_attention_error;
    wire fused_attention_mem_req_valid;
    wire fused_attention_mem_req_write;
    wire [31:0] fused_attention_mem_req_addr;
    wire [31:0] fused_attention_mem_req_wdata;
    wire [3:0] fused_attention_mem_req_wstrb;
    wire [31:0] fused_attention_macro_tiles;
    wire [31:0] fused_attention_softmax_rows;
    wire [31:0] fused_attention_memory_words;
    wire fused_attention_compute_active;
    wire fused_attention_memory_stall;

    wire v2_macro_start;
    wire v2_macro_first;
    wire [127:0] v2_macro_a_top;
    wire [127:0] v2_macro_a_bottom;
    wire [127:0] v2_macro_b_left;
    wire [127:0] v2_macro_b_right;
    wire [15:0] v2_macro_pred_a_top;
    wire [15:0] v2_macro_pred_a_bottom;
    wire [15:0] v2_macro_pred_b_left;
    wire [15:0] v2_macro_pred_b_right;
    wire [2047:0] v2_macro_za_init;

    wire fused_macro_start;
    wire fused_macro_first;
    wire [127:0] fused_macro_a_top;
    wire [127:0] fused_macro_a_bottom;
    wire [127:0] fused_macro_b_left;
    wire [127:0] fused_macro_b_right;
    wire [15:0] fused_macro_pred_a_top;
    wire [15:0] fused_macro_pred_a_bottom;
    wire [15:0] fused_macro_pred_b_left;
    wire [15:0] fused_macro_pred_b_right;
    wire [2047:0] fused_macro_za_init;
    reg [31:0] descriptor_cycle_counter;

    wire flag_trans_b = flags[`LSME_FLAG_TRANS_B];
    wire flag_output_int8 = flags[`LSME_FLAG_OUTPUT_INT8];
    wire flag_bias = flags[`LSME_FLAG_BIAS];
    wire flag_relu = flags[`LSME_FLAG_RELU];
    wire descriptor_is_v2 = descriptor[15][31:16] == `LSME_V2_AUX_MAGIC;
    wire [7:0] descriptor_v2_mode = descriptor[15][7:0];

    function automatic [31:0] physical_addr;
        input [31:0] address;
        begin
            // CPU 使用 0xa0000000～0xbfffffff 的 DMW 非缓存别名；
            // 加速器发起 AXI 访问前，需要去掉别名前缀并恢复物理地址。
            physical_addr = address[31:29] == 3'b101
                          ? {3'b000, address[28:0]} : address;
        end
    endfunction

    function automatic [15:0] make_predicate;
        input [15:0] outer_index;
        input [15:0] outer_size;
        input [15:0] inner_index;
        input [15:0] inner_size;
        integer outer_lane;
        integer inner_lane;
        begin
            make_predicate = 16'd0;
            for (outer_lane = 0; outer_lane < 4; outer_lane = outer_lane + 1)
                for (inner_lane = 0; inner_lane < 4; inner_lane = inner_lane + 1)
                    if ((outer_index + outer_lane < outer_size) &&
                        (inner_index + inner_lane < inner_size))
                        make_predicate[outer_lane*4+inner_lane] = 1'b1;
        end
    endfunction

    function automatic [3:0] tail_strobe;
        input [15:0] remaining;
        begin
            if (remaining >= 4)
                tail_strobe = 4'b1111;
            else if (remaining == 3)
                tail_strobe = 4'b0111;
            else if (remaining == 2)
                tail_strobe = 4'b0011;
            else
                tail_strobe = 4'b0001;
        end
    endfunction

    function automatic [7:0] saturating_add_s8;
        input [7:0] lhs;
        input [7:0] rhs;
        input relu;
        reg signed [8:0] sum;
        begin
            sum = $signed(lhs) + $signed(rhs);
            if (relu && sum < 0)
                saturating_add_s8 = 8'd0;
            else if (sum > 127)
                saturating_add_s8 = 8'h7f;
            else if (sum < -128)
                saturating_add_s8 = 8'h80;
            else
                saturating_add_s8 = sum[7:0];
        end
    endfunction

    lsme_softmax_core u_softmax (
        .clk(clk),
        .reset(reset),
        .start(softmax_start),
        .count(n_dim[6:0]),
        .score_shift(score_shift),
        .row_in(softmax_input),
        .busy(softmax_busy),
        .done(softmax_done),
        .row_out(softmax_output)
    );

    lsme_gemm_v2 u_gemm_v2 (
        .clk(clk), .reset(reset), .start(v2_start),
        .busy(v2_busy), .done(v2_done), .error_code(v2_error),
        .src0_addr(src0_addr), .src1_addr(src1_addr),
        .dst_addr(dst_addr), .bias_addr(bias_addr),
        .m_dim(m_dim), .n_dim(n_dim), .k_dim(k_dim),
        .batch_dim(batch_dim),
        .src0_row_stride(src0_row_stride),
        .src1_row_stride(src1_row_stride),
        .dst_row_stride(dst_row_stride),
        .src0_batch_stride(src0_batch_stride),
        .src1_batch_stride(src1_batch_stride),
        .dst_batch_stride(dst_batch_stride),
        .flag_trans_b(flag_trans_b),
        .flag_output_int8(flag_output_int8),
        .flag_bias(flag_bias), .flag_relu(flag_relu),
        .out_shift(out_shift),
        .burst_cmd_valid(burst_cmd_valid),
        .burst_cmd_ready(burst_cmd_ready),
        .burst_cmd_write(burst_cmd_write),
        .burst_cmd_addr(burst_cmd_addr),
        .burst_cmd_beats(burst_cmd_beats),
        .burst_w_valid(burst_w_valid),
        .burst_w_ready(burst_w_ready),
        .burst_wdata(burst_wdata), .burst_wstrb(burst_wstrb),
        .burst_r_valid(burst_r_valid),
        .burst_r_ready(burst_r_ready),
        .burst_rdata(burst_rdata), .burst_rlast(burst_rlast),
        .burst_rresp(burst_rresp),
        .burst_done(burst_done), .burst_error(burst_error),
        .macro_start(v2_macro_start), .macro_ready(macro_ready),
        .macro_first(v2_macro_first),
        .macro_a_top(v2_macro_a_top),
        .macro_a_bottom(v2_macro_a_bottom),
        .macro_b_left(v2_macro_b_left),
        .macro_b_right(v2_macro_b_right),
        .macro_pred_a_top(v2_macro_pred_a_top),
        .macro_pred_a_bottom(v2_macro_pred_a_bottom),
        .macro_pred_b_left(v2_macro_pred_b_left),
        .macro_pred_b_right(v2_macro_pred_b_right),
        .macro_za_init(v2_macro_za_init),
        .macro_busy(macro_busy), .macro_done(macro_done),
        .macro_za_out(macro_za_out),
        .tiles_completed(v2_tiles_completed),
        .compute_active(v2_compute_active),
        .memory_stall(v2_memory_stall)
    );

    // 与 V2 GEMM 共用同一套宏端口。执行器状态是唯一仲裁条件，因而两个
    // 引擎不可能同时向 ZA/MOPA 发请求，也不会改变原 V1/V2 GEMM 的路径。
    lsme_fused_attention_core u_fused_attention (
        .clk(clk), .reset(reset), .start(fused_attention_start),
        .busy(fused_attention_busy), .done(fused_attention_done),
        .error_code(fused_attention_error),
        .q_addr(src0_addr), .k_addr(src1_addr), .v_addr(bias_addr),
        .context_addr(dst_addr),
        .attention_sum_addr(physical_addr(descriptor[15])),
        .q_row_stride(src0_row_stride), .kv_row_stride(src1_row_stride),
        .context_row_stride(dst_row_stride),
        .q_head_stride(src0_batch_stride),
        .kv_head_stride(src1_batch_stride),
        .context_head_offset(dst_batch_stride),
        .query_count(m_dim), .key_count(n_dim), .head_dim(k_dim),
        .head_count(batch_dim), .score_shift(score_shift),
        .output_shift(out_shift),
        .mem_req_valid(fused_attention_mem_req_valid),
        .mem_req_ready(mem_req_ready && state == ST_FA_WAIT),
        .mem_req_write(fused_attention_mem_req_write),
        .mem_req_addr(fused_attention_mem_req_addr),
        .mem_req_wdata(fused_attention_mem_req_wdata),
        .mem_req_wstrb(fused_attention_mem_req_wstrb),
        .mem_rsp_valid(mem_rsp_valid && state == ST_FA_WAIT),
        .mem_rsp_rdata(mem_rsp_rdata), .mem_rsp_error(mem_rsp_error),
        .macro_start(fused_macro_start), .macro_ready(macro_ready),
        .macro_first(fused_macro_first), .macro_a_top(fused_macro_a_top),
        .macro_a_bottom(fused_macro_a_bottom), .macro_b_left(fused_macro_b_left),
        .macro_b_right(fused_macro_b_right),
        .macro_pred_a_top(fused_macro_pred_a_top),
        .macro_pred_a_bottom(fused_macro_pred_a_bottom),
        .macro_pred_b_left(fused_macro_pred_b_left),
        .macro_pred_b_right(fused_macro_pred_b_right),
        .macro_za_init(fused_macro_za_init),
        .macro_busy(macro_busy), .macro_done(macro_done),
        .macro_za_out(macro_za_out),
        .macro_tiles_completed(fused_attention_macro_tiles),
        .softmax_rows_completed(fused_attention_softmax_rows),
        .memory_words(fused_attention_memory_words),
        .compute_active(fused_attention_compute_active),
        .memory_stall(fused_attention_memory_stall)
    );

    assign macro_start = state == ST_FA_WAIT ? fused_macro_start : v2_macro_start;
    assign macro_first = state == ST_FA_WAIT ? fused_macro_first : v2_macro_first;
    assign macro_a_top = state == ST_FA_WAIT ? fused_macro_a_top : v2_macro_a_top;
    assign macro_a_bottom = state == ST_FA_WAIT ? fused_macro_a_bottom : v2_macro_a_bottom;
    assign macro_b_left = state == ST_FA_WAIT ? fused_macro_b_left : v2_macro_b_left;
    assign macro_b_right = state == ST_FA_WAIT ? fused_macro_b_right : v2_macro_b_right;
    assign macro_pred_a_top = state == ST_FA_WAIT ? fused_macro_pred_a_top : v2_macro_pred_a_top;
    assign macro_pred_a_bottom = state == ST_FA_WAIT ? fused_macro_pred_a_bottom : v2_macro_pred_a_bottom;
    assign macro_pred_b_left = state == ST_FA_WAIT ? fused_macro_pred_b_left : v2_macro_pred_b_left;
    assign macro_pred_b_right = state == ST_FA_WAIT ? fused_macro_pred_b_right : v2_macro_pred_b_right;
    assign macro_za_init = state == ST_FA_WAIT ? fused_macro_za_init : v2_macro_za_init;

    always @(*) begin
        core_req_valid = 1'b0;
        core_req_command = `LSME_CMD_CTRL;
        core_req_imm = 7'd0;
        core_req_rj = 32'd0;
        core_req_rk = 32'd0;

        case (state)
            ST_G_ZERO: begin
                core_req_valid = 1'b1;
                core_req_command = `LSME_CMD_ZERO;
                core_req_imm = 7'b0000001;
            end
            ST_G_BIAS: begin
                core_req_valid = 1'b1;
                core_req_command = `LSME_CMD_ZERO;
                core_req_imm = 7'b1000000;
                core_req_rj = tile_bias_base;
            end
            ST_G_P0: begin
                core_req_valid = 1'b1;
                core_req_command = `LSME_CMD_PSET;
                core_req_imm = 7'd0;
                core_req_rj = {16'd0, make_predicate(tile_m, m_dim, tile_k, k_dim)};
            end
            ST_G_P1: begin
                core_req_valid = 1'b1;
                core_req_command = `LSME_CMD_PSET;
                core_req_imm = 7'd1;
                core_req_rj = {16'd0, make_predicate(tile_n, n_dim, tile_k, k_dim)};
            end
            ST_G_LDA: begin
                core_req_valid = 1'b1;
                core_req_command = `LSME_CMD_LDZ;
                core_req_imm = 7'd0; // 写入 Z0，按行跨步读取，不转置
                core_req_rj = a_k_addr;
                core_req_rk = src0_row_stride;
            end
            ST_G_LDB: begin
                core_req_valid = 1'b1;
                core_req_command = `LSME_CMD_LDZ;
                // 普通 B 按 K×N 行主序存放，装入 Z 时需要做 4×4 转置。
                // TRANS_B 表示内存中已经按 N×K 预转置，不再执行转置装载。
                core_req_imm = flag_trans_b ? 7'd1 : 7'd9;
                core_req_rj = b_k_addr;
                core_req_rk = src1_row_stride;
            end
            ST_G_MOPA: begin
                core_req_valid = 1'b1;
                core_req_command = `LSME_CMD_SMOPA;
                // 选择 Z0、Z1、P0、P1 和 ZA0。
                core_req_rj = 32'h00000108;
            end
            ST_G_STORE: begin
                core_req_valid = 1'b1;
                core_req_command = `LSME_CMD_STZA;
                core_req_imm = {3'd0, flag_relu, flag_output_int8, 2'b00};
                core_req_rj = tile_dst_base;
                core_req_rk = {11'd0, out_shift, dst_row_stride[15:0]};
            end
            default: begin end
        endcase
    end

    always @(*) begin
        vadd_result_word = 32'd0;
        vadd_sum32 = $signed({vadd_src0_word[31], vadd_src0_word})
                   + $signed({mem_rsp_rdata[31], mem_rsp_rdata});
        if (flag_output_int8) begin
            for (byte_lane = 0; byte_lane < 4; byte_lane = byte_lane + 1)
                vadd_result_word[byte_lane*8 +: 8] = saturating_add_s8(
                    vadd_src0_word[byte_lane*8 +: 8],
                    mem_rsp_rdata[byte_lane*8 +: 8], flag_relu);
        end
        else if (flag_relu && vadd_sum32 < 0)
            vadd_result_word = 32'd0;
        else if (vadd_sum32 > 33'sh07fffffff)
            vadd_result_word = 32'h7fffffff;
        else if (vadd_sum32 < -33'sh080000000)
            vadd_result_word = 32'h80000000;
        else
            vadd_result_word = vadd_sum32[31:0];
    end

    always @(*) begin
        mem_req_valid = 1'b0;
        mem_req_write = 1'b0;
        mem_req_addr = 32'd0;
        mem_req_wdata = 32'd0;
        mem_req_wstrb = 4'd0;

        if (state == ST_FA_WAIT) begin
            mem_req_valid = fused_attention_mem_req_valid;
            mem_req_write = fused_attention_mem_req_write;
            mem_req_addr = fused_attention_mem_req_addr;
            mem_req_wdata = fused_attention_mem_req_wdata;
            mem_req_wstrb = fused_attention_mem_req_wstrb;
        end
        else case (state)
            ST_DESC_REQ: begin
                mem_req_valid = 1'b1;
                mem_req_addr = descriptor_base + {descriptor_index, 2'b00};
            end
            ST_SM_READ_REQ: begin
                mem_req_valid = 1'b1;
                mem_req_addr = softmax_row_src + {softmax_index, 2'b00};
            end
            ST_SM_WRITE_REQ: begin
                mem_req_valid = 1'b1;
                mem_req_write = 1'b1;
                mem_req_addr = softmax_row_dst + {softmax_word_index, 2'b00};
                mem_req_wdata = softmax_output[softmax_word_index*32 +: 32];
                mem_req_wstrb = tail_strobe(n_dim - {9'd0, softmax_word_index, 2'b00});
            end
            ST_VA_READ0_REQ: begin
                mem_req_valid = 1'b1;
                mem_req_addr = vadd_row_src0 + {vadd_word_index, 2'b00};
            end
            ST_VA_READ1_REQ: begin
                mem_req_valid = 1'b1;
                mem_req_addr = vadd_row_src1 + {vadd_word_index, 2'b00};
            end
            ST_VA_WRITE_REQ: begin
                mem_req_valid = 1'b1;
                mem_req_write = 1'b1;
                mem_req_addr = vadd_row_dst + {vadd_word_index, 2'b00};
                mem_req_wdata = vadd_result_word;
                mem_req_wstrb = flag_output_int8
                    ? tail_strobe(n_dim - {vadd_word_index, 2'b00})
                    : 4'b1111;
            end
            default: begin end
        endcase
    end

    always @(posedge clk) begin
        done <= 1'b0;
        softmax_start <= 1'b0;
        v2_start <= 1'b0;
        fused_attention_start <= 1'b0;

        if (reset) begin
            state <= ST_IDLE;
            after_core_state <= ST_IDLE;
            busy <= 1'b0;
            done <= 1'b0;
            error_code <= ERR_NONE;
            user_tag <= 32'd0;
            schedule_mode <= `LSME_MODE_K_SPLIT;
            perf_descriptor_count <= 32'd0;
            perf_direct_mem_words <= 32'd0;
            perf_gemm_tiles <= 32'd0;
            perf_softmax_rows <= 32'd0;
            perf_engine_cycles <= 32'd0;
            perf_compute_cycles <= 32'd0;
            perf_memory_stall_cycles <= 32'd0;
            perf_overlap_cycles <= 32'd0;
            perf_last_descriptor_cycles <= 32'd0;
            descriptor_cycle_counter <= 32'd0;
            v2_start <= 1'b0;
            fused_attention_start <= 1'b0;
            descriptor_index <= 5'd0;
            descriptor_base <= 32'd0;
            operation <= 8'd0;
            flags <= 24'd0;
            src0_addr <= 32'd0;
            src1_addr <= 32'd0;
            dst_addr <= 32'd0;
            bias_addr <= 32'd0;
            m_dim <= 16'd0;
            n_dim <= 16'd0;
            k_dim <= 16'd0;
            batch_dim <= 16'd0;
            src0_row_stride <= 32'd0;
            src1_row_stride <= 32'd0;
            dst_row_stride <= 32'd0;
            src0_batch_stride <= 32'd0;
            src1_batch_stride <= 32'd0;
            dst_batch_stride <= 32'd0;
            out_shift <= 5'd0;
            score_shift <= 5'd0;
            head_count <= 8'd0;
            head_dim <= 8'd0;
            batch_index <= 16'd0;
            row_index <= 16'd0;
            tile_m <= 16'd0;
            tile_n <= 16'd0;
            tile_k <= 16'd0;
            batch_src0 <= 32'd0;
            batch_src1 <= 32'd0;
            batch_dst <= 32'd0;
            m_src0_base <= 32'd0;
            m_dst_base <= 32'd0;
            tile_src1_base <= 32'd0;
            tile_dst_base <= 32'd0;
            tile_bias_base <= 32'd0;
            a_k_addr <= 32'd0;
            b_k_addr <= 32'd0;
            softmax_input <= 2048'd0;
            softmax_start <= 1'b0;
            softmax_index <= 7'd0;
            softmax_word_index <= 5'd0;
            softmax_row_src <= 32'd0;
            softmax_row_dst <= 32'd0;
            vadd_word_index <= 16'd0;
            vadd_words_per_row <= 16'd0;
            vadd_row_src0 <= 32'd0;
            vadd_row_src1 <= 32'd0;
            vadd_row_dst <= 32'd0;
            vadd_src0_word <= 32'd0;
            for (i = 0; i < 16; i = i + 1)
                descriptor[i] <= 32'd0;
        end
        else begin
            if (busy) begin
                perf_engine_cycles <= perf_engine_cycles + 32'd1;
                descriptor_cycle_counter <= descriptor_cycle_counter + 32'd1;
            end
            if (v2_compute_active || softmax_busy || fused_attention_compute_active)
                perf_compute_cycles <= perf_compute_cycles + 32'd1;
            if (v2_memory_stall || fused_attention_memory_stall)
                perf_memory_stall_cycles <= perf_memory_stall_cycles + 32'd1;
            if (v2_compute_active && burst_busy)
                perf_overlap_cycles <= perf_overlap_cycles + 32'd1;

            case (state)
                ST_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        busy <= 1'b1;
                        error_code <= ERR_NONE;
                        descriptor_cycle_counter <= 32'd0;
                        descriptor_base <= physical_addr(descriptor_addr);
                        descriptor_index <= 5'd0;
                        state <= ST_DESC_REQ;
                    end
                end

                ST_DESC_REQ: begin
                    if (mem_req_ready)
                        state <= ST_DESC_WAIT;
                end

                ST_DESC_WAIT: begin
                    if (mem_rsp_valid) begin
                        if (mem_rsp_error) begin
                            error_code <= ERR_DESC_MEMORY;
                            state <= ST_ERROR;
                        end
                        else begin
                            descriptor[descriptor_index] <= mem_rsp_rdata;
                            perf_direct_mem_words <= perf_direct_mem_words + 32'd1;
                            if (descriptor_index == 15)
                                state <= ST_DECODE;
                            else begin
                                descriptor_index <= descriptor_index + 5'd1;
                                state <= ST_DESC_REQ;
                            end
                        end
                    end
                end

                ST_DECODE: begin
                    operation <= descriptor[0][7:0];
                    flags <= descriptor[0][31:8];
                    src0_addr <= physical_addr(descriptor[1]);
                    src1_addr <= physical_addr(descriptor[2]);
                    dst_addr <= physical_addr(descriptor[3]);
                    bias_addr <= physical_addr(descriptor[4]);
                    m_dim <= descriptor[5][15:0];
                    n_dim <= descriptor[5][31:16];
                    k_dim <= descriptor[6][15:0];
                    batch_dim <= descriptor[6][31:16] == 0
                               ? 16'd1 : descriptor[6][31:16];
                    src0_row_stride <= descriptor[7] == 0
                        ? {16'd0, descriptor[6][15:0]} : descriptor[7];
                    src1_row_stride <= descriptor[8] == 0
                        ? {16'd0, descriptor[5][31:16]} : descriptor[8];
                    dst_row_stride <= descriptor[9] == 0
                        ? (descriptor[0][8+`LSME_FLAG_OUTPUT_INT8]
                           ? {16'd0, descriptor[5][31:16]}
                           : {14'd0, descriptor[5][31:16], 2'b00})
                        : descriptor[9];
                    src0_batch_stride <= descriptor[10];
                    src1_batch_stride <= descriptor[11];
                    dst_batch_stride <= descriptor[12];
                    out_shift <= descriptor[13][4:0];
                    score_shift <= descriptor[13][12:8];
                    head_count <= descriptor[13][23:16];
                    head_dim <= descriptor[13][31:24];
                    user_tag <= descriptor[14];

                    batch_index <= 16'd0;
                    row_index <= 16'd0;
                    tile_m <= 16'd0;
                    tile_n <= 16'd0;
                    tile_k <= 16'd0;
                    batch_src0 <= physical_addr(descriptor[1]);
                    batch_src1 <= physical_addr(descriptor[2]);
                    batch_dst <= physical_addr(descriptor[3]);
                    m_src0_base <= physical_addr(descriptor[1]);
                    m_dst_base <= physical_addr(descriptor[3]);
                    tile_src1_base <= physical_addr(descriptor[2]);
                    tile_dst_base <= physical_addr(descriptor[3]);
                    tile_bias_base <= physical_addr(descriptor[4]);
                    softmax_row_src <= physical_addr(descriptor[1]);
                    softmax_row_dst <= physical_addr(descriptor[3]);
                    vadd_row_src0 <= physical_addr(descriptor[1]);
                    vadd_row_src1 <= physical_addr(descriptor[2]);
                    vadd_row_dst <= physical_addr(descriptor[3]);

                    if (descriptor[0][8+`LSME_FLAG_HEAD4] &&
                        descriptor[13][23:16] == 8'd4)
                        schedule_mode <= `LSME_MODE_HEAD4;
                    else if (descriptor[5][31:16] >= 8 &&
                             descriptor[6][15:0] >= 8)
                        schedule_mode <= `LSME_MODE_TILE8;
                    else
                        schedule_mode <= `LSME_MODE_K_SPLIT;

                    if (descriptor[5][15:0] == 0 ||
                        descriptor[5][31:16] == 0) begin
                        error_code <= ERR_BAD_DIM;
                        state <= ST_ERROR;
                    end
                    else if (descriptor[0][8+`LSME_FLAG_ACCUMULATE] ||
                             descriptor[0][8+`LSME_FLAG_PER_CHANNEL_SHIFT]) begin
                        error_code <= ERR_UNSUPPORTED;
                        state <= ST_ERROR;
                    end
                    else begin
                        case (descriptor[0][7:0])
                            `LSME_OP_GEMM: begin
                                if (descriptor[6][15:0] == 0) begin
                                    error_code <= ERR_BAD_DIM;
                                    state <= ST_ERROR;
                                end
                                else if (descriptor_is_v2 &&
                                         descriptor_v2_mode !=
                                         `LSME_V2_MODE_STREAM) begin
                                    schedule_mode <= `LSME_MODE_MACRO8;
                                    v2_start <= 1'b1;
                                    state <= ST_G_V2_WAIT;
                                end
                                else if (descriptor[7][31:16] != 0 ||
                                         descriptor[8][31:16] != 0 ||
                                         descriptor[9][31:16] != 0) begin
                                    error_code <= ERR_BAD_DIM;
                                    state <= ST_ERROR;
                                end
                                else
                                    state <= ST_G_INIT;
                            end
                            `LSME_OP_SOFTMAX: begin
                                if (descriptor[5][31:16] > 64) begin
                                    error_code <= ERR_BAD_DIM;
                                    state <= ST_ERROR;
                                end
                                else begin
                                    softmax_input <= 2048'd0;
                                    softmax_index <= 7'd0;
                                    state <= ST_SM_READ_REQ;
                                end
                            end
                            `LSME_OP_VECTOR_ADD: begin
                                vadd_word_index <= 16'd0;
                                vadd_words_per_row <=
                                    descriptor[0][8+`LSME_FLAG_OUTPUT_INT8]
                                    ? ((descriptor[5][31:16] + 16'd3) >> 2)
                                    : descriptor[5][31:16];
                                state <= ST_VA_READ0_REQ;
                            end
                            `LSME_OP_FUSED_ATTENTION: begin
                                // word4 在该操作中是 V 地址，word12 是 token-major
                                // context 内相邻 head 的字节偏移，word15 可选导出
                                // 64 个 attention 列和。所有形状约束由子核再次检查。
                                if (!descriptor[0][8+`LSME_FLAG_OUTPUT_INT8] ||
                                    !descriptor[0][8+`LSME_FLAG_HEAD4] ||
                                    descriptor[5] != 32'h00400040 ||
                                    descriptor[6] != 32'h00040008 ||
                                    descriptor[7] != 32'd8 ||
                                    descriptor[8] != 32'd8 ||
                                    descriptor[9] != 32'd32 ||
                                    descriptor[10] != 32'd512 ||
                                    descriptor[11] != 32'd512 ||
                                    descriptor[12] != 32'd8) begin
                                    error_code <= ERR_BAD_DIM;
                                    state <= ST_ERROR;
                                end
                                else begin
                                    schedule_mode <= `LSME_MODE_MACRO8;
                                    fused_attention_start <= 1'b1;
                                    state <= ST_FA_WAIT;
                                end
                            end
                            default: begin
                                error_code <= ERR_BAD_OP;
                                state <= ST_ERROR;
                            end
                        endcase
                    end
                end

                ST_G_INIT: begin
                    tile_k <= 16'd0;
                    a_k_addr <= m_src0_base;
                    b_k_addr <= tile_src1_base;
                    state <= flag_bias ? ST_G_BIAS : ST_G_ZERO;
                end

                ST_G_V2_WAIT: begin
                    if (v2_done) begin
                        if (v2_error != 0) begin
                            error_code <= v2_error;
                            state <= ST_ERROR;
                        end
                        else begin
                            perf_gemm_tiles <= perf_gemm_tiles +
                                               v2_tiles_completed;
                            state <= ST_FINISH;
                        end
                    end
                end

                ST_FA_WAIT: begin
                    if (fused_attention_done) begin
                        if (fused_attention_error != 0) begin
                            error_code <= fused_attention_error;
                            state <= ST_ERROR;
                        end
                        else begin
                            perf_gemm_tiles <= perf_gemm_tiles +
                                               fused_attention_macro_tiles;
                            perf_softmax_rows <= perf_softmax_rows +
                                                  fused_attention_softmax_rows;
                            perf_direct_mem_words <= perf_direct_mem_words +
                                                     fused_attention_memory_words;
                            state <= ST_FINISH;
                        end
                    end
                end

                ST_G_ZERO, ST_G_BIAS, ST_G_P0, ST_G_P1,
                ST_G_LDA, ST_G_LDB, ST_G_MOPA, ST_G_STORE: begin
                    if (core_req_ready) begin
                        case (state)
                            ST_G_ZERO:  after_core_state <= ST_G_P0;
                            ST_G_BIAS:  after_core_state <= ST_G_P0;
                            ST_G_P0:    after_core_state <= ST_G_P1;
                            ST_G_P1:    after_core_state <= ST_G_LDA;
                            ST_G_LDA:   after_core_state <= ST_G_LDB;
                            ST_G_LDB:   after_core_state <= ST_G_MOPA;
                            ST_G_MOPA:  after_core_state <= ST_G_K_ADV;
                            default:    after_core_state <= ST_G_ADV;
                        endcase
                        state <= ST_CORE_WAIT;
                    end
                end

                ST_CORE_WAIT: begin
                    if (core_rsp_valid) begin
                        if (core_rsp_rdata[7:0] != 0) begin
                            error_code <= ERR_CORE;
                            state <= ST_ERROR;
                        end
                        else
                            state <= after_core_state;
                    end
                end

                ST_G_K_ADV: begin
                    if (tile_k + 16'd4 >= k_dim)
                        state <= ST_G_STORE;
                    else begin
                        tile_k <= tile_k + 16'd4;
                        a_k_addr <= a_k_addr + 32'd4;
                        b_k_addr <= flag_trans_b
                            ? b_k_addr + 32'd4
                            : b_k_addr + (src1_row_stride << 2);
                        state <= ST_G_P0;
                    end
                end

                ST_G_ADV: begin
                    perf_gemm_tiles <= perf_gemm_tiles + 32'd1;
                    if (tile_n + 16'd4 < n_dim) begin
                        tile_n <= tile_n + 16'd4;
                        tile_src1_base <= flag_trans_b
                            ? tile_src1_base + (src1_row_stride << 2)
                            : tile_src1_base + 32'd4;
                        tile_dst_base <= tile_dst_base
                            + (flag_output_int8 ? 32'd4 : 32'd16);
                        tile_bias_base <= tile_bias_base + 32'd16;
                        state <= ST_G_INIT;
                    end
                    else if (tile_m + 16'd4 < m_dim) begin
                        tile_m <= tile_m + 16'd4;
                        tile_n <= 16'd0;
                        m_src0_base <= m_src0_base + (src0_row_stride << 2);
                        m_dst_base <= m_dst_base + (dst_row_stride << 2);
                        tile_src1_base <= batch_src1;
                        tile_dst_base <= m_dst_base + (dst_row_stride << 2);
                        tile_bias_base <= bias_addr;
                        state <= ST_G_INIT;
                    end
                    else if (batch_index + 16'd1 < batch_dim) begin
                        batch_index <= batch_index + 16'd1;
                        tile_m <= 16'd0;
                        tile_n <= 16'd0;
                        batch_src0 <= batch_src0 + src0_batch_stride;
                        batch_src1 <= batch_src1 + src1_batch_stride;
                        batch_dst <= batch_dst + dst_batch_stride;
                        m_src0_base <= batch_src0 + src0_batch_stride;
                        m_dst_base <= batch_dst + dst_batch_stride;
                        tile_src1_base <= batch_src1 + src1_batch_stride;
                        tile_dst_base <= batch_dst + dst_batch_stride;
                        tile_bias_base <= bias_addr;
                        state <= ST_G_INIT;
                    end
                    else
                        state <= ST_FINISH;
                end

                ST_SM_READ_REQ: begin
                    if (mem_req_ready)
                        state <= ST_SM_READ_WAIT;
                end

                ST_SM_READ_WAIT: begin
                    if (mem_rsp_valid) begin
                        if (mem_rsp_error) begin
                            error_code <= ERR_DATA_MEMORY;
                            state <= ST_ERROR;
                        end
                        else begin
                            softmax_input[softmax_index*32 +: 32] <= mem_rsp_rdata;
                            perf_direct_mem_words <= perf_direct_mem_words + 32'd1;
                            if ({9'd0, softmax_index} + 16'd1 >= n_dim)
                                state <= ST_SM_START;
                            else begin
                                softmax_index <= softmax_index + 7'd1;
                                state <= ST_SM_READ_REQ;
                            end
                        end
                    end
                end

                ST_SM_START: begin
                    softmax_start <= 1'b1;
                    state <= ST_SM_WAIT;
                end

                ST_SM_WAIT: begin
                    if (softmax_done) begin
                        softmax_word_index <= 5'd0;
                        state <= ST_SM_WRITE_REQ;
                    end
                end

                ST_SM_WRITE_REQ: begin
                    if (mem_req_ready)
                        state <= ST_SM_WRITE_WAIT;
                end

                ST_SM_WRITE_WAIT: begin
                    if (mem_rsp_valid) begin
                        if (mem_rsp_error) begin
                            error_code <= ERR_DATA_MEMORY;
                            state <= ST_ERROR;
                        end
                        else begin
                            perf_direct_mem_words <= perf_direct_mem_words + 32'd1;
                            if ({9'd0, softmax_word_index, 2'b00} + 16'd4 >= n_dim)
                                state <= ST_SM_ADV;
                            else begin
                                softmax_word_index <= softmax_word_index + 5'd1;
                                state <= ST_SM_WRITE_REQ;
                            end
                        end
                    end
                end

                ST_SM_ADV: begin
                    perf_softmax_rows <= perf_softmax_rows + 32'd1;
                    softmax_input <= 2048'd0;
                    softmax_index <= 7'd0;
                    if (row_index + 16'd1 < m_dim) begin
                        row_index <= row_index + 16'd1;
                        softmax_row_src <= softmax_row_src + src0_row_stride;
                        softmax_row_dst <= softmax_row_dst + dst_row_stride;
                        state <= ST_SM_READ_REQ;
                    end
                    else if (batch_index + 16'd1 < batch_dim) begin
                        batch_index <= batch_index + 16'd1;
                        row_index <= 16'd0;
                        batch_src0 <= batch_src0 + src0_batch_stride;
                        batch_dst <= batch_dst + dst_batch_stride;
                        softmax_row_src <= batch_src0 + src0_batch_stride;
                        softmax_row_dst <= batch_dst + dst_batch_stride;
                        state <= ST_SM_READ_REQ;
                    end
                    else
                        state <= ST_FINISH;
                end

                ST_VA_READ0_REQ: begin
                    if (mem_req_ready)
                        state <= ST_VA_READ0_WAIT;
                end

                ST_VA_READ0_WAIT: begin
                    if (mem_rsp_valid) begin
                        if (mem_rsp_error) begin
                            error_code <= ERR_DATA_MEMORY;
                            state <= ST_ERROR;
                        end
                        else begin
                            vadd_src0_word <= mem_rsp_rdata;
                            perf_direct_mem_words <= perf_direct_mem_words + 32'd1;
                            state <= ST_VA_READ1_REQ;
                        end
                    end
                end

                ST_VA_READ1_REQ: begin
                    if (mem_req_ready)
                        state <= ST_VA_READ1_WAIT;
                end

                ST_VA_READ1_WAIT: begin
                    if (mem_rsp_valid) begin
                        if (mem_rsp_error) begin
                            error_code <= ERR_DATA_MEMORY;
                            state <= ST_ERROR;
                        end
                        else begin
                            perf_direct_mem_words <= perf_direct_mem_words + 32'd1;
                            state <= ST_VA_WRITE_REQ;
                        end
                    end
                end

                ST_VA_WRITE_REQ: begin
                    if (mem_req_ready)
                        state <= ST_VA_WRITE_WAIT;
                end

                ST_VA_WRITE_WAIT: begin
                    if (mem_rsp_valid) begin
                        if (mem_rsp_error) begin
                            error_code <= ERR_DATA_MEMORY;
                            state <= ST_ERROR;
                        end
                        else begin
                            perf_direct_mem_words <= perf_direct_mem_words + 32'd1;
                            state <= ST_VA_ADV;
                        end
                    end
                end

                ST_VA_ADV: begin
                    if (vadd_word_index + 16'd1 < vadd_words_per_row) begin
                        vadd_word_index <= vadd_word_index + 16'd1;
                        state <= ST_VA_READ0_REQ;
                    end
                    else if (row_index + 16'd1 < m_dim) begin
                        row_index <= row_index + 16'd1;
                        vadd_word_index <= 16'd0;
                        vadd_row_src0 <= vadd_row_src0 + src0_row_stride;
                        vadd_row_src1 <= vadd_row_src1 + src1_row_stride;
                        vadd_row_dst <= vadd_row_dst + dst_row_stride;
                        state <= ST_VA_READ0_REQ;
                    end
                    else if (batch_index + 16'd1 < batch_dim) begin
                        batch_index <= batch_index + 16'd1;
                        row_index <= 16'd0;
                        vadd_word_index <= 16'd0;
                        batch_src0 <= batch_src0 + src0_batch_stride;
                        batch_src1 <= batch_src1 + src1_batch_stride;
                        batch_dst <= batch_dst + dst_batch_stride;
                        vadd_row_src0 <= batch_src0 + src0_batch_stride;
                        vadd_row_src1 <= batch_src1 + src1_batch_stride;
                        vadd_row_dst <= batch_dst + dst_batch_stride;
                        state <= ST_VA_READ0_REQ;
                    end
                    else
                        state <= ST_FINISH;
                end

                ST_FINISH: begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    perf_descriptor_count <= perf_descriptor_count + 32'd1;
                    perf_last_descriptor_cycles <= descriptor_cycle_counter;
                    state <= ST_IDLE;
                end

                ST_ERROR: begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    perf_last_descriptor_cycles <= descriptor_cycle_counter;
                    state <= ST_IDLE;
                end

                default: begin
                    error_code <= ERR_BAD_OP;
                    state <= ST_ERROR;
                end
            endcase
        end
    end

endmodule
