/*------------------------------------------------------------------------------
--------------------------------------------------------------------------------
Copyright (c) 2016, Loongson Technology Corporation Limited.

All rights reserved.

Redistribution and use in source and binary forms, with or without modification,
are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this 
list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice, 
this list of conditions and the following disclaimer in the documentation and/or
other materials provided with the distribution.

3. Neither the name of Loongson Technology Corporation Limited nor the names of 
its contributors may be used to endorse or promote products derived from this 
software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND 
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED 
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE 
DISCLAIMED. IN NO EVENT SHALL LOONGSON TECHNOLOGY CORPORATION LIMITED BE LIABLE
TO ANY PARTY FOR DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR 
CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE 
GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) 
HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT 
LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF
THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
--------------------------------------------------------------------------------
------------------------------------------------------------------------------*/
`timescale 1ns / 1ps
`include "config.h"
// `define FFT_OUTPUT_TXT

`define UART_PSEL               u_soc_top.u_axi_uart_controller.uart0.PSEL
`define UART_PENBLE             u_soc_top.u_axi_uart_controller.uart0.PENABLE
`define UART_PWRITE             u_soc_top.u_axi_uart_controller.uart0.PWRITE
`define UART_WADDR              u_soc_top.u_axi_uart_controller.uart0.PADDR[7:0]
`define UART_WDATA              u_soc_top.u_axi_uart_controller.uart0.PWDATA[7:0]
`define END_PC                  32'h1c000200

module tb_top( );
reg reset;
reg clk;
reg   [3:0]  touch_btn;
reg   [31:0]  dip_sw;

wire         UART_RX;
wire         UART_TX;
wire  [2:0]  video_red;
wire  [2:0]  video_green;
wire  [1:0]  video_blue;
wire  video_hsync;
wire  video_vsync;
wire  video_clk;
wire  video_de;
wire  [15:0]  leds;
wire  [7:0]  dpy0;
wire  [7:0]  dpy1;
wire  [19:0]  base_ram_addr;
wire  [ 3:0]  base_ram_be_n;
wire  base_ram_ce_n;
wire  base_ram_oe_n;
wire  base_ram_we_n;
wire  [19:0]  ext_ram_addr;
wire  [ 3:0]  ext_ram_be_n;
wire  ext_ram_ce_n;
wire  ext_ram_oe_n;
wire  ext_ram_we_n;
wire  [31:0]  base_ram_data;
wire  [31:0]  ext_ram_data;

//产生时钟与复位信号
initial begin
    clk = 1'b0;
    reset = 1'b1;
    dip_sw = 32'h0;
    #2000;
    reset = 1'b0;
end
always #10 clk=~clk;

//产生按键信号
initial begin
    touch_btn = 4'h0;
    dip_sw    = 32'h0000_abcd;

    #3000000;

    #100000
    touch_btn = 4'b0001;
    #50
    touch_btn = 4'b0000;

    #100000
    touch_btn = 4'b0010;
    #50
    touch_btn = 4'b0000;

    #100000
    touch_btn = 4'b0100;
    #50
    touch_btn = 4'b0000;

    #100000
    touch_btn = 4'b1000;
    #50
    touch_btn = 4'b0000;

end

soc_top  #(.SIMULATION(1'b1)) u_soc_top (
    .clk                     ( clk           ),
    .reset                   ( reset         ),
    .touch_btn               ( touch_btn     ),
    .dip_sw                  ( dip_sw        ),

    .video_red               ( video_red     ),
    .video_green             ( video_green   ),
    .video_blue              ( video_blue    ),
    .video_hsync             ( video_hsync   ),
    .video_vsync             ( video_vsync   ),
    .video_clk               ( video_clk     ),
    .video_de                ( video_de      ),
    .leds                    ( leds          ),
    .dpy0                    ( dpy0          ),
    .dpy1                    ( dpy1          ),

    .base_ram_addr           ( base_ram_addr   ),
    .base_ram_be_n           ( base_ram_be_n   ),
    .base_ram_ce_n           ( base_ram_ce_n   ),
    .base_ram_oe_n           ( base_ram_oe_n   ),
    .base_ram_we_n           ( base_ram_we_n   ),
    .ext_ram_addr            ( ext_ram_addr    ),
    .ext_ram_be_n            ( ext_ram_be_n    ),
    .ext_ram_ce_n            ( ext_ram_ce_n    ),
    .ext_ram_oe_n            ( ext_ram_oe_n    ),
    .ext_ram_we_n            ( ext_ram_we_n    ),

    .base_ram_data           ( base_ram_data   ),
    .ext_ram_data            ( ext_ram_data    ),

    .UART_RX                 ( UART_RX       ),
    .UART_TX                 ( UART_TX       )
);

