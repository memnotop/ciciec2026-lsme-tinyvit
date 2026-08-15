`timescale 1ns / 1ps
`include "lsme_defs.vh"

// 完整的 LSME-128I 子系统：包括 LACC 指令端点、Z/P/ZA 向量/瓦片状态、
// 描述符控制器、整数 Softmax/向量单元、AXI CSR 从机和 AXI 存储器主机。
module lsme_top #(
    parameter integer MOPA_LANES = 64
) (
    input              clk,
    input              aresetn,

    input              lacc_req_valid,
    output             lacc_req_ready,
    input      [2:0]   lacc_req_command,
    input      [6:0]   lacc_req_imm,
    input      [31:0]  lacc_req_rj,
    input      [31:0]  lacc_req_rk,
    output reg         lacc_rsp_valid,
    output reg [31:0]  lacc_rsp_rdata,

    input      [4:0]   s_awid,
    input      [31:0]  s_awaddr,
    input      [7:0]   s_awlen,
    input      [2:0]   s_awsize,
    input      [1:0]   s_awburst,
    input              s_awlock,
    input      [3:0]   s_awcache,
    input      [2:0]   s_awprot,
    input              s_awvalid,
    output             s_awready,
    input      [31:0]  s_wdata,
    input      [3:0]   s_wstrb,
    input              s_wlast,
    input              s_wvalid,
    output             s_wready,
    output     [4:0]   s_bid,
    output     [1:0]   s_bresp,
    output             s_bvalid,
    input              s_bready,
    input      [4:0]   s_arid,
    input      [31:0]  s_araddr,
    input      [7:0]   s_arlen,
    input      [2:0]   s_arsize,
    input      [1:0]   s_arburst,
    input              s_arlock,
    input      [3:0]   s_arcache,
    input      [2:0]   s_arprot,
    input              s_arvalid,
    output             s_arready,
    output     [4:0]   s_rid,
    output     [31:0]  s_rdata,
    output     [1:0]   s_rresp,
    output             s_rlast,
    output             s_rvalid,
    input              s_rready,

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

    localparam [1:0] L_IDLE       = 2'd0;
    localparam [1:0] L_CORE_ISSUE = 2'd1;
    localparam [1:0] L_CORE_WAIT  = 2'd2;
    localparam [1:0] L_EXEC_WAIT  = 2'd3;
    localparam [7:0] ERR_BUSY     = 8'h20;

    wire reset = !aresetn;

    reg [1:0] lacc_state;
    reg [2:0] lacc_command_hold;
    reg [6:0] lacc_imm_hold;
    reg [31:0] lacc_rj_hold;
    reg [31:0] lacc_rk_hold;
    reg lacc_exec_start;
    reg [31:0] lacc_descriptor_addr;

    wire csr_start_pulse;
    wire csr_clear_pulse;
    wire [31:0] csr_descriptor_addr;
    wire [1:0] debug_za_sel;
    wire [3:0] debug_za_elem;

    wire exec_busy;
    wire exec_done;
    wire [7:0] exec_error;
    wire [31:0] exec_user_tag;
    wire [1:0] exec_schedule_mode;
    wire [31:0] perf_descriptor_count;
    wire [31:0] perf_direct_mem_words;
    wire [31:0] perf_gemm_tiles;
    wire [31:0] perf_softmax_rows;
    wire [31:0] perf_rmsnorm_rows;
    wire [31:0] perf_engine_cycles;
    wire [31:0] perf_compute_cycles;
    wire [31:0] perf_memory_stall_cycles;
    wire [31:0] perf_overlap_cycles;
    wire [31:0] perf_last_descriptor_cycles;
    reg [31:0] perf_axi_read_beats;
    reg [31:0] perf_axi_write_beats;

    wire exec_core_req_valid;
    wire exec_core_req_ready;
    wire [2:0] exec_core_req_command;
    wire [6:0] exec_core_req_imm;
    wire [31:0] exec_core_req_rj;
    wire [31:0] exec_core_req_rk;
    wire exec_core_rsp_valid;
    wire [31:0] exec_core_rsp_rdata;

    wire lacc_core_req_valid = lacc_state == L_CORE_ISSUE;
    wire lacc_core_req_ready;
    wire lacc_core_rsp_valid;
    wire [31:0] lacc_core_rsp_rdata;

    wire core_req_valid = exec_busy ? exec_core_req_valid
                                    : lacc_core_req_valid;
    wire core_req_ready;
    wire [2:0] core_req_command = exec_busy ? exec_core_req_command
                                            : lacc_command_hold;
    wire [6:0] core_req_imm = exec_busy ? exec_core_req_imm
                                        : lacc_imm_hold;
    wire [31:0] core_req_rj = exec_busy ? exec_core_req_rj
                                        : lacc_rj_hold;
    wire [31:0] core_req_rk = exec_busy ? exec_core_req_rk
                                        : lacc_rk_hold;
    wire core_rsp_valid;
    wire [31:0] core_rsp_rdata;

    assign exec_core_req_ready = exec_busy && core_req_ready;
    assign lacc_core_req_ready = !exec_busy && core_req_ready;
    assign exec_core_rsp_valid = exec_busy && core_rsp_valid;
    assign exec_core_rsp_rdata = core_rsp_rdata;
    assign lacc_core_rsp_valid = !exec_busy && core_rsp_valid;
    assign lacc_core_rsp_rdata = core_rsp_rdata;

    wire exec_start = lacc_exec_start |
                      (csr_start_pulse && !exec_busy &&
                       lacc_state == L_IDLE && !lacc_req_valid);
    wire [31:0] exec_descriptor_addr = lacc_exec_start
                                      ? lacc_descriptor_addr
                                      : csr_descriptor_addr;

    wire exec_mem_req_valid;
    wire exec_mem_req_ready;
    wire exec_mem_req_write;
    wire [31:0] exec_mem_req_addr;
    wire [31:0] exec_mem_req_wdata;
    wire [3:0] exec_mem_req_wstrb;
    wire exec_mem_rsp_valid;
    wire [31:0] exec_mem_rsp_rdata;
    wire exec_mem_rsp_error;

    wire exec_burst_cmd_valid;
    wire exec_burst_cmd_ready;
    wire exec_burst_cmd_write;
    wire [31:0] exec_burst_cmd_addr;
    wire [3:0] exec_burst_cmd_beats;
    wire exec_burst_w_valid;
    wire exec_burst_w_ready;
    wire [31:0] exec_burst_wdata;
    wire [3:0] exec_burst_wstrb;
    wire exec_burst_r_valid;
    wire exec_burst_r_ready;
    wire [31:0] exec_burst_rdata;
    wire exec_burst_rlast;
    wire [1:0] exec_burst_rresp;
    wire exec_burst_done;
    wire exec_burst_error;
    wire exec_burst_busy;
    wire axi_perf_read_beat;
    wire axi_perf_write_beat;

    wire exec_macro_start;
    wire exec_macro_ready;
    wire exec_macro_first;
    wire [127:0] exec_macro_a_top;
    wire [127:0] exec_macro_a_bottom;
    wire [127:0] exec_macro_b_left;
    wire [127:0] exec_macro_b_right;
    wire [15:0] exec_macro_pred_a_top;
    wire [15:0] exec_macro_pred_a_bottom;
    wire [15:0] exec_macro_pred_b_left;
    wire [15:0] exec_macro_pred_b_right;
    wire [2047:0] exec_macro_za_init;
    wire exec_macro_busy;
    wire exec_macro_done;
    wire [2047:0] exec_macro_za_out;

    wire core_mem_req_valid;
    wire core_mem_req_ready;
    wire core_mem_req_write;
    wire [31:0] core_mem_req_addr;
    wire [31:0] core_mem_req_wdata;
    wire [3:0] core_mem_req_wstrb;
    wire core_mem_rsp_valid;
    wire [31:0] core_mem_rsp_rdata;
    wire core_mem_rsp_error;

    wire axi_req_valid = exec_mem_req_valid | core_mem_req_valid;
    wire axi_req_ready;
    wire axi_req_write = exec_mem_req_valid ? exec_mem_req_write
                                            : core_mem_req_write;
    wire [31:0] axi_req_addr = exec_mem_req_valid ? exec_mem_req_addr
                                                  : core_mem_req_addr;
    wire [31:0] axi_req_wdata = exec_mem_req_valid ? exec_mem_req_wdata
                                                   : core_mem_req_wdata;
    wire [3:0] axi_req_wstrb = exec_mem_req_valid ? exec_mem_req_wstrb
                                                  : core_mem_req_wstrb;
    wire axi_rsp_valid;
    wire [31:0] axi_rsp_rdata;
    wire axi_rsp_error;
    reg response_owner_exec;

    assign exec_mem_req_ready = exec_mem_req_valid && axi_req_ready;
    assign core_mem_req_ready = !exec_mem_req_valid && axi_req_ready;
    assign exec_mem_rsp_valid = axi_rsp_valid && response_owner_exec;
    assign exec_mem_rsp_rdata = axi_rsp_rdata;
    assign exec_mem_rsp_error = axi_rsp_error;
    assign core_mem_rsp_valid = axi_rsp_valid && !response_owner_exec;
    assign core_mem_rsp_rdata = axi_rsp_rdata;
    assign core_mem_rsp_error = axi_rsp_error;

    wire [7:0] core_error;
    wire [31:0] perf_mopa_count;
    wire [31:0] perf_active_cycles;
    wire [31:0] debug_za_data;

    assign lacc_req_ready = lacc_state == L_IDLE;

    // LACC 命令分发：
    // CTRL～STZA 进入低级体系结构核心；EXEC 异步启动描述符并立即应答；
    // WAIT 则保持请求，直到描述符引擎完成后才返回错误码。
    always @(posedge clk) begin
        lacc_rsp_valid <= 1'b0;
        lacc_exec_start <= 1'b0;

        if (reset) begin
            lacc_state <= L_IDLE;
            lacc_command_hold <= 3'd0;
            lacc_imm_hold <= 7'd0;
            lacc_rj_hold <= 32'd0;
            lacc_rk_hold <= 32'd0;
            lacc_rsp_valid <= 1'b0;
            lacc_rsp_rdata <= 32'd0;
            lacc_exec_start <= 1'b0;
            lacc_descriptor_addr <= 32'd0;
        end
        else begin
            case (lacc_state)
                L_IDLE: begin
                    if (lacc_req_valid) begin
                        if (lacc_req_command <= `LSME_CMD_STZA) begin
                            if (exec_busy) begin
                                lacc_rsp_valid <= 1'b1;
                                lacc_rsp_rdata <= {24'd0, ERR_BUSY};
                            end
                            else begin
                                lacc_command_hold <= lacc_req_command;
                                lacc_imm_hold <= lacc_req_imm;
                                lacc_rj_hold <= lacc_req_rj;
                                lacc_rk_hold <= lacc_req_rk;
                                lacc_state <= L_CORE_ISSUE;
                            end
                        end
                        else if (lacc_req_command == `LSME_CMD_EXEC) begin
                            if (exec_busy) begin
                                lacc_rsp_valid <= 1'b1;
                                lacc_rsp_rdata <= {24'd0, ERR_BUSY};
                            end
                            else begin
                                lacc_descriptor_addr <= lacc_req_rj;
                                lacc_exec_start <= 1'b1;
                                lacc_rsp_valid <= 1'b1;
                                lacc_rsp_rdata <= 32'd0;
                            end
                        end
                        else begin
                            if (exec_busy)
                                lacc_state <= L_EXEC_WAIT;
                            else begin
                                lacc_rsp_valid <= 1'b1;
                                lacc_rsp_rdata <= {24'd0, exec_error};
                            end
                        end
                    end
                end

                L_CORE_ISSUE: begin
                    if (lacc_core_req_ready)
                        lacc_state <= L_CORE_WAIT;
                end

                L_CORE_WAIT: begin
                    if (lacc_core_rsp_valid) begin
                        lacc_rsp_valid <= 1'b1;
                        lacc_rsp_rdata <= lacc_core_rsp_rdata;
                        lacc_state <= L_IDLE;
                    end
                end

                L_EXEC_WAIT: begin
                    if (exec_done || !exec_busy) begin
                        lacc_rsp_valid <= 1'b1;
                        lacc_rsp_rdata <= {24'd0, exec_error};
                        lacc_state <= L_IDLE;
                    end
                end

                default: lacc_state <= L_IDLE;
            endcase
        end
    end

    always @(posedge clk) begin
        if (reset)
            response_owner_exec <= 1'b0;
        else if (axi_req_valid && axi_req_ready)
            response_owner_exec <= exec_mem_req_valid;
    end

    always @(posedge clk) begin
        if (reset) begin
            perf_axi_read_beats <= 32'd0;
            perf_axi_write_beats <= 32'd0;
        end
        else begin
            if (axi_perf_read_beat)
                perf_axi_read_beats <= perf_axi_read_beats + 32'd1;
            if (axi_perf_write_beat)
                perf_axi_write_beats <= perf_axi_write_beats + 32'd1;
        end
    end

    lsme_exec_engine u_exec (
        .clk(clk), .reset(reset),
        .start(exec_start), .descriptor_addr(exec_descriptor_addr),
        .busy(exec_busy), .done(exec_done), .error_code(exec_error),
        .user_tag(exec_user_tag), .schedule_mode(exec_schedule_mode),
        .perf_descriptor_count(perf_descriptor_count),
        .perf_direct_mem_words(perf_direct_mem_words),
        .perf_gemm_tiles(perf_gemm_tiles),
        .perf_softmax_rows(perf_softmax_rows),
        .perf_rmsnorm_rows(perf_rmsnorm_rows),
        .perf_engine_cycles(perf_engine_cycles),
        .perf_compute_cycles(perf_compute_cycles),
        .perf_memory_stall_cycles(perf_memory_stall_cycles),
        .perf_overlap_cycles(perf_overlap_cycles),
        .perf_last_descriptor_cycles(perf_last_descriptor_cycles),
        .core_req_valid(exec_core_req_valid),
        .core_req_ready(exec_core_req_ready),
        .core_req_command(exec_core_req_command),
        .core_req_imm(exec_core_req_imm),
        .core_req_rj(exec_core_req_rj), .core_req_rk(exec_core_req_rk),
        .core_rsp_valid(exec_core_rsp_valid),
        .core_rsp_rdata(exec_core_rsp_rdata),
        .mem_req_valid(exec_mem_req_valid),
        .mem_req_ready(exec_mem_req_ready),
        .mem_req_write(exec_mem_req_write),
        .mem_req_addr(exec_mem_req_addr),
        .mem_req_wdata(exec_mem_req_wdata),
        .mem_req_wstrb(exec_mem_req_wstrb),
        .mem_rsp_valid(exec_mem_rsp_valid),
        .mem_rsp_rdata(exec_mem_rsp_rdata),
        .mem_rsp_error(exec_mem_rsp_error),
        .burst_cmd_valid(exec_burst_cmd_valid),
        .burst_cmd_ready(exec_burst_cmd_ready),
        .burst_cmd_write(exec_burst_cmd_write),
        .burst_cmd_addr(exec_burst_cmd_addr),
        .burst_cmd_beats(exec_burst_cmd_beats),
        .burst_w_valid(exec_burst_w_valid),
        .burst_w_ready(exec_burst_w_ready),
        .burst_wdata(exec_burst_wdata),
        .burst_wstrb(exec_burst_wstrb),
        .burst_r_valid(exec_burst_r_valid),
        .burst_r_ready(exec_burst_r_ready),
        .burst_rdata(exec_burst_rdata),
        .burst_rlast(exec_burst_rlast),
        .burst_rresp(exec_burst_rresp),
        .burst_done(exec_burst_done),
        .burst_error(exec_burst_error),
        .burst_busy(exec_burst_busy),
        .macro_start(exec_macro_start),
        .macro_ready(exec_macro_ready),
        .macro_first(exec_macro_first),
        .macro_a_top(exec_macro_a_top),
        .macro_a_bottom(exec_macro_a_bottom),
        .macro_b_left(exec_macro_b_left),
        .macro_b_right(exec_macro_b_right),
        .macro_pred_a_top(exec_macro_pred_a_top),
        .macro_pred_a_bottom(exec_macro_pred_a_bottom),
        .macro_pred_b_left(exec_macro_pred_b_left),
        .macro_pred_b_right(exec_macro_pred_b_right),
        .macro_za_init(exec_macro_za_init),
        .macro_busy(exec_macro_busy),
        .macro_done(exec_macro_done),
        .macro_za_out(exec_macro_za_out)
    );

    lsme_core #(.MOPA_LANES(MOPA_LANES)) u_core (
        .clk(clk), .reset(reset),
        .req_valid(core_req_valid), .req_ready(core_req_ready),
        .req_command(core_req_command), .req_imm(core_req_imm),
        .req_rj(core_req_rj), .req_rk(core_req_rk),
        .rsp_valid(core_rsp_valid), .rsp_rdata(core_rsp_rdata),
        .mem_req_valid(core_mem_req_valid),
        .mem_req_ready(core_mem_req_ready),
        .mem_req_write(core_mem_req_write),
        .mem_req_addr(core_mem_req_addr),
        .mem_req_wdata(core_mem_req_wdata),
        .mem_req_wstrb(core_mem_req_wstrb),
        .mem_rsp_valid(core_mem_rsp_valid),
        .mem_rsp_rdata(core_mem_rsp_rdata),
        .mem_rsp_error(core_mem_rsp_error),
        .macro_start(exec_macro_start),
        .macro_ready(exec_macro_ready),
        .macro_first(exec_macro_first),
        .macro_a_top(exec_macro_a_top),
        .macro_a_bottom(exec_macro_a_bottom),
        .macro_b_left(exec_macro_b_left),
        .macro_b_right(exec_macro_b_right),
        .macro_pred_a_top(exec_macro_pred_a_top),
        .macro_pred_a_bottom(exec_macro_pred_a_bottom),
        .macro_pred_b_left(exec_macro_pred_b_left),
        .macro_pred_b_right(exec_macro_pred_b_right),
        .macro_za_init(exec_macro_za_init),
        .macro_busy(exec_macro_busy),
        .macro_done(exec_macro_done),
        .macro_za_out(exec_macro_za_out),
        .error_code(core_error), .perf_mopa_count(perf_mopa_count),
        .perf_active_cycles(perf_active_cycles),
        .debug_za_sel(debug_za_sel), .debug_za_elem(debug_za_elem),
        .debug_za_data(debug_za_data)
    );

    lsme_axi_master u_axi_master (
        .clk(clk), .reset(reset),
        .req_valid(axi_req_valid), .req_ready(axi_req_ready),
        .req_write(axi_req_write), .req_addr(axi_req_addr),
        .req_wdata(axi_req_wdata), .req_wstrb(axi_req_wstrb),
        .rsp_valid(axi_rsp_valid), .rsp_rdata(axi_rsp_rdata),
        .rsp_error(axi_rsp_error),
        .burst_cmd_valid(exec_burst_cmd_valid),
        .burst_cmd_ready(exec_burst_cmd_ready),
        .burst_cmd_write(exec_burst_cmd_write),
        .burst_cmd_addr(exec_burst_cmd_addr),
        .burst_cmd_beats(exec_burst_cmd_beats),
        .burst_w_valid(exec_burst_w_valid),
        .burst_w_ready(exec_burst_w_ready),
        .burst_wdata(exec_burst_wdata),
        .burst_wstrb(exec_burst_wstrb),
        .burst_r_valid(exec_burst_r_valid),
        .burst_r_ready(exec_burst_r_ready),
        .burst_rdata(exec_burst_rdata),
        .burst_rlast(exec_burst_rlast),
        .burst_rresp(exec_burst_rresp),
        .burst_done(exec_burst_done),
        .burst_error(exec_burst_error),
        .burst_busy(exec_burst_busy),
        .perf_read_beat(axi_perf_read_beat),
        .perf_write_beat(axi_perf_write_beat),
        .m_arid(m_arid), .m_araddr(m_araddr), .m_arlen(m_arlen),
        .m_arsize(m_arsize), .m_arburst(m_arburst),
        .m_arlock(m_arlock), .m_arcache(m_arcache),
        .m_arprot(m_arprot), .m_arvalid(m_arvalid),
        .m_arready(m_arready), .m_rid(m_rid), .m_rdata(m_rdata),
        .m_rresp(m_rresp), .m_rlast(m_rlast), .m_rvalid(m_rvalid),
        .m_rready(m_rready),
        .m_awid(m_awid), .m_awaddr(m_awaddr), .m_awlen(m_awlen),
        .m_awsize(m_awsize), .m_awburst(m_awburst),
        .m_awlock(m_awlock), .m_awcache(m_awcache),
        .m_awprot(m_awprot), .m_awvalid(m_awvalid),
        .m_awready(m_awready), .m_wid(m_wid), .m_wdata(m_wdata),
        .m_wstrb(m_wstrb), .m_wlast(m_wlast), .m_wvalid(m_wvalid),
        .m_wready(m_wready), .m_bid(m_bid), .m_bresp(m_bresp),
        .m_bvalid(m_bvalid), .m_bready(m_bready)
    );

    lsme_csr_axi #(.MOPA_LANES(MOPA_LANES)) u_csr (
        .clk(clk), .reset(reset),
        .start_pulse(csr_start_pulse), .clear_pulse(csr_clear_pulse),
        .descriptor_addr(csr_descriptor_addr),
        .debug_za_sel(debug_za_sel), .debug_za_elem(debug_za_elem),
        .engine_busy(exec_busy), .engine_done(exec_done),
        .engine_error(exec_error), .schedule_mode(exec_schedule_mode),
        .user_tag(exec_user_tag),
        .perf_descriptor_count(perf_descriptor_count),
        .perf_direct_mem_words(perf_direct_mem_words),
        .perf_gemm_tiles(perf_gemm_tiles),
        .perf_softmax_rows(perf_softmax_rows),
        .perf_rmsnorm_rows(perf_rmsnorm_rows),
        .perf_mopa_count(perf_mopa_count),
        .perf_active_cycles(perf_active_cycles),
        .perf_engine_cycles(perf_engine_cycles),
        .perf_axi_read_beats(perf_axi_read_beats),
        .perf_axi_write_beats(perf_axi_write_beats),
        .perf_compute_cycles(perf_compute_cycles),
        .perf_memory_stall_cycles(perf_memory_stall_cycles),
        .perf_overlap_cycles(perf_overlap_cycles),
        .perf_last_descriptor_cycles(perf_last_descriptor_cycles),
        .debug_za_data(debug_za_data),
        .s_awid(s_awid), .s_awaddr(s_awaddr), .s_awlen(s_awlen),
        .s_awsize(s_awsize), .s_awburst(s_awburst),
        .s_awlock(s_awlock), .s_awcache(s_awcache),
        .s_awprot(s_awprot), .s_awvalid(s_awvalid),
        .s_awready(s_awready), .s_wdata(s_wdata), .s_wstrb(s_wstrb),
        .s_wlast(s_wlast), .s_wvalid(s_wvalid), .s_wready(s_wready),
        .s_bid(s_bid), .s_bresp(s_bresp), .s_bvalid(s_bvalid),
        .s_bready(s_bready),
        .s_arid(s_arid), .s_araddr(s_araddr), .s_arlen(s_arlen),
        .s_arsize(s_arsize), .s_arburst(s_arburst),
        .s_arlock(s_arlock), .s_arcache(s_arcache),
        .s_arprot(s_arprot), .s_arvalid(s_arvalid),
        .s_arready(s_arready), .s_rid(s_rid), .s_rdata(s_rdata),
        .s_rresp(s_rresp), .s_rlast(s_rlast), .s_rvalid(s_rvalid),
        .s_rready(s_rready)
    );

endmodule
