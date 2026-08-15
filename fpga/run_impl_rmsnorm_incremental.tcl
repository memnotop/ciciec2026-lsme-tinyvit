# 面向实板启动稳定性的 RMSNorm 增量实现。
#
# 历史可见 RTL 重建后的配置载荷与 2026-07-26 已展示的 V1 位流相同，
# 因而该 routed DCP 是目前唯一可复用的、已知能够稳定从 BaseRAM 启动的
# 物理参考。这里不把它当作功能基线，而只复用未改动的 CPU、时钟、
# BaseRAM、UART、CONFREG 和 DVI 物理实现；LSME 内部重新综合以加入 RMSNorm。
#
# 为避免“展示装修”改变全芯片布局，本候选使用归档版 axi_dvi.v。DVI 的
# MMIO ABI 不变，TinyViT 的输入图、注意力、类别分数和 PASS 灯仍可显示。

set script_dir [file dirname [file normalize [info script]]]
set root_dir [file normalize [file join $script_dir ..]]
set archive_root [file normalize [file join $root_dir .. 技术数据 ciciec2026_lsme_tinyvit-submit ciciec2026_lsme_tinyvit]]
set project_name RmsnormIncremental
set project_path [file join $script_dir project_rmsnorm_incremental]
set part xc7a200tfbg676-1
set reference_dcp [file join $archive_root build remote_v2_base64_no_rms project Loongson_Soc.runs impl_1 soc_top_routed.dcp]
set baseline_dvi [file join $archive_root rtl ip DVI axi_dvi.v]
set current_dvi [file join $root_dir rtl ip DVI axi_dvi.v]
set rms_files [list \
    [file join $root_dir rtl ip lsme lsme_udiv32.v] \
    [file join $root_dir rtl ip lsme lsme_isqrt32.v] \
    [file join $root_dir rtl ip lsme lsme_rmsnorm_core.v]]

foreach required [concat [list $reference_dcp $baseline_dvi $current_dvi] $rms_files] {
    if {![file exists $required]} {
        puts "ERROR: required file is missing: $required"
        exit 1
    }
}

# 独立工程避免污染普通仿真/实现工程，也保证候选的文件来源可审计。
file delete -force $project_path
create_project -force $project_name $project_path -part $part
set_param general.maxThreads 8

add_files -scan_for_includes [file join $root_dir rtl]

# 当前工作区的 DVI 只增加了静态铭牌；本次启动候选恢复已经验证的实现，
# 以减少与加速器无关的布线扰动。
set dvi_file [get_files -quiet $current_dvi]
if {[llength $dvi_file] == 0} {
    puts "ERROR: current DVI source was not added to the project"
    exit 1
}
remove_files $dvi_file
add_files -norecurse -scan_for_includes $baseline_dvi

add_files -norecurse -scan_for_includes \
    [file join $root_dir rtl ip PLL_2019_2 clk_pll.xci]
add_files -fileset constrs_1 -quiet [file join $root_dir fpga constraints]
set_property top soc_top [current_fileset]
update_compile_order -fileset sources_1
upgrade_ip -quiet [get_ips]

# 使用已验证 routed checkpoint 作为增量参考。工具会自动只复用网表和
# 层次名称未改变的部分；新增 RMSNorm 及改动后的 LSME 仍会重新放置布线。
set impl_run [get_runs impl_1]
set_property strategy Performance_Explore $impl_run
set_property incremental_checkpoint $reference_dcp $impl_run
catch {set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED true $impl_run}
catch {set_property STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE AggressiveExplore $impl_run}
catch {set_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE Explore $impl_run}

launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1

if {[get_property PROGRESS $impl_run] ne "100%"} {
    puts "ERROR: incremental RMSNorm implementation failed"
    exit 1
}

open_run impl_1
report_incremental_reuse -file [file join $project_path incremental_reuse.rpt]
report_utilization -file [file join $project_path utilization.rpt]
report_utilization -hierarchical -hierarchical_depth 4 \
    -file [file join $project_path hierarchical_utilization.rpt]
report_timing_summary -delay_type min_max -report_unconstrained \
    -file [file join $project_path timing_summary.rpt]
report_timing -delay_type max -max_paths 20 -nworst 2 \
    -file [file join $project_path critical_paths.rpt]
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
puts "RMSNorm incremental setup slack: $setup_slack ns"
puts "RMSNorm incremental hold slack: $hold_slack ns"
if {$setup_slack < 0.0 || $hold_slack < 0.0} {
    puts "ERROR: incremental RMSNorm candidate has a timing violation"
    exit 1
}

set bit_file [file join $project_path ${project_name}.runs impl_1 soc_top.bit]
if {![file exists $bit_file]} {
    puts "ERROR: expected bitstream was not generated: $bit_file"
    exit 1
}
puts "RMSNorm incremental bitstream: $bit_file"
close_project
exit 0