sram_sp #(
    .AW        ( 18     ),
    .Init_File(`SRAM_Init_File))
base_sram_sp (
    .ram_addr                ( base_ram_addr   ),
    .ram_be_n                ( base_ram_be_n   ),
    .ram_ce_n                ( base_ram_ce_n   ),
    .ram_oe_n                ( base_ram_oe_n   ),
    .ram_we_n                ( base_ram_we_n   ),

    .ram_data                ( base_ram_data   )
);

sram_sp #(
    .AW        ( 18     ),
    .Init_File(`SRAM_Init_File))
ext_sram_sp (
    .ram_addr                ( ext_ram_addr   ),
    .ram_be_n                ( ext_ram_be_n   ),
    .ram_ce_n                ( ext_ram_ce_n   ),
    .ram_oe_n                ( ext_ram_oe_n   ),
    .ram_we_n                ( ext_ram_we_n   ),

    .ram_data                ( ext_ram_data   )
);

//模拟串口打印
wire uart_display;
wire [7:0] uart_data;
wire uart_wen;
assign uart_wen = (`UART_PSEL == 1'b1) &&  (`UART_PENBLE == 1'b1) && (`UART_PWRITE == 1'b1);
assign uart_display = (uart_wen == 1'b1) && (`UART_WADDR == 8'h0);
assign uart_data    = `UART_WDATA;

always @(posedge clk)
begin
    if(uart_display)
    begin
        if(uart_data==8'hff)
        begin
            ;//$finish;
        end
        else
        begin
            $write("%c",uart_data);
        end
    end
end

//仿真结束
wire [31:0] debug_wb_pc;
assign debug_wb_pc = u_soc_top.debug_wb_pc;
wire test_end = debug_wb_pc==`END_PC;
integer cpu_timeout_count = 0;
localparam integer CPU_TIMEOUT_CYCLES = 30000000;
always @(posedge u_soc_top.cpu_clk)
begin
    if (!u_soc_top.cpu_resetn) begin
        cpu_timeout_count <= 0;
    end
    else if(test_end) begin
        $display("==============================================================");
        $display("Test end!");
	    $finish;
	end
    else begin
        cpu_timeout_count <= cpu_timeout_count + 1;
        if (cpu_timeout_count == CPU_TIMEOUT_CYCLES) begin
            $display("[TB] TIMEOUT pc=%08x inst=%08x", debug_wb_pc,
                     u_soc_top.debug_wb_inst);
            $display("[TB] LACC cpu_req=%b cpu_ready=%b sys_req=%b sys_ready=%b",
                     u_soc_top.cpu_lacc_req_valid,
                     u_soc_top.cpu_lacc_req_ready,
                     u_soc_top.sys_lacc_req_valid,
                     u_soc_top.sys_lacc_req_ready);
            $display("[TB] LSME lacc_state=%0d exec_busy=%b exec_state=%0d core_state=%0d error=%h",
                     u_soc_top.u_lsme.lacc_state,
                     u_soc_top.u_lsme.exec_busy,
                     u_soc_top.u_lsme.u_exec.state,
                     u_soc_top.u_lsme.u_core.state,
                     u_soc_top.u_lsme.exec_error);
            $display("[TB] IF valid=%b pc=%08x next=%08x ready=%b allow=%b addr_ok=%b data_ok=%b",
                     u_soc_top.u_cpu.if_stage.fs_valid,
                     u_soc_top.u_cpu.if_stage.fs_pc,
                     u_soc_top.u_cpu.if_stage.nextpc,
                     u_soc_top.u_cpu.if_stage.fs_ready_go,
                     u_soc_top.u_cpu.if_stage.fs_allowin,
                     u_soc_top.u_cpu.inst_addr_ok,
                     u_soc_top.u_cpu.inst_data_ok);
            $display("[TB] BTB lock=%b buffer=%h raw_en=%b raw_taken=%b raw_pc=%08x mux_en=%b mux_taken=%b mux_pc=%08x fetch_target=%b br_state=%b",
                     u_soc_top.u_cpu.if_stage.btb_lock_en,
                     u_soc_top.u_cpu.if_stage.btb_lock_buffer,
                     u_soc_top.u_cpu.btb_en,
                     u_soc_top.u_cpu.btb_taken,
                     u_soc_top.u_cpu.btb_ret_pc,
                     u_soc_top.u_cpu.if_stage.btb_en_t,
                     u_soc_top.u_cpu.if_stage.btb_taken_t,
                     u_soc_top.u_cpu.if_stage.btb_ret_pc_t,
                     u_soc_top.u_cpu.if_stage.fetch_btb_target,
                     u_soc_top.u_cpu.if_stage.br_target_inst_req_state);
            $display("[TB] ID valid=%b pc=%08x ready=%b allow=%b br=%b inst=%08x",
                     u_soc_top.u_cpu.id_stage.ds_valid,
                     u_soc_top.u_cpu.id_stage.ds_pc,
                     u_soc_top.u_cpu.id_stage.ds_ready_go,
                     u_soc_top.u_cpu.id_stage.ds_allowin,
                     u_soc_top.u_cpu.id_stage.br_taken,
                     u_soc_top.u_cpu.id_stage.ds_inst);
            $display("[TB] EX valid=%b pc=%08x ready=%b allow=%b lacc=%b data_valid=%b addr_ok=%b data_ok=%b",
                     u_soc_top.u_cpu.exe_stage.es_valid,
                     u_soc_top.u_cpu.exe_stage.es_pc,
                     u_soc_top.u_cpu.exe_stage.es_ready_go,
                     u_soc_top.u_cpu.exe_stage.es_allowin,
                     u_soc_top.u_cpu.es_lacc_req,
                     u_soc_top.u_cpu.data_valid,
                     u_soc_top.u_cpu.data_addr_ok,
                     u_soc_top.u_cpu.data_data_ok);
            $display("[TB] CPU AXI ar=%b/%b r=%b/%b aw=%b/%b w=%b/%b b=%b/%b",
                     u_soc_top.cpu_arvalid, u_soc_top.cpu_arready,
                     u_soc_top.cpu_rvalid, u_soc_top.cpu_rready,
                     u_soc_top.cpu_awvalid, u_soc_top.cpu_awready,
                     u_soc_top.cpu_wvalid, u_soc_top.cpu_wready,
                     u_soc_top.cpu_bvalid, u_soc_top.cpu_bready);
            $display("[TB] SYS RAM ar=%b/%b r=%b/%b aw=%b/%b w=%b/%b b=%b/%b",
                     u_soc_top.ram_arvalid, u_soc_top.ram_arready,
                     u_soc_top.ram_rvalid, u_soc_top.ram_rready,
                     u_soc_top.ram_awvalid, u_soc_top.ram_awready,
                     u_soc_top.ram_wvalid, u_soc_top.ram_wready,
                     u_soc_top.ram_bvalid, u_soc_top.ram_bready);
            $finish;
        end
    end
end

//FFT测试结果输出
`ifdef FFT_OUTPUT_TXT
    integer fft_output_re;
    integer fft_output_im;
    initial begin
        fft_output_re = $fopen("../../../../../../python/fft512_output_re.txt", "w"); 
        fft_output_im = $fopen("../../../../../../python/fft512_output_im.txt", "w");
        forever begin
        @(posedge u_soc_top.u_axi_fft_top.u_axi_fft_wrap.aclk);
        if(u_soc_top.u_axi_fft_top.u_axi_fft_wrap.valid_out) begin
            $fwrite(fft_output_re, "%04h\n", u_soc_top.u_axi_fft_top.u_axi_fft_wrap.y_re);
            $fwrite(fft_output_im, "%04h\n", u_soc_top.u_axi_fft_top.u_axi_fft_wrap.y_im);
        end
        end
    end
`endif

endmodule
