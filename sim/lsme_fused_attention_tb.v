`timescale 1ns / 1ps

// 融合 Attention 的独立位精确回归。
// 用同一颗 lsme_softmax_core 生成 QK->Softmax->PV 分解路径的参考概率，
// 再逐字节比较融合核写出的 token-major context 和 64 点热图摘要。
module lsme_fused_attention_tb;
    reg clk = 1'b0;
    reg reset = 1'b1;
    reg start = 1'b0;
    wire busy;
    wire done;
    wire [7:0] error_code;

    localparam [31:0] Q_ADDR = 32'h00001000;
    localparam [31:0] K_ADDR = 32'h00002000;
    localparam [31:0] V_ADDR = 32'h00003000;
    localparam [31:0] C_ADDR = 32'h00004000;
    localparam [31:0] SUM_ADDR = 32'h00005000;

    wire mem_req_valid;
    wire mem_req_write;
    wire [31:0] mem_req_addr;
    wire [31:0] mem_req_wdata;
    wire [3:0] mem_req_wstrb;
    wire mem_req_ready = 1'b1;
    reg mem_rsp_valid = 1'b0;
    reg [31:0] mem_rsp_rdata = 32'd0;
    reg mem_rsp_error = 1'b0;

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
    wire [31:0] macro_tiles_completed;
    wire [31:0] softmax_rows_completed;
    wire [31:0] memory_words;

    reg [7:0] memory [0:65535];
    reg response_pending = 1'b0;
    reg pending_write = 1'b0;
    reg [31:0] pending_addr = 32'd0;
    reg [31:0] pending_wdata = 32'd0;
    reg [3:0] pending_wstrb = 4'd0;

    reg ref_start = 1'b0;
    reg [2047:0] ref_input = 2048'd0;
    wire ref_busy;
    wire ref_done;
    wire [511:0] ref_output;
    reg [7:0] reference_probability [0:3][0:63][0:63];

    integer h;
    integer q;
    integer k;
    integer d;
    integer score;
    integer expected;
    integer got;
    integer sum;
    integer cycles;
    integer tests = 0;

    always #5 clk = ~clk;

    lsme_fused_attention_core dut (
        .clk(clk), .reset(reset), .start(start), .busy(busy), .done(done),
        .error_code(error_code),
        .q_addr(Q_ADDR), .k_addr(K_ADDR), .v_addr(V_ADDR),
        .context_addr(C_ADDR), .attention_sum_addr(SUM_ADDR),
        .q_row_stride(32'd8), .kv_row_stride(32'd8),
        .context_row_stride(32'd32), .q_head_stride(32'd512),
        .kv_head_stride(32'd512), .context_head_offset(32'd8),
        .query_count(16'd64), .key_count(16'd64), .head_dim(16'd8),
        .head_count(16'd4), .score_shift(5'd6), .output_shift(5'd7),
        .mem_req_valid(mem_req_valid), .mem_req_ready(mem_req_ready),
        .mem_req_write(mem_req_write), .mem_req_addr(mem_req_addr),
        .mem_req_wdata(mem_req_wdata), .mem_req_wstrb(mem_req_wstrb),
        .mem_rsp_valid(mem_rsp_valid), .mem_rsp_rdata(mem_rsp_rdata),
        .mem_rsp_error(mem_rsp_error),
        .macro_start(macro_start), .macro_ready(macro_ready),
        .macro_first(macro_first), .macro_a_top(macro_a_top),
        .macro_a_bottom(macro_a_bottom), .macro_b_left(macro_b_left),
        .macro_b_right(macro_b_right), .macro_pred_a_top(macro_pred_a_top),
        .macro_pred_a_bottom(macro_pred_a_bottom),
        .macro_pred_b_left(macro_pred_b_left),
        .macro_pred_b_right(macro_pred_b_right), .macro_za_init(macro_za_init),
        .macro_busy(macro_busy), .macro_done(macro_done),
        .macro_za_out(macro_za_out),
        .macro_tiles_completed(macro_tiles_completed),
        .softmax_rows_completed(softmax_rows_completed),
        .memory_words(memory_words), .compute_active(), .memory_stall()
    );

    lsme_core #(.MOPA_LANES(64)) u_core (
        .clk(clk), .reset(reset), .req_valid(1'b0), .req_ready(),
        .req_command(3'd0), .req_imm(7'd0), .req_rj(32'd0), .req_rk(32'd0),
        .rsp_valid(), .rsp_rdata(), .mem_req_valid(), .mem_req_ready(1'b0),
        .mem_req_write(), .mem_req_addr(), .mem_req_wdata(), .mem_req_wstrb(),
        .mem_rsp_valid(1'b0), .mem_rsp_rdata(32'd0), .mem_rsp_error(1'b0),
        .macro_start(macro_start), .macro_ready(macro_ready),
        .macro_first(macro_first), .macro_a_top(macro_a_top),
        .macro_a_bottom(macro_a_bottom), .macro_b_left(macro_b_left),
        .macro_b_right(macro_b_right), .macro_pred_a_top(macro_pred_a_top),
        .macro_pred_a_bottom(macro_pred_a_bottom),
        .macro_pred_b_left(macro_pred_b_left),
        .macro_pred_b_right(macro_pred_b_right), .macro_za_init(macro_za_init),
        .macro_busy(macro_busy), .macro_done(macro_done),
        .macro_za_out(macro_za_out), .error_code(), .perf_mopa_count(),
        .perf_active_cycles(), .debug_za_sel(2'd0), .debug_za_elem(4'd0),
        .debug_za_data()
    );

    lsme_softmax_core u_reference_softmax (
        .clk(clk), .reset(reset), .start(ref_start), .count(7'd64),
        .score_shift(5'd6), .row_in(ref_input), .busy(ref_busy),
        .done(ref_done), .row_out(ref_output)
    );

    always @(posedge clk) begin
        mem_rsp_valid <= 1'b0;
        mem_rsp_error <= 1'b0;
        if (response_pending) begin
            mem_rsp_valid <= 1'b1;
            if (pending_write) begin
                if (pending_wstrb[0]) memory[pending_addr] <= pending_wdata[7:0];
                if (pending_wstrb[1]) memory[pending_addr + 1] <= pending_wdata[15:8];
                if (pending_wstrb[2]) memory[pending_addr + 2] <= pending_wdata[23:16];
                if (pending_wstrb[3]) memory[pending_addr + 3] <= pending_wdata[31:24];
                mem_rsp_rdata <= 32'd0;
            end
            else begin
                mem_rsp_rdata <= {memory[pending_addr + 3], memory[pending_addr + 2],
                                  memory[pending_addr + 1], memory[pending_addr]};
            end
            response_pending <= 1'b0;
        end
        if (!reset && mem_req_valid && mem_req_ready) begin
            response_pending <= 1'b1;
            pending_write <= mem_req_write;
            pending_addr <= mem_req_addr;
            pending_wdata <= mem_req_wdata;
            pending_wstrb <= mem_req_wstrb;
        end
    end

    function integer signed_byte;
        input [31:0] address;
        begin
            signed_byte = $signed(memory[address]);
        end
    endfunction

    function integer read_u32;
        input [31:0] address;
        reg [31:0] word_value;
        begin
            word_value = {memory[address + 3], memory[address + 2],
                          memory[address + 1], memory[address]};
            read_u32 = word_value;
        end
    endfunction

    function integer quantize_s8;
        input integer value;
        integer shifted;
        begin
            if (value < 0)
                shifted = -((-value + 64) / 128);
            else
                shifted = (value + 64) / 128;
            if (shifted > 127) quantize_s8 = 127;
            else if (shifted < -128) quantize_s8 = -128;
            else quantize_s8 = shifted;
        end
    endfunction

    task build_reference;
        begin
            for (h = 0; h < 4; h = h + 1) begin
                for (q = 0; q < 64; q = q + 1) begin
                    ref_input = 2048'd0;
                    for (k = 0; k < 64; k = k + 1) begin
                        score = 0;
                        for (d = 0; d < 8; d = d + 1)
                            score = score + signed_byte(Q_ADDR + h*512 + q*8 + d) *
                                            signed_byte(K_ADDR + h*512 + k*8 + d);
                        ref_input[k*32 +: 32] = score;
                    end
                    @(negedge clk);
                    ref_start = 1'b1;
                    @(negedge clk);
                    ref_start = 1'b0;
                    cycles = 0;
                    while (!ref_done && cycles < 1000) begin
                        @(negedge clk);
                        cycles = cycles + 1;
                    end
                    if (!ref_done) begin
                        $display("FAIL reference softmax timeout h=%0d q=%0d", h, q);
                        $fatal(1);
                    end
                    for (k = 0; k < 64; k = k + 1)
                        reference_probability[h][q][k] = ref_output[k*8 +: 8];
                end
            end
        end
    endtask

    task run_fused;
        begin
            @(negedge clk);
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;
            cycles = 0;
            while (!done && cycles < 250000) begin
                @(negedge clk);
                cycles = cycles + 1;
            end
            if (!done || error_code != 0) begin
                $display("FAIL fused attention timeout/error cycles=%0d error=%h state=%0d",
                         cycles, error_code, dut.state);
                $fatal(1);
            end
        end
    endtask

    initial begin
        for (q = 0; q < 65536; q = q + 1)
            memory[q] = 8'd0;
        repeat (5) @(negedge clk);
        reset = 1'b0;

        // 每个 head 都有不同的 Q/K/V，覆盖 batch/head 地址和 token-major 写回。
        for (h = 0; h < 4; h = h + 1)
            for (q = 0; q < 64; q = q + 1)
                for (d = 0; d < 8; d = d + 1) begin
                    memory[Q_ADDR + h*512 + q*8 + d] = ((h*71 + q*37 + d*19) % 255) - 127;
                    memory[K_ADDR + h*512 + q*8 + d] = ((h*43 + q*29 + d*53) % 255) - 127;
                    memory[V_ADDR + h*512 + q*8 + d] = -127;
                end

        build_reference();
        run_fused();

        if (macro_tiles_completed != 1024 || softmax_rows_completed != 256 ||
            memory_words != 2112) begin
            $display("FAIL fused counters macro=%0d softmax=%0d memory=%0d",
                     macro_tiles_completed, softmax_rows_completed, memory_words);
            $fatal(1);
        end

        for (q = 0; q < 64; q = q + 1)
            for (h = 0; h < 4; h = h + 1)
                for (d = 0; d < 8; d = d + 1) begin
                    sum = 0;
                    for (k = 0; k < 64; k = k + 1)
                        sum = sum + reference_probability[h][q][k] *
                                    signed_byte(V_ADDR + h*512 + k*8 + d);
                    expected = quantize_s8(sum);
                    got = signed_byte(C_ADDR + q*32 + h*8 + d);
                    if (got != expected) begin
                        $display("FAIL fused context h=%0d q=%0d d=%0d exp=%0d got=%0d",
                                 h, q, d, expected, got);
                        $fatal(1);
                    end
                end

        for (k = 0; k < 64; k = k + 1) begin
            sum = 0;
            for (h = 0; h < 4; h = h + 1)
                for (q = 0; q < 64; q = q + 1)
                    sum = sum + reference_probability[h][q][k];
            got = read_u32(SUM_ADDR + k*4);
            if (got != sum) begin
                $display("FAIL fused summary key=%0d exp=%0d got=%0d", k, sum, got);
                $fatal(1);
            end
        end
        tests = tests + 1;
        $display("PASS lsme_fused_attention tests=%0d cycles=%0d", tests, cycles);
        $finish;
    end
endmodule
