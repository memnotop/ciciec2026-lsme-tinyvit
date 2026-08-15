`timescale 1ns / 1ps

// LSME-128I 有符号 INT8 外积求和核心。
//
// 对每一个目标元素执行：
//   ZA[row][col] += sum(k=0..3,
//       pred_n[4*row+k] && pred_m[4*col+k]
//         ? zn[8*(4*row+k) +: 8] * zm[8*(4*col+k) +: 8]
//         : 0)
//
// MOPA_LANES 表示数据通路中并行实例化的 INT8 乘积数量，可取 16/32/64，
// 对应完成一次 4×4×4 更新需要 4/2/1 个算术周期。乘法器使用显式移位加法，
// 算术数据通路中不使用 Verilog 乘法运算符，因此不会推断 DSP48。
module lsme_mopa_core #(
    parameter integer MOPA_LANES = 64
) (
    input               clk,
    input               reset,
    input               start,
    input      [127:0]  zn,
    input      [127:0]  zm,
    input      [15:0]   pred_n,
    input      [15:0]   pred_m,
    input      [511:0]  za_in,
    output reg          busy,
    output reg          done,
    output reg [511:0]  za_out
);

    localparam integer K_PER_CYCLE = MOPA_LANES / 16;
    localparam integer STEP_COUNT  = 4 / K_PER_CYCLE;

    reg [1:0] step;
    reg signed [31:0] acc [0:15];

    integer i;
    integer row;
    integer col;
    integer lane;
    integer kval;
    reg signed [31:0] sum_next;
    reg signed [7:0] a_elem;
    reg signed [7:0] b_elem;

    function automatic signed [15:0] mul_s8_lut;
        input signed [7:0] lhs;
        input signed [7:0] rhs;
        reg [7:0] lhs_abs;
        reg [7:0] rhs_abs;
        reg [15:0] magnitude;
        integer bit_idx;
        begin
            lhs_abs = lhs[7] ? (~lhs + 8'd1) : lhs;
            rhs_abs = rhs[7] ? (~rhs + 8'd1) : rhs;
            magnitude = 16'd0;
            for (bit_idx = 0; bit_idx < 8; bit_idx = bit_idx + 1) begin
                if (rhs_abs[bit_idx])
                    magnitude = magnitude + ({8'd0, lhs_abs} << bit_idx);
            end
            mul_s8_lut = (lhs[7] ^ rhs[7]) ? -$signed(magnitude) : $signed(magnitude);
        end
    endfunction

    initial begin
        if ((MOPA_LANES != 16) && (MOPA_LANES != 32) && (MOPA_LANES != 64)) begin
            $error("MOPA_LANES must be 16, 32 or 64");
        end
    end

    always @(posedge clk) begin
        done <= 1'b0;

        if (reset) begin
            busy   <= 1'b0;
            done   <= 1'b0;
            step   <= 2'd0;
            za_out <= 512'd0;
            for (i = 0; i < 16; i = i + 1)
                acc[i] <= 32'sd0;
        end
        else if (start && !busy) begin
            busy <= 1'b1;
            step <= 2'd0;
            for (i = 0; i < 16; i = i + 1)
                acc[i] <= $signed(za_in[i*32 +: 32]);
        end
        else if (busy) begin
            for (row = 0; row < 4; row = row + 1) begin
                for (col = 0; col < 4; col = col + 1) begin
                    sum_next = acc[row*4+col];
                    for (lane = 0; lane < K_PER_CYCLE; lane = lane + 1) begin
                        kval = step*K_PER_CYCLE + lane;
                        a_elem = $signed(zn[(row*4+kval)*8 +: 8]);
                        b_elem = $signed(zm[(col*4+kval)*8 +: 8]);
                        if (pred_n[row*4+kval] && pred_m[col*4+kval])
                            sum_next = sum_next + mul_s8_lut(a_elem, b_elem);
                    end
                    acc[row*4+col] <= sum_next;
                    if (step == STEP_COUNT-1)
                        za_out[(row*4+col)*32 +: 32] <= sum_next;
                end
            end

            if (step == STEP_COUNT-1) begin
                busy <= 1'b0;
                done <= 1'b1;
                step <= 2'd0;
            end
            else begin
                step <= step + 2'd1;
            end
        end
    end

endmodule
