`timescale 1ns / 1ps

// 最多处理 64 个有符号 S32 score 的整数 Softmax。
// 使用 32767 * 2^(-delta/32) 近似指数，其中
// delta = clamp((row_max - score) >> score_shift, 0, 255)。
module lsme_softmax_core #(
    // 1 时逐拍导出概率，省去 512 位 row_out 的变量位选写回网络。
    // 默认 0，保持原 OP_SOFTMAX 的完整行输出 ABI 不变。
    parameter OUTPUT_STREAM_ONLY = 1'b0
) (
    input               clk,
    input               reset,
    input               start,
    input      [6:0]    count,
    input      [4:0]    score_shift,
    input      [2047:0] row_in,
    output reg          busy,
    output reg          done,
    output reg [511:0]  row_out,
    output reg          stream_valid,
    output reg [5:0]    stream_index,
    output reg [7:0]    stream_data
);

    localparam [2:0] ST_IDLE = 3'd0;
    localparam [2:0] ST_MAX  = 3'd1;
    localparam [2:0] ST_EXP  = 3'd2;
    localparam [2:0] ST_PREP = 3'd3;
    localparam [2:0] ST_NORM = 3'd4;

    reg [2:0] state;
    reg [6:0] elem_count;
    reg [5:0] index;
    reg signed [31:0] row_max;
    reg [15:0] exp_buf [0:63];
    reg [21:0] exp_sum;
    reg [4:0] sum_msb;
    reg [15:0] reciprocal;

    reg signed [32:0] delta_full;
    reg [31:0] delta_scaled;
    reg [7:0] delta_index;
    reg [15:0] exp_value;
    reg [31:0] norm_product;
    reg [5:0] norm_shift;
    reg [31:0] norm_rounded;
    integer i;

    function automatic [15:0] exp2_frac;
        input [4:0] frac;
        begin
            case (frac)
                5'd0: exp2_frac=16'd32767; 5'd1: exp2_frac=16'd32065;
                5'd2: exp2_frac=16'd31378; 5'd3: exp2_frac=16'd30705;
                5'd4: exp2_frac=16'd30047; 5'd5: exp2_frac=16'd29404;
                5'd6: exp2_frac=16'd28774; 5'd7: exp2_frac=16'd28157;
                5'd8: exp2_frac=16'd27554; 5'd9: exp2_frac=16'd26963;
                5'd10: exp2_frac=16'd26385; 5'd11: exp2_frac=16'd25820;
                5'd12: exp2_frac=16'd25267; 5'd13: exp2_frac=16'd24725;
                5'd14: exp2_frac=16'd24196; 5'd15: exp2_frac=16'd23677;
                5'd16: exp2_frac=16'd23170; 5'd17: exp2_frac=16'd22673;
                5'd18: exp2_frac=16'd22187; 5'd19: exp2_frac=16'd21712;
                5'd20: exp2_frac=16'd21247; 5'd21: exp2_frac=16'd20791;
                5'd22: exp2_frac=16'd20346; 5'd23: exp2_frac=16'd19910;
                5'd24: exp2_frac=16'd19483; 5'd25: exp2_frac=16'd19066;
                5'd26: exp2_frac=16'd18657; 5'd27: exp2_frac=16'd18258;
                5'd28: exp2_frac=16'd17866; 5'd29: exp2_frac=16'd17483;
                5'd30: exp2_frac=16'd17109; default: exp2_frac=16'd16742;
            endcase
        end
    endfunction

    function automatic [15:0] exp2_lookup;
        input [7:0] delta;
        reg [15:0] base;
        begin
            base = exp2_frac(delta[4:0]);
            exp2_lookup = base >> delta[7:5];
        end
    endfunction

    function automatic [4:0] msb22;
        input [21:0] value;
        integer bit_idx;
        reg found;
        begin
            msb22 = 5'd0;
            found = 1'b0;
            for (bit_idx = 21; bit_idx >= 0; bit_idx = bit_idx - 1) begin
                if (!found && value[bit_idx]) begin
                    msb22 = bit_idx[4:0];
                    found = 1'b1;
                end
            end
        end
    endfunction

    function automatic [7:0] normalized_mantissa;
        input [21:0] value;
        reg [4:0] value_msb;
        reg [21:0] shifted;
        begin
            value_msb = msb22(value);
            if (value_msb >= 7)
                shifted = value >> (value_msb - 7);
            else
                shifted = value << (7 - value_msb);
            normalized_mantissa = shifted[7:0];
        end
    endfunction

    function automatic [31:0] mul_u16_lut;
        input [15:0] lhs;
        input [15:0] rhs;
        reg [31:0] result;
        integer bit_idx;
        begin
            result = 32'd0;
            for (bit_idx = 0; bit_idx < 16; bit_idx = bit_idx + 1)
                if (rhs[bit_idx])
                    result = result + ({16'd0, lhs} << bit_idx);
            mul_u16_lut = result;
        end
    endfunction

    function automatic [15:0] reciprocal_lookup;
        input [7:0] mant;
        begin
            case (mant)
                8'd128: reciprocal_lookup=16'd65024;
                8'd129: reciprocal_lookup=16'd64520;
                8'd130: reciprocal_lookup=16'd64024;
                8'd131: reciprocal_lookup=16'd63535;
                8'd132: reciprocal_lookup=16'd63054;
                8'd133: reciprocal_lookup=16'd62579;
                8'd134: reciprocal_lookup=16'd62112;
                8'd135: reciprocal_lookup=16'd61652;
                8'd136: reciprocal_lookup=16'd61199;
                8'd137: reciprocal_lookup=16'd60752;
                8'd138: reciprocal_lookup=16'd60312;
                8'd139: reciprocal_lookup=16'd59878;
                8'd140: reciprocal_lookup=16'd59451;
                8'd141: reciprocal_lookup=16'd59029;
                8'd142: reciprocal_lookup=16'd58613;
                8'd143: reciprocal_lookup=16'd58203;
                8'd144: reciprocal_lookup=16'd57799;
                8'd145: reciprocal_lookup=16'd57400;
                8'd146: reciprocal_lookup=16'd57007;
                8'd147: reciprocal_lookup=16'd56620;
                8'd148: reciprocal_lookup=16'd56237;
                8'd149: reciprocal_lookup=16'd55860;
                8'd150: reciprocal_lookup=16'd55487;
                8'd151: reciprocal_lookup=16'd55120;
                8'd152: reciprocal_lookup=16'd54757;
                8'd153: reciprocal_lookup=16'd54399;
                8'd154: reciprocal_lookup=16'd54046;
                8'd155: reciprocal_lookup=16'd53697;
                8'd156: reciprocal_lookup=16'd53353;
                8'd157: reciprocal_lookup=16'd53013;
                8'd158: reciprocal_lookup=16'd52678;
                8'd159: reciprocal_lookup=16'd52346;
                8'd160: reciprocal_lookup=16'd52019;
                8'd161: reciprocal_lookup=16'd51696;
                8'd162: reciprocal_lookup=16'd51377;
                8'd163: reciprocal_lookup=16'd51062;
                8'd164: reciprocal_lookup=16'd50750;
                8'd165: reciprocal_lookup=16'd50443;
                8'd166: reciprocal_lookup=16'd50139;
                8'd167: reciprocal_lookup=16'd49839;
                8'd168: reciprocal_lookup=16'd49542;
                8'd169: reciprocal_lookup=16'd49249;
                8'd170: reciprocal_lookup=16'd48959;
                8'd171: reciprocal_lookup=16'd48673;
                8'd172: reciprocal_lookup=16'd48390;
                8'd173: reciprocal_lookup=16'd48110;
                8'd174: reciprocal_lookup=16'd47834;
                8'd175: reciprocal_lookup=16'd47560;
                8'd176: reciprocal_lookup=16'd47290;
                8'd177: reciprocal_lookup=16'd47023;
                8'd178: reciprocal_lookup=16'd46759;
                8'd179: reciprocal_lookup=16'd46498;
                8'd180: reciprocal_lookup=16'd46239;
                8'd181: reciprocal_lookup=16'd45984;
                8'd182: reciprocal_lookup=16'd45731;
                8'd183: reciprocal_lookup=16'd45481;
                8'd184: reciprocal_lookup=16'd45234;
                8'd185: reciprocal_lookup=16'd44990;
                8'd186: reciprocal_lookup=16'd44748;
                8'd187: reciprocal_lookup=16'd44508;
                8'd188: reciprocal_lookup=16'd44272;
                8'd189: reciprocal_lookup=16'd44037;
                8'd190: reciprocal_lookup=16'd43806;
                8'd191: reciprocal_lookup=16'd43576;
                8'd192: reciprocal_lookup=16'd43349;
                8'd193: reciprocal_lookup=16'd43125;
                8'd194: reciprocal_lookup=16'd42902;
                8'd195: reciprocal_lookup=16'd42682;
                8'd196: reciprocal_lookup=16'd42465;
                8'd197: reciprocal_lookup=16'd42249;
                8'd198: reciprocal_lookup=16'd42036;
                8'd199: reciprocal_lookup=16'd41824;
                8'd200: reciprocal_lookup=16'd41615;
                8'd201: reciprocal_lookup=16'd41408;
                8'd202: reciprocal_lookup=16'd41203;
                8'd203: reciprocal_lookup=16'd41000;
                8'd204: reciprocal_lookup=16'd40799;
                8'd205: reciprocal_lookup=16'd40600;
                8'd206: reciprocal_lookup=16'd40403;
                8'd207: reciprocal_lookup=16'd40208;
                8'd208: reciprocal_lookup=16'd40015;
                8'd209: reciprocal_lookup=16'd39823;
                8'd210: reciprocal_lookup=16'd39634;
                8'd211: reciprocal_lookup=16'd39446;
                8'd212: reciprocal_lookup=16'd39260;
                8'd213: reciprocal_lookup=16'd39075;
                8'd214: reciprocal_lookup=16'd38893;
                8'd215: reciprocal_lookup=16'd38712;
                8'd216: reciprocal_lookup=16'd38533;
                8'd217: reciprocal_lookup=16'd38355;
                8'd218: reciprocal_lookup=16'd38179;
                8'd219: reciprocal_lookup=16'd38005;
                8'd220: reciprocal_lookup=16'd37832;
                8'd221: reciprocal_lookup=16'd37661;
                8'd222: reciprocal_lookup=16'd37491;
                8'd223: reciprocal_lookup=16'd37323;
                8'd224: reciprocal_lookup=16'd37157;
                8'd225: reciprocal_lookup=16'd36991;
                8'd226: reciprocal_lookup=16'd36828;
                8'd227: reciprocal_lookup=16'd36666;
                8'd228: reciprocal_lookup=16'd36505;
                8'd229: reciprocal_lookup=16'd36345;
                8'd230: reciprocal_lookup=16'd36187;
                8'd231: reciprocal_lookup=16'd36031;
                8'd232: reciprocal_lookup=16'd35875;
                8'd233: reciprocal_lookup=16'd35721;
                8'd234: reciprocal_lookup=16'd35569;
                8'd235: reciprocal_lookup=16'd35417;
                8'd236: reciprocal_lookup=16'd35267;
                8'd237: reciprocal_lookup=16'd35118;
                8'd238: reciprocal_lookup=16'd34971;
                8'd239: reciprocal_lookup=16'd34825;
                8'd240: reciprocal_lookup=16'd34679;
                8'd241: reciprocal_lookup=16'd34536;
                8'd242: reciprocal_lookup=16'd34393;
                8'd243: reciprocal_lookup=16'd34251;
                8'd244: reciprocal_lookup=16'd34111;
                8'd245: reciprocal_lookup=16'd33972;
                8'd246: reciprocal_lookup=16'd33834;
                8'd247: reciprocal_lookup=16'd33697;
                8'd248: reciprocal_lookup=16'd33561;
                8'd249: reciprocal_lookup=16'd33426;
                8'd250: reciprocal_lookup=16'd33292;
                8'd251: reciprocal_lookup=16'd33160;
                8'd252: reciprocal_lookup=16'd33028;
                8'd253: reciprocal_lookup=16'd32898;
                8'd254: reciprocal_lookup=16'd32768;
                default: reciprocal_lookup=16'd32639;
            endcase
        end
    endfunction

    always @(*) begin
        delta_full = $signed({row_max[31], row_max})
                   - $signed({row_in[index*32+31], row_in[index*32 +: 32]});
        if (delta_full <= 0)
            delta_scaled = 0;
        else
            delta_scaled = $unsigned(delta_full[31:0]) >> score_shift;
        delta_index = delta_scaled > 255 ? 8'hff : delta_scaled[7:0];
        exp_value = exp2_lookup(delta_index);
        norm_product = mul_u16_lut(exp_buf[index], reciprocal);
        norm_shift = sum_msb + 6'd9;
        if (norm_shift == 0)
            norm_rounded = norm_product;
        else
            norm_rounded = (norm_product + (32'd1 << (norm_shift-1))) >> norm_shift;
    end

    always @(posedge clk) begin
        done <= 1'b0;
        stream_valid <= 1'b0;
        if (reset) begin
            state <= ST_IDLE;
            busy <= 1'b0;
            done <= 1'b0;
            elem_count <= 7'd0;
            index <= 6'd0;
            row_max <= 32'sd0;
            exp_sum <= 22'd0;
            sum_msb <= 5'd0;
            reciprocal <= 16'd65024;
            if (!OUTPUT_STREAM_ONLY)
                row_out <= 512'd0;
            stream_valid <= 1'b0;
            stream_index <= 6'd0;
            stream_data <= 8'd0;
            for (i = 0; i < 64; i = i + 1)
                exp_buf[i] <= 16'd0;
        end
        else begin
            case (state)
                ST_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        busy <= 1'b1;
                        elem_count <= (count == 0 || count > 64) ? 7'd64 : count;
                        index <= 6'd0;
                        row_max <= $signed(row_in[31:0]);
                        if (!OUTPUT_STREAM_ONLY)
                            row_out <= 512'd0;
                        state <= ST_MAX;
                    end
                end

                ST_MAX: begin
                    if ($signed(row_in[index*32 +: 32]) > row_max)
                        row_max <= $signed(row_in[index*32 +: 32]);
                    if ({1'b0, index} == elem_count-7'd1) begin
                        index <= 6'd0;
                        exp_sum <= 0;
                        state <= ST_EXP;
                    end
                    else
                        index <= index + 1;
                end

                ST_EXP: begin
                    exp_buf[index] <= exp_value;
                    exp_sum <= exp_sum + {6'd0, exp_value};
                    if ({1'b0, index} == elem_count-7'd1) begin
                        index <= 6'd0;
                        state <= ST_PREP;
                    end
                    else
                        index <= index + 1;
                end

                ST_PREP: begin
                    sum_msb <= msb22(exp_sum);
                    reciprocal <= reciprocal_lookup(normalized_mantissa(exp_sum));
                    state <= ST_NORM;
                end

                ST_NORM: begin
                    if (OUTPUT_STREAM_ONLY) begin
                        stream_valid <= 1'b1;
                        stream_index <= index;
                        stream_data <= norm_rounded > 127
                                     ? 8'd127 : norm_rounded[7:0];
                    end
                    else begin
                        row_out[index*8 +: 8] <= norm_rounded > 127
                                                    ? 8'd127
                                                    : norm_rounded[7:0];
                    end
                    if ({1'b0, index} == elem_count-7'd1) begin
                        busy <= 1'b0;
                        done <= 1'b1;
                        state <= ST_IDLE;
                    end
                    else
                        index <= index + 1;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
