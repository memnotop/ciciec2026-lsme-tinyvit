// Behavioral simulation shell for the Vivado clock-wizard XCI.  Vivado
// uses rtl/ip/PLL_2019_2/clk_pll.xci and does not add this simulation file to
// the design source set.
`ifdef VERILATOR
module clk_pll (
    output cpu_clk,
    output sys_clk,
    input  resetn,
    output locked,
    input  clk_in1
);
    assign cpu_clk = clk_in1;
    assign sys_clk = clk_in1;
    assign locked = resetn;
endmodule
`endif
