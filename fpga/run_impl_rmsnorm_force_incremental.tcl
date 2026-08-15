# 强制增量布局布线：用于当前 LSME/RMSNorm 只改动约 20% 单元、而自动
# 增量门限（80%）以极小差距拒绝时的板级稳定性候选。
#
# 参考 DCP 是已经产生稳定 V1 实板演示的同一物理配置。当前综合网表来自
# run_impl_rmsnorm_incremental.tcl，使用归档 DVI ABI；因此 CPU、BaseRAM、
# UART、时钟、CONFREG 与 DVI 仍可按单元名称复用，改动的 LSME 内部逻辑
# 则由工具重新实现。该脚本绝不覆盖普通工程或发布目录。

set script_dir [file dirname [file normalize [info script]]]
set root_dir [file normalize [file join $script_dir ..]]
set archive_root [file normalize [file join $root_dir .. 技术数据 ciciec2026_lsme_tinyvit-submit ciciec2026_lsme_tinyvit]]
set source_dcp [file join $script_dir project_rmsnorm_incremental RmsnormIncremental.runs synth_1 soc_top.dcp]
set reference_dcp [file join $archive_root build remote_v2_base64_no_rms project Loongson_Soc.runs impl_1 soc_top_routed.dcp]
set pll_xci [file join $root_dir rtl ip PLL_2019_2 clk_pll.xci]
set constraints [file join $root_dir fpga constraints soc.xdc]
set output_dir [file join $script_dir project_rmsnorm_force_incremental]
set output_bit [file join $output_dir lsme_v2_rmsnorm_force_incremental.bit]

foreach required [list $source_dcp $reference_dcp $pll_xci $constraints] {
    if {![file exists $required]} {
        puts "ERROR: required checkpoint is missing: $required"
        exit 1
    }
}

file mkdir $output_dir

# synth_1 的 DCP 中 PLL 以 OOC 黑盒形式存在。不能用 open_checkpoint
# 直接打开它，否则当前会话不知道如何解析该黑盒；此处完全复刻 Vivado
# impl_1 自动脚本的“DCP + XCI + XDC + link_design”顺序。
create_project -in_memory -part xc7a200tfbg676-1
add_files -quiet $source_dcp
read_ip -quiet $pll_xci
read_xdc $constraints
link_design -top soc_top -part xc7a200tfbg676-1
opt_design -directive Explore

# 自动增量因 79.32% 略低于默认 80% 阈值而退化为全量实现。这里明确强制
# 使用参考物理信息，不给工具静默降级为默认流程的机会。
#
# 注意不能复用整个设计：旧 LSME 宏阵列与新增 RMSNorm 的网表不再完全相同，
# 若把它也保留，会挤占新阵列的放置资源。下面仅选择启动关键且 RTL 未变化的
# 外围层次，故 CPU 取指、BaseRAM、UART、时钟域桥、控制寄存器和 DVI 都从
# 已验证参考继承物理信息；u_lsme 整体故意不在此列表中。
set stable_objects [concat \
    [get_cells -hierarchical -quiet u_cpu] \
    [get_cells -hierarchical -quiet u_axi_ram] \
    [get_cells -hierarchical -quiet u_axi_uart_controller] \
    [get_cells -hierarchical -quiet u_confreg] \
    [get_cells -hierarchical -quiet u_axi_dvi] \
    [get_cells -hierarchical -quiet u_Axi_CDC] \
    [get_cells -hierarchical -quiet u_AxiCrossbar_2x8] \
    [get_cells -hierarchical -quiet u_lsme_lacc_cdc]]
if {[llength $stable_objects] != 8} {
    puts "ERROR: expected 8 stable perimeter hierarchies, got [llength $stable_objects]"
    exit 1
}
read_checkpoint -incremental -force_incr -directive TimingClosure \
    -reuse_objects $stable_objects -fix_objects $stable_objects $reference_dcp
report_incremental_reuse -file [file join $output_dir incremental_reuse_loaded.rpt]

# 不要在这一候选上再进行大范围逻辑重写；目标是最大程度保留稳定板级外围。
place_design -directive Explore
report_incremental_reuse -file [file join $output_dir incremental_reuse_placed.rpt]
phys_opt_design -directive AggressiveExplore
route_design -directive Explore

report_incremental_reuse -file [file join $output_dir incremental_reuse_routed.rpt]
report_utilization -file [file join $output_dir utilization.rpt]
report_utilization -hierarchical -hierarchical_depth 4 \
    -file [file join $output_dir hierarchical_utilization.rpt]
report_timing_summary -delay_type min_max -report_unconstrained \
    -file [file join $output_dir timing_summary.rpt]
report_timing -delay_type max -max_paths 20 -nworst 2 \
    -file [file join $output_dir critical_paths.rpt]
report_design_analysis -congestion -file [file join $output_dir congestion.rpt]
report_drc -file [file join $output_dir drc.rpt]
write_checkpoint -force [file join $output_dir lsme_v2_rmsnorm_force_incremental_routed.dcp]

set setup_path [get_timing_paths -delay_type max -max_paths 1 -nworst 1]
set hold_path [get_timing_paths -delay_type min -max_paths 1 -nworst 1]
if {[llength $setup_path] == 0 || [llength $hold_path] == 0} {
    puts "ERROR: no timing path was reported"
    exit 1
}
set setup_slack [get_property SLACK $setup_path]
set hold_slack [get_property SLACK $hold_path]
puts "Forced incremental RMSNorm setup slack: $setup_slack ns"
puts "Forced incremental RMSNorm hold slack: $hold_slack ns"
if {$setup_slack < 0.0 || $hold_slack < 0.0} {
    puts "ERROR: forced incremental candidate has timing violations"
    exit 1
}

write_bitstream -force $output_bit
if {![file exists $output_bit]} {
    puts "ERROR: expected bitstream was not generated: $output_bit"
    exit 1
}
puts "Forced incremental RMSNorm bitstream: $output_bit"
close_design
exit 0
