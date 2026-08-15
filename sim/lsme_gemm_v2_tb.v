`timescale 1ns / 1ps

module lsme_gemm_v2_tb;
    reg clk = 0;
    reg reset = 1;
    reg start = 0;
    wire busy;
    wire done;
    wire [7:0] error_code;

    reg [31:0] src0_addr = 32'h1000;
    reg [31:0] src1_addr = 32'h2000;
    reg [31:0] dst_addr = 32'h3000;
    reg [31:0] bias_addr = 32'h4000;
    reg [15:0] m_dim = 8;
    reg [15:0] n_dim = 8;
    reg [15:0] k_dim = 8;
    reg [15:0] batch_dim = 1;
    reg [31:0] src0_row_stride = 8;
    reg [31:0] src1_row_stride = 8;
    reg [31:0] dst_row_stride = 8;
    reg [31:0] src0_batch_stride = 0;
    reg [31:0] src1_batch_stride = 0;
    reg [31:0] dst_batch_stride = 0;
    reg flag_trans_b = 0;
    reg flag_output_int8 = 1;
    reg flag_bias = 1;
    reg flag_relu = 0;
    reg [4:0] out_shift = 0;

    wire burst_cmd_valid;
    wire burst_cmd_ready;
    wire burst_cmd_write;
    wire [31:0] burst_cmd_addr;
    wire [3:0] burst_cmd_beats;
    wire burst_w_valid;
    wire burst_w_ready;
    wire [31:0] burst_wdata;
    wire [3:0] burst_wstrb;
    wire burst_r_valid;
    wire burst_r_ready;
    wire [31:0] burst_rdata;
    wire burst_rlast;
    wire [1:0] burst_rresp = 2'b00;
    reg burst_done = 0;
    reg burst_error = 0;

    wire macro_start;
    wire macro_ready;
    wire macro_first;
    wire [127:0] macro_a_top;
    wire [127:0] macro_a_bottom;
    wire [127:0] macro_b_left;
    wire [127:0] macro_b_right;
    wire [15:0] macro_pred_a_top;
    wire [15:0] macro_pred_a_bottom;
    wire [15:0] macro_pred_b_left;
    wire [15:0] macro_pred_b_right;
    wire [2047:0] macro_za_init;
    wire macro_busy;
    wire macro_done;
    wire [2047:0] macro_za_out;
    wire [31:0] tiles_completed;

    reg [7:0] memory [0:65535];
    reg transfer_active = 0;
    reg transfer_write = 0;
    reg [31:0] transfer_addr = 0;
    reg [3:0] transfer_beats = 0;
    reg [3:0] transfer_index = 0;

    wire core_req_ready;
    wire core_rsp_valid;
    wire [31:0] core_rsp_rdata;
    wire core_mem_req_valid;
    wire [7:0] core_error;
    wire [31:0] core_mopa_count;
    wire [31:0] core_active_cycles;

    integer row;
    integer col;
    integer kval;
    integer i;
    integer expected;
    integer got;
    integer tests = 0;
    integer cycles;

    assign burst_cmd_ready = !transfer_active;
    assign burst_w_ready = transfer_active && transfer_write;
    assign burst_r_valid = transfer_active && !transfer_write;
    assign burst_rdata = {memory[transfer_addr + transfer_index*4 + 3],
                          memory[transfer_addr + transfer_index*4 + 2],
                          memory[transfer_addr + transfer_index*4 + 1],
                          memory[transfer_addr + transfer_index*4]};
    assign burst_rlast = transfer_index + 1 == transfer_beats;

    always #5 clk = ~clk;

    lsme_gemm_v2 dut (
        .clk(clk), .reset(reset), .start(start),
        .busy(busy), .done(done), .error_code(error_code),
        .src0_addr(src0_addr), .src1_addr(src1_addr),
        .dst_addr(dst_addr), .bias_addr(bias_addr),
        .m_dim(m_dim), .n_dim(n_dim), .k_dim(k_dim),
        .batch_dim(batch_dim),
        .src0_row_stride(src0_row_stride),
        .src1_row_stride(src1_row_stride),
        .dst_row_stride(dst_row_stride),
        .src0_batch_stride(src0_batch_stride),
        .src1_batch_stride(src1_batch_stride),
        .dst_batch_stride(dst_batch_stride),
        .flag_trans_b(flag_trans_b),
        .flag_output_int8(flag_output_int8),
        .flag_bias(flag_bias), .flag_relu(flag_relu),
        .out_shift(out_shift),
        .burst_cmd_valid(burst_cmd_valid),
        .burst_cmd_ready(burst_cmd_ready),
        .burst_cmd_write(burst_cmd_write),
        .burst_cmd_addr(burst_cmd_addr),
        .burst_cmd_beats(burst_cmd_beats),
        .burst_w_valid(burst_w_valid),
        .burst_w_ready(burst_w_ready),
        .burst_wdata(burst_wdata), .burst_wstrb(burst_wstrb),
        .burst_r_valid(burst_r_valid),
        .burst_r_ready(burst_r_ready),
        .burst_rdata(burst_rdata), .burst_rlast(burst_rlast),
        .burst_rresp(burst_rresp),
        .burst_done(burst_done), .burst_error(burst_error),
        .macro_start(macro_start), .macro_ready(macro_ready),
        .macro_first(macro_first),
        .macro_a_top(macro_a_top),
        .macro_a_bottom(macro_a_bottom),
        .macro_b_left(macro_b_left),
        .macro_b_right(macro_b_right),
        .macro_pred_a_top(macro_pred_a_top),
        .macro_pred_a_bottom(macro_pred_a_bottom),
        .macro_pred_b_left(macro_pred_b_left),
        .macro_pred_b_right(macro_pred_b_right),
        .macro_za_init(macro_za_init),
        .macro_busy(macro_busy), .macro_done(macro_done),
        .macro_za_out(macro_za_out),
        .tiles_completed(tiles_completed),
        .compute_active(), .memory_stall()
    );

    lsme_core #(.MOPA_LANES(64)) u_core (
        .clk(clk), .reset(reset),
        .req_valid(1'b0), .req_ready(core_req_ready),
        .req_command(3'd0), .req_imm(7'd0),
        .req_rj(32'd0), .req_rk(32'd0),
        .rsp_valid(core_rsp_valid), .rsp_rdata(core_rsp_rdata),
        .mem_req_valid(core_mem_req_valid), .mem_req_ready(1'b0),
        .mem_req_write(), .mem_req_addr(), .mem_req_wdata(),
        .mem_req_wstrb(), .mem_rsp_valid(1'b0),
        .mem_rsp_rdata(32'd0), .mem_rsp_error(1'b0),
        .macro_start(macro_start), .macro_ready(macro_ready),
        .macro_first(macro_first),
        .macro_a_top(macro_a_top),
        .macro_a_bottom(macro_a_bottom),
        .macro_b_left(macro_b_left),
        .macro_b_right(macro_b_right),
        .macro_pred_a_top(macro_pred_a_top),
        .macro_pred_a_bottom(macro_pred_a_bottom),
        .macro_pred_b_left(macro_pred_b_left),
        .macro_pred_b_right(macro_pred_b_right),
        .macro_za_init(macro_za_init),
        .macro_busy(macro_busy), .macro_done(macro_done),
        .macro_za_out(macro_za_out),
        .error_code(core_error), .perf_mopa_count(core_mopa_count),
        .perf_active_cycles(core_active_cycles),
        .debug_za_sel(2'd0), .debug_za_elem(4'd0), .debug_za_data()
    );

    always @(posedge clk) begin
        burst_done <= 1'b0;
        burst_error <= 1'b0;
        if (reset) begin
            transfer_active <= 1'b0;
            transfer_write <= 1'b0;
            transfer_addr <= 32'd0;
            transfer_beats <= 4'd0;
            transfer_index <= 4'd0;
        end
        else begin
            if (burst_cmd_valid && burst_cmd_ready) begin
                transfer_active <= 1'b1;
                transfer_write <= burst_cmd_write;
                transfer_addr <= burst_cmd_addr;
                transfer_beats <= burst_cmd_beats;
                transfer_index <= 4'd0;
            end
            else if (burst_r_valid && burst_r_ready) begin
                if (transfer_index + 1 == transfer_beats) begin
                    transfer_active <= 1'b0;
                    burst_done <= 1'b1;
                end
                else
                    transfer_index <= transfer_index + 4'd1;
            end
            else if (burst_w_valid && burst_w_ready) begin
                if (burst_wstrb[0])
                    memory[transfer_addr + transfer_index*4] <= burst_wdata[7:0];
                if (burst_wstrb[1])
                    memory[transfer_addr + transfer_index*4 + 1] <= burst_wdata[15:8];
                if (burst_wstrb[2])
                    memory[transfer_addr + transfer_index*4 + 2] <= burst_wdata[23:16];
                if (burst_wstrb[3])
                    memory[transfer_addr + transfer_index*4 + 3] <= burst_wdata[31:24];
                if (transfer_index + 1 == transfer_beats) begin
                    transfer_active <= 1'b0;
                    burst_done <= 1'b1;
                end
                else
                    transfer_index <= transfer_index + 4'd1;
            end
        end
    end

    function integer signed_byte;
        input [31:0] address;
        begin
            signed_byte = $signed(memory[address]);
        end
    endfunction

    function integer read_s32;
        input [31:0] address;
        reg [31:0] value;
        begin
            value = {memory[address+3], memory[address+2],
                     memory[address+1], memory[address]};
            read_s32 = $signed(value);
        end
    endfunction

    task write_s32;
        input [31:0] address;
        input integer value;
        begin
            memory[address] = value[7:0];
            memory[address+1] = value[15:8];
            memory[address+2] = value[23:16];
            memory[address+3] = value[31:24];
        end
    endtask

    task run_engine;
        begin
            @(negedge clk);
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;
            cycles = 0;
            while (!done && cycles < 100000) begin
                @(negedge clk);
                cycles = cycles + 1;
            end
            if (!done || error_code != 0) begin
                $display("FAIL V2 timeout/error cycles=%0d error=%h state=%0d",
                         cycles, error_code, dut.state);
                $fatal(1);
            end
        end
    endtask

    initial begin
        for (row = 0; row < 65536; row = row + 1)
            memory[row] = 0;
        repeat (5) @(negedge clk);
        reset = 0;

        // 普通 K×N 布局的 B，INT8 输出，并广播 bias。
        for (row = 0; row < 8; row = row + 1)
            for (col = 0; col < 8; col = col + 1) begin
                memory[src0_addr + row*8 + col] = ((row*3+col) % 7)-3;
                memory[src1_addr + row*8 + col] = ((row-col+16) % 5)-2;
            end
        for (col = 0; col < 8; col = col + 1)
            write_s32(bias_addr + col*4, col-3);
        run_engine();
        if (tiles_completed != 1 || core_mopa_count != 8) begin
            $display("FAIL V2 counters tiles=%0d mopa=%0d",
                     tiles_completed, core_mopa_count);
            $fatal(1);
        end
        for (row = 0; row < 8; row = row + 1)
            for (col = 0; col < 8; col = col + 1) begin
                expected = col-3;
                for (kval = 0; kval < 8; kval = kval + 1)
                    expected = expected + signed_byte(src0_addr+row*8+kval) *
                                          signed_byte(src1_addr+kval*8+col);
                if (expected > 127) expected = 127;
                if (expected < -128) expected = -128;
                got = signed_byte(dst_addr+row*8+col);
                if (got != expected) begin
                    $display("FAIL V2 int8 r=%0d c=%0d exp=%0d got=%0d",
                             row, col, expected, got);
                    $fatal(1);
                end
            end
        tests = tests + 1;

        // 预转置为 N×K 的 B，输出 S32。
        dst_addr = 32'h5000;
        dst_row_stride = 32;
        flag_trans_b = 1;
        flag_output_int8 = 0;
        flag_bias = 0;
        for (row = 0; row < 8; row = row + 1)
            for (col = 0; col < 8; col = col + 1)
                memory[src1_addr + col*8 + row] = ((row-col+16) % 5)-2;
        run_engine();
        for (row = 0; row < 8; row = row + 1)
            for (col = 0; col < 8; col = col + 1) begin
                expected = 0;
                for (kval = 0; kval < 8; kval = kval + 1)
                    expected = expected + signed_byte(src0_addr+row*8+kval) *
                                          signed_byte(src1_addr+col*8+kval);
                got = read_s32(dst_addr+row*32+col*4);
                if (got != expected) begin
                    $display("FAIL V2 trans r=%0d c=%0d exp=%0d got=%0d",
                             row, col, expected, got);
                    $fatal(1);
                end
            end
        tests = tests + 1;

        // 分类器形状的尾块：M=4、N=12、K=32、S32+bias。
        src0_addr = 32'h6000;
        src1_addr = 32'h6800;
        dst_addr = 32'h7000;
        bias_addr = 32'h7800;
        m_dim = 4;
        n_dim = 12;
        k_dim = 32;
        src0_row_stride = 32;
        src1_row_stride = 12;
        dst_row_stride = 48;
        flag_trans_b = 0;
        flag_output_int8 = 0;
        flag_bias = 1;
        for (row = 0; row < 4; row = row + 1)
            for (kval = 0; kval < 32; kval = kval + 1)
                memory[src0_addr + row*32 + kval] = ((row+kval) % 9)-4;
        for (kval = 0; kval < 32; kval = kval + 1)
            for (col = 0; col < 12; col = col + 1)
                memory[src1_addr + kval*12 + col] =
                    ((kval*2-col+64) % 7)-3;
        for (col = 0; col < 12; col = col + 1)
            write_s32(bias_addr + col*4, col*3-7);
        run_engine();
        if (tiles_completed != 2) begin
            $display("FAIL V2 tail tile count=%0d", tiles_completed);
            $fatal(1);
        end
        for (row = 0; row < 4; row = row + 1)
            for (col = 0; col < 12; col = col + 1) begin
                expected = col*3-7;
                for (kval = 0; kval < 32; kval = kval + 1)
                    expected = expected + signed_byte(src0_addr+row*32+kval) *
                                          signed_byte(src1_addr+kval*12+col);
                got = read_s32(dst_addr+row*48+col*4);
                if (got != expected) begin
                    $display("FAIL V2 tail r=%0d c=%0d exp=%0d got=%0d",
                             row, col, expected, got);
                    $fatal(1);
                end
            end
        tests = tests + 1;

        // 两个相互独立的转置 batch，用于检查 batch 基地址推进。
        src0_addr = 32'h8000;
        src1_addr = 32'h8400;
        dst_addr = 32'h8800;
        m_dim = 8;
        n_dim = 8;
        k_dim = 8;
        batch_dim = 2;
        src0_row_stride = 8;
        src1_row_stride = 8;
        dst_row_stride = 32;
        src0_batch_stride = 64;
        src1_batch_stride = 64;
        dst_batch_stride = 256;
        flag_trans_b = 1;
        flag_output_int8 = 0;
        flag_bias = 0;
        for (i = 0; i < 2; i = i + 1)
            for (row = 0; row < 8; row = row + 1)
                for (col = 0; col < 8; col = col + 1) begin
                    memory[src0_addr+i*64+row*8+col] =
                        ((i+row*2+col) % 7)-3;
                    memory[src1_addr+i*64+col*8+row] =
                        ((i+row-col+16) % 5)-2;
                end
        run_engine();
        for (i = 0; i < 2; i = i + 1)
            for (row = 0; row < 8; row = row + 1)
                for (col = 0; col < 8; col = col + 1) begin
                    expected = 0;
                    for (kval = 0; kval < 8; kval = kval + 1)
                        expected = expected +
                            signed_byte(src0_addr+i*64+row*8+kval) *
                            signed_byte(src1_addr+i*64+col*8+kval);
                    got = read_s32(dst_addr+i*256+row*32+col*4);
                    if (got != expected) begin
                        $display("FAIL V2 batch=%0d r=%0d c=%0d exp=%0d got=%0d",
                                 i, row, col, expected, got);
                        $fatal(1);
                    end
                end
        tests = tests + 1;

        // 沿 N 方向融合的 QKV 形状，用于检查 96 列 B 缓存布局。
        src0_addr = 32'h9000;
        src1_addr = 32'ha000;
        dst_addr = 32'hb000;
        bias_addr = 32'hd000;
        m_dim = 64;
        n_dim = 96;
        k_dim = 32;
        batch_dim = 1;
        src0_row_stride = 32;
        src1_row_stride = 96;
        dst_row_stride = 96;
        src0_batch_stride = 0;
        src1_batch_stride = 0;
        dst_batch_stride = 0;
        flag_trans_b = 0;
        flag_output_int8 = 1;
        flag_bias = 1;
        for (row = 0; row < 64; row = row + 1)
            for (kval = 0; kval < 32; kval = kval + 1)
                memory[src0_addr+row*32+kval] = ((row+kval*2) % 7)-3;
        for (kval = 0; kval < 32; kval = kval + 1)
            for (col = 0; col < 96; col = col + 1)
                memory[src1_addr+kval*96+col] =
                    ((kval*3-col+192) % 9)-4;
        for (col = 0; col < 96; col = col + 1)
            write_s32(bias_addr+col*4, (col % 11)-5);
        run_engine();
        for (row = 0; row < 64; row = row + 1)
            for (col = 0; col < 96; col = col + 1) begin
                expected = (col % 11)-5;
                for (kval = 0; kval < 32; kval = kval + 1)
                    expected = expected + signed_byte(src0_addr+row*32+kval) *
                                          signed_byte(src1_addr+kval*96+col);
                if (expected > 127) expected = 127;
                if (expected < -128) expected = -128;
                got = signed_byte(dst_addr+row*96+col);
                if (got != expected) begin
                    $display("FAIL V2 QKV r=%0d c=%0d exp=%0d got=%0d",
                             row, col, expected, got);
                    $fatal(1);
                end
            end
        tests = tests + 1;

        $display("PASS lsme_gemm_v2 tests=%0d last_cycles=%0d",
                 tests, cycles);
        $finish;
    end
endmodule
