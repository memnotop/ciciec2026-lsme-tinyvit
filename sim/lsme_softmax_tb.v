`timescale 1ns / 1ps

module lsme_softmax_tb;
    reg clk = 0;
    reg reset = 1;
    reg start = 0;
    reg [6:0] count = 0;
    reg [4:0] score_shift = 0;
    reg [2047:0] row_in = 0;
    wire busy;
    wire done;
    wire [511:0] row_out;

    integer scores [0:63];
    integer exp_ref_buf [0:63];
    integer expected [0:63];
    integer test_count = 0;
    integer seed = 32'h13579bdf;
    integer i;
    integer n;
    integer max_value;
    integer delta;
    integer exp_sum;
    integer msb;
    integer mant;
    integer reciprocal;
    integer product;
    integer shift;
    integer rounded;
    integer cycles;

    lsme_softmax_core dut (
        .clk(clk),
        .reset(reset),
        .start(start),
        .count(count),
        .score_shift(score_shift),
        .row_in(row_in),
        .busy(busy),
        .done(done),
        .row_out(row_out)
    );

    always #5 clk = ~clk;

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

    task build_reference;
        input integer requested_count;
        input integer requested_shift;
        begin
            n = (requested_count == 0 || requested_count > 64)
                    ? 64 : requested_count;
            max_value = scores[0];
            for (i = 1; i < n; i = i + 1)
                if (scores[i] > max_value)
                    max_value = scores[i];

            exp_sum = 0;
            for (i = 0; i < n; i = i + 1) begin
                delta = (max_value - scores[i]) >>> requested_shift;
                if (delta < 0)
                    delta = 0;
                if (delta > 255)
                    delta = 255;
                exp_ref_buf[i] = exp_fraction(delta & 31) >> (delta >> 5);
                exp_sum = exp_sum + exp_ref_buf[i];
            end

            msb = 0;
            for (i = 0; i < 22; i = i + 1)
                if ((exp_sum >> i) != 0)
                    msb = i;
            if (msb >= 7)
                mant = exp_sum >> (msb - 7);
            else
                mant = exp_sum << (7 - msb);
            reciprocal = ((127 * 65536) + (mant >> 1)) / mant;
            shift = msb + 9;

            for (i = 0; i < n; i = i + 1) begin
                product = exp_ref_buf[i] * reciprocal;
                rounded = (product + (1 << (shift-1))) >> shift;
                expected[i] = rounded > 127 ? 127 : rounded;
            end
            for (i = n; i < 64; i = i + 1)
                expected[i] = 0;
        end
    endtask

    task run_case;
        input integer requested_count;
        input integer requested_shift;
        begin
            build_reference(requested_count, requested_shift);
            row_in = 0;
            for (i = 0; i < 64; i = i + 1)
                row_in[i*32 +: 32] = scores[i];

            @(negedge clk);
            count = requested_count;
            score_shift = requested_shift;
            start = 1;
            @(negedge clk);
            start = 0;

            cycles = 0;
            while (!done && cycles < 300) begin
                @(negedge clk);
                cycles = cycles + 1;
            end
            if (!done) begin
                $display("FAIL timeout test=%0d count=%0d", test_count,
                         requested_count);
                $fatal(1);
            end

            for (i = 0; i < 64; i = i + 1) begin
                if (row_out[i*8 +: 8] !== expected[i][7:0]) begin
                    $display("FAIL test=%0d count=%0d shift=%0d index=%0d score=%0d expected=%0d got=%0d",
                             test_count, requested_count, requested_shift, i,
                             scores[i], expected[i], row_out[i*8 +: 8]);
                    $fatal(1);
                end
            end
            test_count = test_count + 1;
        end
    endtask

    initial begin
        for (i = 0; i < 64; i = i + 1)
            scores[i] = 0;

        repeat (4) @(negedge clk);
        reset = 0;

        scores[0] = -123456;
        run_case(1, 0);

        for (i = 0; i < 64; i = i + 1)
            scores[i] = 77;
        run_case(64, 3);
        run_case(0, 3);

        for (i = 0; i < 64; i = i + 1)
            scores[i] = -2048;
        scores[17] = 2048;
        run_case(64, 2);

        repeat (100) begin
            for (i = 0; i < 64; i = i + 1) begin
                seed = seed * 1103515245 + 12345;
                scores[i] = (seed & 16'h3fff) - 8192;
            end
            seed = seed * 1103515245 + 12345;
            n = (seed & 6'h3f) + 1;
            seed = seed * 1103515245 + 12345;
            run_case(n, seed & 5'h0f);
        end

        $display("PASS lsme_softmax tests=%0d", test_count);
        $finish;
    end
endmodule
