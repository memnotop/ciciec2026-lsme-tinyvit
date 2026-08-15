# 用区域赛归档中的原始 RTL 重新生成 bitstream。
#
# 该脚本故意不引用当前工作区的 rtl/，用于把“新 RMSNorm RTL 导致的问题”与
# “当前 Vivado/远程板写入链重新实现后本身就不能启动的问题”严格分开。

set base_root "/home/liumingjian/mloongson/技术数据/ciciec2026_lsme_tinyvit-submit/ciciec2026_lsme_tinyvit"
set project_name Regional_V2_Baseline_Rebuild
set project_path ./project_regional_baseline_rebuild
set project_part xc7a200tfbg676-1

if {![file exists "$base_root/rtl/soc_top.v"]} {
    puts "ERROR: regional baseline source tree is missing: $base_root"
    exit 1
}

file delete -force $project_path
create_project -force $project_name $project_path -part $project_part
add_files -scan_for_includes "$base_root/rtl"
add_files -norecurse -scan_for_includes \
    "$base_root/rtl/ip/PLL_2019_2/clk_pll.xci"
add_files -fileset constrs_1 -quiet "$base_root/fpga/constraints"
set_property top soc_top [current_fileset]

# 复刻区域赛工程的实现策略；不加入当前项目的任何新增文件或额外约束。
catch {set_property strategy Performance_Explore [get_runs impl_1]}
catch {set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED true [get_runs impl_1]}
catch {set_property STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE AggressiveExplore \
       [get_runs impl_1]}
catch {set_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE Explore [get_runs impl_1]}

launch_runs impl_1 -to_step write_bitstream
wait_on_run impl_1

if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    puts "ERROR: Regional baseline rebuild failed."
    exit 1
}

open_run impl_1
report_utilization -file "$project_path/regional_rebuild_utilization.rpt"
report_timing_summary -delay_type min_max -report_unconstrained \
    -file "$project_path/regional_rebuild_timing_summary.rpt"
report_drc -file "$project_path/regional_rebuild_drc.rpt"

set worst_setup_path [get_timing_paths -delay_type max -max_paths 1 -nworst 1]
set worst_hold_path [get_timing_paths -delay_type min -max_paths 1 -nworst 1]
set worst_setup [get_property SLACK $worst_setup_path]
set worst_hold [get_property SLACK $worst_hold_path]
puts "Regional rebuild worst setup slack: $worst_setup ns"
puts "Regional rebuild worst hold slack: $worst_hold ns"
if {$worst_setup < 0.0 || $worst_hold < 0.0} {
    puts "ERROR: Regional baseline rebuild has a timing violation."
    exit 1
}

close_project
exit 0
