# 为流式 Softmax 的融合 Attention 生成独立综合网表。
#
# 该脚本只综合，不做布局布线。后续强制增量流程将以已实板验证的 RGB332
# DVI checkpoint 固定外围启动链，仅重新实现 LSME 加速器区域。score SRAM
# 消除了宽 score 行寄存器，Softmax 仍沿用原有位精确定点规则。

set script_dir [file dirname [file normalize [info script]]]
set root_dir [file normalize [file join $script_dir ..]]
set archive_root [file normalize [file join $root_dir .. 技术数据 ciciec2026_lsme_tinyvit-submit ciciec2026_lsme_tinyvit]]
set fused_dir [file join $script_dir fused_attention]
set project_name Rgb332FusedAttentionShared
set project_path [file join $script_dir project_rgb332_fused_attention_shared]
set part xc7a200tfbg676-1
set archive_dvi [file join $archive_root rtl ip DVI axi_dvi.v]
set archive_exec [file join $archive_root rtl ip lsme lsme_exec_engine.v]
set archive_softmax [file join $archive_root rtl ip lsme lsme_softmax_core.v]
set archive_top [file join $archive_root rtl ip lsme lsme_top.v]
set archive_lsm_core [file join $archive_root rtl ip lsme lsme_core.v]
set stream_softmax [file join $root_dir rtl ip lsme lsme_softmax_core.v]
set fused_top [file join $fused_dir lsme_top_fused_hierarchy.v]
set preserved_lsm_core [file join $fused_dir lsme_core_mopa_hierarchy.v]
set rgb332_dvi [file join $root_dir rtl ip DVI axi_dvi.v]
set fused_exec [file join $fused_dir lsme_exec_engine.v]
set fused_core [file join $fused_dir lsme_fused_attention_core.v]
set fused_softmax_sram [file join $fused_dir lsme_softmax_score_sram.v]
set fused_defs [file join $fused_dir lsme_defs_fused.vh]
set archive_pll [file join $archive_root rtl ip PLL_2019_2 clk_pll.xci]
set archive_xdc [file join $archive_root fpga constraints soc.xdc]

foreach required [list $archive_dvi $archive_exec $archive_softmax $archive_top $archive_lsm_core $stream_softmax $fused_top $preserved_lsm_core $rgb332_dvi $fused_exec \
                       $fused_core $fused_softmax_sram $fused_defs $archive_pll $archive_xdc] {
    if {![file exists $required]} {
        puts "ERROR: required fused-Attention source is missing: $required"
        exit 1
    }
}

file delete -force $project_path
create_project -force $project_name $project_path -part $part
set_param general.maxThreads 8

add_files -scan_for_includes [file join $archive_root rtl]
foreach source_to_replace [list $archive_dvi $archive_exec $archive_softmax $archive_top $archive_lsm_core] {
    set selected [get_files -quiet $source_to_replace]
    if {[llength $selected] != 1} {
        puts "ERROR: archived source was not added exactly once: $source_to_replace"
        exit 1
    }
    remove_files $selected
}
add_files -norecurse -scan_for_includes $rgb332_dvi
add_files -norecurse -scan_for_includes $stream_softmax
add_files -norecurse -scan_for_includes $fused_top
add_files -norecurse -scan_for_includes $preserved_lsm_core
add_files -norecurse -scan_for_includes $fused_defs
add_files -norecurse -scan_for_includes $fused_softmax_sram
add_files -norecurse -scan_for_includes $fused_core
add_files -norecurse -scan_for_includes $fused_exec
set_property include_dirs [list $fused_dir] [current_fileset]
add_files -norecurse -scan_for_includes $archive_pll
add_files -fileset constrs_1 -quiet $archive_xdc
set_property top soc_top [current_fileset]
update_compile_order -fileset sources_1
upgrade_ip -quiet [get_ips]

launch_runs synth_1 -jobs 8
wait_on_run synth_1
set synth_run [get_runs synth_1]
if {[get_property PROGRESS $synth_run] ne "100%"} {
    puts "ERROR: fused-Attention synthesis failed"
    exit 1
}

set dcp_file [file join $project_path ${project_name}.runs synth_1 soc_top.dcp]
if {![file exists $dcp_file]} {
    puts "ERROR: expected synthesis checkpoint was not generated: $dcp_file"
    exit 1
}
puts "Fused-Attention synthesis checkpoint: $dcp_file"
close_project
exit 0
