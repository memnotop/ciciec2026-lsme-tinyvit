# 基于实板稳定 V2 配置的 RGB332 DVI 单模块增量实现。
#
# 已验证的区域赛 routed DCP 与远程板稳定 bitstream 使用相同配置有效载荷。
# 本流程只把其中的 u_axi_dvi 替换为当前 RGB332 版本；CPU、PLL、BaseRAM、
# UART、CONFREG、AXI 互连和 V2 LSME 全部从归档源码重建并以该 DCP 为增量参考。
# 这避免把全芯片重新布局得到的未验证配置当作板端交付物。

set script_dir [file dirname [file normalize [info script]]]
set root_dir [file normalize [file join $script_dir ..]]
set archive_root [file normalize [file join $root_dir .. 技术数据 ciciec2026_lsme_tinyvit-submit ciciec2026_lsme_tinyvit]]
set project_name Rgb332BaselineDvi
set project_path [file join $script_dir project_rgb332_baseline_dvi]
set part xc7a200tfbg676-1
set reference_dcp [file join $archive_root build remote_v2_base64_no_rms project Loongson_Soc.runs impl_1 soc_top_routed.dcp]
set archive_dvi [file join $archive_root rtl ip DVI axi_dvi.v]
set rgb332_dvi [file join $root_dir rtl ip DVI axi_dvi.v]
set archive_pll [file join $archive_root rtl ip PLL_2019_2 clk_pll.xci]
set archive_xdc [file join $archive_root fpga constraints soc.xdc]

foreach required [list $reference_dcp $archive_dvi $rgb332_dvi $archive_pll $archive_xdc] {
    if {![file exists $required]} {
        puts "ERROR: required baseline artifact is missing: $required"
        exit 1
    }
}

# 使用独立工程，不能污染常规全量实现工程或已验证的区域赛工程。
file delete -force $project_path
create_project -force $project_name $project_path -part $part
set_param general.maxThreads 8

# 除 DVI 外全部采用归档的实板基线 RTL，保证没有意外混入当前 RMSNorm 等修改。
add_files -scan_for_includes [file join $archive_root rtl]
set baseline_dvi_file [get_files -quiet $archive_dvi]
if {[llength $baseline_dvi_file] != 1} {
    puts "ERROR: archived DVI source was not added exactly once"
    exit 1
}
remove_files $baseline_dvi_file
add_files -norecurse -scan_for_includes $rgb332_dvi
add_files -norecurse -scan_for_includes $archive_pll
add_files -fileset constrs_1 -quiet $archive_xdc
set_property top soc_top [current_fileset]
update_compile_order -fileset sources_1
upgrade_ip -quiet [get_ips]

# 仅一个外围模块发生变化时，增量实现应复用绝大多数已验证物理结构。
set impl_run [get_runs impl_1]
set_property strategy Performance_Explore $impl_run
set_property incremental_checkpoint $reference_dcp $impl_run
catch {set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED true $impl_run}
catch {set_property STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE AggressiveExplore $impl_run}
catch {set_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE Explore $impl_run}

launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
if {[get_property PROGRESS $impl_run] ne "100%"} {
    puts "ERROR: baseline-DVI incremental implementation failed"
    exit 1
}

open_run impl_1
set reuse_report [file join $project_path incremental_reuse.rpt]
report_incremental_reuse -file $reuse_report
set reuse_handle [open $reuse_report r]
set reuse_text [read $reuse_handle]
close $reuse_handle
if {![regexp {\| Non-Reused Cells[ \t]*\|[ \t]*([0-9.]+)[ \t]*\|} \
              $reuse_text -> non_reused_cells]} {
    puts "ERROR: incremental reuse report has no Non-Reused Cells entry"
    exit 1
}
puts "RGB332 baseline-DVI non-reused cells: $non_reused_cells %"
if {$non_reused_cells > 5.0} {
    puts "ERROR: DVI-only build exceeded the 5% non-reuse boundary"
    exit 1
}
report_utilization -file [file join $project_path utilization.rpt]
report_utilization -hierarchical -hierarchical_depth 4 \
    -file [file join $project_path hierarchical_utilization.rpt]
report_timing_summary -delay_type min_max -report_unconstrained \
    -file [file join $project_path timing_summary.rpt]
report_timing -delay_type max -max_paths 20 -nworst 2 \
    -file [file join $project_path critical_paths.rpt]
report_timing -delay_type min -max_paths 20 -nworst 2 \
    -file [file join $project_path hold_paths.rpt]
report_design_analysis -congestion -file [file join $project_path congestion.rpt]
report_drc -file [file join $project_path drc.rpt]

set setup_path [get_timing_paths -delay_type max -max_paths 1 -nworst 1]
set hold_path [get_timing_paths -delay_type min -max_paths 1 -nworst 1]
if {[llength $setup_path] == 0 || [llength $hold_path] == 0} {
    puts "ERROR: no timing path was reported"
    exit 1
}
set setup_slack [get_property SLACK $setup_path]
set hold_slack [get_property SLACK $hold_path]
puts "RGB332 baseline-DVI setup slack: $setup_slack ns"
puts "RGB332 baseline-DVI hold slack: $hold_slack ns"
if {$setup_slack < 0.0 || $hold_slack < 0.0} {
    puts "ERROR: baseline-DVI candidate has a timing violation"
    exit 1
}

set bit_file [file join $project_path ${project_name}.runs impl_1 soc_top.bit]
if {![file exists $bit_file]} {
    puts "ERROR: expected bitstream was not generated: $bit_file"
    exit 1
}
puts "RGB332 baseline-DVI bitstream: $bit_file"
close_project
exit 0
