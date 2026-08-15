# SME 风格融合 Attention 的增量实现。
#
# 物理参考点是已在远程板成功启动并显示 RGB332 DVI 的 routed checkpoint。
# 本工程只替换 LSME 执行器/新增融合核，并保留该 DVI；CPU、PLL、BaseRAM、
# UART、CONFREG 和 AXI 互连始终使用同一份区域赛归档 RTL。禁止退化为全量重布局。

set script_dir [file dirname [file normalize [info script]]]
set root_dir [file normalize [file join $script_dir ..]]
set archive_root [file normalize [file join $root_dir .. 技术数据 ciciec2026_lsme_tinyvit-submit ciciec2026_lsme_tinyvit]]
set fused_dir [file join $script_dir fused_attention]
set project_name Rgb332FusedAttention
set project_path [file join $script_dir project_rgb332_fused_attention]
set part xc7a200tfbg676-1
set reference_dcp [file join $script_dir project_rgb332_baseline_dvi Rgb332BaselineDvi.runs impl_1 soc_top_routed.dcp]
set archive_dvi [file join $archive_root rtl ip DVI axi_dvi.v]
set archive_exec [file join $archive_root rtl ip lsme lsme_exec_engine.v]
set archive_softmax [file join $archive_root rtl ip lsme lsme_softmax_core.v]
set stream_softmax [file join $root_dir rtl ip lsme lsme_softmax_core.v]
set rgb332_dvi [file join $root_dir rtl ip DVI axi_dvi.v]
set fused_exec [file join $fused_dir lsme_exec_engine.v]
set fused_core [file join $fused_dir lsme_fused_attention_core.v]
set fused_defs [file join $fused_dir lsme_defs_fused.vh]
set archive_pll [file join $archive_root rtl ip PLL_2019_2 clk_pll.xci]
set archive_xdc [file join $archive_root fpga constraints soc.xdc]

foreach required [list $reference_dcp $archive_dvi $archive_exec $archive_softmax $stream_softmax $rgb332_dvi \
                       $fused_exec $fused_core $fused_defs $archive_pll $archive_xdc] {
    if {![file exists $required]} {
        puts "ERROR: required fused-Attention artifact is missing: $required"
        exit 1
    }
}

file delete -force $project_path
create_project -force $project_name $project_path -part $part
set_param general.maxThreads 8

# 先加入物理验证过的区域赛 RTL，只剔除 DVI 和执行器；这两个模块分别由
# RGB332 展示版本和融合 Attention 版本替换。
add_files -scan_for_includes [file join $archive_root rtl]
foreach source_to_replace [list $archive_dvi $archive_exec $archive_softmax] {
    set selected [get_files -quiet $source_to_replace]
    if {[llength $selected] != 1} {
        puts "ERROR: archived source was not added exactly once: $source_to_replace"
        exit 1
    }
    remove_files $selected
}
add_files -norecurse -scan_for_includes $rgb332_dvi
add_files -norecurse -scan_for_includes $stream_softmax
add_files -norecurse -scan_for_includes $fused_defs
add_files -norecurse -scan_for_includes $fused_core
add_files -norecurse -scan_for_includes $fused_exec
set_property include_dirs [list $fused_dir] [current_fileset]
add_files -norecurse -scan_for_includes $archive_pll
add_files -fileset constrs_1 -quiet $archive_xdc
set_property top soc_top [current_fileset]
update_compile_order -fileset sources_1
upgrade_ip -quiet [get_ips]

set impl_run [get_runs impl_1]
set_property strategy Performance_Explore $impl_run
set_property incremental_checkpoint $reference_dcp $impl_run
catch {set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED true $impl_run}
catch {set_property STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE AggressiveExplore $impl_run}
catch {set_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE Explore $impl_run}

launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
if {[get_property PROGRESS $impl_run] ne "100%"} {
    puts "ERROR: fused-Attention incremental implementation failed"
    exit 1
}

open_run impl_1
report_incremental_reuse -file [file join $project_path incremental_reuse.rpt]
report_utilization -file [file join $project_path utilization.rpt]
report_utilization -hierarchical -hierarchical_depth 5 \
    -file [file join $project_path hierarchical_utilization.rpt]
report_timing_summary -delay_type min_max -report_unconstrained \
    -file [file join $project_path timing_summary.rpt]
report_timing -delay_type max -max_paths 20 -nworst 2 \
    -file [file join $project_path critical_paths.rpt]
report_timing -delay_type min -max_paths 20 -nworst 2 \
    -file [file join $project_path hold_paths.rpt]
report_design_analysis -congestion \
    -file [file join $project_path congestion.rpt]
report_drc -file [file join $project_path drc.rpt]

set setup_path [get_timing_paths -delay_type max -max_paths 1 -nworst 1]
set hold_path [get_timing_paths -delay_type min -max_paths 1 -nworst 1]
if {[llength $setup_path] == 0 || [llength $hold_path] == 0} {
    puts "ERROR: no timing path was reported"
    exit 1
}
set setup_slack [get_property SLACK $setup_path]
set hold_slack [get_property SLACK $hold_path]
puts "Fused-Attention setup slack: $setup_slack ns"
puts "Fused-Attention hold slack: $hold_slack ns"
if {$setup_slack < 0.0 || $hold_slack < 0.0} {
    puts "ERROR: fused-Attention candidate has a timing violation"
    exit 1
}

set bit_file [file join $project_path ${project_name}.runs impl_1 soc_top.bit]
if {![file exists $bit_file]} {
    puts "ERROR: expected fused-Attention bitstream was not generated: $bit_file"
    exit 1
}
puts "Fused-Attention bitstream: $bit_file"
close_project
exit 0
