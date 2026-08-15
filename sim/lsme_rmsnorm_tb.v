`timescale 1ns / 1ps

module lsme_rmsnorm_tb;
    reg clk = 1'b0;
    reg reset = 1'b1;
    always #5 clk = ~clk;

    reg start;
    wire busy;
    wire done;
    wire [7:0] error_code;
    wire mem_req_valid;
    reg mem_req_ready;
    wire mem_req_write;
    wire [31:0] mem_req_addr;
    wire [31:0] mem_req_wdata;
    wire [3:0] mem_req_wstrb;
    reg mem_rsp_valid;
    reg [31:0] mem_rsp_rdata;
    reg mem_rsp_error;
    wire [31:0] rows_completed;
    wire [31:0] memory_words;
    wire compute_active;
    wire memory_stall;

    localparam SRC  = 32'h0000_0100;
    localparam GAIN = 32'h0000_0200;
    localparam DST  = 32'h0000_0300;
    localparam ROWS = 2;
    localparam COLS = 7;
    localparam BATCHES = 2;
    localparam ROW_STRIDE = 12;
    localparam BATCH_STRIDE = 32;

    reg [31:0] memory [0:511];
    reg response_pending;
    reg [31:0] response_data;
    integer i;
    integer b;
    integer r;
    integer c;
    integer sum_square;
    integer rms;
    integer denominator;
    integer numerator;
    integer magnitude;
    integer quotient;
    integer remainder;
    integer expected;
    integer cycles;

    lsme_rmsnorm_core dut (
        .clk(clk), .reset(reset), .start(start),
        .busy(busy), .done(done), .error_code(error_code),
        .src_addr(SRC), .gain_addr(GAIN), .dst_addr(DST),
        .rows(ROWS), .columns(COLS), .batch_count(BATCHES),
        .src_row_stride(ROW_STRIDE), .dst_row_stride(ROW_STRIDE),
        .src_batch_stride(BATCH_STRIDE),
        .dst_batch_stride(BATCH_STRIDE),
        .token_frac(8'd5), .gain_frac(8'd6),
        .mem_req_valid(mem_req_valid), .mem_req_ready(mem_req_ready),
        .mem_req_write(mem_req_write), .mem_req_addr(mem_req_addr),
        .mem_req_wdata(mem_req_wdata), .mem_req_wstrb(mem_req_wstrb),
        .mem_rsp_valid(mem_rsp_valid), .mem_rsp_rdata(mem_rsp_rdata),
        .mem_rsp_error(mem_rsp_error),
        .rows_completed(rows_completed), .memory_words(memory_words),
        .compute_active(compute_active), .memory_stall(memory_stall)
    );

    task set_byte;
        input [31:0] address;
        input [7:0] value;
        begin
            memory[address[10:2]][address[1:0]*8 +: 8] = value;
        end
    endtask

    function [7:0] get_byte;
        input [31:0] address;
        begin
            get_byte = memory[address[10:2]][address[1:0]*8 +: 8];
        end
    endfunction

    function integer integer_sqrt;
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
            integer_sqrt = result;
        end
    endfunction

    always @(posedge clk) begin
        mem_rsp_valid <= response_pending;
        mem_rsp_rdata <= response_data;
        mem_rsp_error <= 1'b0;
        response_pending <= 1'b0;

        if (mem_req_valid && mem_req_ready) begin
            response_pending <= 1'b1;
            response_data <= memory[mem_req_addr[10:2]];
            if (mem_req_write) begin
                for (i = 0; i < 4; i = i + 1)
                    if (mem_req_wstrb[i])
                        memory[mem_req_addr[10:2]][i*8 +: 8]
                            <= mem_req_wdata[i*8 +: 8];
            end
        end
    end

    initial begin
        start = 1'b0;
        mem_req_ready = 1'b1;
        mem_rsp_valid = 1'b0;
        mem_rsp_rdata = 32'd0;
        mem_rsp_error = 1'b0;
        response_pending = 1'b0;
        response_data = 32'd0;
        for (i = 0; i < 512; i = i + 1)
            memory[i] = 32'h0;

        // 增益包含正负值，用于覆盖符号组合、四舍五入与饱和路径。
        for (c = 0; c < COLS; c = c + 1)
            set_byte(GAIN + c, 8'(45 + c * 7));
        set_byte(GAIN + 3, -8'sd64);

        for (b = 0; b < BATCHES; b = b + 1)
            for (r = 0; r < ROWS; r = r + 1)
                for (c = 0; c < COLS; c = c + 1)
                    if (b == 1 && r == 1)
                        set_byte(SRC + b*BATCH_STRIDE + r*ROW_STRIDE + c,
                                 8'((c % 5) - 2));
                    else
                        set_byte(SRC + b*BATCH_STRIDE + r*ROW_STRIDE + c,
                                 8'((b*37 + r*19 + c*23) - 70));

        repeat (4) @(posedge clk);
        reset <= 1'b0;
        @(posedge clk);
        start <= 1'b1;
        @(posedge clk);
        start <= 1'b0;

        cycles = 0;
        while (!done && cycles < 20000) begin
            @(posedge clk);
            cycles = cycles + 1;
        end
        if (!done) begin
            $display("FAIL RMSNorm timeout");
            $finish(1);
        end
        if (error_code != 0 || rows_completed != ROWS*BATCHES) begin
            $display("FAIL RMSNorm status error=%02x rows=%0d",
                     error_code, rows_completed);
            $finish(1);
        end

        for (b = 0; b < BATCHES; b = b + 1) begin
            for (r = 0; r < ROWS; r = r + 1) begin
                sum_square = 0;
                for (c = 0; c < COLS; c = c + 1) begin
                    numerator = $signed(get_byte(
                        SRC + b*BATCH_STRIDE + r*ROW_STRIDE + c));
                    sum_square = sum_square + numerator*numerator;
                end
                rms = integer_sqrt(sum_square / COLS);
                if (rms == 0)
                    rms = 1;
                denominator = rms << 6;

                for (c = 0; c < COLS; c = c + 1) begin
                    numerator = $signed(get_byte(
                        SRC + b*BATCH_STRIDE + r*ROW_STRIDE + c)) *
                        $signed(get_byte(GAIN + c));
                    numerator = numerator << 5;
                    magnitude = numerator < 0 ? -numerator : numerator;
                    quotient = magnitude / denominator;
                    remainder = magnitude % denominator;
                    if (remainder * 2 >= denominator)
                        quotient = quotient + 1;
                    expected = numerator < 0 ? -quotient : quotient;
                    if (expected > 127)
                        expected = 127;
                    else if (expected < -128)
                        expected = -128;
                    if ($signed(get_byte(
                        DST + b*BATCH_STRIDE + r*ROW_STRIDE + c)) != expected) begin
                        $display("FAIL RMSNorm b=%0d r=%0d c=%0d got=%0d expected=%0d",
                            b, r, c,
                            $signed(get_byte(DST + b*BATCH_STRIDE +
                                             r*ROW_STRIDE + c)), expected);
                        $finish(1);
                    end
                end
            end
        end

        $display("PASS lsme_rmsnorm rows=%0d words=%0d cycles=%0d",
                 rows_completed, memory_words, cycles);
        $finish;
    end

endmodule
