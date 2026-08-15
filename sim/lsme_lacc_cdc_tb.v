`timescale 1ns / 1ps

module lsme_lacc_cdc_tb;
    reg src_clk = 0;
    reg dst_clk = 0;
    reg src_reset = 1;
    reg dst_reset = 1;
    reg src_req_valid = 0;
    wire src_req_ready;
    reg [2:0] src_req_command = 0;
    reg [6:0] src_req_imm = 0;
    reg [31:0] src_req_rj = 0;
    reg [31:0] src_req_rk = 0;
    wire src_rsp_valid;
    wire [31:0] src_rsp_rdata;
    wire dst_req_valid;
    reg dst_req_ready = 1;
    wire [2:0] dst_req_command;
    wire [6:0] dst_req_imm;
    wire [31:0] dst_req_rj;
    wire [31:0] dst_req_rk;
    reg dst_rsp_valid = 0;
    reg [31:0] dst_rsp_rdata = 0;
    reg [2:0] response_delay = 0;
    reg response_pending = 0;
    integer test_count = 0;
    integer cycles;
    reg [31:0] expected;

    lsme_lacc_cdc dut (
        .src_clk(src_clk), .src_reset(src_reset),
        .src_req_valid(src_req_valid), .src_req_ready(src_req_ready),
        .src_req_command(src_req_command), .src_req_imm(src_req_imm),
        .src_req_rj(src_req_rj), .src_req_rk(src_req_rk),
        .src_rsp_valid(src_rsp_valid), .src_rsp_rdata(src_rsp_rdata),
        .dst_clk(dst_clk), .dst_reset(dst_reset),
        .dst_req_valid(dst_req_valid), .dst_req_ready(dst_req_ready),
        .dst_req_command(dst_req_command), .dst_req_imm(dst_req_imm),
        .dst_req_rj(dst_req_rj), .dst_req_rk(dst_req_rk),
        .dst_rsp_valid(dst_rsp_valid), .dst_rsp_rdata(dst_rsp_rdata)
    );

    always #10 src_clk = ~src_clk;
    always #7 dst_clk = ~dst_clk;

    always @(posedge dst_clk) begin
        dst_rsp_valid <= 0;
        if (dst_req_valid && dst_req_ready) begin
            dst_rsp_rdata <= dst_req_rj ^ dst_req_rk
                           ^ {22'd0, dst_req_command, dst_req_imm};
            response_delay <= (dst_req_command & 3) + 1;
            response_pending <= 1;
        end
        else if (response_pending) begin
            if (response_delay == 0) begin
                dst_rsp_valid <= 1;
                response_pending <= 0;
            end
            else
                response_delay <= response_delay - 1;
        end
    end

    task issue;
        input [2:0] command_value;
        input [6:0] imm_value;
        input [31:0] rj_value;
        input [31:0] rk_value;
        begin
            expected = rj_value ^ rk_value ^ {22'd0, command_value, imm_value};
            @(negedge src_clk);
            while (!src_req_ready) @(negedge src_clk);
            src_req_command = command_value;
            src_req_imm = imm_value;
            src_req_rj = rj_value;
            src_req_rk = rk_value;
            src_req_valid = 1;
            @(negedge src_clk);
            src_req_valid = 0;
            cycles = 0;
            while (!src_rsp_valid && cycles < 100) begin
                @(negedge src_clk);
                cycles = cycles + 1;
            end
            if (!src_rsp_valid || src_rsp_rdata !== expected) begin
                $display("FAIL CDC test=%0d expected=%h got=%h valid=%b",
                         test_count, expected, src_rsp_rdata, src_rsp_valid);
                $fatal(1);
            end
            test_count = test_count + 1;
        end
    endtask

    initial begin
        repeat (5) @(negedge src_clk);
        src_reset = 0;
        repeat (3) @(negedge dst_clk);
        dst_reset = 0;

        issue(0, 0, 32'h12345678, 32'h01020304);
        issue(7, 7'h7f, 32'hdeadbeef, 32'h55aa55aa);
        repeat (20) begin
            issue(test_count[2:0], (test_count*9) & 7'h7f,
                  32'h10000000 + test_count*32'h10203,
                  32'h80000000 - test_count*32'h30405);
        end

        $display("PASS lsme_lacc_cdc tests=%0d", test_count);
        $finish;
    end
endmodule
