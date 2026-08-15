`timescale 1ns / 1ps

module lsme_core_tb;
    parameter integer LANES = 64;

    reg clk = 0;
    reg reset = 1;
    reg req_valid = 0;
    wire req_ready;
    reg [2:0] req_command;
    reg [6:0] req_imm;
    reg [31:0] req_rj;
    reg [31:0] req_rk;
    wire rsp_valid;
    wire [31:0] rsp_rdata;

    wire mem_req_valid;
    reg mem_req_ready = 1;
    wire mem_req_write;
    wire [31:0] mem_req_addr;
    wire [31:0] mem_req_wdata;
    wire [3:0] mem_req_wstrb;
    reg mem_rsp_valid = 0;
    reg [31:0] mem_rsp_rdata = 0;
    reg mem_rsp_error = 0;

    wire [7:0] error_code;
    wire [31:0] perf_mopa_count;
    wire [31:0] perf_active_cycles;
    reg [1:0] debug_za_sel = 0;
    reg [3:0] debug_za_elem = 0;
    wire [31:0] debug_za_data;

    reg [31:0] memory [0:255];
    integer i;
    integer row;
    integer col;
    integer expected;
    integer got;
    integer cycles = 0;

    lsme_core #(.MOPA_LANES(LANES)) dut (
        .clk(clk), .reset(reset),
        .req_valid(req_valid), .req_ready(req_ready),
        .req_command(req_command), .req_imm(req_imm),
        .req_rj(req_rj), .req_rk(req_rk),
        .rsp_valid(rsp_valid), .rsp_rdata(rsp_rdata),
        .mem_req_valid(mem_req_valid), .mem_req_ready(mem_req_ready),
        .mem_req_write(mem_req_write), .mem_req_addr(mem_req_addr),
        .mem_req_wdata(mem_req_wdata), .mem_req_wstrb(mem_req_wstrb),
        .mem_rsp_valid(mem_rsp_valid), .mem_rsp_rdata(mem_rsp_rdata),
        .mem_rsp_error(mem_rsp_error),
        .macro_start(1'b0), .macro_ready(), .macro_first(1'b0),
        .macro_a_top(128'd0), .macro_a_bottom(128'd0),
        .macro_b_left(128'd0), .macro_b_right(128'd0),
        .macro_pred_a_top(16'd0), .macro_pred_a_bottom(16'd0),
        .macro_pred_b_left(16'd0), .macro_pred_b_right(16'd0),
        .macro_za_init(2048'd0), .macro_busy(), .macro_done(),
        .macro_za_out(),
        .error_code(error_code), .perf_mopa_count(perf_mopa_count),
        .perf_active_cycles(perf_active_cycles),
        .debug_za_sel(debug_za_sel), .debug_za_elem(debug_za_elem),
        .debug_za_data(debug_za_data)
    );

    always #10 clk = ~clk;

    always @(posedge clk) begin
        cycles <= cycles + 1;
        if (cycles > 2000) begin
            $display("TIMEOUT state=%0d word=%0d req=%b rsp=%b mem_req=%b mem_rsp=%b mopa_busy=%b",
                     dut.state, dut.word_index, req_valid, rsp_valid,
                     mem_req_valid, mem_rsp_valid, dut.mopa_busy);
            $fatal(1);
        end
    end

    always @(posedge clk) begin
        mem_rsp_valid <= 0;
        if (mem_req_valid && mem_req_ready) begin
            if (mem_req_write) begin
                memory[mem_req_addr[9:2]] <= mem_req_wdata;
                mem_rsp_valid <= 1;
            end
            else begin
                mem_rsp_rdata <= memory[mem_req_addr[9:2]];
                mem_rsp_valid <= 1;
            end
        end
    end

    task issue;
        input [2:0] cmd;
        input [6:0] imm;
        input [31:0] rj;
        input [31:0] rk;
        begin
            @(negedge clk);
            $display("ISSUE t=%0t cmd=%0d imm=%0d rj=%h rk=%h", $time, cmd, imm, rj, rk);
            while (!req_ready) @(negedge clk);
            req_command = cmd;
            req_imm = imm;
            req_rj = rj;
            req_rk = rk;
            req_valid = 1;
            @(negedge clk);
            req_valid = 0;
            while (!rsp_valid) @(negedge clk);
            $display("RSP   t=%0t cmd=%0d data=%h", $time, cmd, rsp_rdata);
        end
    endtask

    initial begin
        for (i = 0; i < 256; i = i + 1)
            memory[i] = 0;

        // Z0 包含四个行组：[1,2,3,4]、[5,6,7,8]……
        memory[0] = 32'h04030201;
        memory[1] = 32'h08070605;
        memory[2] = 32'h0c0b0a09;
        memory[3] = 32'h100f0e0d;

        // 0x40 处存放四个行主序行；转置 LDZ 后，Z1 得到四个列组：
        // [1,5,9,13]、[2,6,10,14]……
        memory[16] = 32'h04030201;
        memory[17] = 32'h08070605;
        memory[18] = 32'h0c0b0a09;
        memory[19] = 32'h100f0e0d;

        // 四行之间相隔 8 字节，按跨步方式装载且不转置。
        memory[32] = 32'h04030201;
        memory[34] = 32'h08070605;
        memory[36] = 32'h0c0b0a09;
        memory[38] = 32'h100f0e0d;

        // ZERO.BIAS 使用的四个 S32 bias。
        memory[48] = 32'd101;
        memory[49] = -32'sd22;
        memory[50] = 32'd303;
        memory[51] = -32'sd44;

        repeat (4) @(negedge clk);
        reset = 0;

        issue(3'd0, 7'd1, 0, 0);               // 开启 streaming 状态
        issue(3'd1, 7'b0000000, 32'h0, 0);     // 装载 Z0
        issue(3'd1, 7'b0001001, 32'h40, 32'd4);// 转置装载 Z1
        issue(3'd1, 7'b0000010, 32'h80, 32'd8);// 跨步装载 Z2
        if (dut.z_reg[2] !== 128'h100f0e0d_0c0b0a09_08070605_04030201) begin
            $display("FAIL strided LDZ got=%h", dut.z_reg[2]);
            $fatal(1);
        end
        issue(3'd2, 7'd0, 32'hffff, 0);         // P0 全部有效
        issue(3'd3, 7'b1000000, 32'hc0, 0);     // 将 bias 广播初始化到 ZA0
        for (row = 0; row < 4; row = row + 1) begin
            for (col = 0; col < 4; col = col + 1) begin
                debug_za_elem = row*4+col;
                #1;
                case (col)
                    0: expected = 101;
                    1: expected = -22;
                    2: expected = 303;
                    default: expected = -44;
                endcase
                if ($signed(debug_za_data) != expected) begin
                    $display("FAIL ZERO.BIAS row=%0d col=%0d expected=%0d got=%0d",
                             row, col, expected, $signed(debug_za_data));
                    $fatal(1);
                end
            end
        end
        issue(3'd3, 7'b0000001, 0, 0);         // 清零 ZA0
        issue(3'd4, 7'd0, 32'h00000008, 0);    // ZA0 += SMOPA(Z0,Z1,P0,P0)

        for (row = 0; row < 4; row = row + 1) begin
            for (col = 0; col < 4; col = col + 1) begin
                expected = 0;
                for (i = 0; i < 4; i = i + 1)
                    expected = expected + (row*4+i+1) * (i*4+col+1);
                debug_za_elem = row*4+col;
                #1;
                got = $signed(debug_za_data);
                if (got != expected) begin
                    $display("FAIL lanes=%0d row=%0d col=%0d expected=%0d got=%0d",
                             LANES, row, col, expected, got);
                    $fatal(1);
                end
            end
        end

        issue(3'd5, 7'd0, 32'h100, 32'd16); // 以 S32 格式存储 ZA
        for (i = 0; i < 16; i = i + 1) begin
            debug_za_elem = i;
            #1;
            if (memory[64+i] !== debug_za_data) begin
                $display("FAIL STZA index=%0d mem=%h za=%h", i, memory[64+i], debug_za_data);
                $fatal(1);
            end
        end

        if (perf_mopa_count != 1 || error_code != 0) begin
            $display("FAIL counters mopa=%0d error=%0d", perf_mopa_count, error_code);
            $fatal(1);
        end

        $display("PASS lsme_core lanes=%0d active_cycles=%0d", LANES, perf_active_cycles);
        $finish;
    end
endmodule
