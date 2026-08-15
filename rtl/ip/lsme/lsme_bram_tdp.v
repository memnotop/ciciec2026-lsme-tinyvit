`timescale 1ns / 1ps

// 面向推理的小型真双口 Block RAM 封装。两个端口都是同步读、写优先。
// 显式封装存储器可以让 Vivado 稳定地把 V2 操作数缓存推断为 BRAM，
// 并避免在 MOPA 输入路径上生成很大的异步读多路选择器。
module lsme_bram_tdp #(
    parameter integer ADDR_WIDTH = 10,
    parameter integer DEPTH = 1024
) (
    input                       clk,

    input                       a_en,
    input                       a_we,
    input      [ADDR_WIDTH-1:0] a_addr,
    input      [31:0]           a_wdata,
    output reg [31:0]           a_rdata,

    input                       b_en,
    input                       b_we,
    input      [ADDR_WIDTH-1:0] b_addr,
    input      [31:0]           b_wdata,
    output reg [31:0]           b_rdata
);

    (* ram_style = "block" *) reg [31:0] memory [0:DEPTH-1];

    // Vivado 的真双口 RAM 推断模板要求每个写端口位于独立的时序进程中。
    // 如果把两个写端口放在同一个 always 块中，即使设置 ram_style="block"，
    // 该数组也可能被展开成 DEPTH*32 个触发器。
    always @(posedge clk) begin
        if (a_en) begin
            if (a_we)
                memory[a_addr] <= a_wdata;
            a_rdata <= a_we ? a_wdata : memory[a_addr];
        end
    end

    always @(posedge clk) begin
        if (b_en) begin
            if (b_we)
                memory[b_addr] <= b_wdata;
            b_rdata <= b_we ? b_wdata : memory[b_addr];
        end
    end

endmodule
