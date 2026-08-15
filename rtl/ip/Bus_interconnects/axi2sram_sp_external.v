// Copyright 2018 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51.
//
// 寄存化 AXI4 到异步 SRAM 适配器。burst 地址由 beat 地址寄存器逐拍推进，
// 不再使用组合的 base+counter 乘法/移位地址锥，因此板级 SRAM 地址引脚不会
// 直接受到旧 WRAP/length 组合逻辑驱动。AXI 接收端就绪时，读通道可持续
// 每拍返回一个 beat；外部 SRAM 连续写之间仍保留必须的低电平间隔。
module axi2sram_sp_external #(
    parameter AXI_ID_WIDTH   = 5,
    parameter AXI_ADDR_WIDTH = 32,
    parameter AXI_DATA_WIDTH = 32
) (
    input                          clk,
    input                          resetn,

    input      [AXI_ADDR_WIDTH-1:0] s_araddr,
    input      [1:0]                s_arburst,
    input      [3:0]                s_arcache,
    input      [AXI_ID_WIDTH-1:0]   s_arid,
    input      [7:0]                s_arlen,
    input                           s_arlock,
    input      [2:0]                s_arprot,
    output                          s_arready,
    input      [2:0]                s_arsize,
    input                           s_arvalid,

    input      [AXI_ADDR_WIDTH-1:0] s_awaddr,
    input      [1:0]                s_awburst,
    input      [3:0]                s_awcache,
    input      [AXI_ID_WIDTH-1:0]   s_awid,
    input      [7:0]                s_awlen,
    input                           s_awlock,
    input      [2:0]                s_awprot,
    output                          s_awready,
    input      [2:0]                s_awsize,
    input                           s_awvalid,

    output     [AXI_ID_WIDTH-1:0]   s_bid,
    input                           s_bready,
    output     [1:0]                s_bresp,
    output                          s_bvalid,

    output     [AXI_DATA_WIDTH-1:0] s_rdata,
    output     [AXI_ID_WIDTH-1:0]   s_rid,
    output                          s_rlast,
    input                           s_rready,
    output     [1:0]                s_rresp,
    output                          s_rvalid,

    input      [AXI_DATA_WIDTH-1:0] s_wdata,
    input                           s_wlast,
    output                          s_wready,
    input      [AXI_DATA_WIDTH/8-1:0] s_wstrb,
    input                           s_wvalid,

    output                          req_o,
    output                          we_o,
    output     [AXI_ADDR_WIDTH-1:0] addr_o,
    output     [AXI_DATA_WIDTH/8-1:0] be_o,
    output     [AXI_DATA_WIDTH-1:0] data_o,
    input      [AXI_DATA_WIDTH-1:0] data_i
);

    localparam [2:0] ST_IDLE    = 3'd0;
    localparam [2:0] ST_RDATA   = 3'd1;
    localparam [2:0] ST_WWAIT   = 3'd2;
    localparam [2:0] ST_WPULSE  = 3'd3;
    localparam [2:0] ST_BRESP   = 3'd4;

    localparam [1:0] BURST_FIXED = 2'b00;
    localparam [1:0] BURST_INCR  = 2'b01;
    localparam [1:0] BURST_WRAP  = 2'b10;

    reg [2:0] state_q;
    reg [AXI_ID_WIDTH-1:0] id_q;
    reg [7:0] len_q;
    reg [7:0] beat_q;
    reg [1:0] burst_q;
    reg [AXI_ADDR_WIDTH-1:0] beat_addr_q;
    reg [AXI_ADDR_WIDTH-1:0] wrap_base_q;
    reg [AXI_ADDR_WIDTH-1:0] wrap_mask_q;
    reg response_error_q;
    reg [AXI_DATA_WIDTH-1:0] write_data_q;
    reg [AXI_DATA_WIDTH/8-1:0] write_strb_q;
    reg write_last_q;

    wire expected_last = beat_q == len_q;
    wire read_hs = s_rvalid && s_rready;
    wire write_hs = s_wvalid && s_wready;

    function automatic [AXI_ADDR_WIDTH-1:0] wrap_mask;
        input [7:0] len;
        reg [AXI_ADDR_WIDTH-1:0] byte_count;
        begin
            byte_count = ({24'd0, len} + 1) << 2;
            wrap_mask = byte_count - 1;
        end
    endfunction

    function automatic [AXI_ADDR_WIDTH-1:0] next_address;
        input [AXI_ADDR_WIDTH-1:0] current;
        input [1:0] burst_type;
        input [AXI_ADDR_WIDTH-1:0] wrap_base;
        input [AXI_ADDR_WIDTH-1:0] mask;
        reg [AXI_ADDR_WIDTH-1:0] incremented;
        begin
            incremented = current + 4;
            case (burst_type)
                BURST_FIXED: next_address = current;
                BURST_WRAP: begin
                    if ((incremented & ~mask) != wrap_base)
                        next_address = wrap_base;
                    else
                        next_address = incremented;
                end
                default: next_address = incremented;
            endcase
        end
    endfunction

    assign s_arready = state_q == ST_IDLE;
    assign s_awready = state_q == ST_IDLE && !s_arvalid;
    assign s_rvalid = state_q == ST_RDATA;
    assign s_rdata = data_i;
    assign s_rid = id_q;
    assign s_rlast = expected_last;
    assign s_rresp = response_error_q ? 2'b10 : 2'b00;

    assign s_wready = state_q == ST_WWAIT;
    assign s_bvalid = state_q == ST_BRESP;
    assign s_bid = id_q;
    assign s_bresp = response_error_q ? 2'b10 : 2'b00;

    assign req_o = state_q == ST_RDATA || state_q == ST_WPULSE;
    assign we_o = state_q == ST_WPULSE;
    assign addr_o = beat_addr_q;
    assign be_o = write_strb_q;
    assign data_o = write_data_q;

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            state_q <= ST_IDLE;
            id_q <= {AXI_ID_WIDTH{1'b0}};
            len_q <= 8'd0;
            beat_q <= 8'd0;
            burst_q <= BURST_INCR;
            beat_addr_q <= {AXI_ADDR_WIDTH{1'b0}};
            wrap_base_q <= {AXI_ADDR_WIDTH{1'b0}};
            wrap_mask_q <= {AXI_ADDR_WIDTH{1'b0}};
            response_error_q <= 1'b0;
            write_data_q <= {AXI_DATA_WIDTH{1'b0}};
            write_strb_q <= {AXI_DATA_WIDTH/8{1'b0}};
            write_last_q <= 1'b0;
        end
        else begin
            case (state_q)
                ST_IDLE: begin
                    beat_q <= 8'd0;
                    response_error_q <= 1'b0;
                    if (s_arvalid) begin
                        id_q <= s_arid;
                        len_q <= s_arlen;
                        burst_q <= s_arburst;
                        beat_addr_q <= {s_araddr[AXI_ADDR_WIDTH-1:2], 2'b00};
                        wrap_mask_q <= wrap_mask(s_arlen);
                        wrap_base_q <= s_araddr & ~wrap_mask(s_arlen);
                        response_error_q <= s_arsize != 3'b010 ||
                                            s_arburst == 2'b11 ||
                                            s_araddr[1:0] != 0;
                        state_q <= ST_RDATA;
                    end
                    else if (s_awvalid) begin
                        id_q <= s_awid;
                        len_q <= s_awlen;
                        burst_q <= s_awburst;
                        beat_addr_q <= {s_awaddr[AXI_ADDR_WIDTH-1:2], 2'b00};
                        wrap_mask_q <= wrap_mask(s_awlen);
                        wrap_base_q <= s_awaddr & ~wrap_mask(s_awlen);
                        response_error_q <= s_awsize != 3'b010 ||
                                            s_awburst == 2'b11 ||
                                            s_awaddr[1:0] != 0;
                        state_q <= ST_WWAIT;
                    end
                end

                ST_RDATA: begin
                    if (read_hs) begin
                        if (expected_last)
                            state_q <= ST_IDLE;
                        else begin
                            beat_q <= beat_q + 8'd1;
                            beat_addr_q <= next_address(beat_addr_q, burst_q,
                                                       wrap_base_q,
                                                       wrap_mask_q);
                        end
                    end
                end

                ST_WWAIT: begin
                    if (write_hs) begin
                        write_data_q <= s_wdata;
                        write_strb_q <= s_wstrb;
                        write_last_q <= s_wlast;
                        if (s_wlast != expected_last)
                            response_error_q <= 1'b1;
                        state_q <= ST_WPULSE;
                    end
                end

                ST_WPULSE: begin
                    // 外部 SRAM 写脉冲占用完整的当前周期；返回 WWAIT 后，
                    // 下一次写脉冲之前自然形成所要求的低电平间隔。
                    if (expected_last || write_last_q)
                        state_q <= ST_BRESP;
                    else begin
                        beat_q <= beat_q + 8'd1;
                        beat_addr_q <= next_address(beat_addr_q, burst_q,
                                                   wrap_base_q,
                                                   wrap_mask_q);
                        state_q <= ST_WWAIT;
                    end
                end

                ST_BRESP: begin
                    if (s_bready)
                        state_q <= ST_IDLE;
                end

                default: state_q <= ST_IDLE;
            endcase
        end
    end

    // SRAM 目标不使用 AXI cache/prot/lock 等属性，但显式消费这些输入，
    // 可以避免综合工具产生无意义的未使用端口告警。
    wire unused_attributes = ^{s_arcache, s_arlock, s_arprot,
                               s_awcache, s_awlock, s_awprot};

endmodule
