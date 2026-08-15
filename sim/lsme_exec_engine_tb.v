`timescale 1ns / 1ps
`include "lsme_defs.vh"

module lsme_exec_engine_tb;
    reg clk = 0;
    reg reset = 1;
    reg start = 0;
    reg [31:0] descriptor_addr = 0;
    wire busy;
    wire done;
    wire [7:0] error_code;
    wire [31:0] user_tag;
    wire [1:0] schedule_mode;
    wire [31:0] perf_descriptor_count;
    wire [31:0] perf_direct_mem_words;
    wire [31:0] perf_gemm_tiles;
    wire [31:0] perf_softmax_rows;
    wire [31:0] perf_rmsnorm_rows;

    wire exec_core_req_valid;
    wire exec_core_req_ready;
    wire [2:0] exec_core_req_command;
    wire [6:0] exec_core_req_imm;
    wire [31:0] exec_core_req_rj;
    wire [31:0] exec_core_req_rk;
    wire exec_core_rsp_valid;
    wire [31:0] exec_core_rsp_rdata;

    wire exec_mem_req_valid;
    wire exec_mem_req_ready;
    wire exec_mem_req_write;
    wire [31:0] exec_mem_req_addr;
    wire [31:0] exec_mem_req_wdata;
    wire [3:0] exec_mem_req_wstrb;
    reg exec_mem_rsp_valid = 0;
    reg [31:0] exec_mem_rsp_rdata = 0;
    reg exec_mem_rsp_error = 0;

    wire core_mem_req_valid;
    wire core_mem_req_ready;
    wire core_mem_req_write;
    wire [31:0] core_mem_req_addr;
    wire [31:0] core_mem_req_wdata;
    wire [3:0] core_mem_req_wstrb;
    reg core_mem_rsp_valid = 0;
    reg [31:0] core_mem_rsp_rdata = 0;
    reg core_mem_rsp_error = 0;

    wire [7:0] core_error;
    wire [31:0] core_mopa_count;
    wire [31:0] core_active_cycles;
    wire [31:0] unused_debug;

    reg [7:0] memory [0:262143];
    reg memory_pending = 0;
    reg memory_owner_exec = 0;
    reg pending_write = 0;
    reg [31:0] pending_addr = 0;
    reg [31:0] pending_wdata = 0;
    reg [3:0] pending_wstrb = 0;

    integer i;
    integer row;
    integer col;
    integer kval;
    integer expected;
    integer got;
    integer cycles;
    integer tests = 0;
    integer max_value;
    integer exp_sum;
    integer delta;
    integer msb;
    integer mant;
    integer reciprocal;
    integer product;
    integer shift;
    integer sum_square;
    integer rms_value;
    integer denominator;
    integer numerator;
    integer magnitude;
    integer quotient;
    integer remainder;
    integer softmax_expected [0:63];
    integer softmax_exp [0:63];

    localparam [31:0] DESC_GEMM = 32'h00001000;
    localparam [31:0] DESC_SOFT = 32'h00001100;
    localparam [31:0] DESC_VADD = 32'h00001200;
    localparam [31:0] DESC_RMS = 32'h00001300;
    localparam [31:0] GEMM_A = 32'h00002000;
    localparam [31:0] GEMM_B = 32'h00003000;
    localparam [31:0] GEMM_C = 32'h00004000;
    localparam [31:0] GEMM_BIAS = 32'h00005000;
    localparam [31:0] SOFT_SRC = 32'h00006000;
    localparam [31:0] SOFT_DST = 32'h00007000;
    localparam [31:0] VADD_A = 32'h00008000;
    localparam [31:0] VADD_B = 32'h00008100;
    localparam [31:0] VADD_C = 32'h00008200;
    localparam [31:0] RMS_SRC = 32'h00009000;
    localparam [31:0] RMS_GAIN = 32'h00009100;
    localparam [31:0] RMS_DST = 32'h00009200;

    lsme_exec_engine dut (
        .clk(clk), .reset(reset),
        .start(start), .descriptor_addr(descriptor_addr),
        .busy(busy), .done(done), .error_code(error_code),
        .user_tag(user_tag), .schedule_mode(schedule_mode),
        .perf_descriptor_count(perf_descriptor_count),
        .perf_direct_mem_words(perf_direct_mem_words),
        .perf_gemm_tiles(perf_gemm_tiles),
        .perf_softmax_rows(perf_softmax_rows),
        .perf_rmsnorm_rows(perf_rmsnorm_rows),
        .perf_engine_cycles(), .perf_compute_cycles(),
        .perf_memory_stall_cycles(), .perf_overlap_cycles(),
        .perf_last_descriptor_cycles(),
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
        .burst_cmd_valid(), .burst_cmd_ready(1'b0),
        .burst_cmd_write(), .burst_cmd_addr(), .burst_cmd_beats(),
        .burst_w_valid(), .burst_w_ready(1'b0),
        .burst_wdata(), .burst_wstrb(),
        .burst_r_valid(1'b0), .burst_r_ready(),
        .burst_rdata(32'd0), .burst_rlast(1'b0),
        .burst_rresp(2'b00), .burst_done(1'b0),
        .burst_error(1'b0), .burst_busy(1'b0),
        .macro_start(), .macro_ready(1'b0), .macro_first(),
        .macro_a_top(), .macro_a_bottom(),
        .macro_b_left(), .macro_b_right(),
        .macro_pred_a_top(), .macro_pred_a_bottom(),
        .macro_pred_b_left(), .macro_pred_b_right(),
        .macro_za_init(), .macro_busy(1'b0),
        .macro_done(1'b0), .macro_za_out(2048'd0)
    );

    function integer integer_sqrt_ref;
        input integer value;
        integer operand;
        integer result;
        integer bit_value;
        begin
            operand = value;
            result = 0;
            bit_value = 32'h4000_0000;
            while (bit_value > operand)
                bit_value = bit_value >> 2;
            while (bit_value != 0) begin
                if (operand >= result + bit_value) begin
                    operand = operand - result - bit_value;
                    result = (result >> 1) + bit_value;
                end
                else
                    result = result >> 1;
                bit_value = bit_value >> 2;
            end
            integer_sqrt_ref = result;
        end
    endfunction

    lsme_core #(.MOPA_LANES(64)) u_core (
        .clk(clk), .reset(reset),
        .req_valid(exec_core_req_valid), .req_ready(exec_core_req_ready),
        .req_command(exec_core_req_command), .req_imm(exec_core_req_imm),
        .req_rj(exec_core_req_rj), .req_rk(exec_core_req_rk),
        .rsp_valid(exec_core_rsp_valid), .rsp_rdata(exec_core_rsp_rdata),
        .mem_req_valid(core_mem_req_valid),
        .mem_req_ready(core_mem_req_ready),
        .mem_req_write(core_mem_req_write),
        .mem_req_addr(core_mem_req_addr),
        .mem_req_wdata(core_mem_req_wdata),
        .mem_req_wstrb(core_mem_req_wstrb),
        .mem_rsp_valid(core_mem_rsp_valid),
        .mem_rsp_rdata(core_mem_rsp_rdata),
        .mem_rsp_error(core_mem_rsp_error),
        .macro_start(1'b0), .macro_ready(), .macro_first(1'b0),
        .macro_a_top(128'd0), .macro_a_bottom(128'd0),
        .macro_b_left(128'd0), .macro_b_right(128'd0),
        .macro_pred_a_top(16'd0), .macro_pred_a_bottom(16'd0),
        .macro_pred_b_left(16'd0), .macro_pred_b_right(16'd0),
        .macro_za_init(2048'd0), .macro_busy(), .macro_done(),
        .macro_za_out(),
        .error_code(core_error), .perf_mopa_count(core_mopa_count),
        .perf_active_cycles(core_active_cycles),
        .debug_za_sel(2'd0), .debug_za_elem(4'd0),
        .debug_za_data(unused_debug)
    );

    assign exec_mem_req_ready = !memory_pending;
    assign core_mem_req_ready = !memory_pending && !exec_mem_req_valid;

    always #5 clk = ~clk;

    function [31:0] read_word;
        input [31:0] address;
        begin
            read_word = {memory[address+3], memory[address+2],
                         memory[address+1], memory[address]};
        end
    endfunction

    task write_word;
        input [31:0] address;
        input [31:0] value;
        begin
            memory[address] = value[7:0];
            memory[address+1] = value[15:8];
            memory[address+2] = value[23:16];
            memory[address+3] = value[31:24];
        end
    endtask

    task write_byte;
        input [31:0] address;
        input integer value;
        begin
            memory[address] = value[7:0];
        end
    endtask

    function integer signed_byte;
        input [31:0] address;
        begin
            signed_byte = $signed(memory[address]);
        end
    endfunction

    always @(posedge clk) begin
        exec_mem_rsp_valid <= 0;
        core_mem_rsp_valid <= 0;
        exec_mem_rsp_error <= 0;
        core_mem_rsp_error <= 0;

        if (memory_pending) begin
            if (pending_write) begin
                if (pending_wstrb[0]) memory[pending_addr] <= pending_wdata[7:0];
                if (pending_wstrb[1]) memory[pending_addr+1] <= pending_wdata[15:8];
                if (pending_wstrb[2]) memory[pending_addr+2] <= pending_wdata[23:16];
                if (pending_wstrb[3]) memory[pending_addr+3] <= pending_wdata[31:24];
            end
            if (memory_owner_exec) begin
                exec_mem_rsp_valid <= 1;
                exec_mem_rsp_rdata <= read_word(pending_addr);
            end
            else begin
                core_mem_rsp_valid <= 1;
                core_mem_rsp_rdata <= read_word(pending_addr);
            end
            memory_pending <= 0;
        end
        else if (exec_mem_req_valid) begin
            memory_pending <= 1;
            memory_owner_exec <= 1;
            pending_write <= exec_mem_req_write;
            pending_addr <= exec_mem_req_addr;
            pending_wdata <= exec_mem_req_wdata;
            pending_wstrb <= exec_mem_req_wstrb;
        end
        else if (core_mem_req_valid) begin
            memory_pending <= 1;
            memory_owner_exec <= 0;
            pending_write <= core_mem_req_write;
            pending_addr <= core_mem_req_addr;
            pending_wdata <= core_mem_req_wdata;
            pending_wstrb <= core_mem_req_wstrb;
        end
    end

    task clear_descriptor;
        input [31:0] base;
        begin
            for (i = 0; i < 16; i = i + 1)
                write_word(base + i*4, 0);
        end
    endtask

    task run_descriptor;
        input [31:0] address;
        begin
            @(negedge clk);
            descriptor_addr = address | 32'ha0000000;
            start = 1;
            @(negedge clk);
            start = 0;
            cycles = 0;
            while (!done && cycles < 20000) begin
                @(negedge clk);
                cycles = cycles + 1;
            end
            if (!done) begin
                $display("FAIL descriptor timeout addr=%h state=%0d core_state=%0d",
                         address, dut.state, u_core.state);
                $fatal(1);
            end
            if (error_code != 0) begin
                $display("FAIL descriptor error addr=%h error=%h state=%0d",
                         address, error_code, dut.state);
                $fatal(1);
            end
            tests = tests + 1;
        end
    endtask

    function integer exp_fraction;
        input integer frac;
        begin
            case (frac)
                0: exp_fraction=32767;  1: exp_fraction=32065;
                2: exp_fraction=31378;  3: exp_fraction=30705;
                4: exp_fraction=30047;  5: exp_fraction=29404;
                6: exp_fraction=28774;  7: exp_fraction=28157;
                8: exp_fraction=27554;  9: exp_fraction=26963;
                10: exp_fraction=26385; 11: exp_fraction=25820;
                12: exp_fraction=25267; 13: exp_fraction=24725;
                14: exp_fraction=24196; 15: exp_fraction=23677;
                16: exp_fraction=23170; 17: exp_fraction=22673;
                18: exp_fraction=22187; 19: exp_fraction=21712;
                20: exp_fraction=21247; 21: exp_fraction=20791;
                22: exp_fraction=20346; 23: exp_fraction=19910;
                24: exp_fraction=19483; 25: exp_fraction=19066;
                26: exp_fraction=18657; 27: exp_fraction=18258;
                28: exp_fraction=17866; 29: exp_fraction=17483;
                30: exp_fraction=17109; default: exp_fraction=16742;
            endcase
        end
    endfunction

    task build_softmax_reference;
        input [31:0] source;
        input integer count_value;
        input integer score_shift_value;
        begin
            max_value = $signed(read_word(source));
            for (i = 1; i < count_value; i = i + 1)
                if ($signed(read_word(source+i*4)) > max_value)
                    max_value = $signed(read_word(source+i*4));
            exp_sum = 0;
            for (i = 0; i < count_value; i = i + 1) begin
                delta = (max_value - $signed(read_word(source+i*4)))
                        >>> score_shift_value;
                if (delta > 255) delta = 255;
                softmax_exp[i] = exp_fraction(delta & 31) >> (delta >> 5);
                exp_sum = exp_sum + softmax_exp[i];
            end
            msb = 0;
            for (i = 0; i < 22; i = i + 1)
                if ((exp_sum >> i) != 0) msb = i;
            mant = msb >= 7 ? exp_sum >> (msb-7) : exp_sum << (7-msb);
            reciprocal = ((127*65536) + (mant>>1)) / mant;
            shift = msb + 9;
            for (i = 0; i < count_value; i = i + 1) begin
                product = softmax_exp[i] * reciprocal;
                softmax_expected[i] = (product + (1 << (shift-1))) >> shift;
                if (softmax_expected[i] > 127) softmax_expected[i] = 127;
            end
        end
    endtask

    initial begin
        for (i = 0; i < 262144; i = i + 1)
            memory[i] = 0;

        repeat (4) @(negedge clk);
        reset = 0;

        // 8×8×8 有符号 INT8 GEMM，输出 S32 并广播 bias。
        // V1 路径包含四个输出瓦片，每个瓦片执行两个 K 切片。
        for (row = 0; row < 8; row = row + 1)
            for (col = 0; col < 8; col = col + 1) begin
                write_byte(GEMM_A + row*8 + col, ((row*3+col*2) % 9)-4);
                write_byte(GEMM_B + row*8 + col, ((row*5-col*2+32) % 11)-5);
            end
        for (col = 0; col < 8; col = col + 1)
            write_word(GEMM_BIAS + col*4, col*7-20);

        clear_descriptor(DESC_GEMM);
        write_word(DESC_GEMM+0, `LSME_OP_GEMM | (1 << (8+`LSME_FLAG_BIAS)));
        write_word(DESC_GEMM+4, GEMM_A | 32'ha0000000);
        write_word(DESC_GEMM+8, GEMM_B | 32'ha0000000);
        write_word(DESC_GEMM+12, GEMM_C | 32'ha0000000);
        write_word(DESC_GEMM+16, GEMM_BIAS | 32'ha0000000);
        write_word(DESC_GEMM+20, {16'd8,16'd8});
        write_word(DESC_GEMM+24, {16'd1,16'd8});
        write_word(DESC_GEMM+28, 32'd8);
        write_word(DESC_GEMM+32, 32'd8);
        write_word(DESC_GEMM+36, 32'd32);
        write_word(DESC_GEMM+56, 32'h47534d31);
        run_descriptor(DESC_GEMM);

        for (row = 0; row < 8; row = row + 1)
            for (col = 0; col < 8; col = col + 1) begin
                expected = col*7-20;
                for (kval = 0; kval < 8; kval = kval + 1)
                    expected = expected
                        + signed_byte(GEMM_A + row*8 + kval)
                        * signed_byte(GEMM_B + kval*8 + col);
                got = $signed(read_word(GEMM_C + row*32 + col*4));
                if (got != expected) begin
                    $display("FAIL GEMM row=%0d col=%0d expected=%0d got=%0d",
                             row, col, expected, got);
                    $fatal(1);
                end
            end
        if (schedule_mode != `LSME_MODE_TILE8 || perf_gemm_tiles != 4 ||
            core_mopa_count != 8) begin
            $display("FAIL GEMM mode/counters mode=%0d tiles=%0d mopa=%0d",
                     schedule_mode, perf_gemm_tiles, core_mopa_count);
            $fatal(1);
        end

        // 两行、每行八个 S32 score，输出打包的无符号 INT8 概率。
        for (row = 0; row < 2; row = row + 1)
            for (col = 0; col < 8; col = col + 1)
                write_word(SOFT_SRC + row*32 + col*4,
                           (row ? 90 : -30) + col*13 - col*col*2);
        clear_descriptor(DESC_SOFT);
        write_word(DESC_SOFT+0, `LSME_OP_SOFTMAX);
        write_word(DESC_SOFT+4, SOFT_SRC | 32'ha0000000);
        write_word(DESC_SOFT+12, SOFT_DST | 32'ha0000000);
        write_word(DESC_SOFT+20, {16'd8,16'd2});
        write_word(DESC_SOFT+24, {16'd1,16'd0});
        write_word(DESC_SOFT+28, 32'd32);
        write_word(DESC_SOFT+36, 32'd8);
        write_word(DESC_SOFT+52, 32'h00000200);
        write_word(DESC_SOFT+56, 32'h534f4654);
        run_descriptor(DESC_SOFT);
        for (row = 0; row < 2; row = row + 1) begin
            build_softmax_reference(SOFT_SRC + row*32, 8, 2);
            for (col = 0; col < 8; col = col + 1)
                if (memory[SOFT_DST + row*8 + col] != softmax_expected[col]) begin
                    $display("FAIL SOFTMAX row=%0d col=%0d expected=%0d got=%0d",
                             row, col, softmax_expected[col],
                             memory[SOFT_DST + row*8 + col]);
                    $fatal(1);
                end
        end
        if (perf_softmax_rows != 2 || user_tag != 32'h534f4654) begin
            $display("FAIL SOFTMAX counters/tag rows=%0d tag=%h",
                     perf_softmax_rows, user_tag);
            $fatal(1);
        end

        // 带饱和、ReLU 和三字节尾块的 INT8 residual add。
        for (row = 0; row < 2; row = row + 1) begin
            for (col = 0; col < 8; col = col + 1) begin
                write_byte(VADD_A + row*8 + col, col == 0 ? 120 : col*25-80);
                write_byte(VADD_B + row*8 + col, col == 0 ? 30 : 55-col*9);
                write_byte(VADD_C + row*8 + col, 8'haa);
            end
        end
        clear_descriptor(DESC_VADD);
        write_word(DESC_VADD+0, `LSME_OP_VECTOR_ADD
            | (1 << (8+`LSME_FLAG_OUTPUT_INT8))
            | (1 << (8+`LSME_FLAG_RELU)));
        write_word(DESC_VADD+4, VADD_A | 32'ha0000000);
        write_word(DESC_VADD+8, VADD_B | 32'ha0000000);
        write_word(DESC_VADD+12, VADD_C | 32'ha0000000);
        write_word(DESC_VADD+20, {16'd7,16'd2});
        write_word(DESC_VADD+24, {16'd1,16'd0});
        write_word(DESC_VADD+28, 32'd8);
        write_word(DESC_VADD+32, 32'd8);
        write_word(DESC_VADD+36, 32'd8);
        run_descriptor(DESC_VADD);
        for (row = 0; row < 2; row = row + 1) begin
            for (col = 0; col < 7; col = col + 1) begin
                expected = signed_byte(VADD_A + row*8 + col)
                         + signed_byte(VADD_B + row*8 + col);
                if (expected < 0) expected = 0;
                if (expected > 127) expected = 127;
                if (memory[VADD_C + row*8 + col] != expected) begin
                    $display("FAIL VADD row=%0d col=%0d expected=%0d got=%0d",
                             row, col, expected, memory[VADD_C + row*8 + col]);
                    $fatal(1);
                end
            end
            if (memory[VADD_C + row*8 + 7] != 8'haa) begin
                $display("FAIL VADD tail strobe row=%0d got=%h", row,
                         memory[VADD_C + row*8 + 7]);
                $fatal(1);
            end
        end

        // TinyViT 位置编码和残差更新所使用的多行原位加法。
        for (row = 0; row < 2; row = row + 1)
            for (col = 0; col < 8; col = col + 1) begin
                write_byte(VADD_A + row*8 + col, row*10 + col - 20);
                write_byte(VADD_B + row*8 + col, 30 - col*3);
            end
        clear_descriptor(DESC_VADD);
        write_word(DESC_VADD+0, `LSME_OP_VECTOR_ADD
            | (1 << (8+`LSME_FLAG_OUTPUT_INT8)));
        write_word(DESC_VADD+4, VADD_A | 32'ha0000000);
        write_word(DESC_VADD+8, VADD_B | 32'ha0000000);
        write_word(DESC_VADD+12, VADD_A | 32'ha0000000);
        write_word(DESC_VADD+20, {16'd8,16'd2});
        write_word(DESC_VADD+24, {16'd1,16'd0});
        write_word(DESC_VADD+28, 32'd8);
        write_word(DESC_VADD+32, 32'd8);
        write_word(DESC_VADD+36, 32'd8);
        run_descriptor(DESC_VADD);
        for (row = 0; row < 2; row = row + 1)
            for (col = 0; col < 8; col = col + 1) begin
                expected = (row*10 + col - 20) + (30 - col*3);
                if (expected > 127) expected = 127;
                if (expected < -128) expected = -128;
                if (signed_byte(VADD_A + row*8 + col) != expected) begin
                    $display("FAIL VADD in-place row=%0d col=%0d expected=%0d got=%0d",
                             row, col, expected,
                             signed_byte(VADD_A + row*8 + col));
                    $fatal(1);
                end
            end

        // 执行引擎级 RMSNorm：覆盖描述符解码、共享访存端口和行计数器。
        for (col = 0; col < 7; col = col + 1)
            write_byte(RMS_GAIN + col, col == 3 ? -64 : 45 + col*7);
        for (row = 0; row < 2; row = row + 1)
            for (col = 0; col < 7; col = col + 1)
                write_byte(RMS_SRC + row*8 + col, row*19 + col*23 - 70);
        clear_descriptor(DESC_RMS);
        write_word(DESC_RMS+0, `LSME_OP_RMSNORM
            | (1 << (8+`LSME_FLAG_OUTPUT_INT8)));
        write_word(DESC_RMS+4, RMS_SRC | 32'ha0000000);
        write_word(DESC_RMS+8, RMS_GAIN | 32'ha0000000);
        write_word(DESC_RMS+12, RMS_DST | 32'ha0000000);
        write_word(DESC_RMS+20, {16'd7,16'd2});
        write_word(DESC_RMS+24, {16'd1,16'd0});
        write_word(DESC_RMS+28, 32'd8);
        write_word(DESC_RMS+36, 32'd8);
        write_word(DESC_RMS+52, 32'h00000605);
        write_word(DESC_RMS+56, 32'h524e5442);
        run_descriptor(DESC_RMS);
        for (row = 0; row < 2; row = row + 1) begin
            sum_square = 0;
            for (col = 0; col < 7; col = col + 1) begin
                numerator = signed_byte(RMS_SRC + row*8 + col);
                sum_square = sum_square + numerator*numerator;
            end
            rms_value = integer_sqrt_ref(sum_square / 7);
            if (rms_value == 0) rms_value = 1;
            denominator = rms_value << 6;
            for (col = 0; col < 7; col = col + 1) begin
                numerator = signed_byte(RMS_SRC + row*8 + col)
                          * signed_byte(RMS_GAIN + col) * 32;
                magnitude = numerator < 0 ? -numerator : numerator;
                quotient = magnitude / denominator;
                remainder = magnitude % denominator;
                if (remainder * 2 >= denominator) quotient = quotient + 1;
                expected = numerator < 0 ? -quotient : quotient;
                if (expected > 127) expected = 127;
                if (expected < -128) expected = -128;
                if (signed_byte(RMS_DST + row*8 + col) != expected) begin
                    $display("FAIL RMS descriptor row=%0d col=%0d expected=%0d got=%0d",
                             row, col, expected,
                             signed_byte(RMS_DST + row*8 + col));
                    $fatal(1);
                end
            end
        end
        if (perf_rmsnorm_rows != 2 || user_tag != 32'h524e5442) begin
            $display("FAIL RMS counters rows=%0d tag=%h",
                     perf_rmsnorm_rows, user_tag);
            $fatal(1);
        end

        if (perf_descriptor_count != 5 || core_error != 0) begin
            $display("FAIL final counters descriptors=%0d core_error=%0d",
                     perf_descriptor_count, core_error);
            $fatal(1);
        end
        $display("PASS lsme_exec_engine tests=%0d descriptors=%0d direct_words=%0d",
                 tests, perf_descriptor_count, perf_direct_mem_words);
        $finish;
    end
endmodule
