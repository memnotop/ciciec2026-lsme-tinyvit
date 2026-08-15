# 强制增量实现流式 Softmax + score SRAM 的融合 Attention。
#
# 常规增量在融合核加入后只有约 51% 的单元匹配，Vivado 会静默退化为全量
# 布局布线。此前全量候选曾造成远程板无输出，因此本流程固定复用已实板验证
# 的启动关键层级，只让 u_lsme 及其局部连接重新实现。

set script_dir [file dirname [file normalize [info script]]]
set root_dir [file normalize [file join $script_dir ..]]
set archive_root [file normalize [file join $root_dir .. 技术数据 ciciec2026_lsme_tinyvit-submit ciciec2026_lsme_tinyvit]]
set source_dcp [file join $script_dir project_rgb332_fused_attention_shared Rgb332FusedAttentionShared.runs synth_1 soc_top.dcp]
set reference_dcp [file join $script_dir project_rgb332_baseline_dvi Rgb332BaselineDvi.runs impl_1 soc_top_routed.dcp]
set pll_xci [file join $archive_root rtl ip PLL_2019_2 clk_pll.xci]
set constraints [file join $archive_root fpga constraints soc.xdc]
set output_dir [file join $script_dir project_rgb332_fused_attention_shared_force_incremental]
set output_bit [file join $output_dir lsme_fused_attention_shared_force_incremental.bit]

foreach required [list $source_dcp $reference_dcp $pll_xci $constraints] {
    if {![file exists $required]} {
        puts "ERROR: required fused-Attention checkpoint is missing: $required"
        exit 1
    }
}

file delete -force $output_dir
file mkdir $output_dir
create_project -in_memory -part xc7a200tfbg676-1
set_param general.maxThreads 8

# 复刻 Vivado impl run 的 DCP + XCI + XDC 链接顺序，避免 PLL 黑盒丢失。
add_files -quiet $source_dcp
read_ip -quiet $pll_xci
read_xdc $constraints
link_design -top soc_top -part xc7a200tfbg676-1
opt_design -directive Explore

# 固定的层级均与已成功运行的 RGB332-DVI bitstream 保持 RTL、接口和名称不变。
# u_lsme 内部保持可重布线，让物理优化可同时处理融合缓存与 MOPA 接口附近的
# 关键网；硬固定内核会阻断这类优化并产生无效的物理方程告警。
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

# 只固定 MOPA 计算阵列，而不锁定整个 u_core：score SRAM 改变了局部扇出和
# 可用 LUTRAM，过强的区域约束会压缩控制逻辑的时序优化空间。外围启动层级
# 仍从实板基线复用，其余 LSME 逻辑由 placer 自由收敛。
set mopa_core [get_cells -quiet u_lsme/u_core]
if {[llength $mopa_core] != 1} {
    puts "ERROR: expected one unchanged MOPA core, got [llength $mopa_core]"
    exit 1
}
set fused_exec [get_cells -quiet u_lsme/u_exec]
set mopa_array [get_cells -quiet u_lsme/u_core/u_mopa]
if {[llength $fused_exec] != 1 ||
    [llength $mopa_array] != 1 ||
    [get_property KEEP_HIERARCHY $mopa_core] ne "YES" ||
    [get_property KEEP_HIERARCHY $fused_exec] ne "YES" ||
    [get_property KEEP_HIERARCHY $mopa_array] ne "YES"} {
    puts "ERROR: fused implementation requires preserved u_core/u_exec/u_mopa hierarchy"
    exit 1
}
create_pblock pblock_lsme_mopa
resize_pblock [get_pblocks pblock_lsme_mopa] -add {SLICE_X4Y42:SLICE_X137Y103}
add_cells_to_pblock [get_pblocks pblock_lsme_mopa] $mopa_array
report_incremental_reuse -file [file join $output_dir incremental_reuse_loaded.rpt]

place_design -directive Explore
report_incremental_reuse -file [file join $output_dir incremental_reuse_placed.rpt]
phys_opt_design -directive AggressiveExplore
# 核心已经落在基线收敛区域，使用 Explore 对新增缓存区域进行时序与保持优化。
route_design -directive Explore

report_incremental_reuse -file [file join $output_dir incremental_reuse_routed.rpt]
report_utilization -file [file join $output_dir utilization.rpt]
report_utilization -hierarchical -hierarchical_depth 5 \
    -file [file join $output_dir hierarchical_utilization.rpt]
report_timing_summary -delay_type min_max -report_unconstrained \
    -file [file join $output_dir timing_summary.rpt]
report_timing -delay_type max -max_paths 20 -nworst 2 \
    -file [file join $output_dir critical_paths.rpt]
report_timing -delay_type min -max_paths 20 -nworst 2 \
    -file [file join $output_dir hold_paths.rpt]
report_design_analysis -congestion -file [file join $output_dir congestion.rpt]
report_drc -file [file join $output_dir drc.rpt]
write_checkpoint -force [file join $output_dir lsme_fused_attention_force_incremental_routed.dcp]

set setup_path [get_timing_paths -delay_type max -max_paths 1 -nworst 1]
set hold_path [get_timing_paths -delay_type min -max_paths 1 -nworst 1]
if {[llength $setup_path] == 0 || [llength $hold_path] == 0} {
    puts "ERROR: no timing path was reported"
    exit 1
}
set setup_slack [get_property SLACK $setup_path]
set hold_slack [get_property SLACK $hold_path]
puts "Forced score-SRAM fused-Attention setup slack: $setup_slack ns"
puts "Forced score-SRAM fused-Attention hold slack: $hold_slack ns"
if {$setup_slack < 0.0 || $hold_slack < 0.0} {
    puts "ERROR: forced shared-Softmax fused-Attention candidate has timing violations"
    exit 1
}

write_bitstream -force $output_bit
if {![file exists $output_bit]} {
    puts "ERROR: expected fused-Attention bitstream was not generated: $output_bit"
    exit 1
}
puts "Forced shared-Softmax fused-Attention bitstream: $output_bit"
close_design
exit 0
