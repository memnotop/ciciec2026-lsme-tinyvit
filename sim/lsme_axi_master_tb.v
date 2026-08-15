`timescale 1ns / 1ps

module lsme_axi_master_tb;
    reg clk = 0;
    reg reset = 1;

    reg req_valid = 0;
    wire req_ready;
    reg req_write = 0;
    reg [31:0] req_addr = 0;
    reg [31:0] req_wdata = 0;
    reg [3:0] req_wstrb = 0;
    wire rsp_valid;
    wire [31:0] rsp_rdata;
    wire rsp_error;

    wire [3:0] m_arid;
    wire [31:0] m_araddr;
    wire [7:0] m_arlen;
    wire [2:0] m_arsize;
    wire [1:0] m_arburst;
    wire m_arlock;
    wire [3:0] m_arcache;
    wire [2:0] m_arprot;
    wire m_arvalid;
    reg m_arready = 0;
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
    reg m_awready = 0;
    wire [3:0] m_wid;
    wire [31:0] m_wdata;
    wire [3:0] m_wstrb;
    wire m_wlast;
    wire m_wvalid;
    reg m_wready = 0;
    reg [3:0] m_bid = 0;
    reg [1:0] m_bresp = 0;
    reg m_bvalid = 0;
    wire m_bready;

    integer tests = 0;

    lsme_axi_master dut (
        .clk(clk), .reset(reset),
        .req_valid(req_valid), .req_ready(req_ready),
        .req_write(req_write), .req_addr(req_addr),
        .req_wdata(req_wdata), .req_wstrb(req_wstrb),
        .rsp_valid(rsp_valid), .rsp_rdata(rsp_rdata),
        .rsp_error(rsp_error),
        .burst_cmd_valid(1'b0), .burst_cmd_ready(),
        .burst_cmd_write(1'b0), .burst_cmd_addr(32'd0),
        .burst_cmd_beats(4'd1), .burst_w_valid(1'b0),
        .burst_w_ready(), .burst_wdata(32'd0),
        .burst_wstrb(4'd0), .burst_r_valid(),
        .burst_r_ready(1'b0), .burst_rdata(), .burst_rlast(),
        .burst_rresp(), .burst_done(), .burst_error(),
        .burst_busy(), .perf_read_beat(), .perf_write_beat(),
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

    task issue_request;
        input write_value;
        input [31:0] address_value;
        input [31:0] data_value;
        input [3:0] strobe_value;
        begin
            @(negedge clk);
            while (!req_ready)
                @(negedge clk);
            req_write = write_value;
            req_addr = address_value;
            req_wdata = data_value;
            req_wstrb = strobe_value;
            req_valid = 1;
            @(negedge clk);
            req_valid = 0;
            if (req_ready) begin
                $display("FAIL request did not leave idle");
                $fatal(1);
            end
        end
    endtask

    task finish_read;
        input [31:0] data_value;
        input [3:0] id_value;
        input [1:0] response_value;
        input last_value;
        input expected_error;
        begin
            repeat (2) @(negedge clk);
            if (!m_rready) begin
                $display("FAIL RREADY missing");
                $fatal(1);
            end
            m_rdata = data_value;
            m_rid = id_value;
            m_rresp = response_value;
            m_rlast = last_value;
            m_rvalid = 1;
            @(negedge clk);
            m_rvalid = 0;
            if (!rsp_valid || rsp_rdata !== data_value ||
                rsp_error !== expected_error) begin
                $display("FAIL read response valid=%b data=%h error=%b",
                         rsp_valid, rsp_rdata, rsp_error);
                $fatal(1);
            end
            @(negedge clk);
            if (!req_ready || rsp_valid) begin
                $display("FAIL read completion pulse/idle");
                $fatal(1);
            end
            tests = tests + 1;
        end
    endtask

    task finish_write;
        input [3:0] id_value;
        input [1:0] response_value;
        input expected_error;
        begin
            repeat (2) @(negedge clk);
            if (!m_bready) begin
                $display("FAIL BREADY missing");
                $fatal(1);
            end
            m_bid = id_value;
            m_bresp = response_value;
            m_bvalid = 1;
            @(negedge clk);
            m_bvalid = 0;
            if (!rsp_valid || rsp_error !== expected_error) begin
                $display("FAIL write response valid=%b error=%b",
                         rsp_valid, rsp_error);
                $fatal(1);
            end
            @(negedge clk);
            if (!req_ready || rsp_valid) begin
                $display("FAIL write completion pulse/idle");
                $fatal(1);
            end
            tests = tests + 1;
        end
    endtask

    initial begin
        repeat (4) @(negedge clk);
        reset = 0;

        // 从机施加反压期间，读地址必须保持稳定。
        issue_request(0, 32'h1c001234, 0, 0);
        repeat (3) begin
            @(negedge clk);
            if (!m_arvalid || m_araddr !== 32'h1c001234 ||
                m_arid != 4'h2 || m_arlen != 0 || m_arsize != 3'b010 ||
                m_arburst != 2'b01) begin
                $display("FAIL read address channel");
                $fatal(1);
            end
        end
        m_arready = 1;
        @(negedge clk);
        m_arready = 0;
        finish_read(32'hcafef00d, 4'h2, 2'b00, 1, 0);

        // 非法读请求或读响应错误必须上报给请求方。
        issue_request(0, 32'h1c005678, 0, 0);
        m_arready = 1;
        @(negedge clk);
        m_arready = 0;
        finish_read(32'hdeadbeef, 4'h3, 2'b10, 0, 1);

        // 写事务先发送寄存化地址阶段，再发送数据阶段。
        issue_request(1, 32'h1c008000, 32'h11223344, 4'b1010);
        if (!m_awvalid || m_wvalid || m_awaddr !== 32'h1c008000 ||
            m_awlen != 0) begin
            $display("FAIL write address phase");
            $fatal(1);
        end
        m_awready = 1;
        @(negedge clk);
        m_awready = 0;
        if (!m_wvalid || m_wdata !== 32'h11223344 ||
            m_wstrb != 4'b1010 || !m_wlast) begin
            $display("FAIL write data phase");
            $fatal(1);
        end
        m_wready = 1;
        @(negedge clk);
        m_wready = 0;
        finish_write(4'h2, 2'b00, 0);

        // 第二次写事务用于检查 BRESP/BID 错误传播。
        issue_request(1, 32'h1c009000, 32'h55667788, 4'b1111);
        if (!m_awvalid || m_awaddr !== 32'h1c009000) begin
            $display("FAIL second write address");
            $fatal(1);
        end
        m_awready = 1;
        @(negedge clk);
        m_awready = 0;
        if (!m_wvalid || m_wdata !== 32'h55667788 || !m_wlast) begin
            $display("FAIL second write data");
            $fatal(1);
        end
        m_wready = 1;
        @(negedge clk);
        m_wready = 0;
        finish_write(4'h7, 2'b10, 1);

        $display("PASS lsme_axi_master tests=%0d", tests);
        $finish;
    end
endmodule
