# 在独立目录中对“旧 V2 cached RTL + V2 兼容固件”做完整 SoC 仿真。
#
# 用法：
#   vivado -mode batch -source tools/run_v2_compat_old_rtl_sim.tcl \
#       -tclargs <old_v2_source_root> <simulation_output_dir>
#
# 输出目录必须位于 <old_v2_source_root>/fpga 下。旧 rtl/config.h 中的
# SRAM_Init_File 是相对路径；保持这个层级可让仿真读取旧工程 sdk/axi_ram.mif。

if {[llength $argv] != 2} {
    puts "usage: run_v2_compat_old_rtl_sim.tcl <old_root> <out_dir>"
    exit 2
}

set old_root [file normalize [lindex $argv 0]]
set out_dir [file normalize [lindex $argv 1]]
set expected_parent [file normalize "$old_root/fpga"]
if {[file dirname $out_dir] ne $expected_parent} {
    puts "ERROR: out_dir must be directly under $expected_parent"
    exit 2
}

foreach required [list "$old_root/rtl" "$old_root/sim" "$old_root/sdk/axi_ram.mif" \
                       "$old_root/rtl/ip/PLL_2019_2/clk_pll.xci"] {
    if {![file exists $required]} {
        puts "ERROR: missing required path $required"
        exit 2
    }
}

set project_dir "$out_dir/project"
file delete -force $project_dir
file mkdir $out_dir

create_project -force Loongson_Soc $project_dir -part xc7a200tfbg676-1
add_files -scan_for_includes "$old_root/rtl"
add_files -norecurse -scan_for_includes "$old_root/rtl/ip/PLL_2019_2/clk_pll.xci"
add_files -fileset sim_1 "$old_root/sim"
set_property top soc_top [current_fileset]
set_property top tb_top [get_filesets sim_1]
set_property -name {xsim.simulate.log_all_signals} -value {false} \
    -objects [get_filesets sim_1]

launch_simulation -simset sim_1 -mode behavioral
run all
close_sim
close_project
puts "V2_COMPAT_OLD_RTL_SIM_DONE"
exit 0
