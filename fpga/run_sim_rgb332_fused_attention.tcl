# 使用同一套归档 SoC 加融合 Attention 执行器进行行为仿真。

set script_dir [file dirname [file normalize [info script]]]
set root_dir [file normalize [file join $script_dir ..]]
set archive_root [file normalize [file join $root_dir .. 技术数据 ciciec2026_lsme_tinyvit-submit ciciec2026_lsme_tinyvit]]
set fused_dir [file join $script_dir fused_attention]
set project_name Rgb332FusedAttentionSim
set project_path [file join $script_dir project_rgb332_fused_attention_sim]
set part xc7a200tfbg676-1
set archive_dvi [file join $archive_root rtl ip DVI axi_dvi.v]
set archive_exec [file join $archive_root rtl ip lsme lsme_exec_engine.v]
set archive_softmax [file join $archive_root rtl ip lsme lsme_softmax_core.v]
set stream_softmax [file join $root_dir rtl ip lsme lsme_softmax_core.v]
set archive_pll [file join $archive_root rtl ip PLL_2019_2 clk_pll.xci]
set archive_xdc [file join $archive_root fpga constraints soc.xdc]

foreach required [list [file join $archive_root rtl] [file join $archive_root sim] \
                       $archive_dvi $archive_exec $archive_softmax $stream_softmax $archive_pll $archive_xdc \
                       [file join $root_dir rtl ip DVI axi_dvi.v] \
                       [file join $fused_dir lsme_defs_fused.vh] \
                       [file join $fused_dir lsme_softmax_score_sram.v] \
                       [file join $fused_dir lsme_fused_attention_core.v] \
                       [file join $fused_dir lsme_exec_engine.v] \
                       [file join $root_dir sdk axi_ram.mif]] {
    if {![file exists $required]} {
        puts "ERROR: required fused-Attention simulation artifact is missing: $required"
        exit 1
    }
}

file delete -force $project_path
create_project -force $project_name $project_path -part $part
add_files -scan_for_includes [file join $archive_root rtl]
foreach source_to_replace [list $archive_dvi $archive_exec $archive_softmax] {
    set selected [get_files -quiet $source_to_replace]
    if {[llength $selected] != 1} {
        puts "ERROR: archived source was not added exactly once: $source_to_replace"
        exit 1
    }
    remove_files $selected
}
add_files -norecurse -scan_for_includes [file join $root_dir rtl ip DVI axi_dvi.v]
add_files -norecurse -scan_for_includes $stream_softmax
add_files -norecurse -scan_for_includes [file join $fused_dir lsme_defs_fused.vh]
add_files -norecurse -scan_for_includes [file join $fused_dir lsme_softmax_score_sram.v]
add_files -norecurse -scan_for_includes [file join $fused_dir lsme_fused_attention_core.v]
add_files -norecurse -scan_for_includes [file join $fused_dir lsme_exec_engine.v]
set_property include_dirs [list $fused_dir] [current_fileset]
add_files -norecurse -scan_for_includes $archive_pll
add_files -fileset constrs_1 -quiet $archive_xdc
add_files -fileset sim_1 [file join $archive_root sim]
set_property top soc_top [current_fileset]
set_property top tb_top [get_filesets sim_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
upgrade_ip -quiet [get_ips]
set_property xsim.simulate.log_all_signals false [get_filesets sim_1]
launch_simulation -simset sim_1 -mode behavioral
run all
close_sim
close_project
exit 0
