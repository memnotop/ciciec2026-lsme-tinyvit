`include "mycpu.h" 
`include "csr.h"

`ifdef HAS_LACC
module lacc_core(
    input                       clk,
    input                       reset,

    input                       lacc_flush,

    input                       lacc_req_valid,
    input [`LACC_OP_WIDTH-1: 0] lacc_req_command,
    input [6: 0]                lacc_req_imm,
    input [31: 0]               lacc_req_rj,
    input [31: 0]               lacc_req_rk,

    output                      lacc_rsp_valid,
    output [31: 0]              lacc_rsp_rdat,

    // 写请求同样会发送 valid 握手信号。
    output                      lacc_data_valid,
    input                       lacc_data_ready,
    output [31: 0]              lacc_data_addr,
    output                      lacc_data_read,
    output [31: 0]              lacc_data_wdata,
    output [1: 0]               lacc_data_size,

    input                       lacc_drsp_valid,
    input [31: 0]               lacc_drsp_rdata,

    output                      ext_req_valid,
    input                       ext_req_ready,
    output [`LACC_OP_WIDTH-1:0] ext_req_command,
    output [6:0]                ext_req_imm,
    output [31:0]               ext_req_rj,
    output [31:0]               ext_req_rk,
    input                       ext_rsp_valid,
    input [31:0]                ext_rsp_rdata
);

    reg request_issued;

    assign ext_req_valid = lacc_req_valid && !request_issued;
    assign ext_req_command = lacc_req_command;
    assign ext_req_imm = lacc_req_imm;
    assign ext_req_rj = lacc_req_rj;
    assign ext_req_rk = lacc_req_rk;

    assign lacc_rsp_valid = ext_rsp_valid && request_issued;
    assign lacc_rsp_rdat = ext_rsp_rdata;

    // 原示例加速器借用了 CPU D-cache 侧端口；当前 LSME 拥有独立的系统
    // AXI Master，因此旧的数据侧端口保持空闲。
    assign lacc_data_valid = 1'b0;
    assign lacc_data_addr = 32'd0;
    assign lacc_data_read = 1'b1;
    assign lacc_data_wdata = 32'd0;
    assign lacc_data_size = 2'b10;

    always @(posedge clk) begin
        if (reset) begin
            request_issued <= 1'b0;
        end
        else begin
            if (ext_req_valid && ext_req_ready)
                request_issued <= 1'b1;
            if (ext_rsp_valid && request_issued)
                request_issued <= 1'b0;
        end
    end

    // 为保持旧接口兼容，显式消费这些保留输入，避免未使用信号告警。
    wire unused_legacy = lacc_flush | lacc_data_ready |
                         lacc_drsp_valid | lacc_drsp_rdata[0];
endmodule
`endif
