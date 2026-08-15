`timescale 1ns / 1ps

// 阻塞式 LACC 指令端口的跨时钟域桥，一次只允许一个未完成请求。
// 请求载荷会一直保持到对应响应返回；请求/响应使用 toggle 翻转表示新事件，
// toggle 和保持稳定的数据总线分别经过两级同步，从而避免跨域单周期脉冲丢失。
module lsme_lacc_cdc (
    input              src_clk,
    input              src_reset,
    input              src_req_valid,
    output             src_req_ready,
    input      [2:0]   src_req_command,
    input      [6:0]   src_req_imm,
    input      [31:0]  src_req_rj,
    input      [31:0]  src_req_rk,
    output reg         src_rsp_valid,
    output reg [31:0]  src_rsp_rdata,

    input              dst_clk,
    input              dst_reset,
    output             dst_req_valid,
    input              dst_req_ready,
    output reg [2:0]   dst_req_command,
    output reg [6:0]   dst_req_imm,
    output reg [31:0]  dst_req_rj,
    output reg [31:0]  dst_req_rk,
    input              dst_rsp_valid,
    input      [31:0]  dst_rsp_rdata
);

    reg [73:0] src_payload;
    reg src_req_toggle;
    reg src_outstanding;
    reg src_rsp_seen;

    reg dst_rsp_toggle;
    reg [31:0] dst_rsp_payload;

    (* ASYNC_REG = "TRUE" *) reg dst_req_sync1;
    (* ASYNC_REG = "TRUE" *) reg dst_req_sync2;
    (* ASYNC_REG = "TRUE" *) reg [73:0] dst_payload_sync1;
    (* ASYNC_REG = "TRUE" *) reg [73:0] dst_payload_sync2;
    reg dst_req_seen;
    reg dst_pending;
    reg dst_issued;

    (* ASYNC_REG = "TRUE" *) reg src_rsp_sync1;
    (* ASYNC_REG = "TRUE" *) reg src_rsp_sync2;
    (* ASYNC_REG = "TRUE" *) reg [31:0] src_rsp_data_sync1;
    (* ASYNC_REG = "TRUE" *) reg [31:0] src_rsp_data_sync2;

    assign src_req_ready = !src_outstanding;
    assign dst_req_valid = dst_pending && !dst_issued;

    always @(posedge src_clk) begin
        src_rsp_valid <= 1'b0;
        if (src_reset) begin
            src_payload <= 74'd0;
            src_req_toggle <= 1'b0;
            src_outstanding <= 1'b0;
            src_rsp_seen <= 1'b0;
            src_rsp_valid <= 1'b0;
            src_rsp_rdata <= 32'd0;
            src_rsp_sync1 <= 1'b0;
            src_rsp_sync2 <= 1'b0;
            src_rsp_data_sync1 <= 32'd0;
            src_rsp_data_sync2 <= 32'd0;
        end
        else begin
            src_rsp_sync1 <= dst_rsp_toggle;
            src_rsp_sync2 <= src_rsp_sync1;
            src_rsp_data_sync1 <= dst_rsp_payload;
            src_rsp_data_sync2 <= src_rsp_data_sync1;

            if (src_req_valid && src_req_ready) begin
                src_payload <= {src_req_command, src_req_imm,
                                src_req_rj, src_req_rk};
                src_req_toggle <= !src_req_toggle;
                src_outstanding <= 1'b1;
            end

            if (src_rsp_sync2 != src_rsp_seen) begin
                src_rsp_seen <= src_rsp_sync2;
                src_rsp_rdata <= src_rsp_data_sync2;
                src_rsp_valid <= 1'b1;
                src_outstanding <= 1'b0;
            end
        end
    end

    always @(posedge dst_clk) begin
        if (dst_reset) begin
            dst_req_sync1 <= 1'b0;
            dst_req_sync2 <= 1'b0;
            dst_payload_sync1 <= 74'd0;
            dst_payload_sync2 <= 74'd0;
            dst_req_seen <= 1'b0;
            dst_pending <= 1'b0;
            dst_issued <= 1'b0;
            dst_req_command <= 3'd0;
            dst_req_imm <= 7'd0;
            dst_req_rj <= 32'd0;
            dst_req_rk <= 32'd0;
            dst_rsp_toggle <= 1'b0;
            dst_rsp_payload <= 32'd0;
        end
        else begin
            dst_req_sync1 <= src_req_toggle;
            dst_req_sync2 <= dst_req_sync1;
            dst_payload_sync1 <= src_payload;
            dst_payload_sync2 <= dst_payload_sync1;

            if (!dst_pending && dst_req_sync2 != dst_req_seen) begin
                dst_req_seen <= dst_req_sync2;
                dst_pending <= 1'b1;
                dst_issued <= 1'b0;
                {dst_req_command, dst_req_imm, dst_req_rj, dst_req_rk}
                    <= dst_payload_sync2;
            end

            if (dst_req_valid && dst_req_ready)
                dst_issued <= 1'b1;

            if (dst_pending && dst_issued && dst_rsp_valid) begin
                dst_rsp_payload <= dst_rsp_rdata;
                dst_rsp_toggle <= !dst_rsp_toggle;
                dst_pending <= 1'b0;
                dst_issued <= 1'b0;
            end
        end
    end

endmodule
