# 归档 V2 RTL 加 RGB332 DVI 的完整 SoC 回归。
# 测试平台位于独立工程下，config.h 的相对 MIF 路径会读取当前工程 sdk/axi_ram.mif，
# 从而验证当前 CIFAR 固件与区域赛 V2 硬件 ABI 的组合。

set script_dir [file dirname [file normalize [info script]]]
set root_dir [file normalize [file join $script_dir ..]]
set archive_root [file normalize [file join $root_dir .. 技术数据 ciciec2026_lsme_tinyvit-submit ciciec2026_lsme_tinyvit]]
set project_path [file join $script_dir project_rgb332_baseline_dvi]
set project_file [file join $project_path Rgb332BaselineDvi.xpr]
set archive_sim [file join $archive_root sim]

foreach required [list $project_file $archive_sim [file join $root_dir sdk axi_ram.mif]] {
    if {![file exists $required]} {
        puts "ERROR: required baseline-DVI simulation artifact is missing: $required"
        exit 1
    }
}

open_project $project_file
set sim_files [get_files -quiet -of_objects [get_filesets sim_1]]
if {[llength $sim_files] == 0} {
    add_files -fileset sim_1 $archive_sim
}
set_property top tb_top [get_filesets sim_1]
set_property xsim.simulate.log_all_signals false [get_filesets sim_1]
launch_simulation -simset sim_1 -mode behavioral
run all
close_sim
close_project
exit 0
