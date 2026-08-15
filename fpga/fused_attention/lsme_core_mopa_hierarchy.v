`timescale 1ns / 1ps

// LSME-128I 的体系结构状态和低级指令执行核心。
// 大粒度的 EXEC 描述符由 lsme_top/lsme_exec_engine 处理；本模块实现
// CTRL、LDZ、PSET、ZERO/BIAS、SMOPA 和 STZA，并使用一个抽象的
// 32 位单字存储器端口完成低级访存。
module lsme_core #(
    parameter integer MOPA_LANES = 64
) (
    input              clk,
    input              reset,

    input              req_valid,
    output             req_ready,
    input      [2:0]   req_command,
    input      [6:0]   req_imm,
    input      [31:0]  req_rj,
    input      [31:0]  req_rk,
    output reg         rsp_valid,
    output reg [31:0]  rsp_rdata,

    output reg         mem_req_valid,
    input              mem_req_ready,
    output reg         mem_req_write,
    output reg [31:0]  mem_req_addr,
    output reg [31:0]  mem_req_wdata,
    output reg [3:0]   mem_req_wstrb,
    input              mem_rsp_valid,
    input      [31:0]  mem_rsp_rdata,
    input              mem_rsp_error,

    // V2 8×8 宏瓦片端口。四个体系结构 ZA 分别保存四个 4×4 象限；
    // 每个 K=4 切片复用现有 MOPA 数据通路四次，因此无需再复制一套乘法阵列。
    input              macro_start,
    output             macro_ready,
    input              macro_first,
    input      [127:0] macro_a_top,
    input      [127:0] macro_a_bottom,
    input      [127:0] macro_b_left,
    input      [127:0] macro_b_right,
    input      [15:0]  macro_pred_a_top,
    input      [15:0]  macro_pred_a_bottom,
    input      [15:0]  macro_pred_b_left,
    input      [15:0]  macro_pred_b_right,
    input      [2047:0] macro_za_init,
    output             macro_busy,
    output reg         macro_done,
    output     [2047:0] macro_za_out,

    output reg [7:0]   error_code,
    output reg [31:0]  perf_mopa_count,
    output reg [31:0]  perf_active_cycles,

    input      [1:0]   debug_za_sel,
    input      [3:0]   debug_za_elem,
    output     [31:0]  debug_za_data
);

    localparam [2:0] CMD_CTRL  = 3'd0;
    localparam [2:0] CMD_LDZ   = 3'd1;
    localparam [2:0] CMD_PSET  = 3'd2;
    localparam [2:0] CMD_ZERO  = 3'd3;
    localparam [2:0] CMD_SMOPA = 3'd4;
    localparam [2:0] CMD_STZA  = 3'd5;

    localparam [3:0] ST_IDLE       = 4'd0;
    localparam [3:0] ST_LDZ_REQ    = 4'd1;
    localparam [3:0] ST_LDZ_WAIT   = 4'd2;
    localparam [3:0] ST_MOPA_WAIT  = 4'd3;
    localparam [3:0] ST_STZA_REQ   = 4'd4;
    localparam [3:0] ST_STZA_WAIT  = 4'd5;
    localparam [3:0] ST_BIAS_REQ   = 4'd6;
    localparam [3:0] ST_BIAS_WAIT  = 4'd7;
    localparam [3:0] ST_MACRO_START = 4'd8;
    localparam [3:0] ST_MACRO_WAIT  = 4'd9;

    localparam [7:0] ERR_NONE       = 8'h00;
    localparam [7:0] ERR_BAD_CMD    = 8'h01;
    localparam [7:0] ERR_BAD_INDEX  = 8'h02;
    localparam [7:0] ERR_ALIGN      = 8'h03;
    localparam [7:0] ERR_MEM        = 8'h04;

    reg [3:0] state;
    reg streaming_enable;

    reg [127:0] z_reg [0:7];
    reg [15:0]  p_reg [0:3];
    reg [511:0] za_reg[0:3];

    reg [2:0]  op_zd;
    reg        op_transpose;
    reg [31:0] op_base;
    reg [15:0] op_stride;
    reg [3:0]  word_index;
    reg [127:0] load_buffer;

    reg [1:0]  op_za;
    reg        op_store_int8;
    reg        op_relu;
    reg [4:0]  op_shift;

    reg [2:0]  mopa_zn_idx;
    reg [2:0]  mopa_zm_idx;
    reg [1:0]  mopa_pn_idx;
    reg [1:0]  mopa_pm_idx;
    reg [1:0]  mopa_za_idx;
    reg        mopa_start;
    wire       mopa_busy;
    wire       mopa_done;
    wire [511:0] mopa_result;
    reg [1:0] macro_step;

    integer i;
    integer row;
    reg [31:0] packed_word;

    assign req_ready = state == ST_IDLE && !macro_start;
    assign macro_ready = state == ST_IDLE;
    assign macro_busy = state == ST_MACRO_START || state == ST_MACRO_WAIT;
    assign macro_za_out = {za_reg[3], za_reg[2], za_reg[1], za_reg[0]};
    assign debug_za_data = za_reg[debug_za_sel][debug_za_elem*32 +: 32];

    // 保持 MOPA 阵列为独立物理层级。顶层只固定这一计算阵列到已验证邻域，
    // 其余 core 控制逻辑与融合 Attention 缓存保持可自由放置。
    (* keep_hierarchy = "yes" *) lsme_mopa_core #(.MOPA_LANES(MOPA_LANES)) u_mopa (
        .clk(clk),
        .reset(reset),
        .start(mopa_start),
        .zn(z_reg[mopa_zn_idx]),
        .zm(z_reg[mopa_zm_idx]),
        .pred_n(p_reg[mopa_pn_idx]),
        .pred_m(p_reg[mopa_pm_idx]),
        .za_in(za_reg[mopa_za_idx]),
        .busy(mopa_busy),
        .done(mopa_done),
        .za_out(mopa_result)
    );

    function automatic signed [7:0] requant_s8;
        input signed [31:0] value;
        input [4:0] shift;
        input relu;
        reg signed [31:0] magnitude;
        reg signed [31:0] shifted;
        reg signed [31:0] rounder;
        begin
            if (shift == 0) begin
                shifted = value;
            end
            else begin
                rounder = 32'sd1 <<< (shift - 1);
                if (value < 0) begin
                    magnitude = -value;
                    shifted = -((magnitude + rounder) >>> shift);
                end
                else begin
                    shifted = (value + rounder) >>> shift;
                end
            end

            if (relu && shifted < 0)
                requant_s8 = 8'sd0;
            else if (shifted > 127)
                requant_s8 = 8'sd127;
            else if (shifted < -128)
                requant_s8 = -8'sd128;
            else
                requant_s8 = shifted[7:0];
        end
    endfunction

    function automatic [31:0] physical_addr;
        input [31:0] address;
        begin
            physical_addr = address[31:29] == 3'b101
                          ? {3'b000, address[28:0]} : address;
        end
    endfunction

    always @(*) begin
        mem_req_valid = 1'b0;
        mem_req_write = 1'b0;
        mem_req_addr  = 32'd0;
        mem_req_wdata = 32'd0;
        mem_req_wstrb = 4'b0000;
        packed_word   = 32'd0;
        row           = 0;

        if (state == ST_LDZ_REQ) begin
            mem_req_valid = 1'b1;
            mem_req_write = 1'b0;
            mem_req_addr = op_base + word_index * op_stride;
        end
        else if (state == ST_BIAS_REQ) begin
            mem_req_valid = 1'b1;
            mem_req_write = 1'b0;
            mem_req_addr = op_base + word_index * 4;
        end
        else if (state == ST_STZA_REQ) begin
            mem_req_valid = 1'b1;
            mem_req_write = 1'b1;
            mem_req_wstrb = 4'b1111;
            if (op_store_int8) begin
                row = word_index;
                packed_word[7:0]   = requant_s8($signed(za_reg[op_za][(row*4+0)*32 +: 32]), op_shift, op_relu);
                packed_word[15:8]  = requant_s8($signed(za_reg[op_za][(row*4+1)*32 +: 32]), op_shift, op_relu);
                packed_word[23:16] = requant_s8($signed(za_reg[op_za][(row*4+2)*32 +: 32]), op_shift, op_relu);
                packed_word[31:24] = requant_s8($signed(za_reg[op_za][(row*4+3)*32 +: 32]), op_shift, op_relu);
                mem_req_addr  = op_base + row * op_stride;
                mem_req_wdata = packed_word;
            end
            else begin
                mem_req_addr  = op_base
                              + (word_index[3:2] * op_stride)
                              + (word_index[1:0] * 4);
                mem_req_wdata = za_reg[op_za][word_index*32 +: 32];
            end
        end
    end

    always @(posedge clk) begin
        rsp_valid <= 1'b0;
        mopa_start <= 1'b0;
        macro_done <= 1'b0;

        if (reset) begin
            state <= ST_IDLE;
            streaming_enable <= 1'b0;
            rsp_valid <= 1'b0;
            rsp_rdata <= 32'd0;
            error_code <= ERR_NONE;
            perf_mopa_count <= 32'd0;
            perf_active_cycles <= 32'd0;
            op_zd <= 3'd0;
            op_transpose <= 1'b0;
            op_base <= 32'd0;
            op_stride <= 16'd0;
            word_index <= 3'd0;
            load_buffer <= 128'd0;
            op_za <= 2'd0;
            op_store_int8 <= 1'b0;
            op_relu <= 1'b0;
            op_shift <= 5'd0;
            mopa_zn_idx <= 3'd0;
            mopa_zm_idx <= 3'd0;
            mopa_pn_idx <= 2'd0;
            mopa_pm_idx <= 2'd0;
            mopa_za_idx <= 2'd0;
            macro_step <= 2'd0;
            macro_done <= 1'b0;
            for (i = 0; i < 8; i = i + 1)
                z_reg[i] <= 128'd0;
            for (i = 0; i < 4; i = i + 1) begin
                p_reg[i] <= 16'd0;
                za_reg[i] <= 512'd0;
            end
        end
        else begin
            if (state != ST_IDLE)
                perf_active_cycles <= perf_active_cycles + 32'd1;

            case (state)
                ST_IDLE: begin
                    if (macro_start) begin
                        z_reg[0] <= macro_a_top;
                        z_reg[1] <= macro_a_bottom;
                        z_reg[2] <= macro_b_left;
                        z_reg[3] <= macro_b_right;
                        p_reg[0] <= macro_pred_a_top;
                        p_reg[1] <= macro_pred_a_bottom;
                        p_reg[2] <= macro_pred_b_left;
                        p_reg[3] <= macro_pred_b_right;
                        if (macro_first) begin
                            za_reg[0] <= macro_za_init[0 +: 512];
                            za_reg[1] <= macro_za_init[512 +: 512];
                            za_reg[2] <= macro_za_init[1024 +: 512];
                            za_reg[3] <= macro_za_init[1536 +: 512];
                        end
                        macro_step <= 2'd0;
                        state <= ST_MACRO_START;
                    end
                    else if (req_valid) begin
                        case (req_command)
                            CMD_CTRL: begin
                                rsp_valid <= 1'b1;
                                case (req_imm)
                                    7'd0: rsp_rdata <= {8'h02,
                                                       MOPA_LANES[7:0],
                                                       8'd64, 8'h88};
                                    7'd1: begin
                                        streaming_enable <= 1'b1;
                                        error_code <= ERR_NONE;
                                        rsp_rdata <= 32'd0;
                                    end
                                    7'd2: begin
                                        streaming_enable <= 1'b0;
                                        rsp_rdata <= 32'd0;
                                    end
                                    7'd3: begin
                                        error_code <= ERR_NONE;
                                        perf_mopa_count <= 32'd0;
                                        perf_active_cycles <= 32'd0;
                                        for (i = 0; i < 4; i = i + 1)
                                            za_reg[i] <= 512'd0;
                                        rsp_rdata <= 32'd0;
                                    end
                                    7'd4: rsp_rdata <= perf_mopa_count;
                                    7'd5: rsp_rdata <= perf_active_cycles;
                                    default: begin
                                        error_code <= ERR_BAD_CMD;
                                        rsp_rdata <= {24'd0, ERR_BAD_CMD};
                                    end
                                endcase
                            end

                            CMD_LDZ: begin
                                if (req_rj[1:0] != 2'b00) begin
                                    error_code <= ERR_ALIGN;
                                    rsp_valid <= 1'b1;
                                    rsp_rdata <= {24'd0, ERR_ALIGN};
                                end
                                else begin
                                    op_zd <= req_imm[2:0];
                                    op_transpose <= req_imm[3];
                                    op_base <= physical_addr(req_rj);
                                    op_stride <= req_rk[15:0] == 0
                                               ? 16'd4 : req_rk[15:0];
                                    word_index <= 4'd0;
                                    load_buffer <= 128'd0;
                                    state <= ST_LDZ_REQ;
                                end
                            end

                            CMD_PSET: begin
                                p_reg[req_imm[1:0]] <= req_rj[15:0];
                                rsp_valid <= 1'b1;
                                rsp_rdata <= 32'd0;
                            end

                            CMD_ZERO: begin
                                // imm[6]=1：从 rj 指向的地址读取 4 个 S32 bias，
                                // 并把这 4 个数广播到所选 ZA 的四个输出行。
                                if (req_imm[6]) begin
                                    if (req_rj[1:0] != 2'b00) begin
                                        error_code <= ERR_ALIGN;
                                        rsp_valid <= 1'b1;
                                        rsp_rdata <= {24'd0, ERR_ALIGN};
                                    end
                                    else begin
                                        op_za <= req_imm[1:0];
                                        op_base <= physical_addr(req_rj);
                                        word_index <= 4'd0;
                                        state <= ST_BIAS_REQ;
                                    end
                                end
                                else begin
                                    for (i = 0; i < 4; i = i + 1)
                                        if (req_imm[i])
                                            za_reg[i] <= 512'd0;
                                    rsp_valid <= 1'b1;
                                    rsp_rdata <= 32'd0;
                                end
                            end

                            CMD_SMOPA: begin
                                mopa_zn_idx <= req_rj[2:0];
                                mopa_zm_idx <= req_rj[5:3];
                                mopa_pn_idx <= req_rj[7:6];
                                mopa_pm_idx <= req_rj[9:8];
                                mopa_za_idx <= req_rj[11:10];
                                mopa_start <= 1'b1;
                                state <= ST_MOPA_WAIT;
                            end

                            CMD_STZA: begin
                                if (req_rj[1:0] != 2'b00) begin
                                    error_code <= ERR_ALIGN;
                                    rsp_valid <= 1'b1;
                                    rsp_rdata <= {24'd0, ERR_ALIGN};
                                end
                                else begin
                                    op_za <= req_imm[1:0];
                                    op_store_int8 <= req_imm[2];
                                    op_relu <= req_imm[3];
                                    op_base <= physical_addr(req_rj);
                                    op_stride <= req_rk[15:0] == 0
                                               ? (req_imm[2] ? 16'd4 : 16'd16)
                                               : req_rk[15:0];
                                    op_shift <= req_rk[20:16];
                                    word_index <= 4'd0;
                                    state <= ST_STZA_REQ;
                                end
                            end

                            default: begin
                                error_code <= ERR_BAD_CMD;
                                rsp_valid <= 1'b1;
                                rsp_rdata <= {24'd0, ERR_BAD_CMD};
                            end
                        endcase
                    end
                end

                ST_LDZ_REQ: begin
                    if (mem_req_ready)
                        state <= ST_LDZ_WAIT;
                end

                ST_LDZ_WAIT: begin
                    if (mem_rsp_valid) begin
                        if (mem_rsp_error) begin
                            error_code <= ERR_MEM;
                            rsp_valid <= 1'b1;
                            rsp_rdata <= {24'd0, ERR_MEM};
                            state <= ST_IDLE;
                        end
                        else begin
                            load_buffer[word_index*32 +: 32] <= mem_rsp_rdata;
                            if (word_index == 3) begin
                                if (op_transpose) begin
                                    z_reg[op_zd][31:0] <= {
                                        mem_rsp_rdata[7:0],
                                        load_buffer[71:64],
                                        load_buffer[39:32],
                                        load_buffer[7:0]
                                    };
                                    z_reg[op_zd][63:32] <= {
                                        mem_rsp_rdata[15:8],
                                        load_buffer[79:72],
                                        load_buffer[47:40],
                                        load_buffer[15:8]
                                    };
                                    z_reg[op_zd][95:64] <= {
                                        mem_rsp_rdata[23:16],
                                        load_buffer[87:80],
                                        load_buffer[55:48],
                                        load_buffer[23:16]
                                    };
                                    z_reg[op_zd][127:96] <= {
                                        mem_rsp_rdata[31:24],
                                        load_buffer[95:88],
                                        load_buffer[63:56],
                                        load_buffer[31:24]
                                    };
                                end
                                else begin
                                    z_reg[op_zd] <= {mem_rsp_rdata, load_buffer[95:0]};
                                end
                                rsp_valid <= 1'b1;
                                rsp_rdata <= 32'd0;
                                state <= ST_IDLE;
                            end
                            else begin
                                word_index <= word_index + 4'd1;
                                state <= ST_LDZ_REQ;
                            end
                        end
                    end
                end

                ST_MOPA_WAIT: begin
                    if (mopa_done) begin
                        za_reg[mopa_za_idx] <= mopa_result;
                        perf_mopa_count <= perf_mopa_count + 32'd1;
                        rsp_valid <= 1'b1;
                        rsp_rdata <= 32'd0;
                        state <= ST_IDLE;
                    end
                end

                ST_MACRO_START: begin
                    case (macro_step)
                        2'd0: begin
                            mopa_zn_idx <= 3'd0;
                            mopa_zm_idx <= 3'd2;
                            mopa_pn_idx <= 2'd0;
                            mopa_pm_idx <= 2'd2;
                            mopa_za_idx <= 2'd0;
                        end
                        2'd1: begin
                            mopa_zn_idx <= 3'd0;
                            mopa_zm_idx <= 3'd3;
                            mopa_pn_idx <= 2'd0;
                            mopa_pm_idx <= 2'd3;
                            mopa_za_idx <= 2'd1;
                        end
                        2'd2: begin
                            mopa_zn_idx <= 3'd1;
                            mopa_zm_idx <= 3'd2;
                            mopa_pn_idx <= 2'd1;
                            mopa_pm_idx <= 2'd2;
                            mopa_za_idx <= 2'd2;
                        end
                        default: begin
                            mopa_zn_idx <= 3'd1;
                            mopa_zm_idx <= 3'd3;
                            mopa_pn_idx <= 2'd1;
                            mopa_pm_idx <= 2'd3;
                            mopa_za_idx <= 2'd3;
                        end
                    endcase
                    mopa_start <= 1'b1;
                    state <= ST_MACRO_WAIT;
                end

                ST_MACRO_WAIT: begin
                    if (mopa_done) begin
                        za_reg[macro_step] <= mopa_result;
                        perf_mopa_count <= perf_mopa_count + 32'd1;
                        if (macro_step == 2'd3) begin
                            macro_done <= 1'b1;
                            state <= ST_IDLE;
                        end
                        else begin
                            macro_step <= macro_step + 2'd1;
                            state <= ST_MACRO_START;
                        end
                    end
                end

                ST_STZA_REQ: begin
                    if (mem_req_ready)
                        state <= ST_STZA_WAIT;
                end

                ST_STZA_WAIT: begin
                    if (mem_rsp_valid) begin
                        if (mem_rsp_error) begin
                            error_code <= ERR_MEM;
                            rsp_valid <= 1'b1;
                            rsp_rdata <= {24'd0, ERR_MEM};
                            state <= ST_IDLE;
                        end
                        else if ((op_store_int8 && word_index == 3) ||
                                 (!op_store_int8 && word_index == 15)) begin
                            rsp_valid <= 1'b1;
                            rsp_rdata <= 32'd0;
                            state <= ST_IDLE;
                        end
                        else begin
                            word_index <= word_index + 4'd1;
                            state <= ST_STZA_REQ;
                        end
                    end
                end

                ST_BIAS_REQ: begin
                    if (mem_req_ready)
                        state <= ST_BIAS_WAIT;
                end

                ST_BIAS_WAIT: begin
                    if (mem_rsp_valid) begin
                        if (mem_rsp_error) begin
                            error_code <= ERR_MEM;
                            rsp_valid <= 1'b1;
                            rsp_rdata <= {24'd0, ERR_MEM};
                            state <= ST_IDLE;
                        end
                        else begin
                            for (i = 0; i < 4; i = i + 1)
                                za_reg[op_za][(i*4+word_index)*32 +: 32]
                                    <= mem_rsp_rdata;
                            if (word_index == 3) begin
                                rsp_valid <= 1'b1;
                                rsp_rdata <= 32'd0;
                                state <= ST_IDLE;
                            end
                            else begin
                                word_index <= word_index + 4'd1;
                                state <= ST_BIAS_REQ;
                            end
                        end
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
