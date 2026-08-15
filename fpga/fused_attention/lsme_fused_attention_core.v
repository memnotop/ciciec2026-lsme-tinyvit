`timescale 1ns / 1ps

// 固定形状的融合 Attention 引擎。
//
// 该单元实现 TinyViT 中一整个 head 的 QK^T -> Softmax -> PV 链：
//   * Q、K、V 从外部内存各读取一次，随后在片上复用；
//   * QK 的 S32 score 和 Q7 probability 均不写回外部内存；
//   * 两个矩阵乘阶段都通过现有的 8x8 x 4 MOPA 宏端口执行；
//   * 最终直接按 token-major 布局写 context，消除软件 merge_heads；
//   * 对每个 key 累加 probability 的列和，仅导出 64 个 U32，供 DVI 热图使用。
//
// 此版本故意只接受 M=N=64、K=8、head=4。固定形状让片上存储、时序和
// 演示口径都可控，也避免把尚未验证的通用调度器混入实板启动链。
module lsme_fused_attention_core (
    input               clk,
    input               reset,
    input               start,
    output reg          busy,
    output reg          done,
    output reg [7:0]    error_code,

    input      [31:0]   q_addr,
    input      [31:0]   k_addr,
    input      [31:0]   v_addr,
    input      [31:0]   context_addr,
    input      [31:0]   attention_sum_addr,
    input      [31:0]   q_row_stride,
    input      [31:0]   kv_row_stride,
    input      [31:0]   context_row_stride,
    input      [31:0]   q_head_stride,
    input      [31:0]   kv_head_stride,
    input      [31:0]   context_head_offset,
    input      [15:0]   query_count,
    input      [15:0]   key_count,
    input      [15:0]   head_dim,
    input      [15:0]   head_count,
    input      [4:0]    score_shift,
    input      [4:0]    output_shift,

    output reg          mem_req_valid,
    input               mem_req_ready,
    output reg          mem_req_write,
    output reg [31:0]   mem_req_addr,
    output reg [31:0]   mem_req_wdata,
    output reg [3:0]    mem_req_wstrb,
    input               mem_rsp_valid,
    input      [31:0]   mem_rsp_rdata,
    input               mem_rsp_error,

    output reg          macro_start,
    input               macro_ready,
    output reg          macro_first,
    output reg [127:0]  macro_a_top,
    output reg [127:0]  macro_a_bottom,
    output reg [127:0]  macro_b_left,
    output reg [127:0]  macro_b_right,
    output reg [15:0]   macro_pred_a_top,
    output reg [15:0]   macro_pred_a_bottom,
    output reg [15:0]   macro_pred_b_left,
    output reg [15:0]   macro_pred_b_right,
    output reg [2047:0] macro_za_init,
    input               macro_busy,
    input               macro_done,
    input      [2047:0] macro_za_out,

    output reg [31:0]   macro_tiles_completed,
    output reg [31:0]   softmax_rows_completed,
    output reg [31:0]   memory_words,
    output              compute_active,
    output              memory_stall
);

    localparam [7:0] ERR_NONE       = 8'h00;
    localparam [7:0] ERR_BAD_DIM    = 8'h12;
    localparam [7:0] ERR_DATA_MEMORY = 8'h15;

    localparam [4:0] ST_IDLE         = 5'd0;
    localparam [4:0] ST_VALIDATE     = 5'd1;
    localparam [4:0] ST_LOAD_REQ     = 5'd2;
    localparam [4:0] ST_LOAD_WAIT    = 5'd3;
    localparam [4:0] ST_QK_SETUP     = 5'd4;
    localparam [4:0] ST_QK_ISSUE     = 5'd5;
    localparam [4:0] ST_QK_WAIT      = 5'd6;
    localparam [4:0] ST_SM_LOAD      = 5'd7;
    localparam [4:0] ST_SM_START     = 5'd8;
    localparam [4:0] ST_SM_WAIT      = 5'd9;
    localparam [4:0] ST_PV_SETUP     = 5'd10;
    localparam [4:0] ST_PV_ISSUE     = 5'd11;
    localparam [4:0] ST_PV_WAIT      = 5'd12;
    localparam [4:0] ST_STORE_PREP   = 5'd13;
    localparam [4:0] ST_STORE_LOAD   = 5'd14;
    localparam [4:0] ST_STORE_REQ    = 5'd15;
    localparam [4:0] ST_STORE_WAIT   = 5'd16;
    localparam [4:0] ST_HEAD_ADV     = 5'd17;
    localparam [4:0] ST_SUM_REQ      = 5'd18;
    localparam [4:0] ST_SUM_WAIT     = 5'd19;
    localparam [4:0] ST_FINISH       = 5'd20;
    localparam [4:0] ST_ERROR        = 5'd21;
    // 将一个 8x8 MOPA 输出串行写进 score SRAM，避免综合成 8 条 2048 位寄存器。
    localparam [4:0] ST_SCORE_STORE  = 5'd22;

    localparam [1:0] LOAD_Q = 2'd0;
    localparam [1:0] LOAD_K = 2'd1;
    localparam [1:0] LOAD_V = 2'd2;

    reg [4:0] state;
    reg [1:0] load_kind;
    reg [6:0] load_index;
    reg [2:0] head_index;
    reg [2:0] query_block;
    reg [2:0] key_block;
    reg       k_part;
    reg [2:0] softmax_row;
    reg [3:0] context_word;
    reg [5:0] summary_index;
    reg [5:0] score_index;
    reg [31:0] context_write_word;

    // 一个 head 的 Q、K、V 各为 64 x 8 字节，即 128 个 32 位字。
    (* ram_style = "block" *) reg [31:0] q_memory [0:127];
    (* ram_style = "block" *) reg [31:0] k_memory [0:127];
    (* ram_style = "block" *) reg [31:0] v_memory [0:127];

    // 当前 8 个 query 的 8x64 个 S32 score。旧实现使用 8 条 2048 位向量，
    // 动态切片写会被综合为大规模触发器和选择网络。这里改为单端口 512x32
    // 存储：MOPA 结果顺序写入，Softmax 启动前顺序读出，便于映射为 LUTRAM。
    (* ram_style = "distributed" *) reg [31:0] score_memory [0:511];

    // PV 宏每拍需要同时读取 8 行概率，因此保留按行并行的紧凑 Q7 缓冲。
    (* ram_style = "distributed" *) reg [511:0] probability_row [0:7];
    reg [15:0] attention_sum [0:63];

    reg          softmax_start;
    wire         softmax_busy;
    wire         softmax_done;
    wire         softmax_stream_valid;
    wire [5:0]   softmax_score_index;
    wire [5:0]   softmax_stream_index;
    wire [7:0]   softmax_stream_data;
    wire signed [31:0] softmax_score_data =
        $signed(score_memory[{softmax_row, softmax_score_index}]);

    integer i;
    // 不同 always 块不能复用同一个模块级循环变量，否则仿真和综合都会引入
    // 隐式竞争。宏装载、量化打包和 score 写入各自使用独立索引。
    integer macro_row;
    integer macro_col;
    integer macro_lane;
    integer pack_lane;
    reg [31:0] packed_context_word;

    function automatic signed [31:0] za_element;
        input [3:0] row_index;
        input [3:0] col_index;
        integer quadrant;
        integer element_index;
        begin
            quadrant = (row_index >= 4 ? 2 : 0) +
                       (col_index >= 4 ? 1 : 0);
            element_index = (row_index & 3) * 4 + (col_index & 3);
            za_element = $signed(macro_za_out[
                quadrant * 512 + element_index * 32 +: 32]);
        end
    endfunction

    // 与 lsme_gemm_v2 完全相同的有符号量化和半远离零舍入规则，保证
    // 融合 PV 输出与原来的 GEMM + merge_heads 路径逐字节一致。
    function automatic signed [7:0] requant_s8;
        input signed [31:0] value;
        input [4:0] shift;
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
            if (shifted > 127)
                requant_s8 = 8'sd127;
            else if (shifted < -128)
                requant_s8 = -8'sd128;
            else
                requant_s8 = shifted[7:0];
        end
    endfunction

    assign compute_active = state == ST_QK_ISSUE || state == ST_QK_WAIT ||
                            state == ST_SM_LOAD || state == ST_SM_START ||
                            state == ST_SM_WAIT || state == ST_PV_ISSUE ||
                            state == ST_PV_WAIT;
    assign memory_stall = state == ST_LOAD_REQ || state == ST_LOAD_WAIT ||
                          state == ST_STORE_REQ || state == ST_STORE_WAIT ||
                          state == ST_SUM_REQ || state == ST_SUM_WAIT;

    // 直接从 score SRAM 逐元素读取。该三遍扫描 Softmax 保持原 max/exp/
    // 归一化定点算法和舍入规则，同时删除 2048 位 row_in 总线及动态位选。
    lsme_softmax_score_sram u_softmax (
        .clk(clk), .reset(reset), .start(softmax_start),
        .count(7'd64), .score_shift(score_shift), .score_data(softmax_score_data),
        .busy(softmax_busy), .done(softmax_done),
        .stream_valid(softmax_stream_valid),
        .score_index(softmax_score_index), .stream_index(softmax_stream_index),
        .stream_data(softmax_stream_data)
    );

    always @(*) begin
        mem_req_valid = 1'b0;
        mem_req_write = 1'b0;
        mem_req_addr = 32'd0;
        mem_req_wdata = 32'd0;
        mem_req_wstrb = 4'b1111;

        if (state == ST_LOAD_REQ) begin
            mem_req_valid = 1'b1;
            case (load_kind)
                LOAD_Q: mem_req_addr = q_addr + head_index * q_head_stride +
                                       {load_index, 2'b00};
                LOAD_K: mem_req_addr = k_addr + head_index * kv_head_stride +
                                       {load_index, 2'b00};
                default: mem_req_addr = v_addr + head_index * kv_head_stride +
                                        {load_index, 2'b00};
            endcase
        end
        else if (state == ST_STORE_REQ) begin
            mem_req_valid = 1'b1;
            mem_req_write = 1'b1;
            mem_req_addr = context_addr +
                           ((query_block * 8 + (context_word >> 1)) *
                            context_row_stride) +
                           head_index * context_head_offset +
                           ((context_word & 1) << 2);
            mem_req_wdata = context_write_word;
        end
        else if (state == ST_SUM_REQ) begin
            mem_req_valid = 1'b1;
            mem_req_write = 1'b1;
            mem_req_addr = attention_sum_addr + {summary_index, 2'b00};
            mem_req_wdata = {16'd0, attention_sum[summary_index]};
        end
    end

    // MOPA 输入在宏请求存续期间保持稳定。QK 阶段把 K 的行主序数据按
    // 宏端口所需的列主序排布；PV 阶段则将 V 做同样的 4x4 局部转置。
    always @(*) begin
        macro_start = 1'b0;
        macro_first = 1'b0;
        macro_a_top = 128'd0;
        macro_a_bottom = 128'd0;
        macro_b_left = 128'd0;
        macro_b_right = 128'd0;
        macro_pred_a_top = 16'hffff;
        macro_pred_a_bottom = 16'hffff;
        macro_pred_b_left = 16'hffff;
        macro_pred_b_right = 16'hffff;
        macro_za_init = 2048'd0;

        if (state == ST_QK_ISSUE) begin
            macro_start = 1'b1;
            macro_first = !k_part;
            for (macro_row = 0; macro_row < 4; macro_row = macro_row + 1) begin
                macro_a_top[macro_row * 32 +: 32] =
                    q_memory[((query_block * 8 + macro_row) * 2) + k_part];
                macro_a_bottom[macro_row * 32 +: 32] =
                    q_memory[((query_block * 8 + macro_row + 4) * 2) + k_part];
                macro_b_left[macro_row * 32 +: 32] =
                    k_memory[((key_block * 8 + macro_row) * 2) + k_part];
                macro_b_right[macro_row * 32 +: 32] =
                    k_memory[((key_block * 8 + macro_row + 4) * 2) + k_part];
            end
        end
        else if (state == ST_PV_ISSUE) begin
            macro_start = 1'b1;
            macro_first = (key_block == 0) && !k_part;
            for (macro_row = 0; macro_row < 4; macro_row = macro_row + 1) begin
                macro_a_top[macro_row * 32 +: 32] = probability_row[macro_row][
                    ((key_block * 8 + k_part * 4) * 8) +: 32];
                macro_a_bottom[macro_row * 32 +: 32] = probability_row[macro_row + 4][
                    ((key_block * 8 + k_part * 4) * 8) +: 32];
            end
            for (macro_lane = 0; macro_lane < 4; macro_lane = macro_lane + 1) begin
                for (macro_col = 0; macro_col < 4; macro_col = macro_col + 1) begin
                    macro_b_left[(macro_col * 4 + macro_lane) * 8 +: 8] =
                        v_memory[((key_block * 8 + k_part * 4 + macro_lane) * 2)]
                                [macro_col * 8 +: 8];
                    macro_b_right[(macro_col * 4 + macro_lane) * 8 +: 8] =
                        v_memory[((key_block * 8 + k_part * 4 + macro_lane) * 2 + 1)]
                                [macro_col * 8 +: 8];
                end
            end
        end
    end

    // za_element 是函数调用；为兼容 Icarus/XSim 对函数内部敏感信号的处理，
    // 显式列出 macro_za_out，避免最后一次 MOPA 后首个打包字保留旧值。
    always @(macro_za_out or context_word or output_shift) begin
        packed_context_word = 32'd0;
        for (pack_lane = 0; pack_lane < 4; pack_lane = pack_lane + 1)
            packed_context_word[pack_lane * 8 +: 8] = requant_s8(
                za_element(context_word >> 1, (context_word[0] * 4) + pack_lane),
                output_shift);
    end

    always @(posedge clk) begin
        done <= 1'b0;
        softmax_start <= 1'b0;

        if (reset) begin
            state <= ST_IDLE;
            busy <= 1'b0;
            done <= 1'b0;
            error_code <= ERR_NONE;
            load_kind <= LOAD_Q;
            load_index <= 7'd0;
            head_index <= 3'd0;
            query_block <= 3'd0;
            key_block <= 3'd0;
            k_part <= 1'b0;
            softmax_row <= 3'd0;
            context_word <= 4'd0;
            summary_index <= 6'd0;
            score_index <= 6'd0;
            context_write_word <= 32'd0;
            macro_tiles_completed <= 32'd0;
            softmax_rows_completed <= 32'd0;
            memory_words <= 32'd0;
            for (i = 0; i < 64; i = i + 1)
                attention_sum[i] <= 16'd0;
        end
        else begin
            case (state)
                ST_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        busy <= 1'b1;
                        error_code <= ERR_NONE;
                        macro_tiles_completed <= 32'd0;
                        softmax_rows_completed <= 32'd0;
                        memory_words <= 32'd0;
                        state <= ST_VALIDATE;
                    end
                end

                ST_VALIDATE: begin
                    if (query_count != 64 || key_count != 64 ||
                        head_dim != 8 || head_count != 4 ||
                        q_row_stride != 8 || kv_row_stride != 8 ||
                        context_row_stride != 32 || q_head_stride != 512 ||
                        kv_head_stride != 512 || context_head_offset != 8 ||
                        score_shift > 31 || output_shift > 31) begin
                        error_code <= ERR_BAD_DIM;
                        state <= ST_ERROR;
                    end
                    else begin
                        head_index <= 3'd0;
                        load_kind <= LOAD_Q;
                        load_index <= 7'd0;
                        query_block <= 3'd0;
                        key_block <= 3'd0;
                        k_part <= 1'b0;
                        score_index <= 6'd0;
                        for (i = 0; i < 64; i = i + 1)
                            attention_sum[i] <= 16'd0;
                        state <= ST_LOAD_REQ;
                    end
                end

                ST_LOAD_REQ: begin
                    if (mem_req_ready)
                        state <= ST_LOAD_WAIT;
                end

                ST_LOAD_WAIT: begin
                    if (mem_rsp_valid) begin
                        if (mem_rsp_error) begin
                            error_code <= ERR_DATA_MEMORY;
                            state <= ST_ERROR;
                        end
                        else begin
                            case (load_kind)
                                LOAD_Q: q_memory[load_index] <= mem_rsp_rdata;
                                LOAD_K: k_memory[load_index] <= mem_rsp_rdata;
                                default: v_memory[load_index] <= mem_rsp_rdata;
                            endcase
                            memory_words <= memory_words + 32'd1;
                            if (load_index == 7'd127) begin
                                load_index <= 7'd0;
                                if (load_kind == LOAD_Q) begin
                                    load_kind <= LOAD_K;
                                    state <= ST_LOAD_REQ;
                                end
                                else if (load_kind == LOAD_K) begin
                                    load_kind <= LOAD_V;
                                    state <= ST_LOAD_REQ;
                                end
                                else begin
                                    query_block <= 3'd0;
                                    key_block <= 3'd0;
                                    k_part <= 1'b0;
                                    state <= ST_QK_SETUP;
                                end
                            end
                            else begin
                                load_index <= load_index + 7'd1;
                                state <= ST_LOAD_REQ;
                            end
                        end
                    end
                end

                ST_QK_SETUP: begin
                    key_block <= 3'd0;
                    k_part <= 1'b0;
                    state <= ST_QK_ISSUE;
                end

                ST_QK_ISSUE: begin
                    if (macro_ready)
                        state <= ST_QK_WAIT;
                end

                ST_QK_WAIT: begin
                    if (macro_done) begin
                        macro_tiles_completed <= macro_tiles_completed + 32'd1;
                        if (!k_part) begin
                            k_part <= 1'b1;
                            state <= ST_QK_ISSUE;
                        end
                        else begin
                            // macro_za_out 在下一次 macro_start 前保持稳定，可在
                            // 64 个短周期内无损写入 score SRAM。
                            score_index <= 6'd0;
                            state <= ST_SCORE_STORE;
                        end
                    end
                end

                ST_SCORE_STORE: begin
                    score_memory[{score_index[5:3], key_block, score_index[2:0]}]
                        <= za_element(score_index[5:3], score_index[2:0]);
                    if (score_index == 6'd63) begin
                        if (key_block == 3'd7) begin
                            softmax_row <= 3'd0;
                            state <= ST_SM_START;
                        end
                        else begin
                            key_block <= key_block + 3'd1;
                            k_part <= 1'b0;
                            state <= ST_QK_ISSUE;
                        end
                    end
                    else
                        score_index <= score_index + 6'd1;
                end

                ST_SM_LOAD: begin
                    // 兼容旧状态编码。新 Softmax 直接读取 score SRAM，不再需要
                    // 先把整行复制到 2048 位输入寄存器。
                    state <= ST_SM_START;
                end

                ST_SM_START: begin
                    softmax_start <= 1'b1;
                    state <= ST_SM_WAIT;
                end

                ST_SM_WAIT: begin
                    if (softmax_stream_valid) begin
                        probability_row[softmax_row][softmax_stream_index * 8 +: 8]
                            <= softmax_stream_data;
                        attention_sum[softmax_stream_index]
                            <= attention_sum[softmax_stream_index]
                             + {8'd0, softmax_stream_data};
                    end
                    if (softmax_done) begin
                        softmax_rows_completed <= softmax_rows_completed + 32'd1;
                        if (softmax_row == 3'd7) begin
                            key_block <= 3'd0;
                            k_part <= 1'b0;
                            state <= ST_PV_SETUP;
                        end
                        else begin
                            softmax_row <= softmax_row + 3'd1;
                            state <= ST_SM_START;
                        end
                    end
                end

                ST_PV_SETUP: begin
                    key_block <= 3'd0;
                    k_part <= 1'b0;
                    state <= ST_PV_ISSUE;
                end

                ST_PV_ISSUE: begin
                    if (macro_ready)
                        state <= ST_PV_WAIT;
                end

                ST_PV_WAIT: begin
                    if (macro_done) begin
                        macro_tiles_completed <= macro_tiles_completed + 32'd1;
                        if (!k_part) begin
                            k_part <= 1'b1;
                            state <= ST_PV_ISSUE;
                        end
                        else if (key_block != 3'd7) begin
                            key_block <= key_block + 3'd1;
                            k_part <= 1'b0;
                            state <= ST_PV_ISSUE;
                        end
                        else begin
                            context_word <= 4'd0;
                            // macro_done 与 ZA 更新在同一个时钟沿发生。先等待
                            // 一个准备拍，保证第一个 32 位 context 字不读取旧 ZA。
                            state <= ST_STORE_PREP;
                        end
                    end
                end

                // 将组合量化结果先寄存，再进入 AXI 请求状态。这样首个字的
                // 数据与最后一次 macro 写 ZA 的时序边界完全解耦。
                ST_STORE_PREP: state <= ST_STORE_LOAD;

                ST_STORE_LOAD: begin
                    context_write_word <= packed_context_word;
                    state <= ST_STORE_REQ;
                end

                ST_STORE_REQ: begin
                    if (mem_req_ready)
                        state <= ST_STORE_WAIT;
                end

                ST_STORE_WAIT: begin
                    if (mem_rsp_valid) begin
                        if (mem_rsp_error) begin
                            error_code <= ERR_DATA_MEMORY;
                            state <= ST_ERROR;
                        end
                        else begin
                            memory_words <= memory_words + 32'd1;
                            if (context_word == 4'd15) begin
                                state <= ST_HEAD_ADV;
                            end
                            else begin
                                context_word <= context_word + 4'd1;
                                state <= ST_STORE_LOAD;
                            end
                        end
                    end
                end

                ST_HEAD_ADV: begin
                    if (query_block == 3'd7) begin
                        if (head_index == 3'd3) begin
                            summary_index <= 6'd0;
                            state <= attention_sum_addr == 0 ? ST_FINISH : ST_SUM_REQ;
                        end
                        else begin
                            head_index <= head_index + 3'd1;
                            load_kind <= LOAD_Q;
                            load_index <= 7'd0;
                            query_block <= 3'd0;
                            state <= ST_LOAD_REQ;
                        end
                    end
                    else begin
                        query_block <= query_block + 3'd1;
                        key_block <= 3'd0;
                        k_part <= 1'b0;
                        state <= ST_QK_SETUP;
                    end
                end

                ST_SUM_REQ: begin
                    if (mem_req_ready)
                        state <= ST_SUM_WAIT;
                end

                ST_SUM_WAIT: begin
                    if (mem_rsp_valid) begin
                        if (mem_rsp_error) begin
                            error_code <= ERR_DATA_MEMORY;
                            state <= ST_ERROR;
                        end
                        else begin
                            memory_words <= memory_words + 32'd1;
                            if (summary_index == 6'd63)
                                state <= ST_FINISH;
                            else begin
                                summary_index <= summary_index + 6'd1;
                                state <= ST_SUM_REQ;
                            end
                        end
                    end
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

                default: state <= ST_ERROR;
            endcase
        end
    end
endmodule
