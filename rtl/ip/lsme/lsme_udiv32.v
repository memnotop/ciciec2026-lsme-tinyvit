`timescale 1ns / 1ps

// 32 位无符号恢复除法器。
//
// 设计目的：RMSNorm 同时需要“平方和/列数”和“幅值/归一化分母”。
// 两类运算复用一个逐位迭代单元，固定迭代 32 拍，避免综合出面积大、
// 组合路径长的通用除法器，从而降低 FPGA 布局布线与时序收敛难度。
module lsme_udiv32 (
    input             clk,
    input             reset,
    input             start,
    input      [31:0] dividend,
    input      [31:0] divisor,
    output reg        busy,
    output reg        done,
    output reg [31:0] quotient,
    output reg [31:0] remainder
);

    reg [31:0] dividend_hold;
    reg [31:0] divisor_hold;
    reg [4:0] bit_index;
    reg [32:0] shifted_remainder;

    always @(*)
        shifted_remainder = {remainder, dividend_hold[bit_index]};

    always @(posedge clk) begin
        done <= 1'b0;

        if (reset) begin
            busy <= 1'b0;
            done <= 1'b0;
            quotient <= 32'd0;
            remainder <= 32'd0;
            dividend_hold <= 32'd0;
            divisor_hold <= 32'd0;
            bit_index <= 5'd0;
        end
        else if (start && !busy) begin
            dividend_hold <= dividend;
            divisor_hold <= divisor;
            quotient <= 32'd0;
            remainder <= 32'd0;
            bit_index <= 5'd31;
            busy <= 1'b1;

            // 上层已经排除除数为 0；此保护使模块独立使用时也不会挂死。
            if (divisor == 0) begin
                quotient <= 32'hffff_ffff;
                remainder <= dividend;
                busy <= 1'b0;
                done <= 1'b1;
            end
        end
        else if (busy) begin
            if (shifted_remainder >= {1'b0, divisor_hold}) begin
                remainder <= shifted_remainder[31:0] - divisor_hold;
                quotient[bit_index] <= 1'b1;
            end
            else
                remainder <= shifted_remainder[31:0];

            if (bit_index == 0) begin
                busy <= 1'b0;
                done <= 1'b1;
            end
            else
                bit_index <= bit_index - 5'd1;
        end
    end

endmodule
