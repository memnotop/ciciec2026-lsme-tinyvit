# 从已实板验证的 RGB332-DVI checkpoint 提取未修改的 LSME MOPA 核。
# 该 DCP 用于模块级实现复用，避免新执行器改变全局优化后破坏原有累加链时序。

set script_dir [file dirname [file normalize [info script]]]
set reference_dcp [file join $script_dir project_rgb332_baseline_dvi Rgb332BaselineDvi.runs impl_1 soc_top_routed.dcp]
set output_dcp [file join $script_dir baseline_lsme_core_routed.dcp]
if {![file exists $reference_dcp]} {
    puts "ERROR: baseline checkpoint is missing: $reference_dcp"
    exit 1
}
open_checkpoint $reference_dcp
set core_cell [get_cells -quiet u_lsme/u_core]
if {[llength $core_cell] != 1} {
    puts "ERROR: baseline does not contain exactly one u_lsme/u_core"
    exit 1
}
write_checkpoint -force -cell $core_cell $output_dcp
puts "Extracted baseline MOPA core: $output_dcp"
close_design
exit 0
