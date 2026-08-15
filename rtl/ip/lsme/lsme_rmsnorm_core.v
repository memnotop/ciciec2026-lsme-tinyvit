`timescale 1ns / 1ps

// SME 风格的流式 RMSNorm 引擎。
//
// 数据流分为五段：
//   1. 增益向量只装载一次，并常驻 512 位本地寄存器；
//   2. 输入行按 32 位字流入，同时完成四路 INT8 平方和归约；
//   3. 共享整数除法器和整数平方根单元求 RMS；
//   4. 逐元素执行 input*gain、定点缩放、精确除法和四舍五入；
//   5. 四个 INT8 结果合并为一个 32 位字后流式写回。
//
// 这种“流式输入 + 行级归约状态 + 向量写回”借鉴了 Arm SME 对 streaming
// mode 和二维累加状态的组织思想，但针对 TinyViT 的定点 RMSNorm 做了小型化。
module lsme_rmsnorm_core (
    input             clk,
    input             reset,
    input             start,
    output reg        busy,
    output reg        done,
    output reg [7:0]  error_code,

    input      [31:0] src_addr,
    input      [31:0] gain_addr,
    input      [31:0] dst_addr,
    input      [15:0] rows,
    input      [15:0] columns,
    input      [15:0] batch_count,
    input      [31:0] src_row_stride,
    input      [31:0] dst_row_stride,
    input      [31:0] src_batch_stride,
    input      [31:0] dst_batch_stride,
    input      [7:0]  token_frac,
    input      [7:0]  gain_frac,

    output reg        mem_req_valid,
    input             mem_req_ready,
    output reg        mem_req_write,
    output reg [31:0] mem_req_addr,
    output reg [31:0] mem_req_wdata,
    output reg [3:0]  mem_req_wstrb,
    input             mem_rsp_valid,
    input      [31:0] mem_rsp_rdata,
    input             mem_rsp_error,

    output reg [31:0] rows_completed,
    output reg [31:0] memory_words,
    output            compute_active,
    output            memory_stall
);

    localparam [4:0] ST_IDLE          = 5'd0;
    localparam [4:0] ST_GAIN_REQ      = 5'd1;
    localparam [4:0] ST_GAIN_WAIT     = 5'd2;
    localparam [4:0] ST_ROW_INIT      = 5'd3;
    localparam [4:0] ST_ROW_REQ       = 5'd4;
    localparam [4:0] ST_ROW_WAIT      = 5'd5;
    localparam [4:0] ST_MEAN_START    = 5'd6;
    localparam [4:0] ST_MEAN_WAIT     = 5'd7;
    localparam [4:0] ST_SQRT_START    = 5'd8;
    localparam [4:0] ST_SQRT_WAIT     = 5'd9;
    localparam [4:0] ST_ELEM_MUL      = 5'd10;
    localparam [4:0] ST_ELEM_SCALE    = 5'd11;
    localparam [4:0] ST_ELEM_DIV      = 5'd12;
    localparam [4:0] ST_ELEM_WAIT     = 5'd13;
    localparam [4:0] ST_WRITE_REQ     = 5'd14;
    localparam [4:0] ST_WRITE_WAIT    = 5'd15;
    localparam [4:0] ST_ROW_ADV       = 5'd16;
    localparam [4:0] ST_FINISH        = 5'd17;
    localparam [4:0] ST_ERROR         = 5'd18;

    localparam [7:0] ERR_NONE   = 8'h00;
    localparam [7:0] ERR_MEMORY = 8'h15;

    reg [4:0] state;
    reg [511:0] gain_vector;
    reg [511:0] input_row;
    reg [15:0] word_index;
    reg [15:0] words_per_row;
    reg [15:0] element_index;
    reg [15:0] row_index;
    reg [15:0] batch_index;
    reg [31:0] batch_src;
    reg [31:0] batch_dst;
    reg [31:0] row_src;
    reg [31:0] row_dst;
    reg [31:0] square_sum;
    reg [31:0] mean_square;
    reg [31:0] denominator;
    reg [31:0] output_word;
    // 小位宽乘法显式映射到 LUT，维持整个自主 IP 的 DSP48 使用量为 0。
    (* use_dsp = "no" *) reg signed [15:0] element_product;
    reg element_negative;
    reg [31:0] division_dividend;
    reg [31:0] division_divisor;

    reg divider_start;
    wire divider_busy;
    wire divider_done;
    wire [31:0] divider_quotient;
    wire [31:0] divider_remainder;
    reg sqrt_start;
    wire sqrt_busy;
    wire sqrt_done;
    wire [15:0] sqrt_root;

    integer lane;
    reg signed [8:0] square_value;
    (* use_dsp = "no" *) reg signed [17:0] square_product;
    reg [31:0] square_word_sum;

    // 当前收到的 32 位输入字包含四个 INT8 元素；组合计算其平方和，
    // 下一拍再写入 square_sum，缩短跨状态的组合路径。
    always @(*) begin
        square_word_sum = 32'd0;
        for (lane = 0; lane < 4; lane = lane + 1) begin
            square_value = $signed({mem_rsp_rdata[lane*8 + 7],
                                    mem_rsp_rdata[lane*8 +: 8]});
            square_product = square_value * square_value;
            if ({14'd0, word_index, 2'b00} + lane < {16'd0, columns})
                square_word_sum = square_word_sum + square_product;
        end
    end

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

    function automatic [7:0] rounded_s8;
        input [31:0] quotient;
        input [31:0] remainder;
        input [31:0] divisor;
        input negative;
        reg [32:0] rounded;
        reg signed [33:0] signed_value;
        begin
            rounded = {1'b0, quotient};
            if ({remainder, 1'b0} >= {1'b0, divisor})
                rounded = rounded + 33'd1;
            signed_value = negative ? -$signed({1'b0, rounded})
                                    :  $signed({1'b0, rounded});
            if (signed_value > 127)
                rounded_s8 = 8'h7f;
            else if (signed_value < -128)
                rounded_s8 = 8'h80;
            else
                rounded_s8 = signed_value[7:0];
        end
    endfunction

    lsme_udiv32 u_divider (
        .clk(clk), .reset(reset), .start(divider_start),
        .dividend(division_dividend), .divisor(division_divisor),
        .busy(divider_busy), .done(divider_done),
        .quotient(divider_quotient), .remainder(divider_remainder)
    );

    lsme_isqrt32 u_sqrt (
        .clk(clk), .reset(reset), .start(sqrt_start), .value(mean_square),
        .busy(sqrt_busy), .done(sqrt_done), .root(sqrt_root)
    );

    assign compute_active = divider_busy || sqrt_busy ||
                            state == ST_MEAN_START || state == ST_SQRT_START ||
                            state == ST_ELEM_MUL || state == ST_ELEM_SCALE ||
                            state == ST_ELEM_DIV;

    assign memory_stall = ((state == ST_GAIN_REQ || state == ST_ROW_REQ ||
                            state == ST_WRITE_REQ) && !mem_req_ready) ||
                          ((state == ST_GAIN_WAIT || state == ST_ROW_WAIT ||
                            state == ST_WRITE_WAIT) && !mem_rsp_valid);

    always @(*) begin
        mem_req_valid = 1'b0;
        mem_req_write = 1'b0;
        mem_req_addr = 32'd0;
        mem_req_wdata = 32'd0;
        mem_req_wstrb = 4'd0;

        case (state)
            ST_GAIN_REQ: begin
                mem_req_valid = 1'b1;
                mem_req_addr = gain_addr + {14'd0, word_index, 2'b00};
            end
            ST_ROW_REQ: begin
                mem_req_valid = 1'b1;
                mem_req_addr = row_src + {14'd0, word_index, 2'b00};
            end
            ST_WRITE_REQ: begin
                mem_req_valid = 1'b1;
                mem_req_write = 1'b1;
                mem_req_addr = row_dst + {16'd0, element_index[15:2], 2'b00};
                mem_req_wdata = output_word;
                mem_req_wstrb = tail_strobe(columns -
                    {element_index[15:2], 2'b00});
            end
            default: begin end
        endcase
    end

    always @(posedge clk) begin
        done <= 1'b0;
        divider_start <= 1'b0;
        sqrt_start <= 1'b0;

        if (reset) begin
            state <= ST_IDLE;
            busy <= 1'b0;
            done <= 1'b0;
            error_code <= ERR_NONE;
            gain_vector <= 512'd0;
            input_row <= 512'd0;
            word_index <= 16'd0;
            words_per_row <= 16'd0;
            element_index <= 16'd0;
            row_index <= 16'd0;
            batch_index <= 16'd0;
            batch_src <= 32'd0;
            batch_dst <= 32'd0;
            row_src <= 32'd0;
            row_dst <= 32'd0;
            square_sum <= 32'd0;
            mean_square <= 32'd0;
            denominator <= 32'd1;
            output_word <= 32'd0;
            element_product <= 16'sd0;
            element_negative <= 1'b0;
            division_dividend <= 32'd0;
            division_divisor <= 32'd1;
            divider_start <= 1'b0;
            sqrt_start <= 1'b0;
            rows_completed <= 32'd0;
            memory_words <= 32'd0;
        end
        else begin
            case (state)
                ST_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        busy <= 1'b1;
                        error_code <= ERR_NONE;
                        gain_vector <= 512'd0;
                        input_row <= 512'd0;
                        word_index <= 16'd0;
                        words_per_row <= (columns + 16'd3) >> 2;
                        row_index <= 16'd0;
                        batch_index <= 16'd0;
                        batch_src <= src_addr;
                        batch_dst <= dst_addr;
                        row_src <= src_addr;
                        row_dst <= dst_addr;
                        rows_completed <= 32'd0;
                        memory_words <= 32'd0;
                        state <= ST_GAIN_REQ;
                    end
                end

                ST_GAIN_REQ: begin
                    if (mem_req_ready)
                        state <= ST_GAIN_WAIT;
                end

                ST_GAIN_WAIT: begin
                    if (mem_rsp_valid) begin
                        if (mem_rsp_error) begin
                            error_code <= ERR_MEMORY;
                            state <= ST_ERROR;
                        end
                        else begin
                            gain_vector[word_index*32 +: 32] <= mem_rsp_rdata;
                            memory_words <= memory_words + 32'd1;
                            if (word_index + 16'd1 >= words_per_row) begin
                                word_index <= 16'd0;
                                state <= ST_ROW_INIT;
                            end
                            else begin
                                word_index <= word_index + 16'd1;
                                state <= ST_GAIN_REQ;
                            end
                        end
                    end
                end

                ST_ROW_INIT: begin
                    input_row <= 512'd0;
                    square_sum <= 32'd0;
                    word_index <= 16'd0;
                    state <= ST_ROW_REQ;
                end

                ST_ROW_REQ: begin
                    if (mem_req_ready)
                        state <= ST_ROW_WAIT;
                end

                ST_ROW_WAIT: begin
                    if (mem_rsp_valid) begin
                        if (mem_rsp_error) begin
                            error_code <= ERR_MEMORY;
                            state <= ST_ERROR;
                        end
                        else begin
                            input_row[word_index*32 +: 32] <= mem_rsp_rdata;
                            square_sum <= square_sum + square_word_sum;
                            memory_words <= memory_words + 32'd1;
                            if (word_index + 16'd1 >= words_per_row) begin
                                division_dividend <= square_sum + square_word_sum;
                                division_divisor <= {16'd0, columns};
                                state <= ST_MEAN_START;
                            end
                            else begin
                                word_index <= word_index + 16'd1;
                                state <= ST_ROW_REQ;
                            end
                        end
                    end
                end

                ST_MEAN_START: begin
                    divider_start <= 1'b1;
                    state <= ST_MEAN_WAIT;
                end

                ST_MEAN_WAIT: begin
                    if (divider_done) begin
                        mean_square <= divider_quotient;
                        state <= ST_SQRT_START;
                    end
                end

                ST_SQRT_START: begin
                    sqrt_start <= 1'b1;
                    state <= ST_SQRT_WAIT;
                end

                ST_SQRT_WAIT: begin
                    if (sqrt_done) begin
                        denominator <= ((sqrt_root == 0 ? 32'd1
                                                       : {16'd0, sqrt_root})
                                        << gain_frac);
                        element_index <= 16'd0;
                        output_word <= 32'd0;
                        state <= ST_ELEM_MUL;
                    end
                end

                ST_ELEM_MUL: begin
                    element_product <=
                        $signed(input_row[element_index*8 +: 8]) *
                        $signed(gain_vector[element_index*8 +: 8]);
                    state <= ST_ELEM_SCALE;
                end

                ST_ELEM_SCALE: begin
                    element_negative <= element_product < 0;
                    if (element_product < 0)
                        division_dividend <= -(
                            $signed({{16{element_product[15]}}, element_product})
                            <<< token_frac);
                    else
                        division_dividend <=
                            $signed({{16{element_product[15]}}, element_product})
                            <<< token_frac;
                    division_divisor <= denominator;
                    state <= ST_ELEM_DIV;
                end

                ST_ELEM_DIV: begin
                    divider_start <= 1'b1;
                    state <= ST_ELEM_WAIT;
                end

                ST_ELEM_WAIT: begin
                    if (divider_done) begin
                        output_word[element_index[1:0]*8 +: 8] <= rounded_s8(
                            divider_quotient, divider_remainder,
                            denominator, element_negative);
                        if (element_index[1:0] == 2'd3 ||
                            element_index + 16'd1 >= columns)
                            state <= ST_WRITE_REQ;
                        else begin
                            element_index <= element_index + 16'd1;
                            state <= ST_ELEM_MUL;
                        end
                    end
                end

                ST_WRITE_REQ: begin
                    if (mem_req_ready)
                        state <= ST_WRITE_WAIT;
                end

                ST_WRITE_WAIT: begin
                    if (mem_rsp_valid) begin
                        if (mem_rsp_error) begin
                            error_code <= ERR_MEMORY;
                            state <= ST_ERROR;
                        end
                        else begin
                            memory_words <= memory_words + 32'd1;
                            if (element_index + 16'd1 >= columns)
                                state <= ST_ROW_ADV;
                            else begin
                                element_index <= element_index + 16'd1;
                                output_word <= 32'd0;
                                state <= ST_ELEM_MUL;
                            end
                        end
                    end
                end

                ST_ROW_ADV: begin
                    rows_completed <= rows_completed + 32'd1;
                    if (row_index + 16'd1 < rows) begin
                        row_index <= row_index + 16'd1;
                        row_src <= row_src + src_row_stride;
                        row_dst <= row_dst + dst_row_stride;
                        state <= ST_ROW_INIT;
                    end
                    else if (batch_index + 16'd1 < batch_count) begin
                        batch_index <= batch_index + 16'd1;
                        row_index <= 16'd0;
                        batch_src <= batch_src + src_batch_stride;
                        batch_dst <= batch_dst + dst_batch_stride;
                        row_src <= batch_src + src_batch_stride;
                        row_dst <= batch_dst + dst_batch_stride;
                        state <= ST_ROW_INIT;
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

                default: state <= ST_ERROR;
            endcase
        end
    end

endmodule
