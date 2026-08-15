`timescale 1ns / 1ps
`include "lsme_defs.vh"

module lsme_top_tb;
    reg clk = 0;
    reg aresetn = 0;

    reg lacc_req_valid = 0;
    wire lacc_req_ready;
    reg [2:0] lacc_req_command = 0;
    reg [6:0] lacc_req_imm = 0;
    reg [31:0] lacc_req_rj = 0;
    reg [31:0] lacc_req_rk = 0;
    wire lacc_rsp_valid;
    wire [31:0] lacc_rsp_rdata;

    reg [4:0] s_awid = 0;
    reg [31:0] s_awaddr = 0;
    reg [7:0] s_awlen = 0;
    reg [2:0] s_awsize = 3'b010;
    reg [1:0] s_awburst = 2'b01;
    reg s_awlock = 0;
    reg [3:0] s_awcache = 0;
    reg [2:0] s_awprot = 0;
    reg s_awvalid = 0;
    wire s_awready;
    reg [31:0] s_wdata = 0;
    reg [3:0] s_wstrb = 0;
    reg s_wlast = 1;
    reg s_wvalid = 0;
    wire s_wready;
    wire [4:0] s_bid;
    wire [1:0] s_bresp;
    wire s_bvalid;
    reg s_bready = 1;
    reg [4:0] s_arid = 0;
    reg [31:0] s_araddr = 0;
    reg [7:0] s_arlen = 0;
    reg [2:0] s_arsize = 3'b010;
    reg [1:0] s_arburst = 2'b01;
    reg s_arlock = 0;
    reg [3:0] s_arcache = 0;
    reg [2:0] s_arprot = 0;
    reg s_arvalid = 0;
    wire s_arready;
    wire [4:0] s_rid;
    wire [31:0] s_rdata;
    wire [1:0] s_rresp;
    wire s_rlast;
    wire s_rvalid;
    reg s_rready = 1;

    wire [3:0] m_arid;
    wire [31:0] m_araddr;
    wire [7:0] m_arlen;
    wire [2:0] m_arsize;
    wire [1:0] m_arburst;
    wire m_arlock;
    wire [3:0] m_arcache;
    wire [2:0] m_arprot;
    wire m_arvalid;
    wire m_arready;
    reg [3:0] m_rid = 0;
    reg [31:0] m_rdata = 0;
    reg [1:0] m_rresp = 0;
    reg m_rlast = 0;
    reg m_rvalid = 0;
    wire m_rready;
    wire [3:0] m_awid;
    wire [31:0] m_awaddr;
    wire [7:0] m_awlen;
    wire [2:0] m_awsize;
    wire [1:0] m_awburst;
    wire m_awlock;
    wire [3:0] m_awcache;
    wire [2:0] m_awprot;
    wire m_awvalid;
    wire m_awready;
    wire [3:0] m_wid;
    wire [31:0] m_wdata;
    wire [3:0] m_wstrb;
    wire m_wlast;
    wire m_wvalid;
    wire m_wready;
    reg [3:0] m_bid = 0;
    reg [1:0] m_bresp = 0;
    reg m_bvalid = 0;
    wire m_bready;

    reg [7:0] memory [0:131071];
    reg read_active = 0;
    reg [31:0] read_addr_hold = 0;
    reg [7:0] read_len_hold = 0;
    reg [7:0] read_index = 0;
    reg [3:0] read_id_hold = 0;
    reg aw_hold = 0;
    reg [31:0] aw_addr_hold = 0;
    reg [3:0] aw_id_hold = 0;
    reg [7:0] aw_len_hold = 0;
    reg [7:0] write_index = 0;

    integer i;
    integer cycles;
    integer expected;
    integer got;
    integer row;
    integer col;
    integer kval;
    integer status_value;
    reg [31:0] read_value;

    localparam [31:0] CSR_BASE = 32'h1f300000;
    localparam [31:0] DESC_VADD = 32'h00001000;
    localparam [31:0] DESC_SOFT = 32'h00001100;
    localparam [31:0] VADD_A = 32'h00002000;
    localparam [31:0] VADD_B = 32'h00002100;
    localparam [31:0] VADD_C = 32'h00002200;
    localparam [31:0] SOFT_SRC = 32'h00003000;
    localparam [31:0] SOFT_DST = 32'h00003100;
    localparam [31:0] DESC_GEMM_V2 = 32'h00004000;
    localparam [31:0] GEMM_A = 32'h00005000;
    localparam [31:0] GEMM_B = 32'h00005100;
    localparam [31:0] GEMM_C = 32'h00005200;
    localparam [31:0] GEMM_BIAS = 32'h00005300;

    assign m_arready = !read_active && !m_rvalid;
    assign m_awready = !aw_hold && !m_bvalid;
    assign m_wready = aw_hold && !m_bvalid;

    lsme_top #(.MOPA_LANES(64)) dut (
        .clk(clk), .aresetn(aresetn),
        .lacc_req_valid(lacc_req_valid), .lacc_req_ready(lacc_req_ready),
        .lacc_req_command(lacc_req_command), .lacc_req_imm(lacc_req_imm),
        .lacc_req_rj(lacc_req_rj), .lacc_req_rk(lacc_req_rk),
        .lacc_rsp_valid(lacc_rsp_valid), .lacc_rsp_rdata(lacc_rsp_rdata),
        .s_awid(s_awid), .s_awaddr(s_awaddr), .s_awlen(s_awlen),
        .s_awsize(s_awsize), .s_awburst(s_awburst), .s_awlock(s_awlock),
        .s_awcache(s_awcache), .s_awprot(s_awprot),
        .s_awvalid(s_awvalid), .s_awready(s_awready),
        .s_wdata(s_wdata), .s_wstrb(s_wstrb), .s_wlast(s_wlast),
        .s_wvalid(s_wvalid), .s_wready(s_wready),
        .s_bid(s_bid), .s_bresp(s_bresp), .s_bvalid(s_bvalid),
        .s_bready(s_bready),
        .s_arid(s_arid), .s_araddr(s_araddr), .s_arlen(s_arlen),
        .s_arsize(s_arsize), .s_arburst(s_arburst), .s_arlock(s_arlock),
        .s_arcache(s_arcache), .s_arprot(s_arprot),
        .s_arvalid(s_arvalid), .s_arready(s_arready),
        .s_rid(s_rid), .s_rdata(s_rdata), .s_rresp(s_rresp),
        .s_rlast(s_rlast), .s_rvalid(s_rvalid), .s_rready(s_rready),
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

    always @(posedge clk) begin
        if (m_arvalid && m_arready) begin
            read_active <= 1'b1;
            read_addr_hold <= m_araddr;
            read_len_hold <= m_arlen;
            read_index <= 8'd0;
            read_id_hold <= m_arid;
        end
        if (read_active && !m_rvalid) begin
            m_rid <= read_id_hold;
            m_rdata <= read_word(read_addr_hold + {read_index, 2'b00});
            m_rresp <= 2'b00;
            m_rlast <= read_index == read_len_hold;
            m_rvalid <= 1'b1;
        end
        else if (m_rvalid && m_rready) begin
            m_rvalid <= 1'b0;
            if (m_rlast)
                read_active <= 1'b0;
            else
                read_index <= read_index + 8'd1;
        end

        if (m_awvalid && m_awready) begin
            aw_hold <= 1'b1;
            aw_addr_hold <= m_awaddr;
            aw_id_hold <= m_awid;
            aw_len_hold <= m_awlen;
            write_index <= 8'd0;
        end
        if (m_wvalid && m_wready) begin
            if (m_wstrb[0]) memory[aw_addr_hold + {write_index,2'b00}]
                <= m_wdata[7:0];
            if (m_wstrb[1]) memory[aw_addr_hold + {write_index,2'b00} + 1]
                <= m_wdata[15:8];
            if (m_wstrb[2]) memory[aw_addr_hold + {write_index,2'b00} + 2]
                <= m_wdata[23:16];
            if (m_wstrb[3]) memory[aw_addr_hold + {write_index,2'b00} + 3]
                <= m_wdata[31:24];
            if (m_wlast || write_index == aw_len_hold) begin
                m_bid <= aw_id_hold;
                m_bresp <= (m_wlast == (write_index == aw_len_hold))
                           ? 2'b00 : 2'b10;
                m_bvalid <= 1'b1;
                aw_hold <= 1'b0;
            end
            else
                write_index <= write_index + 8'd1;
        end
        if (m_bvalid && m_bready)
            m_bvalid <= 1'b0;
    end

    task csr_write;
        input [31:0] address;
        input [31:0] value;
        begin
            @(negedge clk);
            while (!s_awready || !s_wready) @(negedge clk);
            s_awid = 5'h0b;
            s_awaddr = address;
            s_awvalid = 1;
            s_wdata = value;
            s_wstrb = 4'b1111;
            s_wvalid = 1;
            @(negedge clk);
            s_awvalid = 0;
            s_wvalid = 0;
            while (!s_bvalid) @(negedge clk);
            if (s_bresp != 0 || s_bid != 5'h0b) begin
                $display("FAIL CSR write response addr=%h resp=%b id=%h",
                         address, s_bresp, s_bid);
                $fatal(1);
            end
            @(negedge clk);
        end
    endtask

    task csr_read;
        input [31:0] address;
        output [31:0] value;
        begin
            @(negedge clk);
            while (!s_arready) @(negedge clk);
            s_arid = 5'h0d;
            s_araddr = address;
            s_arvalid = 1;
            @(negedge clk);
            s_arvalid = 0;
            while (!s_rvalid) @(negedge clk);
            value = s_rdata;
            if (s_rresp != 0 || !s_rlast || s_rid != 5'h0d) begin
                $display("FAIL CSR read response addr=%h resp=%b id=%h",
                         address, s_rresp, s_rid);
                $fatal(1);
            end
            @(negedge clk);
        end
    endtask

    task lacc_issue;
        input [2:0] command_value;
        input [6:0] imm_value;
        input [31:0] rj_value;
        input [31:0] rk_value;
        output [31:0] response_value;
        begin
            @(negedge clk);
            while (!lacc_req_ready) @(negedge clk);
            lacc_req_command = command_value;
            lacc_req_imm = imm_value;
            lacc_req_rj = rj_value;
            lacc_req_rk = rk_value;
            lacc_req_valid = 1;
            @(negedge clk);
            lacc_req_valid = 0;
            cycles = 0;
            while (!lacc_rsp_valid && cycles < 5000) begin
                @(negedge clk);
                cycles = cycles + 1;
            end
            if (!lacc_rsp_valid) begin
                $display("FAIL LACC timeout command=%0d", command_value);
                $fatal(1);
            end
            response_value = lacc_rsp_rdata;
        end
    endtask

    initial begin
        for (i = 0; i < 131072; i = i + 1)
            memory[i] = 0;
        repeat (5) @(negedge clk);
        aresetn = 1;

        csr_read(CSR_BASE+0, read_value);
        if (read_value != 32'h4c534d45) begin
            $display("FAIL CSR ID got=%h", read_value);
            $fatal(1);
        end
        csr_read(CSR_BASE+4, read_value);
        if (read_value[23:16] != 8'd64) begin
            $display("FAIL CSR lanes got=%h", read_value);
            $fatal(1);
        end

        // 通过 MMIO 描述符启动的 INT8 向量加法。
        for (i = 0; i < 4; i = i + 1) begin
            memory[VADD_A+i] = (i*60-70) & 8'hff;
            memory[VADD_B+i] = (80-i*20) & 8'hff;
            memory[VADD_C+i] = 0;
        end
        for (i = 0; i < 16; i = i + 1)
            write_word(DESC_VADD+i*4, 0);
        write_word(DESC_VADD+0, `LSME_OP_VECTOR_ADD
            | (1 << (8+`LSME_FLAG_OUTPUT_INT8))
            | (1 << (8+`LSME_FLAG_RELU)));
        write_word(DESC_VADD+4, VADD_A | 32'ha0000000);
        write_word(DESC_VADD+8, VADD_B | 32'ha0000000);
        write_word(DESC_VADD+12, VADD_C | 32'ha0000000);
        write_word(DESC_VADD+20, {16'd4,16'd1});
        write_word(DESC_VADD+24, {16'd1,16'd0});
        write_word(DESC_VADD+28, 4);
        write_word(DESC_VADD+32, 4);
        write_word(DESC_VADD+36, 4);
        write_word(DESC_VADD+56, 32'h4d4d494f);
        csr_write(CSR_BASE+16, DESC_VADD | 32'ha0000000);
        csr_write(CSR_BASE+8, 1);
        cycles = 0;
        status_value = 0;
        while ((status_value & 2) == 0 && cycles < 200) begin
            csr_read(CSR_BASE+12, read_value);
            status_value = read_value;
            cycles = cycles + 1;
        end
        if ((status_value & 6) != 2) begin
            $display("FAIL MMIO status=%h", status_value);
            $fatal(1);
        end
        for (i = 0; i < 4; i = i + 1) begin
            expected = $signed(memory[VADD_A+i]) + $signed(memory[VADD_B+i]);
            if (expected < 0) expected = 0;
            if (expected > 127) expected = 127;
            if (memory[VADD_C+i] != expected) begin
                $display("FAIL MMIO VADD index=%0d expected=%0d got=%0d",
                         i, expected, memory[VADD_C+i]);
                $fatal(1);
            end
        end

        // V2 缓存式 8×8 GEMM，用于覆盖 AXI burst 和宏瓦片路径。
        for (row = 0; row < 8; row = row + 1)
            for (col = 0; col < 8; col = col + 1) begin
                memory[GEMM_A + row*8 + col] = ((row*3+col) % 7)-3;
                memory[GEMM_B + row*8 + col] = ((row-col+16) % 5)-2;
                memory[GEMM_C + row*8 + col] = 0;
            end
        for (col = 0; col < 8; col = col + 1)
            write_word(GEMM_BIAS + col*4, col-3);
        for (i = 0; i < 16; i = i + 1)
            write_word(DESC_GEMM_V2+i*4, 0);
        write_word(DESC_GEMM_V2+0, `LSME_OP_GEMM
            | (1 << (8+`LSME_FLAG_OUTPUT_INT8))
            | (1 << (8+`LSME_FLAG_BIAS)));
        write_word(DESC_GEMM_V2+4, GEMM_A | 32'ha0000000);
        write_word(DESC_GEMM_V2+8, GEMM_B | 32'ha0000000);
        write_word(DESC_GEMM_V2+12, GEMM_C | 32'ha0000000);
        write_word(DESC_GEMM_V2+16, GEMM_BIAS | 32'ha0000000);
        write_word(DESC_GEMM_V2+20, {16'd8,16'd8});
        write_word(DESC_GEMM_V2+24, {16'd1,16'd8});
        write_word(DESC_GEMM_V2+28, 32'd8);
        write_word(DESC_GEMM_V2+32, 32'd8);
        write_word(DESC_GEMM_V2+36, 32'd8);
        write_word(DESC_GEMM_V2+56, 32'h5632474d);
        write_word(DESC_GEMM_V2+60, 32'h56320000);
        lacc_issue(`LSME_CMD_EXEC, 0,
                   DESC_GEMM_V2 | 32'ha0000000, 0, read_value);
        lacc_issue(`LSME_CMD_WAIT, 0, 0, 0, read_value);
        if (read_value[7:0] != 0) begin
            $display("FAIL V2 wait error=%h", read_value);
            $fatal(1);
        end
        for (row = 0; row < 8; row = row + 1)
            for (col = 0; col < 8; col = col + 1) begin
                expected = col-3;
                for (kval = 0; kval < 8; kval = kval + 1)
                    expected = expected +
                        $signed(memory[GEMM_A+row*8+kval]) *
                        $signed(memory[GEMM_B+kval*8+col]);
                if (expected > 127) expected = 127;
                if (expected < -128) expected = -128;
                got = $signed(memory[GEMM_C+row*8+col]);
                if (got != expected) begin
                    $display("FAIL top V2 r=%0d c=%0d exp=%0d got=%0d",
                             row, col, expected, got);
                    $fatal(1);
                end
            end

        // 低级能力查询使用同一个自定义指令端点。
        lacc_issue(`LSME_CMD_CTRL, 0, 0, 0, read_value);
        if (read_value != 32'h024040bf) begin
            $display("FAIL LACC feature got=%h", read_value);
            $fatal(1);
        end

        // LACC EXEC 异步启动；LACC WAIT 阻塞到 Softmax 完成。
        write_word(SOFT_SRC+0, -32'sd16);
        write_word(SOFT_SRC+4, 32'sd0);
        write_word(SOFT_SRC+8, 32'sd16);
        write_word(SOFT_SRC+12, 32'sd32);
        for (i = 0; i < 16; i = i + 1)
            write_word(DESC_SOFT+i*4, 0);
        write_word(DESC_SOFT+0, `LSME_OP_SOFTMAX);
        write_word(DESC_SOFT+4, SOFT_SRC | 32'ha0000000);
        write_word(DESC_SOFT+12, SOFT_DST | 32'ha0000000);
        write_word(DESC_SOFT+20, {16'd4,16'd1});
        write_word(DESC_SOFT+24, {16'd1,16'd0});
        write_word(DESC_SOFT+28, 16);
        write_word(DESC_SOFT+36, 4);
        write_word(DESC_SOFT+52, 32'h00000100);
        lacc_issue(`LSME_CMD_EXEC, 0, DESC_SOFT | 32'ha0000000, 0, read_value);
        if (read_value != 0) begin
            $display("FAIL LACC EXEC response=%h", read_value);
            $fatal(1);
        end
        lacc_issue(`LSME_CMD_WAIT, 0, 0, 0, read_value);
        if (read_value != 0 || memory[SOFT_DST+3] <= memory[SOFT_DST]) begin
            $display("FAIL LACC WAIT/Softmax response=%h out=%h_%h_%h_%h",
                     read_value, memory[SOFT_DST+3], memory[SOFT_DST+2],
                     memory[SOFT_DST+1], memory[SOFT_DST]);
            $fatal(1);
        end

        csr_read(CSR_BASE+24, read_value);
        if (read_value != 3) begin
            $display("FAIL descriptor counter=%0d", read_value);
            $fatal(1);
        end

        $display("PASS lsme_top MMIO+LACC+AXI+V2 descriptors=%0d",
                 read_value);
        $finish;
    end
endmodule
