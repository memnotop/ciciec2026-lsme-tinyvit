`timescale 1ns / 1ps

module axi2sram_sp_external_tb;
    reg clk = 0;
    reg resetn = 0;
    reg [31:0] araddr = 0;
    reg [7:0] arlen = 0;
    reg arvalid = 0;
    wire arready;
    reg [31:0] awaddr = 0;
    reg [7:0] awlen = 0;
    reg awvalid = 0;
    wire awready;
    reg [31:0] wdata = 0;
    reg [3:0] wstrb = 4'hf;
    reg wlast = 0;
    reg wvalid = 0;
    wire wready;
    wire [31:0] rdata;
    wire rlast;
    wire rvalid;
    reg rready = 0;
    wire bvalid;
    reg bready = 1;
    wire req;
    wire we;
    wire [31:0] addr;
    wire [3:0] be;
    wire [31:0] data_o;
    wire [31:0] data_i;
    reg [31:0] memory [0:255];
    integer i;
    integer seen;

    always #5 clk = ~clk;
    assign data_i = memory[addr[9:2]];

    always @(posedge clk)
        if (req && we) begin
            if (be[0]) memory[addr[9:2]][7:0] <= data_o[7:0];
            if (be[1]) memory[addr[9:2]][15:8] <= data_o[15:8];
            if (be[2]) memory[addr[9:2]][23:16] <= data_o[23:16];
            if (be[3]) memory[addr[9:2]][31:24] <= data_o[31:24];
        end

    axi2sram_sp_external dut (
        .clk(clk), .resetn(resetn),
        .s_araddr(araddr), .s_arburst(2'b01), .s_arcache(4'd0),
        .s_arid(5'h12), .s_arlen(arlen), .s_arlock(1'b0),
        .s_arprot(3'd0), .s_arready(arready), .s_arsize(3'b010),
        .s_arvalid(arvalid),
        .s_awaddr(awaddr), .s_awburst(2'b01), .s_awcache(4'd0),
        .s_awid(5'h13), .s_awlen(awlen), .s_awlock(1'b0),
        .s_awprot(3'd0), .s_awready(awready), .s_awsize(3'b010),
        .s_awvalid(awvalid),
        .s_bid(), .s_bready(bready), .s_bresp(), .s_bvalid(bvalid),
        .s_rdata(rdata), .s_rid(), .s_rlast(rlast), .s_rready(rready),
        .s_rresp(), .s_rvalid(rvalid),
        .s_wdata(wdata), .s_wlast(wlast), .s_wready(wready),
        .s_wstrb(wstrb), .s_wvalid(wvalid),
        .req_o(req), .we_o(we), .addr_o(addr), .be_o(be),
        .data_o(data_o), .data_i(data_i)
    );

    initial begin
        for (i = 0; i < 256; i = i + 1)
            memory[i] = 32'h10000000 + i;
        repeat (4) @(negedge clk);
        resetn = 1;

        @(negedge clk);
        araddr = 32'h40;
        arlen = 3;
        arvalid = 1;
        while (!arready) @(negedge clk);
        @(negedge clk);
        arvalid = 0;
        rready = 1;
        seen = 0;
        while (seen < 4) begin
            if (rvalid) begin
                if (rdata != 32'h10000010 + seen ||
                    rlast != (seen == 3)) begin
                    $display("FAIL SRAM read beat=%0d data=%h last=%b",
                             seen, rdata, rlast);
                    $fatal(1);
                end
                seen = seen + 1;
            end
            @(negedge clk);
        end

        @(negedge clk);
        awaddr = 32'h80;
        awlen = 3;
        awvalid = 1;
        while (!awready) @(negedge clk);
        @(negedge clk);
        awvalid = 0;
        for (i = 0; i < 4; i = i + 1) begin
            while (!wready) @(negedge clk);
            wdata = 32'habc00000 + i;
            wlast = i == 3;
            wvalid = 1;
            @(negedge clk);
            wvalid = 0;
        end
        while (!bvalid) @(negedge clk);
        @(negedge clk);
        for (i = 0; i < 4; i = i + 1)
            if (memory[8'h20+i] != 32'habc00000+i) begin
                $display("FAIL SRAM write beat=%0d data=%h",
                         i, memory[8'h20+i]);
                $fatal(1);
            end

        $display("PASS axi2sram_sp_external burst read/write");
        $finish;
    end
endmodule
