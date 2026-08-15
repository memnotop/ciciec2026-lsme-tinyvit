`timescale 1ns / 1ps

// LSME 统一 AXI 主机。
// legacy 单字端口供体系结构指令 LDZ/STZA、描述符读取以及 V1 控制器使用；
// V2 端口一次执行 1～8 个 beat 的 INCR burst，并提供流式读写数据接口。
// 任意时刻最多只有一个尚未完成的 AXI 事务（one outstanding），这样能让
// 比赛 SoC 的交叉开关行为保持确定，同时用 burst 分摊地址和响应开销。
module lsme_axi_master (
    input              clk,
    input              reset,

    input              req_valid,
    output             req_ready,
    input              req_write,
    input      [31:0]  req_addr,
    input      [31:0]  req_wdata,
    input      [3:0]   req_wstrb,
    output reg         rsp_valid,
    output reg [31:0]  rsp_rdata,
    output reg         rsp_error,

    input              burst_cmd_valid,
    output             burst_cmd_ready,
    input              burst_cmd_write,
    input      [31:0]  burst_cmd_addr,
    input      [3:0]   burst_cmd_beats,
    input              burst_w_valid,
    output             burst_w_ready,
    input      [31:0]  burst_wdata,
    input      [3:0]   burst_wstrb,
    output             burst_r_valid,
    input              burst_r_ready,
    output     [31:0]  burst_rdata,
    output             burst_rlast,
    output     [1:0]   burst_rresp,
    output reg         burst_done,
    output reg         burst_error,
    output             burst_busy,
    output reg         perf_read_beat,
    output reg         perf_write_beat,

    output     [3:0]   m_arid,
    output     [31:0]  m_araddr,
    output     [7:0]   m_arlen,
    output     [2:0]   m_arsize,
    output     [1:0]   m_arburst,
    output             m_arlock,
    output     [3:0]   m_arcache,
    output     [2:0]   m_arprot,
    output             m_arvalid,
    input              m_arready,
    input      [3:0]   m_rid,
    input      [31:0]  m_rdata,
    input      [1:0]   m_rresp,
    input              m_rlast,
    input              m_rvalid,
    output             m_rready,

    output     [3:0]   m_awid,
    output     [31:0]  m_awaddr,
    output     [7:0]   m_awlen,
    output     [2:0]   m_awsize,
    output     [1:0]   m_awburst,
    output             m_awlock,
    output     [3:0]   m_awcache,
    output     [2:0]   m_awprot,
    output             m_awvalid,
    input              m_awready,
    output     [3:0]   m_wid,
    output     [31:0]  m_wdata,
    output     [3:0]   m_wstrb,
    output             m_wlast,
    output             m_wvalid,
    input              m_wready,
    input      [3:0]   m_bid,
    input      [1:0]   m_bresp,
    input              m_bvalid,
    output             m_bready
);

    localparam [2:0] ST_IDLE  = 3'd0;
    localparam [2:0] ST_RADDR = 3'd1;
    localparam [2:0] ST_RDATA = 3'd2;
    localparam [2:0] ST_WADDR = 3'd3;
    localparam [2:0] ST_WDATA = 3'd4;
    localparam [2:0] ST_WRESP = 3'd5;

    reg [2:0] state;
    reg transaction_burst;
    reg [31:0] address_hold;
    reg [31:0] simple_wdata;
    reg [3:0] simple_wstrb;
    reg [3:0] beats_hold;
    reg [3:0] beat_index;
    reg error_hold;

    wire valid_burst_count = burst_cmd_beats >= 1 && burst_cmd_beats <= 8;
    wire expected_last = beat_index + 4'd1 == beats_hold;
    wire read_handshake = m_rvalid && m_rready;
    wire write_handshake = m_wvalid && m_wready;
    wire read_error_now = (m_rresp != 2'b00) || (m_rid != 4'h2) ||
                          (m_rlast != expected_last);

    assign req_ready = state == ST_IDLE && !burst_cmd_valid;
    assign burst_cmd_ready = state == ST_IDLE;
    assign burst_busy = transaction_burst && state != ST_IDLE;

    assign m_arid = 4'h2;
    assign m_araddr = address_hold;
    assign m_arlen = {4'd0, beats_hold - 4'd1};
    assign m_arsize = 3'b010;
    assign m_arburst = 2'b01;
    assign m_arlock = 1'b0;
    assign m_arcache = 4'b0000;
    assign m_arprot = 3'b000;
    assign m_arvalid = state == ST_RADDR;
    assign m_rready = state == ST_RDATA &&
                      (transaction_burst ? burst_r_ready : 1'b1);

    assign burst_r_valid = state == ST_RDATA && transaction_burst && m_rvalid;
    assign burst_rdata = m_rdata;
    assign burst_rlast = m_rlast;
    assign burst_rresp = m_rresp;

    assign m_awid = 4'h2;
    assign m_awaddr = address_hold;
    assign m_awlen = {4'd0, beats_hold - 4'd1};
    assign m_awsize = 3'b010;
    assign m_awburst = 2'b01;
    assign m_awlock = 1'b0;
    assign m_awcache = 4'b0000;
    assign m_awprot = 3'b000;
    assign m_awvalid = state == ST_WADDR;
    assign m_wid = 4'h2;
    assign m_wdata = transaction_burst ? burst_wdata : simple_wdata;
    assign m_wstrb = transaction_burst ? burst_wstrb : simple_wstrb;
    assign m_wlast = expected_last;
    assign m_wvalid = state == ST_WDATA &&
                      (transaction_burst ? burst_w_valid : 1'b1);
    assign burst_w_ready = state == ST_WDATA && transaction_burst && m_wready;
    assign m_bready = state == ST_WRESP;

    always @(posedge clk) begin
        rsp_valid <= 1'b0;
        rsp_error <= 1'b0;
        burst_done <= 1'b0;
        burst_error <= 1'b0;
        perf_read_beat <= 1'b0;
        perf_write_beat <= 1'b0;

        if (reset) begin
            state <= ST_IDLE;
            transaction_burst <= 1'b0;
            address_hold <= 32'd0;
            simple_wdata <= 32'd0;
            simple_wstrb <= 4'd0;
            beats_hold <= 4'd1;
            beat_index <= 4'd0;
            error_hold <= 1'b0;
            rsp_rdata <= 32'd0;
        end
        else begin
            case (state)
                ST_IDLE: begin
                    beat_index <= 4'd0;
                    error_hold <= 1'b0;
                    if (burst_cmd_valid) begin
                        transaction_burst <= 1'b1;
                        if (!valid_burst_count || burst_cmd_addr[1:0] != 0) begin
                            burst_done <= 1'b1;
                            burst_error <= 1'b1;
                        end
                        else begin
                            address_hold <= burst_cmd_addr;
                            beats_hold <= burst_cmd_beats;
                            state <= burst_cmd_write ? ST_WADDR : ST_RADDR;
                        end
                    end
                    else if (req_valid) begin
                        transaction_burst <= 1'b0;
                        address_hold <= req_addr;
                        simple_wdata <= req_wdata;
                        simple_wstrb <= req_wstrb;
                        beats_hold <= 4'd1;
                        if (req_addr[1:0] != 0) begin
                            rsp_valid <= 1'b1;
                            rsp_error <= 1'b1;
                        end
                        else
                            state <= req_write ? ST_WADDR : ST_RADDR;
                    end
                end

                ST_RADDR: begin
                    if (m_arready)
                        state <= ST_RDATA;
                end

                ST_RDATA: begin
                    if (read_handshake) begin
                        perf_read_beat <= 1'b1;
                        error_hold <= error_hold || read_error_now;
                        if (transaction_burst) begin
                            if (expected_last || m_rlast) begin
                                burst_done <= 1'b1;
                                burst_error <= error_hold || read_error_now;
                                state <= ST_IDLE;
                            end
                            else
                                beat_index <= beat_index + 4'd1;
                        end
                        else begin
                            rsp_valid <= 1'b1;
                            rsp_rdata <= m_rdata;
                            rsp_error <= read_error_now;
                            state <= ST_IDLE;
                        end
                    end
                end

                ST_WADDR: begin
                    if (m_awready)
                        state <= ST_WDATA;
                end

                ST_WDATA: begin
                    if (write_handshake) begin
                        perf_write_beat <= 1'b1;
                        if (expected_last)
                            state <= ST_WRESP;
                        else
                            beat_index <= beat_index + 4'd1;
                    end
                end

                ST_WRESP: begin
                    if (m_bvalid) begin
                        if (transaction_burst) begin
                            burst_done <= 1'b1;
                            burst_error <= (m_bresp != 2'b00) ||
                                           (m_bid != 4'h2);
                        end
                        else begin
                            rsp_valid <= 1'b1;
                            rsp_rdata <= 32'd0;
                            rsp_error <= (m_bresp != 2'b00) ||
                                         (m_bid != 4'h2);
                        end
                        state <= ST_IDLE;
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
