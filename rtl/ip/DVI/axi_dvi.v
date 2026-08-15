`timescale 1ns / 1ps

(* use_dsp = "no" *) module axi_dvi #
(
    parameter WIDTH = 12,
    parameter HSIZE = 800,
    parameter HFP = 856,
    parameter HSP = 976,
    parameter HMAX = 1040,
    parameter VSIZE = 600,
    parameter VFP = 637,
    parameter VSP = 643,
    parameter VMAX = 666,
    parameter HSPP = 1,
    parameter VSPP = 1,
    parameter SIMULATION = 0
)
(
    input            s_awvalid,
    output           s_awready,
    input   [31:0]   s_awaddr,
    input   [4:0]    s_awid,
    input   [7:0]    s_awlen,
    input   [2:0]    s_awsize,
    input   [1:0]    s_awburst,
    input   [0:0]    s_awlock,
    input   [3:0]    s_awcache,
    input   [2:0]    s_awprot,
    input            s_wvalid,
    output reg       s_wready,
    input   [31:0]   s_wdata,
    input   [3:0]    s_wstrb,
    input            s_wlast,
    output reg       s_bvalid,
    input            s_bready,
    output  [4:0]    s_bid,
    output  [1:0]    s_bresp,
    input            s_arvalid,
    output           s_arready,
    input   [31:0]   s_araddr,
    input   [4:0]    s_arid,
    input   [7:0]    s_arlen,
    input   [2:0]    s_arsize,
    input   [1:0]    s_arburst,
    input   [0:0]    s_arlock,
    input   [3:0]    s_arcache,
    input   [2:0]    s_arprot,
    output reg       s_rvalid,
    input            s_rready,
    output reg [31:0] s_rdata,
    output  [4:0]    s_rid,
    output  [1:0]    s_rresp,
    output reg       s_rlast,

    output           video_clk,
    output           hsync,
    output           vsync,
    output           data_enable,
    output  [2:0]    video_red,
    output  [2:0]    video_green,
    output  [1:0]    video_blue,

    input            aclk,
    input            aresetn
);

    reg [31:0] DVI_RECT_DIR;
    reg [31:0] DVI_RECT_L_W;
    reg [31:0] DVI_SQU_DIR;
    reg [31:0] DVI_SQU_R;

    // TinyViT/XAI 仪表盘寄存器组。软件以打包的 32 位字写入三块存储区，
    // 光栅器异步读取它们，从而在不占用推理数据通路的情况下生成画面。
    reg [31:0] xai_control;
    reg [31:0] xai_cycles;
    reg [31:0] xai_mopa;
    reg [31:0] xai_tiles;
    reg [31:0] xai_descriptors;
    reg [31:0] xai_accuracy;
    reg [31:0] xai_test_index;
    // RGB332 输入预览为 32x32x8bit，正好占 1 KiB / 256 个 AXI word。
    // 旧灰度 ABI 仍只写前 784 B，并通过 control[1]=0 选择旧显示方式。
    reg [31:0] xai_image_words [0:255];
    reg [31:0] xai_heatmap_words [0:15];
    reg [31:0] xai_score_words [0:2];

    reg busy;
    reg write;
    reg R_or_W;

    wire ar_enter = s_arvalid & s_arready;
    wire r_retire = s_rvalid & s_rready & s_rlast;
    wire aw_enter = s_awvalid & s_awready;
    wire w_enter  = s_wvalid & s_wready & s_wlast;
    wire b_retire = s_bvalid & s_bready;

    assign s_arready = ~busy & (!R_or_W | !s_awvalid);
    assign s_awready = ~busy & ( R_or_W | !s_arvalid);

    always @(posedge aclk) begin
        if (!aresetn)
            busy <= 1'b0;
        else if (ar_enter | aw_enter)
            busy <= 1'b1;
        else if (r_retire | b_retire)
            busy <= 1'b0;
    end

    reg [4:0]  buf_id;
    reg [31:0] buf_addr;
    reg [7:0]  buf_len;
    reg [2:0]  buf_size;
    reg [1:0]  buf_burst;
    reg        buf_lock;
    reg [3:0]  buf_cache;
    reg [2:0]  buf_prot;

    always @(posedge aclk) begin
        if (!aresetn) begin
            R_or_W    <= 1'b0;
            buf_id    <= 5'd0;
            buf_addr  <= 32'd0;
            buf_len   <= 8'd0;
            buf_size  <= 3'd0;
            buf_burst <= 2'd0;
            buf_lock  <= 1'b0;
            buf_cache <= 4'd0;
            buf_prot  <= 3'd0;
        end
        else if (ar_enter | aw_enter) begin
            R_or_W    <= ar_enter;
            buf_id    <= ar_enter ? s_arid    : s_awid;
            buf_addr  <= ar_enter ? s_araddr  : s_awaddr;
            buf_len   <= ar_enter ? s_arlen   : s_awlen;
            buf_size  <= ar_enter ? s_arsize  : s_awsize;
            buf_burst <= ar_enter ? s_arburst : s_awburst;
            buf_lock  <= ar_enter ? s_arlock  : s_awlock;
            buf_cache <= ar_enter ? s_arcache : s_awcache;
            buf_prot  <= ar_enter ? s_arprot  : s_awprot;
        end
    end

    always @(posedge aclk) begin
        if (!aresetn)
            write <= 1'b0;
        else if (aw_enter)
            write <= 1'b1;
        else if (ar_enter)
            write <= 1'b0;
    end

    always @(posedge aclk) begin
        if (!aresetn)
            s_wready <= 1'b0;
        else if (aw_enter)
            s_wready <= 1'b1;
        else if (w_enter)
            s_wready <= 1'b0;
    end

    function [31:0] merge_strobe;
        input [31:0] old_value;
        input [31:0] new_value;
        input [3:0] strobe;
        integer lane;
        begin
            merge_strobe = old_value;
            for (lane = 0; lane < 4; lane = lane + 1)
                if (strobe[lane])
                    merge_strobe[lane*8 +: 8] = new_value[lane*8 +: 8];
        end
    endfunction

    reg [31:0] rdata_d;
    always @(*) begin
        rdata_d = 32'd0;
        case (buf_addr[15:0])
            16'h0000: rdata_d = DVI_RECT_DIR;
            16'h0004: rdata_d = DVI_RECT_L_W;
            16'h0008: rdata_d = DVI_SQU_DIR;
            16'h000c: rdata_d = DVI_SQU_R;
            16'h0010: rdata_d = xai_control;
            16'h0014: rdata_d = xai_cycles;
            16'h0018: rdata_d = xai_mopa;
            16'h001c: rdata_d = xai_tiles;
            16'h0020: rdata_d = xai_descriptors;
            16'h0024: rdata_d = xai_accuracy;
            16'h0028: rdata_d = xai_test_index;
            default: begin
                if (buf_addr[15:0] >= 16'h0100 &&
                    buf_addr[15:0] < 16'h0500)
                    rdata_d = xai_image_words[(buf_addr[15:0]-16'h0100) >> 2];
                else if (buf_addr[15:0] >= 16'h0500 &&
                         buf_addr[15:0] < 16'h0540)
                    rdata_d = xai_heatmap_words[(buf_addr[15:0]-16'h0500) >> 2];
                else if (buf_addr[15:0] >= 16'h0600 &&
                         buf_addr[15:0] < 16'h060c)
                    rdata_d = xai_score_words[(buf_addr[15:0]-16'h0600) >> 2];
            end
        endcase
    end

    always @(posedge aclk) begin
        if (!aresetn) begin
            s_rdata  <= 32'd0;
            s_rvalid <= 1'b0;
            s_rlast  <= 1'b0;
        end
        else if (busy & !write & !r_retire) begin
            s_rdata  <= rdata_d;
            s_rvalid <= 1'b1;
            s_rlast  <= 1'b1;
        end
        else if (r_retire) begin
            s_rvalid <= 1'b0;
            s_rlast  <= 1'b0;
        end
    end

    always @(posedge aclk) begin
        if (!aresetn)
            s_bvalid <= 1'b0;
        else if (w_enter)
            s_bvalid <= 1'b1;
        else if (b_retire)
            s_bvalid <= 1'b0;
    end

    assign s_rid   = buf_id;
    assign s_bid   = buf_id;
    assign s_bresp = 2'b00;
    assign s_rresp = 2'b00;

    always @(posedge aclk) begin
        if (!aresetn) begin
            DVI_RECT_DIR   <= 32'd0;
            DVI_RECT_L_W   <= 32'd0;
            DVI_SQU_DIR    <= 32'd0;
            DVI_SQU_R      <= 32'd0;
            xai_control    <= 32'd0;
            xai_cycles     <= 32'd0;
            xai_mopa       <= 32'd0;
            xai_tiles      <= 32'd0;
            xai_descriptors <= 32'd0;
            xai_accuracy   <= 32'd0;
            xai_test_index <= 32'd0;
        end
        else if (w_enter) begin
            case (buf_addr[15:0])
                16'h0000: DVI_RECT_DIR <= merge_strobe(DVI_RECT_DIR, s_wdata, s_wstrb);
                16'h0004: DVI_RECT_L_W <= merge_strobe(DVI_RECT_L_W, s_wdata, s_wstrb);
                16'h0008: DVI_SQU_DIR <= merge_strobe(DVI_SQU_DIR, s_wdata, s_wstrb);
                16'h000c: DVI_SQU_R <= merge_strobe(DVI_SQU_R, s_wdata, s_wstrb);
                16'h0010: xai_control <= merge_strobe(xai_control, s_wdata, s_wstrb);
                16'h0014: xai_cycles <= merge_strobe(xai_cycles, s_wdata, s_wstrb);
                16'h0018: xai_mopa <= merge_strobe(xai_mopa, s_wdata, s_wstrb);
                16'h001c: xai_tiles <= merge_strobe(xai_tiles, s_wdata, s_wstrb);
                16'h0020: xai_descriptors <= merge_strobe(xai_descriptors, s_wdata, s_wstrb);
                16'h0024: xai_accuracy <= merge_strobe(xai_accuracy, s_wdata, s_wstrb);
                16'h0028: xai_test_index <= merge_strobe(xai_test_index, s_wdata, s_wstrb);
                default: begin
                    if (buf_addr[15:0] >= 16'h0100 &&
                        buf_addr[15:0] < 16'h0500)
                        xai_image_words[(buf_addr[15:0]-16'h0100) >> 2]
                            <= merge_strobe(
                                xai_image_words[(buf_addr[15:0]-16'h0100) >> 2],
                                s_wdata, s_wstrb);
                    else if (buf_addr[15:0] >= 16'h0500 &&
                             buf_addr[15:0] < 16'h0540)
                        xai_heatmap_words[(buf_addr[15:0]-16'h0500) >> 2]
                            <= merge_strobe(
                                xai_heatmap_words[(buf_addr[15:0]-16'h0500) >> 2],
                                s_wdata, s_wstrb);
                    else if (buf_addr[15:0] >= 16'h0600 &&
                             buf_addr[15:0] < 16'h060c)
                        xai_score_words[(buf_addr[15:0]-16'h0600) >> 2]
                            <= merge_strobe(
                                xai_score_words[(buf_addr[15:0]-16'h0600) >> 2],
                                s_wdata, s_wstrb);
                end
            endcase
        end
    end

    reg [WIDTH-1:0] hdata;
    reg [WIDTH-1:0] vdata;

    always @(posedge aclk) begin
        if (!aresetn)
            hdata <= {WIDTH{1'b0}};
        else if (hdata == HMAX - 1)
            hdata <= {WIDTH{1'b0}};
        else
            hdata <= hdata + {{(WIDTH-1){1'b0}}, 1'b1};
    end

    always @(posedge aclk) begin
        if (!aresetn)
            vdata <= {WIDTH{1'b0}};
        else if (hdata == HMAX - 1) begin
            if (vdata == VMAX - 1)
                vdata <= {WIDTH{1'b0}};
            else
                vdata <= vdata + {{(WIDTH-1){1'b0}}, 1'b1};
        end
    end

    assign video_clk = aclk;
    assign hsync = ((hdata >= HFP) && (hdata < HSP)) ? HSPP : !HSPP;
    assign vsync = ((vdata >= VFP) && (vdata < VSP)) ? VSPP : !VSPP;
    assign data_enable = (hdata < HSIZE) && (vdata < VSIZE);

    function [7:0] select_byte;
        input [31:0] word;
        input [1:0] lane;
        begin
            case (lane)
                2'd0: select_byte = word[7:0];
                2'd1: select_byte = word[15:8];
                2'd2: select_byte = word[23:16];
                default: select_byte = word[31:24];
            endcase
        end
    endfunction

    function [7:0] heat_rgb;
        input [7:0] value;
        reg [2:0] green;
        begin
            green = value[7] ? ~value[6:4] : value[6:4];
            heat_rgb = {value[7:5], green, ~value[7:6]};
        end
    endfunction

    function [7:0] hex_ascii;
        input [3:0] nibble;
        begin
            hex_ascii = nibble < 10 ? (8'h30 + nibble)
                                    : (8'h41 + nibble - 10);
        end
    endfunction

    function [34:0] glyph5x7;
        input [7:0] character;
        begin
            case (character)
                "0": glyph5x7 = {5'b01110,5'b10001,5'b10011,5'b10101,5'b11001,5'b10001,5'b01110};
                "1": glyph5x7 = {5'b00100,5'b01100,5'b00100,5'b00100,5'b00100,5'b00100,5'b01110};
                "2": glyph5x7 = {5'b01110,5'b10001,5'b00001,5'b00010,5'b00100,5'b01000,5'b11111};
                "3": glyph5x7 = {5'b11110,5'b00001,5'b00001,5'b01110,5'b00001,5'b00001,5'b11110};
                "4": glyph5x7 = {5'b00010,5'b00110,5'b01010,5'b10010,5'b11111,5'b00010,5'b00010};
                "5": glyph5x7 = {5'b11111,5'b10000,5'b10000,5'b11110,5'b00001,5'b00001,5'b11110};
                "6": glyph5x7 = {5'b01110,5'b10000,5'b10000,5'b11110,5'b10001,5'b10001,5'b01110};
                "7": glyph5x7 = {5'b11111,5'b00001,5'b00010,5'b00100,5'b01000,5'b01000,5'b01000};
                "8": glyph5x7 = {5'b01110,5'b10001,5'b10001,5'b01110,5'b10001,5'b10001,5'b01110};
                "9": glyph5x7 = {5'b01110,5'b10001,5'b10001,5'b01111,5'b00001,5'b00001,5'b01110};
                "A": glyph5x7 = {5'b01110,5'b10001,5'b10001,5'b11111,5'b10001,5'b10001,5'b10001};
                "C": glyph5x7 = {5'b01111,5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b01111};
                "D": glyph5x7 = {5'b11110,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b11110};
                "E": glyph5x7 = {5'b11111,5'b10000,5'b10000,5'b11110,5'b10000,5'b10000,5'b11111};
                "F": glyph5x7 = {5'b11111,5'b10000,5'b10000,5'b11110,5'b10000,5'b10000,5'b10000};
                "H": glyph5x7 = {5'b10001,5'b10001,5'b10001,5'b11111,5'b10001,5'b10001,5'b10001};
                "I": glyph5x7 = {5'b11111,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100,5'b11111};
                "L": glyph5x7 = {5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b11111};
                "M": glyph5x7 = {5'b10001,5'b11011,5'b10101,5'b10101,5'b10001,5'b10001,5'b10001};
                "N": glyph5x7 = {5'b10001,5'b11001,5'b10101,5'b10011,5'b10001,5'b10001,5'b10001};
                "O": glyph5x7 = {5'b01110,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b01110};
                "P": glyph5x7 = {5'b11110,5'b10001,5'b10001,5'b11110,5'b10000,5'b10000,5'b10000};
                "R": glyph5x7 = {5'b11110,5'b10001,5'b10001,5'b11110,5'b10100,5'b10010,5'b10001};
                "S": glyph5x7 = {5'b01111,5'b10000,5'b10000,5'b01110,5'b00001,5'b00001,5'b11110};
                "T": glyph5x7 = {5'b11111,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100};
                "U": glyph5x7 = {5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b01110};
                "V": glyph5x7 = {5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b01010,5'b00100};
                "X": glyph5x7 = {5'b10001,5'b10001,5'b01010,5'b00100,5'b01010,5'b10001,5'b10001};
                "Y": glyph5x7 = {5'b10001,5'b10001,5'b01010,5'b00100,5'b00100,5'b00100,5'b00100};
                default: glyph5x7 = 35'd0;
            endcase
        end
    endfunction

    function [7:0] label_ascii;
        input [4:0] label;
        input [4:0] index;
        begin
            label_ascii = " ";
            case (label)
                0: case (index)
                    0:label_ascii="L"; 1:label_ascii="S"; 2:label_ascii="M"; 3:label_ascii="E";
                    5:label_ascii="T"; 6:label_ascii="I"; 7:label_ascii="N"; 8:label_ascii="Y";
                    9:label_ascii="V"; 10:label_ascii="I"; 11:label_ascii="T";
                    13:label_ascii="X"; 14:label_ascii="A"; 15:label_ascii="I";
                    default: label_ascii=" "; endcase
                1: case (index) 0:label_ascii="I";1:label_ascii="N";2:label_ascii="P";3:label_ascii="U";4:label_ascii="T";default:label_ascii=" ";endcase
                2: case (index) 0:label_ascii="A";1:label_ascii="T";2:label_ascii="T";3:label_ascii="E";4:label_ascii="N";5:label_ascii="T";6:label_ascii="I";7:label_ascii="O";8:label_ascii="N";default:label_ascii=" ";endcase
                3: case (index) 0:label_ascii="C";1:label_ascii="L";2:label_ascii="A";3:label_ascii="S";4:label_ascii="S";6:label_ascii="S";7:label_ascii="C";8:label_ascii="O";9:label_ascii="R";10:label_ascii="E";default:label_ascii=" ";endcase
                4: case (index) 0:label_ascii="C";1:label_ascii="Y";2:label_ascii="C";3:label_ascii="L";4:label_ascii="E";5:label_ascii="S";default:label_ascii=" ";endcase
                5: case (index) 0:label_ascii="M";1:label_ascii="O";2:label_ascii="P";3:label_ascii="A";default:label_ascii=" ";endcase
                6: case (index) 0:label_ascii="T";1:label_ascii="I";2:label_ascii="L";3:label_ascii="E";4:label_ascii="S";default:label_ascii=" ";endcase
                7: case (index) 0:label_ascii="D";1:label_ascii="E";2:label_ascii="S";3:label_ascii="C";default:label_ascii=" ";endcase
                8: case (index) 0:label_ascii="A";1:label_ascii="C";2:label_ascii="C";default:label_ascii=" ";endcase
                9: case (index) 0:label_ascii="L";1:label_ascii="A";2:label_ascii="N";3:label_ascii="E";4:label_ascii="S";default:label_ascii=" ";endcase
                10: case (index) 0:label_ascii="P";1:label_ascii="R";2:label_ascii="E";3:label_ascii="D";default:label_ascii=" ";endcase
                11: case (index) 0:label_ascii="E";1:label_ascii="X";2:label_ascii="P";default:label_ascii=" ";endcase
                // 顶部数据流铭牌：这四个模块对应 LSME 的实际算子路径。
                12: case (index) 0:label_ascii="M";1:label_ascii="O";2:label_ascii="P";3:label_ascii="A";default:label_ascii=" ";endcase
                13: case (index) 0:label_ascii="S";1:label_ascii="O";2:label_ascii="F";3:label_ascii="T";default:label_ascii=" ";endcase
                14: case (index) 0:label_ascii="V";1:label_ascii="A";2:label_ascii="D";3:label_ascii="D";default:label_ascii=" ";endcase
                15: case (index) 0:label_ascii="N";1:label_ascii="O";2:label_ascii="R";3:label_ascii="M";default:label_ascii=" ";endcase
                16: case (index) 0:label_ascii="I";1:label_ascii="P";3:label_ascii="P";4:label_ascii="A";5:label_ascii="S";6:label_ascii="S";default:label_ascii=" ";endcase
                17: case (index) 0:label_ascii="I";1:label_ascii="P";3:label_ascii="F";4:label_ascii="A";5:label_ascii="I";6:label_ascii="L";default:label_ascii=" ";endcase
                18: case (index) 0:label_ascii="S";1:label_ascii="M";2:label_ascii="E";4:label_ascii="I";5:label_ascii="N";6:label_ascii="T";7:label_ascii="8";default:label_ascii=" ";endcase
                default: label_ascii = " ";
            endcase
        end
    endfunction

    wire dashboard_enable = xai_control[0];
    // control[1]=1：image buffer 中的每个字节都是视频原生 RGB332；
    // control[1]=0：保持历史灰度字节的显示语义，不影响已有软件包。
    wire image_rgb332 = xai_control[1];
    wire [3:0] predicted_class = xai_control[7:4];
    wire dashboard_ok = xai_control[31:24] == 8'd0;

    // 下面的铭牌和结果条完全由已存在的 enable/status 位驱动；不新增 MMIO，
    // 因而不会改动软件 ABI、描述符或推理的任何时序。
    wire pipe_mopa_box = hdata >= 40 && hdata < 136 &&
                         vdata >= 64 && vdata < 86;
    wire pipe_soft_box = hdata >= 180 && hdata < 276 &&
                         vdata >= 64 && vdata < 86;
    wire pipe_vadd_box = hdata >= 320 && hdata < 416 &&
                         vdata >= 64 && vdata < 86;
    wire pipe_rms_box = hdata >= 460 && hdata < 556 &&
                        vdata >= 64 && vdata < 86;
    wire pipe_sme_badge = hdata >= 616 && hdata < 776 &&
                          vdata >= 64 && vdata < 86;
    wire pipe_arrow = ((hdata >= 136 && hdata < 180) ||
                       (hdata >= 276 && hdata < 320) ||
                       (hdata >= 416 && hdata < 460)) &&
                      vdata >= 73 && vdata < 77;
    wire pipe_border = (((hdata == 40 || hdata == 135) && vdata >= 64 && vdata < 86) ||
                        ((hdata == 180 || hdata == 275) && vdata >= 64 && vdata < 86) ||
                        ((hdata == 320 || hdata == 415) && vdata >= 64 && vdata < 86) ||
                        ((hdata == 460 || hdata == 555) && vdata >= 64 && vdata < 86) ||
                        ((hdata == 616 || hdata == 775) && vdata >= 64 && vdata < 86) ||
                        ((hdata >= 40 && hdata < 136) && (vdata == 64 || vdata == 85)) ||
                        ((hdata >= 180 && hdata < 276) && (vdata == 64 || vdata == 85)) ||
                        ((hdata >= 320 && hdata < 416) && (vdata == 64 || vdata == 85)) ||
                        ((hdata >= 460 && hdata < 556) && (vdata == 64 || vdata == 85)) ||
                        ((hdata >= 616 && hdata < 776) && (vdata == 64 || vdata == 85)));
    wire result_strip = hdata >= 40 && hdata < 640 &&
                        vdata >= 568 && vdata < 592;
    wire result_strip_border = ((hdata >= 40 && hdata < 640) &&
                                (vdata == 568 || vdata == 591)) ||
                               ((vdata >= 568 && vdata < 592) &&
                                (hdata == 40 || hdata == 639));

    // 32x32 源像素以 8x8 无插值放大为 256x256，避免除法器进入像素路径。
    wire image_region = hdata >= 60 && hdata < 316 &&
                        vdata >= 120 && vdata < 376;
    wire heatmap_region = hdata >= 326 && hdata < 582 &&
                          vdata >= 120 && vdata < 376;
    wire score_region = hdata >= 640 && hdata < 768 &&
                        vdata >= 120 && vdata < 440;

    reg [7:0] image_pixel;
    reg [7:0] heatmap_pixel;
    reg [7:0] score_pixel;
    integer image_index;
    integer heatmap_index;
    integer score_index;
    always @(*) begin
        image_pixel = 8'd0;
        heatmap_pixel = 8'd0;
        score_pixel = 8'd0;
        image_index = 0;
        heatmap_index = 0;
        score_index = 0;
        if (!SIMULATION && image_region) begin
            image_index = ((vdata - 120) >> 3) * 32 + ((hdata - 60) >> 3);
            image_pixel = select_byte(xai_image_words[image_index >> 2],
                                      image_index[1:0]);
        end
        if (!SIMULATION && heatmap_region) begin
            heatmap_index = ((vdata - 120) >> 5) * 8 + ((hdata - 326) >> 5);
            heatmap_pixel = select_byte(xai_heatmap_words[heatmap_index >> 2],
                                        heatmap_index[1:0]);
        end
        if (!SIMULATION && score_region) begin
            score_index = (vdata - 120) >> 5;
            score_pixel = select_byte(xai_score_words[score_index >> 2],
                                      score_index[1:0]);
        end
    end

    reg font_active;
    reg [7:0] font_ascii;
    reg [2:0] font_column;
    reg [2:0] font_row;
    integer font_index;
    integer decimal_value;
    always @(*) begin
        font_active = 1'b0;
        font_ascii = " ";
        font_column = 3'd0;
        font_row = 3'd0;
        font_index = 0;
        decimal_value = 0;

        if (!SIMULATION) begin
        if (hdata >= 40 && hdata < 296 && vdata >= 24 && vdata < 38) begin
            font_index = (hdata - 40) >> 4;
            font_ascii = label_ascii(0, font_index[4:0]);
            font_column = ((hdata - 40) >> 1) & 7;
            font_row = (vdata - 24) >> 1;
            font_active = 1'b1;
        end
        else if (hdata >= 60 && hdata < 140 && vdata >= 92 && vdata < 106) begin
            font_index = (hdata - 60) >> 4;
            font_ascii = label_ascii(1, font_index[4:0]);
            font_column = ((hdata - 60) >> 1) & 7;
            font_row = (vdata - 92) >> 1;
            font_active = 1'b1;
        end
        else if (hdata >= 48 && hdata < 112 && vdata >= 68 && vdata < 82) begin
            font_index = (hdata - 48) >> 4;
            font_ascii = label_ascii(12, font_index[4:0]);
            font_column = ((hdata - 48) >> 1) & 7;
            font_row = (vdata - 68) >> 1;
            font_active = 1'b1;
        end
        else if (hdata >= 188 && hdata < 252 && vdata >= 68 && vdata < 82) begin
            font_index = (hdata - 188) >> 4;
            font_ascii = label_ascii(13, font_index[4:0]);
            font_column = ((hdata - 188) >> 1) & 7;
            font_row = (vdata - 68) >> 1;
            font_active = 1'b1;
        end
        else if (hdata >= 328 && hdata < 392 && vdata >= 68 && vdata < 82) begin
            font_index = (hdata - 328) >> 4;
            font_ascii = label_ascii(14, font_index[4:0]);
            font_column = ((hdata - 328) >> 1) & 7;
            font_row = (vdata - 68) >> 1;
            font_active = 1'b1;
        end
        else if (hdata >= 468 && hdata < 516 && vdata >= 68 && vdata < 82) begin
            font_index = (hdata - 468) >> 4;
            font_ascii = label_ascii(15, font_index[4:0]);
            font_column = ((hdata - 468) >> 1) & 7;
            font_row = (vdata - 68) >> 1;
            font_active = 1'b1;
        end
        else if (hdata >= 624 && hdata < 752 && vdata >= 68 && vdata < 82) begin
            font_index = (hdata - 624) >> 4;
            font_ascii = label_ascii(18, font_index[4:0]);
            font_column = ((hdata - 624) >> 1) & 7;
            font_row = (vdata - 68) >> 1;
            font_active = 1'b1;
        end
        else if (hdata >= 320 && hdata < 464 && vdata >= 92 && vdata < 106) begin
            font_index = (hdata - 320) >> 4;
            font_ascii = label_ascii(2, font_index[4:0]);
            font_column = ((hdata - 320) >> 1) & 7;
            font_row = (vdata - 92) >> 1;
            font_active = 1'b1;
        end
        else if (hdata >= 604 && hdata < 780 && vdata >= 92 && vdata < 106) begin
            font_index = (hdata - 604) >> 4;
            font_ascii = label_ascii(3, font_index[4:0]);
            font_column = ((hdata - 604) >> 1) & 7;
            font_row = (vdata - 92) >> 1;
            font_active = 1'b1;
        end
        else if (hdata >= 610 && hdata < 626 && vdata >= 120 && vdata < 440 &&
                 ((vdata - 120) & 31) < 14) begin
            font_index = (vdata - 120) >> 5;
            font_ascii = hex_ascii(font_index[3:0]);
            font_column = ((hdata - 610) >> 1) & 7;
            font_row = ((vdata - 120) & 31) >> 1;
            font_active = 1'b1;
        end
        else if (hdata >= 60 && hdata < 156 && vdata >= 464 && vdata < 478) begin
            font_index = (hdata - 60) >> 4;
            font_ascii = label_ascii(4, font_index[4:0]);
            font_column = ((hdata - 60) >> 1) & 7;
            font_row = (vdata - 464) >> 1;
            font_active = 1'b1;
        end
        else if (hdata >= 164 && hdata < 292 && vdata >= 464 && vdata < 478) begin
            font_index = (hdata - 164) >> 4;
            font_ascii = hex_ascii((xai_cycles >> ((7-font_index)*4)) & 4'hf);
            font_column = ((hdata - 164) >> 1) & 7;
            font_row = (vdata - 464) >> 1;
            font_active = 1'b1;
        end
        else if (hdata >= 330 && hdata < 394 && vdata >= 464 && vdata < 478) begin
            font_index = (hdata - 330) >> 4;
            font_ascii = label_ascii(5, font_index[4:0]);
            font_column = ((hdata - 330) >> 1) & 7;
            font_row = (vdata - 464) >> 1;
            font_active = 1'b1;
        end
        else if (hdata >= 410 && hdata < 538 && vdata >= 464 && vdata < 478) begin
            font_index = (hdata - 410) >> 4;
            font_ascii = hex_ascii((xai_mopa >> ((7-font_index)*4)) & 4'hf);
            font_column = ((hdata - 410) >> 1) & 7;
            font_row = (vdata - 464) >> 1;
            font_active = 1'b1;
        end
        else if (hdata >= 600 && hdata < 680 && vdata >= 464 && vdata < 478) begin
            font_index = (hdata - 600) >> 4;
            font_ascii = label_ascii(9, font_index[4:0]);
            font_column = ((hdata - 600) >> 1) & 7;
            font_row = (vdata - 464) >> 1;
            font_active = 1'b1;
        end
        else if (hdata >= 696 && hdata < 728 && vdata >= 464 && vdata < 478) begin
            font_index = (hdata - 696) >> 4;
            font_ascii = hex_ascii((xai_control[23:16] >> ((1-font_index)*4)) & 4'hf);
            font_column = ((hdata - 696) >> 1) & 7;
            font_row = (vdata - 464) >> 1;
            font_active = 1'b1;
        end
        else if (hdata >= 60 && hdata < 140 && vdata >= 504 && vdata < 518) begin
            font_index = (hdata - 60) >> 4;
            font_ascii = label_ascii(6, font_index[4:0]);
            font_column = ((hdata - 60) >> 1) & 7;
            font_row = (vdata - 504) >> 1;
            font_active = 1'b1;
        end
        else if (hdata >= 150 && hdata < 278 && vdata >= 504 && vdata < 518) begin
            font_index = (hdata - 150) >> 4;
            font_ascii = hex_ascii((xai_tiles >> ((7-font_index)*4)) & 4'hf);
            font_column = ((hdata - 150) >> 1) & 7;
            font_row = (vdata - 504) >> 1;
            font_active = 1'b1;
        end
        else if (hdata >= 330 && hdata < 394 && vdata >= 504 && vdata < 518) begin
            font_index = (hdata - 330) >> 4;
            font_ascii = label_ascii(7, font_index[4:0]);
            font_column = ((hdata - 330) >> 1) & 7;
            font_row = (vdata - 504) >> 1;
            font_active = 1'b1;
        end
        else if (hdata >= 410 && hdata < 538 && vdata >= 504 && vdata < 518) begin
            font_index = (hdata - 410) >> 4;
            font_ascii = hex_ascii((xai_descriptors >> ((7-font_index)*4)) & 4'hf);
            font_column = ((hdata - 410) >> 1) & 7;
            font_row = (vdata - 504) >> 1;
            font_active = 1'b1;
        end
        else if (hdata >= 600 && hdata < 648 && vdata >= 504 && vdata < 518) begin
            font_index = (hdata - 600) >> 4;
            font_ascii = label_ascii(8, font_index[4:0]);
            font_column = ((hdata - 600) >> 1) & 7;
            font_row = (vdata - 504) >> 1;
            font_active = 1'b1;
        end
        else if (hdata >= 660 && hdata < 724 && vdata >= 504 && vdata < 518) begin
            font_index = (hdata - 660) >> 4;
            case (font_index)
                0: decimal_value = (xai_accuracy / 1000) % 10;
                1: decimal_value = (xai_accuracy / 100) % 10;
                2: decimal_value = (xai_accuracy / 10) % 10;
                default: decimal_value = xai_accuracy % 10;
            endcase
            font_ascii = 8'h30 + decimal_value[7:0];
            font_column = ((hdata - 660) >> 1) & 7;
            font_row = (vdata - 504) >> 1;
            font_active = 1'b1;
        end
        else if (hdata >= 60 && hdata < 124 && vdata >= 544 && vdata < 558) begin
            font_index = (hdata - 60) >> 4;
            font_ascii = label_ascii(10, font_index[4:0]);
            font_column = ((hdata - 60) >> 1) & 7;
            font_row = (vdata - 544) >> 1;
            font_active = 1'b1;
        end
        else if (hdata >= 140 && hdata < 156 && vdata >= 544 && vdata < 558) begin
            font_ascii = hex_ascii(xai_control[7:4]);
            font_column = ((hdata - 140) >> 1) & 7;
            font_row = (vdata - 544) >> 1;
            font_active = 1'b1;
        end
        else if (hdata >= 200 && hdata < 248 && vdata >= 544 && vdata < 558) begin
            font_index = (hdata - 200) >> 4;
            font_ascii = label_ascii(11, font_index[4:0]);
            font_column = ((hdata - 200) >> 1) & 7;
            font_row = (vdata - 544) >> 1;
            font_active = 1'b1;
        end
        else if (hdata >= 264 && hdata < 280 && vdata >= 544 && vdata < 558) begin
            font_ascii = hex_ascii(xai_control[11:8]);
            font_column = ((hdata - 264) >> 1) & 7;
            font_row = (vdata - 544) >> 1;
            font_active = 1'b1;
        end
        else if (hdata >= 284 && hdata < 396 && vdata >= 572 && vdata < 586) begin
            font_index = (hdata - 284) >> 4;
            font_ascii = label_ascii(dashboard_ok ? 16 : 17,
                                     font_index[4:0]);
            font_column = ((hdata - 284) >> 1) & 7;
            font_row = (vdata - 572) >> 1;
            font_active = 1'b1;
        end
        end
    end

    wire [34:0] active_glyph = glyph5x7(font_ascii);
    wire font_pixel = font_active && font_column < 5 && font_row < 7 &&
                      active_glyph[34 - (font_row * 5 + font_column)];

    wire legacy_rect =
        (hdata > (DVI_RECT_DIR[31:16] - DVI_RECT_L_W[31:16])) &&
        (hdata < (DVI_RECT_DIR[31:16] + DVI_RECT_L_W[31:16])) &&
        (vdata > DVI_RECT_DIR[15:0]) &&
        (vdata < (DVI_RECT_DIR[15:0] + DVI_RECT_L_W[15:0]));
    wire legacy_square =
        (hdata > (DVI_SQU_DIR[31:16] - DVI_SQU_R[31:16])) &&
        (hdata < (DVI_SQU_DIR[31:16] + DVI_SQU_R[31:16])) &&
        (vdata > (DVI_SQU_DIR[15:0] - DVI_SQU_R[15:0])) &&
        (vdata < (DVI_SQU_DIR[15:0] + DVI_SQU_R[15:0]));

    wire image_border =
        ((hdata >= 57 && hdata < 319) && (vdata == 117 || vdata == 378)) ||
        ((vdata >= 117 && vdata < 379) && (hdata == 57 || hdata == 318));
    wire heatmap_border =
        ((hdata >= 323 && hdata < 585) && (vdata == 117 || vdata == 378)) ||
        ((vdata >= 117 && vdata < 379) && (hdata == 323 || hdata == 584));
    wire score_border =
        ((hdata >= 637 && hdata < 771) && (vdata == 117 || vdata == 442)) ||
        ((vdata >= 117 && vdata < 443) && (hdata == 637 || hdata == 770));
    wire score_bar_y = score_region && (((vdata - 120) & 31) >= 7) &&
                       (((vdata - 120) & 31) < 25);
    wire score_bar_fill = score_bar_y &&
                          ((hdata - 640) < (score_pixel >> 1));
    wire predicted_row = score_region &&
                         (((vdata - 120) >> 5) == predicted_class);

    reg [7:0] pixel_color;
    always @(*) begin
        pixel_color = 8'h00;
        if (data_enable && !SIMULATION) begin
            if (!dashboard_enable) begin
                pixel_color = (legacy_rect | legacy_square) ? 8'he0 : 8'h00;
            end
            else begin
                // 深蓝背景叠加稀疏工程网格，强调这是实时硬件仪表盘而非图片。
                pixel_color = ((hdata[5:0] == 0) || (vdata[5:0] == 0))
                            ? 8'h05 : 8'h01;
                if (vdata >= 16 && vdata < 58)
                    pixel_color = 8'h06;
                if (vdata == 58)
                    pixel_color = 8'h1f;

                if (pipe_mopa_box | pipe_soft_box | pipe_vadd_box | pipe_rms_box)
                    pixel_color = 8'h06;
                if (pipe_sme_badge)
                    pixel_color = 8'h08;
                if (pipe_arrow | pipe_border)
                    pixel_color = 8'h1f;
                if (result_strip)
                    pixel_color = dashboard_ok ? 8'h1c : 8'he0;
                if (result_strip_border)
                    pixel_color = 8'h1f;

                if (image_region)
                    pixel_color = image_rgb332 ? image_pixel
                                                : {image_pixel[7:5],
                                                   image_pixel[7:5],
                                                   image_pixel[7:6]};
                if (heatmap_region)
                    pixel_color = heat_rgb(heatmap_pixel);
                if (score_bar_y)
                    pixel_color = predicted_row ? 8'h08 : 8'h04;
                if (score_bar_fill)
                    pixel_color = predicted_row ? 8'h1c : 8'h1f;
                if (image_border | heatmap_border | score_border)
                    pixel_color = 8'h1f;
                if (font_pixel)
                    pixel_color = 8'h1f;

                // 右侧硬件状态灯：分类正确且逐位校验通过时为绿色。
                if (hdata >= 690 && hdata < 758 && vdata >= 540 && vdata < 566)
                    pixel_color = dashboard_ok ? 8'h1c : 8'he0;
                if (((hdata >= 688 && hdata < 760) &&
                     (vdata == 538 || vdata == 567)) ||
                    ((vdata >= 538 && vdata < 568) &&
                     (hdata == 688 || hdata == 759)))
                    pixel_color = 8'h1f;
            end
        end
    end

    assign video_red   = pixel_color[7:5];
    assign video_green = pixel_color[4:2];
    assign video_blue  = pixel_color[1:0];

endmodule
