# 构建远程平台容量诊断用的 LSME lane 变体。
#
# 不改动主工程及其已验证的 V2 RTL：只在独立 Vivado 工程中覆写
# soc_top 参数 LSME_MOPA_LANES。这样可判断远程配置失败是否由 bitstream
# 容量边界触发，同时保留 V2 cached GEMM、Softmax、VADD、RMSNorm、LACC 和 DVI。
#
# 用法：
#   vivado -mode batch -source tools/build_remote_lane_variant.tcl \
#       -tclargs <root> <variant_name> <lanes>

if {[llength $argv] != 3} {
    puts "usage: build_remote_lane_variant.tcl <root> <variant_name> <lanes>"
    exit 2
}

set root [file normalize [lindex $argv 0]]
set variant [lindex $argv 1]
set lanes [lindex $argv 2]
if {$lanes != 16 && $lanes != 32 && $lanes != 64} {
    puts "ERROR: lanes must be 16, 32, or 64"
    exit 2
}

set out_dir "$root/build/$variant"
set project_dir "$out_dir/project"
file delete -force $project_dir
file mkdir $out_dir

create_project -force Loongson_Soc $project_dir -part xc7a200tfbg676-1
add_files -scan_for_includes "$root/rtl"
add_files -norecurse -scan_for_includes "$root/rtl/ip/PLL_2019_2/clk_pll.xci"
add_files -fileset constrs_1 -quiet "$root/fpga/constraints"
set_property top soc_top [current_fileset]
set_property generic "LSME_MOPA_LANES=$lanes" [current_fileset]

upgrade_ip -quiet [get_ips]
set_property strategy Performance_Explore [get_runs impl_1]
set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED true [get_runs impl_1]
set_property STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE AggressiveExplore [get_runs impl_1]
set_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE Explore [get_runs impl_1]

launch_runs impl_1 -jobs 4
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    puts "ERROR: implementation did not complete"
    exit 1
}

open_run impl_1
report_utilization -file "$out_dir/utilization.rpt"
report_timing_summary -delay_type min_max -report_unconstrained \
    -file "$out_dir/timing_summary.rpt"
report_drc -file "$out_dir/drc.rpt"

set paths [get_timing_paths -delay_type max -max_paths 1]
if {[llength $paths] == 0 || [get_property SLACK $paths] < 0.0} {
    puts "ERROR: setup timing is not met"
    exit 1
}
write_bitstream -force "$out_dir/${variant}.bit"
puts "REMOTE_VARIANT_DONE bit=$out_dir/${variant}.bit"
close_project
exit 0
