`timescale 1ns / 1ps

module axi_dvi_xai_tb;
    reg clk = 0;
    reg resetn = 0;
    always #5 clk = ~clk;

    reg awvalid = 0;
    wire awready;
    reg [31:0] awaddr = 0;
    reg wvalid = 0;
    wire wready;
    reg [31:0] wdata = 0;
    reg [3:0] wstrb = 4'hf;
    reg bready = 1;
    wire bvalid;
    reg arvalid = 0;
    wire arready;
    reg [31:0] araddr = 0;
    wire rvalid;
    reg rready = 1;
    wire [31:0] rdata;
    wire [2:0] red;
    wire [2:0] green;
    wire [1:0] blue;
    wire [7:0] rgb = {red, green, blue};

    axi_dvi #(
        .HFP(801), .HSP(802), .HMAX(804),
        .VFP(601), .VSP(602), .VMAX(604),
        .SIMULATION(0)
    ) dut (
        .s_awvalid(awvalid), .s_awready(awready), .s_awaddr(awaddr),
        .s_awid(5'd0), .s_awlen(8'd0), .s_awsize(3'd2),
        .s_awburst(2'd1), .s_awlock(1'b0), .s_awcache(4'd0),
        .s_awprot(3'd0), .s_wvalid(wvalid), .s_wready(wready),
        .s_wdata(wdata), .s_wstrb(wstrb), .s_wlast(1'b1),
        .s_bvalid(bvalid), .s_bready(bready), .s_bid(), .s_bresp(),
        .s_arvalid(arvalid), .s_arready(arready), .s_araddr(araddr),
        .s_arid(5'd0), .s_arlen(8'd0), .s_arsize(3'd2),
        .s_arburst(2'd1), .s_arlock(1'b0), .s_arcache(4'd0),
        .s_arprot(3'd0), .s_rvalid(rvalid), .s_rready(rready),
        .s_rdata(rdata), .s_rid(), .s_rresp(), .s_rlast(),
        .video_clk(), .hsync(), .vsync(), .data_enable(),
        .video_red(red), .video_green(green), .video_blue(blue),
        .aclk(clk), .aresetn(resetn)
    );

    task axi_write;
        input [15:0] address;
        input [31:0] value;
        begin
            @(posedge clk);
            awaddr <= {16'hbf10, address};
            awvalid <= 1'b1;
            while (!awready)
                @(posedge clk);
            @(posedge clk);
            awvalid <= 1'b0;
            wdata <= value;
            wvalid <= 1'b1;
            while (!wready)
                @(posedge clk);
            @(posedge clk);
            wvalid <= 1'b0;
            while (!bvalid)
                @(posedge clk);
            @(posedge clk);
        end
    endtask

    task expect_pixel;
        input integer x;
        input integer y;
        input [7:0] expected;
        begin
            while (dut.hdata != x || dut.vdata != y)
                @(posedge clk);
            #1;
            if (rgb !== expected) begin
                $display("DVI pixel mismatch x=%0d y=%0d expected=%02x got=%02x",
                         x, y, expected, rgb);
                $fatal(1);
            end
        end
    endtask

    initial begin
        repeat (5) @(posedge clk);
        resetn <= 1'b1;
        axi_write(16'h0100, 32'hffffffff); // first four historical gray pixels
        axi_write(16'h0500, 32'h00000000); // low heat is blue
        axi_write(16'h053c, 32'hff000000); // heatmap cell 63 is high red
        axi_write(16'h0600, 32'h000000ff); // class zero has a full bar
        axi_write(16'h0010, 32'h00400001); // enable, predicted zero, 64 lanes

        expect_pixel(40, 24, 8'h1f);   // title font
        expect_pixel(60, 120, 8'hff);  // input image
        expect_pixel(326, 120, 8'h03); // heatmap blue endpoint
        expect_pixel(550, 344, 8'he0); // heatmap cell (7,7), right-bottom boundary
        expect_pixel(650, 130, 8'h1c); // selected class bar
        expect_pixel(115, 70, 8'h06);  // MOPA dataflow block, outside glyph
        expect_pixel(50, 580, 8'h1c);  // bottom PASS strip
        expect_pixel(700, 550, 8'h1c); // bit-exact/pass lamp
        // control[1] 将同一 8-bit 存储解释为原生 RGB332，而不是灰度。
        axi_write(16'h0100, 32'he3e3e3e3);
        axi_write(16'h0010, 32'h00400003);
        expect_pixel(60, 120, 8'he3);  // RGB332: red=7, green=0, blue=3
        axi_write(16'h0010, 32'h01400001); // status bit0: predicted/expected mismatch
        expect_pixel(50, 580, 8'he0);  // bottom FAIL strip
        $display("AXI_DVI_XAI_PASS");
        $finish;
    end
endmodule
