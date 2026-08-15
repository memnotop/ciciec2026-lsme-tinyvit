# RGB332 DVI 候选的定向后布线保持时间修复。
#
# 默认实现只会修复负保持裕量；但远程板曾在“理论通过、裕量极小”的配置上
# 无法启动。因此本脚本从完整布线检查点读取所有保持裕量低于 0.10ns 的实际
# 寄存器路径，为每条路径添加 0.46ns 的局部最小延迟目标，再由物理优化插入
# 合法路由延时。它不改 RTL、时钟频率或软件 ABI。

set script_dir [file dirname [file normalize [info script]]]
set project_path [file join $script_dir project]
set routed_dcp [file join $project_path Loongson_Soc.runs impl_1 soc_top_routed.dcp]
set output_dcp [file join $project_path cifar_rgb332_board_stable.dcp]
set output_bit [file join $project_path cifar_tinyvit_rgb332_board_stable.bit]
set target_slack 0.10
set target_min_delay 0.46

if {![file exists $routed_dcp]} {
    puts "ERROR: routed checkpoint is missing: $routed_dcp"
    exit 1
}

open_project [file join $project_path Loongson_Soc.xpr]
open_checkpoint $routed_dcp

# 先读取最短的 256 条已布线路径。相同起点、终点的重复边沿路径只约束一次。
set seen_paths [dict create]
set targeted_count 0
foreach hold_path [get_timing_paths -delay_type min -max_paths 256 -nworst 1] {
    set slack [get_property SLACK $hold_path]
    if {$slack >= $target_slack} {
        continue
    }

    set start_pin [get_property STARTPOINT_PIN $hold_path]
    set end_pin [get_property ENDPOINT_PIN $hold_path]
    if {[llength $start_pin] != 1 || [llength $end_pin] != 1} {
        continue
    }

    set path_key "${start_pin}->${end_pin}"
    if {[dict exists $seen_paths $path_key]} {
        continue
    }
    dict set seen_paths $path_key 1
    set_min_delay $target_min_delay -from $start_pin -to $end_pin
    incr targeted_count
}

puts "RGB332 targeted short hold paths: $targeted_count"
if {$targeted_count == 0} {
    puts "ERROR: no short hold paths were selected"
    exit 1
}

# 上面的局部最小延迟目标会产生可修复违例；工具只在这些数据路径插入物理延迟。
phys_opt_design -aggressive_hold_fix
route_design -preserve

# 临时约束只用于引导物理工具插入延时。Vivado 没有逐路径删除约束的 Tcl 命令，
# 因此清空时序数据库后重新读取工程的原始 XDC。已验证该操作会自动重新推导
# PLL 生成的 cpu_clk 与 sys_clk，故写出的检查点和 bitstream 不包含临时例外。
reset_timing
read_xdc [file join $script_dir constraints soc.xdc]

report_utilization -file [file join $project_path rgb332_board_stable_utilization.rpt]
report_timing_summary -delay_type min_max -report_unconstrained \
    -file [file join $project_path rgb332_board_stable_timing_summary.rpt]
report_timing -delay_type min -max_paths 40 -nworst 2 \
    -file [file join $project_path rgb332_board_stable_hold_paths.rpt]
report_timing -delay_type max -max_paths 40 -nworst 2 \
    -file [file join $project_path rgb332_board_stable_setup_paths.rpt]
report_drc -file [file join $project_path rgb332_board_stable_drc.rpt]

set setup_path [get_timing_paths -delay_type max -max_paths 1 -nworst 1]
set hold_path [get_timing_paths -delay_type min -max_paths 1 -nworst 1]
if {[llength $setup_path] == 0 || [llength $hold_path] == 0} {
    puts "ERROR: no timing path was reported"
    exit 1
}
set setup_slack [get_property SLACK $setup_path]
set hold_slack [get_property SLACK $hold_path]
puts "RGB332 board-stable setup slack: $setup_slack ns"
puts "RGB332 board-stable hold slack: $hold_slack ns"

if {$setup_slack < $target_slack || $hold_slack < $target_slack} {
    puts "ERROR: RGB332 candidate does not meet the 0.10 ns setup/hold threshold"
    exit 1
}

write_checkpoint -force $output_dcp
write_bitstream -force $output_bit
puts "RGB332 board-stable bitstream: $output_bit"
close_project
exit 0
