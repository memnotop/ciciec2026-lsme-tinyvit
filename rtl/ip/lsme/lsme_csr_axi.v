`timescale 1ns / 1ps

// LSME 加速器的 AXI4 单 beat 控制、状态和性能计数器寄存器组。
module lsme_csr_axi #(
    parameter integer MOPA_LANES = 64
) (
    input              clk,
    input              reset,

    output reg         start_pulse,
    output reg         clear_pulse,
    output reg [31:0]  descriptor_addr,
    output reg [1:0]   debug_za_sel,
    output reg [3:0]   debug_za_elem,

    input              engine_busy,
    input              engine_done,
    input      [7:0]   engine_error,
    input      [1:0]   schedule_mode,
    input      [31:0]  user_tag,
    input      [31:0]  perf_descriptor_count,
    input      [31:0]  perf_direct_mem_words,
    input      [31:0]  perf_gemm_tiles,
    input      [31:0]  perf_softmax_rows,
    input      [31:0]  perf_rmsnorm_rows,
    input      [31:0]  perf_mopa_count,
    input      [31:0]  perf_active_cycles,
    input      [31:0]  perf_engine_cycles,
    input      [31:0]  perf_axi_read_beats,
    input      [31:0]  perf_axi_write_beats,
    input      [31:0]  perf_compute_cycles,
    input      [31:0]  perf_memory_stall_cycles,
    input      [31:0]  perf_overlap_cycles,
    input      [31:0]  perf_last_descriptor_cycles,
    input      [31:0]  debug_za_data,

    input      [4:0]   s_awid,
    input      [31:0]  s_awaddr,
    input      [7:0]   s_awlen,
    input      [2:0]   s_awsize,
    input      [1:0]   s_awburst,
    input              s_awlock,
    input      [3:0]   s_awcache,
    input      [2:0]   s_awprot,
    input              s_awvalid,
    output             s_awready,
    input      [31:0]  s_wdata,
    input      [3:0]   s_wstrb,
    input              s_wlast,
    input              s_wvalid,
    output             s_wready,
    output reg [4:0]   s_bid,
    output reg [1:0]   s_bresp,
    output reg         s_bvalid,
    input              s_bready,

    input      [4:0]   s_arid,
    input      [31:0]  s_araddr,
    input      [7:0]   s_arlen,
    input      [2:0]   s_arsize,
    input      [1:0]   s_arburst,
    input              s_arlock,
    input      [3:0]   s_arcache,
    input      [2:0]   s_arprot,
    input              s_arvalid,
    output             s_arready,
    output reg [4:0]   s_rid,
    output reg [31:0]  s_rdata,
    output reg [1:0]   s_rresp,
    output             s_rlast,
    output reg         s_rvalid,
    input              s_rready
);

    reg aw_pending;
    reg [4:0] aw_id;
    reg [11:0] aw_offset;
    reg aw_bad_burst;
    reg w_pending;
    reg [31:0] w_data;
    reg [3:0] w_strb;
    reg w_bad_last;
    reg done_sticky;
    reg [31:0] debug_control;

    wire [7:0] lanes_value = MOPA_LANES;

    assign s_awready = !aw_pending && !s_bvalid;
    assign s_wready = !w_pending && !s_bvalid;
    assign s_arready = !s_rvalid;
    assign s_rlast = 1'b1;

    function automatic [31:0] merge_wstrb;
        input [31:0] old_value;
        input [31:0] new_value;
        input [3:0] byte_enable;
        integer lane;
        begin
            merge_wstrb = old_value;
            for (lane = 0; lane < 4; lane = lane + 1)
                if (byte_enable[lane])
                    merge_wstrb[lane*8 +: 8] = new_value[lane*8 +: 8];
        end
    endfunction

    function automatic register_valid;
        input [11:0] offset;
        begin
            case (offset)
                12'h000, 12'h004, 12'h008, 12'h00c,
                12'h010, 12'h014, 12'h018, 12'h01c,
                12'h020, 12'h024, 12'h028, 12'h02c,
                12'h030, 12'h034, 12'h038, 12'h03c,
                12'h040, 12'h044, 12'h048, 12'h04c,
                12'h050, 12'h054: register_valid = 1'b1;
                default: register_valid = 1'b0;
            endcase
        end
    endfunction

    function automatic [31:0] read_register;
        input [11:0] offset;
        begin
            case (offset)
                12'h000: read_register = 32'h4c534d45; // "LSME"
                // 能力字：版本号、MOPA lane 数、V2 最大缓存 K、功能位图。
                // 当前功能包括 macro8、burst、scratchpad、VADD、Softmax
                // 和 SME 风格的流式 RMSNorm；功能位 bit5 表示 RMSNorm。
                12'h004: read_register = {8'h02, lanes_value, 8'd64, 8'hbf};
                12'h008: read_register = 32'd0;
                12'h00c: read_register = {16'd0, engine_error, 3'd0,
                                           schedule_mode, engine_error != 0,
                                           done_sticky, engine_busy};
                12'h010: read_register = descriptor_addr;
                12'h014: read_register = user_tag;
                12'h018: read_register = perf_descriptor_count;
                12'h01c: read_register = perf_mopa_count;
                12'h020: read_register = perf_active_cycles;
                12'h024: read_register = perf_direct_mem_words;
                12'h028: read_register = perf_gemm_tiles;
                12'h02c: read_register = perf_softmax_rows;
                12'h030: read_register = debug_control;
                12'h034: read_register = debug_za_data;
                12'h038: read_register = perf_engine_cycles;
                12'h03c: read_register = perf_axi_read_beats;
                12'h040: read_register = perf_axi_write_beats;
                12'h044: read_register = perf_compute_cycles;
                12'h048: read_register = perf_memory_stall_cycles;
                12'h04c: read_register = perf_overlap_cycles;
                12'h050: read_register = perf_last_descriptor_cycles;
                12'h054: read_register = perf_rmsnorm_rows;
                default: read_register = 32'd0;
            endcase
        end
    endfunction

    always @(posedge clk) begin
        start_pulse <= 1'b0;
        clear_pulse <= 1'b0;

        if (reset) begin
            aw_pending <= 1'b0;
            aw_id <= 5'd0;
            aw_offset <= 12'd0;
            aw_bad_burst <= 1'b0;
            w_pending <= 1'b0;
            w_data <= 32'd0;
            w_strb <= 4'd0;
            w_bad_last <= 1'b0;
            s_bid <= 5'd0;
            s_bresp <= 2'b00;
            s_bvalid <= 1'b0;
            s_rid <= 5'd0;
            s_rdata <= 32'd0;
            s_rresp <= 2'b00;
            s_rvalid <= 1'b0;
            descriptor_addr <= 32'd0;
            debug_control <= 32'd0;
            debug_za_sel <= 2'd0;
            debug_za_elem <= 4'd0;
            done_sticky <= 1'b0;
            start_pulse <= 1'b0;
            clear_pulse <= 1'b0;
        end
        else begin
            if (engine_done)
                done_sticky <= 1'b1;

            if (s_awvalid && s_awready) begin
                aw_pending <= 1'b1;
                aw_id <= s_awid;
                aw_offset <= s_awaddr[11:0];
                aw_bad_burst <= s_awlen != 0 || s_awsize != 3'b010 ||
                                s_awburst == 2'b11;
            end

            if (s_wvalid && s_wready) begin
                w_pending <= 1'b1;
                w_data <= s_wdata;
                w_strb <= s_wstrb;
                w_bad_last <= !s_wlast;
            end

            if (!s_bvalid && aw_pending && w_pending) begin
                s_bid <= aw_id;
                s_bvalid <= 1'b1;
                if (aw_bad_burst || w_bad_last || !register_valid(aw_offset))
                    s_bresp <= 2'b10;
                else begin
                    s_bresp <= 2'b00;
                    case (aw_offset)
                        12'h008: begin
                            if (w_strb[0] && w_data[0])
                                start_pulse <= 1'b1;
                            if (w_strb[0] && w_data[1]) begin
                                clear_pulse <= 1'b1;
                                done_sticky <= 1'b0;
                            end
                        end
                        12'h010:
                            descriptor_addr <= merge_wstrb(
                                descriptor_addr, w_data, w_strb);
                        12'h030: begin
                            debug_control <= merge_wstrb(
                                debug_control, w_data, w_strb);
                            if (w_strb[0]) begin
                                debug_za_sel <= w_data[1:0];
                                debug_za_elem <= w_data[5:2];
                            end
                        end
                        default: begin end
                    endcase
                end
                aw_pending <= 1'b0;
                w_pending <= 1'b0;
            end

            if (s_bvalid && s_bready)
                s_bvalid <= 1'b0;

            if (s_arvalid && s_arready) begin
                s_rid <= s_arid;
                s_rdata <= read_register(s_araddr[11:0]);
                s_rvalid <= 1'b1;
                s_rresp <= (s_arlen != 0 || s_arsize != 3'b010 ||
                            s_arburst == 2'b11 ||
                            !register_valid(s_araddr[11:0]))
                           ? 2'b10 : 2'b00;
            end
            else if (s_rvalid && s_rready)
                s_rvalid <= 1'b0;
        end
    end

endmodule
