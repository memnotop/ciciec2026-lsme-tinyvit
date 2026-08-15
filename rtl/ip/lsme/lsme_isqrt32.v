`timescale 1ns / 1ps

// 32 位无符号整数平方根，返回 floor(sqrt(value))。
// 算法与软件参考实现等价，每拍处理一个二进制“二位组”，不使用浮点数。
module lsme_isqrt32 (
    input             clk,
    input             reset,
    input             start,
    input      [31:0] value,
    output reg        busy,
    output reg        done,
    output reg [15:0] root
);

    reg [31:0] operand;
    reg [31:0] result;
    reg [31:0] trial_bit;
    reg normalizing;

    always @(posedge clk) begin
        done <= 1'b0;

        if (reset) begin
            busy <= 1'b0;
            done <= 1'b0;
            root <= 16'd0;
            operand <= 32'd0;
            result <= 32'd0;
            trial_bit <= 32'd0;
            normalizing <= 1'b0;
        end
        else if (start && !busy) begin
            operand <= value;
            result <= 32'd0;
            trial_bit <= 32'h4000_0000;
            normalizing <= 1'b1;
            busy <= 1'b1;
        end
        else if (busy) begin
            // 第一阶段只负责找到不大于 operand 的最高 4^n 位。
            // 找到以后必须退出该阶段；正式求根阶段即使 trial_bit 大于
            // 剩余 operand，也仍要执行 result>>1，不能再次当作规格化跳过。
            if (normalizing) begin
                if (trial_bit > operand)
                    trial_bit <= trial_bit >> 2;
                else
                    normalizing <= 1'b0;
            end
            else if (trial_bit == 0) begin
                root <= result[15:0];
                busy <= 1'b0;
                done <= 1'b1;
            end
            else begin
                if (operand >= result + trial_bit) begin
                    operand <= operand - result - trial_bit;
                    result <= (result >> 1) + trial_bit;
                end
                else
                    result <= result >> 1;
                trial_bit <= trial_bit >> 2;
            end
        end
    end

endmodule
