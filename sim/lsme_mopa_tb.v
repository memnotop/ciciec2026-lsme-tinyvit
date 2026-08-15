`timescale 1ns / 1ps

module lsme_mopa_tb;
    parameter integer LANES = 64;

    reg clk = 1'b0;
    reg reset = 1'b1;
    reg start = 1'b0;
    reg [127:0] zn;
    reg [127:0] zm;
    reg [15:0] pred_n;
    reg [15:0] pred_m;
    reg [511:0] za_in;
    wire busy;
    wire done;
    wire [511:0] za_out;

    integer test_id;
    integer row;
    integer col;
    integer k;
    integer idx;
    integer seed;
    integer expected;
    integer got;
    reg signed [7:0] av;
    reg signed [7:0] bv;

    lsme_mopa_core #(.MOPA_LANES(LANES)) dut (
        .clk(clk),
        .reset(reset),
        .start(start),
        .zn(zn),
        .zm(zm),
        .pred_n(pred_n),
        .pred_m(pred_m),
        .za_in(za_in),
        .busy(busy),
        .done(done),
        .za_out(za_out)
    );

    always #10 clk = ~clk;

    task run_case;
        begin
            @(negedge clk);
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;
            while (!done)
                @(negedge clk);

            for (row = 0; row < 4; row = row + 1) begin
                for (col = 0; col < 4; col = col + 1) begin
                    expected = $signed(za_in[(row*4+col)*32 +: 32]);
                    for (k = 0; k < 4; k = k + 1) begin
                        av = $signed(zn[(row*4+k)*8 +: 8]);
                        bv = $signed(zm[(col*4+k)*8 +: 8]);
                        if (pred_n[row*4+k] && pred_m[col*4+k])
                            expected = expected + av * bv;
                    end
                    got = $signed(za_out[(row*4+col)*32 +: 32]);
                    if (got !== expected) begin
                        $display("FAIL lanes=%0d test=%0d row=%0d col=%0d expected=%0d got=%0d",
                                 LANES, test_id, row, col, expected, got);
                        $fatal(1);
                    end
                end
            end
        end
    endtask

    initial begin
        zn = 128'd0;
        zm = 128'd0;
        pred_n = 16'hffff;
        pred_m = 16'hffff;
        za_in = 512'd0;
        seed = 32'h51a7c0de;

        repeat (4) @(negedge clk);
        reset = 1'b0;

        test_id = 0;
        run_case();

        test_id = 1;
        for (idx = 0; idx < 16; idx = idx + 1) begin
            zn[idx*8 +: 8] = 8'h7f;
            zm[idx*8 +: 8] = 8'h80;
            za_in[idx*32 +: 32] = idx - 8;
        end
        run_case();

        for (test_id = 2; test_id < 202; test_id = test_id + 1) begin
            for (idx = 0; idx < 16; idx = idx + 1) begin
                zn[idx*8 +: 8] = $random(seed);
                zm[idx*8 +: 8] = $random(seed);
                za_in[idx*32 +: 32] = $random(seed);
            end
            pred_n = $random(seed);
            pred_m = $random(seed);
            run_case();
        end

        $display("PASS lsme_mopa lanes=%0d tests=%0d", LANES, test_id);
        $finish;
    end
endmodule
